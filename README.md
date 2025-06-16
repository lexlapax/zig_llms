# zig_llms: A Lightweight LLM Agent Framework in Zig

zig_llms (zig.llms) is an upcoming library for the Zig programming language, designed to provide a robust and efficient foundation for building AI-powered agents. Inspired by the capabilities and goals of libraries like go-llms and the agentic scripting potential seen in projects like go-llmspell, zig_llms aims to deliver high performance, memory safety, and fine-grained control, leveraging the strengths of Zig.

## Vision

The core vision behind zig_llms is to:

1.  **Simplify LLM Integration**: Offer a clean, unified API to interact with various Large Language Models (LLMs), both cloud-based (e.g., OpenAI, Anthropic) and local (e.g., via Ollama, llama.cpp).
2.  **Empower Agent Creation**: Provide a lightweight yet powerful infrastructure for developing autonomous agents capable of reasoning, planning, and executing tasks.
3.  **Facilitate Tool Use**: Enable agents to seamlessly use external tools and APIs to augment their capabilities and interact with the world.
4.  **Enable Complex Workflows**: Support the definition and execution of multi-step workflows, allowing agents to tackle more complex problems.
5.  **Promote Interoperability**: Expose a C-API to allow zig_llms to be easily integrated into other programming environments, particularly scripting languages like Lua, enabling rapid development of agentic applications.
6.  **Prioritize Performance and Safety**: Utilize Zig's features to create a library that is not only fast and memory-efficient but also robust and predictable.4

## Inspirations
1. https://github.com/lexlapax/go-llms/README.md and it's architecture https://github.com/lexlapax/go-llms/blob/main/docs/technical/architecture.md and agentic setup https://github.com/lexlapax/go-llms/blob/main/docs/technical/agents.md 
2. which itself is based on google agent development kit https://google.github.io/adk-docs/ 
3. the intent for this library is so that we can create other dependent lightweight wrappers with bridges for scripts to call llms and create agents in a lightweight way inspired by https://github.com/lexlapax/go-llmspell/README.md

## coding guidelines
1. centralize testing utilities in a set of helpers, mocks, fixtures and scenarios that can be reused.
2. create a makefile with build, test, format, lint etc targets and run them after every implementation.


## Project Structure
`txt
zig_agents/
├── .gitignore
├── LICENSE
├── README.md
├── build.zig
├── examples/
│   └── basic_tool_usage.zig
├── src/
│   ├── main.zig                # Main library file, exports public API
│   ├── agent.zig               # Core agent logic, state, and execution loop
│   ├── llm.zig                 # Abstractions for LLM interactions
│   │   ├── provider.zig        # Interface for LLM providers
│   │   ├── openai.zig          # OpenAI specific implementation
│   │   ├── anthropic.zig       # Anthropic specific implementation (placeholder)
│   │   └── ollama.zig          # Ollama/local LLM specific implementation (placeholder)
│   ├── tool.zig                # Tool definition, registration, and execution
│   ├── workflow.zig            # Workflow definition and orchestration
│   ├── memory/
│   │   ├── short_term.zig      # Short-term memory (e.g., conversation history)
│   │   └── long_term.zig       # Long-term memory (e.g., vector stores - placeholder)
│   ├── prompt.zig              # Prompt templating and management
│   ├── bindings/
│   │   └── capi.zig            # C-API for exposing functionality to other languages (e.g., Lua)
│   └── util.zig                # Utility functions (e.g., JSON handling, HTTP client wrappers)
└── test/
    └── main.zig                # Test suite entry point
`

## Development Status

zig_llms is currently under active development with significant progress across multiple phases:

### ✅ Core Framework Complete (Phases 1-9)
- **Foundation**: Types, error handling, provider interface, memory management, build system
- **Provider System**: Complete OpenAI provider with HTTP client, connection pooling, retry logic
- **Agent System**: Full agent lifecycle management with BaseAgent and LLMAgent implementations
- **Tool System**: 8 built-in tools (file, http, system, data, process, math, feed, wrapper) with discovery and validation
- **Workflow Engine**: Sequential, parallel, conditional, and loop patterns with error handling and state management
- **Hook System**: Comprehensive lifecycle hooks with metrics, logging, tracing, validation, and caching
- **Event System**: Event emitter with filtering, recording, and replay functionality
- **Memory Management**: Short-term conversation memory with ring buffer and token counting
- **Output Parsing**: JSON parser with recovery and schema-guided extraction
- **C-API Bindings**: Complete C-API with memory management and error handling
- **Testing Framework**: Scenarios, mocks, matchers, fixtures for comprehensive testing

### ✅ Scripting Engine Infrastructure Complete (Phase 9)
- **Core Interface**: VTable-based ScriptingEngine with universal value bridge system
- **Error Handling**: Stack traces, recovery strategies, and sandboxing support
- **Registry System**: Dynamic engine discovery with lazy loading and feature detection
- **API Bridges**: 10 complete bridges exposing all zig_llms functionality to scripts
- **Type Marshaling**: Complex structure conversion for AgentConfig, ToolDefinition, etc.

### 🚧 Lua Scripting Engine In Progress (Phase 10) - 60% Complete
- ✅ **Research and Planning**: Comprehensive analysis of Lua 5.4 integration (10/10 complete)
- ✅ **Core Integration**: State management, pooling, isolation, snapshots, panic handling (10/10 complete)
- ✅ **Type System**: ScriptValue ↔ Lua type conversion with weak references and struct serialization (11/11 complete)
- 🚧 **API Bridge Integration**: Lua C function wrappers for all bridges (0/14 in progress)
- 📋 **Advanced Features**: Coroutines, metatables, module system, debug hooks
- 📋 **Security & Sandboxing**: Restricted environments, resource limits, bytecode validation

