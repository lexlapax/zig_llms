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

# Run tests (once uncommented in build.zig)
zig build test
```

## Architecture Overview

zig_llms is a lightweight LLM agent framework inspired by go-llms and Google's Agent Development Kit. The library provides:

1. **Modular LLM Provider System**: Unified interface (`llm/provider.zig`) with implementations for OpenAI, Anthropic, and local models via Ollama
2. **Agent Core**: State management and execution loop in `agent.zig`
3. **Tool System**: Extensible tool framework for agent capabilities (`tool.zig`)
4. **Workflow Engine**: Multi-step task orchestration (`workflow.zig`)
5. **Memory Management**: Short-term conversation history and long-term storage abstractions
6. **C-API Bindings**: Enable integration with scripting languages like Lua (`bindings/capi.zig`)

## Development Guidelines

1. **Build System**: The project uses Zig's built-in build system. A Makefile should be created with standard targets (build, test, format, lint) as per coding guidelines.

2. **Testing**: Centralize testing utilities in reusable helpers, mocks, fixtures and scenarios. Tests go in `test/` directory.

3. **Module Structure**: 
   - All public APIs are exported through `src/main.zig`
   - Each major feature has its own module file
   - Provider implementations live in `src/llm/` subdirectory
   - Memory subsystems are in `src/memory/`

4. **Current State**: The project is in early development with many placeholder implementations. Most functionality needs to be implemented following the patterns established in the existing file structure.

## Key Implementation Notes

- The library prioritizes being lightweight with minimal dependencies
- Designed for easy cross-compilation and C-API exposure
- Memory safety and performance are primary concerns leveraging Zig's compile-time features
- Follow the modular architecture pattern established in the source structure