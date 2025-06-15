# Scripting Engine Binding Interface Design

## Executive Summary

This document outlines the design for a generic scripting engine binding interface for zig_llms, enabling support for multiple scripting languages through a unified abstraction layer rather than language-specific implementations.

## Motivation

Instead of creating Lua-specific bindings (Task 19.1), we will create a generic **Scripting Engine Interface** that can support multiple languages including Lua, JavaScript (QuickJS), Wren, Python, and others. This approach provides:

- **Extensibility**: Easy addition of new scripting languages
- **Consistency**: Uniform API across all supported languages  
- **Maintainability**: Single abstraction instead of N implementations
- **User Choice**: Developers can choose their preferred scripting language
- **Future-proofing**: New engines can be added without architectural changes

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    zig_llms Core APIs                       │
│  ┌─────────┬─────────┬─────────┬─────────┬───────────────┐ │
│  │ Agents  │ Tools   │Workflows│ Events  │  Providers    │ │
│  ├─────────┼─────────┼─────────┼─────────┼───────────────┤ │
│  │ Testing │ Schema  │ Memory  │  Hooks  │Output Parsing │ │
│  └─────────┴─────────┴─────────┴─────────┴───────────────┘ │
├─────────────────────────────────────────────────────────────┤
│              API Bridge Generation Layer                    │
│         (Automatic binding for all zig_llms APIs)          │
├─────────────────────────────────────────────────────────────┤
│                Scripting Engine Interface                  │
│  ┌─────────────┬─────────────┬─────────────┬─────────────┐ │
│  │ Value Bridge│ Error Bridge│Context Mgmt │ Module Sys  │ │
│  └─────────────┴─────────────┴─────────────┴─────────────┘ │
├─────────────────────────────────────────────────────────────┤
│              Engine Registry & Discovery                   │
├─────────────────────────────────────────────────────────────┤
│           Engine-Specific Implementations                  │
│  ┌─────────┬──────────┬──────────┬─────────┬──────────────┐ │
│  │   Lua   │ QuickJS  │   Wren   │ Python  │   Future     │ │
│  │ Engine  │  Engine  │  Engine  │ Engine  │   Engines    │ │
│  └─────────┴──────────┴──────────┴─────────┴──────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                       C-API Layer                          │
└─────────────────────────────────────────────────────────────┘
```

## Design Principles

### 1. "Good Guest" Principle
Following embedded scripting best practices:
- **Minimal assumptions** about host environment (no filesystem, stdio, env vars)
- **Clean resource management** with proper initialization/cleanup
- **Thread safety** considerations for each engine
- **No host application crashes** from script errors

### 2. Engine Agnostic Interface
- **Unified API** regardless of underlying scripting language
- **Consistent error handling** across all engines
- **Standardized value conversion** between Zig and script types
- **Common context management** patterns

### 3. Performance Considerations
- **Lazy engine loading** - only load engines when needed
- **Context pooling** - reuse script contexts when possible
- **Minimal marshaling overhead** for value conversion
- **Native performance** for heavy computations in Zig

## Core Interface Design

### ScriptingEngine Interface

```zig
// Core scripting engine interface that all engines must implement
pub const ScriptingEngine = struct {
    const Self = @This();
    
    // Engine metadata
    name: []const u8,
    version: []const u8,
    supported_extensions: []const []const u8,
    
    // VTable for polymorphic operations
    vtable: *const VTable,
    
    pub const VTable = struct {
        // Lifecycle management
        init: *const fn (allocator: std.mem.Allocator, config: EngineConfig) anyerror!*Self,
        deinit: *const fn (self: *Self) void,
        
        // Context management
        createContext: *const fn (self: *Self, context_name: []const u8) anyerror!*ScriptContext,
        destroyContext: *const fn (self: *Self, context: *ScriptContext) void,
        
        // Script execution
        loadScript: *const fn (context: *ScriptContext, source: []const u8, name: []const u8) anyerror!void,
        executeFunction: *const fn (context: *ScriptContext, func_name: []const u8, args: []const ScriptValue) anyerror!ScriptValue,
        
        // Module system
        registerModule: *const fn (context: *ScriptContext, module: *const ScriptModule) anyerror!void,
        
        // Error handling
        getLastError: *const fn (context: *ScriptContext) ?ScriptError,
        clearErrors: *const fn (context: *ScriptContext) void,
    };
};
```

### Value Bridge System

```zig
// Universal value type for script<->zig conversion
pub const ScriptValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    array: []ScriptValue,
    object: std.StringHashMap(ScriptValue),
    function: ScriptFunction,
    userdata: *anyopaque,
    
    pub fn fromZig(comptime T: type, value: T, allocator: std.mem.Allocator) !ScriptValue { }
    pub fn toZig(self: ScriptValue, comptime T: type, allocator: std.mem.Allocator) !T { }
    pub fn deinit(self: *ScriptValue, allocator: std.mem.Allocator) void { }
};

