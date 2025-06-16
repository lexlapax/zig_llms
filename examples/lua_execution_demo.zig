// ABOUTME: Demonstrates Lua script execution with comprehensive error handling
// ABOUTME: Shows execution options, error recovery, and performance tracking

const std = @import("std");
const zig_llms = @import("zig_llms");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Lua Script Execution Demo ===", .{});

    // Create engine
    const config = zig_llms.scripting.EngineConfig{
        .max_memory_bytes = 10 * 1024 * 1024, // 10MB
        .sandbox_level = .restricted,
    };

    const engine = zig_llms.scripting.engines.LuaEngine.create(allocator, config) catch |err| {
        if (err == error.LuaNotEnabled) {
            std.log.info("Lua is not enabled, skipping demo", .{});
            return;
        }
        return err;
    };
    defer engine.deinit();

    const context = try engine.createContext("demo");
    defer engine.destroyContext(context);

    // Test 1: Basic script execution
    try testBasicExecution(engine, context);
    
    // Test 2: Error handling
    try testErrorHandling(engine, context, allocator);
    
    // Test 3: Function calls
    try testFunctionCalls(engine, context, allocator);
    
    // Test 4: Performance tracking
    try testPerformanceTracking(engine, context);
    
    // Test 5: Global variables
    try testGlobalVariables(engine, context, allocator);

    std.log.info("\n=== Demo Complete ===", .{});
}

fn testBasicExecution(engine: *zig_llms.scripting.ScriptingEngine, context: *zig_llms.scripting.ScriptContext) !void {
    std.log.info("\n--- Test 1: Basic Script Execution ---", .{});
    
    // Simple expression
    var result = try engine.executeScript(context, "return 2 + 2");
    defer result.deinit(context.allocator);
    
    if (result == .integer) {
        std.log.info("✓ 2 + 2 = {}", .{result.integer});
    }
    
    // Multiple returns
    var multi_result = try engine.executeScript(context, 
        \\local a, b, c = 10, 20, 30
        \\return a + b + c
    );
    defer multi_result.deinit(context.allocator);
    
    if (multi_result == .integer) {
        std.log.info("✓ Sum = {}", .{multi_result.integer});
    }
    
    // String manipulation
    var str_result = try engine.executeScript(context,
        \\local name = "Zig"
        \\local greeting = "Hello, " .. name .. "!"
        \\return greeting
    );
    defer str_result.deinit(context.allocator);
    
    if (str_result == .string) {
        std.log.info("✓ Greeting: {s}", .{str_result.string});
    }
}

fn testErrorHandling(
    engine: *zig_llms.scripting.ScriptingEngine, 
    context: *zig_llms.scripting.ScriptContext,
    allocator: std.mem.Allocator,
) !void {
    std.log.info("\n--- Test 2: Error Handling ---", .{});
    
    // Syntax error
    const syntax_err = engine.executeScript(context, "return 42 +");
    if (syntax_err) |_| {
        std.log.err("Expected syntax error!", .{});
    } else |err| {
        std.log.info("✓ Caught syntax error: {}", .{err});
        
        if (engine.getLastError(context)) |script_err| {
            std.log.info("  Error details: {s}", .{script_err.message});
        }
        engine.clearErrors(context);
    }
    
    // Runtime error
    const runtime_err = engine.executeScript(context, "return unknown_variable");
    if (runtime_err) |_| {
        std.log.err("Expected runtime error!", .{});
    } else |err| {
        std.log.info("✓ Caught runtime error: {}", .{err});
        
        if (engine.getLastError(context)) |script_err| {
            std.log.info("  Error details: {s}", .{script_err.message});
        }
        engine.clearErrors(context);
    }
    
    // Type error
    const type_err = engine.executeScript(context, 
        \\local t = {}
        \\return t()  -- attempt to call a table
    );
    if (type_err) |_| {
        std.log.err("Expected type error!", .{});
    } else |err| {
        std.log.info("✓ Caught type error: {}", .{err});
        engine.clearErrors(context);
    }
    
    // Error with stack trace
    _ = engine.executeScript(context,
        \\function level3()
        \\    error("Something went wrong!")
        \\end
        \\
        \\function level2()
        \\    level3()
        \\end
        \\
        \\function level1()
        \\    level2()
        \\end
    ) catch {};
    
    const stack_err = engine.executeScript(context, "level1()");
    if (stack_err) |_| {
        std.log.err("Expected error with stack trace!", .{});
    } else |err| {
        _ = err;
        std.log.info("✓ Caught error with stack trace", .{});
        
        if (engine.getLastError(context)) |script_err| {
            std.log.info("  Error: {s}", .{script_err.message});
            if (script_err.stack_trace) |trace| {
                const trace_str = try trace.toString(allocator);
                defer allocator.free(trace_str);
                std.log.info("  Stack trace:\n{s}", .{trace_str});
            }
        }
        engine.clearErrors(context);
    }
}

