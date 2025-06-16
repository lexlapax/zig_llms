// ABOUTME: Lua C function wrappers for Tool Bridge API
// ABOUTME: Provides Lua access to tool registration, execution, and discovery

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual tool bridge implementation
const ToolBridge = @import("../../api_bridges/tool_bridge.zig").ToolBridge;

// Import zig_llms tool API
const tool = @import("../../../tool.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 10;

/// Tool bridge errors specific to Lua integration
pub const LuaToolError = error{
    InvalidTool,
    ToolNotFound,
    InvalidDefinition,
    ExecutionFailed,
    DiscoveryFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all tool bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "register", .func = luaToolRegister },
        .{ .name = "unregister", .func = luaToolUnregister },
        .{ .name = "execute", .func = luaToolExecute },
        .{ .name = "discover", .func = luaToolDiscover },
        .{ .name = "list", .func = luaToolList },
        .{ .name = "get", .func = luaToolGet },
        .{ .name = "exists", .func = luaToolExists },
        .{ .name = "validate", .func = luaToolValidate },
        .{ .name = "get_schema", .func = luaToolGetSchema },
        .{ .name = "get_info", .func = luaToolGetInfo },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} tool bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up tool bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // Tool execution modes
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "direct");
    lua.c.lua_setfield(L, -2, "DIRECT");

    lua.c.lua_pushstring(L, "sandboxed");
    lua.c.lua_setfield(L, -2, "SANDBOXED");

    lua.c.lua_pushstring(L, "async");
    lua.c.lua_setfield(L, -2, "ASYNC");

    lua.c.lua_setfield(L, -2, "ExecutionMode");

    // Tool categories
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "file");
    lua.c.lua_setfield(L, -2, "FILE");

    lua.c.lua_pushstring(L, "http");
    lua.c.lua_setfield(L, -2, "HTTP");

    lua.c.lua_pushstring(L, "system");
    lua.c.lua_setfield(L, -2, "SYSTEM");

    lua.c.lua_pushstring(L, "data");
    lua.c.lua_setfield(L, -2, "DATA");

    lua.c.lua_setfield(L, -2, "Category");
}

// Lua C Function Implementations

/// zigllms.tool.register(definition) -> tool_id
/// Register a new tool with the given definition
export fn luaToolRegister(L: ?*lua.c.lua_State) c_int {
    const start_time = std.time.nanoTimestamp();

    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1 or !lua.c.lua_istable(L, 1)) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const definition_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer definition_value.deinit(context.allocator);

    const result = ToolBridge.registerTool(context, &[_]ScriptValue{definition_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    const execution_time = std.time.nanoTimestamp() - start_time;
    _ = execution_time; // TODO: Record metrics

    return 1;
}

/// zigllms.tool.unregister(tool_id) -> success
/// Unregister a tool by ID
export fn luaToolUnregister(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const tool_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer tool_id_value.deinit(context.allocator);

    const result = ToolBridge.unregisterTool(context, &[_]ScriptValue{tool_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.execute(tool_id, input, options?) -> result
/// Execute a tool with the given input and optional configuration
export fn luaToolExecute(L: ?*lua.c.lua_State) c_int {
    const start_time = std.time.nanoTimestamp();

    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    const arg_count = lua.c.lua_gettop(L);
    if (arg_count < 2 or arg_count > 3) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const tool_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer tool_id_value.deinit(context.allocator);

    const input_value = LuaValueConverter.pullScriptValue(context.allocator, L, 2) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer input_value.deinit(context.allocator);

    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    try args.append(tool_id_value);
    try args.append(input_value);

    if (arg_count == 3) {
        const options_value = LuaValueConverter.pullScriptValue(context.allocator, L, 3) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(options_value);
    }

    const result = ToolBridge.executeTool(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    const execution_time = std.time.nanoTimestamp() - start_time;
    _ = execution_time; // TODO: Record metrics

    return 1;
}

/// zigllms.tool.discover(category?) -> tool_list
/// Discover available tools, optionally filtered by category
export fn luaToolDiscover(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    const arg_count = lua.c.lua_gettop(L);
    if (arg_count > 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    if (arg_count == 1) {
        const category_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(category_value);
    }

    const result = ToolBridge.discoverTools(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.list() -> tool_list
/// List all registered tools
export fn luaToolList(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 0) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const result = ToolBridge.listTools(context, &[_]ScriptValue{}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.get(tool_id) -> tool_definition
/// Get tool definition by ID
export fn luaToolGet(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const tool_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer tool_id_value.deinit(context.allocator);

    const result = ToolBridge.getTool(context, &[_]ScriptValue{tool_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.exists(tool_id) -> boolean
/// Check if a tool exists
export fn luaToolExists(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const tool_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer tool_id_value.deinit(context.allocator);

    const result = ToolBridge.toolExists(context, &[_]ScriptValue{tool_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.validate(definition) -> validation_result
/// Validate a tool definition
export fn luaToolValidate(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const definition_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer definition_value.deinit(context.allocator);

    const result = ToolBridge.validateTool(context, &[_]ScriptValue{definition_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.get_schema(tool_id) -> schema
/// Get input/output schema for a tool
export fn luaToolGetSchema(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const tool_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer tool_id_value.deinit(context.allocator);

    const result = ToolBridge.getToolSchema(context, &[_]ScriptValue{tool_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.tool.get_info(tool_id) -> tool_info
/// Get detailed information about a tool
export fn luaToolGetInfo(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const tool_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer tool_id_value.deinit(context.allocator);

    const result = ToolBridge.getToolInfo(context, &[_]ScriptValue{tool_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
