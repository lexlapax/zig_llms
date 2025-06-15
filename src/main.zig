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

// HTTP infrastructure
pub const http = struct {
    pub const HttpClient = @import("http/client.zig").HttpClient;
    pub const HttpClientConfig = @import("http/client.zig").HttpClientConfig;
    pub const HttpRequest = @import("http/client.zig").HttpRequest;
    pub const HttpResponse = @import("http/client.zig").HttpResponse;
    pub const HttpMethod = @import("http/client.zig").HttpMethod;
    
    pub const PooledHttpClient = @import("http/pool.zig").PooledHttpClient;
    pub const ConnectionPool = @import("http/pool.zig").ConnectionPool;
    pub const ConnectionPoolConfig = @import("http/pool.zig").ConnectionPoolConfig;
    
    pub const RetryableHttpClient = @import("http/retry.zig").RetryableHttpClient;
    pub const RetryConfig = @import("http/retry.zig").RetryConfig;
    pub const RetryResult = @import("http/retry.zig").RetryResult;
    pub const retry = @import("http/retry.zig");
};

// Testing framework
pub const testing = struct {
    pub const scenario = @import("testing/scenario.zig");
    pub const mocks = @import("testing/mocks.zig");
    pub const matchers = @import("testing/matchers.zig");
    pub const fixtures = @import("testing/fixtures.zig");
};

// Output parsing
pub const outputs = struct {
    pub const Parser = @import("outputs/parser.zig").Parser;
    pub const ParseOptions = @import("outputs/parser.zig").ParseOptions;
    pub const ParseResult = @import("outputs/parser.zig").ParseResult;
    pub const ParserRegistry = @import("outputs/parser.zig").ParserRegistry;
    pub const JsonParser = @import("outputs/json_parser.zig").JsonParser;
    pub const YamlParser = @import("outputs/yaml_parser.zig").YamlParser;
    pub const recovery = @import("outputs/recovery.zig");
    pub const registry = @import("outputs/registry.zig");
    pub const extractor = @import("outputs/extractor.zig");
};

// Utilities
pub const util = @import("util.zig");

test "simple test" {
    try std.testing.expect(true);
}