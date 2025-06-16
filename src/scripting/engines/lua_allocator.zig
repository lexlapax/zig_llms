// ABOUTME: Zig allocator integration for Lua memory management
// ABOUTME: Provides custom allocation, tracking, and memory limits for Lua states

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const builtin = @import("builtin");

/// Memory allocation statistics
pub const AllocationStats = struct {
    total_allocated: usize,
    peak_allocated: usize,
    allocation_count: usize,
    deallocation_count: usize,
    reallocation_count: usize,
    failed_allocations: usize,

    pub fn init() AllocationStats {
        return AllocationStats{
            .total_allocated = 0,
            .peak_allocated = 0,
            .allocation_count = 0,
            .deallocation_count = 0,
            .reallocation_count = 0,
            .failed_allocations = 0,
        };
    }

    pub fn recordAllocation(self: *AllocationStats, size: usize) void {
        self.total_allocated += size;
        self.allocation_count += 1;
        if (self.total_allocated > self.peak_allocated) {
            self.peak_allocated = self.total_allocated;
        }
    }

    pub fn recordDeallocation(self: *AllocationStats, size: usize) void {
        self.total_allocated -|= size; // Saturating subtraction
        self.deallocation_count += 1;
    }

    pub fn recordReallocation(self: *AllocationStats, old_size: usize, new_size: usize) void {
        self.total_allocated = self.total_allocated - old_size + new_size;
        self.reallocation_count += 1;
        if (self.total_allocated > self.peak_allocated) {
            self.peak_allocated = self.total_allocated;
        }
    }

    pub fn recordFailure(self: *AllocationStats) void {
        self.failed_allocations += 1;
    }
};

/// Lua allocator context that wraps a Zig allocator
pub const LuaAllocatorContext = struct {
    allocator: std.mem.Allocator,
    stats: AllocationStats,
    memory_limit: usize,
    mutex: std.Thread.Mutex,
    allocations: std.AutoHashMap(usize, AllocationInfo),
    debug_mode: bool,

    const AllocationInfo = struct {
        size: usize,
        timestamp: i64,
        stack_trace: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, memory_limit: usize, debug_mode: bool) !*LuaAllocatorContext {
        const self = try allocator.create(LuaAllocatorContext);
        self.* = LuaAllocatorContext{
            .allocator = allocator,
            .stats = AllocationStats.init(),
            .memory_limit = memory_limit,
            .mutex = std.Thread.Mutex{},
            .allocations = std.AutoHashMap(usize, AllocationInfo).init(allocator),
            .debug_mode = debug_mode,
        };
        return self;
    }

    pub fn deinit(self: *LuaAllocatorContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up allocation tracking
        self.allocations.deinit();

        // Log any leaked memory in debug mode
        if (self.debug_mode and self.stats.total_allocated > 0) {
            std.log.warn("Lua allocator leaked {} bytes", .{self.stats.total_allocated});
        }

        self.allocator.destroy(self);
    }

    pub fn getStats(self: *LuaAllocatorContext) AllocationStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    pub fn checkMemoryLimit(self: *LuaAllocatorContext, additional: usize) bool {
        if (self.memory_limit == 0) return true;
        return (self.stats.total_allocated + additional) <= self.memory_limit;
    }
};

/// Lua allocation function that integrates with Zig allocators
pub fn luaAllocFunction(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.C) ?*anyopaque {
    const context = @as(*LuaAllocatorContext, @ptrCast(@alignCast(ud.?)));

    context.mutex.lock();
    defer context.mutex.unlock();

    // Handle different allocation cases
    if (nsize == 0) {
        // Free operation
        if (ptr) |p| {
            const aligned_ptr = @as([*]u8, @ptrCast(@alignCast(p)));

            // Update tracking
            if (context.debug_mode) {
                if (context.allocations.get(@intFromPtr(p))) |info| {
                    context.stats.recordDeallocation(info.size);
                    _ = context.allocations.remove(@intFromPtr(p));
                } else {
                    context.stats.recordDeallocation(osize);
                }
            } else {
                context.stats.recordDeallocation(osize);
            }

            // Free the memory
            context.allocator.free(aligned_ptr[0..osize]);
        }
        return null;
    } else if (ptr == null) {
        // Allocation operation
        if (!context.checkMemoryLimit(nsize)) {
            context.stats.recordFailure();
            return null;
        }

        const new_ptr = context.allocator.alloc(u8, nsize) catch {
            context.stats.recordFailure();
            return null;
        };

        context.stats.recordAllocation(nsize);

        // Track allocation in debug mode
        if (context.debug_mode) {
            context.allocations.put(@intFromPtr(new_ptr.ptr), LuaAllocatorContext.AllocationInfo{
                .size = nsize,
                .timestamp = std.time.milliTimestamp(),
                .stack_trace = null, // TODO: Capture stack trace
            }) catch {};
        }

        return @ptrCast(new_ptr.ptr);
    } else {
        // Reallocation operation
        const old_ptr = @as([*]u8, @ptrCast(@alignCast(ptr.?)));

        if (!context.checkMemoryLimit(if (nsize > osize) nsize - osize else 0)) {
            context.stats.recordFailure();
            return null;
        }

        // Try to resize in place first
        if (context.allocator.resize(old_ptr[0..osize], nsize)) {
            context.stats.recordReallocation(osize, nsize);

            // Update tracking in debug mode
            if (context.debug_mode) {
                if (context.allocations.get(@intFromPtr(ptr))) |*info| {
                    info.size = nsize;
                }
            }

            return ptr;
        }

        // Fallback to allocate + copy + free
        const new_ptr = context.allocator.alloc(u8, nsize) catch {
            context.stats.recordFailure();
            return null;
        };

        // Copy old data
        const copy_size = @min(osize, nsize);
        @memcpy(new_ptr[0..copy_size], old_ptr[0..copy_size]);

        // Free old memory
        context.allocator.free(old_ptr[0..osize]);

        context.stats.recordReallocation(osize, nsize);

        // Update tracking in debug mode
        if (context.debug_mode) {
            _ = context.allocations.remove(@intFromPtr(ptr));
            context.allocations.put(@intFromPtr(new_ptr.ptr), LuaAllocatorContext.AllocationInfo{
                .size = nsize,
                .timestamp = std.time.milliTimestamp(),
                .stack_trace = null,
            }) catch {};
        }

        return @ptrCast(new_ptr.ptr);
    }
}

