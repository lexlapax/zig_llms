// ABOUTME: Demonstrates advanced Lua engine lifecycle management features
// ABOUTME: Shows state pooling, snapshots, and isolation capabilities

const std = @import("std");
const zig_llms = @import("zig_llms");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Only run if Lua is enabled - we'll just try to run and catch the error if disabled

    std.log.info("=== Lua Engine Lifecycle Management Demo ===", .{});

    // Create engine with lifecycle management
    const config = zig_llms.scripting.EngineConfig{
        .max_memory_bytes = 10 * 1024 * 1024, // 10MB limit
        .max_execution_time_ms = 5000, // 5 second timeout
        .sandbox_level = .restricted, // Enable basic sandboxing
    };

    const engine = zig_llms.scripting.engines.LuaEngine.create(allocator, config) catch |err| {
        if (err == error.LuaNotEnabled) {
            std.log.info("Lua is not enabled, skipping demo", .{});
            return;
        }
        return err;
    };
    defer engine.deinit();

    std.log.info("✓ Created Lua engine with lifecycle management", .{});

    // Demonstrate context creation and state pooling
    std.log.info("\n--- Testing State Pooling ---", .{});
    
    const context1 = try engine.createContext("context1");
    const context2 = try engine.createContext("context2");
    
    // Get initial pool stats
    const initial_stats = engine.getPoolStats();
    std.log.info("Pool stats - Available: {}, In-use: {}, Max: {}", .{
        initial_stats.available_count,
        initial_stats.in_use_count,
        initial_stats.max_pool_size,
    });

    // Test script execution with lifecycle tracking
    std.log.info("\n--- Testing Script Execution ---", .{});
    
    _ = try engine.executeScript(context1, "local x = 42; return x + 8");
    std.log.info("✓ Executed script in context1", .{});

    // Test global variables
    try engine.setGlobal(context2, "test_var", zig_llms.scripting.ScriptValue{ .integer = 100 });
    const result = try engine.getGlobal(context2, "test_var");
    defer result.deinit(allocator);
    
    if (result == .integer) {
        std.log.info("✓ Global variable test_var = {}", .{result.integer});
    }

    // Test memory usage and garbage collection
    std.log.info("\n--- Testing Memory Management ---", .{});
    
    const memory_before = engine.getMemoryUsage(context1);
    
    // Create some memory pressure
    _ = try engine.executeScript(context1, 
        \\local big_table = {}
        \\for i = 1, 1000 do
        \\    big_table[i] = "string_" .. i
        \\end
        \\return #big_table
    );
    
    const memory_after = engine.getMemoryUsage(context1);
    std.log.info("Memory usage - Before: {} bytes, After: {} bytes", .{ memory_before, memory_after });
    
    // Force garbage collection
    engine.collectGarbage(context1);
    const memory_after_gc = engine.getMemoryUsage(context1);
    std.log.info("Memory after GC: {} bytes", .{memory_after_gc});

    // Test snapshots (if available)
    std.log.info("\n--- Testing Snapshots ---", .{});
    
    try engine.setGlobal(context1, "snapshot_test", zig_llms.scripting.ScriptValue{ .integer = 1 });
    try engine.createSnapshot(context1);
    std.log.info("✓ Created snapshot", .{});
    
    try engine.setGlobal(context1, "snapshot_test", zig_llms.scripting.ScriptValue{ .integer = 2 });
    const changed_value = try engine.getGlobal(context1, "snapshot_test");
    defer changed_value.deinit(allocator);
    std.log.info("Changed value: {}", .{changed_value.integer});
    
    try engine.restoreSnapshot(context1, 0);
    const restored_value = try engine.getGlobal(context1, "snapshot_test");
    defer restored_value.deinit(allocator);
    std.log.info("✓ Restored value: {}", .{restored_value.integer});

    // Test context stats
    if (engine.getContextStats(context1)) |stats| {
        std.log.info("\n--- Context Statistics ---", .{});
        std.log.info("Execution count: {}", .{stats.execution_count});
        std.log.info("Error count: {}", .{stats.error_count});
        std.log.info("Age: {}ms", .{stats.getAge()});
        std.log.info("Idle time: {}ms", .{stats.getIdleTime()});
    }

    // Clean up contexts (will return states to pool)
    engine.destroyContext(context1);
    engine.destroyContext(context2);

    // Check final pool stats
    const final_stats = engine.getPoolStats();
    std.log.info("\n--- Final Pool Stats ---", .{});
    std.log.info("Available: {}, In-use: {}, Max: {}", .{
        final_stats.available_count,
        final_stats.in_use_count,
        final_stats.max_pool_size,
    });

    // Cleanup idle states
    engine.cleanupIdleStates();
    std.log.info("✓ Cleaned up idle states", .{});

    std.log.info("\n=== Lifecycle Management Demo Complete ===", .{});
}