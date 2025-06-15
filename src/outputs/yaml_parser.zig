// ABOUTME: YAML parser for extracting structured data from YAML-formatted LLM outputs
// ABOUTME: Converts YAML to JSON representation for unified processing

const std = @import("std");
const parser = @import("parser.zig");

pub const YamlParser = struct {
    base: parser.Parser,
    allocator: std.mem.Allocator,
    
    const vtable = parser.Parser.VTable{
        .parse = yamlParse,
        .canParse = yamlCanParse,
        .getFormat = yamlGetFormat,
        .getName = yamlGetName,
        .deinit = yamlDeinit,
    };
    
    pub fn init(allocator: std.mem.Allocator) YamlParser {
        return .{
            .base = parser.Parser{ .vtable = &vtable },
            .allocator = allocator,
        };
    }
    
    fn yamlParse(
        base: *parser.Parser,
        input: []const u8,
        options: parser.ParseOptions,
        allocator: std.mem.Allocator,
    ) parser.ParseError!parser.ParseResult {
        const self: *YamlParser = @fieldParentPtr("base", base);
        _ = self;
        
        var warnings = std.ArrayList([]const u8).init(allocator);
        defer warnings.deinit();
        
        // Clean the input
        const cleaned = parser.utils.cleanLlmResponse(allocator, input) catch {
            return parser.ParseResult{
                .value = std.json.Value{ .null = {} },
                .format = .yaml,
                .success = false,
                .errors = &[_]parser.ParseError{parser.ParseError.InvalidFormat},
                .allocator = allocator,
            };
        };
        defer allocator.free(cleaned);
        
        // Extract YAML from code block if present
        const yaml_content = if (parser.utils.extractCodeBlock(cleaned, "yaml")) |content|
            content
        else if (parser.utils.extractCodeBlock(cleaned, "yml")) |content|
            content
        else
            cleaned;
        
        // Parse YAML into JSON
        const json_value = try parseYamlToJson(allocator, yaml_content);
        
        // Validate against schema if provided
        if (options.validation_schema) |schema| {
            const validation_result = schema.validate(json_value) catch {
                return parser.ParseResult{
                    .value = json_value,
                    .format = .yaml,
                    .success = false,
                    .errors = &[_]parser.ParseError{parser.ParseError.SchemaValidationFailed},
                    .allocator = allocator,
                };
            };
            
            if (!validation_result.valid and options.strict) {
                return parser.ParseResult{
                    .value = json_value,
                    .format = .yaml,
                    .success = false,
                    .errors = &[_]parser.ParseError{parser.ParseError.SchemaValidationFailed},
                    .warnings = try warnings.toOwnedSlice(),
                    .allocator = allocator,
                };
            }
        }
        
        // Extract specific fields if requested
        const final_value = if (options.extract_fields) |fields|
            try parser.utils.extractFields(allocator, json_value, fields)
        else
            json_value;
        
        return parser.ParseResult{
            .value = final_value,
            .format = .yaml,
            .success = true,
            .warnings = try warnings.toOwnedSlice(),
            .allocator = allocator,
        };
    }
    
    fn yamlCanParse(base: *parser.Parser, input: []const u8) bool {
        _ = base;
        
        // Check for YAML indicators
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        
        // Look for YAML markers
        if (std.mem.startsWith(u8, trimmed, "---")) return true;
        
        // Check for YAML in code blocks
        if (parser.utils.extractCodeBlock(input, "yaml") != null or
            parser.utils.extractCodeBlock(input, "yml") != null) {
            return true;
        }
        
        // Simple heuristic: contains colon followed by space or newline
        if (std.mem.indexOf(u8, trimmed, ": ") != null or
            std.mem.indexOf(u8, trimmed, ":\n") != null) {
            return true;
        }
        
        return false;
    }
    
    fn yamlGetFormat(base: *parser.Parser) parser.ParseOptions.Format {
        _ = base;
        return .yaml;
    }
    
    fn yamlGetName(base: *parser.Parser) []const u8 {
        _ = base;
        return "YAML Parser";
    }
    
    fn yamlDeinit(base: *parser.Parser) void {
        const self: *YamlParser = @fieldParentPtr("base", base);
        _ = self;
    }
};

