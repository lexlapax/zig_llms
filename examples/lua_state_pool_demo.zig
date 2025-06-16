// ABOUTME: Demonstrates lua_State pooling with performance monitoring
// ABOUTME: Shows state reuse, recycling policies, and scoped handles

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const LuaEngine = @import("zig_llms").scripting.engines.LuaEngine;
const LuaStatePool = @import("zig_llms").scripting.engines.lua_lifecycle.LuaStatePool;
const ScopedLuaState = @import("zig_llms").scripting.engines.lua_lifecycle.ScopedLuaState;
const EngineConfig = @import("zig_llms").scripting.EngineConfig;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua State Pool Demo ===\n\n", .{});

    // Create engine with custom pool config
    const config = EngineConfig{
        .max_memory_bytes = 10 * 1024 * 1024, // 10 MB per state
        .enable_sandboxing = true,
    };

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    // Get pool statistics
    const lua_engine = @fieldParentPtr(LuaEngine, "base", engine);

    std.debug.print("Initial pool stats:\n", .{});
    printPoolStats(lua_engine.state_pool.getStats());

    // Test 1: Basic state acquisition and release
    std.debug.print("\n1. Testing basic state acquisition and release:\n", .{});
    {
        const context1 = try engine.createContext("context1");
        defer engine.destroyContext(context1);

        const context2 = try engine.createContext("context2");
        defer engine.destroyContext(context2);

        // Execute some code in each context
        _ = try engine.executeScript(context1, "return 'Hello from context 1'");
        _ = try engine.executeScript(context2, "return 'Hello from context 2'");

        std.debug.print("Pool stats with 2 active contexts:\n", .{});
        printPoolStats(lua_engine.state_pool.getStats());
    }

    // After contexts are destroyed, states should be returned to pool
    std.debug.print("\nPool stats after releasing contexts:\n", .{});
    printPoolStats(lua_engine.state_pool.getStats());

    // Test 2: State reuse demonstration
    std.debug.print("\n2. Testing state reuse:\n", .{});
    {
        // Create and destroy contexts multiple times to show reuse
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const context = try engine.createContext("temp_context");
            defer engine.destroyContext(context);

            const script = try std.fmt.allocPrint(allocator, "return 'Iteration {d}'", .{i});
            defer allocator.free(script);

            const result = try engine.executeScript(context, script);
            defer result.deinit(allocator);

            if (result == .string) {
                std.debug.print("  {s}\n", .{result.string});
            }
        }

        std.debug.print("\nPool stats after reuse test:\n", .{});
        printPoolStats(lua_engine.state_pool.getStats());
    }

    // Test 3: Scoped state handles
    std.debug.print("\n3. Testing scoped state handles:\n", .{});
    {
        // Direct pool access for demonstration
        var scoped = try ScopedLuaState.init(lua_engine.state_pool);
        defer scoped.deinit();

        const wrapper = scoped.getWrapper();

        // Execute some Lua code
        try wrapper.doString(
            \\function fibonacci(n)
            \\    if n <= 1 then return n end
            \\    return fibonacci(n-1) + fibonacci(n-2)
            \\end
            \\return fibonacci(10)
        );

        const result = wrapper.toNumber(-1);
        std.debug.print("  Fibonacci(10) = {d}\n", .{result.?});
        wrapper.pop(1);

        // State will be automatically released when scoped goes out of scope
    }

    std.debug.print("\nFinal pool stats:\n", .{});
    printPoolStats(lua_engine.state_pool.getStats());

    // Test 4: Pool cleanup
    std.debug.print("\n4. Testing pool cleanup:\n", .{});
    lua_engine.state_pool.cleanup();

    std.debug.print("Pool stats after cleanup:\n", .{});
    printPoolStats(lua_engine.state_pool.getStats());

    // Test 5: Performance comparison
    std.debug.print("\n5. Performance comparison (pooled vs non-pooled):\n", .{});

    // Pooled execution
    const pooled_start = std.time.microTimestamp();
    {
        var j: usize = 0;
        while (j < 100) : (j += 1) {
            const ctx = try engine.createContext("perf_test");
            _ = try engine.executeScript(ctx, "return 2 + 2");
            engine.destroyContext(ctx);
        }
    }
    const pooled_time = std.time.microTimestamp() - pooled_start;

    std.debug.print("  Pooled execution (100 iterations): {d} µs\n", .{pooled_time});
    std.debug.print("  Average per iteration: {d:.2} µs\n", .{@as(f64, @floatFromInt(pooled_time)) / 100.0});

    // Show detailed statistics
    const final_stats = lua_engine.state_pool.getStats();
    std.debug.print("\nDetailed pool statistics:\n", .{});
    std.debug.print("  Total states created: {d}\n", .{final_stats.total_created});
    std.debug.print("  Total states recycled: {d}\n", .{final_stats.total_recycled});
    std.debug.print("  State reuse rate: {d:.1}%\n", .{if (final_stats.total_created > 0)
        (1.0 - @as(f64, @floatFromInt(final_stats.total_created)) / 105.0) * 100.0
    else
        0.0});
    std.debug.print("  Average state lifetime: {d:.0} ms\n", .{final_stats.average_age_ms});
    std.debug.print("  Average uses per state: {d:.1}\n", .{final_stats.average_uses});

    std.debug.print("\n=== Demo Complete ===\n", .{});
}

fn printPoolStats(stats: LuaStatePool.PoolStats) void {
    std.debug.print("  Available states: {d}\n", .{stats.available_count});
    std.debug.print("  In-use states: {d}\n", .{stats.in_use_count});
    std.debug.print("  Total states: {d}\n", .{stats.total_count});
    std.debug.print("  Pool capacity: {d}-{d}\n", .{ stats.min_pool_size, stats.max_pool_size });
}
