// ABOUTME: Flexible assertion matchers for better test readability and error messages
// ABOUTME: Provides fluent API for complex assertions with detailed failure reporting

const std = @import("std");
const types = @import("../types.zig");

pub const MatchResult = struct {
    success: bool,
    message: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, success: bool, message: []const u8) !MatchResult {
        return MatchResult{
            .success = success,
            .message = try allocator.dupe(u8, message),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MatchResult) void {
        self.allocator.free(self.message);
    }
    
    pub fn expectSuccess(self: *MatchResult) !void {
        defer self.deinit();
        if (!self.success) {
            std.debug.print("Assertion failed: {s}\n", .{self.message});
            return error.AssertionFailed;
        }
    }
};

// String matchers
pub const StringMatcher = struct {
    actual: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, actual: []const u8) StringMatcher {
        return StringMatcher{
            .actual = actual,
            .allocator = allocator,
        };
    }
    
    pub fn toEqual(self: StringMatcher, expected: []const u8) !MatchResult {
        const success = std.mem.eql(u8, self.actual, expected);
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to equal '{s}' ✓", .{ self.actual, expected })
        else
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to equal '{s}'", .{ self.actual, expected });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toContain(self: StringMatcher, substring: []const u8) !MatchResult {
        const success = std.mem.indexOf(u8, self.actual, substring) != null;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to contain '{s}' ✓", .{ self.actual, substring })
        else
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to contain '{s}'", .{ self.actual, substring });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toStartWith(self: StringMatcher, prefix: []const u8) !MatchResult {
        const success = std.mem.startsWith(u8, self.actual, prefix);
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to start with '{s}' ✓", .{ self.actual, prefix })
        else
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to start with '{s}'", .{ self.actual, prefix });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toEndWith(self: StringMatcher, suffix: []const u8) !MatchResult {
        const success = std.mem.endsWith(u8, self.actual, suffix);
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to end with '{s}' ✓", .{ self.actual, suffix })
        else
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to end with '{s}'", .{ self.actual, suffix });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toMatch(self: StringMatcher, pattern: []const u8) !MatchResult {
        // Simple pattern matching (could be extended with regex)
        const success = std.mem.indexOf(u8, self.actual, pattern) != null;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to match pattern '{s}' ✓", .{ self.actual, pattern })
        else
            try std.fmt.allocPrint(self.allocator, "Expected '{s}' to match pattern '{s}'", .{ self.actual, pattern });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toBeLengthOf(self: StringMatcher, expected_length: usize) !MatchResult {
        const success = self.actual.len == expected_length;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected string length {d} to equal {d} ✓", .{ self.actual.len, expected_length })
        else
            try std.fmt.allocPrint(self.allocator, "Expected string length {d} to equal {d}", .{ self.actual.len, expected_length });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toBeEmpty(self: StringMatcher) !MatchResult {
        const success = self.actual.len == 0;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected string to be empty ✓", .{})
        else
            try std.fmt.allocPrint(self.allocator, "Expected string to be empty, but got '{s}'", .{self.actual});
        
        return MatchResult.init(self.allocator, success, message);
    }
};

// Numeric matchers
pub fn NumberMatcher(comptime T: type) type {
    return struct {
        const Self = @This();
        actual: T,
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator, actual: T) Self {
            return Self{
                .actual = actual,
                .allocator = allocator,
            };
        }
        
        pub fn toEqual(self: Self, expected: T) !MatchResult {
            const success = self.actual == expected;
            const message = if (success)
                try std.fmt.allocPrint(self.allocator, "Expected {any} to equal {any} ✓", .{ self.actual, expected })
            else
                try std.fmt.allocPrint(self.allocator, "Expected {any} to equal {any}", .{ self.actual, expected });
            
            return MatchResult.init(self.allocator, success, message);
        }
        
        pub fn toBeGreaterThan(self: Self, threshold: T) !MatchResult {
            const success = self.actual > threshold;
            const message = if (success)
                try std.fmt.allocPrint(self.allocator, "Expected {any} to be greater than {any} ✓", .{ self.actual, threshold })
            else
                try std.fmt.allocPrint(self.allocator, "Expected {any} to be greater than {any}", .{ self.actual, threshold });
            
            return MatchResult.init(self.allocator, success, message);
        }
        
        pub fn toBeLessThan(self: Self, threshold: T) !MatchResult {
            const success = self.actual < threshold;
            const message = if (success)
                try std.fmt.allocPrint(self.allocator, "Expected {any} to be less than {any} ✓", .{ self.actual, threshold })
            else
                try std.fmt.allocPrint(self.allocator, "Expected {any} to be less than {any}", .{ self.actual, threshold });
            
            return MatchResult.init(self.allocator, success, message);
        }
        
        pub fn toBeInRange(self: Self, min: T, max: T) !MatchResult {
            const success = self.actual >= min and self.actual <= max;
            const message = if (success)
                try std.fmt.allocPrint(self.allocator, "Expected {any} to be in range [{any}, {any}] ✓", .{ self.actual, min, max })
            else
                try std.fmt.allocPrint(self.allocator, "Expected {any} to be in range [{any}, {any}]", .{ self.actual, min, max });
            
            return MatchResult.init(self.allocator, success, message);
        }
    };
}

