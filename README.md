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

zig_llms is currently under active development. Here's the current implementation status:

### ✅ Completed (Phase 1 & 2)
- **Core Infrastructure**: Types, error handling, provider interface, memory management
- **Build System**: Makefile, test configuration  
- **Testing Framework**: Scenarios, mocks, matchers, fixtures for comprehensive testing
- **Provider System**: Complete OpenAI provider with HTTP client and connection pooling
- **HTTP Infrastructure**: Request/response handling, connection pooling, retry logic
- **Memory Management**: Short-term conversation memory with token counting

### 🚧 In Progress (Phase 2)
- JSON schema validation and utilities
- Retry logic with exponential backoff

### 📋 Planned (Phase 3+)
- Agent system with lifecycle management
- Tool infrastructure and built-in tools
- Workflow engine for complex task orchestration
- Event system and output parsing
- C-API bindings for language interoperability

## Core Features

*   **Modular LLM Connectors**: ✅ **IMPLEMENTED**
    *   Standardized provider interface for LLM interactions
    *   **OpenAI provider fully implemented** with chat completions API
    *   Extensible design for adding more providers (Anthropic, Cohere, local models via Ollama)
*   **Memory Management**: ✅ **IMPLEMENTED**
    *   Short-term memory for conversational context with ring buffer and token counting
    *   (Future) Long-term memory solutions for persistent knowledge and learning
*   **Testing Framework**: ✅ **IMPLEMENTED**
    *   Comprehensive testing utilities with mocks, fixtures, and scenarios
    *   Declarative test scenarios for end-to-end testing
    *   Flexible assertion matchers for better test readability
*   **HTTP Infrastructure**: ✅ **IMPLEMENTED**
    *   Robust HTTP client with request/response handling
    *   Connection pooling for efficient resource usage
    *   JSON serialization/deserialization support
*   **Agent Core**: 📋 **PLANNED**
    *   Agent lifecycle management
    *   Flexible prompt engineering and management utilities
    *   State management and context handling
*   **Tooling System**: 📋 **PLANNED**
    *   Define custom tools with clear input/output schemas
    *   Mechanism for agents to discover, select, and execute tools
    *   Support for both synchronous and asynchronous tool operations
*   **Workflow Engine**: 📋 **PLANNED**
    *   Define sequences of agent actions, tool invocations, and conditional logic
    *   Orchestrate complex tasks involving multiple steps or agent collaborations
*   **C-API for Bindings**: 📋 **PLANNED**
    *   Expose key functionalities through a C-compatible interface
    *   Enable easy creation of bindings for languages like Lua (e.g., via LuaJIT FFI), Python, etc.
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