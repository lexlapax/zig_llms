// ABOUTME: Rate limiting hooks for controlling API call frequency and preventing abuse
// ABOUTME: Provides configurable rate limiting with multiple algorithms and sliding windows

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;

// Rate limit algorithms
pub const RateLimitAlgorithm = enum {
    token_bucket,
    leaky_bucket,
    fixed_window,
    sliding_window,
    sliding_log,
};

// Rate limit entry for tracking usage
pub const RateLimitEntry = struct {
    key: []const u8,
    count: u64,
    last_refill: i64,
    tokens: f64,
    window_start: i64,
    requests: std.ArrayList(i64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, key: []const u8, initial_tokens: f64) !RateLimitEntry {
        return .{
            .key = key,
            .count = 0,
            .last_refill = std.time.milliTimestamp(),
            .tokens = initial_tokens,
            .window_start = std.time.milliTimestamp(),
            .requests = std.ArrayList(i64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimitEntry) void {
        self.requests.deinit();
    }
};

// Rate limiter interface
pub const RateLimiter = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        checkLimit: *const fn (limiter: *RateLimiter, key: []const u8, cost: f64) anyerror!RateLimitResult,
        reset: *const fn (limiter: *RateLimiter, key: []const u8) void,
        getStatus: *const fn (limiter: *RateLimiter, key: []const u8) RateLimitStatus,
        deinit: ?*const fn (limiter: *RateLimiter) void = null,
    };

    pub const RateLimitResult = struct {
        allowed: bool,
        remaining: f64,
        reset_time: i64,
        retry_after: ?i64 = null,
    };

    pub const RateLimitStatus = struct {
        current_usage: f64,
        limit: f64,
        remaining: f64,
        reset_time: i64,
        window_start: i64,
    };

    pub fn checkLimit(self: *RateLimiter, key: []const u8, cost: f64) !RateLimitResult {
        return self.vtable.checkLimit(self, key, cost);
    }

    pub fn reset(self: *RateLimiter, key: []const u8) void {
        self.vtable.reset(self, key);
    }

    pub fn getStatus(self: *RateLimiter, key: []const u8) RateLimitStatus {
        return self.vtable.getStatus(self, key);
    }

    pub fn deinit(self: *RateLimiter) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Token bucket rate limiter
pub const TokenBucketLimiter = struct {
    limiter: RateLimiter,
    entries: std.StringHashMap(RateLimitEntry),
    bucket_size: f64,
    refill_rate: f64, // tokens per second
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        bucket_size: f64,
        refill_rate: f64,
    ) !*TokenBucketLimiter {
        const self = try allocator.create(TokenBucketLimiter);
        self.* = .{
            .limiter = .{
                .vtable = &.{
                    .checkLimit = checkLimit,
                    .reset = reset,
                    .getStatus = getStatus,
                    .deinit = deinit,
                },
            },
            .entries = std.StringHashMap(RateLimitEntry).init(allocator),
            .bucket_size = bucket_size,
            .refill_rate = refill_rate,
            .mutex = .{},
            .allocator = allocator,
        };
        return self;
    }

    fn checkLimit(limiter: *RateLimiter, key: []const u8, cost: f64) !RateLimiter.RateLimitResult {
        const self = @fieldParentPtr(TokenBucketLimiter, "limiter", limiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();

        // Get or create entry
        const entry_result = try self.entries.getOrPut(key);
        if (!entry_result.found_existing) {
            entry_result.value_ptr.* = try RateLimitEntry.init(self.allocator, key, self.bucket_size);
        }

        const entry = entry_result.value_ptr;

        // Calculate tokens to add based on elapsed time
        const elapsed_ms = now - entry.last_refill;
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const tokens_to_add = elapsed_seconds * self.refill_rate;

        // Update tokens (capped at bucket size)
        entry.tokens = @min(self.bucket_size, entry.tokens + tokens_to_add);
        entry.last_refill = now;

        // Check if request can be satisfied
        if (entry.tokens >= cost) {
            entry.tokens -= cost;
            entry.count += 1;

            return RateLimiter.RateLimitResult{
                .allowed = true,
                .remaining = entry.tokens,
                .reset_time = now + @as(i64, @intFromFloat((self.bucket_size - entry.tokens) / self.refill_rate * 1000)),
            };
        } else {
            const wait_time = @as(i64, @intFromFloat((cost - entry.tokens) / self.refill_rate * 1000));
            return RateLimiter.RateLimitResult{
                .allowed = false,
                .remaining = entry.tokens,
                .reset_time = now + wait_time,
                .retry_after = wait_time,
            };
        }
    }

    fn reset(limiter: *RateLimiter, key: []const u8) void {
        const self = @fieldParentPtr(TokenBucketLimiter, "limiter", limiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.getPtr(key)) |entry| {
            entry.tokens = self.bucket_size;
            entry.last_refill = std.time.milliTimestamp();
            entry.count = 0;
        }
    }

    fn getStatus(limiter: *RateLimiter, key: []const u8) RateLimiter.RateLimitStatus {
        const self = @fieldParentPtr(TokenBucketLimiter, "limiter", limiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(key)) |entry| {
            const now = std.time.milliTimestamp();
            const elapsed_ms = now - entry.last_refill;
            const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
            const current_tokens = @min(self.bucket_size, entry.tokens + elapsed_seconds * self.refill_rate);

            return RateLimiter.RateLimitStatus{
                .current_usage = self.bucket_size - current_tokens,
                .limit = self.bucket_size,
                .remaining = current_tokens,
                .reset_time = now + @as(i64, @intFromFloat((self.bucket_size - current_tokens) / self.refill_rate * 1000)),
                .window_start = entry.last_refill,
            };
        }

        return RateLimiter.RateLimitStatus{
            .current_usage = 0,
            .limit = self.bucket_size,
            .remaining = self.bucket_size,
            .reset_time = std.time.milliTimestamp(),
            .window_start = std.time.milliTimestamp(),
        };
    }

    fn deinit(limiter: *RateLimiter) void {
        const self = @fieldParentPtr(TokenBucketLimiter, "limiter", limiter);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.entries.deinit();
        self.allocator.destroy(self);
    }
};

// Sliding window rate limiter
pub const SlidingWindowLimiter = struct {
    limiter: RateLimiter,
    entries: std.StringHashMap(RateLimitEntry),
    window_size_ms: i64,
    limit: u64,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        window_size_ms: i64,
        limit: u64,
    ) !*SlidingWindowLimiter {
        const self = try allocator.create(SlidingWindowLimiter);
        self.* = .{
            .limiter = .{
                .vtable = &.{
                    .checkLimit = checkLimit,
                    .reset = reset,
                    .getStatus = getStatus,
                    .deinit = deinit,
                },
            },
            .entries = std.StringHashMap(RateLimitEntry).init(allocator),
            .window_size_ms = window_size_ms,
            .limit = limit,
            .mutex = .{},
            .allocator = allocator,
        };
        return self;
    }

    fn checkLimit(limiter: *RateLimiter, key: []const u8, cost: f64) !RateLimiter.RateLimitResult {
        const self = @fieldParentPtr(SlidingWindowLimiter, "limiter", limiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const window_start = now - self.window_size_ms;

        // Get or create entry
        const entry_result = try self.entries.getOrPut(key);
        if (!entry_result.found_existing) {
            entry_result.value_ptr.* = try RateLimitEntry.init(self.allocator, key, 0);
        }

        const entry = entry_result.value_ptr;

        // Remove old requests outside the window
        var i: usize = 0;
        while (i < entry.requests.items.len) {
            if (entry.requests.items[i] < window_start) {
                _ = entry.requests.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check if we can add the new request
        const current_count = entry.requests.items.len;
        const cost_int = @as(u64, @intFromFloat(cost));

        if (current_count + cost_int <= self.limit) {
            // Add requests for the cost
            var j: u64 = 0;
            while (j < cost_int) : (j += 1) {
                try entry.requests.append(now);
            }

            entry.count += cost_int;

            return RateLimiter.RateLimitResult{
                .allowed = true,
                .remaining = @as(f64, @floatFromInt(self.limit - (current_count + cost_int))),
                .reset_time = if (entry.requests.items.len > 0) entry.requests.items[0] + self.window_size_ms else now + self.window_size_ms,
            };
        } else {
            const oldest_request = if (entry.requests.items.len > 0) entry.requests.items[0] else now;
            const retry_after = oldest_request + self.window_size_ms - now;

            return RateLimiter.RateLimitResult{
                .allowed = false,
                .remaining = @as(f64, @floatFromInt(self.limit - current_count)),
                .reset_time = oldest_request + self.window_size_ms,
                .retry_after = @max(0, retry_after),
            };
        }
    }

    fn reset(limiter: *RateLimiter, key: []const u8) void {
        const self = @fieldParentPtr(SlidingWindowLimiter, "limiter", limiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.getPtr(key)) |entry| {
            entry.requests.clearRetainingCapacity();
            entry.count = 0;
        }
    }

    fn getStatus(limiter: *RateLimiter, key: []const u8) RateLimiter.RateLimitStatus {
        const self = @fieldParentPtr(SlidingWindowLimiter, "limiter", limiter);

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const window_start = now - self.window_size_ms;

        if (self.entries.get(key)) |entry| {
            // Count requests in current window
            var count: u64 = 0;
            for (entry.requests.items) |timestamp| {
                if (timestamp >= window_start) {
                    count += 1;
                }
            }

            const oldest_in_window = blk: {
                for (entry.requests.items) |timestamp| {
                    if (timestamp >= window_start) {
                        break :blk timestamp;
                    }
                }
                break :blk now;
            };

            return RateLimiter.RateLimitStatus{
                .current_usage = @as(f64, @floatFromInt(count)),
                .limit = @as(f64, @floatFromInt(self.limit)),
                .remaining = @as(f64, @floatFromInt(self.limit - count)),
                .reset_time = oldest_in_window + self.window_size_ms,
                .window_start = window_start,
            };
        }

        return RateLimiter.RateLimitStatus{
            .current_usage = 0,
            .limit = @as(f64, @floatFromInt(self.limit)),
            .remaining = @as(f64, @floatFromInt(self.limit)),
            .reset_time = now + self.window_size_ms,
            .window_start = window_start,
        };
    }

    fn deinit(limiter: *RateLimiter) void {
        const self = @fieldParentPtr(SlidingWindowLimiter, "limiter", limiter);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.entries.deinit();
        self.allocator.destroy(self);
    }
};

// Rate limiting hook
pub const RateLimitingHook = struct {
    hook: Hook,
    config: RateLimitConfig,
    limiter: *RateLimiter,
    key_generator: KeyGenerator,
    stats: RateLimitStats,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub const RateLimitConfig = struct {
        enabled: bool = true,
        algorithm: RateLimitAlgorithm = .token_bucket,
        limit: u64 = 100,
        window_size_ms: i64 = 60000, // 1 minute
        burst_size: ?u64 = null,
        cost_calculator: ?*const fn (*const HookContext) f64 = null,
        exempt_points: []const HookPoint = &[_]HookPoint{},
        block_on_limit: bool = true, // If false, just log the violation
        custom_headers: bool = true, // Add rate limit headers to response
    };

    pub const KeyGenerator = enum {
        global, // Single rate limit for all requests
        agent_id, // Per agent rate limiting
        hook_point, // Per hook point rate limiting
        custom, // Custom key generation function
    };

    pub const RateLimitStats = struct {
        requests: u64 = 0,
        blocked: u64 = 0,
        total_cost: f64 = 0,

        pub fn blockRate(self: *const RateLimitStats) f64 {
            if (self.requests == 0) return 0.0;
            return @as(f64, @floatFromInt(self.blocked)) / @as(f64, @floatFromInt(self.requests));
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        config: RateLimitConfig,
        limiter: *RateLimiter,
    ) !*RateLimitingHook {
        const self = try allocator.create(RateLimitingHook);

        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = execute,
            .deinit = hookDeinit,
        };

        self.* = .{
            .hook = .{
                .id = id,
                .name = "Rate Limiting Hook",
                .description = "Controls request rate to prevent abuse",
                .vtable = vtable,
                .priority = .highest, // Run very early to block requests
                .supported_points = &[_]HookPoint{.custom}, // Apply to all points
                .config = .{ .integer = @intFromPtr(self) },
            },
            .config = config,
            .limiter = limiter,
            .key_generator = .global,
            .stats = .{},
            .mutex = .{},
            .allocator = allocator,
        };

        return self;
    }

    pub fn getStats(self: *RateLimitingHook) RateLimitStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    pub fn resetLimits(self: *RateLimitingHook, key: ?[]const u8) void {
        if (key) |k| {
            self.limiter.reset(k);
        } else {
            // Reset all - implementation depends on limiter type
            self.limiter.reset("global");
        }
    }

    fn hookDeinit(hook: *Hook) void {
        const self = @as(*RateLimitingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        self.limiter.deinit();
        self.allocator.destroy(hook.vtable);
        self.allocator.destroy(self);
    }

    fn execute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @as(*RateLimitingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        if (!self.config.enabled) {
            return HookResult{ .continue_processing = true };
        }

        // Check if this hook point is exempt
        for (self.config.exempt_points) |exempt_point| {
            if (exempt_point == context.point) {
                return HookResult{ .continue_processing = true };
            }
        }

        // Generate rate limit key
        const rate_key = try self.generateKey(context);
        defer self.allocator.free(rate_key);

        // Calculate cost
        const cost = if (self.config.cost_calculator) |calc|
            calc(context)
        else
            1.0;

        // Check rate limit
        const limit_result = try self.limiter.checkLimit(rate_key, cost);

        // Update stats
        self.mutex.lock();
        self.stats.requests += 1;
        self.stats.total_cost += cost;
        if (!limit_result.allowed) {
            self.stats.blocked += 1;
        }
        self.mutex.unlock();

        // Add rate limit headers if configured
        var headers: ?std.json.ObjectMap = null;
        if (self.config.custom_headers) {
            headers = std.json.ObjectMap.init(context.allocator);
            try headers.?.put("X-RateLimit-Limit", .{ .string = try std.fmt.allocPrint(context.allocator, "{d}", .{self.config.limit}) });
            try headers.?.put("X-RateLimit-Remaining", .{ .string = try std.fmt.allocPrint(context.allocator, "{d}", .{@as(u64, @intFromFloat(limit_result.remaining))}) });
            try headers.?.put("X-RateLimit-Reset", .{ .string = try std.fmt.allocPrint(context.allocator, "{d}", .{limit_result.reset_time}) });

            if (limit_result.retry_after) |retry| {
                try headers.?.put("Retry-After", .{ .string = try std.fmt.allocPrint(context.allocator, "{d}", .{@divTrunc(retry, 1000)}) });
            }
        }

        if (!limit_result.allowed) {
            if (self.config.block_on_limit) {
                // Block the request
                return HookResult{
                    .continue_processing = false,
                    .error_info = .{
                        .message = "Rate limit exceeded",
                        .error_type = "RateLimitError",
                        .recoverable = true,
                        .details = if (headers) |h| .{ .object = h } else null,
                    },
                };
            } else {
                // Just log the violation
                std.log.warn("Rate limit exceeded for key '{s}' at hook point {s}", .{ rate_key, context.point.toString() });
            }
        }

        return HookResult{
            .continue_processing = true,
            .metadata = if (headers) |h| .{ .object = h } else null,
        };
    }

    fn generateKey(self: *RateLimitingHook, context: *const HookContext) ![]u8 {
        return switch (self.key_generator) {
            .global => try self.allocator.dupe(u8, "global"),
            .agent_id => blk: {
                if (context.agent) |agent| {
                    if (agent.state.metadata.get("agent_id")) |id| {
                        break :blk try self.allocator.dupe(u8, id.string);
                    }
                }
                break :blk try self.allocator.dupe(u8, "unknown_agent");
            },
            .hook_point => try std.fmt.allocPrint(self.allocator, "point_{s}", .{context.point.toString()}),
            .custom => try std.fmt.allocPrint(self.allocator, "custom_{d}", .{@intFromPtr(context)}),
        };
    }
};

// Rate limit manager for multiple limiters
pub const RateLimitManager = struct {
    limiters: std.StringHashMap(*RateLimitingHook),
    global_stats: RateLimitingHook.RateLimitStats,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RateLimitManager {
        return .{
            .limiters = std.StringHashMap(*RateLimitingHook).init(allocator),
            .global_stats = .{},
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RateLimitManager) void {
        var iter = self.limiters.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.hook.vtable.deinit.?(&entry.value_ptr.*.hook);
        }
        self.limiters.deinit();
    }

    pub fn registerLimiter(self: *RateLimitManager, name: []const u8, limiter: *RateLimitingHook) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.limiters.put(name, limiter);
    }

    pub fn getLimiter(self: *RateLimitManager, name: []const u8) ?*RateLimitingHook {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.limiters.get(name);
    }

    pub fn getGlobalStats(self: *RateLimitManager) RateLimitingHook.RateLimitStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = RateLimitingHook.RateLimitStats{};
        var iter = self.limiters.iterator();
        while (iter.next()) |entry| {
            const limiter_stats = entry.value_ptr.*.getStats();
            stats.requests += limiter_stats.requests;
            stats.blocked += limiter_stats.blocked;
            stats.total_cost += limiter_stats.total_cost;
        }

        return stats;
    }
};

// Builder for rate limiting hook
pub fn createRateLimitingHook(
    allocator: std.mem.Allocator,
    id: []const u8,
    config: RateLimitingHook.RateLimitConfig,
) !*Hook {
    const limiter = switch (config.algorithm) {
        .token_bucket => blk: {
            const bucket_size = @as(f64, @floatFromInt(config.burst_size orelse config.limit));
            const refill_rate = @as(f64, @floatFromInt(config.limit)) * 1000.0 / @as(f64, @floatFromInt(config.window_size_ms));
            const token_limiter = try TokenBucketLimiter.init(allocator, bucket_size, refill_rate);
            break :blk &token_limiter.limiter;
        },
        .sliding_window => blk: {
            const sliding_limiter = try SlidingWindowLimiter.init(allocator, config.window_size_ms, config.limit);
            break :blk &sliding_limiter.limiter;
        },
        else => {
            // Default to token bucket for unsupported algorithms
            const bucket_size = @as(f64, @floatFromInt(config.limit));
            const refill_rate = bucket_size * 1000.0 / @as(f64, @floatFromInt(config.window_size_ms));
            const token_limiter = try TokenBucketLimiter.init(allocator, bucket_size, refill_rate);
            break :blk &token_limiter.limiter;
        },
    };

    const rate_limiting_hook = try RateLimitingHook.init(allocator, id, config, limiter);
    return &rate_limiting_hook.hook;
}

// Tests
test "token bucket limiter" {
    const allocator = std.testing.allocator;

    const limiter = try TokenBucketLimiter.init(allocator, 10.0, 1.0); // 10 tokens, 1 token/sec
    defer limiter.limiter.deinit();

    // First request should succeed
    const result1 = try limiter.limiter.checkLimit("test", 5.0);
    try std.testing.expect(result1.allowed);
    try std.testing.expectEqual(@as(f64, 5.0), result1.remaining);

    // Second request should also succeed
    const result2 = try limiter.limiter.checkLimit("test", 3.0);
    try std.testing.expect(result2.allowed);
    try std.testing.expectEqual(@as(f64, 2.0), result2.remaining);

    // Third request should fail (only 2 tokens left, requesting 5)
    const result3 = try limiter.limiter.checkLimit("test", 5.0);
    try std.testing.expect(!result3.allowed);
    try std.testing.expect(result3.retry_after != null);

    // Reset should restore tokens
    limiter.limiter.reset("test");
    const result4 = try limiter.limiter.checkLimit("test", 5.0);
    try std.testing.expect(result4.allowed);
}

test "sliding window limiter" {
    const allocator = std.testing.allocator;

    const limiter = try SlidingWindowLimiter.init(allocator, 1000, 5); // 5 requests per second
    defer limiter.limiter.deinit();

    // First 5 requests should succeed
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const result = try limiter.limiter.checkLimit("test", 1.0);
        try std.testing.expect(result.allowed);
    }

    // 6th request should fail
    const result6 = try limiter.limiter.checkLimit("test", 1.0);
    try std.testing.expect(!result6.allowed);
    try std.testing.expect(result6.retry_after != null);
}

test "rate limiting hook" {
    const allocator = std.testing.allocator;

    const hook = try createRateLimitingHook(allocator, "test_rate_limit", .{
        .limit = 10,
        .window_size_ms = 60000,
        .algorithm = .token_bucket,
    });
    defer hook.vtable.deinit.?(hook);

    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();

    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();

    // First request should succeed
    const result1 = try hook.execute(&context);
    try std.testing.expect(result1.continue_processing);

    const rate_limiting_hook = @as(*RateLimitingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
    const stats = rate_limiting_hook.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.requests);
    try std.testing.expectEqual(@as(u64, 0), stats.blocked);
}

test "rate limit manager" {
    const allocator = std.testing.allocator;

    var manager = RateLimitManager.init(allocator);
    defer manager.deinit();

    const hook1 = try createRateLimitingHook(allocator, "limiter1", .{ .limit = 10 });
    const rate_limiting_hook1 = @as(*RateLimitingHook, @ptrFromInt(@as(usize, @intCast(hook1.config.?.integer))));
    try manager.registerLimiter("api", rate_limiting_hook1);

    const hook2 = try createRateLimitingHook(allocator, "limiter2", .{ .limit = 5 });
    const rate_limiting_hook2 = @as(*RateLimitingHook, @ptrFromInt(@as(usize, @intCast(hook2.config.?.integer))));
    try manager.registerLimiter("upload", rate_limiting_hook2);

    // Test retrieval
    const retrieved = manager.getLimiter("api");
    try std.testing.expect(retrieved != null);

    // Test global stats
    const global_stats = manager.getGlobalStats();
    try std.testing.expectEqual(@as(u64, 0), global_stats.requests);
}
