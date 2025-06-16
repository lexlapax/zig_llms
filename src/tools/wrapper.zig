// ABOUTME: Wrapper tool for converting agents and workflows into reusable tool components
// ABOUTME: Enables composition and modular execution of complex agent behaviors as tools

const std = @import("std");
const tool = @import("../tool.zig");
const agent = @import("../agent.zig");
const workflow = @import("../workflow.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;
const Agent = agent.Agent;
const BaseAgent = agent.BaseAgent;
const Workflow = workflow.Workflow;
const WorkflowStep = workflow.WorkflowStep;

// Wrapper types
pub const WrapperType = enum {
    agent,
    workflow,

    pub fn toString(self: WrapperType) []const u8 {
        return @tagName(self);
    }
};

// Wrapper execution modes
pub const ExecutionMode = enum {
    synchronous, // Wait for completion
    asynchronous, // Start and return immediately
    streaming, // Stream partial results

    pub fn toString(self: ExecutionMode) []const u8 {
        return @tagName(self);
    }
};

// Wrapper tool error types
pub const WrapperToolError = error{
    InvalidWrapper,
    ExecutionFailed,
    TimeoutError,
    InvalidInput,
    UnsupportedMode,
    AgentNotFound,
    WorkflowNotFound,
};

// Wrapper configuration
pub const WrapperConfig = struct {
    timeout_seconds: u32 = 60,
    max_output_size: usize = 10 * 1024 * 1024, // 10MB
    allow_nested_execution: bool = false,
    execution_mode: ExecutionMode = .synchronous,
    stream_interval_ms: u32 = 100,
    max_retries: u32 = 3,
    enable_caching: bool = false,
};

// Agent wrapper context
pub const AgentWrapper = struct {
    agent_ptr: *Agent,
    name: []const u8,
    description: []const u8,
    input_schema: ?std.json.Value = null,
    output_schema: ?std.json.Value = null,

    pub fn deinit(self: *AgentWrapper, allocator: std.mem.Allocator) void {
        if (self.input_schema) |schema| {
            switch (schema) {
                .object => |obj| obj.deinit(),
                else => {},
            }
        }
        if (self.output_schema) |schema| {
            switch (schema) {
                .object => |obj| obj.deinit(),
                else => {},
            }
        }
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

// Workflow wrapper context
pub const WorkflowWrapper = struct {
    workflow_ptr: *Workflow,
    name: []const u8,
    description: []const u8,
    input_schema: ?std.json.Value = null,
    output_schema: ?std.json.Value = null,

    pub fn deinit(self: *WorkflowWrapper, allocator: std.mem.Allocator) void {
        if (self.input_schema) |schema| {
            switch (schema) {
                .object => |obj| obj.deinit(),
                else => {},
            }
        }
        if (self.output_schema) |schema| {
            switch (schema) {
                .object => |obj| obj.deinit(),
                else => {},
            }
        }
        allocator.free(self.name);
        allocator.free(self.description);
    }
};

// Execution context for tracking state
pub const ExecutionContext = struct {
    execution_id: []const u8,
    start_time: i64,
    status: ExecutionStatus,
    partial_results: std.ArrayList(std.json.Value),
    error_message: ?[]const u8 = null,

    pub const ExecutionStatus = enum {
        pending,
        running,
        completed,
        failed,
        cancelled,
    };

    pub fn init(allocator: std.mem.Allocator, execution_id: []const u8) ExecutionContext {
        return ExecutionContext{
            .execution_id = execution_id,
            .start_time = std.time.milliTimestamp(),
            .status = .pending,
            .partial_results = std.ArrayList(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *ExecutionContext, allocator: std.mem.Allocator) void {
        for (self.partial_results.items) |result| {
            switch (result) {
                .object => |obj| obj.deinit(),
                .array => |arr| arr.deinit(),
                else => {},
            }
        }
        self.partial_results.deinit();
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        allocator.free(self.execution_id);
    }
};

// Wrapper tool for agents and workflows
pub const WrapperTool = struct {
    base: BaseTool,
    config: WrapperConfig,
    wrapper_type: WrapperType,
    agent_wrapper: ?AgentWrapper = null,
    workflow_wrapper: ?WorkflowWrapper = null,
    allocator: std.mem.Allocator,
    execution_contexts: std.StringHashMap(*ExecutionContext),
    mutex: std.Thread.Mutex,

    pub fn initAgent(
        allocator: std.mem.Allocator,
        agent_ptr: *Agent,
        config: WrapperConfig,
        name: []const u8,
        description: []const u8,
    ) !*WrapperTool {
        const self = try allocator.create(WrapperTool);

        // Create tool metadata
        const metadata = ToolMetadata{
            .name = try std.fmt.allocPrint(allocator, "agent_{s}", .{name}),
            .description = try std.fmt.allocPrint(allocator, "Wrapped agent: {s}", .{description}),
            .version = "1.0.0",
            .category = .agent,
            .capabilities = &[_][]const u8{ "agent_execution", "state_management", "async_execution" },
            .input_schema = try createAgentInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Execute agent with input",
                    .input = .{ .object = try createExampleAgentInput(allocator, "Hello agent") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Agent executed successfully") },
                },
            },
        };

        self.* = .{
            .base = BaseTool.init(metadata),
            .config = config,
            .wrapper_type = .agent,
            .agent_wrapper = AgentWrapper{
                .agent_ptr = agent_ptr,
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, description),
            },
            .allocator = allocator,
            .execution_contexts = std.StringHashMap(*ExecutionContext).init(allocator),
            .mutex = std.Thread.Mutex{},
        };

        // Set vtable
        self.base.tool.vtable = &.{
            .execute = execute,
            .validate = validate,
            .deinit = deinit,
        };

        return self;
    }

    pub fn initWorkflow(
        allocator: std.mem.Allocator,
        workflow_ptr: *Workflow,
        config: WrapperConfig,
        name: []const u8,
        description: []const u8,
    ) !*WrapperTool {
        const self = try allocator.create(WrapperTool);

        // Create tool metadata
        const metadata = ToolMetadata{
            .name = try std.fmt.allocPrint(allocator, "workflow_{s}", .{name}),
            .description = try std.fmt.allocPrint(allocator, "Wrapped workflow: {s}", .{description}),
            .version = "1.0.0",
            .category = .workflow,
            .capabilities = &[_][]const u8{ "workflow_execution", "step_management", "async_execution" },
            .input_schema = try createWorkflowInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Execute workflow with parameters",
                    .input = .{ .object = try createExampleWorkflowInput(allocator, "Execute task") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Workflow completed") },
                },
            },
        };

        self.* = .{
            .base = BaseTool.init(metadata),
            .config = config,
            .wrapper_type = .workflow,
            .workflow_wrapper = WorkflowWrapper{
                .workflow_ptr = workflow_ptr,
                .name = try allocator.dupe(u8, name),
                .description = try allocator.dupe(u8, description),
            },
            .allocator = allocator,
            .execution_contexts = std.StringHashMap(*ExecutionContext).init(allocator),
            .mutex = std.Thread.Mutex{},
        };

        // Set vtable
        self.base.tool.vtable = &.{
            .execute = execute,
            .validate = validate,
            .deinit = deinit,
        };

        return self;
    }

    fn execute(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const self = @fieldParentPtr(WrapperTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

        // Parse common input
        const mode_val = input.object.get("mode") orelse
            .{ .string = self.config.execution_mode.toString() };

        if (mode_val != .string) {
            return error.InvalidInput;
        }

        const mode = std.meta.stringToEnum(ExecutionMode, mode_val.string) orelse {
            return error.UnsupportedMode;
        };

        // Generate execution ID
        const execution_id = try std.fmt.allocPrint(allocator, "{d}_{s}", .{ std.time.milliTimestamp(), self.wrapper_type.toString() });

        // Execute based on wrapper type and mode
        return switch (self.wrapper_type) {
            .agent => switch (mode) {
                .synchronous => self.executeAgentSync(input, execution_id, allocator),
                .asynchronous => self.executeAgentAsync(input, execution_id, allocator),
                .streaming => self.executeAgentStreaming(input, execution_id, allocator),
            },
            .workflow => switch (mode) {
                .synchronous => self.executeWorkflowSync(input, execution_id, allocator),
                .asynchronous => self.executeWorkflowAsync(input, execution_id, allocator),
                .streaming => self.executeWorkflowStreaming(input, execution_id, allocator),
            },
        };
    }

    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;

        // Basic validation
        if (input != .object) return false;

        // Check for required fields based on wrapper type
        if (input.object.get("input_data") == null) return false;

        // Validate mode if present
        if (input.object.get("mode")) |mode| {
            if (mode != .string) return false;
            const execution_mode = std.meta.stringToEnum(ExecutionMode, mode.string) orelse return false;
            _ = execution_mode;
        }

        return true;
    }

    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(WrapperTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

        // Clean up execution contexts
        var iter = self.execution_contexts.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.execution_contexts.deinit();

        // Clean up wrapper-specific data
        if (self.agent_wrapper) |*wrapper| {
            wrapper.deinit(self.allocator);
        }

        if (self.workflow_wrapper) |*wrapper| {
            wrapper.deinit(self.allocator);
        }

        self.allocator.destroy(self);
    }

    fn executeAgentSync(self: *WrapperTool, input: std.json.Value, execution_id: []const u8, allocator: std.mem.Allocator) !ToolResult {
        const agent_wrapper = self.agent_wrapper orelse return ToolResult.failure("Agent wrapper not initialized");

        const input_data = input.object.get("input_data") orelse return error.MissingInputData;

        // Create execution context
        var context = ExecutionContext.init(allocator, try allocator.dupe(u8, execution_id));
        defer context.deinit(allocator);

        context.status = .running;

        // Execute agent
        const start_time = std.time.milliTimestamp();
        const agent_result = agent_wrapper.agent_ptr.vtable.run(agent_wrapper.agent_ptr, input_data, allocator) catch |err| {
            context.status = .failed;
            context.error_message = try std.fmt.allocPrint(allocator, "Agent execution failed: {}", .{err});
            return ToolResult.failure(context.error_message.?);
        };

        const duration = std.time.milliTimestamp() - start_time;
        context.status = .completed;

        // Build result
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("execution_id", .{ .string = execution_id });
        try result_obj.put("wrapper_type", .{ .string = "agent" });
        try result_obj.put("agent_name", .{ .string = agent_wrapper.name });
        try result_obj.put("result", agent_result);
        try result_obj.put("duration_ms", .{ .integer = duration });
        try result_obj.put("status", .{ .string = @tagName(context.status) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeAgentAsync(self: *WrapperTool, input: std.json.Value, execution_id: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        // For now, return not implemented
        // In a full implementation, this would spawn a thread
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("execution_id", .{ .string = execution_id });
        try result_obj.put("status", .{ .string = "pending" });
        try result_obj.put("message", .{ .string = "Asynchronous execution not yet implemented" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeAgentStreaming(self: *WrapperTool, input: std.json.Value, execution_id: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        // For now, return not implemented
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("execution_id", .{ .string = execution_id });
        try result_obj.put("status", .{ .string = "not_supported" });
        try result_obj.put("message", .{ .string = "Streaming execution not yet implemented" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeWorkflowSync(self: *WrapperTool, input: std.json.Value, execution_id: []const u8, allocator: std.mem.Allocator) !ToolResult {
        const workflow_wrapper = self.workflow_wrapper orelse return ToolResult.failure("Workflow wrapper not initialized");

        const input_data = input.object.get("input_data") orelse return error.MissingInputData;

        // Create execution context
        var context = ExecutionContext.init(allocator, try allocator.dupe(u8, execution_id));
        defer context.deinit(allocator);

        context.status = .running;

        // Execute workflow
        const start_time = std.time.milliTimestamp();
        const workflow_result = workflow_wrapper.workflow_ptr.vtable.execute(workflow_wrapper.workflow_ptr, input_data, allocator) catch |err| {
            context.status = .failed;
            context.error_message = try std.fmt.allocPrint(allocator, "Workflow execution failed: {}", .{err});
            return ToolResult.failure(context.error_message.?);
        };

        const duration = std.time.milliTimestamp() - start_time;
        context.status = .completed;

        // Build result
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("execution_id", .{ .string = execution_id });
        try result_obj.put("wrapper_type", .{ .string = "workflow" });
        try result_obj.put("workflow_name", .{ .string = workflow_wrapper.name });
        try result_obj.put("result", workflow_result);
        try result_obj.put("duration_ms", .{ .integer = duration });
        try result_obj.put("status", .{ .string = @tagName(context.status) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeWorkflowAsync(self: *WrapperTool, input: std.json.Value, execution_id: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        // For now, return not implemented
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("execution_id", .{ .string = execution_id });
        try result_obj.put("status", .{ .string = "pending" });
        try result_obj.put("message", .{ .string = "Asynchronous workflow execution not yet implemented" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeWorkflowStreaming(self: *WrapperTool, input: std.json.Value, execution_id: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        // For now, return not implemented
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("execution_id", .{ .string = execution_id });
        try result_obj.put("status", .{ .string = "not_supported" });
        try result_obj.put("message", .{ .string = "Streaming workflow execution not yet implemented" });

        return ToolResult.success(.{ .object = result_obj });
    }
};

// Helper functions for schema creation
fn createAgentInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var input_data_prop = std.json.ObjectMap.init(allocator);
    try input_data_prop.put("type", .{ .string = "object" });
    try input_data_prop.put("description", .{ .string = "Input data for the agent" });
    try properties.put("input_data", .{ .object = input_data_prop });

    var mode_prop = std.json.ObjectMap.init(allocator);
    try mode_prop.put("type", .{ .string = "string" });
    try mode_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "synchronous" },
        .{ .string = "asynchronous" },
        .{ .string = "streaming" },
    })) });
    try mode_prop.put("description", .{ .string = "Execution mode" });
    try properties.put("mode", .{ .object = mode_prop });

    var timeout_prop = std.json.ObjectMap.init(allocator);
    try timeout_prop.put("type", .{ .string = "integer" });
    try timeout_prop.put("description", .{ .string = "Timeout in seconds" });
    try properties.put("timeout", .{ .object = timeout_prop });

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "input_data" },
    })) });

    return .{ .object = schema };
}

fn createWorkflowInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var input_data_prop = std.json.ObjectMap.init(allocator);
    try input_data_prop.put("type", .{ .string = "object" });
    try input_data_prop.put("description", .{ .string = "Input parameters for the workflow" });
    try properties.put("input_data", .{ .object = input_data_prop });

    var mode_prop = std.json.ObjectMap.init(allocator);
    try mode_prop.put("type", .{ .string = "string" });
    try mode_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "synchronous" },
        .{ .string = "asynchronous" },
        .{ .string = "streaming" },
    })) });
    try mode_prop.put("description", .{ .string = "Execution mode" });
    try properties.put("mode", .{ .object = mode_prop });

    var step_params_prop = std.json.ObjectMap.init(allocator);
    try step_params_prop.put("type", .{ .string = "object" });
    try step_params_prop.put("description", .{ .string = "Step-specific parameters" });
    try properties.put("step_params", .{ .object = step_params_prop });

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "input_data" },
    })) });

    return .{ .object = schema };
}

