// ABOUTME: Mock implementations of providers and components for testing
// ABOUTME: Provides configurable mocks with response recording and verification capabilities

const std = @import("std");
const types = @import("../types.zig");
const Provider = @import("../provider.zig").Provider;
const ProviderMetadata = @import("../provider.zig").ProviderMetadata;
const Tool = @import("../tool.zig").Tool;
const ToolRegistry = @import("../tool_registry.zig").ToolRegistry;

pub const MockCall = struct {
    method: []const u8,
    args: std.json.Value,
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator, method: []const u8, args: std.json.Value) MockCall {
        return MockCall{
            .method = try allocator.dupe(u8, method),
            .args = args,
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *MockCall, allocator: std.mem.Allocator) void {
        allocator.free(self.method);
        // Note: args cleanup handled by caller
    }
};

pub const MockResponse = struct {
    content: []const u8,
    usage: ?types.Usage = null,
    metadata: ?std.json.Value = null,
    delay_ms: u32 = 0,
    should_fail: bool = false,
    error_type: ?anyerror = null,

    pub fn init(content: []const u8) MockResponse {
        return MockResponse{
            .content = content,
        };
    }

    pub fn withUsage(self: MockResponse, usage: types.Usage) MockResponse {
        var response = self;
        response.usage = usage;
        return response;
    }

    pub fn withDelay(self: MockResponse, delay_ms: u32) MockResponse {
        var response = self;
        response.delay_ms = delay_ms;
        return response;
    }

    pub fn withFailure(self: MockResponse, error_type: anyerror) MockResponse {
        var response = self;
        response.should_fail = true;
        response.error_type = error_type;
        return response;
    }

    pub fn toResponse(self: *const MockResponse, allocator: std.mem.Allocator) !types.Response {
        if (self.should_fail) {
            return self.error_type orelse error.MockError;
        }

        if (self.delay_ms > 0) {
            std.time.sleep(self.delay_ms * std.time.ns_per_ms);
        }

        return types.Response{
            .content = try allocator.dupe(u8, self.content),
            .usage = self.usage,
            .metadata = self.metadata,
        };
    }
};

