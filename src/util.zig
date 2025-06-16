// ABOUTME: Common utility functions used across the zig_llms library
// ABOUTME: Provides JSON handling, HTTP client wrappers, and string utilities

const std = @import("std");

// JSON utilities
pub const json = struct {
    pub fn parseFromString(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
        return std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    }

    pub fn parseFromStringLeaky(allocator: std.mem.Allocator, input: []const u8) !std.json.Value {
        const parsed = try parseFromString(allocator, input);
        return parsed.value;
    }

    pub fn parseFromFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(std.json.Value) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10MB max
        defer allocator.free(content);

        return parseFromString(allocator, content);
    }

    pub fn stringify(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
        return std.json.stringifyAlloc(allocator, value, .{});
    }

    pub fn stringifyPretty(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
        return std.json.stringifyAlloc(allocator, value, .{ .whitespace = .{ .indent = .{ .space = 2 } } });
    }

    pub fn writeToFile(path: []const u8, value: std.json.Value, allocator: std.mem.Allocator) !void {
        const json_string = try stringifyPretty(allocator, value);
        defer allocator.free(json_string);

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        try file.writeAll(json_string);
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

    pub fn getFloatValue(object: std.json.ObjectMap, key: []const u8) ?f64 {
        if (getValue(object, key)) |value| {
            switch (value) {
                .float => |f| return f,
                .integer => |i| return @as(f64, @floatFromInt(i)),
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

    pub fn getArrayValue(object: std.json.ObjectMap, key: []const u8) ?std.json.Array {
        if (getValue(object, key)) |value| {
            switch (value) {
                .array => |a| return a,
                else => return null,
            }
        }
        return null;
    }

    pub fn getObjectValue(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
        if (getValue(object, key)) |value| {
            switch (value) {
                .object => |o| return o,
                else => return null,
            }
        }
        return null;
    }

    // Path-based access (e.g., "user.profile.name")
    pub fn getValueByPath(root: std.json.Value, path: []const u8) ?std.json.Value {
        var current = root;
        var iter = std.mem.tokenize(u8, path, ".");

        while (iter.next()) |segment| {
            switch (current) {
                .object => |obj| {
                    if (obj.get(segment)) |next| {
                        current = next;
                    } else {
                        return null;
                    }
                },
                .array => |arr| {
                    const index = std.fmt.parseInt(usize, segment, 10) catch return null;
                    if (index >= arr.items.len) return null;
                    current = arr.items[index];
                },
                else => return null,
            }
        }

        return current;
    }

    // Deep merge two JSON objects
    pub fn merge(allocator: std.mem.Allocator, base: std.json.Value, overlay: std.json.Value) !std.json.Value {
        if (base != .object or overlay != .object) {
            return overlay; // Non-objects: overlay wins
        }

        var result = std.json.ObjectMap.init(allocator);
        errdefer result.deinit();

        // Copy base values
        var base_iter = base.object.iterator();
        while (base_iter.next()) |entry| {
            try result.put(entry.key_ptr.*, entry.value_ptr.*);
        }

        // Overlay values
        var overlay_iter = overlay.object.iterator();
        while (overlay_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const overlay_value = entry.value_ptr.*;

            if (result.get(key)) |base_value| {
                // Recursive merge for nested objects
                if (base_value == .object and overlay_value == .object) {
                    const merged = try merge(allocator, base_value, overlay_value);
                    try result.put(key, merged);
                } else {
                    try result.put(key, overlay_value);
                }
            } else {
                try result.put(key, overlay_value);
            }
        }

        return std.json.Value{ .object = result };
    }

    // Create a JSON object builder
    pub const ObjectBuilder = struct {
        allocator: std.mem.Allocator,
        object: std.json.ObjectMap,

        pub fn init(allocator: std.mem.Allocator) ObjectBuilder {
            return .{
                .allocator = allocator,
                .object = std.json.ObjectMap.init(allocator),
            };
        }

        pub fn deinit(self: *ObjectBuilder) void {
            self.object.deinit();
        }

        pub fn put(self: *ObjectBuilder, key: []const u8, value: anytype) !*ObjectBuilder {
            const T = @TypeOf(value);
            const json_value = switch (@typeInfo(T)) {
                .Bool => std.json.Value{ .bool = value },
                .Int => std.json.Value{ .integer = @as(i64, @intCast(value)) },
                .Float => std.json.Value{ .float = @as(f64, @floatCast(value)) },
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => if (ptr.child == u8)
                        std.json.Value{ .string = value }
                    else
                        return error.UnsupportedType,
                    else => return error.UnsupportedType,
                },
                .Null => std.json.Value{ .null = {} },
                else => return error.UnsupportedType,
            };

            try self.object.put(key, json_value);
            return self;
        }

        pub fn putObject(self: *ObjectBuilder, key: []const u8, object: std.json.ObjectMap) !*ObjectBuilder {
            try self.object.put(key, .{ .object = object });
            return self;
        }

        pub fn putArray(self: *ObjectBuilder, key: []const u8, array: std.json.Array) !*ObjectBuilder {
            try self.object.put(key, .{ .array = array });
            return self;
        }

        pub fn build(self: *ObjectBuilder) std.json.Value {
            return .{ .object = self.object };
        }
    };

    // Create a JSON array builder
    pub const ArrayBuilder = struct {
        allocator: std.mem.Allocator,
        array: std.json.Array,

        pub fn init(allocator: std.mem.Allocator) ArrayBuilder {
            return .{
                .allocator = allocator,
                .array = std.json.Array.init(allocator),
            };
        }

        pub fn deinit(self: *ArrayBuilder) void {
            self.array.deinit();
        }

        pub fn append(self: *ArrayBuilder, value: anytype) !*ArrayBuilder {
            const T = @TypeOf(value);
            const json_value = switch (@typeInfo(T)) {
                .Bool => std.json.Value{ .bool = value },
                .Int => std.json.Value{ .integer = @as(i64, @intCast(value)) },
                .Float => std.json.Value{ .float = @as(f64, @floatCast(value)) },
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => if (ptr.child == u8)
                        std.json.Value{ .string = value }
                    else
                        return error.UnsupportedType,
                    else => return error.UnsupportedType,
                },
                .Null => std.json.Value{ .null = {} },
                else => return error.UnsupportedType,
            };

            try self.array.append(json_value);
            return self;
        }

        pub fn appendObject(self: *ArrayBuilder, object: std.json.ObjectMap) !*ArrayBuilder {
            try self.array.append(.{ .object = object });
            return self;
        }

        pub fn appendArray(self: *ArrayBuilder, array: std.json.Array) !*ArrayBuilder {
            try self.array.append(.{ .array = array });
            return self;
        }

        pub fn build(self: *ArrayBuilder) std.json.Value {
            return .{ .array = self.array };
        }
    };
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
            @memcpy(result[pos .. pos + part.len], part);
            pos += part.len;

            if (i < parts.len - 1) {
                @memcpy(result[pos .. pos + delimiter.len], delimiter);
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

test "json path-based access" {
    const allocator = std.testing.allocator;

    var builder = json.ObjectBuilder.init(allocator);
    defer builder.deinit();

    var profile = json.ObjectBuilder.init(allocator);
    defer profile.deinit();

    _ = try profile.put("name", "John Doe");
    _ = try profile.put("age", 30);

    _ = try builder.put("id", 123);
    _ = try builder.putObject("profile", profile.object);

    const obj = builder.build();

    // Test path access
    const name = json.getValueByPath(obj, "profile.name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("John Doe", name.?.string);

    const age = json.getValueByPath(obj, "profile.age");
    try std.testing.expect(age != null);
    try std.testing.expectEqual(@as(i64, 30), age.?.integer);

    const missing = json.getValueByPath(obj, "profile.missing");
    try std.testing.expect(missing == null);
}

test "json builders" {
    const allocator = std.testing.allocator;

    // Object builder test
    {
        var builder = json.ObjectBuilder.init(allocator);
        defer builder.deinit();

        _ = try builder.put("name", "test");
        _ = try builder.put("count", 42);
        _ = try builder.put("active", true);

        const obj = builder.build();

        try std.testing.expectEqualStrings("test", obj.object.get("name").?.string);
        try std.testing.expectEqual(@as(i64, 42), obj.object.get("count").?.integer);
        try std.testing.expect(obj.object.get("active").?.bool);
    }

    // Array builder test
    {
        var builder = json.ArrayBuilder.init(allocator);
        defer builder.deinit();

        _ = try builder.append("first");
        _ = try builder.append(2);
        _ = try builder.append(true);

        const arr = builder.build();

        try std.testing.expectEqual(@as(usize, 3), arr.array.items.len);
        try std.testing.expectEqualStrings("first", arr.array.items[0].string);
        try std.testing.expectEqual(@as(i64, 2), arr.array.items[1].integer);
        try std.testing.expect(arr.array.items[2].bool);
    }
}

test "json merge" {
    const allocator = std.testing.allocator;

    var base_builder = json.ObjectBuilder.init(allocator);
    defer base_builder.deinit();
    _ = try base_builder.put("a", 1);
    _ = try base_builder.put("b", 2);

    var nested_base = json.ObjectBuilder.init(allocator);
    defer nested_base.deinit();
    _ = try nested_base.put("x", 10);
    _ = try base_builder.putObject("nested", nested_base.object);

    var overlay_builder = json.ObjectBuilder.init(allocator);
    defer overlay_builder.deinit();
    _ = try overlay_builder.put("b", 3);
    _ = try overlay_builder.put("c", 4);

    var nested_overlay = json.ObjectBuilder.init(allocator);
    defer nested_overlay.deinit();
    _ = try nested_overlay.put("y", 20);
    _ = try overlay_builder.putObject("nested", nested_overlay.object);

    const base = base_builder.build();
    const overlay = overlay_builder.build();

    const merged = try json.merge(allocator, base, overlay);
    defer if (merged == .object) merged.object.deinit();

    // Check merged values
    try std.testing.expectEqual(@as(i64, 1), merged.object.get("a").?.integer);
    try std.testing.expectEqual(@as(i64, 3), merged.object.get("b").?.integer); // Overlay wins
    try std.testing.expectEqual(@as(i64, 4), merged.object.get("c").?.integer);

    // Check nested merge
    const nested = merged.object.get("nested").?.object;
    try std.testing.expectEqual(@as(i64, 10), nested.get("x").?.integer);
    try std.testing.expectEqual(@as(i64, 20), nested.get("y").?.integer);
}
