// ABOUTME: Workflow composition support for embedding workflows within workflows
// ABOUTME: Enables building complex workflows from simpler sub-workflows with parameter mapping

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const WorkflowAgent = definition.WorkflowAgent;
const RunContext = @import("../context.zig").RunContext;
const Agent = @import("../agent.zig").Agent;

// Workflow composition configuration
pub const WorkflowComposition = struct {
    // Sub-workflow reference
    workflow_id: []const u8,
    workflow: ?*WorkflowDefinition = null,
    
    // Parameter mapping
    input_mapping: ?ParameterMapping = null,
    output_mapping: ?ParameterMapping = null,
    
    // Execution options
    inherit_context: bool = true,
    isolate_state: bool = false,
    timeout_override: ?u32 = null,
    
    // Error handling
    on_error: ErrorStrategy = .propagate,
    retry_config: ?RetryConfig = null,
    
    pub const ParameterMapping = struct {
        mappings: std.StringHashMap(MappingRule),
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) ParameterMapping {
            return .{
                .mappings = std.StringHashMap(MappingRule).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *ParameterMapping) void {
            var iter = self.mappings.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.mappings.deinit();
        }
        
        pub fn addMapping(self: *ParameterMapping, target: []const u8, rule: MappingRule) !void {
            try self.mappings.put(target, rule);
        }
        
        pub fn applyMappings(self: *const ParameterMapping, source: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
            var result = std.json.ObjectMap.init(allocator);
            errdefer result.deinit();
            
            var iter = self.mappings.iterator();
            while (iter.next()) |entry| {
                const value = try entry.value_ptr.apply(source, allocator);
                try result.put(entry.key_ptr.*, value);
            }
            
            return .{ .object = result };
        }
    };
    
    pub const MappingRule = struct {
        rule_type: RuleType,
        
        pub const RuleType = union(enum) {
            direct: []const u8,           // Direct field mapping
            path: []const u8,             // JSON path expression
            template: []const u8,         // String template with variables
            transform: TransformFunction,  // Custom transformation
            constant: std.json.Value,     // Constant value
            expression: []const u8,       // Simple expression
        };
        
        pub const TransformFunction = *const fn (value: std.json.Value, allocator: std.mem.Allocator) anyerror!std.json.Value;
        
        pub fn deinit(self: *MappingRule, allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
        
        pub fn apply(self: *const MappingRule, source: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
            return switch (self.rule_type) {
                .direct => |field| getFieldValue(source, field) orelse .{ .null = {} },
                .path => |path| getPathValue(source, path) orelse .{ .null = {} },
                .template => |tmpl| try applyTemplate(tmpl, source, allocator),
                .transform => |func| try func(source, allocator),
                .constant => |value| value,
                .expression => |expr| try evaluateExpression(expr, source, allocator),
            };
        }
    };
    
    pub const ErrorStrategy = enum {
        propagate,    // Propagate error to parent workflow
        ignore,       // Continue execution ignoring the error
        use_default,  // Use default value on error
        compensate,   // Run compensation workflow
    };
    
    pub const RetryConfig = struct {
        max_attempts: u8 = 3,
        delay_ms: u32 = 1000,
        backoff_multiplier: f32 = 2.0,
        max_delay_ms: u32 = 60000,
    };
};

// Workflow repository for managing workflow definitions
pub const WorkflowRepository = struct {
    workflows: std.StringHashMap(*WorkflowDefinition),
    allocator: std.mem.Allocator,
    loader: ?WorkflowLoader = null,
    
    pub const WorkflowLoader = *const fn (id: []const u8, allocator: std.mem.Allocator) anyerror!*WorkflowDefinition;
    
    pub fn init(allocator: std.mem.Allocator) WorkflowRepository {
        return .{
            .workflows = std.StringHashMap(*WorkflowDefinition).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WorkflowRepository) void {
        var iter = self.workflows.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.workflows.deinit();
    }
    
    pub fn register(self: *WorkflowRepository, workflow: *WorkflowDefinition) !void {
        try self.workflows.put(workflow.id, workflow);
    }
    
    pub fn unregister(self: *WorkflowRepository, id: []const u8) bool {
        if (self.workflows.fetchRemove(id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            return true;
        }
        return false;
    }
    
    pub fn get(self: *WorkflowRepository, id: []const u8) !*WorkflowDefinition {
        if (self.workflows.get(id)) |workflow| {
            return workflow;
        }
        
        // Try to load if loader is configured
        if (self.loader) |loader| {
            const workflow = try loader(id, self.allocator);
            try self.register(workflow);
            return workflow;
        }
        
        return error.WorkflowNotFound;
    }
    
    pub fn exists(self: *const WorkflowRepository, id: []const u8) bool {
        return self.workflows.contains(id);
    }
};

// Composable workflow step
pub const ComposableWorkflowStep = struct {
    composition: WorkflowComposition,
    repository: *WorkflowRepository,
    
    pub fn execute(
        self: *ComposableWorkflowStep,
        context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        // Get sub-workflow
        const sub_workflow = if (self.composition.workflow) |wf|
            wf
        else
            try self.repository.get(self.composition.workflow_id);
        
        // Apply input mapping
        const current_input = context.getVariable("input") orelse .{ .null = {} };
        const mapped_input = if (self.composition.input_mapping) |mapping|
            try mapping.applyMappings(current_input, context.allocator)
        else
            current_input;
        
        // Create sub-workflow agent
        var sub_agent = try WorkflowAgent.init(
            context.allocator,
            sub_workflow.*,
            .{
                .description = sub_workflow.description,
                .timeout_ms = self.composition.timeout_override orelse 30000,
            },
        );
        defer sub_agent.deinit();
        
        // Execute with retry if configured
        var attempts: u8 = 0;
        const max_attempts = if (self.composition.retry_config) |cfg| cfg.max_attempts else 1;
        var delay_ms = if (self.composition.retry_config) |cfg| cfg.delay_ms else 0;
        
        while (attempts < max_attempts) : (attempts += 1) {
            if (attempts > 0) {
                std.time.sleep(delay_ms * std.time.ns_per_ms);
                
                // Apply backoff
                if (self.composition.retry_config) |cfg| {
                    delay_ms = @min(
                        @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay_ms)) * cfg.backoff_multiplier)),
                        cfg.max_delay_ms
                    );
                }
            }
            
            // Execute sub-workflow
            const result = sub_agent.base.agent.execute(run_context, mapped_input) catch |err| {
                if (attempts >= max_attempts - 1) {
                    return self.handleError(err, context);
                }
                continue;
            };
            
            // Apply output mapping
            if (self.composition.output_mapping) |mapping| {
                return mapping.applyMappings(result, context.allocator);
            }
            
            return result;
        }
        
        unreachable;
    }
    
    fn handleError(self: *ComposableWorkflowStep, err: anyerror, context: *WorkflowExecutionContext) !std.json.Value {
        switch (self.composition.on_error) {
            .propagate => return err,
            .ignore => return .{ .null = {} },
            .use_default => {
                var obj = std.json.ObjectMap.init(context.allocator);
                try obj.put("error", .{ .string = @errorName(err) });
                try obj.put("default_used", .{ .bool = true });
                return .{ .object = obj };
            },
            .compensate => {
                // TODO: Implement compensation workflow execution
                return error.CompensationNotImplemented;
            },
        }
    }
};

