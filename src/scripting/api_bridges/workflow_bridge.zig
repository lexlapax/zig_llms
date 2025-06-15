// ABOUTME: Workflow API bridge for exposing workflow functionality to scripts
// ABOUTME: Enables creation and execution of complex multi-step workflows from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms workflow API
const workflow = @import("../../workflow.zig");

/// Script workflow wrapper
const ScriptWorkflow = struct {
    id: []const u8,
    name: []const u8,
    steps: std.ArrayList(WorkflowStep),
    context: *ScriptContext,
    state: WorkflowState,
    
    const WorkflowStep = struct {
        name: []const u8,
        agent: []const u8,
        action: []const u8,
        params: ScriptValue,
        depends_on: []const []const u8,
        retry_policy: ?RetryPolicy = null,
        timeout_ms: ?u32 = null,
        
        const RetryPolicy = struct {
            max_attempts: u32 = 3,
            backoff_ms: u32 = 1000,
            backoff_multiplier: f32 = 2.0,
        };
    };
    
    const WorkflowState = enum {
        created,
        running,
        paused,
        completed,
        failed,
        cancelled,
    };
    
    pub fn deinit(self: *ScriptWorkflow) void {
        const allocator = self.context.allocator;
        allocator.free(self.id);
        allocator.free(self.name);
        
        for (self.steps.items) |*step| {
            allocator.free(step.name);
            allocator.free(step.agent);
            allocator.free(step.action);
            step.params.deinit(allocator);
            for (step.depends_on) |dep| {
                allocator.free(dep);
            }
            allocator.free(step.depends_on);
        }
        self.steps.deinit();
        
        allocator.destroy(self);
    }
};

/// Global workflow registry
var workflow_registry: ?std.StringHashMap(*ScriptWorkflow) = null;
var registry_mutex = std.Thread.Mutex{};
var next_workflow_id: u32 = 1;

/// Workflow Bridge implementation
pub const WorkflowBridge = struct {
    pub const bridge = APIBridge{
        .name = "workflow",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };
    
    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);
        
        module.* = ScriptModule{
            .name = "workflow",
            .functions = &workflow_functions,
            .constants = &workflow_constants,
            .description = "Workflow creation and execution API",
            .version = "1.0.0",
        };
        
        return module;
    }
    
    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;
        
        registry_mutex.lock();
        defer registry_mutex.unlock();
        
        if (workflow_registry == null) {
            workflow_registry = std.StringHashMap(*ScriptWorkflow).init(context.allocator);
        }
    }
    
    fn deinit() void {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        
        if (workflow_registry) |*registry| {
            var iter = registry.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            registry.deinit();
            workflow_registry = null;
        }
    }
};

// Workflow module functions
const workflow_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "create",
        "Create a new workflow",
        1,
        createWorkflow,
    ),
    createModuleFunction(
        "destroy",
        "Destroy a workflow and free resources",
        1,
        destroyWorkflow,
    ),
    createModuleFunction(
        "addStep",
        "Add a step to the workflow",
        2,
        addWorkflowStep,
    ),
    createModuleFunction(
        "removeStep",
        "Remove a step from the workflow",
        2,
        removeWorkflowStep,
    ),
    createModuleFunction(
        "execute",
        "Execute the workflow with input",
        2,
        executeWorkflow,
    ),
    createModuleFunction(
        "executeAsync",
        "Execute workflow asynchronously",
        3,
        executeWorkflowAsync,
    ),
    createModuleFunction(
        "pause",
        "Pause a running workflow",
        1,
        pauseWorkflow,
    ),
    createModuleFunction(
        "resume",
        "Resume a paused workflow",
        1,
        resumeWorkflow,
    ),
    createModuleFunction(
        "cancel",
        "Cancel a running workflow",
        1,
        cancelWorkflow,
    ),
    createModuleFunction(
        "getStatus",
        "Get workflow execution status",
        1,
        getWorkflowStatus,
    ),
    createModuleFunction(
        "getSteps",
        "Get all steps in a workflow",
        1,
        getWorkflowSteps,
    ),
    createModuleFunction(
        "getResults",
        "Get results from completed workflow",
        1,
        getWorkflowResults,
    ),
    createModuleFunction(
        "list",
        "List all workflows",
        0,
        listWorkflows,
    ),
    createModuleFunction(
        "validate",
        "Validate workflow configuration",
        1,
        validateWorkflow,
    ),
    createModuleFunction(
        "visualize",
        "Get workflow visualization data",
        1,
        visualizeWorkflow,
    ),
};

