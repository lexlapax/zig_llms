// ABOUTME: Workflow definition structures and base workflow agent implementation
// ABOUTME: Workflows are specialized agents that orchestrate other agents and tools

const std = @import("std");
const agent_mod = @import("../agent.zig");
const Agent = agent_mod.Agent;
const BaseAgent = agent_mod.BaseAgent;
const AgentConfig = agent_mod.AgentConfig;
const RunContext = @import("../context.zig").RunContext;
const tool_mod = @import("../tool.zig");
const Tool = tool_mod.Tool;

// Workflow step types
pub const WorkflowStepType = enum {
    agent,       // Execute another agent
    tool,        // Execute a tool
    condition,   // Conditional execution
    loop,        // Loop execution
    parallel,    // Parallel execution
    sequential,  // Sequential execution
    script,      // Script execution
    delay,       // Delay/sleep
    transform,   // Data transformation
};

// Base workflow step
pub const WorkflowStep = struct {
    id: []const u8,
    name: []const u8,
    step_type: WorkflowStepType,
    config: StepConfig,
    metadata: StepMetadata = .{},
    
    pub const StepConfig = union(WorkflowStepType) {
        agent: AgentStepConfig,
        tool: ToolStepConfig,
        condition: ConditionStepConfig,
        loop: LoopStepConfig,
        parallel: ParallelStepConfig,
        sequential: SequentialStepConfig,
        script: ScriptStepConfig,
        delay: DelayStepConfig,
        transform: TransformStepConfig,
    };
    
    pub const StepMetadata = struct {
        description: ?[]const u8 = null,
        timeout_ms: ?u32 = null,
        retry_count: u8 = 0,
        retry_delay_ms: u32 = 1000,
        continue_on_error: bool = false,
        tags: []const []const u8 = &[_][]const u8{},
    };
};

// Agent step configuration
pub const AgentStepConfig = struct {
    agent_name: []const u8,
    input_mapping: ?InputMapping = null,
    output_mapping: ?OutputMapping = null,
    config_override: ?std.json.Value = null,
};

// Tool step configuration
pub const ToolStepConfig = struct {
    tool_name: []const u8,
    input_mapping: ?InputMapping = null,
    output_mapping: ?OutputMapping = null,
    validation_schema: ?[]const u8 = null,
};

// Condition step configuration
pub const ConditionStepConfig = struct {
    condition: ConditionExpression,
    true_steps: []const WorkflowStep,
    false_steps: []const WorkflowStep = &[_]WorkflowStep{},
};

// Loop step configuration
pub const LoopStepConfig = struct {
    loop_type: LoopType,
    condition: ?ConditionExpression = null,
    max_iterations: ?u32 = null,
    steps: []const WorkflowStep,
    
    pub const LoopType = enum {
        while_loop,
        for_loop,
        foreach_loop,
    };
};

// Parallel step configuration
pub const ParallelStepConfig = struct {
    steps: []const WorkflowStep,
    max_concurrency: ?u32 = null,
    fail_fast: bool = true,
    collect_results: bool = true,
};

// Sequential step configuration
pub const SequentialStepConfig = struct {
    steps: []const WorkflowStep,
    fail_fast: bool = true,
};

// Script step configuration
pub const ScriptStepConfig = struct {
    language: ScriptLanguage,
    code: []const u8,
    environment: ?std.StringHashMap([]const u8) = null,
    
    pub const ScriptLanguage = enum {
        lua,
        javascript,
        python,
        shell,
    };
};

// Delay step configuration
pub const DelayStepConfig = struct {
    duration_ms: u32,
    jitter_percent: f32 = 0.0,
};

// Transform step configuration
pub const TransformStepConfig = struct {
    transform_type: TransformType,
    expression: []const u8,
    
    pub const TransformType = enum {
        jq,         // jq expression
        jsonpath,   // JSONPath expression
        template,   // Template string
        function,   // Custom function
    };
};

