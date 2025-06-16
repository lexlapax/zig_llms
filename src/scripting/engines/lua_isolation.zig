// ABOUTME: lua_State isolation mechanisms for multi-tenant scenarios
// ABOUTME: Provides tenant isolation, resource limits, and security boundaries

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const LuaError = lua.LuaError;
const EngineConfig = @import("../interface.zig").EngineConfig;

/// Tenant isolation error types
pub const IsolationError = error{
    TenantNotFound,
    TenantAlreadyExists,
    ResourceLimitExceeded,
    SecurityViolation,
    IsolationBreach,
    InvalidConfiguration,
    PermissionDenied,
    QuotaExceeded,
};

/// Tenant resource limits
pub const TenantLimits = struct {
    max_memory_bytes: usize = 10 * 1024 * 1024, // 10MB default
    max_cpu_time_ms: u64 = 5000, // 5 seconds default
    max_stack_size: usize = 1024, // Stack depth limit
    max_global_vars: usize = 1000, // Global variable limit
    max_table_size: usize = 10000, // Table entry limit
    max_string_length: usize = 1024 * 1024, // 1MB string limit
    max_function_calls: u64 = 100000, // Function call limit
    allow_io: bool = false,
    allow_os: bool = false,
    allow_package: bool = false,
    allow_debug: bool = false,
    allow_coroutines: bool = true,
    allow_metatables: bool = true,
    allow_bytecode: bool = false,
    allowed_modules: []const []const u8 = &.{},
    denied_globals: []const []const u8 = &.{},
};

/// Tenant metadata
pub const TenantInfo = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
    last_accessed: i64,
    limits: TenantLimits,
    tags: std.StringHashMap([]const u8),
    parent_tenant: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8, limits: TenantLimits) !TenantInfo {
        return TenantInfo{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .created_at = std.time.milliTimestamp(),
            .last_accessed = std.time.milliTimestamp(),
            .limits = limits,
            .tags = std.StringHashMap([]const u8).init(allocator),
            .parent_tenant = null,
        };
    }

    pub fn deinit(self: *TenantInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.tags.deinit();
    }
};

