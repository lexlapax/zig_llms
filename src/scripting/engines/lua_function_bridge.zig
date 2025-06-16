// ABOUTME: Lua function reference system for bidirectional function calls
// ABOUTME: Handles ScriptFunction creation, storage, and execution between Lua and Zig

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptFunction = @import("../interface.zig").ScriptFunction;
const ScriptContext = @import("../context.zig").ScriptContext;
const pushScriptValue = @import("lua_value_converter.zig").pushScriptValue;
const pullScriptValue = @import("lua_value_converter.zig").pullScriptValue;

/// Function reference errors
pub const FunctionError = error{
    InvalidFunction,
    FunctionNotFound,
    ArgumentMismatch,
    ReturnValueError,
    CallError,
    RegistryFull,
    InvalidContext,
    LuaNotEnabled,
};

/// Lua function reference that can be called from Zig
pub const LuaFunctionRef = struct {
    registry_key: c_int,
    context: *ScriptContext,
    wrapper: *LuaWrapper,
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    arity: ?u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *ScriptContext,
        wrapper: *LuaWrapper,
        lua_index: c_int,
    ) !*LuaFunctionRef {
        if (!lua.lua_enabled) return FunctionError.LuaNotEnabled;

        // Verify it's a function
        if (lua.c.lua_type(wrapper.state, lua_index) != lua.c.LUA_TFUNCTION) {
            return FunctionError.InvalidFunction;
        }

        const self = try allocator.create(LuaFunctionRef);
        errdefer allocator.destroy(self);

        // Store function in Lua registry
        lua.c.lua_pushvalue(wrapper.state, lua_index);
        const registry_key = lua.c.luaL_ref(wrapper.state, lua.c.LUA_REGISTRYINDEX);

        if (registry_key == lua.c.LUA_REFNIL) {
            return FunctionError.RegistryFull;
        }

        self.* = LuaFunctionRef{
            .registry_key = registry_key,
            .context = context,
            .wrapper = wrapper,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *LuaFunctionRef) void {
        if (lua.lua_enabled) {
            // Release reference from Lua registry
            lua.c.luaL_unref(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, self.registry_key);
        }

        if (self.name) |name| {
            self.allocator.free(name);
        }

        self.allocator.destroy(self);
    }

    pub fn setName(self: *LuaFunctionRef, name: []const u8) !void {
        if (self.name) |old_name| {
            self.allocator.free(old_name);
        }
        self.name = try self.allocator.dupe(u8, name);
    }

    pub fn call(self: *LuaFunctionRef, args: []const ScriptValue) !ScriptValue {
        if (!lua.lua_enabled) return FunctionError.LuaNotEnabled;

        // Get function from registry
        lua.c.lua_rawgeti(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, self.registry_key);

        // Verify it's still a function
        if (lua.c.lua_type(self.wrapper.state, -1) != lua.c.LUA_TFUNCTION) {
            lua.c.lua_pop(self.wrapper.state, 1);
            return FunctionError.InvalidFunction;
        }

        // Push arguments
        for (args) |arg| {
            try pushScriptValue(self.wrapper, arg);
        }

        // Call function
        const result = lua.c.lua_pcall(self.wrapper.state, @intCast(args.len), 1, // One return value
            0 // No error handler
        );

        if (result != lua.c.LUA_OK) {
            // Get error message
            const error_msg = lua.c.lua_tostring(self.wrapper.state, -1);
            if (error_msg) |msg| {
                std.log.err("Lua function call failed: {s}", .{std.mem.span(msg)});
            }
            lua.c.lua_pop(self.wrapper.state, 1);
            return FunctionError.CallError;
        }

        // Get return value
        const return_value = try pullScriptValue(self.wrapper, -1, self.allocator);
        lua.c.lua_pop(self.wrapper.state, 1);

        return return_value;
    }

    pub fn getInfo(self: *LuaFunctionRef) FunctionInfo {
        var info = FunctionInfo{
            .name = self.name,
            .arity = self.arity,
            .is_lua_function = true,
            .is_c_function = false,
        };

        if (!lua.lua_enabled) return info;

        // Get function from registry to inspect it
        lua.c.lua_rawgeti(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, self.registry_key);
        defer lua.c.lua_pop(self.wrapper.state, 1);

        if (lua.c.lua_type(self.wrapper.state, -1) == lua.c.LUA_TFUNCTION) {
            info.is_c_function = lua.c.lua_iscfunction(self.wrapper.state, -1) != 0;
            info.is_lua_function = !info.is_c_function;
        }

        return info;
    }
};