// Input/Output mapping
pub const InputMapping = struct {
    source_path: []const u8,
    target_path: []const u8,
    transform: ?[]const u8 = null,
    default_value: ?std.json.Value = null,
};

pub const OutputMapping = struct {
    source_path: []const u8,
    target_path: []const u8,
    transform: ?[]const u8 = null,
};

// Condition expression
pub const ConditionExpression = struct {
    expression_type: ExpressionType,
    expression: []const u8,
    
    pub const ExpressionType = enum {
        jsonpath,   // JSONPath boolean expression
        javascript, // JavaScript expression
        simple,     // Simple comparison (key op value)
    };
    
    pub fn evaluate(self: ConditionExpression, context: std.json.Value, allocator: std.mem.Allocator) !bool {
        return switch (self.expression_type) {
            .simple => try evaluateSimpleExpression(self.expression, context, allocator),
            .jsonpath => try evaluateJsonPathExpression(self.expression, context, allocator),
            .javascript => try evaluateJavaScriptExpression(self.expression, context, allocator),
        };
    }
};

// Workflow definition
pub const WorkflowDefinition = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    version: []const u8 = "1.0.0",
    author: ?[]const u8 = null,
    steps: []const WorkflowStep,
    input_schema: ?std.json.Value = null,
    output_schema: ?std.json.Value = null,
    variables: std.StringHashMap(std.json.Value),
    metadata: WorkflowMetadata = .{},
    
    pub const WorkflowMetadata = struct {
        tags: []const []const u8 = &[_][]const u8{},
        timeout_ms: ?u32 = null,
        max_retries: u8 = 0,
        created_at: ?i64 = null,
        updated_at: ?i64 = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, id: []const u8, name: []const u8) WorkflowDefinition {
        return .{
            .id = id,
            .name = name,
            .steps = &[_]WorkflowStep{},
            .variables = std.StringHashMap(std.json.Value).init(allocator),
        };
    }
    
    pub fn deinit(self: *WorkflowDefinition) void {
        self.variables.deinit();
    }
};

