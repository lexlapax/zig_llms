// ABOUTME: Default parser registry with all built-in parsers pre-registered
// ABOUTME: Provides automatic format detection and parsing for LLM outputs

const std = @import("std");
const parser = @import("parser.zig");
const json_parser = @import("json_parser.zig");
const yaml_parser = @import("yaml_parser.zig");

pub fn createDefaultRegistry(allocator: std.mem.Allocator) !parser.ParserRegistry {
    var registry = parser.ParserRegistry.init(allocator);
    errdefer registry.deinit();
    
    // Register JSON parser
    const json = try allocator.create(json_parser.JsonParser);
    json.* = json_parser.JsonParser.init(allocator);
    try registry.register(&json.base);
    
    // Register YAML parser
    const yaml = try allocator.create(yaml_parser.YamlParser);
    yaml.* = yaml_parser.YamlParser.init(allocator);
    try registry.register(&yaml.base);
    
    // Additional parsers can be added here as they're implemented
    // e.g., XML parser, Markdown parser, etc.
    
    return registry;
}

// Convenience function to parse with automatic format detection
pub fn parseAny(
    allocator: std.mem.Allocator,
    input: []const u8,
    options: parser.ParseOptions,
) !parser.ParseResult {
    var registry = try createDefaultRegistry(allocator);
    defer registry.deinit();
    
    return registry.parse(input, options);
}

// Parse with schema validation
pub fn parseWithSchema(
    allocator: std.mem.Allocator,
    input: []const u8,
    schema: @import("../schema/validator.zig").Schema,
) !parser.ParseResult {
    const options = parser.ParseOptions{
        .validation_schema = schema,
        .strict = true,
    };
    
    return parseAny(allocator, input, options);
}

// Parse and extract specific fields
pub fn parseAndExtract(
    allocator: std.mem.Allocator,
    input: []const u8,
    fields: []const []const u8,
) !parser.ParseResult {
    const options = parser.ParseOptions{
        .extract_fields = fields,
    };
    
    return parseAny(allocator, input, options);
}

// Tests
test "registry with multiple formats" {
    const allocator = std.testing.allocator;
    
    var registry = try createDefaultRegistry(allocator);
    defer registry.deinit();
    
    // Test JSON parsing
    {
        const json_input = "{\"format\": \"json\", \"valid\": true}";
        var result = try registry.parse(json_input, .{});
        defer result.deinit();
        
        try std.testing.expect(result.success);
        try std.testing.expectEqual(parser.ParseOptions.Format.json, result.format);
        try std.testing.expectEqualStrings("json", result.value.object.get("format").?.string);
    }
    
    // Test YAML parsing
    {
        const yaml_input = 
            \\format: yaml
            \\valid: true
        ;
        var result = try registry.parse(yaml_input, .{});
        defer result.deinit();
        
        try std.testing.expect(result.success);
        try std.testing.expectEqual(parser.ParseOptions.Format.yaml, result.format);
        try std.testing.expectEqualStrings("yaml", result.value.object.get("format").?.string);
    }
}

test "parse any format" {
    const allocator = std.testing.allocator;
    
    // Test with JSON in markdown
    {
        const input = 
            \\Here's the response:
            \\```json
            \\{"status": "success", "code": 200}
            \\```
        ;
        
        var result = try parseAny(allocator, input, .{});
        defer result.deinit();
        
        try std.testing.expect(result.success);
        try std.testing.expectEqualStrings("success", result.value.object.get("status").?.string);
        try std.testing.expectEqual(@as(i64, 200), result.value.object.get("code").?.integer);
    }
    
    // Test with YAML
    {
        const input = 
            \\---
            \\status: success
            \\code: 200
        ;
        
        var result = try parseAny(allocator, input, .{});
        defer result.deinit();
        
        try std.testing.expect(result.success);
        try std.testing.expectEqualStrings("success", result.value.object.get("status").?.string);
        try std.testing.expectEqual(@as(i64, 200), result.value.object.get("code").?.integer);
    }
}

test "parse and extract fields" {
    const allocator = std.testing.allocator;
    
    const input = 
        \\{
        \\  "user": {
        \\    "id": 123,
        \\    "name": "Alice",
        \\    "email": "alice@example.com"
        \\  },
        \\  "metadata": {
        \\    "timestamp": 1234567890,
        \\    "version": "1.0"
        \\  }
        \\}
    ;
    
    const fields = [_][]const u8{ "user.name", "user.email", "metadata.version" };
    var result = try parseAndExtract(allocator, input, &fields);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Alice", result.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("alice@example.com", result.value.object.get("email").?.string);
    try std.testing.expectEqualStrings("1.0", result.value.object.get("version").?.string);
    
    // Verify unextracted fields are not present
    try std.testing.expect(result.value.object.get("id") == null);
    try std.testing.expect(result.value.object.get("timestamp") == null);
}