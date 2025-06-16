// ABOUTME: Tests for Lua allocator integration with Zig memory management
// ABOUTME: Verifies memory tracking, limits, and allocator behavior

const std = @import("std");
const testing = std.testing;
const lua_allocator = @import("../src/scripting/engines/lua_allocator.zig");
const lua = @import("../src/bindings/lua/lua.zig");

test "LuaAllocatorContext creation and stats" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    
    const context = try lua_allocator.LuaAllocatorContext.init(allocator, 1024 * 1024, true);
    defer context.deinit();
    
    const initial_stats = context.getStats();
    try testing.expectEqual(@as(usize, 0), initial_stats.total_allocated);
    try testing.expectEqual(@as(usize, 0), initial_stats.peak_allocated);
    try testing.expectEqual(@as(usize, 0), initial_stats.allocation_count);
}

test "luaAllocFunction allocation operations" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    const context = try lua_allocator.LuaAllocatorContext.init(allocator, 0, false);
    defer context.deinit();
    
    // Test allocation
    const ptr1 = lua_allocator.luaAllocFunction(context, null, 0, 100);
    try testing.expect(ptr1 != null);
    
    const stats1 = context.getStats();
    try testing.expectEqual(@as(usize, 100), stats1.total_allocated);
    try testing.expectEqual(@as(usize, 1), stats1.allocation_count);
    
    // Test reallocation
    const ptr2 = lua_allocator.luaAllocFunction(context, ptr1, 100, 200);
    try testing.expect(ptr2 != null);
    
    const stats2 = context.getStats();
    try testing.expectEqual(@as(usize, 200), stats2.total_allocated);
    try testing.expectEqual(@as(usize, 1), stats2.reallocation_count);
    
    // Test deallocation
    _ = lua_allocator.luaAllocFunction(context, ptr2, 200, 0);
    
    const stats3 = context.getStats();
    try testing.expectEqual(@as(usize, 0), stats3.total_allocated);
    try testing.expectEqual(@as(usize, 1), stats3.deallocation_count);
}

test "memory limit enforcement" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    const context = try lua_allocator.LuaAllocatorContext.init(allocator, 1000, false);
    defer context.deinit();
    
    // Allocate within limit
    const ptr1 = lua_allocator.luaAllocFunction(context, null, 0, 500);
    try testing.expect(ptr1 != null);
    
    // Try to allocate beyond limit
    const ptr2 = lua_allocator.luaAllocFunction(context, null, 0, 600);
    try testing.expect(ptr2 == null);
    
    const stats = context.getStats();
    try testing.expectEqual(@as(usize, 1), stats.failed_allocations);
    try testing.expectEqual(@as(usize, 500), stats.total_allocated);
    
    // Clean up
    _ = lua_allocator.luaAllocFunction(context, ptr1, 500, 0);
}

test "Lua state with custom allocator" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    
    // Create state with memory limit
    const state = try lua_allocator.createLuaStateWithAllocator(allocator, 100 * 1024, true);
    defer lua_allocator.closeLuaStateWithAllocator(state);
    
    // Get allocator context
    const context = lua_allocator.getAllocatorContext(state);
    try testing.expect(context != null);
    
    // Open standard libraries (will allocate memory)
    lua.c.luaL_openlibs(state);
    
    // Check that memory was allocated
    const stats = context.?.getStats();
    try testing.expect(stats.total_allocated > 0);
    try testing.expect(stats.allocation_count > 0);
    
    // Run some Lua code
    const code = "local t = {} for i = 1, 10 do t[i] = i * i end return #t";
    const result = lua.c.luaL_dostring(state, code);
    try testing.expectEqual(@as(c_int, 0), result);
    
    // Verify result
    const value = lua.c.lua_tointeger(state, -1);
    try testing.expectEqual(@as(lua.LuaInteger, 10), value);
    lua.c.lua_pop(state, 1);
}

test "TrackedLuaAllocator operations" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    
    var tracked = try lua_allocator.TrackedLuaAllocator.init(allocator, 1024 * 1024);
    defer tracked.deinit();
    
    // Run some operations
    const code =
        \\local sum = 0
        \\for i = 1, 100 do
        \\    sum = sum + i
        \\end
        \\return sum
    ;
    
    const result = lua.c.luaL_dostring(tracked.state, code);
    try testing.expectEqual(@as(c_int, 0), result);
    
    const value = lua.c.lua_tointeger(tracked.state, -1);
    try testing.expectEqual(@as(lua.LuaInteger, 5050), value);
    lua.c.lua_pop(tracked.state, 1);
    
    // Check stats
    const stats = tracked.getStats();
    try testing.expect(stats.allocation_count > 0);
    try testing.expect(stats.total_allocated > 0);
    
    // Log stats (only in debug mode)
    if (std.debug.runtime_safety) {
        tracked.logStats();
    }
}

test "allocation tracking in debug mode" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    const context = try lua_allocator.LuaAllocatorContext.init(allocator, 0, true);
    defer context.deinit();
    
    // Allocate with tracking
    const ptr1 = lua_allocator.luaAllocFunction(context, null, 0, 256);
    try testing.expect(ptr1 != null);
    
    // Verify tracking
    try testing.expect(context.allocations.contains(@intFromPtr(ptr1)));
    
    // Reallocate
    const ptr2 = lua_allocator.luaAllocFunction(context, ptr1, 256, 512);
    try testing.expect(ptr2 != null);
    
    // Old pointer should be removed, new one added
    try testing.expect(!context.allocations.contains(@intFromPtr(ptr1)));
    try testing.expect(context.allocations.contains(@intFromPtr(ptr2)));
    
    // Free
    _ = lua_allocator.luaAllocFunction(context, ptr2, 512, 0);
    try testing.expect(!context.allocations.contains(@intFromPtr(ptr2)));
}

test "multiple concurrent allocations" {
    if (!lua.lua_enabled) return;
    
    const allocator = testing.allocator;
    const context = try lua_allocator.LuaAllocatorContext.init(allocator, 0, false);
    defer context.deinit();
    
    var pointers: [10]?*anyopaque = undefined;
    
    // Allocate multiple blocks
    for (&pointers, 0..) |*ptr, i| {
        const size = (i + 1) * 100;
        ptr.* = lua_allocator.luaAllocFunction(context, null, 0, size);
        try testing.expect(ptr.* != null);
    }
    
    const stats_after_alloc = context.getStats();
    try testing.expectEqual(@as(usize, 10), stats_after_alloc.allocation_count);
    try testing.expectEqual(@as(usize, 5500), stats_after_alloc.total_allocated); // Sum of 100 to 1000
    
    // Free all blocks
    for (pointers, 0..) |ptr, i| {
        const size = (i + 1) * 100;
        _ = lua_allocator.luaAllocFunction(context, ptr, size, 0);
    }
    
    const stats_after_free = context.getStats();
    try testing.expectEqual(@as(usize, 0), stats_after_free.total_allocated);
    try testing.expectEqual(@as(usize, 10), stats_after_free.deallocation_count);
}