// Function wrapper for script callbacks
pub const ScriptFunction = struct {
    context: *ScriptContext,
    function_ref: *anyopaque, // Engine-specific function reference
    
    pub fn call(self: *ScriptFunction, args: []const ScriptValue) !ScriptValue { }
};
```

### Error Bridge System

```zig
pub const ScriptError = struct {
    code: ScriptErrorCode,
    message: []const u8,
    source_location: ?SourceLocation,
    stack_trace: ?[]const u8,
    
    pub const ScriptErrorCode = enum {
        syntax_error,
        runtime_error,
        type_error,
        reference_error,
        memory_error,
        timeout_error,
        unknown_error,
    };
    
    pub const SourceLocation = struct {
        file: []const u8,
        line: u32,
        column: u32,
    };
};
```

### Context Management

```zig
pub const ScriptContext = struct {
    engine: *ScriptingEngine,
    engine_context: *anyopaque, // Engine-specific context
    allocator: std.mem.Allocator,
    name: []const u8,
    
    // Registered modules and functions
    modules: std.StringHashMap(*ScriptModule),
    global_functions: std.StringHashMap(ScriptFunction),
    
    // Error state
    last_error: ?ScriptError,
    
    // Security/safety settings
    execution_timeout_ms: u32,
    memory_limit_bytes: usize,
    allowed_modules: ?[]const []const u8,
};
```

## Target Engines Implementation Plan

### Phase 1: Core Infrastructure (Week 1)
- [ ] Design and implement ScriptingEngine interface
- [ ] Create Value Bridge system with conversion utilities
- [ ] Implement Error Bridge with stack trace support
- [ ] Build Engine Registry with dynamic discovery
- [ ] Add Context Management with pooling

### Phase 2: Lua Engine Implementation (Week 1-2)
- [ ] Implement Lua engine wrapper (`src/scripting/engines/lua.zig`)
- [ ] Value conversion between Lua and ScriptValue
- [ ] Error handling with Lua error messages and stack traces
- [ ] Module registration system for zig_llms APIs
- [ ] Context isolation and cleanup

**Rationale**: Lua is designed specifically for embedding with the simplest C API

### Phase 3: QuickJS Engine Implementation (Week 2)
- [ ] Implement QuickJS engine wrapper (`src/scripting/engines/quickjs.zig`)
- [ ] JavaScript object/array conversion to ScriptValue
- [ ] Promise and async function support
- [ ] ES6 module system integration
- [ ] JavaScript error handling with source maps

**Rationale**: Modern JavaScript support with excellent embedding characteristics

### Phase 4: Wren Engine Implementation (Week 2-3)
- [ ] Implement Wren engine wrapper (`src/scripting/engines/wren.zig`)
- [ ] Fiber-based concurrency integration
- [ ] Object-oriented value mapping
- [ ] Foreign method registration for zig_llms
- [ ] Garbage collection coordination

**Rationale**: Smallest footprint, designed for embedding, clean OOP syntax

### Phase 5: Python Engine Implementation (Week 3)
- [ ] Implement Python engine wrapper (`src/scripting/engines/python.zig`)
- [ ] CPython embedding with GIL management
- [ ] Dictionary/list conversion to ScriptValue
- [ ] Module import system integration
- [ ] Exception handling and traceback capture

**Rationale**: Widely known language, excellent for data science workflows

## Engine-Specific Considerations

### Lua Engine
- **Strengths**: Simple API, small footprint, designed for embedding
- **Threading**: Single-threaded, but multiple Lua states can run in parallel
- **Memory**: Manual memory management with custom allocators
- **Type System**: Dynamic typing with metatables
- **Module System**: `require()` with custom loaders

### QuickJS Engine  
- **Strengths**: Full ES2020 support, small size, fast startup
- **Threading**: Single-threaded with async/await support
- **Memory**: Garbage collected with reference counting
- **Type System**: JavaScript types with JSON serialization
- **Module System**: ES6 modules with import/export

### Wren Engine
- **Strengths**: Minimal size (~4000 lines), fiber concurrency, clean syntax
- **Threading**: Fiber-based cooperative multitasking
- **Memory**: Tracing garbage collector
- **Type System**: Object-oriented with classes and methods
- **Module System**: Import system with foreign methods

### Python Engine
- **Strengths**: Familiar syntax, extensive ecosystem
- **Threading**: Global Interpreter Lock (GIL) limitations
- **Memory**: Reference counting + cycle detection
- **Type System**: Dynamic typing with introspection
- **Module System**: Import system with C extensions

## Comprehensive zig_llms API Exposure

### API Bridge Generation System

The scripting engine provides automatic binding generation for ALL zig_llms APIs. Scripts have full access to the AI framework without implementing any AI logic themselves - they simply orchestrate and extend the existing zig_llms functionality.

```zig
// Automatic API bridge generation
pub const APIBridge = struct {
    pub fn generateBindings(engine: *ScriptingEngine, allocator: std.mem.Allocator) !void {
        try engine.registerModule("zigllms.agent", AgentBridge.getModule());
        try engine.registerModule("zigllms.tool", ToolBridge.getModule());
        try engine.registerModule("zigllms.workflow", WorkflowBridge.getModule());
        try engine.registerModule("zigllms.provider", ProviderBridge.getModule());
        try engine.registerModule("zigllms.event", EventBridge.getModule());
        try engine.registerModule("zigllms.test", TestBridge.getModule());
        try engine.registerModule("zigllms.schema", SchemaBridge.getModule());
        try engine.registerModule("zigllms.memory", MemoryBridge.getModule());
        try engine.registerModule("zigllms.hook", HookBridge.getModule());
        try engine.registerModule("zigllms.output", OutputParserBridge.getModule());
    }
};
```

### Complete API Surface Available to Scripts

#### 1. Agent API
```lua
-- Lua: Full agent lifecycle management
local agent = zigllms.agent.create({
    name = "research_agent",
    provider = "openai",
    model = "gpt-4",
    temperature = 0.7,
    max_tokens = 2000,
    memory_config = {
        type = "short_term",
        max_messages = 100
    },
    tools = {"file_reader", "web_search", "calculator"}
})

