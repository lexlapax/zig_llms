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

## Phase 5: Workflow Engine (Weeks 9-10) - COMPLETED (See TODO-DONE.md)

### 10. Workflow Patterns - COMPLETED (See TODO-DONE.md)

### 11. Workflow Features
   11.1. [ ] Add workflow composition
   11.2. [ ] Implement error handling in workflows
   11.3. [ ] Add workflow state management

## Phase 6: Memory Systems (Weeks 11-12) - PARTIALLY COMPLETE

### 12. Short-term Memory - COMPLETED (See TODO-DONE.md)

### 13. Long-term Memory (Future)
   13.1. [ ] Design vector store interface - REVISIT
   13.2. [ ] Add embedding generation support - REVISIT
   13.3. [ ] Implement similarity search - REVISIT

## Phase 7: C-API and Bindings (Weeks 13-14)

### 14. C-API Implementation
   14.1. [ ] Create C-API functions in bindings/capi.zig
   14.2. [ ] Add memory management for C interface
   14.3. [ ] Implement structured error handling for C-API
   14.4. [ ] Create C header file generation
   14.5. [ ] Add tool registration from external languages
   14.6. [ ] Implement event subscription for C clients
   14.7. [ ] Add type conversion helpers (to/from JSON)

### 15. Language Bindings
   15.1. [ ] Design Lua binding interface
   15.2. [ ] Create example Lua scripts
   15.3. [ ] Add binding documentation

## Phase 8: Event System and Output Parsing (Week 15)

### 16. Event System - COMPLETED (See TODO-DONE.md)

### 17. Output Parsing - COMPLETED (See TODO-DONE.md)

## Phase 9: Documentation and Examples

### 18. Documentation
   18.1. [ ] Implement docs/generator.zig for auto-generation
   18.2. [ ] Create docs/templates.zig for output formats
   18.3. [ ] Generate API reference documentation
   18.4. [ ] Write architecture guide
   18.5. [ ] Create user tutorials
   18.6. [ ] Add inline code documentation
   18.7. [ ] Create bridge development guide

### 19. Examples
   19.1. [ ] Create examples/basic_chat.zig
   19.2. [ ] Update examples/basic_tool_usage.zig
   19.3. [ ] Create examples/multi_agent.zig
   19.4. [ ] Create examples/workflow_demo.zig
   19.5. [ ] Create examples/event_monitoring.zig
   19.6. [ ] Create examples/structured_output.zig
   19.7. [ ] Create examples/c_api_demo.c
   19.8. [ ] Create examples/lua/basic.lua
   19.9. [ ] Create examples/lua/tools.lua
   19.10. [ ] Create examples/lua/workflows.lua

## Ongoing Tasks

### 20. Quality Assurance
   20.1. [ ] Maintain test coverage above 80%
   20.2. [ ] Run performance benchmarks
   20.3. [ ] Memory leak detection
   20.4. [ ] Code review and refactoring
   20.5. [ ] Test scenario coverage for all features
   20.6. [ ] Bridge integration testing

### 21. Community
   21.1. [ ] Set up issue templates
   21.2. [ ] Create contribution guidelines
   21.3. [ ] Add code of conduct
   21.4. [ ] Release planning
   21.5. [ ] Create bridge developer community resources