// ABOUTME: Lua C function wrappers for Test Bridge API
// ABOUTME: Provides Lua access to Testing and mocking framework

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual test bridge implementation
const TestBridge = @import("../../api_bridges/test_bridge.zig").TestBridge;

// Import zig_llms test API
const test_api = @import("../../../test.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 8;

/// Test bridge errors specific to Lua integration
pub const LuaTestError = error{
    InvalidTest,
    TestNotFound,
    InvalidDefinition,
    ExecutionFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all test bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "create_scenario", .func = luaTestCreateScenario },
        .{ .name = "run_scenario", .func = luaTestRunScenario },
        .{ .name = "assert_equals", .func = luaTestAssertEquals },
        .{ .name = "assert_contains", .func = luaTestAssertContains },
        .{ .name = "create_mock", .func = luaTestCreateMock },
        .{ .name = "setup_fixture", .func = luaTestSetupFixture },
        .{ .name = "run_suite", .func = luaTestRunSuite },
        .{ .name = "get_coverage", .func = luaTestGetCoverage },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} test bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up test bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // AssertType constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "equals");
    lua.c.lua_setfield(L, -2, "EQUALS");
    lua.c.lua_pushstring(L, "contains");
    lua.c.lua_setfield(L, -2, "CONTAINS");
    lua.c.lua_pushstring(L, "matches");
    lua.c.lua_setfield(L, -2, "MATCHES");
    lua.c.lua_pushstring(L, "throws");
    lua.c.lua_setfield(L, -2, "THROWS");

    lua.c.lua_setfield(L, -2, "AssertType");

    // MockType constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "function");
    lua.c.lua_setfield(L, -2, "FUNCTION");
    lua.c.lua_pushstring(L, "object");
    lua.c.lua_setfield(L, -2, "OBJECT");
    lua.c.lua_pushstring(L, "service");
    lua.c.lua_setfield(L, -2, "SERVICE");

    lua.c.lua_setfield(L, -2, "MockType");
}

// Lua C Function Implementations

/// zigllms.test.create_scenario(definition) -> scenario_id
export fn luaTestCreateScenario(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.createscenario(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.run_scenario(scenario_id, options?) -> result
export fn luaTestRunScenario(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.runscenario(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.assert_equals(actual, expected, message?) -> success
export fn luaTestAssertEquals(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.assertequals(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.assert_contains(haystack, needle, message?) -> success
export fn luaTestAssertContains(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.assertcontains(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.create_mock(definition) -> mock_id
export fn luaTestCreateMock(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.createmock(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.setup_fixture(fixture_data) -> fixture_id
export fn luaTestSetupFixture(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.setupfixture(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.run_suite(suite_definition) -> suite_result
export fn luaTestRunSuite(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.runsuite(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.test.get_coverage() -> coverage_report
export fn luaTestGetCoverage(L: ?*lua.c.lua_State) c_int {
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
    const result = TestBridge.getcoverage(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