// Helper functions
fn getFieldValue(obj: std.json.Value, field: []const u8) ?std.json.Value {
    switch (obj) {
        .object => |o| return o.get(field),
        else => return null,
    }
}

fn getPathValue(obj: std.json.Value, path: []const u8) ?std.json.Value {
    var current = obj;
    var iter = std.mem.tokenize(u8, path, ".");
    
    while (iter.next()) |segment| {
        current = getFieldValue(current, segment) orelse return null;
    }
    
    return current;
}

fn applyTemplate(template: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    while (i < template.len) {
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            // Find closing }}
            if (std.mem.indexOf(u8, template[i + 2..], "}}")) |end_pos| {
                const var_name = template[i + 2 .. i + 2 + end_pos];
                if (getPathValue(context, var_name)) |value| {
                    switch (value) {
                        .string => |s| try result.appendSlice(s),
                        .integer => |n| try result.writer().print("{d}", .{n}),
                        .float => |f| try result.writer().print("{d}", .{f}),
                        .bool => |b| try result.appendSlice(if (b) "true" else "false"),
                        else => try std.json.stringify(value, .{}, result.writer()),
                    }
                }
                i += end_pos + 4; // Skip past }}
                continue;
            }
        }
        
        try result.append(template[i]);
        i += 1;
    }
    
    return .{ .string = try result.toOwnedSlice() };
}

fn evaluateExpression(expr: []const u8, context: std.json.Value, allocator: std.mem.Allocator) !std.json.Value {
    _ = expr;
    _ = context;
    _ = allocator;
    // TODO: Implement simple expression evaluation
    return error.ExpressionNotImplemented;
}

