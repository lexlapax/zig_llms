// ABOUTME: Data manipulation tool for processing JSON, CSV, YAML, and XML formats
// ABOUTME: Provides comprehensive data transformation, filtering, and conversion capabilities

const std = @import("std");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;
const util = @import("../util.zig");

// Data formats supported
pub const DataFormat = enum {
    json,
    csv,
    yaml,
    xml,

    pub fn toString(self: DataFormat) []const u8 {
        return @tagName(self);
    }
};

// Data operations
pub const DataOperation = enum {
    parse,
    stringify,
    transform,
    filter,
    merge,
    extract,
    validate,
    convert,
    query,
    sort,

    pub fn toString(self: DataOperation) []const u8 {
        return @tagName(self);
    }
};

// Data tool error types
pub const DataToolError = error{
    UnsupportedFormat,
    InvalidData,
    ParseError,
    TransformError,
    FilterError,
    UnsafeOperation,
    QueryError,
};

// Safety configuration
pub const DataSafetyConfig = struct {
    max_data_size: usize = 10 * 1024 * 1024, // 10MB
    max_nesting_depth: u32 = 100,
    allow_external_refs: bool = false,
    allowed_formats: []const DataFormat = &[_]DataFormat{ .json, .csv },
    max_output_size: usize = 50 * 1024 * 1024, // 50MB
};

// CSV configuration
pub const CSVConfig = struct {
    delimiter: u8 = ',',
    quote_char: u8 = '"',
    escape_char: u8 = '\\',
    has_header: bool = true,
    skip_empty_lines: bool = true,
};

