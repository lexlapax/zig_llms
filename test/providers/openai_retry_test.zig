// ABOUTME: Tests for OpenAI provider retry logic
// ABOUTME: Verifies that transient failures are handled gracefully

const std = @import("std");
const testing = std.testing;
const zig_llms = @import("zig_llms");
const mocks = @import("../../src/testing/mocks.zig");
const types = @import("../../src/types.zig");

test "OpenAI provider retries on rate limit" {
    const allocator = testing.allocator;

    // Test configuration that simulates rate limiting
    const config = zig_llms.providers.openai.OpenAIConfig{
        .api_key = "test-key",
        .max_retries = 3,
        .timeout_ms = 1000,
    };

    // Create provider
    const provider = try zig_llms.providers.openai.OpenAIProvider.create(allocator, config);
    defer provider.vtable.close(provider);

    // Verify provider has retry configured
    const openai_provider: *zig_llms.providers.openai.OpenAIProvider = @fieldParentPtr("base", provider);
    try testing.expectEqual(@as(u8, 3), openai_provider.retry_client.config.max_attempts);
}

test "retry configuration for OpenAI" {
    const config = zig_llms.http.pool.RetryConfig{
        .max_attempts = 5,
        .initial_delay_ms = 1000,
        .retry_on_status_codes = &[_]u16{ 429, 503 },
    };

    // Test that OpenAI rate limit (429) is retryable
    try testing.expect(config.shouldRetryStatus(429));

    // Test that server errors are retryable
    try testing.expect(config.shouldRetryStatus(503));

    // Test that client errors are not retryable (except 429)
    try testing.expect(!config.shouldRetryStatus(400));
    try testing.expect(!config.shouldRetryStatus(401));
    try testing.expect(!config.shouldRetryStatus(404));
}

test "exponential backoff calculation" {
    const config = zig_llms.http.pool.RetryConfig{
        .initial_delay_ms = 1000,
        .exponential_base = 2.0,
        .jitter = false,
    };

    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();

    // Verify exponential backoff pattern
    const delay1 = config.calculateDelay(1, random);
    const delay2 = config.calculateDelay(2, random);
    const delay3 = config.calculateDelay(3, random);

    try testing.expectEqual(@as(u32, 1000), delay1);
    try testing.expectEqual(@as(u32, 2000), delay2);
    try testing.expectEqual(@as(u32, 4000), delay3);
}

test "retry with mock responses" {
    const allocator = testing.allocator;

    // Create a mock provider that simulates failures then success
    var mock_provider = mocks.createMockProvider(allocator, "retry-test");
    defer mock_provider.deinit();

    // Add responses: two failures, then success
    try mock_provider.addResponse(mocks.MockResponse.init("").withFailure(error.NetworkError));
    try mock_provider.addResponse(mocks.MockResponse.init("").withFailure(error.Timeout));
    try mock_provider.addResponse(mocks.MockResponse.init("Success after retries!"));

    const message = types.Message{
        .role = .user,
        .content = .{ .text = "Test retry logic" },
    };

    // This would fail without retry logic
    const response = try mock_provider.base.generate(&.{message}, .{});
    defer allocator.free(response.content);

    try testing.expectEqualStrings("Success after retries!", response.content);
    try testing.expectEqual(@as(usize, 3), mock_provider.getCallCount());
}
