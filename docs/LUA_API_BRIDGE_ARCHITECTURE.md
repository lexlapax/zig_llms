# Lua API Bridge Architecture

## Overview

The Lua API Bridge provides comprehensive access to all zig_llms functionality from Lua scripts. This document describes the architecture, implementation details, and usage patterns for the bridge system.

## Architecture Components

### 1. Core Infrastructure

#### LuaAPIBridge (`src/scripting/engines/lua_api_bridge.zig`)
The central coordinator that manages all bridge registrations and provides common utilities:

```zig
pub const LuaAPIBridge = struct {
    allocator: std.mem.Allocator,
    registered_bridges: std.StringHashMap(BridgeInfo),
    optimization_config: OptimizationConfig,
    metrics: BridgeMetrics,
    
    pub fn registerAllBridges(self: *Self, wrapper: *LuaWrapper, context: *ScriptContext) !void
};
```

Key features:
- Manages registration of all 10 API bridges
- Provides centralized error handling
- Integrates with optimization systems (batching, memoization, stack pre-sizing)
- Collects performance metrics across all bridges

### 2. Individual API Bridges

Each bridge exposes a specific zig_llms API to Lua:

1. **Agent Bridge** (`lua_bridges/agent_bridge.zig`)
   - Functions: create, destroy, run, configure, get_state, get_info, list, reset
   - Constants: State.IDLE, State.READY, State.RUNNING, State.COMPLETED, State.ERROR

2. **Tool Bridge** (`lua_bridges/tool_bridge.zig`)
   - Functions: register, unregister, execute, discover, list, get, exists, validate, get_schema, get_info
   - Constants: ExecutionMode.DIRECT/SANDBOXED/ASYNC, Category.FILE/HTTP/SYSTEM/DATA

3. **Workflow Bridge** (`lua_bridges/workflow_bridge.zig`)
   - Functions: create, execute, pause, resume, cancel, get_status, get_result, list, get, compose, validate, get_dependencies
   - Constants: Status.PENDING/RUNNING/PAUSED/COMPLETED/FAILED, Pattern.SEQUENTIAL/PARALLEL/CONDITIONAL/LOOP

4. **Provider Bridge** (`lua_bridges/provider_bridge.zig`)
   - Functions: chat, configure, list, get, create, destroy, stream, get_models
   - Constants: Type.OPENAI/ANTHROPIC/COHERE/LOCAL, Status.ACTIVE/INACTIVE/ERROR/INITIALIZING

5. **Event Bridge** (`lua_bridges/event_bridge.zig`)
   - Functions: emit, subscribe, unsubscribe, list_subscriptions, filter, record, replay, clear
   - Constants: Type.SYSTEM/USER/AGENT/TOOL/WORKFLOW, Priority.LOW/NORMAL/HIGH/CRITICAL

6. **Test Bridge** (`lua_bridges/test_bridge.zig`)
   - Functions: create_scenario, run_scenario, assert_equals, assert_contains, create_mock, setup_fixture, run_suite, get_coverage
   - Constants: AssertType.EQUALS/CONTAINS/MATCHES/THROWS, MockType.FUNCTION/OBJECT/SERVICE

7. **Schema Bridge** (`lua_bridges/schema_bridge.zig`)
   - Functions: validate, generate, coerce, extract, merge, create, compile, get_info
   - Constants: Type.OBJECT/ARRAY/STRING/NUMBER/BOOLEAN/NULL, Format.EMAIL/URI/DATE/UUID

8. **Memory Bridge** (`lua_bridges/memory_bridge.zig`)
   - Functions: store, retrieve, delete, list_keys, clear, get_stats, persist, load
   - Constants: Type.SHORT_TERM/LONG_TERM/PERSISTENT, Scope.GLOBAL/AGENT/SESSION

9. **Hook Bridge** (`lua_bridges/hook_bridge.zig`)
   - Functions: register, unregister, execute, list, enable, disable, get_info, compose
   - Constants: Type.PRE/POST/AROUND/ERROR, Priority.HIGHEST/HIGH/NORMAL/LOW/LOWEST

10. **Output Bridge** (`lua_bridges/output_bridge.zig`)
    - Functions: parse, format, detect_format, validate_format, extract_json, extract_markdown, recover, get_schema
    - Constants: Format.JSON/YAML/XML/MARKDOWN/PLAIN, Recovery.STRICT/LENIENT/BEST_EFFORT

### 3. Optimization Systems

#### Batch Optimizer (`lua_batch_optimizer.zig`)
Optimizes multiple API calls by batching and memoization:

