// ABOUTME: Tool interface definition and execution framework for agent capabilities
// ABOUTME: Provides tool structure, validation, and execution logic for external functionality

const std = @import("std");
const Schema = @import("schema/validator.zig").Schema;
const RunContext = @import("context.zig").RunContext;

pub const Tool = struct {
    metadata: ToolMetadata,
    vtable: *const VTable,
    
    pub const VTable = struct {
        execute: *const fn (self: *Tool, context: *RunContext, input: std.json.Value) anyerror!std.json.Value,
        validate: *const fn (self: *Tool, input: std.json.Value) anyerror!void,
        cleanup: *const fn (self: *Tool) void,
    };
    
    pub const ToolMetadata = struct {
        name: []const u8,
        description: []const u8,
        input_schema: Schema,
        output_schema: Schema,
        tags: []const []const u8,
        version: []const u8 = "1.0.0",
        author: ?[]const u8 = null,
        
        pub fn hasTag(self: *const ToolMetadata, tag: []const u8) bool {
            for (self.tags) |t| {
                if (std.mem.eql(u8, t, tag)) return true;
            }
            return false;
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