fn testFunctionCalls(
    engine: *zig_llms.scripting.ScriptingEngine, 
    context: *zig_llms.scripting.ScriptContext,
    allocator: std.mem.Allocator,
) !void {
    std.log.info("\n--- Test 3: Function Calls ---", .{});
    
    // Define some functions
    _ = try engine.executeScript(context,
        \\function add(a, b)
        \\    return a + b
        \\end
        \\
        \\function greet(name)
        \\    return "Hello, " .. name .. "!"
        \\end
        \\
        \\function stats(numbers)
        \\    local sum = 0
        \\    local count = #numbers
        \\    for i = 1, count do
        \\        sum = sum + numbers[i]
        \\    end
        \\    return sum, count, sum / count
        \\end
    );
    
    // Call simple function
    const args1 = [_]zig_llms.scripting.ScriptValue{
        zig_llms.scripting.ScriptValue{ .integer = 10 },
        zig_llms.scripting.ScriptValue{ .integer = 20 },
    };
    
    var result1 = try engine.executeFunction(context, "add", &args1);
    defer result1.deinit(allocator);
    
    if (result1 == .integer) {
        std.log.info("✓ add(10, 20) = {}", .{result1.integer});
    }
    
    // Call with string argument
    const name_arg = try allocator.dupe(u8, "Lua");
    defer allocator.free(name_arg);
    
    const args2 = [_]zig_llms.scripting.ScriptValue{
        zig_llms.scripting.ScriptValue{ .string = name_arg },
    };
    
    var result2 = try engine.executeFunction(context, "greet", &args2);
    defer result2.deinit(allocator);
    
    if (result2 == .string) {
        std.log.info("✓ greet('Lua') = {s}", .{result2.string});
    }
    
    // Call with array argument
    var array = zig_llms.scripting.ScriptValue.Array.init(allocator, 5);
    defer array.deinit();
    
    array.items[0] = zig_llms.scripting.ScriptValue{ .integer = 10 };
    array.items[1] = zig_llms.scripting.ScriptValue{ .integer = 20 };
    array.items[2] = zig_llms.scripting.ScriptValue{ .integer = 30 };
    array.items[3] = zig_llms.scripting.ScriptValue{ .integer = 40 };
    array.items[4] = zig_llms.scripting.ScriptValue{ .integer = 50 };
    
    const args3 = [_]zig_llms.scripting.ScriptValue{
        zig_llms.scripting.ScriptValue{ .array = array },
    };
    
    var result3 = try engine.executeFunction(context, "stats", &args3);
    defer result3.deinit(allocator);
    
    std.log.info("✓ stats([10,20,30,40,50]) returned", .{});
}

