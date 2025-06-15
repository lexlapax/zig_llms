# zig_llms Implementation Plan

## Executive Summary

Based on analysis of go-llms, Google ADK, and go-llmspell, this plan outlines a comprehensive approach to building zig_llms as a high-performance, memory-safe LLM agent framework with excellent scripting language integration capabilities.

## Core Design Principles

1. **Interface-First Design**: Define clear interfaces before implementations
2. **Compile-Time Safety**: Leverage Zig's comptime features for type safety
3. **Zero-Cost Abstractions**: Performance should match hand-written C code
4. **Explicit Memory Management**: No hidden allocations, caller controls memory
5. **C-API First**: Design internal APIs to be easily exposable via C
6. **Minimal Dependencies**: Use only essential external libraries
7. **Bridge-Friendly Architecture**: Prioritize scripting language integration from the start
8. **Runtime Extensibility**: Support dynamic tool and provider registration
9. **Structured Error Handling**: Serializable errors with recovery strategies

## Phase 1: Foundation (Weeks 1-2)

### 1.1 Core Interfaces and Types
```zig
// src/types.zig - Core type definitions
pub const Message = struct {
    role: Role,
    content: Content,
    metadata: ?std.json.Value,
};

pub const Content = union(enum) {
    text: []const u8,
    multimodal: []const MultimodalPart,
};

// src/provider.zig - Provider interface
pub const Provider = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        generate: fn (self: *Provider, messages: []const Message, options: GenerateOptions) anyerror!Response,
        generateStream: fn (self: *Provider, messages: []const Message, options: GenerateOptions) anyerror!StreamResponse,
        close: fn (self: *Provider) void,
    };
};
```

### 1.2 Memory Management Architecture
- Implement arena allocators for request-scoped memory
- Object pools for frequently allocated structures
- Clear ownership model with explicit lifetime management

### 1.3 Error Handling System
```zig
// src/error.zig - Structured error handling with serialization
pub const LLMError = error{
    ProviderError,
    NetworkError,
    RateLimitError,
    InvalidResponse,
    Timeout,
    SchemaValidationError,
    ToolExecutionError,
};

pub const SerializableError = struct {
    code: []const u8,
    message: []const u8,
    context: std.json.Value,
    recovery_strategy: ?RecoveryStrategy,
    cause: ?*SerializableError,
    
    pub fn toJSON(self: *const SerializableError, allocator: std.mem.Allocator) ![]const u8 {
        // Serialize to JSON for logging and debugging
    }
    
    pub fn fromError(err: anyerror, code: []const u8, context: std.json.Value) SerializableError {
        // Convert any error to serializable format
    }
};

pub const RecoveryStrategy = enum {
    retry_once,
    retry_with_backoff,
    failover,
    none,
};
```

### 1.4 Schema Repository System
```zig
// src/schema/repository.zig - Schema storage implementations
pub const SchemaRepository = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        get: fn (self: *SchemaRepository, id: []const u8) anyerror!?Schema,
        put: fn (self: *SchemaRepository, id: []const u8, schema: Schema) anyerror!void,
        list: fn (self: *SchemaRepository) anyerror![]const []const u8,
        delete: fn (self: *SchemaRepository, id: []const u8) anyerror!void,
    };
};

// Built-in implementations
pub const InMemoryRepository = struct {
    schemas: std.StringHashMap(Schema),
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: std.mem.Allocator) InMemoryRepository {
        // Initialize in-memory storage
    }
};

pub const FileRepository = struct {
    base_path: []const u8,
    format: enum { json, yaml },
    
    pub fn init(path: []const u8) FileRepository {
        // Initialize file-based storage
    }
};
```

## Phase 2: Provider Implementation (Weeks 3-4)