// Workflow module constants
const workflow_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "STATE_CREATED",
        ScriptValue{ .string = "created" },
        "Workflow has been created but not started",
    ),
    createModuleConstant(
        "STATE_RUNNING",
        ScriptValue{ .string = "running" },
        "Workflow is currently executing",
    ),
    createModuleConstant(
        "STATE_PAUSED",
        ScriptValue{ .string = "paused" },
        "Workflow execution is paused",
    ),
    createModuleConstant(
        "STATE_COMPLETED",
        ScriptValue{ .string = "completed" },
        "Workflow has completed successfully",
    ),
    createModuleConstant(
        "STATE_FAILED",
        ScriptValue{ .string = "failed" },
        "Workflow execution failed",
    ),
    createModuleConstant(
        "STATE_CANCELLED",
        ScriptValue{ .string = "cancelled" },
        "Workflow was cancelled",
    ),
};

// Implementation functions

fn createWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const name = args[0].string;
    const context = @fieldParentPtr(ScriptContext, "allocator", args[0].string);
    const allocator = context.allocator;
    
    // Generate unique ID
    registry_mutex.lock();
    const workflow_id = try std.fmt.allocPrint(allocator, "workflow_{}", .{next_workflow_id});
    next_workflow_id += 1;
    registry_mutex.unlock();
    
    // Create workflow
    const script_workflow = try allocator.create(ScriptWorkflow);
    script_workflow.* = ScriptWorkflow{
        .id = workflow_id,
        .name = try allocator.dupe(u8, name),
        .steps = std.ArrayList(ScriptWorkflow.WorkflowStep).init(allocator),
        .context = context,
        .state = .created,
    };
    
    // Register workflow
    registry_mutex.lock();
    defer registry_mutex.unlock();
    
    if (workflow_registry) |*registry| {
        try registry.put(workflow_id, script_workflow);
    }
    
    return ScriptValue{ .string = workflow_id };
}

fn destroyWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    defer registry_mutex.unlock();
    
    if (workflow_registry) |*registry| {
        if (registry.fetchRemove(workflow_id)) |kv| {
            kv.value.deinit();
            return ScriptValue{ .boolean = true };
        }
    }
    
    return ScriptValue{ .boolean = false };
}

fn addWorkflowStep(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    const step_def = args[1].object;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    const allocator = script_workflow.?.context.allocator;
    
    // Extract step fields
    const step_name = if (step_def.get("name")) |n|
        try n.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const agent = if (step_def.get("agent")) |a|
        try a.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const action = if (step_def.get("action")) |a|
        try a.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const params = if (step_def.get("params")) |p|
        try p.clone(allocator)
    else
        ScriptValue{ .object = ScriptValue.Object.init(allocator) };
    
    // Optional depends_on
    const depends_on = if (step_def.get("depends_on")) |deps| blk: {
        switch (deps) {
            .array => |arr| {
                var dep_list = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    dep_list[i] = try item.toZig([]const u8, allocator);
                }
                break :blk dep_list;
            },
            else => break :blk &[_][]const u8{},
        }
    } else &[_][]const u8{};
    
    // Optional retry policy
    const retry_policy = if (step_def.get("retry_policy")) |retry| blk: {
        if (retry == .object) {
            break :blk ScriptWorkflow.WorkflowStep.RetryPolicy{
                .max_attempts = if (retry.object.get("max_attempts")) |m|
                    try m.toZig(u32, allocator)
                else
                    3,
                .backoff_ms = if (retry.object.get("backoff_ms")) |b|
                    try b.toZig(u32, allocator)
                else
                    1000,
                .backoff_multiplier = if (retry.object.get("backoff_multiplier")) |m|
                    try m.toZig(f32, allocator)
                else
                    2.0,
            };
        }
        break :blk null;
    } else null;
    
    // Optional timeout
    const timeout_ms = if (step_def.get("timeout_ms")) |t|
        try t.toZig(u32, allocator)
    else
        null;
    
    // Create and add step
    const step = ScriptWorkflow.WorkflowStep{
        .name = try allocator.dupe(u8, step_name),
        .agent = try allocator.dupe(u8, agent),
        .action = try allocator.dupe(u8, action),
        .params = params,
        .depends_on = depends_on,
        .retry_policy = retry_policy,
        .timeout_ms = timeout_ms,
    };
    
    try script_workflow.?.steps.append(step);
    
    return ScriptValue{ .boolean = true };
}