pub const MockProvider = struct {
    base: Provider,
    allocator: std.mem.Allocator,
    responses: std.ArrayList(MockResponse),
    calls: std.ArrayList(MockCall),
    response_index: usize = 0,
    metadata: ProviderMetadata,

    const vtable = Provider.VTable{
        .generate = mockGenerate,
        .generateStream = mockGenerateStream,
        .getMetadata = mockGetMetadata,
        .close = mockClose,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8) MockProvider {
        return MockProvider{
            .base = Provider{ .vtable = &vtable },
            .allocator = allocator,
            .responses = std.ArrayList(MockResponse).init(allocator),
            .calls = std.ArrayList(MockCall).init(allocator),
            .metadata = ProviderMetadata{
                .name = name,
                .version = "1.0.0-mock",
                .capabilities = &.{},
                .models = &.{},
                .max_tokens = 8192,
            },
        };
    }

    pub fn deinit(self: *MockProvider) void {
        self.responses.deinit();

        for (self.calls.items) |*call| {
            call.deinit(self.allocator);
        }
        self.calls.deinit();
    }

    pub fn addResponse(self: *MockProvider, response: MockResponse) !void {
        try self.responses.append(response);
    }

    pub fn addResponses(self: *MockProvider, responses: []const MockResponse) !void {
        for (responses) |response| {
            try self.addResponse(response);
        }
    }

    pub fn getCallCount(self: *const MockProvider) usize {
        return self.calls.items.len;
    }

    pub fn getCall(self: *const MockProvider, index: usize) ?*const MockCall {
        if (index >= self.calls.items.len) return null;
        return &self.calls.items[index];
    }

    pub fn getLastCall(self: *const MockProvider) ?*const MockCall {
        if (self.calls.items.len == 0) return null;
        return &self.calls.items[self.calls.items.len - 1];
    }

    pub fn wasCalledWith(self: *const MockProvider, method: []const u8) bool {
        for (self.calls.items) |call| {
            if (std.mem.eql(u8, call.method, method)) {
                return true;
            }
        }
        return false;
    }

    pub fn reset(self: *MockProvider) void {
        for (self.calls.items) |*call| {
            call.deinit(self.allocator);
        }
        self.calls.clearRetainingCapacity();
        self.response_index = 0;
    }

    fn recordCall(self: *MockProvider, method: []const u8, messages: []const types.Message, options: types.GenerateOptions) !void {
        // Convert arguments to JSON for recording
        var args_obj = std.json.ObjectMap.init(self.allocator);
        defer args_obj.deinit();

        // Add messages array
        var messages_array = std.json.Array.init(self.allocator);
        defer messages_array.deinit();

        for (messages) |message| {
            var msg_obj = std.json.ObjectMap.init(self.allocator);
            defer msg_obj.deinit();

            try msg_obj.put("role", std.json.Value{ .string = @tagName(message.role) });

            switch (message.content) {
                .text => |text| {
                    try msg_obj.put("content", std.json.Value{ .string = text });
                },
                .multimodal => {
                    try msg_obj.put("content", std.json.Value{ .string = "[multimodal content]" });
                },
            }

            try messages_array.append(std.json.Value{ .object = msg_obj });
        }

        try args_obj.put("messages", std.json.Value{ .array = messages_array });

        // Add options
        var options_obj = std.json.ObjectMap.init(self.allocator);
        defer options_obj.deinit();

        if (options.temperature) |temp| {
            try options_obj.put("temperature", std.json.Value{ .float = temp });
        }
        if (options.max_tokens) |max| {
            try options_obj.put("max_tokens", std.json.Value{ .integer = @intCast(max) });
        }
        if (options.top_p) |top_p| {
            try options_obj.put("top_p", std.json.Value{ .float = top_p });
        }
        try options_obj.put("stream", std.json.Value{ .bool = options.stream });

        try args_obj.put("options", std.json.Value{ .object = options_obj });

        const call = MockCall.init(self.allocator, method, std.json.Value{ .object = args_obj });
        try self.calls.append(call);
    }

    fn mockGenerate(base: *Provider, messages: []const types.Message, options: types.GenerateOptions) !types.Response {
        const self: *MockProvider = @fieldParentPtr("base", base);

        try self.recordCall("generate", messages, options);

        if (self.response_index >= self.responses.items.len) {
            return error.NoMoreMockResponses;
        }

        const response = &self.responses.items[self.response_index];
        self.response_index += 1;

        return response.toResponse(self.allocator);
    }

    fn mockGenerateStream(base: *Provider, messages: []const types.Message, options: types.GenerateOptions) !types.StreamResponse {
        const self: *MockProvider = @fieldParentPtr("base", base);

        try self.recordCall("generateStream", messages, options);

        // For now, streaming just returns empty response
        return types.StreamResponse{};
    }

    fn mockGetMetadata(base: *Provider) ProviderMetadata {
        const self: *MockProvider = @fieldParentPtr("base", base);
        return self.metadata;
    }

    fn mockClose(base: *Provider) void {
        _ = base;
        // Nothing to do for mock
    }
};

