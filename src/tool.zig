// ABOUTME: Tool interface definition and execution framework for agent capabilities
// ABOUTME: Provides tool structure, validation, and execution logic for external functionality

const std = @import("std");
const Schema = @import("schema/validator.zig").Schema;
const RunContext = @import("context.zig").RunContext;

pub const Tool = struct {
    metadata: ToolMetadata,
    vtable: *const VTable,
    state: ?*anyopaque = null,

    pub const VTable = struct {
        execute: *const fn (self: *Tool, context: *RunContext, input: std.json.Value) anyerror!std.json.Value,
        validate: *const fn (self: *Tool, input: std.json.Value) anyerror!void,
        cleanup: *const fn (self: *Tool) void,
        describe: *const fn (self: *Tool, allocator: std.mem.Allocator) anyerror![]const u8,
        clone: ?*const fn (self: *Tool, allocator: std.mem.Allocator) anyerror!*Tool = null,
    };

    pub const ToolMetadata = struct {
        name: []const u8,
        description: []const u8,
        input_schema: Schema,
        output_schema: Schema,
        tags: []const []const u8 = &[_][]const u8{},
        version: []const u8 = "1.0.0",
        author: ?[]const u8 = null,
        category: ?ToolCategory = null,
        requires_network: bool = false,
        requires_filesystem: bool = false,
        timeout_ms: ?u32 = null,
        max_retries: u8 = 0,
        examples: []const ToolExample = &[_]ToolExample{},

        pub fn hasTag(self: *const ToolMetadata, tag: []const u8) bool {
            for (self.tags) |t| {
                if (std.mem.eql(u8, t, tag)) return true;
            }
            return false;
        }

        pub fn hasCapability(self: *const ToolMetadata, capability: ToolCapability) bool {
            return switch (capability) {
                .network => self.requires_network,
                .filesystem => self.requires_filesystem,
                .asynchronous => self.timeout_ms != null,
            };
        }
    };

    pub fn execute(self: *Tool, context: *RunContext, input: std.json.Value) !std.json.Value {
        try self.validate(input);
        return self.vtable.execute(self, context, input);
    }

    pub fn validate(self: *Tool, input: std.json.Value) !void {
        return self.vtable.validate(self, input);
    }

    pub fn cleanup(self: *Tool) void {
        self.vtable.cleanup(self);
    }

    pub fn describe(self: *Tool, allocator: std.mem.Allocator) ![]const u8 {
        return self.vtable.describe(self, allocator);
    }

    pub fn clone(self: *Tool, allocator: std.mem.Allocator) !*Tool {
        if (self.vtable.clone) |cloneFn| {
            return cloneFn(self, allocator);
        }
        return error.CloneNotSupported;
    }
};

// Tool categories for organization
pub const ToolCategory = enum {
    data_processing,
    file_system,
    network,
    computation,
    text_manipulation,
    system_info,
    integration,
    utility,
    custom,
};

// Tool capabilities
pub const ToolCapability = enum {
    network,
    filesystem,
    asynchronous,
};

// Tool example for documentation
pub const ToolExample = struct {
    description: []const u8,
    input: std.json.Value,
    expected_output: ?std.json.Value = null,
};

// Base tool implementation that other tools can extend
pub const BaseTool = struct {
    tool: Tool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, metadata: Tool.ToolMetadata) BaseTool {
        return BaseTool{
            .tool = Tool{
                .metadata = metadata,
                .vtable = &.{
                    .execute = executeDefault,
                    .validate = validateDefault,
                    .cleanup = cleanupDefault,
                    .describe = describeDefault,
                },
            },
            .allocator = allocator,
        };
    }

    fn executeDefault(tool: *Tool, context: *RunContext, input: std.json.Value) !std.json.Value {
        _ = tool;
        _ = context;
        _ = input;
        return error.NotImplemented;
    }

    fn validateDefault(tool: *Tool, input: std.json.Value) !void {
        const validation_result = try tool.metadata.input_schema.validate(input);
        if (!validation_result.valid) {
            return error.InvalidInput;
        }
    }

    fn cleanupDefault(tool: *Tool) void {
        _ = tool;
        // Default: no cleanup needed
    }

    fn describeDefault(tool: *Tool, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "Tool: {s}\nDescription: {s}\nVersion: {s}\nTags: {any}", .{ tool.metadata.name, tool.metadata.description, tool.metadata.version, tool.metadata.tags });
    }
};

// Utility for creating simple function tools
pub fn createFunctionTool(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    input_schema: Schema,
    output_schema: Schema,
    function: *const fn (context: *RunContext, input: std.json.Value) anyerror!std.json.Value,
) !*Tool {
    const FunctionTool = struct {
        base: BaseTool,
        function: *const fn (context: *RunContext, input: std.json.Value) anyerror!std.json.Value,

        const vtable = Tool.VTable{
            .execute = execute,
            .validate = BaseTool.validateDefault,
            .cleanup = BaseTool.cleanupDefault,
            .describe = BaseTool.describeDefault,
        };

        fn execute(tool: *Tool, context: *RunContext, input: std.json.Value) !std.json.Value {
            const base_tool: *BaseTool = @fieldParentPtr("tool", tool);
            const self: *@This() = @fieldParentPtr("base", base_tool);
            return self.function(context, input);
        }
    };

    const metadata = Tool.ToolMetadata{
        .name = name,
        .description = description,
        .input_schema = input_schema,
        .output_schema = output_schema,
        .tags = &[_][]const u8{},
    };

    const tool_impl = try allocator.create(FunctionTool);
    tool_impl.* = FunctionTool{
        .base = BaseTool.init(allocator, metadata),
        .function = function,
    };
    tool_impl.base.tool.vtable = &FunctionTool.vtable;

    return &tool_impl.base.tool;
}

