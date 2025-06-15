// ABOUTME: Short-term memory implementation for conversation history and context management
// ABOUTME: Provides ring buffer storage with token counting and message limits for agents

const std = @import("std");
const types = @import("../types.zig");

pub const RingBuffer = std.fifo.LinearFifo;

pub const TokenCounter = struct {
    // TODO: Implement token counting for different models
    pub fn count(self: *const TokenCounter, text: []const u8) u32 {
        _ = self;
        // Simple approximation: ~4 characters per token
        return @intCast((text.len + 3) / 4);
    }
    
    pub fn countMessage(self: *const TokenCounter, message: types.Message) u32 {
        switch (message.content) {
            .text => |text| return self.count(text),
            .multimodal => |parts| {
                var total: u32 = 0;
                for (parts) |part| {
                    switch (part) {
                        .text => |text| total += self.count(text),
                        .image => total += 85, // Approximate tokens for image
                        .file => total += 50, // Approximate tokens for file reference
                    }
                }
                return total;
            },
        }
    }
};

pub const ConversationMemory = struct {
    messages: std.ArrayList(types.Message),
    max_messages: usize,
    max_tokens: u32,
    token_counter: TokenCounter,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, max_messages: usize, max_tokens: u32) ConversationMemory {
        return ConversationMemory{
            .messages = std.ArrayList(types.Message).init(allocator),
            .max_messages = max_messages,
            .max_tokens = max_tokens,
            .token_counter = TokenCounter{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ConversationMemory) void {
        self.messages.deinit();
    }
    
    pub fn add(self: *ConversationMemory, message: types.Message) !void {
        try self.messages.append(message);
        
        // Enforce message limit
        while (self.messages.items.len > self.max_messages) {
            _ = self.messages.orderedRemove(0);
        }
        
        // Enforce token limit
        try self.enforceTokenLimit();
    }
    
    pub fn getContext(self: *ConversationMemory, max_tokens: ?u32) []const types.Message {
        const limit = max_tokens orelse self.max_tokens;
        var current_tokens: u32 = 0;
        var start_idx: usize = self.messages.items.len;
        
        // Work backwards to fit within token limit
        while (start_idx > 0) {
            start_idx -= 1;
            const message_tokens = self.token_counter.countMessage(self.messages.items[start_idx]);
            
            if (current_tokens + message_tokens > limit and current_tokens > 0) {
                start_idx += 1;
                break;
            }
            
            current_tokens += message_tokens;
        }
        
        return self.messages.items[start_idx..];
    }
    
    pub fn clear(self: *ConversationMemory) void {
        self.messages.clearRetainingCapacity();
    }
    
    pub fn getMessageCount(self: *const ConversationMemory) usize {
        return self.messages.items.len;
    }
    
    pub fn getTotalTokens(self: *const ConversationMemory) u32 {
        var total: u32 = 0;
        for (self.messages.items) |message| {
            total += self.token_counter.countMessage(message);
        }
        return total;
    }
    
    fn enforceTokenLimit(self: *ConversationMemory) !void {
        while (self.getTotalTokens() > self.max_tokens and self.messages.items.len > 0) {
            _ = self.messages.orderedRemove(0);
        }
    }
};

test "conversation memory" {
    const allocator = std.testing.allocator;
    
    var memory = ConversationMemory.init(allocator, 10, 1000);
    defer memory.deinit();
    
    const message = types.Message{
        .role = .user,
        .content = .{ .text = "Hello, world!" },
    };
    
    try memory.add(message);
    try std.testing.expectEqual(@as(usize, 1), memory.getMessageCount());
    
    const context = memory.getContext(null);
    try std.testing.expectEqual(@as(usize, 1), context.len);
}