/// Zig function reference that can be called from Lua
pub const ZigFunctionRef = struct {
    callback: *const fn (context: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue,
    context: *ScriptContext,
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    arity: ?u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        context: *ScriptContext,
        callback: *const fn (context: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue,
    ) !*ZigFunctionRef {
        const self = try allocator.create(ZigFunctionRef);
        self.* = ZigFunctionRef{
            .callback = callback,
            .context = context,
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *ZigFunctionRef) void {
        if (self.name) |name| {
            self.allocator.free(name);
        }
        self.allocator.destroy(self);
    }

    pub fn setName(self: *ZigFunctionRef, name: []const u8) !void {
        if (self.name) |old_name| {
            self.allocator.free(old_name);
        }
        self.name = try self.allocator.dupe(u8, name);
    }

    pub fn call(self: *ZigFunctionRef, args: []const ScriptValue) !ScriptValue {
        return try self.callback(self.context, args);
    }
};

/// Function information structure
pub const FunctionInfo = struct {
    name: ?[]const u8 = null,
    arity: ?u8 = null,
    is_lua_function: bool = false,
    is_c_function: bool = false,
};

/// C function trampoline for calling Zig functions from Lua
fn zigFunctionTrampoline(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    // Get ZigFunctionRef from upvalue
    const func_ref: *ZigFunctionRef = @ptrCast(@alignCast(lua.c.lua_touserdata(state, lua.c.lua_upvalueindex(1))));

    // Convert arguments
    const argc = lua.c.lua_gettop(state);
    var args = std.ArrayList(ScriptValue).init(func_ref.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(func_ref.allocator);
        }
        args.deinit();
    }

    // Convert Lua arguments to ScriptValues
    var i: c_int = 1;
    while (i <= argc) : (i += 1) {
        const value = pullScriptValue(&LuaWrapper{ .state = state, .allocator = func_ref.allocator }, i, func_ref.allocator) catch {
            lua.c.lua_pushstring(state, "Failed to convert argument");
            return lua.c.lua_error(state);
        };
        args.append(value) catch {
            lua.c.lua_pushstring(state, "Out of memory");
            return lua.c.lua_error(state);
        };
    }

    // Call the Zig function
    const result = func_ref.call(args.items) catch |err| {
        const error_msg = std.fmt.allocPrint(func_ref.allocator, "Zig function error: {}", .{err}) catch "Unknown error";
        defer func_ref.allocator.free(error_msg);

        lua.c.lua_pushstring(state, error_msg.ptr);
        return lua.c.lua_error(state);
    };
    defer result.deinit(func_ref.allocator);

    // Convert result back to Lua
    const wrapper = LuaWrapper{ .state = state, .allocator = func_ref.allocator };
    pushScriptValue(&wrapper, result) catch {
        lua.c.lua_pushstring(state, "Failed to convert return value");
        return lua.c.lua_error(state);
    };

    return 1; // One return value
}

/// Function bridge manager
pub const LuaFunctionBridge = struct {
    allocator: std.mem.Allocator,
    context: *ScriptContext,
    wrapper: *LuaWrapper,
    lua_functions: std.HashMap(c_int, *LuaFunctionRef, std.hash_map.DefaultContext(c_int), std.hash_map.default_max_load_percentage),
    zig_functions: std.HashMap(usize, *ZigFunctionRef, std.hash_map.DefaultContext(usize), std.hash_map.default_max_load_percentage),

    pub fn init(
        allocator: std.mem.Allocator,
        context: *ScriptContext,
        wrapper: *LuaWrapper,
    ) LuaFunctionBridge {
        return LuaFunctionBridge{
            .allocator = allocator,
            .context = context,
            .wrapper = wrapper,
            .lua_functions = std.HashMap(c_int, *LuaFunctionRef, std.hash_map.DefaultContext(c_int), std.hash_map.default_max_load_percentage).init(allocator),
            .zig_functions = std.HashMap(usize, *ZigFunctionRef, std.hash_map.DefaultContext(usize), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *LuaFunctionBridge) void {
        // Clean up Lua function references
        var lua_iter = self.lua_functions.iterator();
        while (lua_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.lua_functions.deinit();

        // Clean up Zig function references
        var zig_iter = self.zig_functions.iterator();
        while (zig_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.zig_functions.deinit();
    }

    /// Create a ScriptFunction from a Lua function at the given stack index
    pub fn createScriptFunction(self: *LuaFunctionBridge, lua_index: c_int) !*ScriptFunction {
        const lua_func_ref = try LuaFunctionRef.init(
            self.allocator,
            self.context,
            self.wrapper,
            lua_index,
        );
        errdefer lua_func_ref.deinit();

        try self.lua_functions.put(lua_func_ref.registry_key, lua_func_ref);

        const script_func = try self.allocator.create(ScriptFunction);
        script_func.* = ScriptFunction{
            .context = self.context,
            .engine_ref = lua_func_ref,
        };

        return script_func;
    }

    /// Register a Zig function to be callable from Lua
    pub fn registerZigFunction(
        self: *LuaFunctionBridge,
        name: []const u8,
        callback: *const fn (context: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue,
        arity: ?u8,
    ) !void {
        if (!lua.lua_enabled) return FunctionError.LuaNotEnabled;

        const zig_func_ref = try ZigFunctionRef.init(self.allocator, self.context, callback);
        errdefer zig_func_ref.deinit();

        try zig_func_ref.setName(name);
        zig_func_ref.arity = arity;

        const func_id = @intFromPtr(zig_func_ref);
        try self.zig_functions.put(func_id, zig_func_ref);

        // Create light userdata for the function reference
        lua.c.lua_pushlightuserdata(self.wrapper.state, zig_func_ref);

        // Create C closure
        lua.c.lua_pushcclosure(self.wrapper.state, zigFunctionTrampoline, 1);

        // Set as global function
        lua.c.lua_setglobal(self.wrapper.state, name.ptr);
    }

    /// Call a Lua function by registry key
    pub fn callLuaFunction(
        self: *LuaFunctionBridge,
        registry_key: c_int,
        args: []const ScriptValue,
    ) !ScriptValue {
        const lua_func_ref = self.lua_functions.get(registry_key) orelse {
            return FunctionError.FunctionNotFound;
        };

        return try lua_func_ref.call(args);
    }

    /// Get function info by registry key
    pub fn getFunctionInfo(self: *LuaFunctionBridge, registry_key: c_int) ?FunctionInfo {
        const lua_func_ref = self.lua_functions.get(registry_key) orelse return null;
        return lua_func_ref.getInfo();
    }

    /// Release a ScriptFunction
    pub fn releaseScriptFunction(self: *LuaFunctionBridge, script_func: *ScriptFunction) void {
        const lua_func_ref: *LuaFunctionRef = @ptrCast(@alignCast(script_func.engine_ref));

        // Remove from map
        _ = self.lua_functions.remove(lua_func_ref.registry_key);

        // Clean up
        lua_func_ref.deinit();
        self.allocator.destroy(script_func);
    }
};

/// Create a ScriptFunction from Lua function at stack index
pub fn createScriptFunctionFromLua(
    allocator: std.mem.Allocator,
    context: *ScriptContext,
    wrapper: *LuaWrapper,
    lua_index: c_int,
) !*ScriptFunction {
    const lua_func_ref = try LuaFunctionRef.init(allocator, context, wrapper, lua_index);
    errdefer lua_func_ref.deinit();

    const script_func = try allocator.create(ScriptFunction);
    script_func.* = ScriptFunction{
        .context = context,
        .engine_ref = lua_func_ref,
    };

    return script_func;
}

/// Execute a ScriptFunction (called by ScriptFunction.call)
pub fn executeScriptFunction(script_func: *ScriptFunction, args: []const ScriptValue) !ScriptValue {
    const lua_func_ref: *LuaFunctionRef = @ptrCast(@alignCast(script_func.engine_ref));
    return try lua_func_ref.call(args);
}

/// Release a ScriptFunction (called by ScriptFunction.deinit)
pub fn releaseScriptFunction(script_func: *ScriptFunction) void {
    const lua_func_ref: *LuaFunctionRef = @ptrCast(@alignCast(script_func.engine_ref));
    const allocator = lua_func_ref.allocator;

    lua_func_ref.deinit();
    allocator.destroy(script_func);
}

// Tests
test "LuaFunctionRef creation and calling" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    // Create a mock context (simplified for testing)
    var context = ScriptContext{
        .name = "test",
        .allocator = allocator,
        .engine = undefined,
    };

    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create a simple Lua function
    const lua_code = "return function(x, y) return x + y end";
    _ = lua.c.luaL_loadstring(wrapper.state, lua_code.ptr);
    _ = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    // Create function reference
    var func_ref = try LuaFunctionRef.init(allocator, &context, wrapper, -1);
    defer func_ref.deinit();

    lua.c.lua_pop(wrapper.state, 1);

    // Test function call
    const args = [_]ScriptValue{
        ScriptValue{ .integer = 5 },
        ScriptValue{ .integer = 3 },
    };

    var result = try func_ref.call(&args);
    defer result.deinit(allocator);

    try std.testing.expect(result == .integer);
    try std.testing.expectEqual(@as(i64, 8), result.integer);
}

test "ZigFunctionRef creation and registration" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    // Create a mock context
    var context = ScriptContext{
        .name = "test",
        .allocator = allocator,
        .engine = undefined,
    };

    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var bridge = LuaFunctionBridge.init(allocator, &context, wrapper);
    defer bridge.deinit();

    // Define a test function
    const testFunction = struct {
        fn call(ctx: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue {
            _ = ctx;
            if (args.len == 2 and args[0] == .integer and args[1] == .integer) {
                return ScriptValue{ .integer = args[0].integer * args[1].integer };
            }
            return ScriptValue.nil;
        }
    }.call;

    // Register the function
    try bridge.registerZigFunction("multiply", testFunction, 2);

    // Test calling from Lua
    const lua_code = "return multiply(6, 7)";
    _ = lua.c.luaL_loadstring(wrapper.state, lua_code.ptr);
    const result = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    try std.testing.expectEqual(@as(c_int, lua.c.LUA_OK), result);

    const lua_result = lua.c.lua_tointeger(wrapper.state, -1);
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 42), lua_result);

    lua.c.lua_pop(wrapper.state, 1);
}