```zig
pub const LuaBatchOptimizer = struct {
    config: BatchConfig,
    current_batch: std.ArrayList(BatchedCall),
    cache: std.HashMap(u64, CacheEntry, ...),
    metrics: ProfileMetrics,
    
    pub fn addCall(...) !u64
    pub fn flushBatch() !void
};
```

Features:
- Configurable batch size and timeout
- Call prioritization (low, normal, high, critical)
- Function memoization with TTL-based cache
- LRU/LFU/FIFO eviction policies
- Performance profiling and metrics

#### Stack Optimizer (`lua_stack_optimizer.zig`)
Intelligently pre-sizes the Lua stack based on function signatures:

```zig
pub const LuaStackOptimizer = struct {
    function_signatures: std.StringHashMap(FunctionSignature),
    learned_patterns: std.StringHashMap(StackUsagePattern),
    stats: StackStats,
    
    pub fn presizeStack(...) StackOptimizationError!usize
};
```

Features:
- Function signature database
- Adaptive learning from actual usage
- Stack usage prediction
- Performance statistics tracking

## Usage Patterns

### Basic Usage from Lua

```lua
-- Agent example
local agent_id = zigllms.agent.create({
    name = "my_agent",
    provider = "openai",
    model = "gpt-4",
    temperature = 0.7
})

local response = zigllms.agent.run(agent_id, "Hello, world!")
zigllms.agent.destroy(agent_id)

-- Tool example
local tool_id = zigllms.tool.register({
    name = "calculator",
    description = "Perform calculations",
    parameters = {
        type = "object",
        properties = {
            expression = { type = "string" }
        }
    }
})

local result = zigllms.tool.execute(tool_id, {expression = "2 + 2"})
```

### Error Handling

All bridge functions use consistent error handling:

```lua
local success, result = pcall(function()
    return zigllms.agent.get_state("invalid_agent_id")
end)

if not success then
    print("Error:", result)
end
```

### Constants Usage

```lua
-- Using workflow patterns
local workflow_id = zigllms.workflow.create({
    name = "my_workflow",
    pattern = zigllms.workflow.Pattern.SEQUENTIAL,
    steps = {...}
})

-- Using event priorities
zigllms.event.emit("critical_event", {
    priority = zigllms.event.Priority.CRITICAL,
    data = {...}
})
```

## Performance Considerations

### Batching
The batch optimizer automatically groups multiple API calls:

```lua
-- These calls may be batched together
for i = 1, 10 do
    zigllms.memory.store("key_" .. i, "value_" .. i)
end
```

### Memoization
Frequently called functions with the same arguments are cached:

```lua
-- Second call may return cached result
local info1 = zigllms.agent.get_info(agent_id)
local info2 = zigllms.agent.get_info(agent_id)  -- Potentially cached
```

### Stack Pre-sizing
The stack optimizer learns from usage patterns:

```lua
-- Stack is automatically pre-sized based on historical usage
local result = zigllms.workflow.execute(workflow_id, complex_params)
```

## Integration Example

A comprehensive example showing multiple bridges working together:

```lua
-- Create an agent
local agent_id = zigllms.agent.create({
    name = "workflow_agent",
    provider = "openai"
})

-- Register a tool
local tool_id = zigllms.tool.register({
    name = "data_processor",
    execute = function(input)
        return zigllms.output.parse(input.data, zigllms.output.Format.JSON)
    end
})

-- Create a workflow using the agent and tool
local workflow_id = zigllms.workflow.create({
    pattern = zigllms.workflow.Pattern.SEQUENTIAL,
    steps = {
        {
            type = "agent_call",
            agent = agent_id,
            input = "Process this data"
        },
        {
            type = "tool_call", 
            tool = tool_id,
            input = {data = "{{previous.output}}"}
        }
    }
})

-- Subscribe to workflow events
local subscription_id = zigllms.event.subscribe("workflow.*", function(event)
    print("Workflow event:", event.type, event.data)
end)

-- Execute with hooks
zigllms.hook.register("workflow_complete", function(context)
    zigllms.memory.store("last_workflow_result", context.result)
end)

local result = zigllms.workflow.execute(workflow_id)
```

## Implementation Notes

1. **Thread Safety**: All bridges use proper mutex synchronization where needed
2. **Memory Management**: Careful ScriptValue conversion with proper cleanup
3. **Error Propagation**: Lua errors are converted to Zig errors and vice versa
4. **Performance**: Optimization systems are transparent to the user
5. **Extensibility**: New bridges can be added following the established pattern

## Future Enhancements

1. **Streaming Support**: Enhanced streaming capabilities for long-running operations
2. **Async/Await**: Integration with Lua coroutines for async operations
3. **Custom Bridges**: Support for user-defined bridges
4. **Performance Tuning**: More aggressive optimization strategies
5. **Debugging Tools**: Enhanced debugging and profiling capabilities