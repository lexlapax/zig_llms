// ABOUTME: JSON parser with error recovery for handling malformed LLM outputs
// ABOUTME: Implements intelligent recovery strategies for common JSON errors

const std = @import("std");
const parser = @import("parser.zig");
const recovery = @import("recovery.zig");

pub const JsonParser = struct {
    base: parser.Parser,
    allocator: std.mem.Allocator,
    
    const vtable = parser.Parser.VTable{
        .parse = jsonParse,
        .canParse = jsonCanParse,
        .getFormat = jsonGetFormat,
        .getName = jsonGetName,
        .deinit = jsonDeinit,
    };
    
    pub fn init(allocator: std.mem.Allocator) JsonParser {
        return .{
            .base = parser.Parser{ .vtable = &vtable },
            .allocator = allocator,
        };
    }
    
    fn jsonParse(
        base: *parser.Parser,
        input: []const u8,
        options: parser.ParseOptions,
        allocator: std.mem.Allocator,
    ) parser.ParseError!parser.ParseResult {
        const self: *JsonParser = @fieldParentPtr("base", base);
        _ = self;
        
        var warnings = std.ArrayList([]const u8).init(allocator);
        defer warnings.deinit();
        
        var errors = std.ArrayList(parser.ParseError).init(allocator);
        defer errors.deinit();
        
        // Clean the input first
        const cleaned = parser.utils.cleanLlmResponse(allocator, input) catch {
            try errors.append(parser.ParseError.InvalidFormat);
            return parser.ParseResult{
                .value = std.json.Value{ .null = {} },
                .format = .json,
                .success = false,
                .errors = try errors.toOwnedSlice(),
                .allocator = allocator,
            };
        };
        defer allocator.free(cleaned);
        
        // Extract JSON content if embedded in text
        const json_content = parser.utils.findJsonContent(cleaned) orelse cleaned;
        
        // Try parsing with standard parser first
        if (std.json.parseFromSlice(std.json.Value, allocator, json_content, .{})) |parsed| {
            // Validate against schema if provided
            if (options.validation_schema) |schema| {
                const validation_result = schema.validate(parsed.value) catch {
                    parsed.deinit();
                    try errors.append(parser.ParseError.SchemaValidationFailed);
                    return parser.ParseResult{
                        .value = std.json.Value{ .null = {} },
                        .format = .json,
                        .success = false,
                        .errors = try errors.toOwnedSlice(),
                        .allocator = allocator,
                    };
                };
                
                if (!validation_result.valid) {
                    const warning = try std.fmt.allocPrint(allocator, "Schema validation failed: {s}", .{validation_result.errors[0].message});
                    try warnings.append(warning);
                    
                    if (options.strict) {
                        parsed.deinit();
                        try errors.append(parser.ParseError.SchemaValidationFailed);
                        return parser.ParseResult{
                            .value = std.json.Value{ .null = {} },
                            .format = .json,
                            .success = false,
                            .errors = try errors.toOwnedSlice(),
                            .warnings = try warnings.toOwnedSlice(),
                            .allocator = allocator,
                        };
                    }
                }
            }
            
            // Extract specific fields if requested
            const final_value = if (options.extract_fields) |fields|
                try parser.utils.extractFields(allocator, parsed.value, fields)
            else
                parsed.value;
            
            return parser.ParseResult{
                .value = final_value,
                .format = .json,
                .success = true,
                .warnings = try warnings.toOwnedSlice(),
                .allocator = allocator,
            };
        } else |parse_error| {
            // Standard parsing failed
            if (!options.enable_recovery) {
                try errors.append(parser.ParseError.InvalidFormat);
                return parser.ParseResult{
                    .value = std.json.Value{ .null = {} },
                    .format = .json,
                    .success = false,
                    .errors = try errors.toOwnedSlice(),
                    .allocator = allocator,
                };
            }
            
            // Attempt recovery
            var recovery_attempts: u32 = 0;
            var current_content = try allocator.dupe(u8, json_content);
            defer allocator.free(current_content);
            
            while (recovery_attempts < options.max_recovery_attempts) : (recovery_attempts += 1) {
                // Try different recovery strategies
                const recovered = try attemptRecovery(allocator, current_content, parse_error);
                defer if (recovered.modified) allocator.free(recovered.content);
                
                if (!recovered.modified) {
                    break; // No more recovery strategies
                }
                
                // Try parsing recovered content
                if (std.json.parseFromSlice(std.json.Value, allocator, recovered.content, .{})) |parsed| {
                    const warning = try std.fmt.allocPrint(allocator, "Applied recovery: {s}", .{recovered.strategy});
                    try warnings.append(warning);
                    
                    // Extract fields if needed
                    const final_value = if (options.extract_fields) |fields|
                        try parser.utils.extractFields(allocator, parsed.value, fields)
                    else
                        parsed.value;
                    
                    return parser.ParseResult{
                        .value = final_value,
                        .format = .json,
                        .success = true,
                        .warnings = try warnings.toOwnedSlice(),
                        .recovery_applied = true,
                        .allocator = allocator,
                    };
                } else |_| {
                    // Recovery didn't help, try next strategy
                    allocator.free(current_content);
                    current_content = try allocator.dupe(u8, recovered.content);
                }
            }
            
            // All recovery attempts failed
            try errors.append(parser.ParseError.RecoveryFailed);
            
            // If partial results allowed, try to extract what we can
            if (options.allow_partial) {
                const partial = try extractPartialJson(allocator, current_content);
                if (partial.value != .null) {
                    const warning = try allocator.dupe(u8, "Returning partial result after recovery failed");
                    try warnings.append(warning);
                    
                    return parser.ParseResult{
                        .value = partial,
                        .format = .json,
                        .success = false,
                        .errors = try errors.toOwnedSlice(),
                        .warnings = try warnings.toOwnedSlice(),
                        .recovery_applied = true,
                        .allocator = allocator,
                    };
                }
            }
            
            return parser.ParseResult{
                .value = std.json.Value{ .null = {} },
                .format = .json,
                .success = false,
                .errors = try errors.toOwnedSlice(),
                .warnings = try warnings.toOwnedSlice(),
                .allocator = allocator,
            };
        }
    }
    
    fn jsonCanParse(base: *parser.Parser, input: []const u8) bool {
        _ = base;
        
        // Quick checks for JSON-like content
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        
        // Check for JSON markers
        if (std.mem.indexOf(u8, trimmed, "{") != null or 
            std.mem.indexOf(u8, trimmed, "[") != null) {
            return true;
        }
        
        // Check for JSON in code blocks
        if (parser.utils.extractCodeBlock(input, "json") != null) {
            return true;
        }
        
        return false;
    }
    
    fn jsonGetFormat(base: *parser.Parser) parser.ParseOptions.Format {
        _ = base;
        return .json;
    }
    
    fn jsonGetName(base: *parser.Parser) []const u8 {
        _ = base;
        return "JSON Parser";
    }
    
    fn jsonDeinit(base: *parser.Parser) void {
        const self: *JsonParser = @fieldParentPtr("base", base);
        _ = self;
    }
};

