// ABOUTME: Math calculation tool for performing mathematical operations and computations
// ABOUTME: Provides comprehensive math functions including basic arithmetic, statistics, and advanced operations

const std = @import("std");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;

// Math operation types
pub const MathOperation = enum {
    // Basic arithmetic
    add,
    subtract,
    multiply,
    divide,
    modulo,
    power,

    // Advanced operations
    sqrt,
    abs,
    floor,
    ceil,
    round,
    sin,
    cos,
    tan,
    log,
    ln,
    exp,

    // Statistical operations
    mean,
    median,
    mode,
    variance,
    std_dev,
    min,
    max,
    sum,
    count,

    // Array operations
    sort,
    reverse,
    unique,

    // Expression evaluation
    evaluate,

    pub fn toString(self: MathOperation) []const u8 {
        return @tagName(self);
    }
};

// Math tool error types
pub const MathToolError = error{
    DivisionByZero,
    InvalidInput,
    InvalidOperation,
    NegativeSquareRoot,
    UnsupportedOperation,
    ExpressionError,
    OutOfRange,
};

// Math configuration
pub const MathConfig = struct {
    precision: u8 = 10,
    max_array_size: usize = 10000,
    allow_complex_expressions: bool = true,
    angle_unit: AngleUnit = .radians,

    pub const AngleUnit = enum {
        radians,
        degrees,
    };
};

// Number types for calculations
pub const Number = union(enum) {
    integer: i64,
    float: f64,

    pub fn toFloat(self: Number) f64 {
        return switch (self) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
        };
    }

    pub fn toInt(self: Number) i64 {
        return switch (self) {
            .integer => |i| i,
            .float => |f| @as(i64, @intFromFloat(f)),
        };
    }

    pub fn add(self: Number, other: Number) Number {
        if (self == .integer and other == .integer) {
            return Number{ .integer = self.integer + other.integer };
        } else {
            return Number{ .float = self.toFloat() + other.toFloat() };
        }
    }

    pub fn subtract(self: Number, other: Number) Number {
        if (self == .integer and other == .integer) {
            return Number{ .integer = self.integer - other.integer };
        } else {
            return Number{ .float = self.toFloat() - other.toFloat() };
        }
    }

    pub fn multiply(self: Number, other: Number) Number {
        if (self == .integer and other == .integer) {
            return Number{ .integer = self.integer * other.integer };
        } else {
            return Number{ .float = self.toFloat() * other.toFloat() };
        }
    }

    pub fn divide(self: Number, other: Number) !Number {
        if (other.toFloat() == 0.0) {
            return MathToolError.DivisionByZero;
        }
        return Number{ .float = self.toFloat() / other.toFloat() };
    }
};

