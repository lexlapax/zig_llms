// ABOUTME: Retry logic with exponential backoff for resilient HTTP requests
// ABOUTME: Provides configurable retry strategies for handling transient failures

const std = @import("std");
const HttpClient = @import("client.zig").HttpClient;
const HttpRequest = @import("client.zig").HttpRequest;
const HttpResponse = @import("client.zig").HttpResponse;

pub const RetryConfig = struct {
    max_attempts: u8 = 3,
    initial_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 60000,
    exponential_base: f32 = 2.0,
    jitter: bool = true,
    retry_on_status_codes: []const u16 = &[_]u16{ 429, 500, 502, 503, 504 },
    retry_on_errors: []const anyerror = &[_]anyerror{
        error.NetworkError,
        error.Timeout,
        error.ConnectionRefused,
        error.ConnectionReset,
    },

    pub fn shouldRetryStatus(self: *const RetryConfig, status_code: u16) bool {
        for (self.retry_on_status_codes) |code| {
            if (code == status_code) return true;
        }
        return false;
    }

    pub fn shouldRetryError(self: *const RetryConfig, err: anyerror) bool {
        for (self.retry_on_errors) |retry_err| {
            if (err == retry_err) return true;
        }
        return false;
    }

    pub fn calculateDelay(self: *const RetryConfig, attempt: u8, random: std.Random) u32 {
        // Calculate exponential backoff
        const base_delay = self.initial_delay_ms;
        const multiplier = std.math.pow(f32, self.exponential_base, @as(f32, @floatFromInt(attempt - 1)));
        var delay = @as(u32, @intFromFloat(@as(f32, @floatFromInt(base_delay)) * multiplier));

        // Cap at max delay
        delay = @min(delay, self.max_delay_ms);

        // Add jitter if enabled
        if (self.jitter) {
            const jitter_range = @divFloor(delay, 2);
            const jitter_value = random.intRangeAtMost(u32, 0, jitter_range);
            delay = delay - @divFloor(jitter_range, 2) + jitter_value;
        }

        return delay;
    }
};

pub const RetryResult = struct {
    response: ?HttpResponse = null,
    attempts: u8,
    total_delay_ms: u32,
    last_error: ?anyerror = null,
    succeeded: bool,
};

