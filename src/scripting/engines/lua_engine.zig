// ABOUTME: Lua 5.4 scripting engine implementation for zig_llms
// ABOUTME: Provides ScriptingEngine interface implementation using Lua C API

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const EngineConfig = @import("../interface.zig").EngineConfig;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptError = @import("../error_bridge.zig").ScriptError;
const ScriptContext = @import("../context.zig").ScriptContext;

const lua = @import("../../bindings/lua/lua.zig");
const LuaStatePool = @import("lua_lifecycle.zig").LuaStatePool;
const ManagedLuaState = @import("lua_lifecycle.zig").ManagedLuaState;
const StateStats = @import("lua_lifecycle.zig").StateStats;
const TenantManager = @import("lua_isolation.zig").TenantManager;
const TenantLimits = @import("lua_isolation.zig").TenantLimits;

/// Lua scripting engine error types
pub const LuaEngineError = error{
    LuaNotEnabled,
    StateCreationFailed,
    ContextNotFound,
    InvalidArgument,
    ExecutionFailed,
    ModuleRegistrationFailed,
    MemoryError,
    TypeConversionError,
} || lua.LuaError || std.mem.Allocator.Error;

/// Enhanced Lua context with lifecycle management
const LuaContext = struct {
    name: []const u8,
    managed_state: *ManagedLuaState,
    last_error: ?ScriptError,
    allocator: std.mem.Allocator,
    pool: *LuaStatePool,
    mutex: std.Thread.Mutex,
    tenant_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, pool: *LuaStatePool) !*LuaContext {
        const self = try allocator.create(LuaContext);
        errdefer allocator.destroy(self);

        const managed_state = try pool.acquire();
        errdefer pool.release(managed_state);

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        self.* = LuaContext{
            .name = name_copy,
            .managed_state = managed_state,
            .last_error = null,
            .allocator = allocator,
            .pool = pool,
            .mutex = std.Thread.Mutex{},
            .tenant_id = null,
        };

        return self;
    }

    pub fn deinit(self: *LuaContext) void {
        self.pool.release(self.managed_state);
        self.allocator.free(self.name);
        if (self.tenant_id) |tid| {
            self.allocator.free(tid);
        }
        if (self.last_error) |*err| {
            err.deinit(self.allocator);
        }
        self.allocator.destroy(self);
    }

    pub fn clearError(self: *LuaContext) void {
        if (self.last_error) |*err| {
            err.deinit(self.allocator);
            self.last_error = null;
        }
    }

    pub fn setError(self: *LuaContext, error_type: ScriptError.ErrorType, message: []const u8) void {
        self.clearError();
        self.last_error = ScriptError.init(self.allocator, error_type, message, null) catch return;
    }

    pub fn getWrapper(self: *LuaContext) *lua.LuaWrapper {
        return self.managed_state.wrapper;
    }

    pub fn execute(self: *LuaContext, code: []const u8) !void {
        self.managed_state.execute(code) catch |err| {
            self.setError(.execution_error, "Script execution failed");
            return err;
        };
    }

    pub fn createSnapshot(self: *LuaContext) !void {
        try self.managed_state.createSnapshot();
    }

    pub fn restoreSnapshot(self: *LuaContext, index: usize) !void {
        try self.managed_state.restoreSnapshot(index);
    }

    pub fn getMemoryUsage(self: *LuaContext) usize {
        return self.managed_state.getMemoryUsage();
    }

    pub fn collectGarbage(self: *LuaContext) void {
        self.managed_state.collectGarbage();
    }
};