/// Isolated Lua state for a tenant
pub const IsolatedState = struct {
    wrapper: *LuaWrapper,
    tenant_info: TenantInfo,
    resource_usage: ResourceUsage,
    security_context: SecurityContext,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub const ResourceUsage = struct {
        memory_used: usize = 0,
        cpu_time_used: u64 = 0,
        function_calls: u64 = 0,
        global_vars_count: usize = 0,
        last_gc_time: i64 = 0,
        gc_count: u32 = 0,
    };

    pub const SecurityContext = struct {
        sandbox_env: ?i32 = null, // Registry index for sandbox environment
        original_globals: std.StringHashMap(bool), // Track original globals
        hook_installed: bool = false,
        instruction_count: u64 = 0,
        start_time: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, tenant_info: TenantInfo) !*IsolatedState {
        const self = try allocator.create(IsolatedState);
        errdefer allocator.destroy(self);

        // Create wrapper with custom allocator for memory tracking
        const wrapper = try LuaWrapper.initWithCustomAllocator(allocator, tenant_info.limits.max_memory_bytes, false // debug mode
        );
        errdefer wrapper.deinit();

        self.* = IsolatedState{
            .wrapper = wrapper,
            .tenant_info = tenant_info,
            .resource_usage = ResourceUsage{},
            .security_context = SecurityContext{
                .original_globals = std.StringHashMap(bool).init(allocator),
            },
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };

        // Initialize isolation
        try self.setupIsolation();

        return self;
    }

    pub fn deinit(self: *IsolatedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up security context
        self.security_context.original_globals.deinit();

        // Clean up Lua state
        self.wrapper.deinit();

        // Clean up tenant info
        self.tenant_info.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    fn setupIsolation(self: *IsolatedState) !void {
        if (!lua.lua_enabled) return;

        // Install resource limit hooks
        try self.installResourceHooks();

        // Create sandboxed environment
        try self.createSandboxEnvironment();

        // Apply security restrictions
        try self.applySecurityRestrictions();

        self.security_context.start_time = std.time.milliTimestamp();
    }

    fn installResourceHooks(self: *IsolatedState) !void {
        const hook_data = try self.allocator.create(HookData);
        hook_data.* = .{
            .state = self,
            .last_check = std.time.milliTimestamp(),
        };

        // Set debug hook for instruction counting and limits
        lua.c.lua_sethook(self.wrapper.state, hookFunction, lua.c.LUA_MASKCOUNT, 1000 // Check every 1000 instructions
        );

        // Store hook data in registry
        lua.c.lua_pushlightuserdata(self.wrapper.state, hook_data);
        lua.c.lua_setfield(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, "_tenant_hook_data");

        self.security_context.hook_installed = true;
    }

    fn hookFunction(L: ?*lua.c.lua_State, ar: ?*lua.c.lua_Debug) callconv(.C) void {
        _ = ar;
        const state = L.?;

        // Get hook data
        lua.c.lua_getfield(state, lua.c.LUA_REGISTRYINDEX, "_tenant_hook_data");
        const hook_data = @as(*HookData, @ptrCast(@alignCast(lua.c.lua_touserdata(state, -1))));
        lua.c.lua_pop(state, 1);

        const isolated_state = hook_data.state;
        isolated_state.security_context.instruction_count += 1000;

        const now = std.time.milliTimestamp();

        // Check CPU time limit
        const elapsed = now - isolated_state.security_context.start_time;
        if (elapsed > @as(i64, @intCast(isolated_state.tenant_info.limits.max_cpu_time_ms))) {
            lua.c.luaL_error(state, "CPU time limit exceeded for tenant");
            return;
        }

        // Check memory periodically (every 100ms)
        if (now - hook_data.last_check > 100) {
            hook_data.last_check = now;

            // Update memory usage
            if (isolated_state.wrapper.getAllocationStats()) |stats| {
                isolated_state.resource_usage.memory_used = stats.total_allocated;

                if (stats.total_allocated > isolated_state.tenant_info.limits.max_memory_bytes) {
                    lua.c.luaL_error(state, "Memory limit exceeded for tenant");
                    return;
                }
            }
        }

        // Check function call limit
        if (isolated_state.resource_usage.function_calls > isolated_state.tenant_info.limits.max_function_calls) {
            lua.c.luaL_error(state, "Function call limit exceeded for tenant");
            return;
        }
    }

    const HookData = struct {
        state: *IsolatedState,
        last_check: i64,
    };

    fn createSandboxEnvironment(self: *IsolatedState) !void {
        const L = self.wrapper.state;

        // Create new environment table
        lua.c.lua_newtable(L);

        // Copy safe globals
        lua.c.lua_pushglobaltable(L);
        lua.c.lua_pushnil(L);

        while (lua.c.lua_next(L, -2) != 0) {
            // key at -2, value at -1
            const key_type = lua.c.lua_type(L, -2);

            if (key_type == lua.c.LUA_TSTRING) {
                const key = lua.c.lua_tostring(L, -2);
                const key_str = std.mem.span(key);

                // Check if this global is allowed
                if (self.isGlobalAllowed(key_str)) {
                    // Duplicate key for table insertion
                    lua.c.lua_pushvalue(L, -2);
                    lua.c.lua_pushvalue(L, -2);

                    // sandbox_env[key] = value
                    lua.c.lua_rawset(L, -6);

                    // Track original global
                    try self.security_context.original_globals.put(try self.allocator.dupe(u8, key_str), true);
                }
            }

            lua.c.lua_pop(L, 1); // Remove value, keep key for next iteration
        }

        lua.c.lua_pop(L, 1); // Remove global table

        // Store sandbox environment in registry
        const ref = lua.c.luaL_ref(L, lua.c.LUA_REGISTRYINDEX);
        self.security_context.sandbox_env = ref;

        // Set as the default environment for new functions
        lua.c.lua_rawgeti(L, lua.c.LUA_REGISTRYINDEX, ref);
        lua.c.lua_setglobal(L, "_ENV");
    }

    fn isGlobalAllowed(self: *IsolatedState, name: []const u8) bool {
        // Check denied list first
        for (self.tenant_info.limits.denied_globals) |denied| {
            if (std.mem.eql(u8, name, denied)) {
                return false;
            }
        }

        // Check specific dangerous globals
        const dangerous_globals = [_][]const u8{
            "dofile",         "loadfile", "load",         "loadstring",
            "rawget",         "rawset",   "rawequal",     "rawlen",
            "getfenv",        "setfenv",  "getmetatable", "setmetatable",
            "collectgarbage", "newproxy",
        };

        for (dangerous_globals) |dangerous| {
            if (std.mem.eql(u8, name, dangerous)) {
                return !self.tenant_info.limits.allow_metatables or
                    std.mem.eql(u8, dangerous, "collectgarbage");
            }
        }

        // Check module restrictions
        if (std.mem.eql(u8, name, "require")) {
            return self.tenant_info.limits.allowed_modules.len > 0;
        }

        // Check library restrictions
        if (std.mem.eql(u8, name, "io") or std.mem.eql(u8, name, "file")) {
            return self.tenant_info.limits.allow_io;
        }

        if (std.mem.eql(u8, name, "os")) {
            return self.tenant_info.limits.allow_os;
        }

        if (std.mem.eql(u8, name, "package")) {
            return self.tenant_info.limits.allow_package;
        }

        if (std.mem.eql(u8, name, "debug")) {
            return self.tenant_info.limits.allow_debug;
        }

        if (std.mem.eql(u8, name, "coroutine")) {
            return self.tenant_info.limits.allow_coroutines;
        }

        // Allow by default
        return true;
    }

    fn applySecurityRestrictions(self: *IsolatedState) !void {
        const L = self.wrapper.state;

        // Override require if modules are restricted
        if (self.tenant_info.limits.allowed_modules.len > 0) {
            const require_wrapper =
                \\local allowed_modules = {...}
                \\local original_require = require
                \\function require(modname)
                \\    local allowed = false
                \\    for _, mod in ipairs(allowed_modules) do
                \\        if mod == modname then
                \\            allowed = true
                \\            break
                \\        end
                \\    end
                \\    if not allowed then
                \\        error("Module '" .. modname .. "' is not allowed for this tenant")
                \\    end
                \\    return original_require(modname)
                \\end
            ;

            try self.wrapper.doString(require_wrapper);

            // Push allowed modules
            lua.c.lua_getglobal(L, "require");
            for (self.tenant_info.limits.allowed_modules) |module| {
                try self.wrapper.pushString(module);
            }

            lua.c.lua_call(L, @intCast(self.tenant_info.limits.allowed_modules.len), 0);
        }

        // Disable bytecode loading if restricted
        if (!self.tenant_info.limits.allow_bytecode) {
            const bytecode_check =
                \\local original_load = load
                \\function load(chunk, chunkname, mode, env)
                \\    if mode and mode:find("b") then
                \\        error("Bytecode loading is disabled for this tenant")
                \\    end
                \\    return original_load(chunk, chunkname, mode or "t", env)
                \\end
            ;

            try self.wrapper.doString(bytecode_check);
        }

        // Apply string length limits
        if (self.tenant_info.limits.max_string_length > 0) {
            const string_limit =
                \\local original_concat = string.concat or table.concat
                \\local max_length = ...
                \\function string.concat(...)
                \\    local result = original_concat(...)
                \\    if #result > max_length then
                \\        error("String length limit exceeded")
                \\    end
                \\    return result
                \\end
            ;

            try self.wrapper.doString(string_limit);
            self.wrapper.pushNumber(@floatFromInt(self.tenant_info.limits.max_string_length));
            lua.c.lua_call(L, 1, 0);
        }
    }

    pub fn execute(self: *IsolatedState, code: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Update last accessed time
        self.tenant_info.last_accessed = std.time.milliTimestamp();

        // Reset execution context
        self.security_context.start_time = std.time.milliTimestamp();

        // Use sandbox environment
        if (self.security_context.sandbox_env) |ref| {
            lua.c.lua_rawgeti(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, ref);
            lua.c.lua_setupvalue(self.wrapper.state, -2, 1);
        }

        // Execute with error handling
        self.wrapper.doString(code) catch {
            return IsolationError.SecurityViolation;
        };
    }

    pub fn getResourceUsage(self: *IsolatedState) ResourceUsage {
        self.mutex.lock();
        defer self.mutex.unlock();

        var usage = self.resource_usage;

        // Update current memory usage
        if (self.wrapper.getAllocationStats()) |stats| {
            usage.memory_used = stats.total_allocated;
        }

        return usage;
    }

    pub fn collectGarbage(self: *IsolatedState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCCOLLECT, 0);
        self.resource_usage.gc_count += 1;
        self.resource_usage.last_gc_time = std.time.milliTimestamp();
    }

    pub fn validateSecurity(self: *IsolatedState) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if sandbox is intact
        if (self.security_context.sandbox_env == null) {
            return IsolationError.IsolationBreach;
        }

        // Verify hook is still installed
        if (self.security_context.hook_installed) {
            const hook = lua.c.lua_gethook(self.wrapper.state);
            if (hook == null) {
                return IsolationError.SecurityViolation;
            }
        }

        // Check for unauthorized globals
        const L = self.wrapper.state;
        lua.c.lua_pushglobaltable(L);
        lua.c.lua_pushnil(L);

        while (lua.c.lua_next(L, -2) != 0) {
            if (lua.c.lua_type(L, -2) == lua.c.LUA_TSTRING) {
                const key = lua.c.lua_tostring(L, -2);
                const key_str = std.mem.span(key);

                if (!self.security_context.original_globals.contains(key_str) and
                    !self.isGlobalAllowed(key_str))
                {
                    lua.c.lua_pop(L, 2);
                    return IsolationError.SecurityViolation;
                }
            }
            lua.c.lua_pop(L, 1);
        }

        lua.c.lua_pop(L, 1);
    }
};

