// ABOUTME: Sequential workflow agent implementation for ordered step execution
// ABOUTME: Executes workflow steps one after another with error handling and state management

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowAgent = definition.WorkflowAgent;
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const SequentialStepConfig = definition.SequentialStepConfig;
const agent_mod = @import("../agent.zig");
const Agent = agent_mod.Agent;
const BaseAgent = agent_mod.BaseAgent;
const AgentConfig = agent_mod.AgentConfig;
const RunContext = @import("../context.zig").RunContext;

// Sequential workflow execution result
pub const SequentialExecutionResult = struct {
    success: bool,
    completed_steps: usize,
    failed_step: ?[]const u8 = null,
    error_message: ?[]const u8 = null,
    step_results: std.StringHashMap(std.json.Value),
    execution_time_ms: u64,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *SequentialExecutionResult) void {
        var iter = self.step_results.iterator();
        while (iter.next()) |entry| {
            // Note: step results are managed by WorkflowExecutionContext
            _ = entry;
        }
        self.step_results.deinit();
        
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }
    
    pub fn toJson(self: *SequentialExecutionResult) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        try obj.put("success", .{ .bool = self.success });
        try obj.put("completed_steps", .{ .integer = @as(i64, @intCast(self.completed_steps)) });
        try obj.put("execution_time_ms", .{ .integer = @as(i64, @intCast(self.execution_time_ms)) });
        
        if (self.failed_step) |step| {
            try obj.put("failed_step", .{ .string = step });
        }
        
        if (self.error_message) |msg| {
            try obj.put("error_message", .{ .string = msg });
        }
        
        // Add step results
        var results_obj = std.json.ObjectMap.init(self.allocator);
        var iter = self.step_results.iterator();
        while (iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("step_results", .{ .object = results_obj });
        
        return .{ .object = obj };
    }
};

