# zig_llms Makefile

.PHONY: all build test clean format lint run-example help

# Default target
all: build

# Build the library and examples
build:
	@echo "Building zig_llms..."
	zig build

# Build in release mode
release:
	@echo "Building zig_llms in release mode..."
	zig build -Doptimize=ReleaseFast

# Run tests
test:
	@echo "Running tests..."
	zig build test

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	rm -rf zig-cache/ zig-out/

# Format all Zig files
format:
	@echo "Formatting Zig files..."
	find src test examples -name "*.zig" -type f -exec zig fmt {} \;

# Run static analysis (when available)
lint: format
	@echo "Running linter..."
	@echo "Note: Zig doesn't have a separate linter, format enforces style"

# Run the basic example
run-example:
	@echo "Running basic tool usage example..."
	zig build run-example

# Development build with debug info
dev:
	@echo "Building with debug info..."
	zig build -Doptimize=Debug

# Check code without building
check:
	@echo "Checking code..."
	zig build-exe src/main.zig --emit=no-outputs

# Generate documentation
docs:
	@echo "Generating documentation..."
	zig build-exe src/main.zig -femit-docs

# Install library
install:
	@echo "Installing zig_llms..."
	zig build install

# Lua setup
setup-lua:
	@echo "Setting up Lua dependencies..."
	@./scripts/setup_lua.sh

# Build with Lua support
build-lua: setup-lua
	@echo "Building zig_llms with Lua support..."
	zig build -Denable-lua=true

# Build without Lua support
build-no-lua:
	@echo "Building zig_llms without Lua support..."
	zig build -Denable-lua=false

# Run Lua example
run-lua-example: build-lua
	@echo "Running Lua example..."
	zig build run-lua-example

# Test with Lua enabled
test-lua: setup-lua
	@echo "Running tests with Lua enabled..."
	zig build test -Denable-lua=true

# Clean including dependencies
clean-all: clean
	@echo "Cleaning dependencies..."
	rm -rf deps/lua-*

# Show help
help:
	@echo "zig_llms Makefile targets:"
	@echo ""
	@echo "Basic targets:"
	@echo "  make build       - Build the library and examples"
	@echo "  make release     - Build in release mode"
	@echo "  make test        - Run tests"
	@echo "  make clean       - Clean build artifacts"
	@echo "  make format      - Format all Zig files"
	@echo "  make lint        - Run linter (currently just formatting)"
	@echo "  make run-example - Run the basic example"
	@echo "  make dev         - Build with debug info"
	@echo "  make check       - Check code without building"
	@echo "  make docs        - Generate documentation"
	@echo "  make install     - Install the library"
	@echo ""
	@echo "Lua targets:"
	@echo "  make setup-lua      - Download and set up Lua dependencies"
	@echo "  make build-lua      - Build with Lua support (default)"
	@echo "  make build-no-lua   - Build without Lua support"
	@echo "  make run-lua-example - Run Lua scripting example"
	@echo "  make test-lua       - Run tests with Lua enabled"
	@echo "  make clean-all      - Clean everything including deps"
	@echo ""
	@echo "  make help        - Show this help message"