// ABOUTME: Structured error handling system with serialization and recovery strategies
// ABOUTME: Provides bridge-friendly error types that can be serialized to JSON for debugging

const std = @import("std");

pub const LLMError = error{
    ProviderError,
    NetworkError,
    RateLimitError,
    InvalidResponse,
    Timeout,
    SchemaValidationError,
    ToolExecutionError,
    MemoryAllocationError,
    InvalidConfiguration,
};

pub const RecoveryStrategy = enum {
    retry_once,
    retry_with_backoff,
    failover,
    none,
};

pub const SerializableError = struct {
    code: []const u8,
    message: []const u8,
    context: std.json.Value,
    recovery_strategy: ?RecoveryStrategy = null,
    cause: ?*SerializableError = null,
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator, code: []const u8, message: []const u8) !SerializableError {
        return SerializableError{
            .code = code,
            .message = message,
            .context = std.json.Value{ .object = std.json.ObjectMap.init(allocator) },
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn toJSON(self: *const SerializableError, allocator: std.mem.Allocator) ![]const u8 {
        var object = std.json.ObjectMap.init(allocator);
        defer object.deinit();

        try object.put("code", std.json.Value{ .string = self.code });
        try object.put("message", std.json.Value{ .string = self.message });
        try object.put("context", self.context);
        try object.put("timestamp", std.json.Value{ .integer = self.timestamp });

        if (self.recovery_strategy) |strategy| {
            try object.put("recovery_strategy", std.json.Value{ .string = @tagName(strategy) });
        }

        if (self.cause) |cause| {
            const cause_json = try cause.toJSON(allocator);
            defer allocator.free(cause_json);
            const cause_value = try std.json.parseFromSlice(std.json.Value, allocator, cause_json, .{});
            defer cause_value.deinit();
            try object.put("cause", cause_value.value);
        }

        const value = std.json.Value{ .object = object };
        return std.json.stringifyAlloc(allocator, value, .{});
    }

    pub fn fromError(allocator: std.mem.Allocator, err: anyerror, code: []const u8) !SerializableError {
        const message = try std.fmt.allocPrint(allocator, "Error: {s}", .{@errorName(err)});
        return SerializableError.init(allocator, code, message);
    }

    pub fn withContext(self: *SerializableError, key: []const u8, value: std.json.Value) !void {
        if (self.context.object.get(key) == null) {
            try self.context.object.put(key, value);
        }
    }

    pub fn withRecovery(self: *SerializableError, strategy: RecoveryStrategy) void {
        self.recovery_strategy = strategy;
    }

    pub fn withCause(self: *SerializableError, cause: *SerializableError) void {
        self.cause = cause;
    }
};

// Error wrapping utilities
pub fn wrapError(allocator: std.mem.Allocator, err: anyerror, code: []const u8) !SerializableError {
    return SerializableError.fromError(allocator, err, code);
}

// Common error constructors
pub fn providerError(allocator: std.mem.Allocator, provider: []const u8, message: []const u8) !SerializableError {
    var err = try SerializableError.init(allocator, "provider_error", message);
    try err.withContext("provider", std.json.Value{ .string = provider });
    return err;
}

pub fn rateLimitError(allocator: std.mem.Allocator, retry_after: ?i64) !SerializableError {
    var err = try SerializableError.init(allocator, "rate_limit_error", "Rate limit exceeded");
    if (retry_after) |retry| {
        try err.withContext("retry_after", std.json.Value{ .integer = retry });
    }
    err.withRecovery(.retry_with_backoff);
    return err;
}

test "serializable error" {
    const allocator = std.testing.allocator;

    var err = try SerializableError.init(allocator, "test_error", "Test error message");
    try err.withContext("test_key", std.json.Value{ .string = "test_value" });
    err.withRecovery(.retry_once);

    const json = try err.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
}