const RecoveryResult = struct {
    content: []const u8,
    modified: bool,
    strategy: []const u8,
};

fn attemptRecovery(
    allocator: std.mem.Allocator,
    content: []const u8,
    parse_error: anyerror,
) !RecoveryResult {
    _ = parse_error;
    
    // Try recovery strategies in order
    
    // 1. Fix unquoted keys
    if (try recovery.fixUnquotedKeys(allocator, content)) |fixed| {
        return RecoveryResult{
            .content = fixed,
            .modified = true,
            .strategy = "Fixed unquoted keys",
        };
    }
    
    // 2. Fix trailing commas
    if (try recovery.fixTrailingCommas(allocator, content)) |fixed| {
        return RecoveryResult{
            .content = fixed,
            .modified = true,
            .strategy = "Fixed trailing commas",
        };
    }
    
    // 3. Fix single quotes
    if (try recovery.fixSingleQuotes(allocator, content)) |fixed| {
        return RecoveryResult{
            .content = fixed,
            .modified = true,
            .strategy = "Fixed single quotes",
        };
    }
    
    // 4. Fix missing commas
    if (try recovery.fixMissingCommas(allocator, content)) |fixed| {
        return RecoveryResult{
            .content = fixed,
            .modified = true,
            .strategy = "Fixed missing commas",
        };
    }
    
    // 5. Fix unclosed structures
    if (try recovery.fixUnclosedStructures(allocator, content)) |fixed| {
        return RecoveryResult{
            .content = fixed,
            .modified = true,
            .strategy = "Fixed unclosed structures",
        };
    }
    
    // 6. Fix invalid escape sequences
    if (try recovery.fixInvalidEscapes(allocator, content)) |fixed| {
        return RecoveryResult{
            .content = fixed,
            .modified = true,
            .strategy = "Fixed invalid escapes",
        };
    }
    
    // No recovery applied
    return RecoveryResult{
        .content = content,
        .modified = false,
        .strategy = "None",
    };
}