fn removeWorkflowStep(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    const step_name = args[1].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    // Find and remove step
    for (script_workflow.?.steps.items, 0..) |*step, i| {
        if (std.mem.eql(u8, step.name, step_name)) {
            const allocator = script_workflow.?.context.allocator;
            allocator.free(step.name);
            allocator.free(step.agent);
            allocator.free(step.action);
            step.params.deinit(allocator);
            for (step.depends_on) |dep| {
                allocator.free(dep);
            }
            allocator.free(step.depends_on);
            
            _ = script_workflow.?.steps.orderedRemove(i);
            return ScriptValue{ .boolean = true };
        }
    }
    
    return ScriptValue{ .boolean = false };
}

fn executeWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    const input = args[1];
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    // Update state
    script_workflow.?.state = .running;
    
    const allocator = script_workflow.?.context.allocator;
    
    // Simulate workflow execution
    var results = ScriptValue.Object.init(allocator);
    try results.put("workflow_id", ScriptValue{ .string = try allocator.dupe(u8, workflow_id) });
    try results.put("status", ScriptValue{ .string = try allocator.dupe(u8, "completed") });
    
    // Add step results
    var step_results = ScriptValue.Object.init(allocator);
    for (script_workflow.?.steps.items) |step| {
        var step_result = ScriptValue.Object.init(allocator);
        try step_result.put("status", ScriptValue{ .string = try allocator.dupe(u8, "completed") });
        try step_result.put("output", try input.clone(allocator)); // Placeholder
        try step_results.put(step.name, ScriptValue{ .object = step_result });
    }
    try results.put("steps", ScriptValue{ .object = step_results });
    
    script_workflow.?.state = .completed;
    
    return ScriptValue{ .object = results };
}

fn executeWorkflowAsync(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[2] != .function) {
        return error.InvalidArguments;
    }
    
    // Execute synchronously and call callback
    const result = executeWorkflow(args[0..2]) catch |err| {
        const callback_args = [_]ScriptValue{
            ScriptValue.nil,
            ScriptValue{ .string = @errorName(err) },
        };
        _ = try args[2].function.call(&callback_args);
        return ScriptValue.nil;
    };
    
    const callback_args = [_]ScriptValue{
        result,
        ScriptValue.nil,
    };
    _ = try args[2].function.call(&callback_args);
    
    return ScriptValue.nil;
}

fn pauseWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    if (script_workflow.?.state == .running) {
        script_workflow.?.state = .paused;
        return ScriptValue{ .boolean = true };
    }
    
    return ScriptValue{ .boolean = false };
}

fn resumeWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    if (script_workflow.?.state == .paused) {
        script_workflow.?.state = .running;
        return ScriptValue{ .boolean = true };
    }
    
    return ScriptValue{ .boolean = false };
}

fn cancelWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    if (script_workflow.?.state == .running or script_workflow.?.state == .paused) {
        script_workflow.?.state = .cancelled;
        return ScriptValue{ .boolean = true };
    }
    
    return ScriptValue{ .boolean = false };
}

fn getWorkflowStatus(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    const allocator = script_workflow.?.context.allocator;
    var status = ScriptValue.Object.init(allocator);
    
    try status.put("id", ScriptValue{ .string = try allocator.dupe(u8, workflow_id) });
    try status.put("name", ScriptValue{ .string = try allocator.dupe(u8, script_workflow.?.name) });
    try status.put("state", ScriptValue{ .string = try allocator.dupe(u8, @tagName(script_workflow.?.state)) });
    try status.put("steps_count", ScriptValue{ .integer = @intCast(script_workflow.?.steps.items.len) });
    
    return ScriptValue{ .object = status };
}

