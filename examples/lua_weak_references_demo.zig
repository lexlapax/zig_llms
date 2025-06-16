// ABOUTME: Demonstrates bidirectional weak reference system to prevent circular references
// ABOUTME: Shows memory management, lifecycle tracking, and automatic cleanup for cross-language objects

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const WeakReferences = @import("zig_llms").scripting.engines.lua_weak_references;
const WeakReferenceRegistry = WeakReferences.WeakReferenceRegistry;
const LuaWeakRef = WeakReferences.LuaWeakRef;
const ZigWeakRef = WeakReferences.ZigWeakRef;
const BidirectionalWeakRef = WeakReferences.BidirectionalWeakRef;
const WeakReferenceType = WeakReferences.WeakReferenceType;
const WeakReferenceState = WeakReferences.WeakReferenceState;

// Example complex structure for demonstration
const ComplexObject = struct {
    id: u64,
    name: [64]u8,
    value: f64,
    metadata: struct {
        created_at: i64,
        access_count: u32,
        tags: [8][16]u8,
    },

    pub fn init(id: u64, name: []const u8, value: f64) ComplexObject {
        var obj = ComplexObject{
            .id = id,
            .name = std.mem.zeroes([64]u8),
            .value = value,
            .metadata = .{
                .created_at = std.time.timestamp(),
                .access_count = 0,
                .tags = std.mem.zeroes([8][16]u8),
            },
        };

        @memcpy(obj.name[0..@min(name.len, 63)], name[0..@min(name.len, 63)]);
        return obj;
    }

    pub fn getName(self: *const ComplexObject) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn access(self: *ComplexObject) void {
        self.metadata.access_count += 1;
    }
};

