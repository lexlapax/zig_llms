// ABOUTME: Prompt templating and management utilities for LLM interactions
// ABOUTME: Provides template rendering, variable substitution, and prompt formatting

const std = @import("std");
const types = @import("types.zig");

pub const PromptTemplate = struct {
    template: []const u8,
    variables: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, template: []const u8) PromptTemplate {
        return PromptTemplate{
            .template = template,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *PromptTemplate) void {
        self.variables.deinit();
    }
    
    pub fn setVariable(self: *PromptTemplate, name: []const u8, value: []const u8) !void {
        try self.variables.put(name, value);
    }
    
    pub fn render(self: *PromptTemplate) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        var i: usize = 0;
        while (i < self.template.len) {
            if (i + 1 < self.template.len and 
                self.template[i] == '{' and self.template[i + 1] == '{') {
                // Find closing braces
                const start = i + 2;
                var end = start;
                while (end + 1 < self.template.len) {
                    if (self.template[end] == '}' and self.template[end + 1] == '}') {
                        break;
                    }
                    end += 1;
                }
                
                if (end + 1 < self.template.len) {
                    const var_name = self.template[start..end];
                    if (self.variables.get(var_name)) |value| {
                        try result.appendSlice(value);
                    } else {
                        // Variable not found, keep original
                        try result.appendSlice(self.template[i..end + 2]);
                    }
                    i = end + 2;
                } else {
                    try result.append(self.template[i]);
                    i += 1;
                }
            } else {
                try result.append(self.template[i]);
                i += 1;
            }
        }
        
        return result.toOwnedSlice();
    }
};

pub const PromptBuilder = struct {
    system_prompt: ?[]const u8 = null,
    user_prompts: std.ArrayList([]const u8),
    assistant_prompts: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PromptBuilder {
        return PromptBuilder{
            .user_prompts = std.ArrayList([]const u8).init(allocator),
            .assistant_prompts = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *PromptBuilder) void {
        self.user_prompts.deinit();
        self.assistant_prompts.deinit();
    }
    
    pub fn setSystemPrompt(self: *PromptBuilder, prompt: []const u8) void {
        self.system_prompt = prompt;
    }
    
    pub fn addUserMessage(self: *PromptBuilder, message: []const u8) !void {
        try self.user_prompts.append(message);
    }
    
    pub fn addAssistantMessage(self: *PromptBuilder, message: []const u8) !void {
        try self.assistant_prompts.append(message);
    }
    
    pub fn build(self: *PromptBuilder) ![]types.Message {
        var messages = std.ArrayList(types.Message).init(self.allocator);
        defer messages.deinit();
        
        // Add system message if present
        if (self.system_prompt) |sys_prompt| {
            try messages.append(types.Message{
                .role = .system,
                .content = .{ .text = sys_prompt },
            });
        }
        
        // Interleave user and assistant messages
        const max_len = @max(self.user_prompts.items.len, self.assistant_prompts.items.len);
        for (0..max_len) |i| {
            if (i < self.user_prompts.items.len) {
                try messages.append(types.Message{
                    .role = .user,
                    .content = .{ .text = self.user_prompts.items[i] },
                });
            }
            if (i < self.assistant_prompts.items.len) {
                try messages.append(types.Message{
                    .role = .assistant,
                    .content = .{ .text = self.assistant_prompts.items[i] },
                });
            }
        }
        
        return messages.toOwnedSlice();
    }
};

// Common prompt templates
pub const CHAT_TEMPLATE = 
    \\You are a helpful AI assistant. 
    \\{{context}}
    \\
    \\User: {{user_input}}
    \\Assistant:
;

pub const TOOL_USE_TEMPLATE = 
    \\You are an AI assistant with access to tools. 
    \\Available tools: {{tools}}
    \\
    \\Use tools when appropriate to help answer the user's question.
    \\
    \\User: {{user_input}}
    \\Assistant:
;

test "prompt template" {
    const allocator = std.testing.allocator;
    
    var template = PromptTemplate.init(allocator, "Hello {{name}}, welcome to {{place}}!");
    defer template.deinit();
    
    try template.setVariable("name", "World");
    try template.setVariable("place", "Zig");
    
    const result = try template.render();
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings("Hello World, welcome to Zig!", result);
}