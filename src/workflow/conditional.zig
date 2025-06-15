// ABOUTME: Conditional workflow implementation for branching logic in workflows
// ABOUTME: Provides if/then/else logic with expression evaluation and nested workflows

const std = @import("std");
const definition = @import("definition.zig");
const sequential = @import("sequential.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const ConditionStepConfig = definition.ConditionStepConfig;
const ConditionExpression = definition.ConditionExpression;
const SequentialWorkflowExecutor = sequential.SequentialWorkflowExecutor;
const RunContext = @import("../context.zig").RunContext;

// Conditional execution result
pub const ConditionalExecutionResult = struct {
    success: bool,
    condition_result: bool,
    executed_branch: Branch,
    step_results: std.StringHashMap(std.json.Value),
    execution_time_ms: u64,
    error_message: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    
    pub const Branch = enum {
        none,
        true_branch,
        false_branch,
    };
    
    pub fn deinit(self: *ConditionalExecutionResult) void {
        var iter = self.step_results.iterator();
        while (iter.next()) |entry| {
            _ = entry; // Results managed by context
        }
        self.step_results.deinit();
        
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }
    
    pub fn toJson(self: *ConditionalExecutionResult) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        try obj.put("success", .{ .bool = self.success });
        try obj.put("condition_result", .{ .bool = self.condition_result });
        try obj.put("executed_branch", .{ .string = @tagName(self.executed_branch) });
        try obj.put("execution_time_ms", .{ .integer = @as(i64, @intCast(self.execution_time_ms)) });
        
        if (self.error_message) |msg| {
            try obj.put("error_message", .{ .string = msg });
        }
        
        // Step results
        var results_obj = std.json.ObjectMap.init(self.allocator);
        var iter = self.step_results.iterator();
        while (iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("step_results", .{ .object = results_obj });
        
        return .{ .object = obj };
    }
};

// Conditional workflow executor
pub const ConditionalWorkflowExecutor = struct {
    allocator: std.mem.Allocator,
    sequential_executor: SequentialWorkflowExecutor,
    
    pub fn init(allocator: std.mem.Allocator) ConditionalWorkflowExecutor {
        return .{
            .allocator = allocator,
            .sequential_executor = SequentialWorkflowExecutor.init(allocator),
        };
    }
    
    pub fn executeConditionalStep(
        self: *ConditionalWorkflowExecutor,
        config: ConditionStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !ConditionalExecutionResult {
        const start_time = std.time.milliTimestamp();
        
        var result = ConditionalExecutionResult{
            .success = true,
            .condition_result = false,
            .executed_branch = .none,
            .step_results = std.StringHashMap(std.json.Value).init(self.allocator),
            .execution_time_ms = 0,
            .allocator = self.allocator,
        };
        
        // Evaluate condition
        const context_data = try self.getContextAsJson(execution_context);
        defer context_data.deinit(self.allocator);
        
        const condition_result = config.condition.evaluate(context_data, self.allocator) catch |err| {
            result.success = false;
            result.error_message = try std.fmt.allocPrint(self.allocator, 
                "Condition evaluation failed: {s}", .{@errorName(err)});
            result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
            return result;
        };
        
        result.condition_result = condition_result;
        
        // Execute appropriate branch
        const steps_to_execute = if (condition_result) blk: {
            result.executed_branch = .true_branch;
            break :blk config.true_steps;
        } else blk: {
            result.executed_branch = .false_branch;
            break :blk config.false_steps;
        };
        
        if (steps_to_execute.len > 0) {
            // Create a temporary workflow for the steps
            var branch_workflow = WorkflowDefinition.init(self.allocator, "conditional_branch", "Conditional Branch");
            defer branch_workflow.deinit();
            
            branch_workflow.steps = steps_to_execute;
            
            // Execute the branch using sequential executor
            const current_input = execution_context.getVariable("input") orelse .{ .null = {} };
            var branch_result = self.sequential_executor.execute(&branch_workflow, current_input, run_context) catch |err| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator,
                    "Branch execution failed: {s}", .{@errorName(err)});
                result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
                return result;
            };
            defer branch_result.deinit();
            
            if (!branch_result.success) {
                result.success = false;
                result.error_message = if (branch_result.error_message) |msg|
                    try self.allocator.dupe(u8, msg)
                else
                    try self.allocator.dupe(u8, "Branch execution failed");
            }
            
            // Copy step results
            var iter = branch_result.step_results.iterator();
            while (iter.next()) |entry| {
                try result.step_results.put(entry.key_ptr.*, entry.value_ptr.*);
                try execution_context.setStepResult(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        
        result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        return result;
    }
    
    fn getContextAsJson(self: *ConditionalWorkflowExecutor, context: *WorkflowExecutionContext) !std.json.Parsed(std.json.Value) {
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
        
        // Add execution state
        try obj.put("execution_state", .{ .string = @tagName(context.execution_state) });
        
        if (context.current_step) |step| {
            try obj.put("current_step", .{ .string = step });
        }
        
        const json_value = std.json.Value{ .object = obj };
        
        // Convert to string and parse back to get a Parsed value
        const json_string = try std.json.stringifyAlloc(self.allocator, json_value, .{});
        defer self.allocator.free(json_string);
        
        return std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
    }
};

// Simple expression evaluator for conditional logic
pub const SimpleExpressionEvaluator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) SimpleExpressionEvaluator {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn evaluate(self: *SimpleExpressionEvaluator, expression: []const u8, context: std.json.Value) !bool {
        // Parse simple expressions like:
        // - "variables.count > 5"
        // - "step_results.step1.success == true"
        // - "variables.status == 'ready'"
        
        var tokens = std.mem.tokenize(u8, expression, " ");
        
        const left_path = tokens.next() orelse return error.InvalidExpression;
        const operator = tokens.next() orelse return error.InvalidExpression;
        const right_value = tokens.next() orelse return error.InvalidExpression;
        
        // Extract value from context using path
        const left_value = try self.getValueByPath(context, left_path);
        
        // Parse right value
        const right_parsed = try self.parseValue(right_value);
        
        // Perform comparison
        return self.compareValues(left_value, operator, right_parsed);
    }
    
    fn getValueByPath(self: *SimpleExpressionEvaluator, context: std.json.Value, path: []const u8) !std.json.Value {
        _ = self;
        
        var current = context;
        var path_iter = std.mem.tokenize(u8, path, ".");
        
        while (path_iter.next()) |segment| {
            switch (current) {
                .object => |obj| {
                    current = obj.get(segment) orelse return error.PathNotFound;
                },
                else => return error.InvalidPath,
            }
        }
        
        return current;
    }
    
    fn parseValue(self: *SimpleExpressionEvaluator, value_str: []const u8) !std.json.Value {
        _ = self;
        
        // Try to parse as different types
        if (std.mem.eql(u8, value_str, "true")) {
            return .{ .bool = true };
        } else if (std.mem.eql(u8, value_str, "false")) {
            return .{ .bool = false };
        } else if (std.mem.eql(u8, value_str, "null")) {
            return .{ .null = {} };
        } else if (std.fmt.parseInt(i64, value_str, 10)) |int_val| {
            return .{ .integer = int_val };
        } else |_| {
            if (std.fmt.parseFloat(f64, value_str)) |float_val| {
                return .{ .float = float_val };
            } else |_| {
                // Treat as string, removing quotes if present
                const trimmed = std.mem.trim(u8, value_str, "'\"");
                return .{ .string = trimmed };
            }
        }
    }
    
    fn compareValues(self: *SimpleExpressionEvaluator, left: std.json.Value, operator: []const u8, right: std.json.Value) !bool {
        
        if (std.mem.eql(u8, operator, "==")) {
            return self.valuesEqual(left, right);
        } else if (std.mem.eql(u8, operator, "!=")) {
            return !self.valuesEqual(left, right);
        } else if (std.mem.eql(u8, operator, ">")) {
            return try self.compareNumbers(left, right, .greater);
        } else if (std.mem.eql(u8, operator, "<")) {
            return try self.compareNumbers(left, right, .less);
        } else if (std.mem.eql(u8, operator, ">=")) {
            return try self.compareNumbers(left, right, .greater_equal);
        } else if (std.mem.eql(u8, operator, "<=")) {
            return try self.compareNumbers(left, right, .less_equal);
        } else {
            return error.UnsupportedOperator;
        }
    }
    
    fn valuesEqual(self: *SimpleExpressionEvaluator, left: std.json.Value, right: std.json.Value) bool {
        _ = self;
        
        const left_tag = std.meta.activeTag(left);
        const right_tag = std.meta.activeTag(right);
        
        if (left_tag != right_tag) return false;
        
        return switch (left) {
            .null => true,
            .bool => |l| l == right.bool,
            .integer => |l| l == right.integer,
            .float => |l| l == right.float,
            .string => |l| std.mem.eql(u8, l, right.string),
            else => false, // Arrays and objects not supported for equality
        };
    }
    
    fn compareNumbers(self: *SimpleExpressionEvaluator, left: std.json.Value, right: std.json.Value, comptime op: enum { greater, less, greater_equal, less_equal }) !bool {
        _ = self;
        
        const left_num = switch (left) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return error.NotANumber,
        };
        
        const right_num = switch (right) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return error.NotANumber,
        };
        
        return switch (op) {
            .greater => left_num > right_num,
            .less => left_num < right_num,
            .greater_equal => left_num >= right_num,
            .less_equal => left_num <= right_num,
        };
    }
};