### 📋 Planned (Phases 11-14)
- **QuickJS Engine**: Modern JavaScript with ES2020+ features and async/await support
- **Wren Engine**: Fiber-based concurrency system with foreign class integration
- **Cross-Engine Integration**: Unified testing framework and performance comparisons
- **Documentation & Polish**: Auto-generated docs, comprehensive examples, tutorials

## Core Features

*   **Modular LLM Connectors**: ✅ **IMPLEMENTED**
    *   Standardized provider interface for LLM interactions
    *   **OpenAI provider fully implemented** with chat completions API
    *   Extensible design for adding more providers (Anthropic, Cohere, local models via Ollama)
*   **Agent System**: ✅ **IMPLEMENTED**
    *   Complete agent lifecycle management with BaseAgent and LLMAgent
    *   Thread-safe state management with snapshots and pools
    *   Flexible prompt engineering and management utilities
    *   Hook system integration for extensible agent behavior
*   **Tool System**: ✅ **IMPLEMENTED**
    *   8 built-in tools: file operations, HTTP requests, system info, data processing, etc.
    *   Dynamic tool discovery and registration with validation
    *   External tool integration with multiple execution strategies
    *   Schema-based input/output validation
*   **Workflow Engine**: ✅ **IMPLEMENTED**
    *   Sequential, parallel, conditional, and loop workflow patterns
    *   Error handling with retry policies and circuit breakers
    *   State management with checkpoint and recovery capabilities
    *   Workflow composition for complex task orchestration
*   **Memory Management**: ✅ **IMPLEMENTED**
    *   Short-term memory for conversational context with ring buffer and token counting
    *   Thread-safe operations with atomic updates and snapshots
    *   (Future) Long-term memory solutions for persistent knowledge and learning
*   **Hook System**: ✅ **IMPLEMENTED**
    *   Comprehensive lifecycle hooks (metrics, logging, tracing, validation, caching)
    *   Composable hook chains with priority ordering
    *   Built-in hooks for common patterns (rate limiting, middleware, adapters)
*   **Event System**: ✅ **IMPLEMENTED**
    *   Event emitter with pattern matching and filtering
    *   Event recording and replay for debugging and testing
    *   Subscription management with callback support
*   **Scripting Engine Framework**: ✅ **IMPLEMENTED**
    *   Universal scripting engine interface with VTable pattern
    *   10 complete API bridges exposing all zig_llms functionality
    *   Type marshaling system for complex structure conversion
    *   Lua 5.4 engine with state management, pooling, isolation, and panic handling
    *   Complete Lua type system with bidirectional ScriptValue conversion, weak references, and struct serialization
*   **C-API for Bindings**: ✅ **IMPLEMENTED**
    *   Complete C-API with memory management and error handling
    *   Session-based isolation for multi-client scenarios
    *   Comprehensive type conversion and JSON utilities
*   **Testing Framework**: ✅ **IMPLEMENTED**
    *   Comprehensive testing utilities with mocks, fixtures, and scenarios
    *   Declarative test scenarios for end-to-end testing
    *   Flexible assertion matchers for better test readability
*   **HTTP Infrastructure**: ✅ **IMPLEMENTED**
    *   Robust HTTP client with request/response handling
    *   Connection pooling for efficient resource usage
    *   Retry logic with exponential backoff
*   **Zig-Native Benefits**: ✅ **IMPLEMENTED**
    *   Compile-time safety and error handling
    *   Manual memory management for predictable performance and resource usage
    *   Easy cross-compilation

## Project Structure

The library is organized as follows:

*   `src/`: Contains the core library code.
    *   `main.zig`: Main library entry point.
    *   `agent.zig`: Core agent logic.
    *   `llm.zig`: LLM interaction abstractions and provider implementations.
    *   `tool.zig`: Tool definition and execution framework.
    *   `workflow.zig`: Workflow management.
    *   `memory/`: Agent memory systems.
    *   `prompt.zig`: Prompt templating and utilities.
    *   `bindings/capi.zig`: C-API for external language integration.
    *   `util.zig`: Common utilities.
*   `examples/`: Demonstrates usage of the library.
*   `test/`: Unit and integration tests.
*   `build.zig`: Zig build script.

## Getting Started

The library is functional and ready for basic LLM interactions through the OpenAI provider.

1.  **Prerequisites**:
    *   Zig compiler (0.14.0 or later)
    *   OpenAI API key for testing the provider
2.  **Building the Library**:
    ```bash
    zig build
    ```
3.  **Running Tests**:
    ```bash
    zig build test
    ```
4.  **Running Examples**:
    ```bash
    zig build run-example
    ```
5.  **Using the Library**:
    ```zig
    const zig_llms = @import("zig_llms");
    const OpenAIProvider = zig_llms.providers.OpenAIProvider;
    
    // Create OpenAI provider
    const config = .{
        .api_key = "your-api-key",
        .model = "gpt-4",
    };
    const provider = try OpenAIProvider.create(allocator, config);
    defer provider.vtable.close(provider);
    
    // Create a message
    const message = zig_llms.types.Message{
        .role = .user,
        .content = .{ .text = "Hello, how are you?" },
    };
    
    // Generate response
    const response = try provider.generate(&.{message}, .{});
    defer allocator.free(response.content);
    ```

## Contributing

Contributions are welcome! As the project takes shape, contribution guidelines will be established. For now, feel free to open issues for suggestions, bug reports, or feature requests.

## License

This project is intended to be open-source. The specific license (e.g., MIT or Apache 2.0) will be finalized soon.