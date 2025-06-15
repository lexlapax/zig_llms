// ABOUTME: Common test data and setup utilities for consistent testing across the codebase
// ABOUTME: Provides reusable fixtures, builders, and test environment setup functions

const std = @import("std");
const types = @import("../types.zig");
const Provider = @import("../provider.zig").Provider;
const RunContext = @import("../context.zig").RunContext;
const ToolRegistry = @import("../tool_registry.zig").ToolRegistry;
const State = @import("../state.zig").State;
const mocks = @import("mocks.zig");

// Common test messages
pub const TestMessages = struct {
    pub const user_greeting = types.Message{
        .role = .user,
        .content = .{ .text = "Hello, how are you today?" },
    };
    
    pub const assistant_greeting = types.Message{
        .role = .assistant,
        .content = .{ .text = "Hello! I'm doing well, thank you for asking. How can I help you today?" },
    };
    
    pub const system_instruction = types.Message{
        .role = .system,
        .content = .{ .text = "You are a helpful AI assistant. Please be concise and accurate in your responses." },
    };
    
    pub const function_call = types.Message{
        .role = .function,
        .content = .{ .text = "{\"result\": \"success\", \"data\": \"operation completed\"}" },
    };
    
    pub const multimodal_message = types.Message{
        .role = .user,
        .content = .{ .multimodal = &.{
            .{ .text = "Please analyze this image:" },
            .{ .image = .{
                .data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
                .mime_type = "image/png",
            }},
        }},
    };
    
    pub const long_message = types.Message{
        .role = .user,
        .content = .{ .text = "This is a very long message that contains multiple sentences and is designed to test token counting and memory management features. " ** 10 },
    };
};

// Common test responses
pub const TestResponses = struct {
    pub const simple_response = types.Response{
        .content = "This is a simple test response.",
        .usage = types.Usage{
            .prompt_tokens = 10,
            .completion_tokens = 8,
            .total_tokens = 18,
        },
    };
    
    pub const detailed_response = types.Response{
        .content = "This is a detailed response with comprehensive information about the query. It includes multiple sentences and provides thorough coverage of the topic.",
        .usage = types.Usage{
            .prompt_tokens = 25,
            .completion_tokens = 32,
            .total_tokens = 57,
        },
    };
    
    pub const error_response = types.Response{
        .content = "I apologize, but I encountered an error while processing your request. Please try again.",
        .usage = types.Usage{
            .prompt_tokens = 15,
            .completion_tokens = 20,
            .total_tokens = 35,
        },
    };
};

// Common test generate options
pub const TestOptions = struct {
    pub const default_options = types.GenerateOptions{};
    
    pub const creative_options = types.GenerateOptions{
        .temperature = 0.9,
        .max_tokens = 2048,
        .top_p = 0.95,
    };
    
    pub const precise_options = types.GenerateOptions{
        .temperature = 0.1,
        .max_tokens = 1024,
        .top_p = 0.1,
    };
    
    pub const streaming_options = types.GenerateOptions{
        .stream = true,
        .max_tokens = 1024,
    };
};

