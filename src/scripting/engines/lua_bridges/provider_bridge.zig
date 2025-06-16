// ABOUTME: Lua C function wrappers for Provider Bridge API
// ABOUTME: Provides Lua access to LLM provider access and configuration

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual provider bridge implementation
const ProviderBridge = @import("../../api_bridges/provider_bridge.zig").ProviderBridge;

// Import zig_llms provider API
const provider = @import("../../../provider.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 8;

/// Provider bridge errors specific to Lua integration
pub const LuaProviderError = error{
    InvalidProvider,
    ProviderNotFound,
    InvalidDefinition,
    ExecutionFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all provider bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "chat", .func = luaProviderChat },
        .{ .name = "configure", .func = luaProviderConfigure },
        .{ .name = "list", .func = luaProviderList },
        .{ .name = "get", .func = luaProviderGet },
        .{ .name = "create", .func = luaProviderCreate },
        .{ .name = "destroy", .func = luaProviderDestroy },
        .{ .name = "stream", .func = luaProviderStream },
        .{ .name = "get_models", .func = luaProviderGetModels },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} provider bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up provider bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // Type constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "openai");
    lua.c.lua_setfield(L, -2, "OPENAI");
    lua.c.lua_pushstring(L, "anthropic");
    lua.c.lua_setfield(L, -2, "ANTHROPIC");
    lua.c.lua_pushstring(L, "cohere");
    lua.c.lua_setfield(L, -2, "COHERE");
    lua.c.lua_pushstring(L, "local");
    lua.c.lua_setfield(L, -2, "LOCAL");

    lua.c.lua_setfield(L, -2, "Type");

    // Status constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "active");
    lua.c.lua_setfield(L, -2, "ACTIVE");
    lua.c.lua_pushstring(L, "inactive");
    lua.c.lua_setfield(L, -2, "INACTIVE");
    lua.c.lua_pushstring(L, "error");
    lua.c.lua_setfield(L, -2, "ERROR");
    lua.c.lua_pushstring(L, "initializing");
    lua.c.lua_setfield(L, -2, "INITIALIZING");

    lua.c.lua_setfield(L, -2, "Status");
}

// Lua C Function Implementations

/// zigllms.provider.chat(messages, options?) -> response
export fn luaProviderChat(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.chat(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.configure(provider_id, config) -> success
export fn luaProviderConfigure(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.configure(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.list() -> provider_list
export fn luaProviderList(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.list(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.get(provider_id) -> provider_info
export fn luaProviderGet(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.get(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.create(config) -> provider_id
export fn luaProviderCreate(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.create(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.destroy(provider_id) -> success
export fn luaProviderDestroy(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.destroy(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.stream(messages, callback, options?) -> stream_id
export fn luaProviderStream(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.stream(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.provider.get_models(provider_id) -> model_list
export fn luaProviderGetModels(L: ?*lua.c.lua_State) c_int {
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
    const result = ProviderBridge.getmodels(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