### 2.1 Provider Factory Pattern
```zig
// src/providers/factory.zig
pub fn createProvider(allocator: std.mem.Allocator, config: ProviderConfig) !*Provider {
    return switch (config) {
        .openai => |cfg| try OpenAIProvider.create(allocator, cfg),
        .anthropic => |cfg| try AnthropicProvider.create(allocator, cfg),
        .ollama => |cfg| try OllamaProvider.create(allocator, cfg),
    };
}

// Provider metadata for discovery
pub const ProviderMetadata = struct {
    name: []const u8,
    description: []const u8,
    capabilities: []const Capability,
    models: []const ModelInfo,
    constraints: Constraints,
    config_schema: Schema,
    
    pub const Capability = enum {
        streaming,
        function_calling,
        vision,
        embeddings,
    };
    
    pub const ModelInfo = struct {
        id: []const u8,
        max_tokens: u32,
        supports_functions: bool,
        supports_vision: bool,
    };
};

// Dynamic provider registry
pub const ProviderRegistry = struct {
    providers: std.StringHashMap(*Provider),
    metadata: std.StringHashMap(ProviderMetadata),
    
    pub fn register(self: *ProviderRegistry, provider: *Provider, metadata: ProviderMetadata) !void {
        // Dynamic provider registration
    }
    
    pub fn discover(self: *ProviderRegistry) []const ProviderMetadata {
        // Return all available providers without instantiation
    }
};
```

### 2.2 HTTP Client Abstraction
- Wrapper around std.http.Client
- Connection pooling
- Retry logic with exponential backoff
- Request/response interceptors

### 2.3 JSON Schema Validation
```zig
// src/schema.zig
pub const Schema = struct {
    root: SchemaNode,
    
    pub fn validate(self: *const Schema, value: std.json.Value) !void {
        // Implement JSON Schema validation
    }
    
    pub fn coerce(self: *const Schema, value: *std.json.Value) !void {
        // Type coercion support
    }
};
```

## Phase 3: Agent System (Weeks 5-6)

### 3.1 Agent Interface
```zig
// src/agent.zig
pub const Agent = struct {
    vtable: *const VTable,
    state: *State,
    
    pub const VTable = struct {
        initialize: fn (self: *Agent, context: *RunContext) anyerror!void,
        beforeRun: fn (self: *Agent, input: std.json.Value) anyerror!std.json.Value,
        run: fn (self: *Agent, input: std.json.Value) anyerror!std.json.Value,
        afterRun: fn (self: *Agent, output: std.json.Value) anyerror!std.json.Value,
        cleanup: fn (self: *Agent) void,
    };
};
```

### 3.2 State Management
```zig
// src/state.zig
pub const State = struct {
    data: std.StringHashMap(std.json.Value),
    artifacts: std.StringHashMap([]const u8),
    messages: std.ArrayList(Message),
    version: u32,
    mutex: std.Thread.Mutex,
    
    pub fn update(self: *State, key: []const u8, value: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // Thread-safe state updates
    }
};
```

### 3.3 Context and Dependency Injection
```zig
// src/context.zig
pub const RunContext = struct {
    allocator: std.mem.Allocator,
    provider: *Provider,
    tools: ToolRegistry,
    logger: Logger,
    tracer: ?Tracer,
};
```

## Phase 4: Tool System (Weeks 7-8)

### 4.1 Tool Interface
```zig
// src/tool.zig
pub const Tool = struct {
    metadata: ToolMetadata,
    vtable: *const VTable,
    
    pub const VTable = struct {
        execute: fn (self: *Tool, context: *RunContext, input: std.json.Value) anyerror!std.json.Value,
        validate: fn (self: *Tool, input: std.json.Value) anyerror!void,
    };
    
    pub const ToolMetadata = struct {
        name: []const u8,
        description: []const u8,
        input_schema: Schema,
        output_schema: Schema,
        tags: []const []const u8,
    };
};
```

### 4.2 Tool Registry
```zig
// src/tool_registry.zig - Enhanced with dynamic registration
pub const ToolRegistry = struct {
    builtin_tools: std.StringHashMap(ToolInfo),
    dynamic_tools: std.StringHashMap(ToolInfo),
    factories: std.StringHashMap(ToolFactory),
    mutex: std.Thread.Mutex,
    
    pub const ToolInfo = struct {
        metadata: ToolMetadata,
        factory: ToolFactory,
    };
    
    pub fn discover(self: *ToolRegistry) []const ToolMetadata {
        // Return all tools without instantiation
        self.mutex.lock();
        defer self.mutex.unlock();
        // Merge builtin and dynamic tools
    }
    
    pub fn create(self: *ToolRegistry, name: []const u8) !*Tool {
        // Factory-based tool creation
    }
    
    pub fn registerTool(self: *ToolRegistry, info: ToolMetadata, factory: ToolFactory) !void {
        // Dynamic tool registration at runtime
        self.mutex.lock();
        defer self.mutex.unlock();
        // Add to dynamic_tools
    }
    
    pub fn unregisterTool(self: *ToolRegistry, name: []const u8) !void {
        // Remove dynamic tool
    }
    
    pub fn save(self: *ToolRegistry, writer: anytype) !void {
        // Persist registry for reload
    }
    
    pub fn load(self: *ToolRegistry, reader: anytype) !void {
        // Load persisted registry
    }
};
```