// Test environment builder
pub const TestEnvironment = struct {
    allocator: std.mem.Allocator,
    provider: ?*mocks.MockProvider = null,
    tools: ?*ToolRegistry = null,
    state: ?*State = null,
    context: ?*RunContext = null,
    
    pub fn init(allocator: std.mem.Allocator) TestEnvironment {
        return TestEnvironment{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *TestEnvironment) void {
        if (self.context) |_| {
            // Context cleanup is handled by provider/tools/state cleanup
        }
        
        if (self.state) |state| {
            state.deinit();
            self.allocator.destroy(state);
        }
        
        if (self.tools) |tools| {
            tools.deinit();
            self.allocator.destroy(tools);
        }
        
        if (self.provider) |provider| {
            provider.deinit();
            self.allocator.destroy(provider);
        }
    }
    
    pub fn withMockProvider(self: *TestEnvironment, name: []const u8, responses: []const []const u8) !*TestEnvironment {
        const provider = try self.allocator.create(mocks.MockProvider);
        provider.* = mocks.createMockProvider(self.allocator, name);
        
        for (responses) |response_text| {
            try provider.addResponse(mocks.MockResponse.init(response_text));
        }
        
        self.provider = provider;
        return self;
    }
    
    pub fn withDefaultTools(self: *TestEnvironment) !*TestEnvironment {
        const tools = try self.allocator.create(ToolRegistry);
        tools.* = ToolRegistry.init(self.allocator);
        
        // Add some default test tools
        var test_tool = mocks.createMockTool(self.allocator, "test_tool", "A simple test tool");
        try test_tool.addResponse("Tool executed successfully");
        
        // Note: Would need to add tool to registry when registry supports it
        
        self.tools = tools;
        return self;
    }
    
    pub fn withEmptyState(self: *TestEnvironment) !*TestEnvironment {
        const state = try self.allocator.create(State);
        state.* = State.init(self.allocator);
        
        self.state = state;
        return self;
    }
    
    pub fn build(self: *TestEnvironment) !*RunContext {
        // Ensure we have all required components
        if (self.provider == null) {
            _ = try self.withMockProvider("default-test-provider", &.{"Default response"});
        }
        
        if (self.tools == null) {
            _ = try self.withDefaultTools();
        }
        
        if (self.state == null) {
            _ = try self.withEmptyState();
        }
        
        // Create context
        const context = try self.allocator.create(RunContext);
        context.* = RunContext.init(
            self.allocator,
            &self.provider.?.base,
            self.tools.?,
            self.state.?,
        );
        
        self.context = context;
        return context;
    }
};

// Conversation builders
pub const ConversationBuilder = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(types.Message),
    
    pub fn init(allocator: std.mem.Allocator) ConversationBuilder {
        return ConversationBuilder{
            .allocator = allocator,
            .messages = std.ArrayList(types.Message).init(allocator),
        };
    }
    
    pub fn deinit(self: *ConversationBuilder) void {
        self.messages.deinit();
    }
    
    pub fn addMessage(self: *ConversationBuilder, message: types.Message) !*ConversationBuilder {
        try self.messages.append(message);
        return self;
    }
    
    pub fn addUserMessage(self: *ConversationBuilder, content: []const u8) !*ConversationBuilder {
        return self.addMessage(types.Message{
            .role = .user,
            .content = .{ .text = content },
        });
    }
    
    pub fn addAssistantMessage(self: *ConversationBuilder, content: []const u8) !*ConversationBuilder {
        return self.addMessage(types.Message{
            .role = .assistant,
            .content = .{ .text = content },
        });
    }
    
    pub fn addSystemMessage(self: *ConversationBuilder, content: []const u8) !*ConversationBuilder {
        return self.addMessage(types.Message{
            .role = .system,
            .content = .{ .text = content },
        });
    }
    
    pub fn build(self: *ConversationBuilder) ![]const types.Message {
        return self.messages.toOwnedSlice();
    }
    
    pub fn getMessages(self: *const ConversationBuilder) []const types.Message {
        return self.messages.items;
    }
};

// Common conversation patterns
pub const CommonConversations = struct {
    pub fn createGreetingConversation(allocator: std.mem.Allocator) !ConversationBuilder {
        var builder = ConversationBuilder.init(allocator);
        
        _ = try builder.addSystemMessage("You are a helpful AI assistant.")
            .addUserMessage("Hello!")
            .addAssistantMessage("Hello! How can I help you today?")
            .addUserMessage("I'm doing well, thank you.");
        
        return builder;
    }
    
    pub fn createProblemSolvingConversation(allocator: std.mem.Allocator) !ConversationBuilder {
        var builder = ConversationBuilder.init(allocator);
        
        _ = try builder.addSystemMessage("You are a helpful problem-solving assistant.")
            .addUserMessage("I need help solving a technical issue.")
            .addAssistantMessage("I'd be happy to help! Could you please describe the technical issue you're experiencing?")
            .addUserMessage("My application is running slowly and consuming too much memory.")
            .addAssistantMessage("I can help you troubleshoot that. Let's start by identifying potential memory leaks and performance bottlenecks.");
        
        return builder;
    }
    
    pub fn createToolUseConversation(allocator: std.mem.Allocator) !ConversationBuilder {
        var builder = ConversationBuilder.init(allocator);
        
        _ = try builder.addSystemMessage("You have access to various tools to help users.")
            .addUserMessage("Can you search for information about machine learning?")
            .addAssistantMessage("I'll search for information about machine learning for you.")
            .addMessage(types.Message{
                .role = .function,
                .content = .{ .text = "{\"query\": \"machine learning\", \"results\": [\"Machine learning is a subset of AI...\"]}" },
            })
            .addAssistantMessage("Based on my search, machine learning is a subset of artificial intelligence...");
        
        return builder;
    }
};