// Simple YAML to JSON converter (handles basic YAML subset)
fn parseYamlToJson(allocator: std.mem.Allocator, yaml: []const u8) !std.json.Value {
    var lines = std.mem.tokenize(u8, yaml, "\n");
    var stack = std.ArrayList(YamlContext).init(allocator);
    defer stack.deinit();
    
    // Start with root object
    var root = std.json.ObjectMap.init(allocator);
    try stack.append(YamlContext{
        .value = .{ .object = &root },
        .indent = 0,
    });
    
    var line_number: u32 = 0;
    while (lines.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        // Skip comments
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, trimmed, " \t"), "#")) continue;
        
        // Calculate indentation
        const indent = getIndentation(line);
        
        // Handle different line types
        if (std.mem.startsWith(u8, trimmed[indent..], "- ")) {
            // List item
            try handleListItem(allocator, &stack, trimmed[indent + 2..], indent);
        } else if (std.mem.indexOf(u8, trimmed[indent..], ": ")) |colon_pos| {
            // Key-value pair
            const key = std.mem.trim(u8, trimmed[indent..indent + colon_pos], " \t");
            const value_part = trimmed[indent + colon_pos + 2..]; // Skip ": "
            
            try handleKeyValue(allocator, &stack, key, value_part, indent);
        } else if (std.mem.endsWith(u8, trimmed, ":")) {
            // Key with no value (object or array to follow)
            const key = std.mem.trim(u8, trimmed[indent..trimmed.len - 1], " \t");
            try handleKeyOnly(allocator, &stack, key, indent);
        }
    }
    
    return std.json.Value{ .object = root };
}

const YamlContext = struct {
    value: union(enum) {
        object: *std.json.ObjectMap,
        array: *std.json.Array,
    },
    indent: usize,
    key: ?[]const u8 = null,
};

fn getIndentation(line: []const u8) usize {
    var indent: usize = 0;
    for (line) |char| {
        if (char == ' ') {
            indent += 1;
        } else if (char == '\t') {
            indent += 4; // Treat tab as 4 spaces
        } else {
            break;
        }
    }
    return indent;
}

fn handleListItem(
    allocator: std.mem.Allocator,
    stack: *std.ArrayList(YamlContext),
    value_str: []const u8,
    indent: usize,
) !void {
    // Pop stack to appropriate level
    while (stack.items.len > 1 and stack.items[stack.items.len - 1].indent > indent) {
        _ = stack.pop();
    }
    
    const current = &stack.items[stack.items.len - 1];
    
    // Ensure we have an array context
    var array: *std.json.Array = undefined;
    switch (current.value) {
        .array => |arr| array = arr,
        .object => |obj| {
            // Need to create array for the current key
            if (current.key) |key| {
                const new_array = std.json.Array.init(allocator);
                try obj.put(key, std.json.Value{ .array = new_array });
                array = &obj.getPtr(key).?.array;
                
                // Update context
                current.value = .{ .array = array };
            } else {
                return parser.ParseError.StructureMismatch;
            }
        },
    }
    
    // Parse and add the value
    const value = try parseYamlValue(allocator, value_str);
    try array.append(value);
}

fn handleKeyValue(
    allocator: std.mem.Allocator,
    stack: *std.ArrayList(YamlContext),
    key: []const u8,
    value_str: []const u8,
    indent: usize,
) !void {
    // Pop stack to appropriate level
    while (stack.items.len > 1 and stack.items[stack.items.len - 1].indent >= indent) {
        _ = stack.pop();
    }
    
    const current = &stack.items[stack.items.len - 1];
    
    switch (current.value) {
        .object => |obj| {
            const value = try parseYamlValue(allocator, value_str);
            try obj.put(try allocator.dupe(u8, key), value);
        },
        .array => return parser.ParseError.StructureMismatch,
    }
}