### 4.3 Built-in Tools
- File operations (read, write, list)
- HTTP requests
- JSON manipulation
- System information
- Process execution

## Phase 5: Workflow Engine (Weeks 9-10)

### 5.1 Workflow Patterns
```zig
// src/workflow/sequential.zig
pub const SequentialWorkflow = struct {
    agents: []const *Agent,
    
    pub fn execute(self: *SequentialWorkflow, context: *RunContext, input: std.json.Value) !std.json.Value {
        var result = input;
        for (self.agents) |agent| {
            result = try agent.run(result);
        }
        return result;
    }
};

// src/workflow/definition.zig - Serializable workflow definitions
pub const WorkflowDefinition = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    steps: []const Step,
    metadata: std.json.Value,
    
    pub const Step = union(enum) {
        agent: AgentStep,
        tool: ToolStep,
        script: ScriptStep,
        conditional: ConditionalStep,
        parallel: ParallelStep,
    };
    
    pub const ScriptStep = struct {
        id: []const u8,
        script: []const u8,
        language: []const u8, // "lua", "javascript", "expr"
        inputs: []const []const u8,
        outputs: []const []const u8,
    };
};

// src/workflow/serialization.zig
pub const WorkflowSerializer = struct {
    format: enum { json, yaml },
    
    pub fn serialize(self: *WorkflowSerializer, def: *const WorkflowDefinition) ![]const u8 {
        // Convert workflow to JSON/YAML
    }
    
    pub fn deserialize(self: *WorkflowSerializer, data: []const u8) !WorkflowDefinition {
        // Parse workflow from JSON/YAML
    }
};

// Script handler registry for extensibility
pub var script_handlers = std.StringHashMap(ScriptHandler){};

pub fn registerScriptHandler(language: []const u8, handler: ScriptHandler) !void {
    try script_handlers.put(language, handler);
}
```

### 5.2 Parallel Execution
```zig
// src/workflow/parallel.zig
pub const ParallelWorkflow = struct {
    agents: []const *Agent,
    aggregator: AggregatorFn,
    
    pub fn execute(self: *ParallelWorkflow, context: *RunContext, input: std.json.Value) !std.json.Value {
        var results = try context.allocator.alloc(std.json.Value, self.agents.len);
        defer context.allocator.free(results);
        
        // Use thread pool for parallel execution
        var pool = try ThreadPool.init(context.allocator, 4);
        defer pool.deinit();
        
        // Execute agents in parallel
        // Aggregate results
    }
};
```

## Phase 6: Memory Systems (Weeks 11-12)

### 6.1 Short-term Memory
```zig
// src/memory/short_term.zig
pub const ConversationMemory = struct {
    messages: RingBuffer(Message),
    max_messages: usize,
    token_counter: TokenCounter,
    
    pub fn add(self: *ConversationMemory, message: Message) !void {
        // Add with token limit management
    }
    
    pub fn getContext(self: *ConversationMemory, max_tokens: usize) []const Message {
        // Return messages within token limit
    }
};
```

### 6.2 Long-term Memory (Future)
- Vector store integration
- Embedding generation
- Similarity search

## Phase 7: C-API and Bindings (Weeks 13-14)

### 7.1 C-API Design
```zig
// src/bindings/capi.zig - Enhanced C-API with error handling
export fn zig_llms_provider_create(config_json: [*c]const u8) ?*c_void {
    // Create provider from JSON config
}

export fn zig_llms_agent_create(provider: *c_void, system_prompt: [*c]const u8) ?*c_void {
    // Create agent
}

export fn zig_llms_agent_run(agent: *c_void, input_json: [*c]const u8) [*c]u8 {
    // Run agent and return JSON result
}

// Error handling for C-API
export fn zig_llms_get_last_error() [*c]u8 {
    // Return serialized error information
}

// Tool registration from external languages
export fn zig_llms_register_tool(
    name: [*c]const u8,
    schema_json: [*c]const u8,
    handler: fn(input: [*c]const u8) callconv(.C) [*c]u8
) c_int {
    // Register external tool with callback
}

// Event subscription for external monitoring
export fn zig_llms_subscribe_events(
    pattern: [*c]const u8,
    handler: fn(event: [*c]const u8) callconv(.C) void
) c_int {
    // Subscribe to events matching pattern
}

// Type conversion helpers
export fn zig_llms_convert_to_json(value: *c_void, type_id: c_int) [*c]u8 {
    // Convert internal types to JSON for bridges
}

export fn zig_llms_convert_from_json(json: [*c]const u8, type_id: c_int) ?*c_void {
    // Convert JSON to internal types
}
```

