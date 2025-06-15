// ABOUTME: Recovery strategies for fixing common JSON formatting errors
// ABOUTME: Implements heuristic-based fixes for malformed JSON from LLMs

const std = @import("std");

// Fix unquoted keys in JSON objects
pub fn fixUnquotedKeys(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    var in_string = false;
    var escape = false;
    var modified = false;
    
    while (i < content.len) : (i += 1) {
        const char = content[i];
        
        // Track string boundaries
        if (!escape and char == '"') {
            in_string = !in_string;
        }
        
        if (in_string) {
            if (char == '\\' and !escape) {
                escape = true;
            } else {
                escape = false;
            }
            try result.append(char);
            continue;
        }
        
        // Look for unquoted keys (letter followed by colon)
        if (std.ascii.isAlphabetic(char) and i > 0 and 
            (content[i-1] == '{' or content[i-1] == ',' or std.ascii.isWhitespace(content[i-1]))) {
            
            // Find the end of the potential key
            var key_end = i + 1;
            while (key_end < content.len and 
                   (std.ascii.isAlphanumeric(content[key_end]) or content[key_end] == '_')) {
                key_end += 1;
            }
            
            // Skip whitespace
            var colon_pos = key_end;
            while (colon_pos < content.len and std.ascii.isWhitespace(content[colon_pos])) {
                colon_pos += 1;
            }
            
            // Check if followed by colon
            if (colon_pos < content.len and content[colon_pos] == ':') {
                // Add quotes around the key
                try result.append('"');
                try result.appendSlice(content[i..key_end]);
                try result.append('"');
                i = key_end - 1; // -1 because loop will increment
                modified = true;
                continue;
            }
        }
        
        try result.append(char);
    }
    
    if (modified) {
        return result.toOwnedSlice();
    }
    
    return null;
}

// Fix trailing commas in arrays and objects
pub fn fixTrailingCommas(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    var in_string = false;
    var escape = false;
    var modified = false;
    
    while (i < content.len) : (i += 1) {
        const char = content[i];
        
        // Track string boundaries
        if (!escape and char == '"') {
            in_string = !in_string;
        }
        
        if (in_string) {
            if (char == '\\' and !escape) {
                escape = true;
            } else {
                escape = false;
            }
            try result.append(char);
            continue;
        }
        
        // Look for trailing comma before closing bracket/brace
        if (char == ',') {
            // Skip whitespace after comma
            var next_pos = i + 1;
            while (next_pos < content.len and std.ascii.isWhitespace(content[next_pos])) {
                next_pos += 1;
            }
            
            // Check if followed by closing bracket/brace
            if (next_pos < content.len and (content[next_pos] == '}' or content[next_pos] == ']')) {
                // Skip the comma
                modified = true;
                continue;
            }
        }
        
        try result.append(char);
    }
    
    if (modified) {
        return result.toOwnedSlice();
    }
    
    return null;
}

// Convert single quotes to double quotes
pub fn fixSingleQuotes(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    var in_string = false;
    var string_delimiter: u8 = 0;
    var escape = false;
    var modified = false;
    
    while (i < content.len) : (i += 1) {
        const char = content[i];
        
        if (!escape and (char == '"' or char == '\'')) {
            if (!in_string) {
                in_string = true;
                string_delimiter = char;
                if (char == '\'') {
                    try result.append('"');
                    modified = true;
                } else {
                    try result.append(char);
                }
            } else if (char == string_delimiter) {
                in_string = false;
                if (char == '\'') {
                    try result.append('"');
                    modified = true;
                } else {
                    try result.append(char);
                }
                string_delimiter = 0;
            } else {
                // Quote inside string
                try result.append(char);
            }
        } else {
            if (in_string and char == '\\' and !escape) {
                escape = true;
            } else {
                escape = false;
            }
            try result.append(char);
        }
    }
    
    if (modified) {
        return result.toOwnedSlice();
    }
    
    return null;
}