// Data manipulation tool
pub const DataTool = struct {
    base: BaseTool,
    safety_config: DataSafetyConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, safety_config: DataSafetyConfig) !*DataTool {
        const self = try allocator.create(DataTool);

        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "data_manipulation",
            .description = "Process and manipulate data in various formats (JSON, CSV, YAML, XML)",
            .version = "1.0.0",
            .category = .data,
            .capabilities = &[_][]const u8{ "json_processing", "csv_processing", "data_conversion", "data_filtering" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Parse JSON data",
                    .input = .{ .object = try createExampleInput(allocator, "parse", "json", "{\"name\": \"John\", \"age\": 30}") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Parsed JSON data") },
                },
                .{
                    .description = "Convert JSON to CSV",
                    .input = .{ .object = try createExampleInput(allocator, "convert", "json", "[{\"name\": \"John\", \"age\": 30}]") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Converted to CSV") },
                },
            },
        };

        self.* = .{
            .base = BaseTool.init(metadata),
            .safety_config = safety_config,
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
        const self = @fieldParentPtr(DataTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

        // Parse input
        const operation_str = input.object.get("operation") orelse return error.MissingOperation;
        const format_str = input.object.get("format") orelse return error.MissingFormat;
        const data_val = input.object.get("data") orelse return error.MissingData;

        if (operation_str != .string or format_str != .string or data_val != .string) {
            return error.InvalidInput;
        }

        const operation = std.meta.stringToEnum(DataOperation, operation_str.string) orelse {
            return error.InvalidOperation;
        };

        const format = std.meta.stringToEnum(DataFormat, format_str.string) orelse {
            return error.UnsupportedFormat;
        };

        const data = data_val.string;

        // Validate format is allowed
        try self.validateFormat(format);

        // Validate data size
        if (data.len > self.safety_config.max_data_size) {
            return ToolResult.failure("Data too large");
        }

        // Execute operation
        return switch (operation) {
            .parse => self.parseData(format, data, allocator),
            .stringify => self.stringifyData(format, data, allocator),
            .transform => self.transformData(format, data, input, allocator),
            .filter => self.filterData(format, data, input, allocator),
            .merge => self.mergeData(format, data, input, allocator),
            .extract => self.extractData(format, data, input, allocator),
            .validate => self.validateData(format, data, allocator),
            .convert => self.convertData(format, data, input, allocator),
            .query => self.queryData(format, data, input, allocator),
            .sort => self.sortData(format, data, input, allocator),
        };
    }

    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;

        // Basic validation
        if (input != .object) return false;

        const operation = input.object.get("operation") orelse return false;
        const format = input.object.get("format") orelse return false;
        const data = input.object.get("data") orelse return false;

        if (operation != .string or format != .string or data != .string) return false;

        // Validate operation and format are valid
        const data_operation = std.meta.stringToEnum(DataOperation, operation.string) orelse return false;
        const data_format = std.meta.stringToEnum(DataFormat, format.string) orelse return false;

        _ = data_operation;
        _ = data_format;

        return true;
    }

    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(DataTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }

    fn validateFormat(self: *const DataTool, format: DataFormat) !void {
        for (self.safety_config.allowed_formats) |allowed| {
            if (allowed == format) return;
        }
        return DataToolError.UnsupportedFormat;
    }

    fn parseData(self: *const DataTool, format: DataFormat, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        return switch (format) {
            .json => self.parseJSON(data, allocator),
            .csv => self.parseCSV(data, allocator),
            .yaml => ToolResult.failure("YAML parsing not yet implemented"),
            .xml => ToolResult.failure("XML parsing not yet implemented"),
        };
    }

    fn parseJSON(self: *const DataTool, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
            error.InvalidCharacter, error.UnexpectedToken, error.InvalidNumber, error.InvalidUnicodeHex, error.InvalidEscapeCharacter, error.InvalidTopLevel, error.DuplicateField, error.UnknownField => return ToolResult.failure("Invalid JSON format"),
            else => return ToolResult.failure("JSON parsing failed"),
        };
        defer parsed.deinit();

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("parsed_data", parsed.value);
        try result_obj.put("format", .{ .string = "json" });
        try result_obj.put("type", .{ .string = @tagName(parsed.value) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn parseCSV(self: *const DataTool, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        const config = CSVConfig{};
        var rows = std.ArrayList(std.json.Value).init(allocator);
        defer rows.deinit();

        var lines = std.mem.split(u8, data, "\n");
        var headers: ?[][]const u8 = null;
        defer if (headers) |h| {
            for (h) |header| allocator.free(header);
            allocator.free(h);
        };

        var line_num: usize = 0;
        while (lines.next()) |line| {
            if (config.skip_empty_lines and line.len == 0) continue;

            const fields = try self.parseCSVLine(line, config, allocator);
            defer {
                for (fields) |field| allocator.free(field);
                allocator.free(fields);
            }

            if (line_num == 0 and config.has_header) {
                // Store headers
                headers = try allocator.dupe([]const u8, fields);
                for (headers.?, 0..) |*header, i| {
                    header.* = try allocator.dupe(u8, fields[i]);
                }
            } else {
                // Create row object
                var row_obj = std.json.ObjectMap.init(allocator);

                if (headers) |h| {
                    // Use headers as keys
                    for (fields, 0..) |field, i| {
                        const key = if (i < h.len) h[i] else try std.fmt.allocPrint(allocator, "column_{d}", .{i});
                        try row_obj.put(key, .{ .string = try allocator.dupe(u8, field) });
                    }
                } else {
                    // Use numeric indices
                    for (fields, 0..) |field, i| {
                        const key = try std.fmt.allocPrint(allocator, "column_{d}", .{i});
                        try row_obj.put(key, .{ .string = try allocator.dupe(u8, field) });
                    }
                }

                try rows.append(.{ .object = row_obj });
            }

            line_num += 1;
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("parsed_data", .{ .array = std.json.Array.fromOwnedSlice(allocator, try rows.toOwnedSlice()) });
        try result_obj.put("format", .{ .string = "csv" });
        try result_obj.put("row_count", .{ .integer = @as(i64, @intCast(rows.items.len)) });
        if (headers) |h| {
            var headers_array = std.ArrayList(std.json.Value).init(allocator);
            for (h) |header| {
                try headers_array.append(.{ .string = header });
            }
            try result_obj.put("headers", .{ .array = std.json.Array.fromOwnedSlice(allocator, try headers_array.toOwnedSlice()) });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn parseCSVLine(self: *const DataTool, line: []const u8, config: CSVConfig, allocator: std.mem.Allocator) ![][]const u8 {
        _ = self;

        var fields = std.ArrayList([]const u8).init(allocator);
        defer fields.deinit();

        var i: usize = 0;
        while (i < line.len) {
            var field_start = i;
            var in_quotes = false;
            var field_buf = std.ArrayList(u8).init(allocator);
            defer field_buf.deinit();

            while (i < line.len) {
                const char = line[i];

                if (char == config.quote_char and !in_quotes) {
                    in_quotes = true;
                } else if (char == config.quote_char and in_quotes) {
                    // Check for escaped quote
                    if (i + 1 < line.len and line[i + 1] == config.quote_char) {
                        try field_buf.append(config.quote_char);
                        i += 1; // Skip the second quote
                    } else {
                        in_quotes = false;
                    }
                } else if (char == config.delimiter and !in_quotes) {
                    break;
                } else {
                    try field_buf.append(char);
                }

                i += 1;
            }

            try fields.append(try allocator.dupe(u8, field_buf.items));

            if (i < line.len and line[i] == config.delimiter) {
                i += 1; // Skip delimiter
            }
        }

        return try fields.toOwnedSlice();
    }

    fn stringifyData(self: *const DataTool, format: DataFormat, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        return switch (format) {
            .json => self.stringifyJSON(data, allocator),
            .csv => self.stringifyCSV(data, allocator),
            .yaml => ToolResult.failure("YAML stringification not yet implemented"),
            .xml => ToolResult.failure("XML stringification not yet implemented"),
        };
    }

    fn stringifyJSON(self: *const DataTool, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        // Parse the input as JSON first
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
            return ToolResult.failure("Invalid JSON input for stringification");
        };
        defer parsed.deinit();

        // Stringify with pretty formatting
        const stringified = std.json.stringifyAlloc(allocator, parsed.value, .{
            .whitespace = .indent_2,
        }) catch {
            return ToolResult.failure("Failed to stringify JSON");
        };

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("stringified_data", .{ .string = stringified });
        try result_obj.put("format", .{ .string = "json" });
        try result_obj.put("size", .{ .integer = @as(i64, @intCast(stringified.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn stringifyCSV(self: *const DataTool, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        // Parse JSON array input
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
            return ToolResult.failure("Invalid JSON input for CSV conversion");
        };
        defer parsed.deinit();

        if (parsed.value != .array) {
            return ToolResult.failure("Input must be a JSON array for CSV conversion");
        }

        const config = CSVConfig{};
        var csv_buf = std.ArrayList(u8).init(allocator);
        defer csv_buf.deinit();

        const writer = csv_buf.writer();

        // Extract headers from first object
        var headers = std.ArrayList([]const u8).init(allocator);
        defer headers.deinit();

        if (parsed.value.array.items.len > 0 and parsed.value.array.items[0] == .object) {
            var iter = parsed.value.array.items[0].object.iterator();
            while (iter.next()) |entry| {
                try headers.append(entry.key_ptr.*);
            }

            // Write headers
            for (headers.items, 0..) |header, i| {
                if (i > 0) try writer.writeByte(config.delimiter);
                try writer.writeAll(header);
            }
            try writer.writeByte('\n');
        }

        // Write data rows
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;

            for (headers.items, 0..) |header, i| {
                if (i > 0) try writer.writeByte(config.delimiter);

                if (item.object.get(header)) |value| {
                    const str_value = switch (value) {
                        .string => |s| s,
                        .integer => |int| try std.fmt.allocPrint(allocator, "{d}", .{int}),
                        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
                        .bool => |b| if (b) "true" else "false",
                        .null => "null",
                        else => "[complex]",
                    };

                    // Quote if contains delimiter or quotes
                    if (std.mem.indexOf(u8, str_value, &[_]u8{config.delimiter}) != null or
                        std.mem.indexOf(u8, str_value, &[_]u8{config.quote_char}) != null)
                    {
                        try writer.writeByte(config.quote_char);
                        for (str_value) |char| {
                            if (char == config.quote_char) {
                                try writer.writeByte(config.quote_char); // Escape quote
                            }
                            try writer.writeByte(char);
                        }
                        try writer.writeByte(config.quote_char);
                    } else {
                        try writer.writeAll(str_value);
                    }
                }
            }
            try writer.writeByte('\n');
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("stringified_data", .{ .string = try allocator.dupe(u8, csv_buf.items) });
        try result_obj.put("format", .{ .string = "csv" });
        try result_obj.put("size", .{ .integer = @as(i64, @intCast(csv_buf.items.len)) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn transformData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = format;
        _ = data;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Data transformation not yet implemented");
    }

    fn filterData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = format;
        _ = data;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Data filtering not yet implemented");
    }

    fn mergeData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = format;
        _ = data;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Data merging not yet implemented");
    }

    fn extractData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = format;
        _ = data;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Data extraction not yet implemented");
    }

    fn validateData(self: *const DataTool, format: DataFormat, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        return switch (format) {
            .json => self.validateJSON(data, allocator),
            .csv => self.validateCSV(data, allocator),
            .yaml => ToolResult.failure("YAML validation not yet implemented"),
            .xml => ToolResult.failure("XML validation not yet implemented"),
        };
    }

    fn validateJSON(self: *const DataTool, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
            const error_msg = switch (err) {
                error.InvalidCharacter => "Invalid character in JSON",
                error.UnexpectedToken => "Unexpected token in JSON",
                error.InvalidNumber => "Invalid number format in JSON",
                else => "JSON validation failed",
            };

            var result_obj = std.json.ObjectMap.init(allocator);
            try result_obj.put("valid", .{ .bool = false });
            try result_obj.put("error", .{ .string = error_msg });
            try result_obj.put("format", .{ .string = "json" });

            return ToolResult.success(.{ .object = result_obj });
        };
        defer parsed.deinit();

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("valid", .{ .bool = true });
        try result_obj.put("format", .{ .string = "json" });
        try result_obj.put("type", .{ .string = @tagName(parsed.value) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn validateCSV(self: *const DataTool, data: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;

        // Basic CSV validation - check for consistent field counts
        var lines = std.mem.split(u8, data, "\n");
        var field_count: ?usize = null;
        var line_num: usize = 0;
        var valid = true;
        var error_msg: ?[]const u8 = null;

        while (lines.next()) |line| {
            if (line.len == 0) continue; // Skip empty lines

            const fields = try self.parseCSVLine(line, CSVConfig{}, allocator);
            defer {
                for (fields) |field| allocator.free(field);
                allocator.free(fields);
            }

            if (field_count == null) {
                field_count = fields.len;
            } else if (field_count.? != fields.len) {
                valid = false;
                error_msg = try std.fmt.allocPrint(allocator, "Inconsistent field count at line {d}: expected {d}, got {d}", .{ line_num + 1, field_count.?, fields.len });
                break;
            }

            line_num += 1;
        }

        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("valid", .{ .bool = valid });
        try result_obj.put("format", .{ .string = "csv" });
        try result_obj.put("line_count", .{ .integer = @as(i64, @intCast(line_num)) });
        if (field_count) |fc| {
            try result_obj.put("field_count", .{ .integer = @as(i64, @intCast(fc)) });
        }
        if (error_msg) |msg| {
            try result_obj.put("error", .{ .string = msg });
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn convertData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const target_format_val = input.object.get("target_format") orelse return error.MissingTargetFormat;
        if (target_format_val != .string) return error.InvalidTargetFormat;

        const target_format = std.meta.stringToEnum(DataFormat, target_format_val.string) orelse {
            return error.UnsupportedTargetFormat;
        };

        if (format == target_format) {
            return ToolResult.failure("Source and target formats are the same");
        }

        return switch (format) {
            .json => switch (target_format) {
                .csv => self.stringifyCSV(data, allocator),
                else => ToolResult.failure("JSON to target format conversion not supported"),
            },
            .csv => switch (target_format) {
                .json => blk: {
                    const csv_result = try self.parseCSV(data, allocator);
                    if (!csv_result.success) break :blk csv_result;

                    const parsed_data = csv_result.data.?.object.get("parsed_data").?;
                    const json_str = try std.json.stringifyAlloc(allocator, parsed_data, .{});

                    var result_obj = std.json.ObjectMap.init(allocator);
                    try result_obj.put("converted_data", .{ .string = json_str });
                    try result_obj.put("source_format", .{ .string = "csv" });
                    try result_obj.put("target_format", .{ .string = "json" });

                    break :blk ToolResult.success(.{ .object = result_obj });
                },
                else => ToolResult.failure("CSV to target format conversion not supported"),
            },
            else => ToolResult.failure("Source format conversion not supported"),
        };
    }

    fn queryData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = format;
        _ = data;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Data querying not yet implemented");
    }

    fn sortData(self: *const DataTool, format: DataFormat, data: []const u8, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = format;
        _ = data;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Data sorting not yet implemented");
    }
};

// Helper functions for schema creation
fn createInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var operation_prop = std.json.ObjectMap.init(allocator);
    try operation_prop.put("type", .{ .string = "string" });
    try operation_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "parse" },
        .{ .string = "stringify" },
        .{ .string = "transform" },
        .{ .string = "filter" },
        .{ .string = "merge" },
        .{ .string = "extract" },
        .{ .string = "validate" },
        .{ .string = "convert" },
        .{ .string = "query" },
        .{ .string = "sort" },
    })) });
    try properties.put("operation", .{ .object = operation_prop });

    var format_prop = std.json.ObjectMap.init(allocator);
    try format_prop.put("type", .{ .string = "string" });
    try format_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "json" },
        .{ .string = "csv" },
        .{ .string = "yaml" },
        .{ .string = "xml" },
    })) });
    try properties.put("format", .{ .object = format_prop });

    var data_prop = std.json.ObjectMap.init(allocator);
    try data_prop.put("type", .{ .string = "string" });
    try data_prop.put("description", .{ .string = "Data to process" });
    try properties.put("data", .{ .object = data_prop });

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "operation" },
        .{ .string = "format" },
        .{ .string = "data" },
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