### 7.2 Type Conversion Registry
```zig
// src/bindings/type_registry.zig - Bridge-friendly type conversions
pub const TypeRegistry = struct {
    converters: std.AutoHashMap(TypePair, Converter),
    
    pub const TypePair = struct {
        from: std.builtin.Type,
        to: std.builtin.Type,
    };
    
    pub const Converter = struct {
        convert: fn (from: anytype, allocator: std.mem.Allocator) anyerror!anytype,
        can_reverse: bool,
        reverse: ?fn (from: anytype, allocator: std.mem.Allocator) anyerror!anytype,
    };
    
    pub fn registerConverter(self: *TypeRegistry, from: type, to: type, converter: Converter) !void {
        // Register type converter
    }
    
    pub fn convert(self: *TypeRegistry, value: anytype, comptime T: type, allocator: std.mem.Allocator) !T {
        // Perform type conversion, including multi-hop
    }
};

// Pre-registered converters for common types
pub fn initDefaultRegistry(allocator: std.mem.Allocator) !TypeRegistry {
    var registry = TypeRegistry.init(allocator);
    
    // Schema <-> JSON
    try registry.registerConverter(Schema, std.json.Value, schemaToJsonConverter);
    try registry.registerConverter(std.json.Value, Schema, jsonToSchemaConverter);
    
    // Message <-> JSON
    try registry.registerConverter(Message, std.json.Value, messageToJsonConverter);
    
    return registry;
}
```

### 7.3 Lua Bindings
```lua
-- Example Lua usage with enhanced features
local llm = require("zig_llms")

-- Create provider with discovery
local providers = llm.discover_providers()
for _, p in ipairs(providers) do
    print(p.name, p.capabilities)
end

local provider = llm.create_provider({type = "openai", api_key = "..."})

-- Register custom tool from Lua
llm.register_tool({
    name = "weather",
    description = "Get weather information",
    schema = {
        type = "object",
        properties = {
            location = {type = "string"}
        }
    },
    handler = function(args)
        -- Tool implementation
        return {temperature = 72, conditions = "sunny"}
    end
})

-- Create agent with tools
local agent = llm.create_agent(provider, {
    system_prompt = "You are a helpful assistant",
    tools = {"weather"}
})

-- Subscribe to events
llm.subscribe_events("tool.*", function(event)
    print("Tool event:", event.type, event.data)
end)

-- Run with structured output
local response = agent:run_structured({
    input = "What's the weather?",
    output_schema = {
        type = "object",
        properties = {
            summary = {type = "string"},
            temperature = {type = "number"}
        }
    }
})
```

## Phase 8: Event System and Observability (Week 15)

### 8.1 Event System
```zig
// src/events/types.zig - Serializable event system
pub const Event = struct {
    id: []const u8,
    type: EventType,
    timestamp: i64,
    data: std.json.Value,
    metadata: std.json.Value,
    
    pub fn toJSON(self: *const Event, allocator: std.mem.Allocator) ![]const u8 {
        // Serialize event to JSON
    }
};

pub const EventType = enum {
    agent_start,
    agent_complete,
    agent_error,
    tool_start,
    tool_complete,
    tool_error,
    provider_request,
    provider_response,
    state_change,
};

// src/events/emitter.zig
pub const EventEmitter = struct {
    subscribers: std.ArrayList(Subscriber),
    filters: std.StringHashMap(Filter),
    recorder: ?EventRecorder,
    
    pub const Subscriber = struct {
        pattern: []const u8,
        handler: fn (event: Event) void,
    };
    
    pub fn subscribe(self: *EventEmitter, pattern: []const u8, handler: fn (Event) void) !void {
        // Pattern-based subscription
    }
    
    pub fn emit(self: *EventEmitter, event: Event) !void {
        // Emit to matching subscribers
    }
};

// src/events/recorder.zig - Event persistence
pub const EventRecorder = struct {
    storage: EventStorage,
    
    pub fn record(self: *EventRecorder, event: Event) !void {
        // Store event for replay/debugging
    }
    
    pub fn replay(self: *EventRecorder, from: i64, to: i64, handler: fn (Event) void) !void {
        // Replay events in time range
    }
};
```

