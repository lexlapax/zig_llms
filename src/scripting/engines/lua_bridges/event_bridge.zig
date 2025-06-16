// ABOUTME: Lua C function wrappers for Event Bridge API
// ABOUTME: Provides Lua access to Event emission and subscription

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual event bridge implementation
const EventBridge = @import("../../api_bridges/event_bridge.zig").EventBridge;

// Import zig_llms event API
const event = @import("../../../event.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 8;

/// Event bridge errors specific to Lua integration
pub const LuaEventError = error{
    InvalidEvent,
    EventNotFound,
    InvalidDefinition,
    ExecutionFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all event bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "emit", .func = luaEventEmit },
        .{ .name = "subscribe", .func = luaEventSubscribe },
        .{ .name = "unsubscribe", .func = luaEventUnsubscribe },
        .{ .name = "list_subscriptions", .func = luaEventListSubscriptions },
        .{ .name = "filter", .func = luaEventFilter },
        .{ .name = "record", .func = luaEventRecord },
        .{ .name = "replay", .func = luaEventReplay },
        .{ .name = "clear", .func = luaEventClear },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} event bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up event bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // Type constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "system");
    lua.c.lua_setfield(L, -2, "SYSTEM");
    lua.c.lua_pushstring(L, "user");
    lua.c.lua_setfield(L, -2, "USER");
    lua.c.lua_pushstring(L, "agent");
    lua.c.lua_setfield(L, -2, "AGENT");
    lua.c.lua_pushstring(L, "tool");
    lua.c.lua_setfield(L, -2, "TOOL");
    lua.c.lua_pushstring(L, "workflow");
    lua.c.lua_setfield(L, -2, "WORKFLOW");

    lua.c.lua_setfield(L, -2, "Type");

    // Priority constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "low");
    lua.c.lua_setfield(L, -2, "LOW");
    lua.c.lua_pushstring(L, "normal");
    lua.c.lua_setfield(L, -2, "NORMAL");
    lua.c.lua_pushstring(L, "high");
    lua.c.lua_setfield(L, -2, "HIGH");
    lua.c.lua_pushstring(L, "critical");
    lua.c.lua_setfield(L, -2, "CRITICAL");

    lua.c.lua_setfield(L, -2, "Priority");
}

// Lua C Function Implementations

/// zigllms.event.emit(event_name, data) -> success
export fn luaEventEmit(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.emit(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.subscribe(event_name, callback) -> subscription_id
export fn luaEventSubscribe(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.subscribe(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.unsubscribe(subscription_id) -> success
export fn luaEventUnsubscribe(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.unsubscribe(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.list_subscriptions() -> subscription_list
export fn luaEventListSubscriptions(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.listsubscriptions(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.filter(pattern, callback) -> filter_id
export fn luaEventFilter(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.filter(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.record(event_name, duration?) -> recorder_id
export fn luaEventRecord(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.record(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.replay(recorder_id, options?) -> success
export fn luaEventReplay(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.replay(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.event.clear(event_name?) -> success
export fn luaEventClear(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = EventBridge.clear(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
