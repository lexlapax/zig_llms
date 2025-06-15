# TODO List for zig_llms

## Phase 1: Foundation (Weeks 1-2) - COMPLETED (See TODO-DONE.md)

## Phase 2: Provider Implementation (Weeks 3-4) - COMPLETED (See TODO-DONE.md)

## Phase 3: Agent System (Weeks 5-6)

### 6. Core Agent Implementation - COMPLETED (See TODO-DONE.md)

### 7. Agent Features - FUTURE
   7.1. [ ] Add prompt management in prompt.zig
   7.2. [ ] Implement conversation tracking
   7.3. [ ] Create agent factory pattern

## Phase 4: Tool System (Weeks 7-8) - COMPLETED (See TODO-DONE.md)

### 9. Built-in Tools
   9.1. [ ] Create tools/file.zig for file operations
   9.2. [ ] Create tools/http.zig for HTTP requests
   9.3. [ ] Create tools/system.zig for system information
   9.4. [ ] Create tools/data.zig for json/csv/yaml/xml data manipulation
   9.5. [ ] Create tools/process.zig for process execution
   9.6. [ ] Create tools/math.zig for match calculation operations
   9.7. [ ] Create tools/feed.zig for RSS, Atom, JSON Feed formats
   9.8. [ ] Ability to wrap agents/workflows as tools

## Phase 5: Workflow Engine (Weeks 9-10) - COMPLETED (See TODO-DONE.md)

## Phase 6: Comprehensive Hook System

### Design Goals:
   - Hooks should be implemented at the BaseAgent level to automatically work with workflows
   - Support multiple hook types (metrics, logging, tracing, validation, etc.)
   - Allow dynamic hook registration and configuration
   - Enable hook composition and chaining
   - Provide built-in, ready-to-use hook implementations

### 12. Hook Infrastructure - COMPLETED
   12.1. [x] Create hooks/types.zig with base hook interfaces - Completed 2025-06-15
   12.2. [x] Implement hooks/registry.zig for hook management - Completed 2025-06-15
   12.3. [x] Create hooks/context.zig for hook execution context - Completed 2025-06-15
   12.4. [x] Add hook points to BaseAgent for automatic workflow support - Completed 2025-06-15

### 13. Built-in Hook Types
   13.1. [ ] Implement hooks/metrics.zig for performance metrics collection
   13.2. [ ] Create hooks/logging.zig for structured logging hooks
   13.3. [ ] Add hooks/tracing.zig for distributed tracing support
   13.4. [ ] Create hooks/validation.zig for input/output validation
   13.5. [ ] Implement hooks/caching.zig for result caching
   13.6. [ ] Add hooks/rate_limiting.zig for API rate limiting

### 14. Hook Integration
   14.1. [x] Integrate hooks with agent lifecycle (init, before, after, cleanup) - Completed 2025-06-15
   14.2. [x] Add hook configuration to AgentConfig and WorkflowConfig - Completed 2025-06-15
   14.3. [x] Create hook composition for chaining multiple hooks - Completed 2025-06-15
   14.4. [ ] Implement async hook execution support
   14.5. [x] Add hook priority and ordering system - Completed 2025-06-15

### 15. Hook Utilities
   15.1. [ ] Create hooks/builders.zig for fluent hook construction
   15.2. [ ] Add hooks/filters.zig for conditional hook execution
   15.3. [ ] Implement hooks/middleware.zig for hook middleware pattern
   15.4. [ ] Create hooks/adapters.zig for external hook integration

### Example Usage:
```zig
// Metrics hook automatically tracks execution time, token usage, etc.
const metrics_hook = try MetricsHook.init(allocator, .{
    .track_latency = true,
    .track_tokens = true,
    .export_interval_ms = 1000,
});

// Logging hook provides structured logging at each lifecycle point
const logging_hook = try LoggingHook.init(allocator, .{
    .level = .info,
    .include_inputs = true,
    .include_outputs = false,
});

// Add hooks to agent config - works for both agents and workflows
var agent_config = AgentConfig{
    .hooks = &[_]Hook{ metrics_hook, logging_hook },
};

// Hooks automatically execute at lifecycle points (init, beforeRun, afterRun, etc.)
```

## Phase 7: Memory Systems (Weeks 11-12) - PARTIALLY COMPLETE

### 16. Short-term Memory - COMPLETED (See TODO-DONE.md)

### 17. Long-term Memory (Future)
   17.1. [ ] Design vector store interface - REVISIT
   17.2. [ ] Add embedding generation support - REVISIT
   17.3. [ ] Implement similarity search - REVISIT

## Phase 8: C-API and Bindings (Weeks 13-14)

### 18. C-API Implementation
   18.1. [ ] Create C-API functions in bindings/capi.zig
   18.2. [ ] Add memory management for C interface
   18.3. [ ] Implement structured error handling for C-API
   18.4. [ ] Create C header file generation
   18.5. [ ] Add tool registration from external languages
   18.6. [ ] Implement event subscription for C clients
   18.7. [ ] Add type conversion helpers (to/from JSON)

### 19. Language Bindings
   19.1. [ ] Design Lua binding interface
   19.2. [ ] Create example Lua scripts
   19.3. [ ] Add binding documentation

## Phase 9: Event System and Output Parsing (Week 15) - COMPLETED

### 20. Event System - COMPLETED (See TODO-DONE.md)

### 21. Output Parsing - COMPLETED (See TODO-DONE.md)

## Phase 10: Documentation and Examples

### 22. Documentation
   22.1. [ ] Implement docs/generator.zig for auto-generation
   22.2. [ ] Create docs/templates.zig for output formats
   22.3. [ ] Generate API reference documentation
   22.4. [ ] Write architecture guide
   22.5. [ ] Create user tutorials
   22.6. [ ] Add inline code documentation
   22.7. [ ] Create bridge development guide

### 23. Examples
   23.1. [ ] Create examples/basic_chat.zig
   23.2. [ ] Update examples/basic_tool_usage.zig
   23.3. [ ] Create examples/multi_agent.zig
   23.4. [ ] Create examples/workflow_demo.zig
   23.5. [ ] Create examples/event_monitoring.zig
   23.6. [ ] Create examples/structured_output.zig
   23.7. [ ] Create examples/c_api_demo.c
   23.8. [ ] Create examples/lua/basic.lua
   23.9. [ ] Create examples/lua/tools.lua
   23.10. [ ] Create examples/lua/workflows.lua

## Ongoing Tasks

### 24. Quality Assurance
   24.1. [ ] Maintain test coverage above 80%
   24.2. [ ] Run performance benchmarks
   24.3. [ ] Memory leak detection
   24.4. [ ] Code review and refactoring
   24.5. [ ] Test scenario coverage for all features
   24.6. [ ] Bridge integration testing

### 25. Community
   25.1. [ ] Set up issue templates
   25.2. [ ] Create contribution guidelines
   25.3. [ ] Add code of conduct
   25.4. [ ] Release planning
   25.5. [ ] Create bridge developer community resources