// Workflow execution context
pub const WorkflowExecutionContext = struct {
    workflow: *const WorkflowDefinition,
    variables: std.StringHashMap(std.json.Value),
    step_results: std.StringHashMap(std.json.Value),
    execution_state: ExecutionState,
    current_step: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    
    pub const ExecutionState = enum {
        ready,
        running,
        paused,
        completed,
        failed,
        cancelled,
    };
    
    pub fn init(allocator: std.mem.Allocator, workflow: *const WorkflowDefinition) WorkflowExecutionContext {
        return .{
            .workflow = workflow,
            .variables = std.StringHashMap(std.json.Value).init(allocator),
            .step_results = std.StringHashMap(std.json.Value).init(allocator),
            .execution_state = .ready,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WorkflowExecutionContext) void {
        self.variables.deinit();
        self.step_results.deinit();
    }
    
    pub fn setVariable(self: *WorkflowExecutionContext, name: []const u8, value: std.json.Value) !void {
        try self.variables.put(name, value);
    }
    
    pub fn getVariable(self: *WorkflowExecutionContext, name: []const u8) ?std.json.Value {
        return self.variables.get(name);
    }
    
    pub fn setStepResult(self: *WorkflowExecutionContext, step_id: []const u8, result: std.json.Value) !void {
        try self.step_results.put(step_id, result);
    }
    
    pub fn getStepResult(self: *WorkflowExecutionContext, step_id: []const u8) ?std.json.Value {
        return self.step_results.get(step_id);
    }
};

// Workflow agent - executes workflows as an agent
pub const WorkflowAgent = struct {
    base: BaseAgent,
    workflow: WorkflowDefinition,
    execution_context: ?WorkflowExecutionContext = null,
    
    const vtable = Agent.VTable{
        .initialize = workflowInitialize,
        .beforeRun = workflowBeforeRun,
        .run = workflowRun,
        .afterRun = workflowAfterRun,
        .cleanup = workflowCleanup,
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        workflow: WorkflowDefinition,
        config: AgentConfig,
    ) !*WorkflowAgent {
        const base = try BaseAgent.init(allocator, workflow.name, config);
        errdefer base.deinit();
        
        const self = try allocator.create(WorkflowAgent);
        self.* = WorkflowAgent{
            .base = base.*,
            .workflow = workflow,
        };
        
        // Override vtable for workflow-specific behavior
        const workflow_vtable = try allocator.create(Agent.VTable);
        workflow_vtable.* = vtable;
        self.base.agent.vtable = workflow_vtable;
        
        // Free the base agent struct
        allocator.destroy(base);
        
        return self;
    }
    
    pub fn deinit(self: *WorkflowAgent) void {
        if (self.execution_context) |*ctx| {
            ctx.deinit();
        }
        self.workflow.deinit();
        self.base.allocator.destroy(self.base.agent.vtable);
        self.base.deinit();
    }
    
    fn workflowInitialize(agent: *Agent, context: *RunContext) anyerror!void {
        const base_agent: *BaseAgent = @fieldParentPtr("agent", agent);
        const self: *WorkflowAgent = @fieldParentPtr("base", base_agent);
        
        // Call base initialization
        try BaseAgent.baseInitialize(agent, context);
        
        // Initialize workflow execution context
        self.execution_context = WorkflowExecutionContext.init(self.base.allocator, &self.workflow);
        
        // Set workflow metadata
        try agent.state.metadata.put("workflow_id", .{ .string = self.workflow.id });
        try agent.state.metadata.put("workflow_version", .{ .string = self.workflow.version });
        try agent.state.metadata.put("total_steps", .{ .integer = @as(i64, @intCast(self.workflow.steps.len)) });
    }
    
    fn workflowBeforeRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        const base_agent: *BaseAgent = @fieldParentPtr("agent", agent);
        const self: *WorkflowAgent = @fieldParentPtr("base", base_agent);
        
        // Initialize workflow variables from input
        if (self.execution_context) |*ctx| {
            try ctx.setVariable("input", input);
            
            // Copy workflow default variables
            var var_iter = self.workflow.variables.iterator();
            while (var_iter.next()) |entry| {
                try ctx.setVariable(entry.key_ptr.*, entry.value_ptr.*);
            }
            
            ctx.execution_state = .running;
        }
        
        return input;
    }
    
    fn workflowRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        const base_agent: *BaseAgent = @fieldParentPtr("agent", agent);
        const self: *WorkflowAgent = @fieldParentPtr("base", base_agent);
        _ = input;
        
        if (self.execution_context == null) {
            return error.WorkflowNotInitialized;
        }
        
        var ctx = &self.execution_context.?;
        
        // Execute workflow steps sequentially by default
        for (self.workflow.steps) |step| {
            ctx.current_step = step.id;
            
            const step_result = try self.executeStep(step, ctx);
            try ctx.setStepResult(step.id, step_result);
            
            // Update agent state with progress
            try agent.state.metadata.put("current_step", .{ .string = step.id });
        }
        
        ctx.execution_state = .completed;
        
        // Return the result of the last step or a combined result
        if (self.workflow.steps.len > 0) {
            const last_step = self.workflow.steps[self.workflow.steps.len - 1];
            return ctx.getStepResult(last_step.id) orelse .{ .null = {} };
        }
        
        return .{ .null = {} };
    }
    
    fn workflowAfterRun(agent: *Agent, output: std.json.Value) anyerror!std.json.Value {
        const base_agent: *BaseAgent = @fieldParentPtr("agent", agent);
        const self: *WorkflowAgent = @fieldParentPtr("base", base_agent);
        
        // Store final output in context
        if (self.execution_context) |*ctx| {
            try ctx.setVariable("output", output);
        }
        
        return BaseAgent.baseAfterRun(agent, output);
    }
    
    fn workflowCleanup(agent: *Agent) void {
        const base_agent: *BaseAgent = @fieldParentPtr("agent", agent);
        const self: *WorkflowAgent = @fieldParentPtr("base", base_agent);
        
        if (self.execution_context) |*ctx| {
            ctx.execution_state = .cancelled;
        }
        
        BaseAgent.baseCleanup(agent);
    }
    
    fn executeStep(self: *WorkflowAgent, step: WorkflowStep, ctx: *WorkflowExecutionContext) !std.json.Value {
        return switch (step.step_type) {
            .agent => try self.executeAgentStep(step.config.agent, ctx),
            .tool => try self.executeToolStep(step.config.tool, ctx),
            .delay => try self.executeDelayStep(step.config.delay, ctx),
            .transform => try self.executeTransformStep(step.config.transform, ctx),
            else => {
                // For complex step types, delegate to specialized implementations
                return error.StepTypeNotImplemented;
            },
        };
    }
    
    fn executeAgentStep(self: *WorkflowAgent, config: AgentStepConfig, ctx: *WorkflowExecutionContext) !std.json.Value {
        // TODO: Implement agent step execution
        // This would look up the agent by name and execute it
        _ = self;
        _ = config;
        _ = ctx;
        return error.NotImplemented;
    }
    
    fn executeToolStep(self: *WorkflowAgent, config: ToolStepConfig, ctx: *WorkflowExecutionContext) !std.json.Value {
        // TODO: Implement tool step execution
        // This would look up the tool by name and execute it
        _ = self;
        _ = config;
        _ = ctx;
        return error.NotImplemented;
    }
    
    fn executeDelayStep(self: *WorkflowAgent, config: DelayStepConfig, ctx: *WorkflowExecutionContext) !std.json.Value {
        _ = self;
        
        var delay_ms = config.duration_ms;
        
        // Add jitter if specified
        if (config.jitter_percent > 0.0) {
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
            const jitter = @as(f32, @floatFromInt(delay_ms)) * config.jitter_percent / 100.0;
            const jitter_ms = @as(u32, @intFromFloat(rng.random().float(f32) * jitter));
            delay_ms += jitter_ms;
        }
        
        std.time.sleep(delay_ms * std.time.ns_per_ms);
        
        return .{ .object = std.json.ObjectMap.init(ctx.allocator) };
    }
    
    fn executeTransformStep(self: *WorkflowAgent, config: TransformStepConfig, ctx: *WorkflowExecutionContext) !std.json.Value {
        // TODO: Implement data transformation
        _ = self;
        _ = config;
        _ = ctx;
        return error.NotImplemented;
    }
};