fn createOutputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var success_prop = std.json.ObjectMap.init(allocator);
    try success_prop.put("type", .{ .string = "boolean" });
    try properties.put("success", .{ .object = success_prop });

    var data_prop = std.json.ObjectMap.init(allocator);
    try data_prop.put("type", .{ .string = "object" });

    var data_props = std.json.ObjectMap.init(allocator);

    var execution_id_prop = std.json.ObjectMap.init(allocator);
    try execution_id_prop.put("type", .{ .string = "string" });
    try data_props.put("execution_id", .{ .object = execution_id_prop });

    var result_prop = std.json.ObjectMap.init(allocator);
    try result_prop.put("type", .{ .string = "object" });
    try data_props.put("result", .{ .object = result_prop });

    var status_prop = std.json.ObjectMap.init(allocator);
    try status_prop.put("type", .{ .string = "string" });
    try data_props.put("status", .{ .object = status_prop });

    var duration_prop = std.json.ObjectMap.init(allocator);
    try duration_prop.put("type", .{ .string = "integer" });
    try data_props.put("duration_ms", .{ .object = duration_prop });

    try data_prop.put("properties", .{ .object = data_props });
    try properties.put("data", .{ .object = data_prop });

    var error_prop = std.json.ObjectMap.init(allocator);
    try error_prop.put("type", .{ .string = "string" });
    try properties.put("error", .{ .object = error_prop });

    try schema.put("properties", .{ .object = properties });

    return .{ .object = schema };
}