-- Configure agent with hooks
agent:addHook("pre_execution", function(context)
    print("About to execute: " .. context.input)
end)

-- Run agent with structured input/output
local result = agent:run({
    message = "Research the latest AI developments",
    context = {
        sources = {"arxiv", "papers_with_code"},
        format = "markdown"
    }
})

-- Access conversation history
local history = agent:getMemory():getHistory()

-- Clone agent with different config
local fast_agent = agent:clone({temperature = 0.2})
```

#### 2. Tool API
```javascript
// JavaScript: Define and register custom tools
zigllms.tool.register({
    name: "database_query",
    description: "Query a SQL database",
    schema: {
        type: "object",
        properties: {
            query: { type: "string", description: "SQL query" },
            database: { type: "string", enum: ["users", "products", "orders"] }
        },
        required: ["query", "database"]
    },
    execute: async (input) => {
        // Tool implementation
        const result = await queryDatabase(input.database, input.query);
        return { rows: result, count: result.length };
    }
});

// Use built-in tools
const fileContent = await zigllms.tool.execute("file_reader", {
    path: "./data.json"
});

// List available tools
const tools = zigllms.tool.list();
tools.forEach(tool => {
    console.log(`${tool.name}: ${tool.description}`);
});
```

#### 3. Workflow API  
```python
# Python: Build complex multi-step workflows
workflow = zigllms.workflow.create("research_pipeline")

# Add workflow steps
workflow.add_step("gather_sources", {
    "agent": "research_agent",
    "action": "search",
    "params": {
        "query": "{{input.topic}}",
        "sources": ["google_scholar", "arxiv"]
    }
})

workflow.add_step("analyze_papers", {
    "agent": "analysis_agent", 
    "action": "analyze",
    "params": {
        "papers": "{{gather_sources.output}}",
        "criteria": ["novelty", "impact", "methodology"]
    },
    "depends_on": ["gather_sources"]
})

workflow.add_step("generate_report", {
    "agent": "writer_agent",
    "action": "write",
    "params": {
        "analysis": "{{analyze_papers.output}}",
        "format": "academic_report"
    },
    "depends_on": ["analyze_papers"]
})

# Execute workflow
result = workflow.execute({
    "topic": "Transformer architectures in computer vision"
})

# Access step results
for step_name, step_result in result.steps.items():
    print(f"{step_name}: {step_result.status}")