// Workflow composition builder
pub const WorkflowCompositionBuilder = struct {
    allocator: std.mem.Allocator,
    composition: WorkflowComposition,
    input_mapping: ?WorkflowComposition.ParameterMapping = null,
    output_mapping: ?WorkflowComposition.ParameterMapping = null,
    
    pub fn init(allocator: std.mem.Allocator, workflow_id: []const u8) WorkflowCompositionBuilder {
        return .{
            .allocator = allocator,
            .composition = .{
                .workflow_id = workflow_id,
            },
        };
    }
    
    pub fn deinit(self: *WorkflowCompositionBuilder) void {
        if (self.input_mapping) |*mapping| {
            mapping.deinit();
        }
        if (self.output_mapping) |*mapping| {
            mapping.deinit();
        }
    }
    
    pub fn withWorkflow(self: *WorkflowCompositionBuilder, workflow: *WorkflowDefinition) *WorkflowCompositionBuilder {
        self.composition.workflow = workflow;
        return self;
    }
    
    pub fn mapInput(self: *WorkflowCompositionBuilder, target: []const u8, rule: WorkflowComposition.MappingRule) !*WorkflowCompositionBuilder {
        if (self.input_mapping == null) {
            self.input_mapping = WorkflowComposition.ParameterMapping.init(self.allocator);
        }
        try self.input_mapping.?.addMapping(target, rule);
        return self;
    }
    
    pub fn mapOutput(self: *WorkflowCompositionBuilder, target: []const u8, rule: WorkflowComposition.MappingRule) !*WorkflowCompositionBuilder {
        if (self.output_mapping == null) {
            self.output_mapping = WorkflowComposition.ParameterMapping.init(self.allocator);
        }
        try self.output_mapping.?.addMapping(target, rule);
        return self;
    }
    
    pub fn withErrorStrategy(self: *WorkflowCompositionBuilder, strategy: WorkflowComposition.ErrorStrategy) *WorkflowCompositionBuilder {
        self.composition.on_error = strategy;
        return self;
    }
    
    pub fn withRetry(self: *WorkflowCompositionBuilder, config: WorkflowComposition.RetryConfig) *WorkflowCompositionBuilder {
        self.composition.retry_config = config;
        return self;
    }
    
    pub fn build(self: *WorkflowCompositionBuilder) WorkflowComposition {
        self.composition.input_mapping = self.input_mapping;
        self.composition.output_mapping = self.output_mapping;
        self.input_mapping = null;
        self.output_mapping = null;
        return self.composition;
    }
};

// Tests
test "workflow composition" {
    const allocator = std.testing.allocator;
    
    // Create repository
    var repo = WorkflowRepository.init(allocator);
    defer repo.deinit();
    
    // Create a simple sub-workflow
    const sub_workflow = try allocator.create(WorkflowDefinition);
    sub_workflow.* = WorkflowDefinition.init(allocator, "sub_workflow", "Sub Workflow");
    
    try repo.register(sub_workflow);
    
    // Create composition
    var builder = WorkflowCompositionBuilder.init(allocator, "sub_workflow");
    defer builder.deinit();
    
    _ = try builder.mapInput("input", .{ .rule_type = .{ .direct = "data" } })
        .withErrorStrategy(.use_default);
    
    const composition = builder.build();
    
    try std.testing.expectEqualStrings("sub_workflow", composition.workflow_id);
    try std.testing.expect(composition.on_error == .use_default);
}

test "parameter mapping" {
    const allocator = std.testing.allocator;
    
    var mapping = WorkflowComposition.ParameterMapping.init(allocator);
    defer mapping.deinit();
    
    try mapping.addMapping("name", .{ .rule_type = .{ .direct = "user.name" } });
    try mapping.addMapping("age", .{ .rule_type = .{ .path = "user.details.age" } });
    try mapping.addMapping("greeting", .{ .rule_type = .{ .template = "Hello, {{user.name}}!" } });
    
    var source = std.json.ObjectMap.init(allocator);
    defer source.deinit();
    
    var user = std.json.ObjectMap.init(allocator);
    try user.put("name", .{ .string = "Alice" });
    
    var details = std.json.ObjectMap.init(allocator);
    try details.put("age", .{ .integer = 30 });
    try user.put("details", .{ .object = details });
    
    try source.put("user", .{ .object = user });
    
    const result = try mapping.applyMappings(.{ .object = source }, allocator);
    
    try std.testing.expect(result == .object);
    const obj = result.object;
    
    try std.testing.expect(obj.get("name").? == .string);
    try std.testing.expectEqualStrings("Alice", obj.get("name").?.string);
    
    try std.testing.expect(obj.get("age").? == .integer);
    try std.testing.expectEqual(@as(i64, 30), obj.get("age").?.integer);
    
    try std.testing.expect(obj.get("greeting").? == .string);
    try std.testing.expectEqualStrings("Hello, Alice!", obj.get("greeting").?.string);
}