// Sequential workflow executor
pub const SequentialWorkflowExecutor = struct {
    allocator: std.mem.Allocator,
    config: ExecutorConfig = .{},
    
    pub const ExecutorConfig = struct {
        fail_fast: bool = true,
        collect_results: bool = true,
        timeout_ms: ?u32 = null,
        max_step_retries: u8 = 0,
        step_delay_ms: u32 = 0,
        continue_on_error: bool = false,
        validate_step_inputs: bool = true,
        validate_step_outputs: bool = false,
    };
    
    pub fn init(allocator: std.mem.Allocator) SequentialWorkflowExecutor {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn execute(
        self: *SequentialWorkflowExecutor,
        workflow: *const WorkflowDefinition,
        input: std.json.Value,
        context: *RunContext,
    ) !SequentialExecutionResult {
        const start_time = std.time.milliTimestamp();
        
        var execution_context = WorkflowExecutionContext.init(self.allocator, workflow);
        defer execution_context.deinit();
        
        var result = SequentialExecutionResult{
            .success = true,
            .completed_steps = 0,
            .step_results = std.StringHashMap(std.json.Value).init(self.allocator),
            .execution_time_ms = 0,
            .allocator = self.allocator,
        };
        
        // Initialize execution context
        try execution_context.setVariable("input", input);
        execution_context.execution_state = .running;
        
        // Execute steps sequentially
        for (workflow.steps, 0..) |step, step_index| {
            execution_context.current_step = step.id;
            
            // Check timeout
            if (self.config.timeout_ms) |timeout| {
                const elapsed = @as(u32, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed > timeout) {
                    result.success = false;
                    result.error_message = try self.allocator.dupe(u8, "Workflow execution timeout");
                    break;
                }
            }
            
            // Execute step with retries
            const step_result = self.executeStepWithRetries(
                step,
                &execution_context,
                context,
            ) catch |err| {
                result.success = false;
                result.failed_step = step.id;
                result.error_message = try std.allocator.dupe(self.allocator, @errorName(err));
                
                // Check if we should continue on error
                if (!self.config.continue_on_error and !step.metadata.continue_on_error) {
                    break;
                }
                
                // Store null result and continue
                if (self.config.collect_results) {
                    try result.step_results.put(step.id, .{ .null = {} });
                }
                
                continue;
            };
            
            // Store step result
            try execution_context.setStepResult(step.id, step_result);
            
            if (self.config.collect_results) {
                try result.step_results.put(step.id, step_result);
            }
            
            result.completed_steps = step_index + 1;
            
            // Add delay between steps if configured
            if (self.config.step_delay_ms > 0 and step_index < workflow.steps.len - 1) {
                std.time.sleep(self.config.step_delay_ms * std.time.ns_per_ms);
            }
        }
        
        execution_context.execution_state = if (result.success) .completed else .failed;
        result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        
        return result;
    }
    
    fn executeStepWithRetries(
        self: *SequentialWorkflowExecutor,
        step: WorkflowStep,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        const max_retries = if (step.metadata.retry_count > 0)
            step.metadata.retry_count
        else
            self.config.max_step_retries;
        
        var retry_count: u8 = 0;
        
        while (retry_count <= max_retries) : (retry_count += 1) {
            if (retry_count > 0) {
                std.time.sleep(step.metadata.retry_delay_ms * std.time.ns_per_ms);
            }
            
            const result = self.executeStep(step, execution_context, run_context) catch |err| {
                if (retry_count < max_retries) {
                    continue;
                }
                return err;
            };
            
            return result;
        }
        
        unreachable;
    }
    
    fn executeStep(
        self: *SequentialWorkflowExecutor,
        step: WorkflowStep,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        return switch (step.step_type) {
            .agent => try self.executeAgentStep(step.config.agent, execution_context, run_context),
            .tool => try self.executeToolStep(step.config.tool, execution_context, run_context),
            .sequential => try self.executeSequentialStep(step.config.sequential, execution_context, run_context),
            .delay => try self.executeDelayStep(step.config.delay, execution_context),
            .transform => try self.executeTransformStep(step.config.transform, execution_context),
            else => error.StepTypeNotSupported,
        };
    }
    
    fn executeAgentStep(
        self: *SequentialWorkflowExecutor,
        config: definition.AgentStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        _ = self;
        _ = config;
        _ = execution_context;
        _ = run_context;
        
        // TODO: Implement agent step execution
        // This would:
        // 1. Look up the agent by name from a registry
        // 2. Apply input mapping to prepare agent input
        // 3. Execute the agent
        // 4. Apply output mapping to the result
        // 5. Return the mapped result
        
        return error.NotImplemented;
    }
    
    fn executeToolStep(
        self: *SequentialWorkflowExecutor,
        config: definition.ToolStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        _ = self;
        _ = config;
        _ = execution_context;
        _ = run_context;
        
        // TODO: Implement tool step execution
        // This would:
        // 1. Look up the tool by name from a registry
        // 2. Apply input mapping to prepare tool input
        // 3. Validate input against schema if configured
        // 4. Execute the tool
        // 5. Validate output if configured
        // 6. Apply output mapping to the result
        // 7. Return the mapped result
        
        return error.NotImplemented;
    }
    
    fn executeSequentialStep(
        self: *SequentialWorkflowExecutor,
        config: SequentialStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        // Create a sub-workflow for the sequential steps
        var sub_workflow = WorkflowDefinition.init(self.allocator, "sequential_sub", "Sequential Substeps");
        defer sub_workflow.deinit();
        
        sub_workflow.steps = config.steps;
        
        // Create a sub-executor
        var sub_executor = SequentialWorkflowExecutor.init(self.allocator);
        sub_executor.config.fail_fast = config.fail_fast;
        sub_executor.config.collect_results = true;
        
        // Execute sub-workflow
        const current_input = execution_context.getVariable("input") orelse .{ .null = {} };
        var sub_result = try sub_executor.execute(&sub_workflow, current_input, run_context);
        defer sub_result.deinit();
        
        if (!sub_result.success) {
            return error.SubWorkflowFailed;
        }
        
        // Return the combined results
        return try sub_result.toJson();
    }
    
    fn executeDelayStep(
        self: *SequentialWorkflowExecutor,
        config: definition.DelayStepConfig,
        execution_context: *WorkflowExecutionContext,
    ) !std.json.Value {
        _ = execution_context;
        
        var delay_ms = config.duration_ms;
        
        // Add jitter if specified
        if (config.jitter_percent > 0.0) {
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
            const jitter = @as(f32, @floatFromInt(delay_ms)) * config.jitter_percent / 100.0;
            const jitter_ms = @as(u32, @intFromFloat(rng.random().float(f32) * jitter));
            delay_ms += jitter_ms;
        }
        
        std.time.sleep(delay_ms * std.time.ns_per_ms);
        
        // Return delay information
        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("delayed_ms", .{ .integer = @as(i64, @intCast(delay_ms)) });
        try result.put("step_type", .{ .string = "delay" });
        
        return .{ .object = result };
    }
    
    fn executeTransformStep(
        self: *SequentialWorkflowExecutor,
        config: definition.TransformStepConfig,
        execution_context: *WorkflowExecutionContext,
    ) !std.json.Value {
        _ = self;
        _ = config;
        _ = execution_context;
        
        // TODO: Implement data transformation
        // This would:
        // 1. Get the current context data
        // 2. Apply the transformation expression
        // 3. Return the transformed data
        
        return error.NotImplemented;
    }
};

// Sequential workflow agent - specialized agent for sequential execution
pub const SequentialWorkflowAgent = struct {
    base: WorkflowAgent,
    executor: SequentialWorkflowExecutor,
    
    pub fn init(
        allocator: std.mem.Allocator,
        workflow: WorkflowDefinition,
        config: AgentConfig,
        executor_config: SequentialWorkflowExecutor.ExecutorConfig,
    ) !*SequentialWorkflowAgent {
        const base = try WorkflowAgent.init(allocator, workflow, config);
        errdefer base.deinit();
        
        const self = try allocator.create(SequentialWorkflowAgent);
        self.* = SequentialWorkflowAgent{
            .base = base.*,
            .executor = SequentialWorkflowExecutor.init(allocator),
        };
        self.executor.config = executor_config;
        
        // Override run method for sequential execution
        const sequential_vtable = try allocator.create(Agent.VTable);
        sequential_vtable.* = .{
            .initialize = WorkflowAgent.workflowInitialize,
            .beforeRun = WorkflowAgent.workflowBeforeRun,
            .run = sequentialRun,
            .afterRun = WorkflowAgent.workflowAfterRun,
            .cleanup = WorkflowAgent.workflowCleanup,
        };
        self.base.base.agent.vtable = sequential_vtable;
        
        // Free the base workflow agent struct
        allocator.destroy(base);
        
        return self;
    }
    
    pub fn deinit(self: *SequentialWorkflowAgent) void {
        self.base.base.allocator.destroy(self.base.base.agent.vtable);
        self.base.deinit();
    }
    
    fn sequentialRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        const base_agent: *BaseAgent = @fieldParentPtr("agent", agent);
        const workflow_agent: *WorkflowAgent = @fieldParentPtr("base", base_agent);
        const self: *SequentialWorkflowAgent = @fieldParentPtr("base", workflow_agent);
        
        // Get run context from agent state
        // TODO: Better way to get RunContext
        var run_context = RunContext{
            .allocator = self.base.base.allocator,
            .config = std.StringHashMap(std.json.Value).init(self.base.base.allocator),
            .logger = null,
            .tracer = null,
        };
        defer run_context.config.deinit();
        
        // Execute using sequential executor
        var result = try self.executor.execute(&self.base.workflow, input, &run_context);
        defer result.deinit();
        
        if (!result.success) {
            if (result.error_message) |msg| {
                std.log.err("Sequential workflow failed: {s}", .{msg});
            }
            return error.WorkflowExecutionFailed;
        }
        
        // Return the execution result as JSON
        return try result.toJson();
    }
};