### 8.2 Structured Output Support
```zig
// src/outputs/parser.zig - Parse LLM outputs
pub const OutputParser = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        parse: fn (self: *OutputParser, response: []const u8, schema: Schema) anyerror!std.json.Value,
        parseWithRecovery: fn (self: *OutputParser, response: []const u8, schema: Schema) anyerror!std.json.Value,
    };
};

// src/outputs/json_parser.zig
pub const JSONParser = struct {
    strict: bool = false,
    
    pub fn parseWithRecovery(self: *JSONParser, response: []const u8, schema: Schema) !std.json.Value {
        // Try standard parsing
        if (self.parse(response, schema)) |result| {
            return result;
        } else |_| {
            // Extract from markdown blocks
            if (extractJSONFromMarkdown(response)) |json| {
                if (self.parse(json, schema)) |result| {
                    return result;
                } else |_| {}
            }
            
            // Fix common issues
            const fixed = try self.fixCommonIssues(response);
            if (self.parse(fixed, schema)) |result| {
                return result;
            } else |_| {}
            
            // Schema-guided extraction
            return self.extractWithSchema(response, schema);
        }
    }
};

// Registry of parsers
pub const parser_registry = struct {
    pub fn get(format: []const u8) ?OutputParser {
        // Return parser for format
    }
    
    pub fn register(format: []const u8, parser: OutputParser) void {
        // Register custom parser
    }
};
```

## Phase 9: Testing Infrastructure (Week 16)

### 9.1 Testing Utilities
```zig
// src/testing/scenario.zig - Declarative test scenarios
pub const Scenario = struct {
    name: []const u8,
    providers: std.StringHashMap(MockProvider),
    tools: std.StringHashMap(Tool),
    agents: std.StringHashMap(Agent),
    steps: []const TestStep,
    
    pub const TestStep = union(enum) {
        input: InputStep,
        expect_output: ExpectOutputStep,
        expect_tool_call: ExpectToolCallStep,
        expect_event: ExpectEventStep,
    };
    
    pub fn run(self: *Scenario, t: *std.testing.Test) !void {
        // Execute scenario
    }
};

pub const ScenarioBuilder = struct {
    scenario: Scenario,
    
    pub fn withMockProvider(self: *ScenarioBuilder, name: []const u8, responses: MockResponses) *ScenarioBuilder {
        // Add mock provider
    }
    
    pub fn withTool(self: *ScenarioBuilder, tool: Tool) *ScenarioBuilder {
        // Add tool
    }
    
    pub fn expectOutput(self: *ScenarioBuilder, matcher: Matcher) *ScenarioBuilder {
        // Add output expectation
    }
};

// src/testing/mocks.zig
pub const MockProvider = struct {
    responses: std.StringHashMap([]const u8),
    calls: std.ArrayList(ProviderCall),
    
    pub fn init(responses: MockResponses) MockProvider {
        // Initialize with canned responses
    }
};

// src/testing/matchers.zig
pub const Matcher = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        match: fn (self: *Matcher, value: std.json.Value) bool,
        describe: fn (self: *Matcher) []const u8,
    };
};

pub const matchers = struct {
    pub fn contains(substr: []const u8) Matcher {
        // String contains matcher
    }
    
    pub fn equals(expected: std.json.Value) Matcher {
        // Exact equality matcher
    }
    
    pub fn hasField(field: []const u8, value: std.json.Value) Matcher {
        // Field value matcher
    }
};
```