fn getWorkflowSteps(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    const allocator = script_workflow.?.context.allocator;
    var steps = try ScriptValue.Array.init(allocator, script_workflow.?.steps.items.len);
    
    for (script_workflow.?.steps.items, 0..) |step, i| {
        var step_obj = ScriptValue.Object.init(allocator);
        try step_obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, step.name) });
        try step_obj.put("agent", ScriptValue{ .string = try allocator.dupe(u8, step.agent) });
        try step_obj.put("action", ScriptValue{ .string = try allocator.dupe(u8, step.action) });
        try step_obj.put("params", try step.params.clone(allocator));
        
        // Add depends_on
        var deps = try ScriptValue.Array.init(allocator, step.depends_on.len);
        for (step.depends_on, 0..) |dep, j| {
            deps.items[j] = ScriptValue{ .string = try allocator.dupe(u8, dep) };
        }
        try step_obj.put("depends_on", ScriptValue{ .array = deps });
        
        steps.items[i] = ScriptValue{ .object = step_obj };
    }
    
    return ScriptValue{ .array = steps };
}

fn getWorkflowResults(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    if (script_workflow.?.state != .completed) {
        return ScriptValue.nil;
    }
    
    // Return placeholder results
    const allocator = script_workflow.?.context.allocator;
    var results = ScriptValue.Object.init(allocator);
    try results.put("final_output", ScriptValue{ .string = try allocator.dupe(u8, "Workflow completed successfully") });
    
    return ScriptValue{ .object = results };
}

fn listWorkflows(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;
    
    registry_mutex.lock();
    defer registry_mutex.unlock();
    
    if (workflow_registry) |*registry| {
        const allocator = registry.allocator;
        var list = try ScriptValue.Array.init(allocator, registry.count());
        
        var iter = registry.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            var workflow_obj = ScriptValue.Object.init(allocator);
            try workflow_obj.put("id", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            try workflow_obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, entry.value_ptr.*.name) });
            try workflow_obj.put("state", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.state)) });
            list.items[i] = ScriptValue{ .object = workflow_obj };
        }
        
        return ScriptValue{ .array = list };
    }
    
    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn validateWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    const allocator = script_workflow.?.context.allocator;
    var validation = ScriptValue.Object.init(allocator);
    
    // Check for cycles in dependencies
    var has_cycles = false;
    // TODO: Implement cycle detection
    
    try validation.put("valid", ScriptValue{ .boolean = !has_cycles });
    try validation.put("has_cycles", ScriptValue{ .boolean = has_cycles });
    try validation.put("step_count", ScriptValue{ .integer = @intCast(script_workflow.?.steps.items.len) });
    
    return ScriptValue{ .object = validation };
}

fn visualizeWorkflow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const workflow_id = args[0].string;
    
    registry_mutex.lock();
    const script_workflow = if (workflow_registry) |*registry|
        registry.get(workflow_id)
    else
        null;
    registry_mutex.unlock();
    
    if (script_workflow == null) {
        return error.WorkflowNotFound;
    }
    
    const allocator = script_workflow.?.context.allocator;
    var viz = ScriptValue.Object.init(allocator);
    
    // Create nodes array
    var nodes = try ScriptValue.Array.init(allocator, script_workflow.?.steps.items.len);
    for (script_workflow.?.steps.items, 0..) |step, i| {
        var node = ScriptValue.Object.init(allocator);
        try node.put("id", ScriptValue{ .string = try allocator.dupe(u8, step.name) });
        try node.put("label", ScriptValue{ .string = try std.fmt.allocPrint(allocator, "{s}\n({s})", .{ step.name, step.action }) });
        try node.put("type", ScriptValue{ .string = try allocator.dupe(u8, "step") });
        nodes.items[i] = ScriptValue{ .object = node };
    }
    try viz.put("nodes", ScriptValue{ .array = nodes });
    
    // Create edges array
    var edges = std.ArrayList(ScriptValue).init(allocator);
    for (script_workflow.?.steps.items) |step| {
        for (step.depends_on) |dep| {
            var edge = ScriptValue.Object.init(allocator);
            try edge.put("from", ScriptValue{ .string = try allocator.dupe(u8, dep) });
            try edge.put("to", ScriptValue{ .string = try allocator.dupe(u8, step.name) });
            try edges.append(ScriptValue{ .object = edge });
        }
    }
    try viz.put("edges", ScriptValue{ .array = .{ .items = try edges.toOwnedSlice(), .allocator = allocator } });
    
    return ScriptValue{ .object = viz };
}

// Tests
test "WorkflowBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const module = try WorkflowBridge.getModule(allocator);
    defer allocator.destroy(module);
    
    try testing.expectEqualStrings("workflow", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}