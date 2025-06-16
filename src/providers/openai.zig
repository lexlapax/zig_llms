// ABOUTME: OpenAI provider implementation with chat completions API support
// ABOUTME: Handles authentication, request formatting, and response parsing for OpenAI models

const std = @import("std");
const types = @import("../types.zig");
const Provider = @import("../provider.zig").Provider;
const ProviderMetadata = @import("metadata.zig").ProviderMetadata;
const OPENAI_METADATA = @import("metadata.zig").OPENAI_METADATA;
const HttpClient = @import("../http/client.zig").HttpClient;
const HttpClientConfig = @import("../http/client.zig").HttpClientConfig;
const PooledHttpClient = @import("../http/pool.zig").PooledHttpClient;
const ConnectionPoolConfig = @import("../http/pool.zig").ConnectionPoolConfig;
const RetryableHttpClient = @import("../http/retry.zig").RetryableHttpClient;
const RetryConfig = @import("../http/retry.zig").RetryConfig;

pub const OpenAIConfig = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.openai.com/v1",
    model: []const u8 = "gpt-4",
    organization: ?[]const u8 = null,
    max_retries: u8 = 3,
    timeout_ms: u32 = 30000,
};

// OpenAI API request/response types
const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
};

const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    stop: ?[]const []const u8 = null,
    stream: bool = false,
    user: ?[]const u8 = null,
};

const ChatCompletionChoice = struct {
    index: u32,
    message: ChatMessage,
    finish_reason: ?[]const u8 = null,
};

const ChatCompletionUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

const ChatCompletionResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []const ChatCompletionChoice,
    usage: ?ChatCompletionUsage = null,
};

const OpenAIError = struct {
    message: []const u8,
    type: []const u8,
    param: ?[]const u8 = null,
    code: ?[]const u8 = null,
};

const OpenAIErrorResponse = struct {
    @"error": OpenAIError,
};

pub const OpenAIProvider = struct {
    base: Provider,
    config: OpenAIConfig,
    http_client: PooledHttpClient,
    retry_client: RetryableHttpClient,
    allocator: std.mem.Allocator,

    const vtable = Provider.VTable{
        .generate = generate,
        .generateStream = generateStream,
        .getMetadata = getMetadata,
        .close = close,
    };

    pub fn create(allocator: std.mem.Allocator, config: OpenAIConfig) !*Provider {
        const provider = try allocator.create(OpenAIProvider);

        const pool_config = ConnectionPoolConfig{
            .max_connections = 10,
            .max_idle_time_ms = 300000,
        };

        const client_config = HttpClientConfig{
            .timeout_ms = config.timeout_ms,
            .user_agent = "zig-llms-openai/1.0.0",
        };

        const pooled_client = PooledHttpClient.init(allocator, pool_config, client_config);

        // Configure retry logic for OpenAI API
        const retry_config = RetryConfig{
            .max_attempts = config.max_retries,
            .initial_delay_ms = 1000,
            .max_delay_ms = 60000,
            .exponential_base = 2.0,
            .jitter = true,
            // OpenAI specific retry status codes
            .retry_on_status_codes = &[_]u16{ 429, 500, 502, 503, 504, 520, 521, 522, 523, 524 },
        };

        // Create a basic HTTP client for the retry wrapper
        const basic_client = HttpClient.init(allocator, client_config);

        provider.* = OpenAIProvider{
            .base = Provider{ .vtable = &vtable },
            .config = config,
            .http_client = pooled_client,
            .retry_client = RetryableHttpClient.init(allocator, basic_client, retry_config),
            .allocator = allocator,
        };

        return &provider.base;
    }

    fn convertMessages(allocator: std.mem.Allocator, messages: []const types.Message) ![]ChatMessage {
        var chat_messages = try std.ArrayList(ChatMessage).initCapacity(allocator, messages.len);
        defer chat_messages.deinit();

        for (messages) |message| {
            const role_str = switch (message.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .function => "function",
            };

            const content = switch (message.content) {
                .text => |text| text,
                .multimodal => |_| {
                    // For now, convert multimodal to text description
                    // TODO: Implement proper multimodal support
                    "[Multimodal content not yet supported]";
                },
            };

            try chat_messages.append(ChatMessage{
                .role = role_str,
                .content = content,
            });
        }

        return chat_messages.toOwnedSlice();
    }

    fn convertResponse(allocator: std.mem.Allocator, openai_response: ChatCompletionResponse) !types.Response {
        if (openai_response.choices.len == 0) {
            return error.NoChoicesInResponse;
        }

        const choice = openai_response.choices[0];
        const content = try allocator.dupe(u8, choice.message.content);

        const usage = if (openai_response.usage) |u| types.Usage{
            .prompt_tokens = u.prompt_tokens,
            .completion_tokens = u.completion_tokens,
            .total_tokens = u.total_tokens,
        } else null;

        return types.Response{
            .content = content,
            .usage = usage,
            .metadata = null, // TODO: Add metadata if needed
        };
    }

    fn buildRequestUrl(self: *const OpenAIProvider, endpoint: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config.base_url, endpoint });
    }

    fn makeRequest(self: *OpenAIProvider, request_data: ChatCompletionRequest) !ChatCompletionResponse {
        const url = try self.buildRequestUrl("chat/completions");
        defer self.allocator.free(url);

        var http_request = @import("../http/client.zig").request(self.allocator, .POST, url);
        defer http_request.deinit();

        // Set headers
        try http_request.setBearerAuth(self.config.api_key);
        try http_request.setHeader("Content-Type", "application/json");

        if (self.config.organization) |org| {
            try http_request.setHeader("OpenAI-Organization", org);
        }

        // Set JSON body
        try http_request.setJsonBody(request_data);

        // Execute request with retry logic for production use
        // For testing, you could use self.http_client.execute(&http_request) directly
        const retry_result = try self.retry_client.execute(&http_request);

        if (!retry_result.succeeded) {
            std.log.err("All retry attempts failed for OpenAI API request", .{});
            return retry_result.last_error orelse error.OpenAIAPIError;
        }

        var response = retry_result.response orelse return error.NoResponse;
        defer response.deinit();

        if (!response.isSuccess()) {
            // Try to parse error response
            if (response.parseJson(OpenAIErrorResponse)) |error_parsed| {
                defer error_parsed.deinit();

                const error_msg = try std.fmt.allocPrint(self.allocator, "OpenAI API error ({d}): {s}", .{ response.status_code, error_parsed.value.@"error".message });
                defer self.allocator.free(error_msg);

                std.log.err("{s}", .{error_msg});
                return error.OpenAIAPIError;
            } else |_| {
                std.log.err("OpenAI API request failed with status {d}: {s}", .{ response.status_code, response.body });
                return error.OpenAIAPIError;
            }
        }

        // Parse successful response
        const parsed = try response.parseJson(ChatCompletionResponse);
        defer parsed.deinit();

        return parsed.value;
    }

    fn generate(base: *Provider, messages: []const types.Message, options: types.GenerateOptions) !types.Response {
        const self: *OpenAIProvider = @fieldParentPtr("base", base);

        // Convert messages to OpenAI format
        const chat_messages = try self.convertMessages(self.allocator, messages);
        defer self.allocator.free(chat_messages);

        // Build request
        const request_data = ChatCompletionRequest{
            .model = self.config.model,
            .messages = chat_messages,
            .temperature = options.temperature,
            .max_tokens = options.max_tokens,
            .top_p = options.top_p,
            .stop = options.stop_sequences,
            .stream = options.stream,
        };

        // Make API request
        const openai_response = try self.makeRequest(request_data);

        // Convert response
        return self.convertResponse(self.allocator, openai_response);
    }

    fn generateStream(base: *Provider, messages: []const types.Message, options: types.GenerateOptions) !types.StreamResponse {
        _ = base;
        _ = messages;
        _ = options;

        // TODO: Implement streaming support
        return types.StreamResponse{};
    }

    fn getMetadata(base: *Provider) ProviderMetadata {
        _ = base;
        return OPENAI_METADATA;
    }

    fn close(base: *Provider) void {
        const self: *OpenAIProvider = @fieldParentPtr("base", base);
        self.http_client.deinit();
        self.retry_client.deinit();
        self.allocator.destroy(self);
    }
};