### 9.2 Documentation Generation
```zig
// src/docs/generator.zig - Auto-generate documentation
pub const DocumentationGenerator = struct {
    format: enum { markdown, openapi, json },
    
    pub fn generateForTool(self: *DocumentationGenerator, tool: ToolMetadata) ![]const u8 {
        return switch (self.format) {
            .markdown => try self.generateMarkdownForTool(tool),
            .openapi => try self.generateOpenAPIForTool(tool),
            .json => try self.generateJSONForTool(tool),
        };
    }
    
    pub fn generateOpenAPIForTool(self: *DocumentationGenerator, tool: ToolMetadata) ![]const u8 {
        // Generate OpenAPI 3.0 specification
    }
};

// All major types implement Documentable
pub const Documentable = struct {
    getName: fn (self: anytype) []const u8,
    getDescription: fn (self: anytype) []const u8,
    getExamples: fn (self: anytype) []const Example,
    getSchema: fn (self: anytype) ?Schema,
};
```

## Phase 10: Performance and Quality (Ongoing)

### 10.1 Testing Strategy
- Unit tests for each module with scenario-based testing
- Integration tests for provider implementations
- Mock providers for deterministic testing
- Benchmark suite for performance validation
- Event-driven test verification

### 10.2 Documentation
- Auto-generated API documentation
- Architecture guide with diagrams
- Tutorial for building custom providers
- Scripting integration guide with examples
- Bridge development guide

## Implementation Order and Priorities

### Immediate Actions (Week 1)
1. Set up build system with Makefile
2. Implement core types and interfaces with serialization
3. Create error handling system with recovery strategies
4. Set up schema repository implementations
5. Create testing framework with scenario support

### Short Term (Weeks 2-6)
1. OpenAI provider with metadata and discovery
2. Basic agent system with event emission
3. Tool registry with dynamic registration
4. Enhanced C-API with type conversions
5. Basic structured output parsing

### Medium Term (Weeks 7-12)
1. Additional providers (Anthropic, Ollama)
2. Workflow engine with serialization
3. Memory systems
4. Event system with recording
5. Testing infrastructure
6. Output parser with recovery

### Long Term (Weeks 13-16)
1. Complete Lua bindings with all features
2. Documentation generation system
3. Performance optimization
4. Advanced error recovery
5. Community tools and templates

### Priority Features for Downstream Compatibility
1. **High Priority** (Essential for bridges):
   - Schema repository implementations
   - Dynamic tool registration
   - Structured error handling
   - Type conversion registry
   - Event serialization

2. **Medium Priority** (Significant improvements):
   - Provider metadata and discovery
   - Workflow serialization
   - Output parsing with recovery
   - Testing scenario framework

3. **Lower Priority** (Nice to have):
   - Documentation generation
   - Event recording/replay
   - Advanced provider templates

## Project Structure Revisions

### Proposed New Structure
```
zig_llms/
├── build.zig
├── Makefile                    # Build automation
├── src/
│   ├── main.zig               # Library entry point
│   ├── types.zig              # Core type definitions
│   ├── error.zig              # Structured error handling
│   ├── provider.zig           # Provider interface
│   ├── providers/             # Provider implementations
│   │   ├── factory.zig
│   │   ├── registry.zig      # Dynamic provider registry
│   │   ├── metadata.zig      # Provider metadata types
│   │   ├── openai.zig
│   │   ├── anthropic.zig
│   │   └── ollama.zig
│   ├── agent.zig              # Core agent implementation
│   ├── state.zig              # State management
│   ├── context.zig            # Execution context
│   ├── tool.zig               # Tool interface
│   ├── tool_registry.zig      # Enhanced tool registry
│   ├── tools/                 # Built-in tools
│   │   ├── file.zig
│   │   ├── http.zig
│   │   ├── system.zig
│   │   └── json.zig
│   ├── workflow/              # Workflow system
│   │   ├── definition.zig    # Serializable workflows
│   │   ├── serialization.zig # Workflow serialization
│   │   ├── sequential.zig
│   │   ├── parallel.zig
│   │   ├── conditional.zig
│   │   ├── loop.zig
│   │   └── script_step.zig   # Script-based steps
│   ├── memory/
│   │   ├── short_term.zig
│   │   └── long_term.zig
│   ├── schema/                # Schema system
│   │   ├── repository.zig    # Schema storage
│   │   ├── validator.zig
│   │   ├── coercion.zig
│   │   └── generator.zig     # Schema generation
│   ├── events/                # Event system
│   │   ├── types.zig
│   │   ├── emitter.zig
│   │   ├── recorder.zig
│   │   └── filter.zig
│   ├── outputs/               # Output parsing
│   │   ├── parser.zig
│   │   ├── json_parser.zig
│   │   └── recovery.zig
│   ├── http/                  # HTTP utilities
│   │   ├── client.zig
│   │   └── pool.zig
│   ├── bindings/              # Language bindings
│   │   ├── capi.zig          # Enhanced C-API
│   │   ├── type_registry.zig # Type conversions
│   │   └── lua/              # Lua-specific code
│   ├── testing/               # Testing infrastructure
│   │   ├── scenario.zig
│   │   ├── mocks.zig
│   │   ├── matchers.zig
│   │   └── fixtures.zig
│   ├── docs/                  # Documentation generation
│   │   ├── generator.zig
│   │   └── templates.zig
│   └── util/                  # Utilities
│       ├── json.zig
│       ├── string.zig
│       ├── thread_pool.zig
│       └── types.zig         # Type conversion utilities
├── test/
│   ├── main.zig
│   ├── providers/             # Provider tests
│   ├── agents/                # Agent tests
│   ├── tools/                 # Tool tests
│   ├── workflows/             # Workflow tests
│   ├── events/                # Event system tests
│   ├── outputs/               # Output parsing tests
│   ├── bindings/              # Binding tests
│   └── integration/           # Integration tests
├── examples/
│   ├── basic_chat.zig         # Simple example
│   ├── tool_usage.zig         # Tool example
│   ├── multi_agent.zig        # Complex example
│   ├── workflow_demo.zig      # Workflow example
│   ├── event_monitoring.zig   # Event system example
│   ├── structured_output.zig  # Output parsing example
│   ├── c_api_demo.c           # C-API example
│   └── lua/                   # Lua examples
│       ├── basic.lua
│       ├── tools.lua
│       └── workflows.lua
└── docs/                      # Documentation
    ├── api/                   # API reference
    ├── guides/                # User guides
    │   ├── getting_started.md
    │   ├── providers.md
    │   ├── tools.md
    │   ├── workflows.md
    │   └── bridge_development.md
    └── architecture.md        # Architecture documentation
```