```

#### 4. Provider API
```lua
-- Lua: Direct provider access and configuration
local providers = zigllms.provider.list()

-- Configure a new provider
zigllms.provider.register({
    name = "custom_ollama",
    type = "ollama",
    config = {
        base_url = "http://localhost:11434",
        models = {"llama2", "mistral"},
        timeout = 30000
    }
})

-- Get provider capabilities
local capabilities = zigllms.provider.getCapabilities("openai")
print("Supports streaming: " .. tostring(capabilities.streaming))
print("Max context: " .. capabilities.max_context_tokens)

-- Direct provider calls (bypassing agents)
local response = zigllms.provider.complete("openai", {
    model = "gpt-3.5-turbo",
    messages = {{role = "user", content = "Hello"}}
})
```

#### 5. Event System API
```javascript
// JavaScript: Full event system access
const emitter = zigllms.event.createEmitter();

// Subscribe to agent events
emitter.on("agent.execution.start", (event) => {
    console.log(`Agent ${event.agentName} starting execution`);
});

emitter.on("agent.execution.complete", (event) => {
    console.log(`Agent completed in ${event.duration}ms`);
    console.log(`Tokens used: ${event.usage.total_tokens}`);
});

// Subscribe to tool events
emitter.on("tool.execution.*", (event) => {
    logToolUsage(event);
});

// Custom events
emitter.emit("custom.milestone", {
    workflow: "research_pipeline",
    progress: 0.75
});

// Event filtering and transformation
emitter.filter("agent.*", event => event.agentName === "research_agent")
       .map(event => ({ timestamp: Date.now(), ...event }))
       .subscribe(logEvent);
```

#### 6. Testing Framework API
```python
# Python: Access testing framework
test_scenario = zigllms.test.createScenario("tool_validation")

# Add test fixtures
test_scenario.addFixture("sample_data", {
    "users": [
        {"id": 1, "name": "Alice"},
        {"id": 2, "name": "Bob"}
    ]
})

# Define test case
test_scenario.addTest("database_tool_test", async def():
    result = await zigllms.tool.execute("database_query", {
        "query": "SELECT * FROM users",
        "database": "users"
    })
    
    assert result["count"] == 2
    assert result["rows"][0]["name"] == "Alice"
)

# Run tests
results = test_scenario.run()
print(f"Passed: {results.passed}/{results.total}")
```

#### 7. Schema & Validation API
```lua
-- Lua: Schema definition and validation
local user_schema = zigllms.schema.define({
    name = "UserProfile",
    type = "object",
    properties = {
        id = {type = "integer"},
        name = {type = "string", minLength = 1},
        email = {type = "string", format = "email"},
        preferences = {
            type = "object",
            properties = {
                theme = {type = "string", enum = {"light", "dark"}},
                notifications = {type = "boolean"}
            }
        }
    },
    required = {"id", "name", "email"}
})

-- Validate data
local is_valid, errors = zigllms.schema.validate(user_schema, user_data)
if not is_valid then
    for _, error in ipairs(errors) do
        print("Validation error: " .. error.message)
    end
end

-- Use with structured output parsing
local parser = zigllms.output.createParser({
    schema = user_schema,
    format = "json"
})
```

#### 8. Memory Management API
```javascript
// JavaScript: Memory system access
const memory = zigllms.memory.create({
    type: "short_term",
    capacity: 1000,
    ttl: 3600000 // 1 hour
});

// Store conversation context
memory.add({
    role: "user",
    content: "Remember that my name is John",
    metadata: { important: true }
});

// Search memory
const relevant = memory.search("name", { limit: 5 });

// Create memory snapshots
const snapshot = memory.snapshot();
zigllms.memory.saveSnapshot("conversation_123", snapshot);

// Memory statistics
const stats = memory.getStats();
console.log(`Messages: ${stats.messageCount}, Tokens: ${stats.tokenCount}`);
```

#### 9. Hook System API
```python
# Python: Hook system for extensibility
# Register global hooks
zigllms.hook.register("provider.request.pre", async def(context):
    # Add auth headers
    context.headers["X-Custom-Auth"] = get_auth_token()
    
    # Log all API calls
    logger.info(f"API call to {context.provider}: {context.endpoint}")
    
    return context  # Modified context
)

zigllms.hook.register("agent.response.post", async def(response):
    # Post-process all agent responses
    if "confidential" in response.content.lower():
        response.content = "[REDACTED]"
    
    # Add metadata
    response.metadata["processed_at"] = datetime.now()
    
    return response
)

