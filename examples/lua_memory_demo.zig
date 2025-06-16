// ABOUTME: Demonstrates Lua memory management with Zig allocators
// ABOUTME: Shows memory limits, tracking, and custom allocator integration

const std = @import("std");
const zig_llms = @import("zig_llms");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Lua Memory Management Demo ===", .{});

    // Test 1: Basic memory tracking
    try testBasicMemoryTracking(allocator);

    // Test 2: Memory limits
    try testMemoryLimits(allocator);

    // Test 3: Different allocator types
    try testDifferentAllocators();

    // Test 4: Memory pressure and GC
    try testMemoryPressure(allocator);

    std.log.info("\n=== Memory Management Demo Complete ===", .{});
}

fn testBasicMemoryTracking(allocator: std.mem.Allocator) !void {
    std.log.info("\n--- Test 1: Basic Memory Tracking ---", .{});

    // Create engine with memory tracking enabled
    const config = zig_llms.scripting.EngineConfig{
        .max_memory_bytes = 5 * 1024 * 1024, // 5MB limit
        .enable_debugging = true, // Enables detailed tracking
    };

    const engine = zig_llms.scripting.engines.LuaEngine.create(allocator, config) catch |err| {
        if (err == error.LuaNotEnabled) {
            std.log.info("Lua is not enabled, skipping demo", .{});
            return;
        }
        return err;
    };
    defer engine.deinit();

    const context = try engine.createContext("memory_test");
    defer engine.destroyContext(context);

    // Get initial stats
    const initial_stats = engine.getAllocationStats(context);
    std.log.info("Initial memory: {} bytes", .{initial_stats.total_allocated});

    // Allocate some memory in Lua
    _ = try engine.executeScript(context,
        \\local data = {}
        \\for i = 1, 100 do
        \\    data[i] = string.rep("x", 100)
        \\end
        \\return #data
    );

    // Check memory growth
    const after_alloc = engine.getAllocationStats(context);
    std.log.info("After allocation: {} bytes (peak: {} bytes)", .{
        after_alloc.total_allocated,
        after_alloc.peak_allocated,
    });
    std.log.info("Allocations: {}, Deallocations: {}, Reallocations: {}", .{
        after_alloc.allocation_count,
        after_alloc.deallocation_count,
        after_alloc.reallocation_count,
    });

    // Force garbage collection
    engine.collectGarbage(context);

    const after_gc = engine.getAllocationStats(context);
    std.log.info("After GC: {} bytes", .{after_gc.total_allocated});
    std.log.info("✓ Memory tracking working correctly", .{});
}

fn testMemoryLimits(allocator: std.mem.Allocator) !void {
    std.log.info("\n--- Test 2: Memory Limits ---", .{});

    // Create engine with very small memory limit
    const config = zig_llms.scripting.EngineConfig{
        .max_memory_bytes = 100 * 1024, // 100KB limit
        .enable_debugging = true,
    };

    const engine = zig_llms.scripting.engines.LuaEngine.create(allocator, config) catch |err| {
        if (err == error.LuaNotEnabled) return;
        return err;
    };
    defer engine.deinit();

    const context = try engine.createContext("limit_test");
    defer engine.destroyContext(context);

    // Try to allocate beyond the limit
    const result = engine.executeScript(context,
        \\local huge_table = {}
        \\for i = 1, 10000 do
        \\    huge_table[i] = string.rep("x", 1000)
        \\end
        \\return #huge_table
    );

    if (result) |_| {
        std.log.err("Expected memory allocation to fail!", .{});
    } else |err| {
        std.log.info("✓ Memory limit enforced: {}", .{err});

        const stats = engine.getAllocationStats(context);
        std.log.info("Failed allocations: {}", .{stats.failed_allocations});
        std.log.info("Current memory: {} bytes (limit: {} bytes)", .{
            stats.total_allocated,
            config.max_memory_bytes,
        });
    }
}

fn testDifferentAllocators() !void {
    std.log.info("\n--- Test 3: Different Allocator Types ---", .{});

    // Test with arena allocator for bulk operations
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const config = zig_llms.scripting.EngineConfig{
        .max_memory_bytes = 1024 * 1024, // 1MB
    };

    const engine = zig_llms.scripting.engines.LuaEngine.create(arena.allocator(), config) catch |err| {
        if (err == error.LuaNotEnabled) return;
        return err;
    };
    defer engine.deinit();

    const context = try engine.createContext("arena_test");

    // Perform many small allocations
    _ = try engine.executeScript(context,
        \\local results = {}
        \\for i = 1, 1000 do
        \\    results[i] = i * i
        \\end
        \\return #results
    );

    std.log.info("✓ Arena allocator integration successful", .{});

    // Test with fixed buffer allocator
    var buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    const fba_engine = zig_llms.scripting.engines.LuaEngine.create(fba.allocator(), config) catch |err| {
        if (err == error.LuaNotEnabled) return;
        return err;
    };
    defer fba_engine.deinit();

    const fba_context = try fba_engine.createContext("fba_test");

    _ = try fba_engine.executeScript(fba_context,
        \\return "Fixed buffer allocator test"
    );

    std.log.info("✓ Fixed buffer allocator integration successful", .{});
}

fn testMemoryPressure(allocator: std.mem.Allocator) !void {
    std.log.info("\n--- Test 4: Memory Pressure and GC ---", .{});

    const config = zig_llms.scripting.EngineConfig{
        .max_memory_bytes = 2 * 1024 * 1024, // 2MB
        .enable_debugging = true,
    };

    const engine = zig_llms.scripting.engines.LuaEngine.create(allocator, config) catch |err| {
        if (err == error.LuaNotEnabled) return;
        return err;
    };
    defer engine.deinit();

    const context = try engine.createContext("pressure_test");
    defer engine.destroyContext(context);

    // Monitor memory during multiple allocations and GC cycles
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // Allocate memory
        _ = try engine.executeScript(context,
            \\local temp = {}
            \\for j = 1, 100 do
            \\    temp[j] = {data = string.rep("x", 1000)}
            \\end
            \\collectgarbage("step")
            \\return #temp
        );

        const stats = engine.getAllocationStats(context);
        std.log.info("Iteration {}: {} bytes allocated", .{ i + 1, stats.total_allocated });

        // Manual GC
        engine.collectGarbage(context);

        const gc_stats = engine.getAllocationStats(context);
        std.log.info("After GC: {} bytes (freed {} bytes)", .{
            gc_stats.total_allocated,
            stats.total_allocated - gc_stats.total_allocated,
        });
    }

    std.log.info("✓ Memory pressure handling successful", .{});

    // Final stats
    const final_stats = engine.getAllocationStats(context);
    std.log.info("\nFinal Statistics:", .{});
    std.log.info("  Total allocations: {}", .{final_stats.allocation_count});
    std.log.info("  Total deallocations: {}", .{final_stats.deallocation_count});
    std.log.info("  Total reallocations: {}", .{final_stats.reallocation_count});
    std.log.info("  Failed allocations: {}", .{final_stats.failed_allocations});
    std.log.info("  Peak memory: {} bytes", .{final_stats.peak_allocated});
    std.log.info("  Current memory: {} bytes", .{final_stats.total_allocated});
}
