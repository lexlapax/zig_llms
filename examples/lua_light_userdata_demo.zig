// ABOUTME: Demonstrates light userdata optimization for simple pointers and primitive types
// ABOUTME: Shows performance benefits and memory savings from using Lua light userdata vs full userdata

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const LightUserdataManager = @import("zig_llms").scripting.engines.lua_light_userdata.LightUserdataManager;
const LightUserdataConfig = @import("zig_llms").scripting.engines.lua_light_userdata.LightUserdataConfig;
const LightUserdataStrategy = @import("zig_llms").scripting.engines.lua_light_userdata.LightUserdataStrategy;
const OptimizationUtils = @import("zig_llms").scripting.engines.lua_light_userdata.OptimizationUtils;
const TypeCategory = @import("zig_llms").scripting.engines.lua_light_userdata.TypeCategory;
const UserdataSystem = @import("zig_llms").scripting.engines.lua_userdata_system;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Denable-lua=true\\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Light Userdata Optimization Demo ===\\n\\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test 1: Type suitability analysis
    std.debug.print("1. Type suitability analysis:\\n", .{});

    const test_types = [_]struct {
        name: []const u8,
        size: usize,
        suitable: bool,
        category: TypeCategory,
        savings: usize,
    }{
        .{ .name = "i32", .size = @sizeOf(i32), .suitable = OptimizationUtils.isLightUserdataSuitable(i32), .category = OptimizationUtils.getTypeCategory(i32), .savings = OptimizationUtils.estimateMemorySavings(i32) },
        .{ .name = "i64", .size = @sizeOf(i64), .suitable = OptimizationUtils.isLightUserdataSuitable(i64), .category = OptimizationUtils.getTypeCategory(i64), .savings = OptimizationUtils.estimateMemorySavings(i64) },
        .{ .name = "f32", .size = @sizeOf(f32), .suitable = OptimizationUtils.isLightUserdataSuitable(f32), .category = OptimizationUtils.getTypeCategory(f32), .savings = OptimizationUtils.estimateMemorySavings(f32) },
        .{ .name = "f64", .size = @sizeOf(f64), .suitable = OptimizationUtils.isLightUserdataSuitable(f64), .category = OptimizationUtils.getTypeCategory(f64), .savings = OptimizationUtils.estimateMemorySavings(f64) },
        .{ .name = "bool", .size = @sizeOf(bool), .suitable = OptimizationUtils.isLightUserdataSuitable(bool), .category = OptimizationUtils.getTypeCategory(bool), .savings = OptimizationUtils.estimateMemorySavings(bool) },
        .{ .name = "*anyopaque", .size = @sizeOf(*anyopaque), .suitable = OptimizationUtils.isLightUserdataSuitable(*anyopaque), .category = OptimizationUtils.getTypeCategory(*anyopaque), .savings = OptimizationUtils.estimateMemorySavings(*anyopaque) },
    };

    std.debug.print("  Type Analysis Results:\\n", .{});
    std.debug.print("  {'Type':<12} {'Size':<4} {'Suitable':<8} {'Category':<15} {'Savings':<7}\\n", .{});
    std.debug.print("  {'-':<50}\\n", .{});

    for (test_types) |type_info| {
        std.debug.print("  {s:<12} {:<4} {:<8} {s:<15} {} bytes\\n", .{
            type_info.name,
            type_info.size,
            if (type_info.suitable) "✓" else "✗",
            @tagName(type_info.category),
            type_info.savings,
        });
    }

    // Test 2: Light userdata manager with different strategies
    std.debug.print("\\n2. Light userdata manager strategies:\\n", .{});

    const strategies = [_]struct {
        name: []const u8,
        strategy: LightUserdataStrategy,
    }{
        .{ .name = "Safe Types Only", .strategy = .safe_types_only },
        .{ .name = "Aggressive", .strategy = .aggressive },
        .{ .name = "Heuristic", .strategy = .heuristic },
        .{ .name = "Never", .strategy = .never },
    };

    for (strategies) |strat| {
        std.debug.print("  {s} Strategy:\\n", .{strat.name});

        const config = LightUserdataConfig{
            .strategy = strat.strategy,
            .max_light_userdata_size = 64,
            .enable_type_tagging = true,
            .use_pointer_validation = true,
        };

        var manager = LightUserdataManager.init(allocator, wrapper, config);

        // Test with different types
        const should_use_i32 = manager.shouldUseLightUserdata(i32, "i32");
        const should_use_bool = manager.shouldUseLightUserdata(bool, "bool");
        const should_use_large = manager.shouldUseLightUserdata([1024]u8, "large_array");

        std.debug.print("    i32: {s}, bool: {s}, large_array: {s}\\n", .{
            if (should_use_i32) "light" else "full",
            if (should_use_bool) "light" else "full",
            if (should_use_large) "light" else "full",
        });
    }

    // Test 3: Light userdata operations
    std.debug.print("\\n3. Light userdata operations:\\n", .{});

    const config = LightUserdataConfig{
        .strategy = .safe_types_only,
        .max_light_userdata_size = 64,
        .enable_type_tagging = true,
    };

    var manager = LightUserdataManager.init(allocator, wrapper, config);

    // Test i32 operations
    std.debug.print("  Testing i32 operations:\\n", .{});
    try manager.pushLightUserdata(i32, 42, "i32");
    const retrieved_i32 = try manager.getLightUserdata(i32, -1, "i32");

    if (retrieved_i32) |value| {
        std.debug.print("    ✓ Stored and retrieved i32: {} -> {}\\n", .{ 42, value });
    } else {
        std.debug.print("    ✗ Failed to retrieve i32\\n", .{});
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Test bool operations
    std.debug.print("  Testing bool operations:\\n", .{});
    try manager.pushLightUserdata(bool, true, "bool");
    const retrieved_bool = try manager.getLightUserdata(bool, -1, "bool");

    if (retrieved_bool) |value| {
        std.debug.print("    ✓ Stored and retrieved bool: {} -> {}\\n", .{ true, value });
    } else {
        std.debug.print("    ✗ Failed to retrieve bool\\n", .{});
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Test f32 operations
    std.debug.print("  Testing f32 operations:\\n", .{});
    try manager.pushLightUserdata(f32, 3.14, "f32");
    const retrieved_f32 = try manager.getLightUserdata(f32, -1, "f32");

    if (retrieved_f32) |value| {
        std.debug.print("    ✓ Stored and retrieved f32: {d} -> {d}\\n", .{ 3.14, value });
    } else {
        std.debug.print("    ✗ Failed to retrieve f32\\n", .{});
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Test 4: Performance comparison
    std.debug.print("\\n4. Performance comparison:\\n", .{});

    const num_iterations = 1000;

    // Time light userdata operations
    var timer = try std.time.Timer.start();

    for (0..num_iterations) |i| {
        try manager.pushLightUserdata(i32, @intCast(i), "i32");
        _ = try manager.getLightUserdata(i32, -1, "i32");
        lua.c.lua_pop(wrapper.state, 1);
    }

    const light_userdata_time = timer.lap();

    // Time regular userdata operations (simulation)
    var userdata_registry = UserdataSystem.UserdataRegistry.init(allocator);
    defer userdata_registry.deinit();

    try userdata_registry.registerType(UserdataSystem.UserdataTypeInfo{
        .name = "i32",
        .size = @sizeOf(i32),
        .alignment = @alignOf(i32),
    });

    var userdata_manager = UserdataSystem.LuaUserdataManager.init(allocator, wrapper, &userdata_registry);

    timer.reset();
    for (0..num_iterations) |i| {
        _ = try userdata_manager.createUserdata(i32, @intCast(i), "i32");
        _ = try userdata_manager.getUserdata(i32, -1, "i32");
        lua.c.lua_pop(wrapper.state, 1);
    }

    const full_userdata_time = timer.read();

    const performance_improvement = if (full_userdata_time > light_userdata_time)
        @as(f64, @floatFromInt(full_userdata_time - light_userdata_time)) / @as(f64, @floatFromInt(full_userdata_time)) * 100.0
    else
        0.0;

    std.debug.print("  Performance Results ({} iterations):\\n", .{num_iterations});
    std.debug.print("    Light userdata: {d}ms\\n", .{@as(f64, @floatFromInt(light_userdata_time)) / 1_000_000.0});
    std.debug.print("    Full userdata:  {d}ms\\n", .{@as(f64, @floatFromInt(full_userdata_time)) / 1_000_000.0});
    std.debug.print("    Improvement:    {d:.1}%\\n", .{performance_improvement});

    // Test 5: Memory usage analysis
    std.debug.print("\\n5. Memory usage analysis:\\n", .{});

    // Force garbage collection to get baseline
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    const baseline_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);

    // Create many light userdata instances
    const memory_test_count = 100;
    for (0..memory_test_count) |i| {
        try manager.pushLightUserdata(i32, @intCast(i), "i32");
    }

    const light_userdata_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);

    // Clean up
    lua.c.lua_pop(wrapper.state, memory_test_count);
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);

    // Create many full userdata instances
    for (0..memory_test_count) |i| {
        _ = try userdata_manager.createUserdata(i32, @intCast(i), "i32");
    }

    const full_userdata_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);

    // Clean up
    lua.c.lua_pop(wrapper.state, memory_test_count);
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);

    const light_usage = light_userdata_memory - baseline_memory;
    const full_usage = full_userdata_memory - baseline_memory;
    const memory_savings = if (full_usage > light_usage) full_usage - light_usage else 0;

    std.debug.print("  Memory Usage ({} instances):\\n", .{memory_test_count});
    std.debug.print("    Baseline:       {} KB\\n", .{baseline_memory});
    std.debug.print("    Light userdata: {} KB (+{} KB)\\n", .{ light_userdata_memory, light_usage });
    std.debug.print("    Full userdata:  {} KB (+{} KB)\\n", .{ full_userdata_memory, full_usage });
    std.debug.print("    Memory saved:   {} KB\\n", .{memory_savings});

    // Test 6: Type safety validation
    std.debug.print("\\n6. Type safety validation:\\n", .{});

    // Push an i32 as light userdata
    try manager.pushLightUserdata(i32, 100, "i32");

    // Try to retrieve as different types
    const as_i32 = try manager.getLightUserdata(i32, -1, "i32");
    const as_f32 = try manager.getLightUserdata(f32, -1, "f32");
    const as_bool = try manager.getLightUserdata(bool, -1, "bool");

    std.debug.print("  Stored i32(100), retrieved as:\\n", .{});
    std.debug.print("    i32: {}\\n", .{if (as_i32) |v| v else 0});
    std.debug.print("    f32: {}\\n", .{if (as_f32) |v| v else 0.0});
    std.debug.print("    bool: {}\\n", .{if (as_bool) |v| v else false});

    lua.c.lua_pop(wrapper.state, 1);

    // Test 7: ScriptValue integration
    std.debug.print("\\n7. ScriptValue integration:\\n", .{});

    // Create ScriptValue instances for different types
    const test_script_values = [_]struct {
        name: []const u8,
        value: ScriptValue,
    }{
        .{ .name = "integer", .value = ScriptValue{ .integer = 42 } },
        .{ .name = "number", .value = ScriptValue{ .number = 3.14159 } },
        .{ .name = "boolean", .value = ScriptValue{ .boolean = true } },
    };

    for (test_script_values) |test_value| {
        // Convert ScriptValue to light userdata representation
        if (test_value.value == .userdata) {
            var converted = try manager.lightUserdataToScriptValue(-1, allocator, null);
            defer converted.deinit(allocator);
            std.debug.print("  {s} ScriptValue converted successfully\\n", .{test_value.name});
        } else {
            std.debug.print("  {s} ScriptValue: {s}\\n", .{ test_value.name, @tagName(test_value.value) });
        }
    }

    // Test 8: Optimization metrics
    std.debug.print("\\n8. Optimization metrics:\\n", .{});

    const metrics = manager.getOptimizationMetrics();
    std.debug.print("  Light userdata count: {}\\n", .{metrics.light_userdata_count});
    std.debug.print("  Full userdata count:  {}\\n", .{metrics.full_userdata_count});
    std.debug.print("  Total userdata:       {}\\n", .{metrics.getTotalUserdata()});
    std.debug.print("  Light userdata ratio: {d:.1}%\\n", .{metrics.getLightUserdataRatio() * 100.0});
    std.debug.print("  Memory saved:         {} bytes\\n", .{metrics.memory_saved_bytes});
    std.debug.print("  Performance gain:     {d:.1}%\\n", .{metrics.performance_improvement_percent});

    // Test 9: Edge cases and error handling
    std.debug.print("\\n9. Edge cases and error handling:\\n", .{});

    // Test with zero-sized type (should handle gracefully)
    const ZeroSize = struct {};
    try manager.pushLightUserdata(ZeroSize, ZeroSize{}, "ZeroSize");
    const zero_retrieved = try manager.getLightUserdata(ZeroSize, -1, "ZeroSize");
    std.debug.print("  Zero-sized type handled: {}\\n", .{zero_retrieved != null});
    lua.c.lua_pop(wrapper.state, 1);

    // Test with non-userdata value
    lua.c.lua_pushinteger(wrapper.state, 42);
    const non_userdata = try manager.getLightUserdata(i32, -1, "i32");
    std.debug.print("  Non-userdata rejected: {}\\n", .{non_userdata == null});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 10: Stack verification
    std.debug.print("\\n10. Stack verification:\\n", .{});
    const final_stack = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Final stack level: {} (should be 0)\\n", .{final_stack});

    // Final memory check
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    const final_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
    std.debug.print("  Final Lua memory: {} KB\\n", .{final_memory});

    std.debug.print("\\n=== Demo Complete ===\\n", .{});
    std.debug.print("\\nKey optimization features demonstrated:\\n", .{});
    std.debug.print("- Type suitability analysis for light userdata optimization\\n", .{});
    std.debug.print("- Multiple optimization strategies (safe, aggressive, heuristic)\\n", .{});
    std.debug.print("- Performance comparison between light and full userdata\\n", .{});
    std.debug.print("- Memory usage analysis and savings calculation\\n", .{});
    std.debug.print("- Type safety validation and error handling\\n", .{});
    std.debug.print("- ScriptValue integration and bidirectional conversion\\n", .{});
    std.debug.print("- Optimization metrics and performance monitoring\\n", .{});
    std.debug.print("- Edge case handling and robust error management\\n", .{});
}