pub const MockTool = struct {
    base: Tool,
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    responses: std.ArrayList([]const u8),
    calls: std.ArrayList(std.json.Value),
    response_index: usize = 0,
    should_fail: bool = false,

    const vtable = Tool.VTable{
        .getName = mockGetName,
        .getDescription = mockGetDescription,
        .getSchema = mockGetSchema,
        .execute = mockExecute,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, description: []const u8) MockTool {
        return MockTool{
            .base = Tool{ .vtable = &vtable },
            .allocator = allocator,
            .name = name,
            .description = description,
            .responses = std.ArrayList([]const u8).init(allocator),
            .calls = std.ArrayList(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *MockTool) void {
        self.responses.deinit();
        self.calls.deinit();
    }

    pub fn addResponse(self: *MockTool, response: []const u8) !void {
        try self.responses.append(response);
    }

    pub fn setFailure(self: *MockTool, should_fail: bool) void {
        self.should_fail = should_fail;
    }

    pub fn getCallCount(self: *const MockTool) usize {
        return self.calls.items.len;
    }

    pub fn reset(self: *MockTool) void {
        self.calls.clearRetainingCapacity();
        self.response_index = 0;
    }

    fn mockGetName(base: *Tool) []const u8 {
        const self: *MockTool = @fieldParentPtr("base", base);
        return self.name;
    }

    fn mockGetDescription(base: *Tool) []const u8 {
        const self: *MockTool = @fieldParentPtr("base", base);
        return self.description;
    }

    fn mockGetSchema(base: *Tool) ?std.json.Value {
        _ = base;
        return null; // Simple mock schema
    }

    fn mockExecute(base: *Tool, args: std.json.Value) ![]const u8 {
        const self: *MockTool = @fieldParentPtr("base", base);

        try self.calls.append(args);

        if (self.should_fail) {
            return error.MockToolFailure;
        }

        if (self.response_index >= self.responses.items.len) {
            return error.NoMoreMockResponses;
        }

        const response = self.responses.items[self.response_index];
        self.response_index += 1;

        return response;
    }
};

// Helper functions for creating common mocks
pub fn createMockProvider(allocator: std.mem.Allocator, name: []const u8) MockProvider {
    return MockProvider.init(allocator, name);
}

pub fn createSuccessProvider(allocator: std.mem.Allocator, responses: []const []const u8) !MockProvider {
    var provider = MockProvider.init(allocator, "success-mock");

    for (responses) |response_text| {
        try provider.addResponse(MockResponse.init(response_text));
    }

    return provider;
}

pub fn createFailureProvider(allocator: std.mem.Allocator, error_type: anyerror) !MockProvider {
    var provider = MockProvider.init(allocator, "failure-mock");
    try provider.addResponse(MockResponse.init("").withFailure(error_type));
    return provider;
}

pub fn createMockTool(allocator: std.mem.Allocator, name: []const u8, description: []const u8) MockTool {
    return MockTool.init(allocator, name, description);
}

// Test helpers
test "mock provider basic functionality" {
    const allocator = std.testing.allocator;

    var provider = createMockProvider(allocator, "test-provider");
    defer provider.deinit();

    try provider.addResponse(MockResponse.init("Hello, world!"));

    const message = types.Message{
        .role = .user,
        .content = .{ .text = "Hi there" },
    };

    const response = try provider.base.generate(&.{message}, types.GenerateOptions{});
    defer allocator.free(response.content);

    try std.testing.expectEqualStrings("Hello, world!", response.content);
    try std.testing.expectEqual(@as(usize, 1), provider.getCallCount());
    try std.testing.expect(provider.wasCalledWith("generate"));
}

test "mock provider call recording" {
    const allocator = std.testing.allocator;

    var provider = createMockProvider(allocator, "test-provider");
    defer provider.deinit();

    try provider.addResponse(MockResponse.init("Response 1"));
    try provider.addResponse(MockResponse.init("Response 2"));

    const message1 = types.Message{
        .role = .user,
        .content = .{ .text = "First message" },
    };

    const message2 = types.Message{
        .role = .user,
        .content = .{ .text = "Second message" },
    };

    _ = try provider.base.generate(&.{message1}, types.GenerateOptions{});
    _ = try provider.base.generate(&.{message2}, types.GenerateOptions{});

    try std.testing.expectEqual(@as(usize, 2), provider.getCallCount());

    const last_call = provider.getLastCall().?;
    try std.testing.expectEqualStrings("generate", last_call.method);
}

test "mock tool functionality" {
    const allocator = std.testing.allocator;

    var tool = createMockTool(allocator, "test-tool", "A test tool");
    defer tool.deinit();

    try tool.addResponse("Tool executed successfully");

    const args = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    const result = try tool.base.execute(args);

    try std.testing.expectEqualStrings("Tool executed successfully", result);
    try std.testing.expectEqual(@as(usize, 1), tool.getCallCount());
}