// Convenience functions
pub fn createProvider(allocator: std.mem.Allocator, config: OpenAIConfig) !*Provider {
    return OpenAIProvider.create(allocator, config);
}

pub fn createFromEnvironment(allocator: std.mem.Allocator) !*Provider {
    const api_key = std.posix.getenv("OPENAI_API_KEY") orelse return error.MissingAPIKey;
    const model = std.posix.getenv("OPENAI_MODEL") orelse "gpt-4";
    const organization = std.posix.getenv("OPENAI_ORGANIZATION");

    const config = OpenAIConfig{
        .api_key = api_key,
        .model = model,
        .organization = organization,
    };

    return createProvider(allocator, config);
}

// Tests
test "openai provider creation" {
    const allocator = std.testing.allocator;

    const config = OpenAIConfig{
        .api_key = "test-api-key",
        .model = "gpt-3.5-turbo",
    };

    const provider = try OpenAIProvider.create(allocator, config);
    defer provider.vtable.close(provider);

    const metadata = provider.vtable.getMetadata(provider);
    try std.testing.expectEqualStrings("openai", metadata.name);
}

test "message conversion" {
    const allocator = std.testing.allocator;

    const config = OpenAIConfig{
        .api_key = "test-api-key",
    };

    const provider_ptr = try OpenAIProvider.create(allocator, config);
    defer provider_ptr.vtable.close(provider_ptr);

    const provider: *OpenAIProvider = @fieldParentPtr("base", provider_ptr);

    const messages = [_]types.Message{
        .{
            .role = .system,
            .content = .{ .text = "You are a helpful assistant." },
        },
        .{
            .role = .user,
            .content = .{ .text = "Hello, how are you?" },
        },
    };

    const chat_messages = try provider.convertMessages(allocator, &messages);
    defer allocator.free(chat_messages);

    try std.testing.expectEqual(@as(usize, 2), chat_messages.len);
    try std.testing.expectEqualStrings("system", chat_messages[0].role);
    try std.testing.expectEqualStrings("You are a helpful assistant.", chat_messages[0].content);
    try std.testing.expectEqualStrings("user", chat_messages[1].role);
    try std.testing.expectEqualStrings("Hello, how are you?", chat_messages[1].content);
}

test "request url building" {
    const allocator = std.testing.allocator;

    const config = OpenAIConfig{
        .api_key = "test-api-key",
        .base_url = "https://api.openai.com/v1",
    };

    const provider_ptr = try OpenAIProvider.create(allocator, config);
    defer provider_ptr.vtable.close(provider_ptr);

    const provider: *OpenAIProvider = @fieldParentPtr("base", provider_ptr);

    const url = try provider.buildRequestUrl("chat/completions");
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", url);
}