fn createExampleAgentInput(allocator: std.mem.Allocator, message: []const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);

    var input_data = std.json.ObjectMap.init(allocator);
    try input_data.put("message", .{ .string = message });
    try input.put("input_data", .{ .object = input_data });

    try input.put("mode", .{ .string = "synchronous" });

    return input;
}

fn createExampleWorkflowInput(allocator: std.mem.Allocator, task: []const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);

    var input_data = std.json.ObjectMap.init(allocator);
    try input_data.put("task", .{ .string = task });
    try input.put("input_data", .{ .object = input_data });

    try input.put("mode", .{ .string = "synchronous" });

    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, message: []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });

    var data = std.json.ObjectMap.init(allocator);
    try data.put("message", .{ .string = message });
    try data.put("execution_id", .{ .string = "example_123" });
    try data.put("status", .{ .string = "completed" });
    try data.put("duration_ms", .{ .integer = 100 });

    try output.put("data", .{ .object = data });

    return output;
}

// Builder functions for easy creation
pub fn createAgentWrapper(
    allocator: std.mem.Allocator,
    agent_ptr: *Agent,
    config: WrapperConfig,
    name: []const u8,
    description: []const u8,
) !*Tool {
    const wrapper_tool = try WrapperTool.initAgent(allocator, agent_ptr, config, name, description);
    return &wrapper_tool.base.tool;
}