// Math calculation tool
pub const MathTool = struct {
    base: BaseTool,
    config: MathConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: MathConfig) !*MathTool {
        const self = try allocator.create(MathTool);

        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "math_calculator",
            .description = "Perform mathematical calculations and operations",
            .version = "1.0.0",
            .category = .utility,
            .capabilities = &[_][]const u8{ "arithmetic", "statistics", "trigonometry", "expression_evaluation" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Add two numbers",
                    .input = .{ .object = try createExampleInput(allocator, "add", &[_]f64{ 5.0, 3.0 }, null) },
                    .output = .{ .object = try createExampleOutput(allocator, true, 8.0) },
                },
                .{
                    .description = "Calculate mean of array",
                    .input = .{ .object = try createExampleInput(allocator, "mean", &[_]f64{ 1.0, 2.0, 3.0, 4.0, 5.0 }, null) },
                    .output = .{ .object = try createExampleOutput(allocator, true, 3.0) },
                },
            },
        };

        self.* = .{
            .base = BaseTool.init(metadata),
            .config = config,
            .allocator = allocator,
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
        const self = @fieldParentPtr(MathTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

        // Parse input
        const operation_str = input.object.get("operation") orelse return error.MissingOperation;

        if (operation_str != .string) {
            return error.InvalidInput;
        }

        const operation = std.meta.stringToEnum(MathOperation, operation_str.string) orelse {
            return error.InvalidOperation;
        };

        // Execute operation based on type
        return switch (operation) {
            .add, .subtract, .multiply, .divide, .modulo, .power => self.executeBinaryOperation(operation, input, allocator),
            .sqrt, .abs, .floor, .ceil, .round, .sin, .cos, .tan, .log, .ln, .exp => self.executeUnaryOperation(operation, input, allocator),
            .mean, .median, .mode, .variance, .std_dev, .min, .max, .sum, .count, .sort, .reverse, .unique => self.executeArrayOperation(operation, input, allocator),
            .evaluate => self.evaluateExpression(input, allocator),
        };
    }

    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;

        // Basic validation
        if (input != .object) return false;

        const operation = input.object.get("operation") orelse return false;

        if (operation != .string) return false;

        // Validate operation is supported
        const math_operation = std.meta.stringToEnum(MathOperation, operation.string) orelse return false;
        _ = math_operation;

        return true;
    }

    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(MathTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }

    fn executeBinaryOperation(self: *const MathTool, operation: MathOperation, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const a_val = input.object.get("a") orelse return error.MissingOperandA;
        const b_val = input.object.get("b") orelse return error.MissingOperandB;

        const a = self.parseNumber(a_val) orelse return ToolResult.failure("Invalid operand A");
        const b = self.parseNumber(b_val) orelse return ToolResult.failure("Invalid operand B");

        const result = switch (operation) {
            .add => a.add(b),
            .subtract => a.subtract(b),
            .multiply => a.multiply(b),
            .divide => a.divide(b) catch |err| switch (err) {
                MathToolError.DivisionByZero => return ToolResult.failure("Division by zero"),
                else => return ToolResult.failure("Division error"),
            },
            .modulo => blk: {
                if (b.toFloat() == 0.0) {
                    return ToolResult.failure("Modulo by zero");
                }
                const mod_result = @mod(a.toFloat(), b.toFloat());
                break :blk Number{ .float = mod_result };
            },
            .power => blk: {
                const power_result = std.math.pow(f64, a.toFloat(), b.toFloat());
                break :blk Number{ .float = power_result };
            },
            else => unreachable,
        };

        var result_obj = std.json.ObjectMap.init(allocator);
        try self.addNumberToObject(&result_obj, "result", result);
        try result_obj.put("operation", .{ .string = operation.toString() });
        try result_obj.put("operands", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
            try self.numberToJsonValue(a, allocator),
            try self.numberToJsonValue(b, allocator),
        })) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeUnaryOperation(self: *const MathTool, operation: MathOperation, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const value_val = input.object.get("value") orelse return error.MissingValue;

        const value = self.parseNumber(value_val) orelse return ToolResult.failure("Invalid input value");
        const x = value.toFloat();

        const result = switch (operation) {
            .sqrt => blk: {
                if (x < 0) {
                    return ToolResult.failure("Square root of negative number");
                }
                break :blk std.math.sqrt(x);
            },
            .abs => @abs(x),
            .floor => @floor(x),
            .ceil => @ceil(x),
            .round => @round(x),
            .sin => blk: {
                const angle = if (self.config.angle_unit == .degrees) x * std.math.pi / 180.0 else x;
                break :blk @sin(angle);
            },
            .cos => blk: {
                const angle = if (self.config.angle_unit == .degrees) x * std.math.pi / 180.0 else x;
                break :blk @cos(angle);
            },
            .tan => blk: {
                const angle = if (self.config.angle_unit == .degrees) x * std.math.pi / 180.0 else x;
                break :blk @tan(angle);
            },
            .log => blk: {
                if (x <= 0) {
                    return ToolResult.failure("Logarithm of non-positive number");
                }
                break :blk @log10(x);
            },
            .ln => blk: {
                if (x <= 0) {
                    return ToolResult.failure("Natural logarithm of non-positive number");
                }
                break :blk @log(x);
            },
            .exp => @exp(x),
            else => unreachable,
        };

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = result });
        try result_obj.put("operation", .{ .string = operation.toString() });
        try result_obj.put("input", try self.numberToJsonValue(value, allocator));

        return ToolResult.success(.{ .object = result_obj });
    }

    fn executeArrayOperation(self: *const MathTool, operation: MathOperation, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const values_val = input.object.get("values") orelse return error.MissingValues;

        if (values_val != .array) {
            return ToolResult.failure("Values must be an array");
        }

        if (values_val.array.items.len > self.config.max_array_size) {
            return ToolResult.failure("Array too large");
        }

        var numbers = std.ArrayList(f64).init(allocator);
        defer numbers.deinit();

        for (values_val.array.items) |item| {
            if (self.parseNumber(item)) |num| {
                try numbers.append(num.toFloat());
            } else {
                return ToolResult.failure("Invalid number in array");
            }
        }

        if (numbers.items.len == 0) {
            return ToolResult.failure("Empty array");
        }

        return switch (operation) {
            .mean => self.calculateMean(numbers.items, allocator),
            .median => self.calculateMedian(numbers.items, allocator),
            .mode => self.calculateMode(numbers.items, allocator),
            .variance => self.calculateVariance(numbers.items, allocator),
            .std_dev => self.calculateStdDev(numbers.items, allocator),
            .min => self.calculateMin(numbers.items, allocator),
            .max => self.calculateMax(numbers.items, allocator),
            .sum => self.calculateSum(numbers.items, allocator),
            .count => self.calculateCount(numbers.items, allocator),
            .sort => self.sortArray(numbers.items, allocator),
            .reverse => self.reverseArray(numbers.items, allocator),
            .unique => self.uniqueArray(numbers.items, allocator),
            else => unreachable,
        };
    }

    fn evaluateExpression(self: *const MathTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        // Expression evaluation would require a full parser
        // For now, return not implemented
        return ToolResult.failure("Expression evaluation not yet implemented");
    }

    fn parseNumber(self: *const MathTool, value: std.json.Value) ?Number {
        _ = self;
        return switch (value) {
            .integer => |i| Number{ .integer = i },
            .float => |f| Number{ .float = f },
            else => null,
        };
    }

    fn addNumberToObject(self: *const MathTool, obj: *std.json.ObjectMap, key: []const u8, number: Number) !void {
        _ = self;
        switch (number) {
            .integer => |i| try obj.put(key, .{ .integer = i }),
            .float => |f| try obj.put(key, .{ .float = f }),
        }
    }

    fn numberToJsonValue(self: *const MathTool, number: Number, allocator: std.mem.Allocator) !std.json.Value {
        _ = self;
        _ = allocator;
        return switch (number) {
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
        };
    }

    // Statistical calculation functions
    fn calculateMean(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var sum: f64 = 0;
        for (values) |value| {
            sum += value;
        }
        const mean = sum / @as(f64, @floatFromInt(values.len));

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = mean });
        try result_obj.put("operation", .{ .string = "mean" });
        try result_obj.put("count", .{ .integer = @as(i64, @intCast(values.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateMedian(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var sorted_values = try allocator.dupe(f64, values);
        defer allocator.free(sorted_values);

        std.sort.sort(f64, sorted_values, {}, comptime std.sort.asc(f64));

        const median = if (sorted_values.len % 2 == 0) blk: {
            const mid = sorted_values.len / 2;
            break :blk (sorted_values[mid - 1] + sorted_values[mid]) / 2.0;
        } else blk: {
            break :blk sorted_values[sorted_values.len / 2];
        };

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = median });
        try result_obj.put("operation", .{ .string = "median" });
        try result_obj.put("count", .{ .integer = @as(i64, @intCast(values.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateMode(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var frequency_map = std.HashMap(f64, u32, std.HashMap.AutoContext(f64), std.hash_map.default_max_load_percentage).init(allocator);
        defer frequency_map.deinit();

        // Count frequencies
        for (values) |value| {
            const result = try frequency_map.getOrPut(value);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }

        // Find mode(s)
        var max_frequency: u32 = 0;
        var iter = frequency_map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > max_frequency) {
                max_frequency = entry.value_ptr.*;
            }
        }

        var modes = std.ArrayList(f64).init(allocator);
        defer modes.deinit();

        iter = frequency_map.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == max_frequency) {
                try modes.append(entry.key_ptr.*);
            }
        }

        var result_obj = std.json.ObjectMap.init(allocator);

        if (modes.items.len == 1) {
            try result_obj.put("result", .{ .float = modes.items[0] });
        } else {
            var modes_array = std.ArrayList(std.json.Value).init(allocator);
            for (modes.items) |mode| {
                try modes_array.append(.{ .float = mode });
            }
            try result_obj.put("result", .{ .array = std.json.Array.fromOwnedSlice(allocator, try modes_array.toOwnedSlice()) });
        }

        try result_obj.put("operation", .{ .string = "mode" });
        try result_obj.put("frequency", .{ .integer = @as(i64, @intCast(max_frequency)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateVariance(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        // Calculate mean first
        var sum: f64 = 0;
        for (values) |value| {
            sum += value;
        }
        const mean = sum / @as(f64, @floatFromInt(values.len));

        // Calculate variance
        var variance_sum: f64 = 0;
        for (values) |value| {
            const diff = value - mean;
            variance_sum += diff * diff;
        }
        const variance = variance_sum / @as(f64, @floatFromInt(values.len));

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = variance });
        try result_obj.put("operation", .{ .string = "variance" });
        try result_obj.put("mean", .{ .float = mean });
        try result_obj.put("count", .{ .integer = @as(i64, @intCast(values.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateStdDev(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        const variance_result = try self.calculateVariance(values, allocator);
        if (!variance_result.success) return variance_result;

        const variance = variance_result.data.?.object.get("result").?.float;
        const std_dev = std.math.sqrt(variance);

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = std_dev });
        try result_obj.put("operation", .{ .string = "std_dev" });
        try result_obj.put("variance", .{ .float = variance });
        try result_obj.put("count", .{ .integer = @as(i64, @intCast(values.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateMin(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var min_val = values[0];
        for (values[1..]) |value| {
            if (value < min_val) {
                min_val = value;
            }
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = min_val });
        try result_obj.put("operation", .{ .string = "min" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateMax(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var max_val = values[0];
        for (values[1..]) |value| {
            if (value > max_val) {
                max_val = value;
            }
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = max_val });
        try result_obj.put("operation", .{ .string = "max" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateSum(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var sum: f64 = 0;
        for (values) |value| {
            sum += value;
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .float = sum });
        try result_obj.put("operation", .{ .string = "sum" });
        try result_obj.put("count", .{ .integer = @as(i64, @intCast(values.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn calculateCount(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .integer = @as(i64, @intCast(values.len)) });
        try result_obj.put("operation", .{ .string = "count" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn sortArray(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var sorted_values = try allocator.dupe(f64, values);
        std.sort.sort(f64, sorted_values, {}, comptime std.sort.asc(f64));

        var sorted_array = std.ArrayList(std.json.Value).init(allocator);
        for (sorted_values) |value| {
            try sorted_array.append(.{ .float = value });
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .array = std.json.Array.fromOwnedSlice(allocator, try sorted_array.toOwnedSlice()) });
        try result_obj.put("operation", .{ .string = "sort" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn reverseArray(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var reversed_array = std.ArrayList(std.json.Value).init(allocator);

        var i = values.len;
        while (i > 0) {
            i -= 1;
            try reversed_array.append(.{ .float = values[i] });
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .array = std.json.Array.fromOwnedSlice(allocator, try reversed_array.toOwnedSlice()) });
        try result_obj.put("operation", .{ .string = "reverse" });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn uniqueArray(self: *const MathTool, values: []f64, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        var seen = std.HashMap(f64, void, std.HashMap.AutoContext(f64), std.hash_map.default_max_load_percentage).init(allocator);
        defer seen.deinit();

        var unique_values = std.ArrayList(f64).init(allocator);
        defer unique_values.deinit();

        for (values) |value| {
            if (!seen.contains(value)) {
                try seen.put(value, {});
                try unique_values.append(value);
            }
        }

        var unique_array = std.ArrayList(std.json.Value).init(allocator);
        for (unique_values.items) |value| {
            try unique_array.append(.{ .float = value });
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("result", .{ .array = std.json.Array.fromOwnedSlice(allocator, try unique_array.toOwnedSlice()) });
        try result_obj.put("operation", .{ .string = "unique" });
        try result_obj.put("original_count", .{ .integer = @as(i64, @intCast(values.len)) });
        try result_obj.put("unique_count", .{ .integer = @as(i64, @intCast(unique_values.items.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }
};

// Helper functions for schema creation
fn createInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var operation_prop = std.json.ObjectMap.init(allocator);
    try operation_prop.put("type", .{ .string = "string" });
    try operation_prop.put("description", .{ .string = "Mathematical operation to perform" });
    try properties.put("operation", .{ .object = operation_prop });

    var a_prop = std.json.ObjectMap.init(allocator);
    try a_prop.put("type", .{ .string = "number" });
    try a_prop.put("description", .{ .string = "First operand (for binary operations)" });
    try properties.put("a", .{ .object = a_prop });

    var b_prop = std.json.ObjectMap.init(allocator);
    try b_prop.put("type", .{ .string = "number" });
    try b_prop.put("description", .{ .string = "Second operand (for binary operations)" });
    try properties.put("b", .{ .object = b_prop });

    var value_prop = std.json.ObjectMap.init(allocator);
    try value_prop.put("type", .{ .string = "number" });
    try value_prop.put("description", .{ .string = "Input value (for unary operations)" });
    try properties.put("value", .{ .object = value_prop });

    var values_prop = std.json.ObjectMap.init(allocator);
    try values_prop.put("type", .{ .string = "array" });
    var values_items = std.json.ObjectMap.init(allocator);
    try values_items.put("type", .{ .string = "number" });
    try values_prop.put("items", .{ .object = values_items });
    try values_prop.put("description", .{ .string = "Array of numbers (for array operations)" });
    try properties.put("values", .{ .object = values_prop });

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "operation" },
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
    try properties.put("data", .{ .object = data_prop });

    var error_prop = std.json.ObjectMap.init(allocator);
    try error_prop.put("type", .{ .string = "string" });
    try properties.put("error", .{ .object = error_prop });

    try schema.put("properties", .{ .object = properties });

    return .{ .object = schema };
}

fn createExampleInput(allocator: std.mem.Allocator, operation: []const u8, values: []const f64, expression: ?[]const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("operation", .{ .string = operation });

    if (values.len == 1) {
        try input.put("value", .{ .float = values[0] });
    } else if (values.len == 2) {
        try input.put("a", .{ .float = values[0] });
        try input.put("b", .{ .float = values[1] });
    } else if (values.len > 2) {
        var values_array = std.ArrayList(std.json.Value).init(allocator);
        for (values) |value| {
            try values_array.append(.{ .float = value });
        }
        try input.put("values", .{ .array = std.json.Array.fromOwnedSlice(allocator, try values_array.toOwnedSlice()) });
    }

    if (expression) |expr| {
        try input.put("expression", .{ .string = expr });
    }

    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, result: f64) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });

    var data = std.json.ObjectMap.init(allocator);
    try data.put("result", .{ .float = result });
    try output.put("data", .{ .object = data });

    return output;
}

// Builder function for easy creation
pub fn createMathTool(allocator: std.mem.Allocator, config: MathConfig) !*Tool {
    const math_tool = try MathTool.init(allocator, config);
    return &math_tool.base.tool;
}

// Tests
test "math tool creation" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createMathTool(allocator, .{});
    defer tool_ptr.deinit();

    try std.testing.expectEqualStrings("math_calculator", tool_ptr.metadata.name);
}

test "basic arithmetic" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createMathTool(allocator, .{});
    defer tool_ptr.deinit();

    // Test addition
    var add_input = std.json.ObjectMap.init(allocator);
    defer add_input.deinit();
    try add_input.put("operation", .{ .string = "add" });
    try add_input.put("a", .{ .integer = 5 });
    try add_input.put("b", .{ .integer = 3 });

    const add_result = try tool_ptr.execute(.{ .object = add_input }, allocator);
    defer if (add_result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(add_result.success);
    if (add_result.data) |data| {
        const result = data.object.get("result").?;
        try std.testing.expectEqual(@as(i64, 8), result.integer);
    }
}

test "statistical operations" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createMathTool(allocator, .{});
    defer tool_ptr.deinit();

    // Test mean calculation
    var mean_input = std.json.ObjectMap.init(allocator);
    defer mean_input.deinit();
    try mean_input.put("operation", .{ .string = "mean" });

    var values_array = std.ArrayList(std.json.Value).init(allocator);
    defer values_array.deinit();
    try values_array.append(.{ .float = 1.0 });
    try values_array.append(.{ .float = 2.0 });
    try values_array.append(.{ .float = 3.0 });
    try values_array.append(.{ .float = 4.0 });
    try values_array.append(.{ .float = 5.0 });

    try mean_input.put("values", .{ .array = std.json.Array.fromOwnedSlice(allocator, try values_array.toOwnedSlice()) });

    const mean_result = try tool_ptr.execute(.{ .object = mean_input }, allocator);
    defer if (mean_result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(mean_result.success);
    if (mean_result.data) |data| {
        const result = data.object.get("result").?;
        try std.testing.expectEqual(@as(f64, 3.0), result.float);
    }
}