// Workflow builder for sequential workflows
pub const SequentialWorkflowBuilder = struct {
    allocator: std.mem.Allocator,
    workflow: WorkflowDefinition,
    steps: std.ArrayList(WorkflowStep),
    current_step_id: u32 = 0,
    
    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) SequentialWorkflowBuilder {
        return .{
            .allocator = allocator,
            .workflow = WorkflowDefinition.init(allocator, id, name),
            .steps = std.ArrayList(WorkflowStep).init(allocator),
        };
    }
    
    pub fn deinit(self: *SequentialWorkflowBuilder) void {
        self.steps.deinit();
        self.workflow.deinit();
    }
    
    pub fn withDescription(self: *SequentialWorkflowBuilder, description: []const u8) *SequentialWorkflowBuilder {
        self.workflow.description = description;
        return self;
    }
    
    pub fn withVersion(self: *SequentialWorkflowBuilder, version: []const u8) *SequentialWorkflowBuilder {
        self.workflow.version = version;
        return self;
    }
    
    pub fn addDelayStep(self: *SequentialWorkflowBuilder, name: []const u8, duration_ms: u32) !*SequentialWorkflowBuilder {
        const step_id = try std.fmt.allocPrint(self.allocator, "step_{d}", .{self.current_step_id});
        self.current_step_id += 1;
        
        const step = WorkflowStep{
            .id = step_id,
            .name = name,
            .step_type = .delay,
            .config = .{
                .delay = .{
                    .duration_ms = duration_ms,
                },
            },
        };
        
        try self.steps.append(step);
        return self;
    }
    
    pub fn addAgentStep(self: *SequentialWorkflowBuilder, name: []const u8, agent_name: []const u8) !*SequentialWorkflowBuilder {
        const step_id = try std.fmt.allocPrint(self.allocator, "step_{d}", .{self.current_step_id});
        self.current_step_id += 1;
        
        const step = WorkflowStep{
            .id = step_id,
            .name = name,
            .step_type = .agent,
            .config = .{
                .agent = .{
                    .agent_name = agent_name,
                },
            },
        };
        
        try self.steps.append(step);
        return self;
    }
    
    pub fn addToolStep(self: *SequentialWorkflowBuilder, name: []const u8, tool_name: []const u8) !*SequentialWorkflowBuilder {
        const step_id = try std.fmt.allocPrint(self.allocator, "step_{d}", .{self.current_step_id});
        self.current_step_id += 1;
        
        const step = WorkflowStep{
            .id = step_id,
            .name = name,
            .step_type = .tool,
            .config = .{
                .tool = .{
                    .tool_name = tool_name,
                },
            },
        };
        
        try self.steps.append(step);
        return self;
    }
    
    pub fn build(self: *SequentialWorkflowBuilder) !WorkflowDefinition {
        self.workflow.steps = try self.steps.toOwnedSlice();
        return self.workflow;
    }
};

