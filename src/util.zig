// ABOUTME: Common utility functions used across the zig_llms library
// ABOUTME: Provides JSON handling, HTTP client wrappers, and string utilities

const std = @import("std");

// JSON utilities
pub const json = struct {
    pub fn parseFromString(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    }
    
    pub fn stringify(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
        return std.json.stringifyAlloc(allocator, value, .{});
    }
    
    pub fn getValue(object: std.json.ObjectMap, key: []const u8) ?std.json.Value {
        return object.get(key);
    }
    
    pub fn getStringValue(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        if (getValue(object, key)) |value| {
            switch (value) {
                .string => |s| return s,
                else => return null,
            }
        }
        return null;
    }
    
    pub fn getIntValue(object: std.json.ObjectMap, key: []const u8) ?i64 {
        if (getValue(object, key)) |value| {
            switch (value) {
                .integer => |i| return i,
                else => return null,
            }
        }
        return null;
    }
    
    pub fn getBoolValue(object: std.json.ObjectMap, key: []const u8) ?bool {
        if (getValue(object, key)) |value| {
            switch (value) {
                .bool => |b| return b,
                else => return null,
            }
        }
        return null;
    }
};

// String utilities
pub const string = struct {
    pub fn trim(input: []const u8) []const u8 {
        return std.mem.trim(u8, input, " \t\r\n");
    }
    
    pub fn startsWith(input: []const u8, prefix: []const u8) bool {
        return std.mem.startsWith(u8, input, prefix);
    }
    
    pub fn endsWith(input: []const u8, suffix: []const u8) bool {
        return std.mem.endsWith(u8, input, suffix);
    }
    
    pub fn contains(input: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, input, needle) != null;
    }
    
    pub fn split(allocator: std.mem.Allocator, input: []const u8, delimiter: []const u8) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(allocator);
        defer result.deinit();
        
        var iter = std.mem.split(u8, input, delimiter);
        while (iter.next()) |part| {
            try result.append(part);
        }
        
        return result.toOwnedSlice();
    }
    
    pub fn join(allocator: std.mem.Allocator, parts: []const []const u8, delimiter: []const u8) ![]const u8 {
        if (parts.len == 0) return try allocator.dupe(u8, "");
        if (parts.len == 1) return try allocator.dupe(u8, parts[0]);
        
        var total_len: usize = 0;
        for (parts) |part| {
            total_len += part.len;
        }
        total_len += (parts.len - 1) * delimiter.len;
        
        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;
        
        for (parts, 0..) |part, i| {
            @memcpy(result[pos..pos + part.len], part);
            pos += part.len;
            
            if (i < parts.len - 1) {
                @memcpy(result[pos..pos + delimiter.len], delimiter);
                pos += delimiter.len;
            }
        }
        
        return result;
    }
};

// HTTP client wrapper (basic)
pub const http = struct {
    pub const Response = struct {
        status: u16,
        body: []const u8,
        headers: std.StringHashMap([]const u8),
        
        pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
            allocator.free(self.body);
            self.headers.deinit();
        }
    };
    
    pub fn get(allocator: std.mem.Allocator, url: []const u8) !Response {
        // TODO: Implement HTTP GET request
        _ = url;
        return Response{
            .status = 200,
            .body = try allocator.dupe(u8, ""),
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn post(allocator: std.mem.Allocator, url: []const u8, body: []const u8, headers: ?std.StringHashMap([]const u8)) !Response {
        // TODO: Implement HTTP POST request
        _ = url;
        _ = body;
        _ = headers;
        return Response{
            .status = 200,
            .body = try allocator.dupe(u8, ""),
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }
};

// Time utilities
pub const time = struct {
    pub fn now() i64 {
        return std.time.timestamp();
    }
    
    pub fn nowMillis() i64 {
        return std.time.milliTimestamp();
    }
    
    pub fn formatTimestamp(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
        // TODO: Implement timestamp formatting
        return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
    }
};

// Testing utilities
pub const testing = struct {
    pub fn expectEqualJson(allocator: std.mem.Allocator, expected: std.json.Value, actual: std.json.Value) !void {
        const expected_str = try json.stringify(allocator, expected);
        defer allocator.free(expected_str);
        
        const actual_str = try json.stringify(allocator, actual);
        defer allocator.free(actual_str);
        
        try std.testing.expectEqualStrings(expected_str, actual_str);
    }
};

test "json utilities" {
    const allocator = std.testing.allocator;
    
    const test_json = 
        \\{"name": "test", "value": 42, "active": true}
    ;
    
    const parsed = try json.parseFromString(allocator, test_json);
    defer parsed.deinit();
    
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("test", json.getStringValue(obj, "name").?);
    try std.testing.expectEqual(@as(i64, 42), json.getIntValue(obj, "value").?);
    try std.testing.expectEqual(true, json.getBoolValue(obj, "active").?);
}

test "string utilities" {
    const allocator = std.testing.allocator;
    
    try std.testing.expectEqualStrings("hello", string.trim("  hello  "));
    try std.testing.expect(string.startsWith("hello world", "hello"));
    try std.testing.expect(string.endsWith("hello world", "world"));
    try std.testing.expect(string.contains("hello world", "lo wo"));
    
    const parts = try string.split(allocator, "a,b,c", ",");
    defer allocator.free(parts);
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("c", parts[2]);
    
    const joined = try string.join(allocator, parts, "|");
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("a|b|c", joined);
}