## Success Metrics

1. **Performance**: Match or exceed go-llms performance
2. **Memory Safety**: Zero memory leaks, predictable allocation
3. **API Simplicity**: Intuitive interfaces for common tasks
4. **Extensibility**: Easy to add new providers and tools
5. **Interoperability**: Smooth C-API and Lua integration
6. **Bridge-Friendliness**: Minimal boilerplate for language bridges
7. **Runtime Flexibility**: Dynamic tool and provider registration
8. **Observability**: Comprehensive event system with serialization
9. **Error Recovery**: Structured errors with recovery strategies
10. **Documentation**: Auto-generated, always up-to-date docs

## Risk Mitigation

1. **Complexity**: Start with minimal viable features
2. **Performance**: Profile early and often
3. **API Design**: Get feedback on interfaces before implementation
4. **Testing**: Maintain high test coverage from the start
5. **Documentation**: Document as you build

## Summary of Enhancements from Downstream Requirements

The implementation plan has been significantly enhanced based on downstream requirements analysis. Key additions include:

1. **Schema System**: Built-in repository implementations (in-memory and file-based) to avoid reimplementation in bridges
2. **Dynamic Registration**: Runtime tool and provider registration for extensibility
3. **Structured Errors**: Serializable errors with recovery strategies for better debugging
4. **Type Conversion**: Centralized registry for bridge-friendly type conversions
5. **Event System**: Comprehensive event emission with serialization and filtering
6. **Output Parsing**: Robust parsing with recovery mechanisms for unreliable LLM outputs
7. **Testing Infrastructure**: Scenario-based testing to reduce boilerplate
8. **Documentation Generation**: Auto-generated docs to keep documentation in sync
9. **Enhanced C-API**: Additional functions for tool registration, event subscription, and type conversion
10. **Workflow Serialization**: Support for declarative, persistable workflows

These enhancements transform zig_llms from a basic LLM framework into a truly extensible platform that minimizes the work required for language bridges and downstream integrations. The design prioritizes:

- **Zero-cost abstractions** that don't sacrifice performance
- **Bridge-first architecture** that makes integration trivial
- **Runtime flexibility** without compromising type safety
- **Comprehensive observability** for production use
- **Developer experience** through reduced boilerplate and better tooling

This plan provides a structured approach to building zig_llms while incorporating best practices from the reference projects, leveraging Zig's unique strengths, and addressing real-world integration challenges identified by downstream consumers.