/// Create a new Lua state with Zig allocator integration
pub fn createLuaStateWithAllocator(allocator: std.mem.Allocator, memory_limit: usize, debug_mode: bool) !lua.LuaState {
    if (!lua.lua_enabled) {
        return error.LuaNotEnabled;
    }

    // Create allocator context
    const context = try LuaAllocatorContext.init(allocator, memory_limit, debug_mode);
    errdefer context.deinit();

    // Create Lua state with custom allocator
    const state = lua.c.lua_newstate(luaAllocFunction, context) orelse {
        context.deinit();
        return error.OutOfMemory;
    };

    // Store context pointer in registry for later retrieval
    lua.c.lua_pushlightuserdata(state, context);
    lua.c.lua_setfield(state, lua.c.LUA_REGISTRYINDEX, "_ZIG_ALLOCATOR_CONTEXT");

    return state;
}

/// Get the allocator context from a Lua state
pub fn getAllocatorContext(state: lua.LuaState) ?*LuaAllocatorContext {
    if (!lua.lua_enabled) return null;

    lua.c.lua_getfield(state, lua.c.LUA_REGISTRYINDEX, "_ZIG_ALLOCATOR_CONTEXT");
    defer lua.c.lua_pop(state, 1);

    if (lua.c.lua_islightuserdata(state, -1)) {
        const ptr = lua.c.lua_touserdata(state, -1);
        return @as(*LuaAllocatorContext, @ptrCast(@alignCast(ptr)));
    }

    return null;
}

/// Close a Lua state created with custom allocator
pub fn closeLuaStateWithAllocator(state: lua.LuaState) void {
    if (!lua.lua_enabled) return;

    // Get and clean up allocator context
    if (getAllocatorContext(state)) |context| {
        // Close the Lua state first
        lua.c.lua_close(state);

        // Then clean up the allocator context
        context.deinit();
    } else {
        // Fallback to regular close
        lua.c.lua_close(state);
    }
}

/// Tracked allocator that provides detailed memory tracking
pub const TrackedLuaAllocator = struct {
    base_allocator: std.mem.Allocator,
    context: *LuaAllocatorContext,
    state: lua.LuaState,

    pub fn init(base_allocator: std.mem.Allocator, memory_limit: usize) !TrackedLuaAllocator {
        const state = try createLuaStateWithAllocator(base_allocator, memory_limit, true);
        const context = getAllocatorContext(state).?;

        return TrackedLuaAllocator{
            .base_allocator = base_allocator,
            .context = context,
            .state = state,
        };
    }

    pub fn deinit(self: *TrackedLuaAllocator) void {
        closeLuaStateWithAllocator(self.state);
    }

    pub fn getStats(self: *TrackedLuaAllocator) AllocationStats {
        return self.context.getStats();
    }

    pub fn logStats(self: *TrackedLuaAllocator) void {
        const stats = self.getStats();
        std.log.info("Lua Memory Stats:", .{});
        std.log.info("  Total allocated: {} bytes", .{stats.total_allocated});
        std.log.info("  Peak allocated: {} bytes", .{stats.peak_allocated});
        std.log.info("  Allocations: {}", .{stats.allocation_count});
        std.log.info("  Deallocations: {}", .{stats.deallocation_count});
        std.log.info("  Reallocations: {}", .{stats.reallocation_count});
        std.log.info("  Failed allocations: {}", .{stats.failed_allocations});
    }
};

// Tests
test "Lua allocator integration" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    // Test basic allocation
    const state = try createLuaStateWithAllocator(allocator, 1024 * 1024, true); // 1MB limit
    defer closeLuaStateWithAllocator(state);

    const context = getAllocatorContext(state).?;

    // Initial stats should be zero (or small due to Lua internals)
    const initial_stats = context.getStats();
    try std.testing.expect(initial_stats.total_allocated > 0); // Lua allocates some memory on startup

    // Run some Lua code to trigger allocations
    const result = lua.c.luaL_dostring(state, "local t = {} for i = 1, 100 do t[i] = i end return #t");
    try std.testing.expectEqual(@as(c_int, 0), result);

    // Check that allocations increased
    const final_stats = context.getStats();
    try std.testing.expect(final_stats.allocation_count > initial_stats.allocation_count);
    try std.testing.expect(final_stats.total_allocated >= initial_stats.total_allocated);
}

test "Memory limit enforcement" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    // Create state with very small memory limit
    const state = try createLuaStateWithAllocator(allocator, 1024, false); // 1KB limit
    defer closeLuaStateWithAllocator(state);

    // Try to allocate beyond the limit
    const result = lua.c.luaL_dostring(state,
        \\local t = {}
        \\for i = 1, 10000 do
        \\    t[i] = string.rep("x", 1000)
        \\end
    );

    // Should fail with memory error
    try std.testing.expect(result != 0);

    const context = getAllocatorContext(state).?;
    const stats = context.getStats();
    try std.testing.expect(stats.failed_allocations > 0);
}