pub const RetryableHttpClient = struct {
    client: HttpClient,
    config: RetryConfig,
    random: std.Random,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, client: HttpClient, config: RetryConfig) RetryableHttpClient {
        var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
        return RetryableHttpClient{
            .client = client,
            .config = config,
            .random = prng.random(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RetryableHttpClient) void {
        self.client.deinit();
    }

    pub fn execute(self: *RetryableHttpClient, request: *HttpRequest) !RetryResult {
        var result = RetryResult{
            .attempts = 0,
            .total_delay_ms = 0,
            .succeeded = false,
        };

        var attempt: u8 = 1;
        while (attempt <= self.config.max_attempts) : (attempt += 1) {
            result.attempts = attempt;

            // Make the request
            var response = self.client.execute(request) catch |err| {
                result.last_error = err;

                // Check if we should retry this error
                if (!self.config.shouldRetryError(err)) {
                    return result;
                }

                // If this is the last attempt, don't delay
                if (attempt == self.config.max_attempts) {
                    return result;
                }

                // Calculate and apply delay
                const delay = self.config.calculateDelay(attempt, self.random);
                result.total_delay_ms += delay;
                std.time.sleep(delay * std.time.ns_per_ms);

                std.log.debug("Retrying request after error {any}, attempt {d}/{d}, delay {d}ms", .{
                    err,
                    attempt + 1,
                    self.config.max_attempts,
                    delay,
                });

                continue;
            };

            // Check if response indicates we should retry
            if (!response.isSuccess() and self.config.shouldRetryStatus(response.status_code)) {
                // Store the response for potential later use
                if (result.response) |*old_response| {
                    old_response.deinit();
                }

                // If this is the last attempt, return the response
                if (attempt == self.config.max_attempts) {
                    result.response = response;
                    return result;
                }

                // Calculate and apply delay
                const delay = self.config.calculateDelay(attempt, self.random);
                result.total_delay_ms += delay;

                // Check for Retry-After header
                const retry_after = response.getHeader("Retry-After");
                const actual_delay = if (retry_after) |after| blk: {
                    // Try to parse as number of seconds
                    const seconds = std.fmt.parseInt(u32, after, 10) catch {
                        // If not a number, might be HTTP date - use calculated delay
                        break :blk delay;
                    };
                    break :blk @min(seconds * 1000, self.config.max_delay_ms);
                } else delay;

                std.time.sleep(actual_delay * std.time.ns_per_ms);

                std.log.debug("Retrying request after status {d}, attempt {d}/{d}, delay {d}ms", .{
                    response.status_code,
                    attempt + 1,
                    self.config.max_attempts,
                    actual_delay,
                });

                // Clean up the response before retrying
                response.deinit();
                continue;
            }

            // Success!
            result.response = response;
            result.succeeded = true;
            return result;
        }

        return result;
    }

    pub fn get(self: *RetryableHttpClient, url: []const u8) !RetryResult {
        var request = @import("client.zig").request(self.allocator, .GET, url);
        defer request.deinit();

        return self.execute(&request);
    }

    pub fn post(self: *RetryableHttpClient, url: []const u8, body: ?[]const u8) !RetryResult {
        var request = @import("client.zig").request(self.allocator, .POST, url);
        defer request.deinit();

        if (body) |b| {
            try request.setBodyString(b);
        }

        return self.execute(&request);
    }

    pub fn postJson(self: *RetryableHttpClient, url: []const u8, data: anytype) !RetryResult {
        var request = @import("client.zig").request(self.allocator, .POST, url);
        defer request.deinit();

        try request.setJsonBody(data);

        return self.execute(&request);
    }
};

// Convenience functions
pub fn withRetry(allocator: std.mem.Allocator, client: HttpClient, config: RetryConfig) RetryableHttpClient {
    return RetryableHttpClient.init(allocator, client, config);
}

pub fn defaultRetryConfig() RetryConfig {
    return RetryConfig{};
}

pub fn aggressiveRetryConfig() RetryConfig {
    return RetryConfig{
        .max_attempts = 5,
        .initial_delay_ms = 500,
        .max_delay_ms = 120000,
        .exponential_base = 2.5,
    };
}

pub fn conservativeRetryConfig() RetryConfig {
    return RetryConfig{
        .max_attempts = 2,
        .initial_delay_ms = 2000,
        .max_delay_ms = 10000,
        .exponential_base = 1.5,
        .jitter = false,
    };
}

// Tests
test "retry config delay calculation" {
    const config = RetryConfig{
        .initial_delay_ms = 1000,
        .exponential_base = 2.0,
        .jitter = false,
    };

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    // Test exponential backoff without jitter
    try std.testing.expectEqual(@as(u32, 1000), config.calculateDelay(1, random));
    try std.testing.expectEqual(@as(u32, 2000), config.calculateDelay(2, random));
    try std.testing.expectEqual(@as(u32, 4000), config.calculateDelay(3, random));
    try std.testing.expectEqual(@as(u32, 8000), config.calculateDelay(4, random));
}

test "retry config with jitter" {
    const config = RetryConfig{
        .initial_delay_ms = 1000,
        .exponential_base = 2.0,
        .jitter = true,
    };

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    // With jitter, delay should be within range
    const delay = config.calculateDelay(2, random);
    try std.testing.expect(delay >= 1500); // 2000 - 500
    try std.testing.expect(delay <= 2500); // 2000 + 500
}

test "retry config max delay cap" {
    const config = RetryConfig{
        .initial_delay_ms = 1000,
        .max_delay_ms = 5000,
        .exponential_base = 2.0,
        .jitter = false,
    };

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    // Should cap at max_delay_ms
    try std.testing.expectEqual(@as(u32, 5000), config.calculateDelay(10, random));
}

test "retry config status code checking" {
    const config = RetryConfig{};

    try std.testing.expect(config.shouldRetryStatus(429));
    try std.testing.expect(config.shouldRetryStatus(503));
    try std.testing.expect(!config.shouldRetryStatus(200));
    try std.testing.expect(!config.shouldRetryStatus(404));
}

test "retry config error checking" {
    const config = RetryConfig{};

    try std.testing.expect(config.shouldRetryError(error.NetworkError));
    try std.testing.expect(config.shouldRetryError(error.Timeout));
    try std.testing.expect(!config.shouldRetryError(error.InvalidUrl));
}