fn testPerformanceTracking(
    engine: *zig_llms.scripting.ScriptingEngine, 
    context: *zig_llms.scripting.ScriptContext,
) !void {
    std.log.info("\n--- Test 4: Performance Tracking ---", .{});
    
    // Warm up
    _ = try engine.executeScript(context, "return 1");
    
    // Time a simple operation
    const start1 = std.time.microTimestamp();
    var result1 = try engine.executeScript(context, "return 2 + 2");
    const end1 = std.time.microTimestamp();
    defer result1.deinit(context.allocator);
    
    std.log.info("✓ Simple arithmetic: {} μs", .{end1 - start1});
    
    // Time a loop
    const start2 = std.time.microTimestamp();
    var result2 = try engine.executeScript(context,
        \\local sum = 0
        \\for i = 1, 1000 do
        \\    sum = sum + i
        \\end
        \\return sum
    );
    const end2 = std.time.microTimestamp();
    defer result2.deinit(context.allocator);
    
    std.log.info("✓ Loop (1-1000): {} μs, result = {}", .{ end2 - start2, result2.integer });
    
    // Time table operations
    const start3 = std.time.microTimestamp();
    var result3 = try engine.executeScript(context,
        \\local t = {}
        \\for i = 1, 100 do
        \\    t[i] = i * i
        \\end
        \\return #t
    );
    const end3 = std.time.microTimestamp();
    defer result3.deinit(context.allocator);
    
    std.log.info("✓ Table creation: {} μs, size = {}", .{ end3 - start3, result3.integer });
    
    // Check memory usage
    const memory_before = engine.getMemoryUsage(context);
    
    _ = try engine.executeScript(context,
        \\local big = {}
        \\for i = 1, 1000 do
        \\    big[i] = string.rep("x", 100)
        \\end
        \\BIG_TABLE = big  -- Store globally to prevent GC
    );
    
    const memory_after = engine.getMemoryUsage(context);
    std.log.info("✓ Memory usage: {} bytes -> {} bytes (+{} bytes)", .{
        memory_before,
        memory_after,
        memory_after - memory_before,
    });
    
    // Clean up
    _ = try engine.executeScript(context, "BIG_TABLE = nil");
    engine.collectGarbage(context);
    
    const memory_final = engine.getMemoryUsage(context);
    std.log.info("✓ After GC: {} bytes", .{memory_final});
}

fn testGlobalVariables(
    engine: *zig_llms.scripting.ScriptingEngine, 
    context: *zig_llms.scripting.ScriptContext,
    allocator: std.mem.Allocator,
) !void {
    std.log.info("\n--- Test 5: Global Variables ---", .{});
    
    // Set various types
    try engine.setGlobal(context, "test_int", zig_llms.scripting.ScriptValue{ .integer = 42 });
    try engine.setGlobal(context, "test_float", zig_llms.scripting.ScriptValue{ .number = 3.14 });
    try engine.setGlobal(context, "test_bool", zig_llms.scripting.ScriptValue{ .boolean = true });
    
    const test_str = try allocator.dupe(u8, "Hello from Zig!");
    defer allocator.free(test_str);
    try engine.setGlobal(context, "test_string", zig_llms.scripting.ScriptValue{ .string = test_str });
    
    // Create an object
    var obj = zig_llms.scripting.ScriptValue.Object.init(allocator);
    defer obj.deinit();
    
    const key1 = try allocator.dupe(u8, "name");
    defer allocator.free(key1);
    const val1 = try allocator.dupe(u8, "test object");
    defer allocator.free(val1);
    
    try obj.put("name", zig_llms.scripting.ScriptValue{ .string = val1 });
    try obj.put("value", zig_llms.scripting.ScriptValue{ .integer = 100 });
    
    try engine.setGlobal(context, "test_object", zig_llms.scripting.ScriptValue{ .object = obj });
    
    // Verify they're accessible from Lua
    var verify_result = try engine.executeScript(context,
        \\return {
        \\    test_int,
        \\    test_float,
        \\    test_bool,
        \\    test_string,
        \\    test_object and test_object.name,
        \\    test_object and test_object.value
        \\}
    );
    defer verify_result.deinit(allocator);
    
    std.log.info("✓ Set global variables successfully", .{});
    
    // Get them back
    var int_val = try engine.getGlobal(context, "test_int");
    defer int_val.deinit(allocator);
    std.log.info("✓ test_int = {}", .{int_val.integer});
    
    var float_val = try engine.getGlobal(context, "test_float");
    defer float_val.deinit(allocator);
    std.log.info("✓ test_float = {d}", .{float_val.number});
    
    var bool_val = try engine.getGlobal(context, "test_bool");
    defer bool_val.deinit(allocator);
    std.log.info("✓ test_bool = {}", .{bool_val.boolean});
    
    var string_val = try engine.getGlobal(context, "test_string");
    defer string_val.deinit(allocator);
    std.log.info("✓ test_string = {s}", .{string_val.string});
}