// Enhanced condition expression evaluation
pub fn evaluateSimpleExpression(expression: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !bool {
    var evaluator = SimpleExpressionEvaluator.init(allocator);
    return evaluator.evaluate(expression, context);
}

pub fn evaluateJsonPathExpression(expression: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !bool {
    _ = expression;
    _ = context;
    _ = allocator;
    // TODO: Implement JSONPath evaluation
    return true;
}

pub fn evaluateJavaScriptExpression(expression: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !bool {
    _ = expression;
    _ = context;
    _ = allocator;
    // TODO: Implement JavaScript evaluation (would need a JS engine)
    return true;
}

// Tests
test "simple expression evaluator" {
    const allocator = std.testing.allocator;
    
    var context_obj = std.json.ObjectMap.init(allocator);
    defer context_obj.deinit();
    
    var variables_obj = std.json.ObjectMap.init(allocator);
    try variables_obj.put("count", .{ .integer = 10 });
    try variables_obj.put("status", .{ .string = "ready" });
    try context_obj.put("variables", .{ .object = variables_obj });
    
    const context = std.json.Value{ .object = context_obj };
    
    var evaluator = SimpleExpressionEvaluator.init(allocator);
    
    // Test numeric comparison
    try std.testing.expect(try evaluator.evaluate("variables.count > 5", context));
    try std.testing.expect(!try evaluator.evaluate("variables.count < 5", context));
    try std.testing.expect(try evaluator.evaluate("variables.count == 10", context));
    
    // Test string comparison
    try std.testing.expect(try evaluator.evaluate("variables.status == ready", context));
    try std.testing.expect(!try evaluator.evaluate("variables.status == waiting", context));
}

test "conditional execution" {
    const allocator = std.testing.allocator;
    
    var executor = ConditionalWorkflowExecutor.init(allocator);
    
    // Create test execution context
    var workflow = WorkflowDefinition.init(allocator, "test", "Test");
    defer workflow.deinit();
    
    var context = WorkflowExecutionContext.init(allocator, &workflow);
    defer context.deinit();
    
    try context.setVariable("count", .{ .integer = 15 });
    
    // Create conditional step
    const true_steps = [_]WorkflowStep{
        .{
            .id = "true_step",
            .name = "True Step",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 1 } },
        },
    };
    
    const config = ConditionStepConfig{
        .condition = .{
            .expression_type = .simple,
            .expression = "variables.count > 10",
        },
        .true_steps = &true_steps,
        .false_steps = &[_]WorkflowStep{},
    };
    
    var run_context = RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();
    
    var result = try executor.executeConditionalStep(config, &context, &run_context);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expect(result.condition_result);
    try std.testing.expectEqual(ConditionalExecutionResult.Branch.true_branch, result.executed_branch);
}