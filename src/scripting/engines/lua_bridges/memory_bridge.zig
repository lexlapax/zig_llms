// ABOUTME: Lua C function wrappers for Memory Bridge API
// ABOUTME: Provides Lua access to Memory management and conversation history

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual memory bridge implementation
const MemoryBridge = @import("../../api_bridges/memory_bridge.zig").MemoryBridge;

// Import zig_llms memory API
const memory = @import("../../../memory.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 8;

/// Memory bridge errors specific to Lua integration
pub const LuaMemoryError = error{
    InvalidMemory,
    MemoryNotFound,
    InvalidDefinition,
    ExecutionFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all memory bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "store", .func = luaMemoryStore },
        .{ .name = "retrieve", .func = luaMemoryRetrieve },
        .{ .name = "delete", .func = luaMemoryDelete },
        .{ .name = "list_keys", .func = luaMemoryListKeys },
        .{ .name = "clear", .func = luaMemoryClear },
        .{ .name = "get_stats", .func = luaMemoryGetStats },
        .{ .name = "persist", .func = luaMemoryPersist },
        .{ .name = "load", .func = luaMemoryLoad },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} memory bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up memory bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // Type constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "short_term");
    lua.c.lua_setfield(L, -2, "SHORT_TERM");
    lua.c.lua_pushstring(L, "long_term");
    lua.c.lua_setfield(L, -2, "LONG_TERM");
    lua.c.lua_pushstring(L, "persistent");
    lua.c.lua_setfield(L, -2, "PERSISTENT");

    lua.c.lua_setfield(L, -2, "Type");

    // Scope constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "global");
    lua.c.lua_setfield(L, -2, "GLOBAL");
    lua.c.lua_pushstring(L, "agent");
    lua.c.lua_setfield(L, -2, "AGENT");
    lua.c.lua_pushstring(L, "session");
    lua.c.lua_setfield(L, -2, "SESSION");

    lua.c.lua_setfield(L, -2, "Scope");
}

// Lua C Function Implementations

/// zigllms.memory.store(key, value, options?) -> success
export fn luaMemoryStore(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.store(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.retrieve(key) -> value
export fn luaMemoryRetrieve(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.retrieve(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.delete(key) -> success
export fn luaMemoryDelete(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.delete(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.list_keys(pattern?) -> key_list
export fn luaMemoryListKeys(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.listkeys(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.clear() -> success
export fn luaMemoryClear(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.clear(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.get_stats() -> memory_stats
export fn luaMemoryGetStats(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.getstats(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.persist(path) -> success
export fn luaMemoryPersist(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.persist(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.memory.load(path) -> success
export fn luaMemoryLoad(L: ?*lua.c.lua_State) c_int {
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
    const result = MemoryBridge.load(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