/// Main Lua engine implementation
pub const LuaEngine = struct {
    const Self = @This();

    base: ScriptingEngine,
    allocator: std.mem.Allocator,
    config: EngineConfig,
    contexts: std.StringHashMap(*LuaContext),
    context_mutex: std.Thread.Mutex,
    state_pool: *LuaStatePool,
    tenant_manager: ?*TenantManager = null,

    const vtable = ScriptingEngine.VTable{
        .init = init,
        .deinit = deinit,
        .createContext = createContext,
        .destroyContext = destroyContext,
        .loadScript = loadScript,
        .loadFile = loadFile,
        .executeScript = executeScript,
        .executeFunction = executeFunction,
        .registerModule = registerModule,
        .importModule = importModule,
        .setGlobal = setGlobal,
        .getGlobal = getGlobal,
        .getLastError = getLastError,
        .clearErrors = clearErrors,
        .collectGarbage = collectGarbage,
        .getMemoryUsage = getMemoryUsage,
        // Debugging functions will be implemented later
        .setBreakpoint = null,
        .removeBreakpoint = null,
        .getStackTrace = null,
    };

    pub fn create(allocator: std.mem.Allocator, config: EngineConfig) !*ScriptingEngine {
        if (!lua.lua_enabled) {
            return LuaEngineError.LuaNotEnabled;
        }

        const self = try allocator.create(LuaEngine);
        errdefer allocator.destroy(self);

        // Create state pool with reasonable defaults
        const pool_size = if (config.max_memory_bytes > 0)
            @min(8, config.max_memory_bytes / (10 * 1024 * 1024)) // ~10MB per state
        else
            8; // Default pool size
        const state_pool = try LuaStatePool.init(allocator, config, pool_size);
        errdefer state_pool.deinit();

        self.* = LuaEngine{
            .base = ScriptingEngine{
                .name = "lua",
                .version = "5.4.6",
                .supported_extensions = &[_][]const u8{".lua"},
                .features = ScriptingEngine.EngineFeatures{
                    .async_support = true, // Via coroutines
                    .debugging = true, // Via debug hooks
                    .sandboxing = true, // Via restricted environments
                    .hot_reload = false, // Not implemented yet
                    .native_json = false, // Requires external library
                    .native_regex = false, // Requires external library
                },
                .vtable = &vtable,
                .impl = self,
            },
            .allocator = allocator,
            .config = config,
            .contexts = std.StringHashMap(*LuaContext).init(allocator),
            .context_mutex = std.Thread.Mutex{},
            .state_pool = state_pool,
        };

        return &self.base;
    }

    fn fromBase(base: *ScriptingEngine) *Self {
        return @ptrCast(@alignCast(base.impl));
    }

    // VTable implementations
    fn init(allocator: std.mem.Allocator, config: EngineConfig) anyerror!*ScriptingEngine {
        return Self.create(allocator, config);
    }

    fn deinit(base: *ScriptingEngine) void {
        const self = fromBase(base);

        // Clean up all contexts
        var iterator = self.contexts.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.contexts.deinit();

        // Clean up tenant manager if present
        if (self.tenant_manager) |tm| {
            tm.deinit();
        }

        // Clean up state pool
        self.state_pool.deinit();

        self.allocator.destroy(self);
    }

    fn createContext(base: *ScriptingEngine, context_name: []const u8) anyerror!*ScriptContext {
        const self = fromBase(base);

        self.context_mutex.lock();
        defer self.context_mutex.unlock();

        // Check if context already exists
        if (self.contexts.contains(context_name)) {
            return LuaEngineError.InvalidArgument;
        }

        // Create Lua context
        const lua_context = try LuaContext.init(self.allocator, context_name, self.state_pool);
        errdefer lua_context.deinit();

        // Create script context wrapper
        const script_context = try ScriptContext.init(self.allocator, context_name, &self.base, lua_context);
        errdefer script_context.deinit();

        // Store in our contexts map
        try self.contexts.put(context_name, lua_context);

        return script_context;
    }

    fn destroyContext(base: *ScriptingEngine, context: *ScriptContext) void {
        const self = fromBase(base);

        self.context_mutex.lock();
        defer self.context_mutex.unlock();

        if (self.contexts.fetchRemove(context.name)) |entry| {
            entry.value.deinit();
        }

        context.deinit();
    }

    fn loadScript(context: *ScriptContext, source: []const u8, name: []const u8) anyerror!void {
        _ = name; // TODO: Use for better error reporting
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        lua_context.execute(source) catch |err| {
            lua_context.setError(.execution_error, "Script loading failed");
            return err;
        };
    }

    fn loadFile(context: *ScriptContext, path: []const u8) anyerror!void {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        lua_context.getWrapper().doFile(path) catch |err| {
            lua_context.setError(.execution_error, "File loading failed");
            return err;
        };
    }

    fn executeScript(context: *ScriptContext, source: []const u8) anyerror!ScriptValue {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        const execution = @import("lua_execution.zig");
        const options = execution.ExecutionOptions{
            .name = context.name,
            .capture_stack_trace = true,
        };

        var executor = execution.LuaExecutor.init(lua_context.getWrapper(), lua_context.allocator, options);

        var result = executor.executeString(source) catch |err| {
            lua_context.setError(.execution_error, "Script execution failed");
            return err;
        };
        defer result.deinit();

        // Return the first value if any
        if (result.values.len > 0) {
            // Make a copy to return
            const ret_val = try result.values[0].copy(lua_context.allocator);
            return ret_val;
        }

        return ScriptValue.null;
    }

    fn executeFunction(context: *ScriptContext, func_name: []const u8, args: []const ScriptValue) anyerror!ScriptValue {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        const execution = @import("lua_execution.zig");
        const options = execution.ExecutionOptions{
            .name = context.name,
            .capture_stack_trace = true,
        };

        var executor = execution.LuaExecutor.init(lua_context.getWrapper(), lua_context.allocator, options);

        var result = executor.callFunction(func_name, args) catch |err| {
            lua_context.setError(.execution_error, "Function call failed");
            return err;
        };
        defer result.deinit();

        // Return the first value if any
        if (result.values.len > 0) {
            // Make a copy to return
            const ret_val = try result.values[0].copy(lua_context.allocator);
            return ret_val;
        }

        return ScriptValue.null;
    }

    fn registerModule(context: *ScriptContext, module: *const ScriptModule) anyerror!void {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        const wrapper = lua_context.getWrapper();

        // Create module table
        wrapper.createTable(0, @intCast(module.functions.len + module.constants.len));

        // Register functions
        for (module.functions) |func_def| {
            // TODO: Create C function wrapper that calls the Zig callback
            // For now, just create a placeholder
            wrapper.pushNil();
            try wrapper.setField(-2, func_def.name);
        }

        // Register constants
        for (module.constants) |const_def| {
            const value_converter = @import("lua_value_converter.zig");
            try value_converter.scriptValueToLua(wrapper, const_def.value);
            try wrapper.setField(-2, const_def.name);
        }

        // Store module in global table
        try wrapper.setGlobal(module.name);
    }

    fn importModule(context: *ScriptContext, module_name: []const u8) anyerror!void {
        // In Lua, this would typically be handled by require()
        // For now, just check if the module exists
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        const wrapper = lua_context.getWrapper();

        try wrapper.getGlobal(module_name);
        if (wrapper.isNil(-1)) {
            wrapper.pop(1);
            lua_context.setError(.execution_error, "Module not found");
            return LuaEngineError.ModuleRegistrationFailed;
        }
        wrapper.pop(1);
    }

    fn setGlobal(context: *ScriptContext, name: []const u8, value: ScriptValue) anyerror!void {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        const value_converter = @import("lua_value_converter.zig");

        lua_context.mutex.lock();
        defer lua_context.mutex.unlock();

        // Convert and set the value
        try value_converter.scriptValueToLua(lua_context.getWrapper(), value);
        try lua_context.getWrapper().setGlobal(name);
    }

    fn getGlobal(context: *ScriptContext, name: []const u8) anyerror!ScriptValue {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;

        const value_converter = @import("lua_value_converter.zig");

        lua_context.mutex.lock();
        defer lua_context.mutex.unlock();

        const wrapper = lua_context.getWrapper();

        // Get the global value
        try wrapper.getGlobal(name);
        defer wrapper.pop(1);

        // Convert to ScriptValue
        return try value_converter.luaToScriptValue(wrapper, -1, lua_context.allocator);
    }

    fn getLastError(context: *ScriptContext) ?ScriptError {
        const lua_context = getLuaContext(context) orelse return null;
        return lua_context.last_error;
    }

    fn clearErrors(context: *ScriptContext) void {
        const lua_context = getLuaContext(context) orelse return;
        lua_context.clearError();
    }

    fn collectGarbage(context: *ScriptContext) void {
        const lua_context = getLuaContext(context) orelse return;
        lua_context.collectGarbage();
    }

    fn getMemoryUsage(context: *ScriptContext) usize {
        const lua_context = getLuaContext(context) orelse return 0;
        return lua_context.getMemoryUsage();
    }

    // Helper functions
    fn getLuaContext(context: *ScriptContext) ?*LuaContext {
        return @ptrCast(@alignCast(context.engine_context));
    }

    // Lifecycle management methods
    pub fn createSnapshot(self: *Self, context: *ScriptContext) !void {
        _ = self;
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        try lua_context.createSnapshot();
    }

    pub fn restoreSnapshot(self: *Self, context: *ScriptContext, index: usize) !void {
        _ = self;
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        try lua_context.restoreSnapshot(index);
    }

    pub fn cleanupIdleStates(self: *Self) void {
        self.state_pool.cleanup();
    }

    pub fn getPoolStats(self: *Self) LuaStatePool.PoolStats {
        return self.state_pool.getStats();
    }

    pub fn getContextStats(self: *Self, context: *ScriptContext) ?StateStats {
        _ = self;
        const lua_context = getLuaContext(context) orelse return null;
        return lua_context.managed_state.getStats();
    }

    // Multi-tenant support methods
    pub fn enableMultiTenancy(self: *Self, max_tenants: usize, default_limits: TenantLimits) !void {
        if (self.tenant_manager != null) {
            return LuaEngineError.InvalidArgument;
        }

        self.tenant_manager = try TenantManager.init(self.allocator, max_tenants, default_limits);
    }

    pub fn createTenant(self: *Self, tenant_id: []const u8, name: []const u8, limits: ?TenantLimits) !void {
        const tm = self.tenant_manager orelse return LuaEngineError.InvalidArgument;
        try tm.createTenant(tenant_id, name, limits);
    }

    pub fn deleteTenant(self: *Self, tenant_id: []const u8) !void {
        const tm = self.tenant_manager orelse return LuaEngineError.InvalidArgument;
        try tm.deleteTenant(tenant_id);
    }

    pub fn createTenantContext(self: *Self, context_name: []const u8, tenant_id: []const u8) !*ScriptContext {
        const tm = self.tenant_manager orelse return LuaEngineError.InvalidArgument;

        // Verify tenant exists
        _ = try tm.getTenant(tenant_id);

        self.context_mutex.lock();
        defer self.context_mutex.unlock();

        // Check if context already exists
        if (self.contexts.contains(context_name)) {
            return LuaEngineError.InvalidArgument;
        }

        // Create Lua context with tenant association
        const lua_context = try LuaContext.init(self.allocator, context_name, self.state_pool);
        errdefer lua_context.deinit();

        // Set tenant ID
        lua_context.tenant_id = try self.allocator.dupe(u8, tenant_id);

        // Create script context wrapper
        const script_context = try ScriptContext.init(self.allocator, context_name, &self.base, lua_context);
        errdefer script_context.deinit();

        // Store in our contexts map
        try self.contexts.put(context_name, lua_context);

        return script_context;
    }

    pub fn executeTenantScript(self: *Self, tenant_id: []const u8, code: []const u8) !void {
        const tm = self.tenant_manager orelse return LuaEngineError.InvalidArgument;
        try tm.executeTenantCode(tenant_id, code);
    }

    pub fn getTenantResourceUsage(self: *Self, tenant_id: []const u8) !@import("lua_isolation.zig").IsolatedState.ResourceUsage {
        const tm = self.tenant_manager orelse return LuaEngineError.InvalidArgument;
        return try tm.getTenantResourceUsage(tenant_id);
    }

    pub fn updateTenantLimits(self: *Self, tenant_id: []const u8, new_limits: TenantLimits) !void {
        const tm = self.tenant_manager orelse return LuaEngineError.InvalidArgument;
        try tm.updateTenantLimits(tenant_id, new_limits);
    }
};