// Helper functions for condition evaluation
fn evaluateSimpleExpression(expression: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !bool {
    // Parse simple expressions like "field == value" or "field > 10"
    _ = expression;
    _ = context;
    _ = allocator;
    // TODO: Implement simple expression parser
    return true;
}

fn evaluateJsonPathExpression(expression: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !bool {
    // Evaluate JSONPath expressions
    _ = expression;
    _ = context;
    _ = allocator;
    // TODO: Implement JSONPath evaluation
    return true;
}

fn evaluateJavaScriptExpression(expression: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !bool {
    // Evaluate JavaScript expressions (would need a JS engine)
    _ = expression;
    _ = context;
    _ = allocator;
    // TODO: Implement JavaScript evaluation
    return true;
}

// Tests
test "workflow definition creation" {
    const allocator = std.testing.allocator;
    
    var workflow = WorkflowDefinition.init(allocator, "test_workflow", "Test Workflow");
    defer workflow.deinit();
    
    try std.testing.expectEqualStrings("test_workflow", workflow.id);
    try std.testing.expectEqualStrings("Test Workflow", workflow.name);
    try std.testing.expectEqual(@as(usize, 0), workflow.steps.len);
}

test "workflow execution context" {
    const allocator = std.testing.allocator;
    
    var workflow = WorkflowDefinition.init(allocator, "test", "Test");
    defer workflow.deinit();
    
    var ctx = WorkflowExecutionContext.init(allocator, &workflow);
    defer ctx.deinit();
    
    try ctx.setVariable("test_var", .{ .string = "test_value" });
    const value = ctx.getVariable("test_var");
    
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test_value", value.?.string);
}