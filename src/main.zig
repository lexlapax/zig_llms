// ABOUTME: Main library entry point for zig_llms, exporting all public modules and APIs
// ABOUTME: Provides unified access to agents, providers, tools, workflows, and bindings

const std = @import("std");

// Core types and infrastructure
pub const types = @import("types.zig");
pub const errors = @import("error.zig");
pub const context = @import("context.zig");
pub const state = @import("state.zig");

// Provider system
pub const provider = @import("provider.zig");
pub const providers = struct {
    pub const openai = @import("providers/openai.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const ollama = @import("providers/ollama.zig");
};

// Agent system
pub const agent = @import("agent.zig");
pub const prompt = @import("prompt.zig");

// Tool system
pub const tool = @import("tool.zig");
pub const tool_registry = @import("tool_registry.zig");

// Workflow system
pub const workflow = @import("workflow.zig");

// Memory system
pub const memory = @import("memory.zig");

// Language bindings
pub const bindings = @import("bindings/capi.zig");

// Utilities
pub const util = @import("util.zig");

test "simple test" {
    try std.testing.expect(true);
}