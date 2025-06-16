// ABOUTME: Lua C function wrappers for Workflow Bridge API
// ABOUTME: Provides Lua access to workflow creation, execution, and orchestration

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual workflow bridge implementation
const WorkflowBridge = @import("../../api_bridges/workflow_bridge.zig").WorkflowBridge;

// Import zig_llms workflow API
const workflow = @import("../../../workflow.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 12;

/// Workflow bridge errors specific to Lua integration
pub const LuaWorkflowError = error{
    InvalidWorkflow,
    WorkflowNotFound,
    InvalidDefinition,
    ExecutionFailed,
    StepFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all workflow bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "create", .func = luaWorkflowCreate },
        .{ .name = "execute", .func = luaWorkflowExecute },
        .{ .name = "step", .func = luaWorkflowStep },
        .{ .name = "pause", .func = luaWorkflowPause },
        .{ .name = "resume", .func = luaWorkflowResume },
        .{ .name = "cancel", .func = luaWorkflowCancel },
        .{ .name = "get_status", .func = luaWorkflowGetStatus },
        .{ .name = "get_result", .func = luaWorkflowGetResult },
        .{ .name = "list", .func = luaWorkflowList },
        .{ .name = "compose", .func = luaWorkflowCompose },
        .{ .name = "validate", .func = luaWorkflowValidate },
        .{ .name = "get_info", .func = luaWorkflowGetInfo },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} workflow bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up workflow bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // Workflow execution patterns
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "sequential");
    lua.c.lua_setfield(L, -2, "SEQUENTIAL");

    lua.c.lua_pushstring(L, "parallel");
    lua.c.lua_setfield(L, -2, "PARALLEL");

    lua.c.lua_pushstring(L, "conditional");
    lua.c.lua_setfield(L, -2, "CONDITIONAL");

    lua.c.lua_pushstring(L, "loop");
    lua.c.lua_setfield(L, -2, "LOOP");

    lua.c.lua_setfield(L, -2, "Pattern");

    // Workflow states
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "created");
    lua.c.lua_setfield(L, -2, "CREATED");

    lua.c.lua_pushstring(L, "running");
    lua.c.lua_setfield(L, -2, "RUNNING");

    lua.c.lua_pushstring(L, "paused");
    lua.c.lua_setfield(L, -2, "PAUSED");

    lua.c.lua_pushstring(L, "completed");
    lua.c.lua_setfield(L, -2, "COMPLETED");

    lua.c.lua_pushstring(L, "failed");
    lua.c.lua_setfield(L, -2, "FAILED");

    lua.c.lua_pushstring(L, "cancelled");
    lua.c.lua_setfield(L, -2, "CANCELLED");

    lua.c.lua_setfield(L, -2, "State");
}

// Lua C Function Implementations

/// zigllms.workflow.create(definition) -> workflow_id
/// Create a new workflow with the given definition
export fn luaWorkflowCreate(L: ?*lua.c.lua_State) c_int {
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

    const result = WorkflowBridge.createWorkflow(context, &[_]ScriptValue{definition_value}) catch |err| {
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

/// zigllms.workflow.execute(workflow_id, input?, options?) -> result
/// Execute a workflow with optional input and configuration
export fn luaWorkflowExecute(L: ?*lua.c.lua_State) c_int {
    const start_time = std.time.nanoTimestamp();

    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    const arg_count = lua.c.lua_gettop(L);
    if (arg_count < 1 or arg_count > 3) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    try args.append(workflow_id_value);

    if (arg_count >= 2) {
        const input_value = LuaValueConverter.pullScriptValue(context.allocator, L, 2) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(input_value);
    }

    if (arg_count == 3) {
        const options_value = LuaValueConverter.pullScriptValue(context.allocator, L, 3) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(options_value);
    }

    const result = WorkflowBridge.executeWorkflow(context, args.items) catch |err| {
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

/// zigllms.workflow.step(workflow_id) -> step_result
/// Execute the next step in a workflow
export fn luaWorkflowStep(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.stepWorkflow(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.pause(workflow_id) -> success
/// Pause a running workflow
export fn luaWorkflowPause(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.pauseWorkflow(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.resume(workflow_id) -> success
/// Resume a paused workflow
export fn luaWorkflowResume(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.resumeWorkflow(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.cancel(workflow_id) -> success
/// Cancel a workflow execution
export fn luaWorkflowCancel(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.cancelWorkflow(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.get_status(workflow_id) -> status_info
/// Get current status of a workflow
export fn luaWorkflowGetStatus(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.getWorkflowStatus(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.get_result(workflow_id) -> result
/// Get result of a completed workflow
export fn luaWorkflowGetResult(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.getWorkflowResult(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.list() -> workflow_list
/// List all workflows
export fn luaWorkflowList(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 0) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const result = WorkflowBridge.listWorkflows(context, &[_]ScriptValue{}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.compose(workflows, composition_type) -> composed_workflow_id
/// Compose multiple workflows into a new workflow
export fn luaWorkflowCompose(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 2) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflows_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflows_value.deinit(context.allocator);

    const composition_type_value = LuaValueConverter.pullScriptValue(context.allocator, L, 2) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer composition_type_value.deinit(context.allocator);

    const result = WorkflowBridge.composeWorkflows(context, &[_]ScriptValue{ workflows_value, composition_type_value }) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.validate(definition) -> validation_result
/// Validate a workflow definition
export fn luaWorkflowValidate(L: ?*lua.c.lua_State) c_int {
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

    const result = WorkflowBridge.validateWorkflow(context, &[_]ScriptValue{definition_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.workflow.get_info(workflow_id) -> workflow_info
/// Get detailed information about a workflow
export fn luaWorkflowGetInfo(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    if (lua.c.lua_gettop(L) != 1) {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.InvalidArguments);
    }

    const workflow_id_value = LuaValueConverter.pullScriptValue(context.allocator, L, 1) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer workflow_id_value.deinit(context.allocator);

    const result = WorkflowBridge.getWorkflowInfo(context, &[_]ScriptValue{workflow_id_value}) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