fn createExampleInput(allocator: std.mem.Allocator, operation: []const u8, format: []const u8, data: []const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("operation", .{ .string = operation });
    try input.put("format", .{ .string = format });
    try input.put("data", .{ .string = data });
    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, message: []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });

    var data = std.json.ObjectMap.init(allocator);
    try data.put("message", .{ .string = message });
    try output.put("data", .{ .object = data });

    return output;
}

// Builder function for easy creation
pub fn createDataTool(allocator: std.mem.Allocator, safety_config: DataSafetyConfig) !*Tool {
    const data_tool = try DataTool.init(allocator, safety_config);
    return &data_tool.base.tool;
}

// Tests
test "data tool creation" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createDataTool(allocator, .{});
    defer tool_ptr.deinit();

    try std.testing.expectEqualStrings("data_manipulation", tool_ptr.metadata.name);
}

test "json parsing" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createDataTool(allocator, .{});
    defer tool_ptr.deinit();

    var input = std.json.ObjectMap.init(allocator);
    defer input.deinit();
    try input.put("operation", .{ .string = "parse" });
    try input.put("format", .{ .string = "json" });
    try input.put("data", .{ .string = "{\"name\": \"test\", \"value\": 42}" });

    const result = try tool_ptr.execute(.{ .object = input }, allocator);
    defer if (result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(result.success);
    if (result.data) |data| {
        try std.testing.expect(data.object.get("parsed_data") != null);
        try std.testing.expect(data.object.get("format") != null);
    }
}

test "json validation" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createDataTool(allocator, .{});
    defer tool_ptr.deinit();

    // Valid JSON
    var valid_input = std.json.ObjectMap.init(allocator);
    defer valid_input.deinit();
    try valid_input.put("operation", .{ .string = "validate" });
    try valid_input.put("format", .{ .string = "json" });
    try valid_input.put("data", .{ .string = "{\"valid\": true}" });

    const valid_result = try tool_ptr.execute(.{ .object = valid_input }, allocator);
    defer if (valid_result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(valid_result.success);
    if (valid_result.data) |data| {
        try std.testing.expect(data.object.get("valid").?.bool == true);
    }

    // Invalid JSON
    var invalid_input = std.json.ObjectMap.init(allocator);
    defer invalid_input.deinit();
    try invalid_input.put("operation", .{ .string = "validate" });
    try invalid_input.put("format", .{ .string = "json" });
    try invalid_input.put("data", .{ .string = "{invalid json}" });

    const invalid_result = try tool_ptr.execute(.{ .object = invalid_input }, allocator);
    defer if (invalid_result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(invalid_result.success);
    if (invalid_result.data) |data| {
        try std.testing.expect(data.object.get("valid").?.bool == false);
    }
}