// Tool execution result
pub const ToolResult = struct {
    success: bool,
    output: std.json.Value,
    error_message: ?[]const u8 = null,
    execution_time_ms: ?u64 = null,
    metadata: ?std.json.Value = null,
    retry_count: u8 = 0,

    pub fn toJson(self: ToolResult, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("success", .{ .bool = self.success });
        try obj.put("output", self.output);
        if (self.error_message) |msg| {
            try obj.put("error_message", .{ .string = msg });
        }
        if (self.execution_time_ms) |time| {
            try obj.put("execution_time_ms", .{ .integer = @as(i64, @intCast(time)) });
        }
        if (self.metadata) |meta| {
            try obj.put("metadata", meta);
        }
        try obj.put("retry_count", .{ .integer = self.retry_count });
        return .{ .object = obj };
    }
};

// Tool execution context with retries
pub const ToolExecutor = struct {
    allocator: std.mem.Allocator,
    max_retries: u8 = 3,
    retry_delay_ms: u64 = 1000,

    pub fn init(allocator: std.mem.Allocator) ToolExecutor {
        return .{
            .allocator = allocator,
        };
    }

    pub fn execute(self: *ToolExecutor, tool: *Tool, context: *RunContext, input: std.json.Value) !ToolResult {
        const start_time = std.time.milliTimestamp();
        var retry_count: u8 = 0;
        const max_retries = if (tool.metadata.max_retries > 0) tool.metadata.max_retries else self.max_retries;

        while (retry_count <= max_retries) : (retry_count += 1) {
            if (retry_count > 0) {
                std.time.sleep(self.retry_delay_ms * std.time.ns_per_ms);
            }

            const result = tool.execute(context, input) catch |err| {
                if (retry_count < max_retries) {
                    continue;
                }
                return ToolResult{
                    .success = false,
                    .output = .{ .null = {} },
                    .error_message = @errorName(err),
                    .execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
                    .retry_count = retry_count,
                };
            };

            return ToolResult{
                .success = true,
                .output = result,
                .execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time)),
                .retry_count = retry_count,
            };
        }

        unreachable;
    }
};

// Tool builder for fluent API
pub const ToolBuilder = struct {
    allocator: std.mem.Allocator,
    metadata: Tool.ToolMetadata,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) ToolBuilder {
        return .{
            .allocator = allocator,
            .metadata = .{
                .name = name,
                .description = "",
                .input_schema = undefined,
                .output_schema = undefined,
            },
        };
    }

    pub fn withDescription(self: *ToolBuilder, description: []const u8) *ToolBuilder {
        self.metadata.description = description;
        return self;
    }

    pub fn withSchemas(self: *ToolBuilder, input: Schema, output: Schema) *ToolBuilder {
        self.metadata.input_schema = input;
        self.metadata.output_schema = output;
        return self;
    }

    pub fn withTags(self: *ToolBuilder, tags: []const []const u8) *ToolBuilder {
        self.metadata.tags = tags;
        return self;
    }

    pub fn withCategory(self: *ToolBuilder, category: ToolCategory) *ToolBuilder {
        self.metadata.category = category;
        return self;
    }

    pub fn withTimeout(self: *ToolBuilder, timeout_ms: u32) *ToolBuilder {
        self.metadata.timeout_ms = timeout_ms;
        return self;
    }

    pub fn requiresNetwork(self: *ToolBuilder) *ToolBuilder {
        self.metadata.requires_network = true;
        return self;
    }

    pub fn requiresFilesystem(self: *ToolBuilder) *ToolBuilder {
        self.metadata.requires_filesystem = true;
        return self;
    }

    pub fn build(self: *ToolBuilder) !*BaseTool {
        const tool = try self.allocator.create(BaseTool);
        tool.* = BaseTool.init(self.allocator, self.metadata);
        return tool;
    }
};

test "tool validation" {
    const allocator = std.testing.allocator;

    // Create a simple schema for testing
    const input_schema = Schema.init(allocator, .{ .string = .{} });
    const output_schema = Schema.init(allocator, .{ .string = .{} });

    var tool = BaseTool.init(allocator, .{
        .name = "test_tool",
        .description = "A test tool",
        .input_schema = input_schema,
        .output_schema = output_schema,
        .tags = &[_][]const u8{},
    });

    // Test validation with string input (should pass)
    const valid_input = std.json.Value{ .string = "test" };
    try tool.tool.validate(valid_input);

    // Note: Further validation testing would require implementing the schema validator
}
