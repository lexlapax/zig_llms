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

/// Lua-specific context data
const LuaContext = struct {
    name: []const u8,
    wrapper: *lua.LuaWrapper,
    last_error: ?ScriptError,
    allocator: std.mem.Allocator,
    memory_usage: std.atomic.Value(usize),
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) !*LuaContext {
        const self = try allocator.create(LuaContext);
        errdefer allocator.destroy(self);
        
        const wrapper = try lua.LuaWrapper.init(allocator);
        errdefer wrapper.deinit();
        
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        
        self.* = LuaContext{
            .name = name_copy,
            .wrapper = wrapper,
            .last_error = null,
            .allocator = allocator,
            .memory_usage = std.atomic.Value(usize).init(0),
        };
        
        return self;
    }
    
    pub fn deinit(self: *LuaContext) void {
        self.wrapper.deinit();
        self.allocator.free(self.name);
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
};

/// Main Lua engine implementation
pub const LuaEngine = struct {
    const Self = @This();
    
    base: ScriptingEngine,
    allocator: std.mem.Allocator,
    config: EngineConfig,
    contexts: std.StringHashMap(*LuaContext),
    context_mutex: std.Thread.Mutex,
    
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
        
        self.* = LuaEngine{
            .base = ScriptingEngine{
                .name = "lua",
                .version = "5.4.6",
                .supported_extensions = &[_][]const u8{ ".lua" },
                .features = ScriptingEngine.EngineFeatures{
                    .async_support = true,  // Via coroutines
                    .debugging = true,      // Via debug hooks
                    .sandboxing = true,     // Via restricted environments
                    .hot_reload = false,    // Not implemented yet
                    .native_json = false,   // Requires external library
                    .native_regex = false,  // Requires external library
                },
                .vtable = &vtable,
                .impl = self,
            },
            .allocator = allocator,
            .config = config,
            .contexts = std.StringHashMap(*LuaContext).init(allocator),
            .context_mutex = std.Thread.Mutex{},
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
        const lua_context = try LuaContext.init(self.allocator, context_name);
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
        
        lua_context.wrapper.doString(source) catch |err| {
            lua_context.setError(.execution_error, "Script loading failed");
            return err;
        };
    }
    
    fn loadFile(context: *ScriptContext, path: []const u8) anyerror!void {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        lua_context.wrapper.doFile(path) catch |err| {
            lua_context.setError(.execution_error, "File loading failed");
            return err;
        };
    }
    
    fn executeScript(context: *ScriptContext, source: []const u8) anyerror!ScriptValue {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        const initial_top = lua_context.wrapper.getTop();
        
        lua_context.wrapper.doString(source) catch |err| {
            lua_context.setError(.execution_error, "Script execution failed");
            return err;
        };
        
        // If there's a return value on the stack, convert it
        const current_top = lua_context.wrapper.getTop();
        if (current_top > initial_top) {
            const result = try luaValueToScriptValue(lua_context, -1);
            lua_context.wrapper.pop(current_top - initial_top);
            return result;
        }
        
        return ScriptValue.nil;
    }
    
    fn executeFunction(context: *ScriptContext, func_name: []const u8, args: []const ScriptValue) anyerror!ScriptValue {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        // Get the function
        try lua_context.wrapper.getGlobal(func_name);
        if (!lua_context.wrapper.isFunction(-1)) {
            lua_context.wrapper.pop(1);
            lua_context.setError(.execution_error, "Function not found or not callable");
            return LuaEngineError.ExecutionFailed;
        }
        
        // Push arguments
        for (args) |arg| {
            try scriptValueToLuaValue(lua_context, arg);
        }
        
        // Call function
        lua_context.wrapper.call(@intCast(args.len), 1) catch |err| {
            lua_context.setError(.execution_error, "Function call failed");
            return err;
        };
        
        // Convert result
        const result = try luaValueToScriptValue(lua_context, -1);
        lua_context.wrapper.pop(1);
        
        return result;
    }
    
    fn registerModule(context: *ScriptContext, module: *const ScriptModule) anyerror!void {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        // Create module table
        lua_context.wrapper.createTable(0, @intCast(module.functions.len + module.constants.len));
        
        // Register functions
        for (module.functions) |func_def| {
            // TODO: Create C function wrapper that calls the Zig callback
            // For now, just create a placeholder
            lua_context.wrapper.pushNil();
            try lua_context.wrapper.setField(-2, func_def.name);
        }
        
        // Register constants
        for (module.constants) |const_def| {
            try scriptValueToLuaValue(lua_context, const_def.value);
            try lua_context.wrapper.setField(-2, const_def.name);
        }
        
        // Store module in global table
        try lua_context.wrapper.setGlobal(module.name);
    }
    
    fn importModule(context: *ScriptContext, module_name: []const u8) anyerror!void {
        // In Lua, this would typically be handled by require()
        // For now, just check if the module exists
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        try lua_context.wrapper.getGlobal(module_name);
        if (lua_context.wrapper.isNil(-1)) {
            lua_context.wrapper.pop(1);
            lua_context.setError(.execution_error, "Module not found");
            return LuaEngineError.ModuleRegistrationFailed;
        }
        lua_context.wrapper.pop(1);
    }
    
    fn setGlobal(context: *ScriptContext, name: []const u8, value: ScriptValue) anyerror!void {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        try scriptValueToLuaValue(lua_context, value);
        try lua_context.wrapper.setGlobal(name);
    }
    
    fn getGlobal(context: *ScriptContext, name: []const u8) anyerror!ScriptValue {
        const lua_context = getLuaContext(context) orelse return LuaEngineError.ContextNotFound;
        
        try lua_context.wrapper.getGlobal(name);
        defer lua_context.wrapper.pop(1);
        
        return try luaValueToScriptValue(lua_context, -1);
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
        if (lua.lua_enabled) {
            _ = lua.c.lua_gc(lua_context.wrapper.state, lua.c.LUA_GCCOLLECT, 0);
        }
    }
    
    fn getMemoryUsage(context: *ScriptContext) usize {
        const lua_context = getLuaContext(context) orelse return 0;
        if (lua.lua_enabled) {
            return @intCast(lua.c.lua_gc(lua_context.wrapper.state, lua.c.LUA_GCCOUNT, 0) * 1024 +
                           lua.c.lua_gc(lua_context.wrapper.state, lua.c.LUA_GCCOUNTB, 0));
        }
        return 0;
    }
    
    // Helper functions
    fn getLuaContext(context: *ScriptContext) ?*LuaContext {
        return @ptrCast(@alignCast(context.engine_context));
    }
    
    fn scriptValueToLuaValue(lua_context: *LuaContext, value: ScriptValue) !void {
        switch (value) {
            .nil => lua_context.wrapper.pushNil(),
            .boolean => |b| lua_context.wrapper.pushBoolean(b),
            .integer => |i| lua_context.wrapper.pushInteger(@intCast(i)),
            .float => |f| lua_context.wrapper.pushNumber(f),
            .string => |s| try lua_context.wrapper.pushString(s),
            .array => |arr| {
                lua_context.wrapper.createTable(@intCast(arr.len), 0);
                for (arr, 1..) |item, i| {
                    try scriptValueToLuaValue(lua_context, item);
                    lua_context.wrapper.pushInteger(@intCast(i));
                    lua_context.wrapper.setTable(-3);
                }
            },
            .object => |obj| {
                lua_context.wrapper.createTable(0, @intCast(obj.count()));
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    try lua_context.wrapper.pushString(entry.key_ptr.*);
                    try scriptValueToLuaValue(lua_context, entry.value_ptr.*);
                    lua_context.wrapper.setTable(-3);
                }
            },
            .function => {
                // TODO: Implement function reference handling
                lua_context.wrapper.pushNil();
            },
            .userdata => {
                // TODO: Implement userdata handling
                lua_context.wrapper.pushNil();
            },
        }
    }
    
    fn luaValueToScriptValue(lua_context: *LuaContext, index: i32) !ScriptValue {
        const lua_type = lua_context.wrapper.getType(index);
        
        return switch (lua_type) {
            lua.LUA_TNIL => ScriptValue.nil,
            lua.LUA_TBOOLEAN => ScriptValue{ .boolean = lua_context.wrapper.toBoolean(index) },
            lua.LUA_TNUMBER => blk: {
                if (lua_context.wrapper.toInteger(index)) |int_val| {
                    break :blk ScriptValue{ .integer = @intCast(int_val) };
                } else if (lua_context.wrapper.toNumber(index)) |num_val| {
                    break :blk ScriptValue{ .float = num_val };
                } else {
                    break :blk ScriptValue.nil;
                }
            },
            lua.LUA_TSTRING => blk: {
                const str = try lua_context.wrapper.toString(index);
                const str_copy = try lua_context.allocator.dupe(u8, str);
                break :blk ScriptValue{ .string = str_copy };
            },
            lua.LUA_TTABLE => {
                // TODO: Implement table to array/object conversion
                // For now, return nil
                return ScriptValue.nil;
            },
            lua.LUA_TFUNCTION => {
                // TODO: Implement function reference
                return ScriptValue.nil;
            },
            else => ScriptValue.nil,
        };
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