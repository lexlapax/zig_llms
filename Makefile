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

# Show help
help:
	@echo "zig_llms Makefile targets:"
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
	@echo "  make help        - Show this help message"