// Tests
test "LuaEngine creation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    try std.testing.expectEqualStrings("lua", engine.name);
    try std.testing.expectEqualStrings("5.4.6", engine.version);
    try std.testing.expect(engine.features.async_support);
    try std.testing.expect(engine.features.debugging);
    try std.testing.expect(engine.features.sandboxing);
}

test "LuaEngine context management" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    const context = try engine.createContext("test_context");
    defer engine.destroyContext(context);

    try std.testing.expectEqualStrings("test_context", context.name);
}

test "LuaEngine basic script execution" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    const context = try engine.createContext("test_context");
    defer engine.destroyContext(context);

    // Test simple expression
    const result = try engine.executeScript(context, "return 42");
    defer result.deinit(allocator);

    try std.testing.expect(result == .integer);
    try std.testing.expectEqual(@as(i64, 42), result.integer);
}

test "LuaEngine global variables" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    const context = try engine.createContext("test_context");
    defer engine.destroyContext(context);

    // Set global variable
    const test_value = ScriptValue{ .string = try allocator.dupe(u8, "hello") };
    defer test_value.deinit(allocator);

    try engine.setGlobal(context, "test_var", test_value);

    // Get global variable
    const result = try engine.getGlobal(context, "test_var");
    defer result.deinit(allocator);

    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("hello", result.string);
}

test "LuaEngine multi-tenant isolation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    const lua_engine = @as(*LuaEngine, @ptrCast(@alignCast(engine.impl)));

    // Enable multi-tenancy
    try lua_engine.enableMultiTenancy(5, TenantLimits{
        .max_memory_bytes = 1 * 1024 * 1024,
        .allow_io = false,
        .allow_os = false,
    });

    // Create tenants
    try lua_engine.createTenant("tenant1", "Test Tenant 1", null);
    try lua_engine.createTenant("tenant2", "Test Tenant 2", null);

    // Execute code in different tenants
    try lua_engine.executeTenantScript("tenant1", "tenant_data = 'Tenant 1'");
    try lua_engine.executeTenantScript("tenant2", "tenant_data = 'Tenant 2'");

    // Variables should be isolated between tenants

    // Test resource usage
    const usage1 = try lua_engine.getTenantResourceUsage("tenant1");
    try std.testing.expect(usage1.memory_used > 0);
    try std.testing.expect(usage1.function_calls > 0);

    // Clean up
    try lua_engine.deleteTenant("tenant1");
    try lua_engine.deleteTenant("tenant2");
}
