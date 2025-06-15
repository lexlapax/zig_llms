// ABOUTME: Memory system module entry point aggregating short-term and long-term memory
// ABOUTME: Provides unified access to conversation history and persistent knowledge storage

const std = @import("std");

pub const short_term = @import("memory/short_term.zig");
pub const long_term = @import("memory/long_term.zig");

// Re-export commonly used types
pub const ConversationMemory = short_term.ConversationMemory;
pub const VectorStore = long_term.VectorStore;