// Array/slice matchers
pub fn ArrayMatcher(comptime T: type) type {
    return struct {
        const Self = @This();
        actual: []const T,
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator, actual: []const T) Self {
            return Self{
                .actual = actual,
                .allocator = allocator,
            };
        }
        
        pub fn toHaveLength(self: Self, expected_length: usize) !MatchResult {
            const success = self.actual.len == expected_length;
            const message = if (success)
                try std.fmt.allocPrint(self.allocator, "Expected array length {d} to equal {d} ✓", .{ self.actual.len, expected_length })
            else
                try std.fmt.allocPrint(self.allocator, "Expected array length {d} to equal {d}", .{ self.actual.len, expected_length });
            
            return MatchResult.init(self.allocator, success, message);
        }
        
        pub fn toBeEmpty(self: Self) !MatchResult {
            const success = self.actual.len == 0;
            const message = if (success)
                try std.fmt.allocPrint(self.allocator, "Expected array to be empty ✓", .{})
            else
                try std.fmt.allocPrint(self.allocator, "Expected array to be empty, but got length {d}", .{self.actual.len});
            
            return MatchResult.init(self.allocator, success, message);
        }
        
        pub fn toContain(self: Self, item: T) !MatchResult {
            var found = false;
            for (self.actual) |actual_item| {
                if (std.meta.eql(actual_item, item)) {
                    found = true;
                    break;
                }
            }
            
            const message = if (found)
                try std.fmt.allocPrint(self.allocator, "Expected array to contain item ✓", .{})
            else
                try std.fmt.allocPrint(self.allocator, "Expected array to contain item", .{});
            
            return MatchResult.init(self.allocator, found, message);
        }
    };
}

