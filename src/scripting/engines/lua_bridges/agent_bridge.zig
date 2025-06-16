// ABOUTME: Lua C function wrappers for Agent Bridge API
// ABOUTME: Provides Lua access to agent creation, management, and execution

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual agent bridge implementation
const AgentBridge = @import("../../api_bridges/agent_bridge.zig").AgentBridge;

// Import zig_llms agent API
const agent = @import("../../../agent.zig");
const types = @import("../../../types.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 8;

/// Agent bridge errors specific to Lua integration
pub const LuaAgentError = error{
    InvalidAgent,
    AgentNotFound,
    InvalidConfiguration,
    ExecutionFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all agent bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    // Store ScriptContext for access by C functions
    LuaAPIBridge.setScriptContext(wrapper.state, context);

    // Presize stack for optimal performance
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    // Register agent functions
    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "create", .func = luaAgentCreate },
        .{ .name = "destroy", .func = luaAgentDestroy },
        .{ .name = "run", .func = luaAgentRun },
        .{ .name = "configure", .func = luaAgentConfigure },
        .{ .name = "get_state", .func = luaAgentGetState },
        .{ .name = "list", .func = luaAgentList },
        .{ .name = "exists", .func = luaAgentExists },
        .{ .name = "get_info", .func = luaAgentGetInfo },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    // Add constants
    addConstants(wrapper.state);

    std.log.debug("Registered {} agent bridge functions", .{functions.len});
}

/// Cleanup agent bridge resources
pub fn cleanup() void {
    // Agent bridge handles its own cleanup through the registry
    std.log.debug("Cleaning up agent bridge resources");
}

/// Add agent-related constants to the module
fn addConstants(L: ?*lua.c.lua_State) void {
    // Agent states
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "idle");
    lua.c.lua_setfield(L, -2, "IDLE");

    lua.c.lua_pushstring(L, "running");
    lua.c.lua_setfield(L, -2, "RUNNING");

    lua.c.lua_pushstring(L, "stopped");
    lua.c.lua_setfield(L, -2, "STOPPED");

    lua.c.lua_pushstring(L, "error");
    lua.c.lua_setfield(L, -2, "ERROR");

    lua.c.lua_setfield(L, -2, "State");

    // Default configurations
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "gpt-4");
    lua.c.lua_setfield(L, -2, "default_model");

    lua.c.lua_pushnumber(L, 0.7);
    lua.c.lua_setfield(L, -2, "default_temperature");

    lua.c.lua_pushinteger(L, 4096);
    lua.c.lua_setfield(L, -2, "default_max_tokens");

    lua.c.lua_setfield(L, -2, "Defaults");
}

// Lua C Function Implementations

/// zigllms.agent.create(config) -> agent_id
/// Create a new agent with the given configuration
export fn luaAgentCreate(L: ?*lua.c.lua_State) c_int {
    const start_time = std.time.nanoTimestamp();

    // Get script context
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Check arguments
    if (lua.c.lua_gettop(L) != 1 or !lua.c.lua_istable(L, 1)) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    // Convert Lua table to ScriptValue
    const config_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer config_value.deinit(context.allocator);

    // Call the agent bridge create function
    const result = AgentBridge.createAgent(context, &[_]ScriptValue{config_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    // Record metrics
    const execution_time = std.time.nanoTimestamp() - start_time;
    // TODO: Access bridge manager for metrics recording

    return 1;
}

/// zigllms.agent.destroy(agent_id) -> success
/// Destroy an agent and free its resources
export fn luaAgentDestroy(L: ?*lua.c.lua_State) c_int {
    const start_time = std.time.nanoTimestamp();

    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const agent_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer agent_id_value.deinit(context.allocator);

    const result = AgentBridge.destroyAgent(context, &[_]ScriptValue{agent_id_value}) catch |err| {
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

/// zigllms.agent.run(agent_id, message, options?) -> response
/// Run an agent with the given message and optional configuration
export fn luaAgentRun(L: ?*lua.c.lua_State) c_int {
    const start_time = std.time.nanoTimestamp();

    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    const arg_count = lua.c.lua_gettop(L);
    if (arg_count < 2 or arg_count > 3) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    // Get arguments
    const agent_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer agent_id_value.deinit(context.allocator);

    const message_value = LuaValueConverter.pullScriptValue(context.allocator, L, 2) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer message_value.deinit(context.allocator);

    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    try args.append(agent_id_value);
    try args.append(message_value);

    // Optional configuration
    if (arg_count == 3) {
        const options_value = LuaValueConverter.pullScriptValue(context.allocator, L, 3) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(options_value);
    }

    // Execute agent
    const result = AgentBridge.runAgent(context, args.items) catch |err| {
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

/// zigllms.agent.configure(agent_id, config) -> success
/// Update agent configuration
export fn luaAgentConfigure(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 2) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const agent_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer agent_id_value.deinit(context.allocator);

    const config_value = LuaValueConverter.pullScriptValue(context.allocator, L, 2) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer config_value.deinit(context.allocator);

    const result = AgentBridge.configureAgent(context, &[_]ScriptValue{ agent_id_value, config_value }) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.agent.get_state(agent_id) -> state_info
/// Get current state information for an agent
export fn luaAgentGetState(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const agent_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer agent_id_value.deinit(context.allocator);

    const result = AgentBridge.getAgentState(context, &[_]ScriptValue{agent_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.agent.list() -> agent_list
/// List all active agents
export fn luaAgentList(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 0) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const result = AgentBridge.listAgents(context, &[_]ScriptValue{}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.agent.exists(agent_id) -> boolean
/// Check if an agent exists
export fn luaAgentExists(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const agent_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer agent_id_value.deinit(context.allocator);

    const result = AgentBridge.agentExists(context, &[_]ScriptValue{agent_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.agent.get_info(agent_id) -> agent_info
/// Get detailed information about an agent
export fn luaAgentGetInfo(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const agent_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer agent_id_value.deinit(context.allocator);

    const result = AgentBridge.getAgentInfo(context, &[_]ScriptValue{agent_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