// Add missing commas between array/object elements
pub fn fixMissingCommas(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    var in_string = false;
    var escape = false;
    var modified = false;
    var last_value_end: ?usize = null;
    
    while (i < content.len) : (i += 1) {
        const char = content[i];
        
        // Track string boundaries
        if (!escape and char == '"') {
            if (!in_string) {
                in_string = true;
                
                // Check if we need a comma before this string
                if (last_value_end) |end_pos| {
                    // Check if there's already a comma
                    var has_comma = false;
                    var check_pos = end_pos;
                    while (check_pos < i) : (check_pos += 1) {
                        if (content[check_pos] == ',') {
                            has_comma = true;
                            break;
                        } else if (!std.ascii.isWhitespace(content[check_pos])) {
                            break;
                        }
                    }
                    
                    if (!has_comma and check_pos < i) {
                        // Insert comma
                        const pre_content = result.items[0..end_pos];
                        const post_content = result.items[end_pos..];
                        
                        var new_result = std.ArrayList(u8).init(allocator);
                        try new_result.appendSlice(pre_content);
                        try new_result.append(',');
                        try new_result.appendSlice(post_content);
                        
                        result.deinit();
                        result = new_result;
                        modified = true;
                    }
                }
            } else {
                in_string = false;
                last_value_end = result.items.len + 1;
            }
        }
        
        if (in_string and char == '\\' and !escape) {
            escape = true;
        } else {
            escape = false;
        }
        
        try result.append(char);
    }
    
    if (modified) {
        return result.toOwnedSlice();
    }
    
    return null;
}

// Close unclosed structures (add missing brackets/braces)
pub fn fixUnclosedStructures(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var depth_stack = std.ArrayList(u8).init(allocator);
    defer depth_stack.deinit();
    
    var in_string = false;
    var escape = false;
    
    // First pass: track structure depth
    for (content) |char| {
        if (!escape and char == '"') {
            in_string = !in_string;
        }
        
        if (in_string) {
            if (char == '\\' and !escape) {
                escape = true;
            } else {
                escape = false;
            }
        } else {
            switch (char) {
                '{' => try depth_stack.append('}'),
                '[' => try depth_stack.append(']'),
                '}', ']' => {
                    if (depth_stack.items.len > 0) {
                        const expected = depth_stack.pop();
                        if (expected != char) {
                            // Mismatched bracket/brace - this is more complex to fix
                            return null;
                        }
                    }
                },
                else => {},
            }
        }
        
        try result.append(char);
    }
    
    // Add missing closing brackets/braces
    if (depth_stack.items.len > 0) {
        // Add them in reverse order
        while (depth_stack.popOrNull()) |closer| {
            try result.append(closer);
        }
        
        return result.toOwnedSlice();
    }
    
    return null;
}

// Fix invalid escape sequences
pub fn fixInvalidEscapes(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var i: usize = 0;
    var in_string = false;
    var modified = false;
    
    while (i < content.len) : (i += 1) {
        const char = content[i];
        
        if (char == '"' and (i == 0 or content[i-1] != '\\')) {
            in_string = !in_string;
            try result.append(char);
            continue;
        }
        
        if (in_string and char == '\\' and i + 1 < content.len) {
            const next_char = content[i + 1];
            
            // Check if valid escape sequence
            switch (next_char) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {
                    // Valid escape
                    try result.append(char);
                    try result.append(next_char);
                    i += 1;
                },
                'u' => {
                    // Unicode escape - check if valid
                    if (i + 5 < content.len) {
                        var valid_unicode = true;
                        for (content[i+2..i+6]) |hex_char| {
                            if (!std.ascii.isHex(hex_char)) {
                                valid_unicode = false;
                                break;
                            }
                        }
                        
                        if (valid_unicode) {
                            try result.appendSlice(content[i..i+6]);
                            i += 5;
                        } else {
                            // Invalid unicode escape - escape the backslash
                            try result.appendSlice("\\\\");
                            modified = true;
                        }
                    } else {
                        // Incomplete unicode escape
                        try result.appendSlice("\\\\");
                        modified = true;
                    }
                },
                else => {
                    // Invalid escape - escape the backslash
                    try result.appendSlice("\\\\");
                    modified = true;
                },
            }
        } else {
            try result.append(char);
        }
    }
    
    if (modified) {
        return result.toOwnedSlice();
    }
    
    return null;
}

