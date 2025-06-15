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


## Core Features (Planned)

*   **Modular LLM Connectors**:
    *   Standardized interface for LLM interactions.
    *   Initial support planned for OpenAI.
    *   Extensible design for adding more providers (e.g., Anthropic, Cohere, local models via Ollama).
*   **Agent Core**:
    *   Agent lifecycle management.
    *   Flexible prompt engineering and management utilities.
    *   State management and context handling.
*   **Tooling System**:
    *   Define custom tools with clear input/output schemas.
    *   Mechanism for agents to discover, select, and execute tools.
    *   Support for both synchronous and asynchronous tool operations.
*   **Workflow Engine**:
    *   Define sequences of agent actions, tool invocations, and conditional logic.
    *   Orchestrate complex tasks involving multiple steps or agent collaborations.
*   **Memory Management**:
    *   Short-term memory for conversational context.
    *   (Future) Long-term memory solutions for persistent knowledge and learning.
*   **C-API for Bindings**:
    *   Expose key functionalities through a C-compatible interface.
    *   Enable easy creation of bindings for languages like Lua (e.g., via LuaJIT FFI), Python, etc.
*   **Zig-Native Benefits**:
    *   Compile-time safety and error handling.
    *   Manual memory management for predictable performance and resource usage.
    *   Easy cross-compilation.

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

## Getting Started (Placeholder)

*(This section will be updated as the library develops)*

1.  **Prerequisites**:
    *   Zig compiler (latest stable version recommended).
2.  **Building the Library**:
    ```bash
    zig build
    ```
3.  **Running Examples**:
    ```bash
    zig build run-example-name
    ```

## Contributing

Contributions are welcome! As the project takes shape, contribution guidelines will be established. For now, feel free to open issues for suggestions, bug reports, or feature requests.

## License

This project is intended to be open-source. The specific license (e.g., MIT or Apache 2.0) will be finalized soon.