// ABOUTME: Main library entry point for zig_llms, exporting all public modules and APIs
// ABOUTME: Provides unified access to agents, providers, tools, workflows, and bindings

const std = @import("std");

// Core types and infrastructure
pub const types = @import("types.zig");
pub const errors = @import("error.zig");
pub const context = @import("context.zig");
pub const state = struct {
    pub const State = @import("state.zig").State;
    pub const StateSnapshot = @import("state.zig").StateSnapshot;
    pub const StateUpdate = @import("state.zig").StateUpdate;
    pub const StateWatchCallback = @import("state.zig").StateWatchCallback;
    pub const StatePool = @import("state.zig").StatePool;
};

// Provider system
pub const provider = @import("provider.zig");
pub const providers = struct {
    pub const openai = @import("providers/openai.zig");
    pub const anthropic = @import("providers/anthropic.zig");
    pub const ollama = @import("providers/ollama.zig");
};

// Agent system
pub const agent = struct {
    pub const Agent = @import("agent.zig").Agent;
    pub const AgentType = @import("agent.zig").AgentType;
    pub const BaseAgent = @import("agent.zig").BaseAgent;
    pub const LLMAgent = @import("agent.zig").LLMAgent;
    pub const AgentConfig = @import("agent.zig").AgentConfig;
    pub const AgentLifecycle = @import("agent.zig").AgentLifecycle;
};
pub const prompt = @import("prompt.zig");

// Tool system
pub const tool = struct {
    pub const Tool = @import("tool.zig").Tool;
    pub const ToolMetadata = @import("tool.zig").ToolMetadata;
    pub const BaseTool = @import("tool.zig").BaseTool;
    pub const ToolResult = @import("tool.zig").ToolResult;
    pub const ToolExecutor = @import("tool.zig").ToolExecutor;
    pub const ToolBuilder = @import("tool.zig").ToolBuilder;
    pub const ToolCategory = @import("tool.zig").ToolCategory;
    pub const ToolCapability = @import("tool.zig").ToolCapability;
    pub const ToolExample = @import("tool.zig").ToolExample;
    pub const createFunctionTool = @import("tool.zig").createFunctionTool;
};
pub const tool_registry = struct {
    pub const ToolRegistry = @import("tool_registry.zig").ToolRegistry;
    pub const ToolInfo = @import("tool_registry.zig").ToolInfo;
    pub const ToolFilter = @import("tool_registry.zig").ToolFilter;
    pub const RegistryConfig = @import("tool_registry.zig").RegistryConfig;
    pub const ExternalLoader = @import("tool_registry.zig").ExternalLoader;
    pub const DiscoveryResult = @import("tool_registry.zig").DiscoveryResult;
};
pub const tools = struct {
    pub const discovery = @import("tools/discovery.zig");
    pub const validation = @import("tools/validation.zig");
    pub const persistence = @import("tools/persistence.zig");
    pub const external = @import("tools/external.zig");
};

// Workflow system
pub const workflow = @import("workflow.zig");
pub const workflows = struct {
    pub const definition = @import("workflow/definition.zig");
    pub const serialization = @import("workflow/serialization.zig");
    pub const sequential = @import("workflow/sequential.zig");
    pub const parallel = @import("workflow/parallel.zig");
    pub const conditional = @import("workflow/conditional.zig");
    pub const loop = @import("workflow/loop.zig");
    pub const script_step = @import("workflow/script_step.zig");
};

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

// Event system
pub const events = @import("events.zig");

// Utilities
pub const util = @import("util.zig");

test "simple test" {
    try std.testing.expect(true);
}