// Test data generators
pub const TestDataGenerator = struct {
    allocator: std.mem.Allocator,
    random: std.rand.Random,
    
    pub fn init(allocator: std.mem.Allocator, seed: u64) TestDataGenerator {
        var prng = std.rand.DefaultPrng.init(seed);
        return TestDataGenerator{
            .allocator = allocator,
            .random = prng.random(),
        };
    }
    
    pub fn generateRandomMessage(self: *TestDataGenerator, role: types.Role) !types.Message {
        const content_options = [_][]const u8{
            "This is a random test message.",
            "Hello, this is a generated message for testing purposes.",
            "Random content for validation and testing scenarios.",
            "Generated test data with varying lengths and content.",
            "Another example of dynamically created test content.",
        };
        
        const selected_content = content_options[self.random.intRangeAtMost(usize, 0, content_options.len - 1)];
        
        return types.Message{
            .role = role,
            .content = .{ .text = selected_content },
        };
    }
    
    pub fn generateRandomConversation(self: *TestDataGenerator, length: usize) ![]types.Message {
        var messages = try std.ArrayList(types.Message).initCapacity(self.allocator, length);
        defer messages.deinit();
        
        const roles = [_]types.Role{ .user, .assistant };
        
        for (0..length) |i| {
            const role = roles[i % 2];
            const message = try self.generateRandomMessage(role);
            try messages.append(message);
        }
        
        return messages.toOwnedSlice();
    }
    
    pub fn generateRandomResponse(self: *TestDataGenerator) types.Response {
        const responses = [_][]const u8{
            "This is a randomly generated response.",
            "Generated response with different content for testing.",
            "Another variation of response content for validation.",
            "Random response data with simulated AI output.",
        };
        
        const selected_response = responses[self.random.intRangeAtMost(usize, 0, responses.len - 1)];
        const prompt_tokens = self.random.intRangeAtMost(u32, 5, 50);
        const completion_tokens = self.random.intRangeAtMost(u32, 10, 100);
        
        return types.Response{
            .content = selected_response,
            .usage = types.Usage{
                .prompt_tokens = prompt_tokens,
                .completion_tokens = completion_tokens,
                .total_tokens = prompt_tokens + completion_tokens,
            },
        };
    }
};

// Utility functions
pub fn createTestProvider(allocator: std.mem.Allocator, responses: []const []const u8) !mocks.MockProvider {
    var provider = mocks.createMockProvider(allocator, "test-provider");
    
    for (responses) |response_text| {
        try provider.addResponse(mocks.MockResponse.init(response_text));
    }
    
    return provider;
}

pub fn createTestContext(allocator: std.mem.Allocator) !*RunContext {
    var env = TestEnvironment.init(allocator);
    return env.build();
}

pub fn createTestContextWithProvider(allocator: std.mem.Allocator, provider: *Provider) !RunContext {
    var tools = ToolRegistry.init(allocator);
    var state = State.init(allocator);
    
    return RunContext.init(allocator, provider, &tools, &state);
}

// Tests for the fixtures
test "test environment builder" {
    const allocator = std.testing.allocator;
    
    var env = TestEnvironment.init(allocator);
    defer env.deinit();
    
    const context = try env.withMockProvider("test", &.{"Hello"})
        .withDefaultTools()
        .withEmptyState()
        .build();
    
    try std.testing.expect(context != null);
}

test "conversation builder" {
    const allocator = std.testing.allocator;
    
    var builder = ConversationBuilder.init(allocator);
    defer builder.deinit();
    
    _ = try builder.addUserMessage("Hello")
        .addAssistantMessage("Hi there!")
        .addUserMessage("How are you?");
    
    const messages = builder.getMessages();
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqual(types.Role.user, messages[0].role);
    try std.testing.expectEqual(types.Role.assistant, messages[1].role);
    try std.testing.expectEqual(types.Role.user, messages[2].role);
}

test "test data generator" {
    const allocator = std.testing.allocator;
    
    var generator = TestDataGenerator.init(allocator, 12345);
    
    const message = try generator.generateRandomMessage(.user);
    try std.testing.expectEqual(types.Role.user, message.role);
    
    const conversation = try generator.generateRandomConversation(5);
    defer allocator.free(conversation);
    try std.testing.expectEqual(@as(usize, 5), conversation.len);
    
    const response = generator.generateRandomResponse();
    try std.testing.expect(response.content.len > 0);
    try std.testing.expect(response.usage != null);
}