// Advanced recovery: try to infer structure from content patterns
pub fn inferStructure(allocator: std.mem.Allocator, content: []const u8) !?[]const u8 {
    // Look for key-value patterns and try to build valid JSON
    var lines = std.mem.tokenize(u8, content, "\n");
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    try result.append('{');
    var first = true;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        
        // Look for key: value pattern
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            if (colon_pos > 0 and colon_pos < trimmed.len - 1) {
                if (!first) {
                    try result.append(',');
                }
                first = false;
                
                // Extract and quote key
                const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t\"'");
                try result.append('"');
                try result.appendSlice(key);
                try result.appendSlice("\":");
                
                // Extract and format value
                const value = std.mem.trim(u8, trimmed[colon_pos+1..], " \t");
                
                // Determine value type
                if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false") or
                    std.mem.eql(u8, value, "null")) {
                    try result.appendSlice(value);
                } else if (std.fmt.parseInt(i64, value, 10)) |_| {
                    try result.appendSlice(value);
                } else if (std.fmt.parseFloat(f64, value)) |_| {
                    try result.appendSlice(value);
                } else {
                    // String value - ensure quoted
                    if (value.len >= 2 and value[0] == '"' and value[value.len-1] == '"') {
                        try result.appendSlice(value);
                    } else {
                        try result.append('"');
                        // Escape any quotes in the value
                        for (value) |char| {
                            if (char == '"') {
                                try result.appendSlice("\\\"");
                            } else {
                                try result.append(char);
                            }
                        }
                        try result.append('"');
                    }
                }
            }
        }
    }
    
    try result.append('}');
    
    // Only return if we found at least one key-value pair
    if (!first) {
        return result.toOwnedSlice();
    }
    
    return null;
}

// Tests
test "fix unquoted keys" {
    const allocator = std.testing.allocator;
    
    const input = "{name: \"John\", age: 30}";
    const fixed = try fixUnquotedKeys(allocator, input);
    defer if (fixed) |f| allocator.free(f);
    
    try std.testing.expect(fixed != null);
    try std.testing.expectEqualStrings("{\"name\": \"John\", \"age\": 30}", fixed.?);
}

test "fix trailing commas" {
    const allocator = std.testing.allocator;
    
    const input = "[1, 2, 3,]";
    const fixed = try fixTrailingCommas(allocator, input);
    defer if (fixed) |f| allocator.free(f);
    
    try std.testing.expect(fixed != null);
    try std.testing.expectEqualStrings("[1, 2, 3]", fixed.?);
}

test "fix single quotes" {
    const allocator = std.testing.allocator;
    
    const input = "{'key': 'value'}";
    const fixed = try fixSingleQuotes(allocator, input);
    defer if (fixed) |f| allocator.free(f);
    
    try std.testing.expect(fixed != null);
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", fixed.?);
}

test "fix unclosed structures" {
    const allocator = std.testing.allocator;
    
    const input = "{\"key\": \"value\"";
    const fixed = try fixUnclosedStructures(allocator, input);
    defer if (fixed) |f| allocator.free(f);
    
    try std.testing.expect(fixed != null);
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", fixed.?);
}

test "fix invalid escapes" {
    const allocator = std.testing.allocator;
    
    const input = "{\"path\": \"C:\\Users\\name\"}";
    const fixed = try fixInvalidEscapes(allocator, input);
    defer if (fixed) |f| allocator.free(f);
    
    try std.testing.expect(fixed != null);
    try std.testing.expectEqualStrings("{\"path\": \"C:\\\\Users\\\\name\"}", fixed.?);
}

test "infer structure" {
    const allocator = std.testing.allocator;
    
    const input =
        \\name: John Doe
        \\age: 30
        \\active: true
    ;
    
    const fixed = try inferStructure(allocator, input);
    defer if (fixed) |f| allocator.free(f);
    
    try std.testing.expect(fixed != null);
    
    // Parse to verify it's valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixed.?, .{});
    defer parsed.deinit();
    
    try std.testing.expectEqualStrings("John Doe", parsed.value.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 30), parsed.value.object.get("age").?.integer);
    try std.testing.expect(parsed.value.object.get("active").?.bool);
}