// Message-specific matchers
pub const MessageMatcher = struct {
    actual: types.Message,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, actual: types.Message) MessageMatcher {
        return MessageMatcher{
            .actual = actual,
            .allocator = allocator,
        };
    }
    
    pub fn toHaveRole(self: MessageMatcher, expected_role: types.Role) !MatchResult {
        const success = self.actual.role == expected_role;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected message role {s} to equal {s} ✓", .{ @tagName(self.actual.role), @tagName(expected_role) })
        else
            try std.fmt.allocPrint(self.allocator, "Expected message role {s} to equal {s}", .{ @tagName(self.actual.role), @tagName(expected_role) });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toHaveTextContent(self: MessageMatcher, expected_content: []const u8) !MatchResult {
        const success = switch (self.actual.content) {
            .text => |text| std.mem.eql(u8, text, expected_content),
            .multimodal => false,
        };
        
        const actual_content = switch (self.actual.content) {
            .text => |text| text,
            .multimodal => "[multimodal content]",
        };
        
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected message content '{s}' to equal '{s}' ✓", .{ actual_content, expected_content })
        else
            try std.fmt.allocPrint(self.allocator, "Expected message content '{s}' to equal '{s}'", .{ actual_content, expected_content });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toHaveMetadata(self: MessageMatcher) !MatchResult {
        const success = self.actual.metadata != null;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected message to have metadata ✓", .{})
        else
            try std.fmt.allocPrint(self.allocator, "Expected message to have metadata", .{});
        
        return MatchResult.init(self.allocator, success, message);
    }
};

// Response matchers
pub const ResponseMatcher = struct {
    actual: types.Response,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, actual: types.Response) ResponseMatcher {
        return ResponseMatcher{
            .actual = actual,
            .allocator = allocator,
        };
    }
    
    pub fn toHaveContent(self: ResponseMatcher, expected_content: []const u8) !MatchResult {
        const success = std.mem.eql(u8, self.actual.content, expected_content);
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected response content '{s}' to equal '{s}' ✓", .{ self.actual.content, expected_content })
        else
            try std.fmt.allocPrint(self.allocator, "Expected response content '{s}' to equal '{s}'", .{ self.actual.content, expected_content });
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toHaveUsage(self: ResponseMatcher) !MatchResult {
        const success = self.actual.usage != null;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected response to have usage information ✓", .{})
        else
            try std.fmt.allocPrint(self.allocator, "Expected response to have usage information", .{});
        
        return MatchResult.init(self.allocator, success, message);
    }
    
    pub fn toHaveTokenCount(self: ResponseMatcher, expected_total: u32) !MatchResult {
        const success = if (self.actual.usage) |usage| usage.total_tokens == expected_total else false;
        
        const actual_tokens = if (self.actual.usage) |usage| usage.total_tokens else 0;
        const message = if (success)
            try std.fmt.allocPrint(self.allocator, "Expected response token count {d} to equal {d} ✓", .{ actual_tokens, expected_total })
        else
            try std.fmt.allocPrint(self.allocator, "Expected response token count {d} to equal {d}", .{ actual_tokens, expected_total });
        
        return MatchResult.init(self.allocator, success, message);
    }
};

// Fluent API entry points
pub fn expect(allocator: std.mem.Allocator, actual: anytype) ExpectWrapper(@TypeOf(actual)) {
    return ExpectWrapper(@TypeOf(actual)).init(allocator, actual);
}

pub fn ExpectWrapper(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        actual: T,
        
        pub fn init(allocator: std.mem.Allocator, actual: T) Self {
            return Self{
                .allocator = allocator,
                .actual = actual,
            };
        }
        
        pub fn toEqual(self: Self, expected: T) !MatchResult {
            return switch (T) {
                []const u8, []u8 => StringMatcher.init(self.allocator, self.actual).toEqual(expected),
                types.Message => MessageMatcher.init(self.allocator, self.actual).toHaveTextContent(expected.content.text),
                types.Response => ResponseMatcher.init(self.allocator, self.actual).toHaveContent(expected.content),
                else => {
                    const success = std.meta.eql(self.actual, expected);
                    const message = if (success)
                        try std.fmt.allocPrint(self.allocator, "Values are equal ✓", .{})
                    else
                        try std.fmt.allocPrint(self.allocator, "Values are not equal", .{});
                    
                    return MatchResult.init(self.allocator, success, message);
                },
            };
        }
    };
}

// Convenience functions
pub fn expectString(allocator: std.mem.Allocator, actual: []const u8) StringMatcher {
    return StringMatcher.init(allocator, actual);
}

pub fn expectNumber(allocator: std.mem.Allocator, actual: anytype) NumberMatcher(@TypeOf(actual)) {
    return NumberMatcher(@TypeOf(actual)).init(allocator, actual);
}

pub fn expectArray(allocator: std.mem.Allocator, actual: anytype) ArrayMatcher(std.meta.Child(@TypeOf(actual))) {
    return ArrayMatcher(std.meta.Child(@TypeOf(actual))).init(allocator, actual);
}

pub fn expectMessage(allocator: std.mem.Allocator, actual: types.Message) MessageMatcher {
    return MessageMatcher.init(allocator, actual);
}

pub fn expectResponse(allocator: std.mem.Allocator, actual: types.Response) ResponseMatcher {
    return ResponseMatcher.init(allocator, actual);
}

// Test the matchers
test "string matcher" {
    const allocator = std.testing.allocator;
    
    var result = try expectString(allocator, "hello world").toContain("world");
    try result.expectSuccess();
    
    result = try expectString(allocator, "hello").toEqual("hello");
    try result.expectSuccess();
    
    result = try expectString(allocator, "").toBeEmpty();
    try result.expectSuccess();
}

test "number matcher" {
    const allocator = std.testing.allocator;
    
    var result = try expectNumber(allocator, @as(i32, 42)).toEqual(42);
    try result.expectSuccess();
    
    result = try expectNumber(allocator, @as(f32, 3.14)).toBeGreaterThan(3.0);
    try result.expectSuccess();
    
    result = try expectNumber(allocator, @as(u32, 50)).toBeInRange(40, 60);
    try result.expectSuccess();
}

test "message matcher" {
    const allocator = std.testing.allocator;
    
    const message = types.Message{
        .role = .user,
        .content = .{ .text = "Hello, world!" },
    };
    
    var result = try expectMessage(allocator, message).toHaveRole(.user);
    try result.expectSuccess();
    
    result = try expectMessage(allocator, message).toHaveTextContent("Hello, world!");
    try result.expectSuccess();
}