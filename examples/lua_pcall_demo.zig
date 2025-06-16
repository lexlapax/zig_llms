// ABOUTME: Demonstration of lua_pcall wrapper with error handling and recovery
// ABOUTME: Shows safe function execution, error handlers, and sandboxing

const std = @import("std");
const zig_llms = @import("zig_llms");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== Lua Protected Call Demo ===\n\n", .{});

    // Create Lua engine
    const lua_lib = @import("zig_llms").scripting.engines.lua;
    var wrapper = try lua_lib.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create executor with error handling options
    const options = lua_lib.lua_execution.ExecutionOptions{
        .name = "pcall_demo",
        .capture_stack_trace = true,
        .max_trace_depth = 20,
        .stack_reserve = 30,
    };

    var executor = lua_lib.lua_execution.LuaExecutor.init(&wrapper, allocator, options);
    defer executor.deinit();

    // Setup error handler for better debugging
    try executor.pcall.setupErrorHandler();

    // Test 1: Basic successful execution
    std.debug.print("Test 1: Basic successful execution\n", .{});
    {
        var result = try executor.executeString(
            \\function add(a, b)
            \\    return a + b
            \\end
            \\return add(10, 20)
        );
        defer result.deinit();

        std.debug.print("  Result: {any}\n", .{result.values[0]});
        std.debug.print("  Execution time: {}μs\n", .{result.execution_time_us});
    }

    // Test 2: Handling runtime errors with traceback
    std.debug.print("\nTest 2: Handling runtime errors\n", .{});
    {
        const error_result = executor.executeString(
            \\function divide(a, b)
            \\    if b == 0 then
            \\        error("Division by zero!")
            \\    end
            \\    return a / b
            \\end
            \\
            \\function calculate()
            \\    return divide(10, 0)
            \\end
            \\
            \\return calculate()
        );

        if (error_result) |_| {
            std.debug.print("  ERROR: Should have failed!\n", .{});
        } else |err| {
            std.debug.print("  Caught error: {}\n", .{err});
        }
    }

    // Test 3: Using pcall directly within Lua
    std.debug.print("\nTest 3: Using pcall within Lua\n", .{});
    {
        var result = try executor.executeString(
            \\function risky_operation()
            \\    error("Something went wrong!")
            \\end
            \\
            \\local success, result = pcall(risky_operation)
            \\if success then
            \\    return "Operation succeeded: " .. tostring(result)
            \\else
            \\    return "Operation failed: " .. tostring(result)
            \\end
        );
        defer result.deinit();

        std.debug.print("  Result: {s}\n", .{result.values[0].string});
    }

    // Test 4: Function calls with error handling
    std.debug.print("\nTest 4: Function calls with error handling\n", .{});
    {
        // Define test functions
        _ = try executor.executeString(
            \\function safe_function(x)
            \\    return x * 2
            \\end
            \\
            \\function unsafe_function(x)
            \\    if x < 0 then
            \\        error("Negative values not allowed")
            \\    end
            \\    return x * 2
            \\end
        );

        // Call safe function
        const safe_args = [_]zig_llms.scripting.value_bridge.ScriptValue{
            .{ .integer = 5 },
        };

        var safe_result = try executor.callFunction("safe_function", &safe_args);
        defer safe_result.deinit();
        std.debug.print("  Safe function result: {any}\n", .{safe_result.values[0]});

        // Call unsafe function with negative value
        const unsafe_args = [_]zig_llms.scripting.value_bridge.ScriptValue{
            .{ .integer = -5 },
        };

        const unsafe_result = executor.callFunction("unsafe_function", &unsafe_args);
        if (unsafe_result) |_| {
            std.debug.print("  ERROR: Should have failed!\n", .{});
        } else |err| {
            std.debug.print("  Caught error from unsafe function: {}\n", .{err});
        }
    }

    // Test 5: Sandboxed execution
    std.debug.print("\nTest 5: Sandboxed execution\n", .{});
    {
        const sandbox_index = try executor.pcall.createSandbox();

        // Try to use restricted functions in sandbox
        wrapper.pushValue(sandbox_index);
        wrapper.setGlobal("_ENV");

        const sandbox_result = executor.executeString(
            \\-- This should work (safe functions)
            \\local result = math.sqrt(16)
            \\
            \\-- This should fail (dangerous function not in sandbox)
            \\-- local file = io.open("test.txt", "w")
            \\
            \\return result
        );

        if (sandbox_result) |result| {
            defer result.deinit();
            std.debug.print("  Sandbox execution result: {any}\n", .{result.values[0]});
        } else |err| {
            std.debug.print("  Sandbox error: {}\n", .{err});
        }

        // Restore global environment
        wrapper.pushGlobalTable();
        wrapper.setGlobal("_ENV");
    }

    // Test 6: Memory tracking
    std.debug.print("\nTest 6: Memory tracking\n", .{});
    {
        var result = try executor.executeString(
            \\local big_table = {}
            \\for i = 1, 1000 do
            \\    big_table[i] = string.rep("x", 100)
            \\end
            \\return #big_table
        );
        defer result.deinit();

        std.debug.print("  Created table size: {any}\n", .{result.values[0]});
        std.debug.print("  Memory allocated: {} bytes\n", .{result.memory_allocated});
        std.debug.print("  GC collections: {}\n", .{result.gc_count});
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
