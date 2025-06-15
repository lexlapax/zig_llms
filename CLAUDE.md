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
5. **🚧 Agent Core**: State management and execution loop (planned)
6. **🚧 Tool System**: Extensible tool framework for agent capabilities (planned)
7. **🚧 Workflow Engine**: Multi-step task orchestration (planned)
8. **🚧 C-API Bindings**: Enable integration with scripting languages like Lua (planned)

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

4. **Current State**: The project has completed Phase 1 (Foundation) and most of Phase 2 (Provider Implementation). Core infrastructure, testing framework, HTTP client, and OpenAI provider are fully functional. Ready for Phase 3 (Agent System) development.

## Current Implementation Status (Updated 2025-06-15)

### ✅ Completed Components
- **Core Types** (`types.zig`): Message, Content, Role, Response, Usage types
- **Error Handling** (`error.zig`): Structured error types with serialization and recovery strategies
- **Provider Interface** (`provider.zig`): Unified vtable-based provider interface
- **OpenAI Provider** (`providers/openai.zig`): Complete chat completions API implementation
- **HTTP Infrastructure** (`http/`): Client, connection pooling, request/response handling
- **Memory Management** (`memory/short_term.zig`): Conversation history with token counting
- **Testing Framework** (`testing/`): Scenarios, mocks, matchers, fixtures
- **Provider Registry** (`providers/registry.zig`): Dynamic provider registration and discovery
- **Provider Factory** (`providers/factory.zig`): Type-safe provider creation
- **Provider Metadata** (`providers/metadata.zig`): Capability and model discovery

### 🚧 In Progress
- JSON schema validation (`schema/validator.zig`)
- Retry logic with exponential backoff

### 📋 Next Phase (Agent System)
- Agent interface and lifecycle (`agent.zig`)
- State management (`state.zig`) 
- Tool system (`tool.zig`, `tool_registry.zig`)

## Key Implementation Notes

- The library prioritizes being lightweight with minimal dependencies
- Designed for easy cross-compilation and C-API exposure
- Memory safety and performance are primary concerns leveraging Zig's compile-time features
- Follow the modular architecture pattern established in the source structure
- All tests pass and the OpenAI provider is ready for production use