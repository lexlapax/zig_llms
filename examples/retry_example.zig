// ABOUTME: Example demonstrating retry logic with exponential backoff
// ABOUTME: Shows how to handle transient failures gracefully

const std = @import("std");
const zig_llms = @import("zig_llms");
const HttpClient = zig_llms.http.HttpClient;
const HttpClientConfig = zig_llms.http.HttpClientConfig;
const RetryableHttpClient = zig_llms.http.RetryableHttpClient;
const RetryConfig = zig_llms.http.RetryConfig;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create base HTTP client
    const client_config = HttpClientConfig{
        .timeout_ms = 5000,
        .user_agent = "retry-example/1.0.0",
    };
    const http_client = HttpClient.init(allocator, client_config);

    // Configure retry behavior
    const retry_config = RetryConfig{
        .max_attempts = 5,
        .initial_delay_ms = 1000,
        .max_delay_ms = 30000,
        .exponential_base = 2.0,
        .jitter = true,
        .retry_on_status_codes = &[_]u16{ 429, 500, 502, 503, 504 },
    };

    // Create retryable client
    var retry_client = RetryableHttpClient.init(allocator, http_client, retry_config);
    defer retry_client.deinit();

    // Example 1: Simple GET request with retry
    std.debug.print("Example 1: GET request with retry\n", .{});
    var get_result = try retry_client.get("https://httpbin.org/status/503");
    if (get_result.succeeded) {
        std.debug.print("Request succeeded after {d} attempts\n", .{get_result.attempts});
        if (get_result.response) |*response| {
            defer response.deinit();
            std.debug.print("Response status: {d}\n", .{response.status_code});
        }
    } else {
        std.debug.print("Request failed after {d} attempts\n", .{get_result.attempts});
        if (get_result.last_error) |err| {
            std.debug.print("Last error: {any}\n", .{err});
        }
    }
    std.debug.print("Total retry delay: {d}ms\n\n", .{get_result.total_delay_ms});

    // Example 2: POST request with JSON data
    std.debug.print("Example 2: POST request with retry\n", .{});
    const post_data = .{
        .message = "Hello, retry!",
        .attempt = 1,
    };

    var post_result = try retry_client.postJson("https://httpbin.org/status/429", post_data);
    if (post_result.succeeded) {
        std.debug.print("Request succeeded after {d} attempts\n", .{post_result.attempts});
        if (post_result.response) |*response| {
            defer response.deinit();
            std.debug.print("Response status: {d}\n", .{response.status_code});
        }
    } else {
        std.debug.print("Request failed after {d} attempts\n", .{post_result.attempts});
        std.debug.print("Total retry delay: {d}ms\n", .{post_result.total_delay_ms});
    }

    // Example 3: Custom retry configuration
    std.debug.print("\nExample 3: Conservative retry strategy\n", .{});
    const conservative_config = zig_llms.http.retry.conservativeRetryConfig();
    var conservative_client = RetryableHttpClient.init(allocator, http_client, conservative_config);
    defer conservative_client.deinit();

    const conservative_result = try conservative_client.get("https://httpbin.org/delay/10");
    std.debug.print("Attempts: {d}, Success: {}\n", .{ conservative_result.attempts, conservative_result.succeeded });
}

test "retry integration with real HTTP client" {
    const allocator = std.testing.allocator;

    // Create HTTP client
    const client_config = HttpClientConfig{
        .timeout_ms = 1000,
    };
    const http_client = HttpClient.init(allocator, client_config);

    // Create retry client with fast retry for testing
    const retry_config = RetryConfig{
        .max_attempts = 3,
        .initial_delay_ms = 100,
        .max_delay_ms = 500,
        .jitter = false,
    };

    var retry_client = RetryableHttpClient.init(allocator, http_client, retry_config);
    defer retry_client.deinit();

    // This test would require network access, so we'll skip the actual request
    // In a real test, you'd use a mock server or test endpoint
}