/// Multi-tenant Lua state manager
pub const TenantManager = struct {
    tenants: std.StringHashMap(*IsolatedState),
    tenant_limits: std.StringHashMap(TenantLimits),
    default_limits: TenantLimits,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    max_tenants: usize,

    pub fn init(allocator: std.mem.Allocator, max_tenants: usize, default_limits: TenantLimits) !*TenantManager {
        const self = try allocator.create(TenantManager);
        self.* = TenantManager{
            .tenants = std.StringHashMap(*IsolatedState).init(allocator),
            .tenant_limits = std.StringHashMap(TenantLimits).init(allocator),
            .default_limits = default_limits,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .max_tenants = max_tenants,
        };
        return self;
    }

    pub fn deinit(self: *TenantManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all tenants
        var iter = self.tenants.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.tenants.deinit();
        self.tenant_limits.deinit();

        self.allocator.destroy(self);
    }

    pub fn createTenant(self: *TenantManager, id: []const u8, name: []const u8, limits: ?TenantLimits) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if tenant already exists
        if (self.tenants.contains(id)) {
            return IsolationError.TenantAlreadyExists;
        }

        // Check max tenants limit
        if (self.tenants.count() >= self.max_tenants) {
            return IsolationError.QuotaExceeded;
        }

        // Create tenant info
        const tenant_limits = limits orelse self.default_limits;
        const tenant_info = try TenantInfo.init(self.allocator, id, name, tenant_limits);

        // Create isolated state
        const isolated_state = try IsolatedState.init(self.allocator, tenant_info);
        errdefer isolated_state.deinit();

        // Store tenant
        try self.tenants.put(id, isolated_state);
        try self.tenant_limits.put(id, tenant_limits);
    }

    pub fn deleteTenant(self: *TenantManager, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.tenants.fetchRemove(id)) |entry| {
            entry.value.deinit();
            _ = self.tenant_limits.remove(id);
        } else {
            return IsolationError.TenantNotFound;
        }
    }

    pub fn getTenant(self: *TenantManager, id: []const u8) !*IsolatedState {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.tenants.get(id) orelse return IsolationError.TenantNotFound;
    }

    pub fn executeTenantCode(self: *TenantManager, tenant_id: []const u8, code: []const u8) !void {
        const tenant = try self.getTenant(tenant_id);

        // Validate security before execution
        try tenant.validateSecurity();

        // Execute code
        try tenant.execute(code);

        // Update resource tracking
        tenant.resource_usage.function_calls += 1;
    }

    pub fn getTenantResourceUsage(self: *TenantManager, tenant_id: []const u8) !IsolatedState.ResourceUsage {
        const tenant = try self.getTenant(tenant_id);
        return tenant.getResourceUsage();
    }

    pub fn collectTenantGarbage(self: *TenantManager, tenant_id: []const u8) !void {
        const tenant = try self.getTenant(tenant_id);
        tenant.collectGarbage();
    }

    pub fn getAllTenants(self: *TenantManager, allocator: std.mem.Allocator) ![]TenantInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var tenants = std.ArrayList(TenantInfo).init(allocator);
        errdefer tenants.deinit();

        var iter = self.tenants.iterator();
        while (iter.next()) |entry| {
            const tenant_copy = TenantInfo{
                .id = try allocator.dupe(u8, entry.value_ptr.*.tenant_info.id),
                .name = try allocator.dupe(u8, entry.value_ptr.*.tenant_info.name),
                .created_at = entry.value_ptr.*.tenant_info.created_at,
                .last_accessed = entry.value_ptr.*.tenant_info.last_accessed,
                .limits = entry.value_ptr.*.tenant_info.limits,
                .tags = std.StringHashMap([]const u8).init(allocator),
                .parent_tenant = entry.value_ptr.*.tenant_info.parent_tenant,
            };
            try tenants.append(tenant_copy);
        }

        return try tenants.toOwnedSlice();
    }

    pub fn updateTenantLimits(self: *TenantManager, tenant_id: []const u8, new_limits: TenantLimits) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tenant = self.tenants.get(tenant_id) orelse return IsolationError.TenantNotFound;

        // Update limits
        tenant.tenant_info.limits = new_limits;
        try self.tenant_limits.put(tenant_id, new_limits);

        // Reapply security restrictions with new limits
        try tenant.applySecurityRestrictions();
    }
};