// Custom cleanup function
fn customCleanup(meta: *WeakReferences.WeakReferenceMeta, allocator: std.mem.Allocator) void {
    _ = allocator;
    std.debug.print("    Custom cleanup called for reference {} ({})\n", .{ meta.id, meta.type_name });
}

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Denable-lua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Weak Reference System Demo ===\n\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var registry = WeakReferenceRegistry.init(allocator);
    defer registry.deinit();

    // Test 1: Basic Lua-to-Zig weak references
    std.debug.print("1. Basic Lua-to-Zig weak references:\n", .{});

    // Create several Lua objects
    const lua_objects = [_]struct {
        name: []const u8,
        script: []const u8,
    }{
        .{ .name = "Table", .script = "return {x = 10, y = 20, name = 'test'}" },
        .{ .name = "Function", .script = "return function(a, b) return a + b end" },
        .{ .name = "String", .script = "return 'Hello, weak references!'" },
        .{ .name = "Number", .script = "return 42.5" },
    };

    var lua_ref_ids = std.ArrayList(u64).init(allocator);
    defer lua_ref_ids.deinit();

    for (lua_objects, 0..) |obj, i| {
        // Execute script to create object
        const result = lua.c.luaL_dostring(wrapper.state, obj.script.ptr);
        if (result != lua.c.LUA_OK) {
            std.debug.print("  Error creating {s}: {s}\n", .{ obj.name, lua.c.lua_tostring(wrapper.state, -1) });
            lua.c.lua_pop(wrapper.state, 1);
            continue;
        }

        // Create weak reference
        const ref_id = try registry.createLuaRef(wrapper, -1, obj.name);
        try lua_ref_ids.append(ref_id);

        lua.c.lua_pop(wrapper.state, 1); // Remove object from stack

        std.debug.print("  ✓ Created weak reference {} for {s}\n", .{ ref_id, obj.name });

        // Test immediate access
        if (registry.getLuaRef(ref_id)) |weak_ref| {
            if (try weak_ref.get()) |value| {
                defer value.deinit(allocator);
                std.debug.print("    Immediate access successful: {s}\n", .{@tagName(value)});
            }
        }

        // Simulate some delay
        std.time.sleep(1000000); // 1ms
        _ = i;
    }

    // Test 2: Zig-to-Lua weak references
    std.debug.print("\n2. Zig-to-Lua weak references:\n", .{});

    var complex_objects = std.ArrayList(ComplexObject).init(allocator);
    defer complex_objects.deinit();

    var zig_ref_ids = std.ArrayList(u64).init(allocator);
    defer zig_ref_ids.deinit();

    for (0..5) |i| {
        const name = try std.fmt.allocPrint(allocator, "Object_{}", .{i});
        defer allocator.free(name);

        const obj = ComplexObject.init(i, name, @as(f64, @floatFromInt(i)) * 10.5);
        try complex_objects.append(obj);

        // Create weak reference to the object
        const ref_id = try registry.createZigRef(
            &complex_objects.items[complex_objects.items.len - 1],
            @sizeOf(ComplexObject),
            "ComplexObject",
        );
        try zig_ref_ids.append(ref_id);

        std.debug.print("  ✓ Created weak reference {} for {s} (id: {})\n", .{ ref_id, obj.getName(), obj.id });

        // Test access and modification
        if (registry.getZigRef(ref_id)) |weak_ref| {
            if (weak_ref.get(ComplexObject)) |ptr| {
                defer weak_ref.release(); // Release the reference
                ptr.access();
                std.debug.print("    Access count: {}\n", .{ptr.metadata.access_count});
            }
        }
    }

    // Test 3: Bidirectional weak references
    std.debug.print("\n3. Bidirectional weak references:\n", .{});

    var bi_ref_ids = std.ArrayList(u64).init(allocator);
    defer bi_ref_ids.deinit();

    // Create pairs of Lua and Zig objects
    for (0..3) |i| {
        // Create Lua table
        lua.c.lua_newtable(wrapper.state);
        lua.c.lua_pushinteger(wrapper.state, @intCast(i));
        lua.c.lua_setfield(wrapper.state, -2, "id");
        lua.c.lua_pushnumber(wrapper.state, @as(f64, @floatFromInt(i)) * 3.14);
        lua.c.lua_setfield(wrapper.state, -2, "pi_factor");

        // Create corresponding Zig object
        const name = try std.fmt.allocPrint(allocator, "BiObject_{}", .{i});
        defer allocator.free(name);

        const obj = ComplexObject.init(100 + i, name, @as(f64, @floatFromInt(i)) * 3.14);
        try complex_objects.append(obj);

        // Create bidirectional weak reference
        const ref_id = try registry.createBidirectionalRef(
            wrapper,
            -1,
            &complex_objects.items[complex_objects.items.len - 1],
            @sizeOf(ComplexObject),
            "BiDirectionalObject",
        );
        try bi_ref_ids.append(ref_id);

        lua.c.lua_pop(wrapper.state, 1); // Remove Lua table from stack

        std.debug.print("  ✓ Created bidirectional reference {} for pair {}\n", .{ ref_id, i });

        // Test both sides
        if (registry.getBidirectionalRef(ref_id)) |bi_ref| {
            // Test Lua side
            if (try bi_ref.getLua()) |lua_value| {
                defer lua_value.deinit(allocator);
                std.debug.print("    Lua side: {s}\n", .{@tagName(lua_value)});
            }

            // Test Zig side
            if (bi_ref.getZig(ComplexObject)) |zig_ptr| {
                defer bi_ref.zig_ref.release();
                std.debug.print("    Zig side: {s} (id: {})\n", .{ zig_ptr.getName(), zig_ptr.id });
            }
        }
    }

    // Test 4: Reference validation and lifecycle
    std.debug.print("\n4. Reference validation and lifecycle:\n", .{});

    std.debug.print("  Initial registry statistics:\n", .{});
    var stats = registry.getStatistics();
    std.debug.print("    Total references: {}\n", .{stats.getTotalRefs()});
    std.debug.print("    Active references: {}\n", .{stats.getActiveRefs()});
    std.debug.print("    Active ratio: {d:.1}%\n", .{stats.getActiveRatio() * 100.0});
    std.debug.print("    Total accesses: {}\n", .{stats.total_accesses});

    // Test reference validity
    std.debug.print("  Testing reference validity:\n", .{});
    for (lua_ref_ids.items, 0..) |ref_id, i| {
        if (registry.getLuaRef(ref_id)) |weak_ref| {
            const valid = weak_ref.isValid();
            std.debug.print("    Lua ref {} ({}): {s}\n", .{ ref_id, i, if (valid) "valid" else "invalid" });
        }
    }

    for (zig_ref_ids.items, 0..) |ref_id, i| {
        if (registry.getZigRef(ref_id)) |weak_ref| {
            const valid = weak_ref.isValid();
            std.debug.print("    Zig ref {} ({}): {s}\n", .{ ref_id, i, if (valid) "valid" else "invalid" });
        }
    }

    // Test 5: Garbage collection and cleanup
    std.debug.print("\n5. Garbage collection and cleanup:\n", .{});

    // Force Lua garbage collection
    std.debug.print("  Forcing Lua garbage collection...\n", .{});
    const gc_result = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    std.debug.print("    GC result: {} KB\n", .{gc_result});

    // Check reference validity after GC
    std.debug.print("  Checking Lua references after GC:\n", .{});
    for (lua_ref_ids.items, 0..) |ref_id, i| {
        if (registry.getLuaRef(ref_id)) |weak_ref| {
            const valid = weak_ref.isValid();
            std.debug.print("    Lua ref {} ({}): {s}\n", .{ ref_id, i, if (valid) "valid" else "invalid" });

            // Try to access the value
            if (try weak_ref.get()) |value| {
                defer value.deinit(allocator);
                std.debug.print("      Value still accessible: {s}\n", .{@tagName(value)});
            } else {
                std.debug.print("      Value no longer accessible\n", .{});
            }
        }
    }

    // Test 6: Manual cleanup and invalidation
    std.debug.print("\n6. Manual cleanup and invalidation:\n", .{});

    // Remove some Zig objects to test invalidation
    std.debug.print("  Manually invalidating some Zig references:\n", .{});
    for (zig_ref_ids.items[0..2], 0..) |ref_id, i| {
        if (registry.getZigRef(ref_id)) |weak_ref| {
            weak_ref.invalidate();
            std.debug.print("    Invalidated Zig ref {} ({})\n", .{ ref_id, i });
        }
    }

    // Test 7: Custom cleanup functions
    std.debug.print("\n7. Custom cleanup functions:\n", .{});

    // Create some references with custom cleanup
    lua.c.lua_pushstring(wrapper.state, "Test string for cleanup");
    const cleanup_ref = try LuaWeakRef.init(allocator, wrapper, -1, "CleanupTest", 999);
    var cleanup_ref_copy = cleanup_ref;
    cleanup_ref_copy.meta.cleanup_fn = customCleanup;
    lua.c.lua_pop(wrapper.state, 1);

    std.debug.print("  Created reference with custom cleanup function\n", .{});
    cleanup_ref_copy.release();
    std.debug.print("  Released reference (cleanup should have been called)\n", .{});

    // Test 8: Registry cleanup
    std.debug.print("\n8. Registry cleanup:\n", .{});

    std.debug.print("  Running registry cleanup...\n", .{});
    registry.cleanup();

    // Check final statistics
    stats = registry.getStatistics();
    std.debug.print("  Final registry statistics:\n", .{});
    std.debug.print("    Total references: {}\n", .{stats.getTotalRefs()});
    std.debug.print("    Active references: {}\n", .{stats.getActiveRefs()});
    std.debug.print("    Active ratio: {d:.1}%\n", .{stats.getActiveRatio() * 100.0});
    std.debug.print("    Lua refs: {} total, {} active\n", .{ stats.total_lua_refs, stats.active_lua_refs });
    std.debug.print("    Zig refs: {} total, {} active\n", .{ stats.total_zig_refs, stats.active_zig_refs });
    std.debug.print("    Bidirectional refs: {} total, {} active\n", .{ stats.total_bidirectional_refs, stats.active_bidirectional_refs });
    std.debug.print("    Total accesses: {}\n", .{stats.total_accesses});

    // Test 9: Performance testing
    std.debug.print("\n9. Performance testing:\n", .{});

    const num_iterations = 1000;
    var timer = try std.time.Timer.start();

    // Time weak reference creation
    timer.reset();
    var perf_ref_ids = std.ArrayList(u64).init(allocator);
    defer perf_ref_ids.deinit();

    for (0..num_iterations) |i| {
        lua.c.lua_pushinteger(wrapper.state, @intCast(i));
        const ref_id = try registry.createLuaRef(wrapper, -1, "PerfTest");
        try perf_ref_ids.append(ref_id);
        lua.c.lua_pop(wrapper.state, 1);
    }

    const creation_time = timer.lap();

    // Time weak reference access
    for (perf_ref_ids.items) |ref_id| {
        if (registry.getLuaRef(ref_id)) |weak_ref| {
            if (try weak_ref.get()) |value| {
                defer value.deinit(allocator);
                // Just access the value - verify it exists
                std.debug.assert(value == .integer or value == .string or value == .boolean or value == .number or value == .array or value == .object or value == .function or value == .userdata or value == .nil);
            }
        }
    }

    const access_time = timer.lap();

    // Time cleanup
    for (perf_ref_ids.items) |ref_id| {
        registry.removeRef(ref_id);
    }

    const cleanup_time = timer.read();

    std.debug.print("  Performance results ({} iterations):\n", .{num_iterations});
    std.debug.print("    Creation: {d}ms ({d}μs per ref)\n", .{
        @as(f64, @floatFromInt(creation_time)) / 1_000_000.0,
        @as(f64, @floatFromInt(creation_time)) / @as(f64, @floatFromInt(num_iterations)) / 1000.0,
    });
    std.debug.print("    Access:   {d}ms ({d}μs per ref)\n", .{
        @as(f64, @floatFromInt(access_time)) / 1_000_000.0,
        @as(f64, @floatFromInt(access_time)) / @as(f64, @floatFromInt(num_iterations)) / 1000.0,
    });
    std.debug.print("    Cleanup:  {d}ms ({d}μs per ref)\n", .{
        @as(f64, @floatFromInt(cleanup_time)) / 1_000_000.0,
        @as(f64, @floatFromInt(cleanup_time)) / @as(f64, @floatFromInt(num_iterations)) / 1000.0,
    });

    // Test 10: Memory safety validation
    std.debug.print("\n10. Memory safety validation:\n", .{});

    // Create references and let some expire naturally
    var temp_objects = std.ArrayList(ComplexObject).init(allocator);
    defer temp_objects.deinit();

    var temp_ref_ids = std.ArrayList(u64).init(allocator);
    defer temp_ref_ids.deinit();

    for (0..5) |i| {
        const obj = ComplexObject.init(1000 + i, "TempObject", @as(f64, @floatFromInt(i)));
        try temp_objects.append(obj);

        const ref_id = try registry.createZigRef(
            &temp_objects.items[temp_objects.items.len - 1],
            @sizeOf(ComplexObject),
            "TempObject",
        );
        try temp_ref_ids.append(ref_id);
    }

    std.debug.print("  Created {} temporary references\n", .{temp_objects.items.len});

    // Clear half the objects (simulating scope exit)
    const half = temp_objects.items.len / 2;
    for (temp_ref_ids.items[0..half]) |ref_id| {
        if (registry.getZigRef(ref_id)) |weak_ref| {
            weak_ref.invalidate();
        }
    }

    std.debug.print("  Invalidated {} references\n", .{half});

    // Test access to both valid and invalid references
    for (temp_ref_ids.items, 0..) |ref_id, i| {
        if (registry.getZigRef(ref_id)) |weak_ref| {
            if (weak_ref.get(ComplexObject)) |ptr| {
                defer weak_ref.release();
                std.debug.print("    Ref {} ({}): valid, value={d}\n", .{ ref_id, i, ptr.value });
            } else {
                std.debug.print("    Ref {} ({}): invalid/expired\n", .{ ref_id, i });
            }
        }
    }

    // Final cleanup
    for (temp_ref_ids.items) |ref_id| {
        registry.removeRef(ref_id);
    }

    // Final memory check
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    const final_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
    std.debug.print("  Final Lua memory: {} KB\n", .{final_memory});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey features demonstrated:\n", .{});
    std.debug.print("- Lua-to-Zig weak references with automatic expiration detection\n", .{});
    std.debug.print("- Zig-to-Lua weak references with thread-safe reference counting\n", .{});
    std.debug.print("- Bidirectional weak references for complex object relationships\n", .{});
    std.debug.print("- Automatic garbage collection integration and cleanup\n", .{});
    std.debug.print("- Registry-based management with statistics and monitoring\n", .{});
    std.debug.print("- Custom cleanup functions for resource management\n", .{});
    std.debug.print("- Performance optimization for high-frequency operations\n", .{});
    std.debug.print("- Memory safety validation and reference lifecycle tracking\n", .{});
}
