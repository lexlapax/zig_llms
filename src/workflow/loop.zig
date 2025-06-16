// ABOUTME: Loop workflow implementation for iterative execution patterns
// ABOUTME: Supports while, for, and foreach loops with break conditions and iteration tracking

const std = @import("std");
const definition = @import("definition.zig");
const sequential = @import("sequential.zig");
const conditional = @import("conditional.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const LoopStepConfig = definition.LoopStepConfig;
const ConditionExpression = definition.ConditionExpression;
const SequentialWorkflowExecutor = sequential.SequentialWorkflowExecutor;
const RunContext = @import("../context.zig").RunContext;

// Loop execution result
pub const LoopExecutionResult = struct {
    success: bool,
    iterations_completed: u32,
    loop_type: LoopStepConfig.LoopType,
    break_reason: BreakReason,
    iteration_results: std.ArrayList(std.json.Value),
    execution_time_ms: u64,
    error_message: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub const BreakReason = enum {
        condition_false,
        max_iterations_reached,
        iteration_error,
        timeout,
        explicit_break,
        completed_naturally,
    };

    pub fn deinit(self: *LoopExecutionResult) void {
        for (self.iteration_results.items) |result| {
            _ = result; // Results managed by context
        }
        self.iteration_results.deinit();

        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn toJson(self: *LoopExecutionResult) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();

        try obj.put("success", .{ .bool = self.success });
        try obj.put("iterations_completed", .{ .integer = @as(i64, @intCast(self.iterations_completed)) });
        try obj.put("loop_type", .{ .string = @tagName(self.loop_type) });
        try obj.put("break_reason", .{ .string = @tagName(self.break_reason) });
        try obj.put("execution_time_ms", .{ .integer = @as(i64, @intCast(self.execution_time_ms)) });

        if (self.error_message) |msg| {
            try obj.put("error_message", .{ .string = msg });
        }

        // Iteration results
        var results_array = std.json.Array.init(self.allocator);
        for (self.iteration_results.items) |result| {
            try results_array.append(result);
        }
        try obj.put("iteration_results", .{ .array = results_array });

        return .{ .object = obj };
    }
};

// Loop workflow executor
pub const LoopWorkflowExecutor = struct {
    allocator: std.mem.Allocator,
    sequential_executor: SequentialWorkflowExecutor,
    config: ExecutorConfig = .{},

    pub const ExecutorConfig = struct {
        max_iterations: u32 = 1000,
        timeout_ms: ?u32 = null,
        break_on_error: bool = true,
        collect_iteration_results: bool = true,
        iteration_delay_ms: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) LoopWorkflowExecutor {
        return .{
            .allocator = allocator,
            .sequential_executor = SequentialWorkflowExecutor.init(allocator),
        };
    }

    pub fn executeLoopStep(
        self: *LoopWorkflowExecutor,
        config: LoopStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !LoopExecutionResult {
        const start_time = std.time.milliTimestamp();

        var result = LoopExecutionResult{
            .success = true,
            .iterations_completed = 0,
            .loop_type = config.loop_type,
            .break_reason = .completed_naturally,
            .iteration_results = std.ArrayList(std.json.Value).init(self.allocator),
            .execution_time_ms = 0,
            .allocator = self.allocator,
        };

        const max_iterations = config.max_iterations orelse self.config.max_iterations;

        switch (config.loop_type) {
            .while_loop => try self.executeWhileLoop(config, execution_context, run_context, &result, max_iterations, start_time),
            .for_loop => try self.executeForLoop(config, execution_context, run_context, &result, max_iterations, start_time),
            .foreach_loop => try self.executeForeachLoop(config, execution_context, run_context, &result, max_iterations, start_time),
        }

        result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        return result;
    }

    fn executeWhileLoop(
        self: *LoopWorkflowExecutor,
        config: LoopStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
        result: *LoopExecutionResult,
        max_iterations: u32,
        start_time: i64,
    ) !void {
        const condition = config.condition orelse {
            result.success = false;
            result.error_message = try self.allocator.dupe(u8, "While loop requires condition");
            return;
        };

        while (result.iterations_completed < max_iterations) {
            // Check timeout
            if (self.config.timeout_ms) |timeout| {
                const elapsed = @as(u32, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed > timeout) {
                    result.break_reason = .timeout;
                    break;
                }
            }

            // Evaluate condition
            const context_data = try self.getContextAsJson(execution_context);
            defer context_data.deinit();

            const should_continue = condition.evaluate(context_data.value, self.allocator) catch |err| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, "Condition evaluation failed: {s}", .{@errorName(err)});
                result.break_reason = .iteration_error;
                return;
            };

            if (!should_continue) {
                result.break_reason = .condition_false;
                break;
            }

            // Execute iteration
            const iteration_result = self.executeIteration(config.steps, execution_context, run_context, result.iterations_completed) catch |err| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, "Iteration {d} failed: {s}", .{ result.iterations_completed, @errorName(err) });
                result.break_reason = .iteration_error;

                if (self.config.break_on_error) {
                    return;
                }
                continue;
            };

            if (self.config.collect_iteration_results) {
                try result.iteration_results.append(iteration_result);
            }

            result.iterations_completed += 1;

            // Add delay between iterations
            if (self.config.iteration_delay_ms > 0) {
                std.time.sleep(self.config.iteration_delay_ms * std.time.ns_per_ms);
            }
        }

        if (result.iterations_completed >= max_iterations) {
            result.break_reason = .max_iterations_reached;
        }
    }

    fn executeForLoop(
        self: *LoopWorkflowExecutor,
        config: LoopStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
        result: *LoopExecutionResult,
        max_iterations: u32,
        start_time: i64,
    ) !void {
        // For loop executes a fixed number of iterations
        const iterations = @min(max_iterations, 100); // Default to 100 if not specified

        for (0..iterations) |i| {
            // Check timeout
            if (self.config.timeout_ms) |timeout| {
                const elapsed = @as(u32, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed > timeout) {
                    result.break_reason = .timeout;
                    break;
                }
            }

            // Set iteration variable
            try execution_context.setVariable("loop_index", .{ .integer = @as(i64, @intCast(i)) });

            // Execute iteration
            const iteration_result = self.executeIteration(config.steps, execution_context, run_context, @as(u32, @intCast(i))) catch |err| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, "Iteration {d} failed: {s}", .{ i, @errorName(err) });
                result.break_reason = .iteration_error;

                if (self.config.break_on_error) {
                    return;
                }
                continue;
            };

            if (self.config.collect_iteration_results) {
                try result.iteration_results.append(iteration_result);
            }

            result.iterations_completed += 1;

            // Add delay between iterations
            if (self.config.iteration_delay_ms > 0) {
                std.time.sleep(self.config.iteration_delay_ms * std.time.ns_per_ms);
            }
        }
    }

    fn executeForeachLoop(
        self: *LoopWorkflowExecutor,
        config: LoopStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
        result: *LoopExecutionResult,
        max_iterations: u32,
        start_time: i64,
    ) !void {
        // Get iterable from context (assume it's in variables.items)
        const items = execution_context.getVariable("items") orelse {
            result.success = false;
            result.error_message = try self.allocator.dupe(u8, "Foreach loop requires 'items' variable");
            return;
        };

        const items_array = switch (items) {
            .array => |arr| arr,
            else => {
                result.success = false;
                result.error_message = try self.allocator.dupe(u8, "Foreach loop 'items' must be an array");
                return;
            },
        };

        const iteration_count = @min(@as(u32, @intCast(items_array.items.len)), max_iterations);

        for (items_array.items[0..iteration_count], 0..) |item, i| {
            // Check timeout
            if (self.config.timeout_ms) |timeout| {
                const elapsed = @as(u32, @intCast(std.time.milliTimestamp() - start_time));
                if (elapsed > timeout) {
                    result.break_reason = .timeout;
                    break;
                }
            }

            // Set loop variables
            try execution_context.setVariable("loop_index", .{ .integer = @as(i64, @intCast(i)) });
            try execution_context.setVariable("loop_item", item);

            // Execute iteration
            const iteration_result = self.executeIteration(config.steps, execution_context, run_context, @as(u32, @intCast(i))) catch |err| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, "Iteration {d} failed: {s}", .{ i, @errorName(err) });
                result.break_reason = .iteration_error;

                if (self.config.break_on_error) {
                    return;
                }
                continue;
            };

            if (self.config.collect_iteration_results) {
                try result.iteration_results.append(iteration_result);
            }

            result.iterations_completed += 1;

            // Add delay between iterations
            if (self.config.iteration_delay_ms > 0) {
                std.time.sleep(self.config.iteration_delay_ms * std.time.ns_per_ms);
            }
        }
    }

    fn executeIteration(
        self: *LoopWorkflowExecutor,
        steps: []const WorkflowStep,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
        iteration_index: u32,
    ) !std.json.Value {
        // Create a temporary workflow for the iteration
        var iteration_workflow = WorkflowDefinition.init(self.allocator, "loop_iteration", "Loop Iteration");
        defer iteration_workflow.deinit();

        iteration_workflow.steps = steps;

        // Execute iteration using sequential executor
        const current_input = execution_context.getVariable("input") orelse .{ .null = {} };
        var iteration_result = try self.sequential_executor.execute(&iteration_workflow, current_input, run_context);
        defer iteration_result.deinit();

        if (!iteration_result.success) {
            return error.IterationFailed;
        }

        // Update execution context with iteration results
        var iter = iteration_result.step_results.iterator();
        while (iter.next()) |entry| {
            const step_key = try std.fmt.allocPrint(self.allocator, "iter_{d}_{s}", .{ iteration_index, entry.key_ptr.* });
            defer self.allocator.free(step_key);
            try execution_context.setStepResult(step_key, entry.value_ptr.*);
        }

        return try iteration_result.toJson();
    }

    fn getContextAsJson(self: *LoopWorkflowExecutor, context: *WorkflowExecutionContext) !std.json.Parsed(std.json.Value) {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();

        // Add variables
        var variables_obj = std.json.ObjectMap.init(self.allocator);
        var var_iter = context.variables.iterator();
        while (var_iter.next()) |entry| {
            try variables_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("variables", .{ .object = variables_obj });

        // Add step results
        var results_obj = std.json.ObjectMap.init(self.allocator);
        var result_iter = context.step_results.iterator();
        while (result_iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("step_results", .{ .object = results_obj });

        const json_value = std.json.Value{ .object = obj };

        // Convert to string and parse back
        const json_string = try std.json.stringifyAlloc(self.allocator, json_value, .{});
        defer self.allocator.free(json_string);

        return std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
    }
};

// Tests
test "for loop execution" {
    const allocator = std.testing.allocator;

    var executor = LoopWorkflowExecutor.init(allocator);
    executor.config.max_iterations = 3;

    // Create test execution context
    var workflow = WorkflowDefinition.init(allocator, "test", "Test");
    defer workflow.deinit();

    var context = WorkflowExecutionContext.init(allocator, &workflow);
    defer context.deinit();

    // Create loop step with delay
    const loop_steps = [_]WorkflowStep{
        .{
            .id = "delay_step",
            .name = "Delay Step",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 1 } },
        },
    };

    const config = LoopStepConfig{
        .loop_type = .for_loop,
        .condition = null,
        .max_iterations = 3,
        .steps = &loop_steps,
    };

    var run_context = RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();

    var result = try executor.executeLoopStep(config, &context, &run_context);
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 3), result.iterations_completed);
    try std.testing.expectEqual(LoopStepConfig.LoopType.for_loop, result.loop_type);
    try std.testing.expectEqual(LoopExecutionResult.BreakReason.completed_naturally, result.break_reason);
    try std.testing.expectEqual(@as(usize, 3), result.iteration_results.items.len);
}

test "foreach loop execution" {
    const allocator = std.testing.allocator;

    var executor = LoopWorkflowExecutor.init(allocator);

    // Create test execution context
    var workflow = WorkflowDefinition.init(allocator, "test", "Test");
    defer workflow.deinit();

    var context = WorkflowExecutionContext.init(allocator, &workflow);
    defer context.deinit();

    // Set up items to iterate over
    var items_array = std.json.Array.init(allocator);
    defer items_array.deinit();

    try items_array.append(.{ .string = "item1" });
    try items_array.append(.{ .string = "item2" });
    try items_array.append(.{ .string = "item3" });

    try context.setVariable("items", .{ .array = items_array });

    // Create loop step
    const loop_steps = [_]WorkflowStep{
        .{
            .id = "process_item",
            .name = "Process Item",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 1 } },
        },
    };

    const config = LoopStepConfig{
        .loop_type = .foreach_loop,
        .condition = null,
        .max_iterations = null,
        .steps = &loop_steps,
    };

    var run_context = RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();

    var result = try executor.executeLoopStep(config, &context, &run_context);
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 3), result.iterations_completed);
    try std.testing.expectEqual(LoopStepConfig.LoopType.foreach_loop, result.loop_type);
}