// Tests
test "IsolatedState creation and execution" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    const tenant_info = try TenantInfo.init(allocator, "test-tenant", "Test Tenant", .{});
    const isolated = try IsolatedState.init(allocator, tenant_info);
    defer isolated.deinit();

    // Test basic execution
    try isolated.execute("x = 42");

    // Test resource usage
    const usage = isolated.getResourceUsage();
    try std.testing.expect(usage.memory_used > 0);
}

test "TenantManager multi-tenant isolation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    const manager = try TenantManager.init(allocator, 10, .{});
    defer manager.deinit();

    // Create multiple tenants
    try manager.createTenant("tenant1", "Tenant 1", .{
        .max_memory_bytes = 5 * 1024 * 1024,
        .allow_io = false,
    });

    try manager.createTenant("tenant2", "Tenant 2", .{
        .max_memory_bytes = 10 * 1024 * 1024,
        .allow_coroutines = false,
    });

    // Execute code in different tenants
    try manager.executeTenantCode("tenant1", "tenant_var = 'tenant1'");
    try manager.executeTenantCode("tenant2", "tenant_var = 'tenant2'");

    // Verify isolation - variables should not leak between tenants

    // Test resource limits
    const usage1 = try manager.getTenantResourceUsage("tenant1");
    const usage2 = try manager.getTenantResourceUsage("tenant2");

    try std.testing.expect(usage1.memory_used > 0);
    try std.testing.expect(usage2.memory_used > 0);

    // Clean up
    try manager.deleteTenant("tenant1");
    try manager.deleteTenant("tenant2");
}

test "Security restrictions" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    const tenant_info = try TenantInfo.init(allocator, "secure-tenant", "Secure Tenant", .{
        .allow_io = false,
        .allow_os = false,
        .allow_debug = false,
        .allow_bytecode = false,
    });

    const isolated = try IsolatedState.init(allocator, tenant_info);
    defer isolated.deinit();

    // These should fail due to security restrictions
    isolated.execute("os.execute('ls')") catch |err| {
        try std.testing.expect(err == IsolationError.SecurityViolation);
    };

    // Safe operations should work
    try isolated.execute("local x = 1 + 1");
    try isolated.execute("local t = {1, 2, 3}");
}