# Hook priorities and conditions
zigllms.hook.register("tool.execution.pre", 
    handler=validate_tool_input,
    priority=100,  # Higher priority runs first
    condition=lambda ctx: ctx.tool_name in ["database_query", "file_writer"]
)
```

#### 10. Output Parsing API
```lua
-- Lua: Structured output parsing
local parser = zigllms.output.createParser({
    format = "json",
    schema = {
        type = "object",
        properties = {
            summary = {type = "string"},
            key_points = {
                type = "array",
                items = {type = "string"}
            },
            sentiment = {
                type = "string",
                enum = {"positive", "negative", "neutral"}
            }
        }
    }
})

-- Parse agent output
local structured = parser:parse(agent_response)
print("Summary: " .. structured.summary)
print("Sentiment: " .. structured.sentiment)

-- Chain parsers
local markdown_parser = zigllms.output.createParser({format = "markdown"})
local sections = markdown_parser:extractSections(agent_response)
```

### Type Marshaling System

The scripting engine automatically handles complex type conversions:

```zig
// Automatic type marshaling for complex structures
pub const TypeMarshaler = struct {
    pub fn marshalAgentConfig(script_value: ScriptValue) !agent.AgentConfig {
        // Converts script objects to Zig structs
    }
    
    pub fn marshalToolDefinition(script_value: ScriptValue) !tool.ToolDefinition {
        // Handles function references and schemas
    }
    
    pub fn marshalWorkflowStep(script_value: ScriptValue) !workflow.WorkflowStep {
        // Converts workflow definitions
    }
    
    pub fn unmarshalResponse(response: provider.Response) !ScriptValue {
        // Converts Zig responses to script values
    }
};
```

### Callback and Async Support

Different engines handle async operations differently:

```lua
-- Lua: Callback-based async
zigllms.agent.runAsync(agent, input, function(result, error)
    if error then
        print("Error: " .. error.message)
    else
        print("Result: " .. result.content)
    end
end)
```

```javascript
// JavaScript: Promise-based async
try {
    const result = await zigllms.agent.run(agent, input);
    console.log(result.content);
} catch (error) {
    console.error("Error:", error);
}
```

```python
# Python: Both async/await and callback styles
# Async/await style
async def process():
    result = await zigllms.agent.run_async(agent, input)
    return result

# Callback style
def on_complete(result, error):
    if error:
        print(f"Error: {error}")
    else:
        print(f"Result: {result}")

zigllms.agent.run_async(agent, input, callback=on_complete)
```

## Security and Safety

### Sandboxing Strategy
- **Resource limits**: Memory, execution time, file access
- **API restrictions**: Whitelist allowed modules and functions
- **Context isolation**: Scripts cannot access other contexts
- **Safe defaults**: Minimal permissions by default

### Error Isolation
- **Engine crashes**: Isolated to specific contexts, not entire application
- **Memory leaks**: Context-specific cleanup prevents global leaks  
- **Stack overflows**: Engine-specific stack limits and detection
- **Infinite loops**: Execution timeouts and interrupt handling

## File Structure

```
src/scripting/
├── interface.zig           # Core ScriptingEngine interface
├── value_bridge.zig        # ScriptValue and conversion utilities
├── error_bridge.zig        # ScriptError and error handling
├── context.zig            # ScriptContext management
├── registry.zig           # Engine discovery and registration
├── module_system.zig      # zig_llms API module generation
├── type_marshaler.zig     # Complex type conversion system
├── security.zig           # Sandboxing and safety features
├── api_bridges/           # API bridge implementations
│   ├── agent_bridge.zig   # Agent API exposure
│   ├── tool_bridge.zig    # Tool API exposure
│   ├── workflow_bridge.zig # Workflow API exposure
│   ├── provider_bridge.zig # Provider API exposure
│   ├── event_bridge.zig   # Event system exposure
│   ├── test_bridge.zig    # Testing framework exposure
│   ├── schema_bridge.zig  # Schema/validation exposure
│   ├── memory_bridge.zig  # Memory system exposure
│   ├── hook_bridge.zig    # Hook system exposure
│   └── output_bridge.zig  # Output parsing exposure
├── engines/
│   ├── lua.zig            # Lua engine implementation
│   ├── quickjs.zig        # QuickJS engine implementation  
│   ├── wren.zig           # Wren engine implementation
│   └── python.zig         # Python engine implementation
├── bindings/
│   ├── lua_bindings.zig   # Lua-specific C-API bindings
│   ├── js_bindings.zig    # JavaScript-specific bindings
│   ├── wren_bindings.zig  # Wren-specific bindings
│   └── python_bindings.zig # Python-specific bindings
└── examples/
    ├── lua/
    │   ├── basic_agent.lua
    │   ├── custom_tools.lua
    │   ├── workflow.lua
    │   └── event_handling.lua
    ├── javascript/
    │   ├── async_agent.js
    │   ├── tool_chaining.js
    │   ├── complex_workflow.js
    │   └── testing.js
    ├── wren/
    │   ├── oop_agent.wren
    │   ├── fiber_workflow.wren
    │   └── tool_factory.wren
    └── python/
        ├── data_pipeline.py
        ├── multi_agent.py
        ├── tool_ecosystem.py
        └── test_suite.py