// Tests
test "sequential workflow builder" {
    const allocator = std.testing.allocator;
    
    var builder = SequentialWorkflowBuilder.init(allocator, "test_seq", "Test Sequential");
    defer builder.deinit();
    
    _ = builder.withDescription("A test sequential workflow")
        .withVersion("1.0.0");
    
    _ = try builder.addDelayStep("Wait 1 second", 1000);
    _ = try builder.addDelayStep("Wait 2 seconds", 2000);
    
    const workflow = try builder.build();
    
    try std.testing.expectEqual(@as(usize, 2), workflow.steps.len);
    try std.testing.expectEqualStrings("Wait 1 second", workflow.steps[0].name);
    try std.testing.expectEqual(@as(u32, 1000), workflow.steps[0].config.delay.duration_ms);
}

test "sequential executor with delay steps" {
    const allocator = std.testing.allocator;
    
    var builder = SequentialWorkflowBuilder.init(allocator, "delay_test", "Delay Test");
    defer builder.deinit();
    
    _ = try builder.addDelayStep("Short delay", 10); // 10ms delay
    
    const workflow = try builder.build();
    
    var executor = SequentialWorkflowExecutor.init(allocator);
    
    var run_context = RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();
    
    const start_time = std.time.milliTimestamp();
    var result = try executor.execute(&workflow, .{ .null = {} }, &run_context);
    defer result.deinit();
    const elapsed = std.time.milliTimestamp() - start_time;
    
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.completed_steps);
    try std.testing.expect(elapsed >= 10); // At least 10ms elapsed
}