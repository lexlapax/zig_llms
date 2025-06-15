# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build the library
zig build

# Run the example
zig build run-example

# Build in release mode
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

## Architecture Overview

zig_llms is a lightweight LLM agent framework inspired by go-llms and Google's Agent Development Kit. The library provides:

1. **✅ Modular LLM Provider System**: Unified interface (`provider.zig`) with complete OpenAI implementation, registry system, and metadata discovery
2. **✅ HTTP Infrastructure**: Robust HTTP client with connection pooling, request/response handling, and JSON serialization
3. **✅ Testing Framework**: Comprehensive testing utilities with scenarios, mocks, matchers, and fixtures  
4. **✅ Memory Management**: Short-term conversation history with ring buffer and token counting
5. **✅ Agent System**: BaseAgent with lifecycle management, LLMAgent implementation, thread-safe state management
6. **✅ Tool System**: Extensible tool framework with 8 built-in tools, discovery, validation, persistence
7. **✅ Workflow Engine**: Multi-step task orchestration with sequential, parallel, conditional, loop patterns
8. **✅ Hook System**: Comprehensive lifecycle hooks with metrics, logging, tracing, validation, caching
9. **✅ Event System**: Event emitter with filtering, recording, and replay functionality
10. **✅ Output Parsing**: JSON parser with recovery and schema-guided extraction
11. **✅ C-API Bindings**: Complete C-API with memory management and error handling
12. **✅ Universal Scripting Engine Infrastructure**: VTable-based interface with 10 comprehensive API bridges

## Development Guidelines

1. **Build System**: The project uses Zig's built-in build system. A Makefile should be created with standard targets (build, test, format, lint) as per coding guidelines.

2. **Testing**: Centralize testing utilities in reusable helpers, mocks, fixtures and scenarios. Tests go in `test/` directory.

3. **Module Structure**: 
   - All public APIs are exported through `src/main.zig`
   - Each major feature has its own module file
   - Provider implementations live in `src/providers/` subdirectory
   - Memory subsystems are in `src/memory/`
   - HTTP infrastructure in `src/http/`
   - Testing utilities in `src/testing/`
   - Tool system in `src/tools/` with 8 built-in tools
   - Workflow engine in `src/workflow/` with pattern implementations
   - Hook system in `src/hooks/` with comprehensive lifecycle support
   - Event system in `src/events/` with filtering and persistence
   - Output parsing in `src/outputs/` with recovery mechanisms
   - C-API bindings in `src/bindings/` with memory management
   - Scripting engine infrastructure in `src/scripting/` with universal API bridges

4. **Current State**: The project has completed Phases 1-9 (Foundation through Scripting Engine Infrastructure). All major systems are implemented and tested. Ready for Phase 10 (Lua Engine) implementation.

## Current Implementation Status (Updated 2025-06-15)

### ✅ Completed Core Framework (100% Complete)
- **Core Types** (`types.zig`): Message, Content, Role, Response, Usage types
- **Error Handling** (`error.zig`): Structured error types with serialization and recovery strategies
- **Provider System** (`provider.zig`, `providers/`): Unified vtable-based interface, OpenAI implementation, registry, factory, metadata
- **HTTP Infrastructure** (`http/`): Client, connection pooling, request/response handling
- **Agent System** (`agent.zig`, `state.zig`): BaseAgent, LLMAgent, thread-safe state management, lifecycle hooks
- **Tool System** (`tool.zig`, `tool_registry.zig`, `tools/`): VTable interface, 8 built-in tools, discovery, validation, persistence
- **Workflow Engine** (`workflow.zig`, `workflow/`): Sequential, parallel, conditional, loop patterns, composition, error handling
- **Memory Management** (`memory/short_term.zig`): Conversation history with token counting and ring buffer
- **Hook System** (`hooks/`): Comprehensive lifecycle hooks, metrics, logging, tracing, validation, caching, rate limiting
- **Event System** (`events/`): Event emitter, filtering, recording, replay functionality
- **Output Parsing** (`outputs/`): JSON parser with recovery, schema-guided extraction
- **Testing Framework** (`testing/`): Scenarios, mocks, matchers, fixtures
- **Schema System** (`schema/`): JSON schema validation, coercion, generation
- **C-API Bindings** (`bindings/`): Full C-API with memory management, error handling, header generation

### ✅ Completed Scripting Engine Infrastructure (100% Complete)
- **Core Interface** (`src/scripting/interface.zig`): VTable-based ScriptingEngine interface with metadata and features
- **Value Bridge** (`src/scripting/value_bridge.zig`): Universal ScriptValue conversion system
- **Error Bridge** (`src/scripting/error_bridge.zig`): Error handling with stack traces and recovery
- **Context Management** (`src/scripting/context.zig`): Execution context with security sandboxing
- **Registry System** (`src/scripting/registry.zig`): Engine registry and dynamic discovery
- **Module System** (`src/scripting/module_system.zig`): API bridge generation and lazy loading
- **Type Marshaler** (`src/scripting/type_marshaler.zig`): Complex structure conversion
- **API Bridges** (`src/scripting/api_bridges/`): Complete bridge system for all zig_llms APIs:
  - Agent Bridge: Full agent lifecycle, registry, execution
  - Tool Bridge: Registration, execution, discovery, state management
  - Workflow Bridge: Creation, execution, composition, dependencies
  - Provider Bridge: Direct access, streaming, configuration
  - Event Bridge: Subscription, emission, filtering, recording
  - Test Bridge: Scenarios, assertions, mocks, fixtures
  - Schema Bridge: Validation, generation, coercion, extraction
  - Memory Bridge: Conversation history, statistics, persistence
  - Hook Bridge: Registration, execution, filtering, composition
  - Output Bridge: Parsing, recovery, format detection, validation

### 🚧 Phase 10: Lua Scripting Engine (In Progress)
**Current Status**: Task 20.6 completed - Detailed implementation roadmap created
**Next Task**: 20.7 - Research Lua bytecode validation and security implications

**Progress**: 
- ✅ 20.1: Lua 5.4 C API integration research completed
- ✅ 20.2: lua_State management analysis completed (documented in `docs/lua_state_analysis.md`)
- ✅ 20.3: ScriptValue ↔ Lua type conversion system design completed (documented in `docs/lua_type_conversion_design.md`)
- ✅ 20.4: Coroutine integration planning completed (documented in `docs/lua_coroutine_integration_plan.md`)
- ✅ 20.5: Security sandboxing approach design completed (documented in `docs/lua_security_design.md`)
- ✅ 20.6: Implementation roadmap created (documented in `docs/lua_engine_implementation_roadmap.md`)
- 🔄 20.7: Research Lua bytecode validation and security implications (ready to start)

**Completed Research**: Comprehensive analysis of Lua integration patterns, memory management strategies, thread safety, sandboxing, and performance optimization approaches aligned with Zig's memory management philosophy.

## Key Implementation Notes

- The library prioritizes being lightweight with minimal dependencies
- Designed for easy cross-compilation and C-API exposure
- Memory safety and performance are primary concerns leveraging Zig's compile-time features
- Follow the modular architecture pattern established in the source structure
- All tests pass and the OpenAI provider is ready for production use