fn handleKeyOnly(
    allocator: std.mem.Allocator,
    stack: *std.ArrayList(YamlContext),
    key: []const u8,
    indent: usize,
) !void {
    // Pop stack to appropriate level
    while (stack.items.len > 1 and stack.items[stack.items.len - 1].indent >= indent) {
        _ = stack.pop();
    }
    
    const current = &stack.items[stack.items.len - 1];
    
    switch (current.value) {
        .object => |obj| {
            // Create new object for this key
            const new_obj = std.json.ObjectMap.init(allocator);
            try obj.put(try allocator.dupe(u8, key), std.json.Value{ .object = new_obj });
            
            // Push new context
            try stack.append(YamlContext{
                .value = .{ .object = &obj.getPtr(key).?.object },
                .indent = indent,
                .key = key,
            });
        },
        .array => return parser.ParseError.StructureMismatch,
    }
}

fn parseYamlValue(allocator: std.mem.Allocator, value_str: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, value_str, " \t");
    
    // Empty value
    if (trimmed.len == 0) {
        return std.json.Value{ .null = {} };
    }
    
    // Quoted strings
    if ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or
        (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'')) {
        return std.json.Value{ .string = try allocator.dupe(u8, trimmed[1..trimmed.len - 1]) };
    }
    
    // Boolean
    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "yes") or 
        std.mem.eql(u8, trimmed, "on")) {
        return std.json.Value{ .bool = true };
    }
    if (std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "no") or 
        std.mem.eql(u8, trimmed, "off")) {
        return std.json.Value{ .bool = false };
    }
    
    // Null
    if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "~")) {
        return std.json.Value{ .null = {} };
    }
    
    // Number
    if (std.fmt.parseInt(i64, trimmed, 10)) |int_val| {
        return std.json.Value{ .integer = int_val };
    } else |_| {}
    
    if (std.fmt.parseFloat(f64, trimmed)) |float_val| {
        return std.json.Value{ .float = float_val };
    } else |_| {}
    
    // Default to string
    return std.json.Value{ .string = try allocator.dupe(u8, trimmed) };
}

// Tests
test "YAML parser basic" {
    const allocator = std.testing.allocator;
    
    var yaml_parser = YamlParser.init(allocator);
    defer yaml_parser.deinit();
    
    const input =
        \\name: John Doe
        \\age: 30
        \\active: true
    ;
    
    var result = try yaml_parser.base.parse(input, .{}, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expectEqual(parser.ParseOptions.Format.yaml, result.format);
    try std.testing.expectEqualStrings("John Doe", result.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 30), result.value.object.get("age").?.integer);
    try std.testing.expect(result.value.object.get("active").?.bool);
}

test "YAML parser with nested objects" {
    const allocator = std.testing.allocator;
    
    var yaml_parser = YamlParser.init(allocator);
    defer yaml_parser.deinit();
    
    const input =
        \\user:
        \\  name: Alice
        \\  email: alice@example.com
        \\status: active
    ;
    
    var result = try yaml_parser.base.parse(input, .{}, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    
    const user = result.value.object.get("user").?.object;
    try std.testing.expectEqualStrings("Alice", user.get("name").?.string);
    try std.testing.expectEqualStrings("alice@example.com", user.get("email").?.string);
    try std.testing.expectEqualStrings("active", result.value.object.get("status").?.string);
}

test "YAML parser with arrays" {
    const allocator = std.testing.allocator;
    
    var yaml_parser = YamlParser.init(allocator);
    defer yaml_parser.deinit();
    
    const input =
        \\items:
        \\  - apple
        \\  - banana
        \\  - orange
        \\count: 3
    ;
    
    var result = try yaml_parser.base.parse(input, .{}, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    
    const items = result.value.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("apple", items.items[0].string);
    try std.testing.expectEqualStrings("banana", items.items[1].string);
    try std.testing.expectEqualStrings("orange", items.items[2].string);
    try std.testing.expectEqual(@as(i64, 3), result.value.object.get("count").?.integer);
}