fn extractPartialJson(allocator: std.mem.Allocator, content: []const u8) !std.json.Value {
    // Try to extract valid key-value pairs even if overall structure is broken
    var result = std.json.ObjectMap.init(allocator);
    errdefer result.deinit();
    
    // Simple pattern matching for "key": value pairs
    var pos: usize = 0;
    while (pos < content.len) {
        // Find potential key
        const quote_start = std.mem.indexOf(u8, content[pos..], "\"") orelse break;
        const key_start = pos + quote_start + 1;
        
        const quote_end = std.mem.indexOf(u8, content[key_start..], "\"") orelse break;
        const key_end = key_start + quote_end;
        
        const key = content[key_start..key_end];
        
        // Find colon
        const colon_pos = std.mem.indexOf(u8, content[key_end..], ":") orelse break;
        const value_start = key_end + colon_pos + 1;
        
        // Try to extract value (simplified - just handles strings and numbers)
        const trimmed_value_start = std.mem.indexOfNone(u8, content[value_start..], " \t\r\n") orelse break;
        const actual_value_start = value_start + trimmed_value_start;
        
        if (actual_value_start >= content.len) break;
        
        switch (content[actual_value_start]) {
            '"' => {
                // String value
                if (std.mem.indexOf(u8, content[actual_value_start + 1..], "\"")) |end| {
                    const value = content[actual_value_start + 1..actual_value_start + 1 + end];
                    try result.put(try allocator.dupe(u8, key), std.json.Value{ .string = try allocator.dupe(u8, value) });
                    pos = actual_value_start + 1 + end + 1;
                } else {
                    break;
                }
            },
            '0'...'9', '-' => {
                // Number value
                var end = actual_value_start + 1;
                while (end < content.len and (std.ascii.isDigit(content[end]) or content[end] == '.')) : (end += 1) {}
                
                const num_str = content[actual_value_start..end];
                if (std.fmt.parseInt(i64, num_str, 10)) |int_val| {
                    try result.put(try allocator.dupe(u8, key), std.json.Value{ .integer = int_val });
                } else if (std.fmt.parseFloat(f64, num_str)) |float_val| {
                    try result.put(try allocator.dupe(u8, key), std.json.Value{ .float = float_val });
                } else |_| {}
                
                pos = end;
            },
            't', 'f' => {
                // Boolean value
                if (std.mem.startsWith(u8, content[actual_value_start..], "true")) {
                    try result.put(try allocator.dupe(u8, key), std.json.Value{ .bool = true });
                    pos = actual_value_start + 4;
                } else if (std.mem.startsWith(u8, content[actual_value_start..], "false")) {
                    try result.put(try allocator.dupe(u8, key), std.json.Value{ .bool = false });
                    pos = actual_value_start + 5;
                } else {
                    break;
                }
            },
            'n' => {
                // Null value
                if (std.mem.startsWith(u8, content[actual_value_start..], "null")) {
                    try result.put(try allocator.dupe(u8, key), std.json.Value{ .null = {} });
                    pos = actual_value_start + 4;
                } else {
                    break;
                }
            },
            else => break,
        }
    }
    
    if (result.count() > 0) {
        return std.json.Value{ .object = result };
    }
    
    result.deinit();
    return std.json.Value{ .null = {} };
}

// Tests
test "JSON parser basic" {
    const allocator = std.testing.allocator;
    
    var json_parser = JsonParser.init(allocator);
    defer json_parser.deinit();
    
    const input = "{\"key\": \"value\", \"number\": 42}";
    var result = try json_parser.base.parse(input, .{}, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expectEqual(parser.ParseOptions.Format.json, result.format);
    try std.testing.expectEqualStrings("value", result.value.object.get("key").?.string);
    try std.testing.expectEqual(@as(i64, 42), result.value.object.get("number").?.integer);
}

test "JSON parser with markdown code block" {
    const allocator = std.testing.allocator;
    
    var json_parser = JsonParser.init(allocator);
    defer json_parser.deinit();
    
    const input =
        \\Here is the JSON response:
        \\```json
        \\{"status": "ok"}
        \\```
    ;
    
    var result = try json_parser.base.parse(input, .{}, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("ok", result.value.object.get("status").?.string);
}

test "JSON parser field extraction" {
    const allocator = std.testing.allocator;
    
    var json_parser = JsonParser.init(allocator);
    defer json_parser.deinit();
    
    const input = "{\"user\": {\"name\": \"John\", \"age\": 30}, \"status\": \"active\"}";
    const fields = [_][]const u8{ "user.name", "status" };
    
    var result = try json_parser.base.parse(input, .{ .extract_fields = &fields }, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("John", result.value.object.get("name").?.string);
    try std.testing.expectEqualStrings("active", result.value.object.get("status").?.string);
    try std.testing.expect(result.value.object.get("age") == null); // Not extracted
}