```

## Testing Strategy

### Engine-Agnostic Tests
- [ ] Value conversion round-trip tests for all types
- [ ] Error handling and propagation tests
- [ ] Context isolation and cleanup tests
- [ ] Resource limit enforcement tests
- [ ] API exposure completeness tests

### Engine-Specific Tests  
- [ ] Language-specific syntax and idiom tests
- [ ] Performance benchmarks for each engine
- [ ] Memory usage and leak detection tests
- [ ] Concurrency and threading model tests
- [ ] Integration tests with real zig_llms workflows

### Cross-Engine Compatibility Tests
- [ ] Same script logic implemented in all supported languages
- [ ] Result consistency across engines
- [ ] Error handling consistency
- [ ] Performance comparison benchmarks

## Implementation Phases

### Phase 1: Core Infrastructure & API Bridges (Week 1)
- [ ] Core ScriptingEngine interface (`interface.zig`)
- [ ] Value Bridge system (`value_bridge.zig`)
- [ ] Type Marshaler for complex conversions (`type_marshaler.zig`)
- [ ] API Bridge generation system (`module_system.zig`)
- [ ] Implement all 10 API bridges:
  - [ ] Agent Bridge - Full agent lifecycle and configuration
  - [ ] Tool Bridge - Tool registration and execution from scripts
  - [ ] Workflow Bridge - Workflow building and execution
  - [ ] Provider Bridge - Direct provider access and configuration
  - [ ] Event Bridge - Event subscription and emission
  - [ ] Test Bridge - Testing framework access
  - [ ] Schema Bridge - Schema definition and validation
  - [ ] Memory Bridge - Memory management and history
  - [ ] Hook Bridge - Hook registration and lifecycle
  - [ ] Output Bridge - Structured output parsing

### Phase 2: Lua Engine Implementation (Week 1-2)
- [ ] Lua engine wrapper with full API exposure
- [ ] Lua-specific type conversions
- [ ] Callback-based async support
- [ ] Complete example suite demonstrating all APIs

### Phase 3: QuickJS Engine Implementation (Week 2)
- [ ] QuickJS engine wrapper with Promise support
- [ ] JavaScript object/array conversions
- [ ] Async/await integration
- [ ] ES6 module system support

### Phase 4: Additional Engines (Week 3)
- [ ] Wren engine with fiber support
- [ ] Python engine with GIL management
- [ ] Cross-engine compatibility testing

### Phase 5: Testing & Documentation (Week 4)
- [ ] Comprehensive test suite for all API bridges
- [ ] Performance benchmarks
- [ ] Complete documentation with examples
- [ ] Migration guide from direct API usage

## Implementation Timeline

**Week 1**: Core infrastructure, API bridges, and Lua engine  
**Week 2**: QuickJS engine and async improvements  
**Week 3**: Wren and Python engines  
**Week 4**: Testing, documentation, and examples  

## Future Extensions

### Additional Engines
- **mruby**: Lightweight Ruby implementation
- **ChaiScript**: C++ scripting language
- **Duktape**: Alternative JavaScript engine
- **AngelScript**: C-like scripting language

### Advanced Features
- **Hot reloading**: Script modification without restart
- **Debugging support**: Breakpoints and step execution
- **Profiling integration**: Performance analysis
- **JIT compilation**: Where supported by engines

## Conclusion

This design provides a robust, extensible foundation for multi-language scripting support in zig_llms. By abstracting the common patterns and providing engine-specific implementations, we can support developer choice while maintaining consistency and performance.

The modular architecture allows for incremental implementation, starting with the most embedding-friendly engines (Lua, QuickJS) and expanding to broader language support over time.