pub fn createWorkflowWrapper(
    allocator: std.mem.Allocator,
    workflow_ptr: *Workflow,
    config: WrapperConfig,
    name: []const u8,
    description: []const u8,
) !*Tool {
    const wrapper_tool = try WrapperTool.initWorkflow(allocator, workflow_ptr, config, name, description);
    return &wrapper_tool.base.tool;
}

// Tests
test "agent wrapper creation" {
    const allocator = std.testing.allocator;

    // Create a mock agent
    var mock_agent = BaseAgent.init(allocator, .{});
    defer mock_agent.deinit();

    const tool_ptr = try createAgentWrapper(allocator, &mock_agent.agent, .{}, "test_agent", "A test agent");
    defer tool_ptr.deinit();

    try std.testing.expect(std.mem.startsWith(u8, tool_ptr.metadata.name, "agent_"));
}

test "workflow wrapper creation" {
    const allocator = std.testing.allocator;

    // Create a mock workflow
    var mock_workflow = try Workflow.init(allocator, "test_workflow");
    defer mock_workflow.deinit();

    const tool_ptr = try createWorkflowWrapper(allocator, mock_workflow, .{}, "test_workflow", "A test workflow");
    defer tool_ptr.deinit();

    try std.testing.expect(std.mem.startsWith(u8, tool_ptr.metadata.name, "workflow_"));
}

test "wrapper tool validation" {
    const allocator = std.testing.allocator;

    // Create a mock agent
    var mock_agent = BaseAgent.init(allocator, .{});
    defer mock_agent.deinit();

    const tool_ptr = try createAgentWrapper(allocator, &mock_agent.agent, .{}, "test_agent", "A test agent");
    defer tool_ptr.deinit();

    // Valid input
    var valid_input = std.json.ObjectMap.init(allocator);
    defer valid_input.deinit();

    var input_data = std.json.ObjectMap.init(allocator);
    defer input_data.deinit();
    try input_data.put("message", .{ .string = "test" });
    try valid_input.put("input_data", .{ .object = input_data });

    const valid = try tool_ptr.validate(.{ .object = valid_input }, allocator);
    try std.testing.expect(valid);

    // Invalid input (missing input_data)
    var invalid_input = std.json.ObjectMap.init(allocator);
    defer invalid_input.deinit();
    try invalid_input.put("mode", .{ .string = "synchronous" });

    const invalid = try tool_ptr.validate(.{ .object = invalid_input }, allocator);
    try std.testing.expect(!invalid);
}
