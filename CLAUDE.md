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

3. **Module Structure**: Modular architecture with `src/main.zig` as public API export. Major subsystems: `providers/`, `memory/`, `http/`, `testing/`, `tools/` (8 built-in), `workflow/`, `hooks/`, `events/`, `outputs/`, `bindings/` (C-API), `scripting/` (universal engine infrastructure).

4. **Current State**: Phases 1-9 complete (all core systems). Phase 10 (Lua Engine) in progress - research complete, core integration started.

## Current Implementation Status (Updated 2025-06-16)

### ✅ Core Framework (100% Complete)
All foundational systems implemented and tested: Core types, error handling, provider system, HTTP infrastructure, agent system, tool system (8 built-in tools), workflow engine, memory management, hook system, event system, output parsing, testing framework, schema system, and C-API bindings.

### ✅ Scripting Engine Infrastructure (100% Complete)
Universal scripting interface with VTable-based engines, value bridge system, error handling, context management, registry system, module system, type marshaling, and complete API bridges for all 10 zig_llms subsystems (Agent, Tool, Workflow, Provider, Event, Test, Schema, Memory, Hook, Output).

### 🚧 Phase 10: Lua Scripting Engine (In Progress)
**Current Status**: Section 20 (Research) complete, Section 21 (Core Integration) in progress
**Next Task**: 21.2 - Create LuaEngine struct implementing ScriptingEngine interface

**Progress**: 
- ✅ Section 20: Lua Engine Research and Planning (10/10 tasks complete)
  - Complete Lua 5.4 integration analysis, type conversion design, coroutine planning
  - Security sandboxing, bytecode validation, warning system integration
  - GC analysis and debug introspection research
- ✅ 21.1: Lua library dependencies setup in build.zig with cross-platform support
- 🔄 21.2: LuaEngine struct implementation (next task)

**Research Complete**: Comprehensive analysis documented in `docs/archives/` covering all aspects of Lua integration aligned with Zig's memory management philosophy.

## Key Implementation Notes

- The library prioritizes being lightweight with minimal dependencies
- Designed for easy cross-compilation and C-API exposure
- Memory safety and performance are primary concerns leveraging Zig's compile-time features
- Follow the modular architecture pattern established in the source structure
- All tests pass and the OpenAI provider is ready for production use