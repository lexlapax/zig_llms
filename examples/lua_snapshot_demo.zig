// ABOUTME: Demonstrates Lua state snapshot and rollback capabilities
// ABOUTME: Shows state preservation, restoration, and versioning

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const LuaEngine = @import("zig_llms").scripting.engines.LuaEngine;
const ManagedLuaState = @import("zig_llms").scripting.engines.lua_lifecycle.ManagedLuaState;
const EngineConfig = @import("zig_llms").scripting.EngineConfig;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua State Snapshot Demo ===\n\n", .{});

    // Create engine with snapshots enabled
    const config = EngineConfig{
        .enable_snapshots = true,
        .max_snapshots = 5,
        .max_snapshot_size_bytes = 10 * 1024 * 1024, // 10MB
    };

    const engine = try LuaEngine.create(allocator, config);
    defer engine.deinit();

    const context = try engine.createContext("snapshot_demo");
    defer engine.destroyContext(context);

    // Test 1: Basic snapshot and restore
    std.debug.print("1. Basic snapshot and restore:\n");

    // Set initial state
    try engine.loadScript(context,
        \\game_state = {
        \\    player = {
        \\        name = "Hero",
        \\        level = 1,
        \\        health = 100,
        \\        inventory = {"sword", "potion"}
        \\    },
        \\    score = 0,
        \\    checkpoint = "start"
        \\}
        \\
        \\function save_game()
        \\    return "Game saved at checkpoint: " .. game_state.checkpoint
        \\end
    , "initial_state");

    std.debug.print("  Initial state loaded\n", .{});

    // Create snapshot
    const lua_engine = @as(*LuaEngine, @ptrCast(@alignCast(engine.impl)));
    try lua_engine.createSnapshot(context);
    std.debug.print("  ✓ Snapshot 1 created\n", .{});

    // Modify state
    try engine.executeScript(context,
        \\game_state.player.level = 5
        \\game_state.player.health = 150
        \\game_state.score = 1000
        \\game_state.checkpoint = "boss_room"
        \\table.insert(game_state.player.inventory, "shield")
    );

    var result = try engine.executeScript(context,
        \\return string.format("Level: %d, Health: %d, Score: %d",
        \\    game_state.player.level,
        \\    game_state.player.health,
        \\    game_state.score)
    );
    defer result.deinit(allocator);

    std.debug.print("  Modified state: {s}\n", .{result.string});

    // Restore snapshot
    try lua_engine.restoreSnapshot(context, 0);
    std.debug.print("  ✓ Restored to snapshot 1\n", .{});

    // Verify restoration
    result = try engine.executeScript(context,
        \\return string.format("Level: %d, Health: %d, Score: %d",
        \\    game_state.player.level,
        \\    game_state.player.health,
        \\    game_state.score)
    );
    defer result.deinit(allocator);

    std.debug.print("  Restored state: {s}\n", .{result.string});

    // Test 2: Multiple snapshots
    std.debug.print("\n2. Multiple snapshots (save points):\n");

    // Checkpoint 1
    try engine.executeScript(context, "game_state.checkpoint = 'forest'");
    try lua_engine.createSnapshot(context);
    std.debug.print("  ✓ Checkpoint 1: forest\n", .{});

    // Checkpoint 2
    try engine.executeScript(context,
        \\game_state.checkpoint = 'castle'
        \\game_state.player.level = 10
        \\game_state.score = 5000
    );
    try lua_engine.createSnapshot(context);
    std.debug.print("  ✓ Checkpoint 2: castle\n", .{});

    // Checkpoint 3
    try engine.executeScript(context,
        \\game_state.checkpoint = 'final_boss'
        \\game_state.player.level = 20
        \\game_state.score = 10000
    );
    try lua_engine.createSnapshot(context);
    std.debug.print("  ✓ Checkpoint 3: final_boss\n", .{});

    // Show current state
    result = try engine.executeScript(context, "return game_state.checkpoint");
    defer result.deinit(allocator);
    std.debug.print("  Current checkpoint: {s}\n", .{result.string});

    // Restore to checkpoint 2
    try lua_engine.restoreSnapshot(context, 2);
    result = try engine.executeScript(context, "return game_state.checkpoint");
    defer result.deinit(allocator);
    std.debug.print("  ✓ Restored to checkpoint 2: {s}\n", .{result.string});

    // Test 3: Snapshot with complex data
    std.debug.print("\n3. Complex data preservation:\n");

    try engine.executeScript(context,
        \\-- Complex nested structures
        \\complex_data = {
        \\    functions = {
        \\        greet = function(name) return "Hello, " .. name end,
        \\        calc = function(a, b) return a + b end
        \\    },
        \\    coroutines = {},
        \\    metatables = {}
        \\}
        \\
        \\-- Create coroutine
        \\complex_data.coroutines.counter = coroutine.create(function()
        \\    for i = 1, 10 do
        \\        coroutine.yield(i)
        \\    end
        \\end)
        \\
        \\-- Create metatable
        \\local mt = {
        \\    __add = function(a, b)
        \\        return {value = a.value + b.value}
        \\    end,
        \\    __tostring = function(t)
        \\        return "Value: " .. t.value
        \\    end
        \\}
        \\complex_data.metatables.obj1 = setmetatable({value = 10}, mt)
        \\complex_data.metatables.obj2 = setmetatable({value = 20}, mt)
    );

    // Resume coroutine a few times
    for (0..3) |_| {
        _ = try engine.executeScript(context,
            \\local ok, val = coroutine.resume(complex_data.coroutines.counter)
        );
    }

    result = try engine.executeScript(context,
        \\local ok, val = coroutine.resume(complex_data.coroutines.counter)
        \\return val or "finished"
    );
    defer result.deinit(allocator);
    std.debug.print("  Coroutine value before snapshot: {d}\n", .{result.integer});

    // Create snapshot
    try lua_engine.createSnapshot(context);
    std.debug.print("  ✓ Snapshot created with complex data\n", .{});

    // Continue coroutine
    for (0..3) |_| {
        _ = try engine.executeScript(context,
            \\local ok, val = coroutine.resume(complex_data.coroutines.counter)
        );
    }

    result = try engine.executeScript(context,
        \\local ok, val = coroutine.resume(complex_data.coroutines.counter)
        \\return val or "finished"
    );
    defer result.deinit(allocator);
    std.debug.print("  Coroutine value after progress: ");
    if (result == .integer) {
        std.debug.print("{d}\n", .{result.integer});
    } else {
        std.debug.print("{s}\n", .{result.string});
    }

    // Note: Functions and coroutines cannot be fully serialized
    std.debug.print("  Note: Functions and coroutines are not fully preserved\n", .{});

    // Test 4: Snapshot management
    std.debug.print("\n4. Snapshot management:\n");

    // Get snapshot stats using direct access to ManagedLuaState
    const lua_context = @as(*@import("zig_llms").scripting.engines.lua_engine.LuaContext, @ptrCast(@alignCast(context.engine_context)));
    const managed_state = lua_context.managed_state;

    const snapshot_count = managed_state.getSnapshotCount();
    std.debug.print("  Total snapshots: {d}\n", .{snapshot_count});

    // List snapshots if using new snapshot manager
    if (managed_state.snapshot_manager != null) {
        const snapshots = try managed_state.listSnapshots();
        defer {
            for (snapshots) |*s| s.deinit(allocator);
            allocator.free(snapshots);
        }

        std.debug.print("  Snapshot details:\n", .{});
        for (snapshots, 0..) |snapshot, i| {
            std.debug.print("    [{d}] ID: {s}, Size: {d} bytes\n", .{
                i,
                snapshot.id,
                snapshot.size_bytes,
            });
        }
    }

    // Test 5: Error handling
    std.debug.print("\n5. Error handling:\n");

    // Try to restore non-existent snapshot
    lua_engine.restoreSnapshot(context, 999) catch |err| {
        std.debug.print("  ✓ Correctly caught error: {}\n", .{err});
    };

    // Memory usage
    const memory_usage = engine.getMemoryUsage(context);
    std.debug.print("\n6. Resource usage:\n", .{});
    std.debug.print("  Current memory usage: {d} bytes\n", .{memory_usage});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey features demonstrated:\n", .{});
    std.debug.print("- State preservation and restoration\n", .{});
    std.debug.print("- Multiple checkpoint management\n", .{});
    std.debug.print("- Complex data structure handling\n", .{});
    std.debug.print("- Snapshot lifecycle management\n", .{});
    std.debug.print("- Error handling and resource tracking\n", .{});
}
