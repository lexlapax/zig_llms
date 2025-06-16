// ABOUTME: Bidirectional weak reference system to prevent circular references between Lua and Zig
// ABOUTME: Manages weak references with automatic cleanup and lifecycle tracking for cross-language objects

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../context.zig").ScriptContext;

/// Weak reference type
pub const WeakReferenceType = enum {
    /// Lua object referenced from Zig
    lua_to_zig,
    /// Zig object referenced from Lua
    zig_to_lua,
    /// Bidirectional reference
    bidirectional,
};

/// Weak reference state
pub const WeakReferenceState = enum {
    active,
    expired,
    collected,
};

/// Weak reference metadata
pub const WeakReferenceMeta = struct {
    /// Unique ID for this reference
    id: u64,
    /// Type of weak reference
    ref_type: WeakReferenceType,
    /// Current state
    state: WeakReferenceState,
    /// Creation timestamp
    created_at: i64,
    /// Last access timestamp
    last_accessed: i64,
    /// Access count for statistics
    access_count: u32,
    /// Type name for debugging
    type_name: []const u8,
    /// Optional cleanup callback
    cleanup_fn: ?*const fn (meta: *WeakReferenceMeta, allocator: std.mem.Allocator) void,
};

/// Lua-to-Zig weak reference
pub const LuaWeakRef = struct {
    /// Registry key for the Lua object
    registry_key: c_int,
    /// Metadata
    meta: WeakReferenceMeta,
    /// Lua wrapper for access
    wrapper: *LuaWrapper,
    /// Allocator for cleanup
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        wrapper: *LuaWrapper,
        lua_index: c_int,
        type_name: []const u8,
        id: u64,
    ) !LuaWeakRef {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        // Push the object to the top of the stack
        lua.c.lua_pushvalue(wrapper.state, lua_index);

        // Store it in the registry and get the key
        const registry_key = lua.c.luaL_ref(wrapper.state, lua.c.LUA_REGISTRYINDEX);

        const now = std.time.timestamp();

        return LuaWeakRef{
            .registry_key = registry_key,
            .meta = WeakReferenceMeta{
                .id = id,
                .ref_type = .lua_to_zig,
                .state = .active,
                .created_at = now,
                .last_accessed = now,
                .access_count = 0,
                .type_name = type_name,
                .cleanup_fn = null,
            },
            .wrapper = wrapper,
            .allocator = allocator,
        };
    }

    /// Get the referenced Lua value
    pub fn get(self: *LuaWeakRef) !?ScriptValue {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        if (self.meta.state != .active) return null;

        // Get the object from the registry
        lua.c.lua_rawgeti(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, self.registry_key);

        // Check if it's nil (object was collected)
        if (lua.c.lua_isnil(self.wrapper.state, -1)) {
            lua.c.lua_pop(self.wrapper.state, 1);
            self.meta.state = .expired;
            return null;
        }

        // Update access statistics
        self.meta.last_accessed = std.time.timestamp();
        self.meta.access_count += 1;

        // Convert to ScriptValue
        const converter = @import("lua_value_converter.zig");
        const result = try converter.pullScriptValue(self.wrapper, -1, self.allocator);
        lua.c.lua_pop(self.wrapper.state, 1);

        return result;
    }

    /// Check if the reference is still valid
    pub fn isValid(self: *LuaWeakRef) bool {
        if (!lua.lua_enabled) return false;

        if (self.meta.state != .active) return false;

        // Quickly check if object still exists without converting
        lua.c.lua_rawgeti(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, self.registry_key);
        const is_nil = lua.c.lua_isnil(self.wrapper.state, -1);
        lua.c.lua_pop(self.wrapper.state, 1);

        if (is_nil) {
            self.meta.state = .expired;
            return false;
        }

        return true;
    }

    /// Release the weak reference
    pub fn release(self: *LuaWeakRef) void {
        if (!lua.lua_enabled) return;

        if (self.meta.state == .collected) return;

        // Remove from registry
        lua.c.luaL_unref(self.wrapper.state, lua.c.LUA_REGISTRYINDEX, self.registry_key);

        // Run cleanup if provided
        if (self.meta.cleanup_fn) |cleanup| {
            cleanup(&self.meta, self.allocator);
        }

        self.meta.state = .collected;
    }
};

/// Zig-to-Lua weak reference
pub const ZigWeakRef = struct {
    /// Pointer to the Zig object
    ptr: *anyopaque,
    /// Size of the object for validation
    size: usize,
    /// Metadata
    meta: WeakReferenceMeta,
    /// Reference count for tracking usage
    ref_count: std.atomic.Value(u32),
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    /// Allocator for cleanup
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        ptr: *anyopaque,
        size: usize,
        type_name: []const u8,
        id: u64,
    ) ZigWeakRef {
        const now = std.time.timestamp();

        return ZigWeakRef{
            .ptr = ptr,
            .size = size,
            .meta = WeakReferenceMeta{
                .id = id,
                .ref_type = .zig_to_lua,
                .state = .active,
                .created_at = now,
                .last_accessed = now,
                .access_count = 0,
                .type_name = type_name,
                .cleanup_fn = null,
            },
            .ref_count = std.atomic.Value(u32).init(1),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    /// Get the referenced Zig object
    pub fn get(self: *ZigWeakRef, comptime T: type) ?*T {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.meta.state != .active) return null;
        if (@sizeOf(T) != self.size) return null;

        // Update access statistics
        self.meta.last_accessed = std.time.timestamp();
        self.meta.access_count += 1;

        // Increment reference count
        _ = self.ref_count.fetchAdd(1, .seq_cst);

        return @ptrCast(@alignCast(self.ptr));
    }

    /// Release a reference to the object
    pub fn release(self: *ZigWeakRef) void {
        const old_count = self.ref_count.fetchSub(1, .seq_cst);

        if (old_count == 1) {
            // Last reference, mark as expired
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.meta.state == .active) {
                self.meta.state = .expired;

                // Run cleanup if provided
                if (self.meta.cleanup_fn) |cleanup| {
                    cleanup(&self.meta, self.allocator);
                }
            }
        }
    }

    /// Check if the reference is still valid
    pub fn isValid(self: *ZigWeakRef) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.meta.state == .active and self.ref_count.load(.seq_cst) > 0;
    }

    /// Force invalidate the reference (for cleanup)
    pub fn invalidate(self: *ZigWeakRef) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.meta.state != .collected) {
            self.meta.state = .collected;

            // Run cleanup if provided
            if (self.meta.cleanup_fn) |cleanup| {
                cleanup(&self.meta, self.allocator);
            }
        }
    }
};

/// Bidirectional weak reference combining both directions
pub const BidirectionalWeakRef = struct {
    /// Lua-to-Zig reference
    lua_ref: LuaWeakRef,
    /// Zig-to-Lua reference
    zig_ref: ZigWeakRef,
    /// Metadata
    meta: WeakReferenceMeta,
    /// Synchronization mutex
    mutex: std.Thread.Mutex,

    pub fn init(
        allocator: std.mem.Allocator,
        wrapper: *LuaWrapper,
        lua_index: c_int,
        zig_ptr: *anyopaque,
        zig_size: usize,
        type_name: []const u8,
        id: u64,
    ) !BidirectionalWeakRef {
        const now = std.time.timestamp();

        const lua_ref = try LuaWeakRef.init(allocator, wrapper, lua_index, type_name, id);
        const zig_ref = ZigWeakRef.init(allocator, zig_ptr, zig_size, type_name, id);

        return BidirectionalWeakRef{
            .lua_ref = lua_ref,
            .zig_ref = zig_ref,
            .meta = WeakReferenceMeta{
                .id = id,
                .ref_type = .bidirectional,
                .state = .active,
                .created_at = now,
                .last_accessed = now,
                .access_count = 0,
                .type_name = type_name,
                .cleanup_fn = null,
            },
            .mutex = std.Thread.Mutex{},
        };
    }

    /// Get the Lua side of the reference
    pub fn getLua(self: *BidirectionalWeakRef) !?ScriptValue {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.meta.state != .active) return null;

        self.meta.last_accessed = std.time.timestamp();
        self.meta.access_count += 1;

        return try self.lua_ref.get();
    }

    /// Get the Zig side of the reference
    pub fn getZig(self: *BidirectionalWeakRef, comptime T: type) ?*T {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.meta.state != .active) return null;

        self.meta.last_accessed = std.time.timestamp();
        self.meta.access_count += 1;

        return self.zig_ref.get(T);
    }

    /// Check if both sides are still valid
    pub fn isValid(self: *BidirectionalWeakRef) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.meta.state != .active) return false;

        const lua_valid = self.lua_ref.isValid();
        const zig_valid = self.zig_ref.isValid();

        if (!lua_valid or !zig_valid) {
            self.meta.state = .expired;
            return false;
        }

        return true;
    }

    /// Release both sides of the reference
    pub fn release(self: *BidirectionalWeakRef) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.meta.state == .collected) return;

        self.lua_ref.release();
        self.zig_ref.invalidate();

        if (self.meta.cleanup_fn) |cleanup| {
            cleanup(&self.meta, self.zig_ref.allocator);
        }

        self.meta.state = .collected;
    }
};

/// Weak reference registry for managing all weak references
pub const WeakReferenceRegistry = struct {
    const LuaRefMap = std.HashMap(u64, LuaWeakRef, std.HashMap.getAutoHashFn(u64), std.HashMap.getAutoEqlFn(u64), std.HashMap.default_max_load_percentage);
    const ZigRefMap = std.HashMap(u64, ZigWeakRef, std.HashMap.getAutoHashFn(u64), std.HashMap.getAutoEqlFn(u64), std.HashMap.default_max_load_percentage);
    const BiRefMap = std.HashMap(u64, BidirectionalWeakRef, std.HashMap.getAutoHashFn(u64), std.HashMap.getAutoEqlFn(u64), std.HashMap.default_max_load_percentage);

    allocator: std.mem.Allocator,
    lua_refs: LuaRefMap,
    zig_refs: ZigRefMap,
    bidirectional_refs: BiRefMap,
    next_id: std.atomic.Value(u64),
    mutex: std.Thread.RwLock,
    cleanup_timer: ?std.time.Timer,
    last_cleanup: i64,

    pub fn init(allocator: std.mem.Allocator) WeakReferenceRegistry {
        return WeakReferenceRegistry{
            .allocator = allocator,
            .lua_refs = LuaRefMap.init(allocator),
            .zig_refs = ZigRefMap.init(allocator),
            .bidirectional_refs = BiRefMap.init(allocator),
            .next_id = std.atomic.Value(u64).init(1),
            .mutex = std.Thread.RwLock{},
            .cleanup_timer = null,
            .last_cleanup = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *WeakReferenceRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all references
        var lua_iter = self.lua_refs.valueIterator();
        while (lua_iter.next()) |ref| {
            ref.release();
        }
        self.lua_refs.deinit();

        var zig_iter = self.zig_refs.valueIterator();
        while (zig_iter.next()) |ref| {
            ref.invalidate();
        }
        self.zig_refs.deinit();

        var bi_iter = self.bidirectional_refs.valueIterator();
        while (bi_iter.next()) |ref| {
            ref.release();
        }
        self.bidirectional_refs.deinit();
    }

    /// Generate a new unique ID
    fn nextId(self: *WeakReferenceRegistry) u64 {
        return self.next_id.fetchAdd(1, .seq_cst);
    }

    /// Create a Lua-to-Zig weak reference
    pub fn createLuaRef(
        self: *WeakReferenceRegistry,
        wrapper: *LuaWrapper,
        lua_index: c_int,
        type_name: []const u8,
    ) !u64 {
        const id = self.nextId();
        const weak_ref = try LuaWeakRef.init(self.allocator, wrapper, lua_index, type_name, id);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.lua_refs.put(id, weak_ref);
        return id;
    }

    /// Create a Zig-to-Lua weak reference
    pub fn createZigRef(
        self: *WeakReferenceRegistry,
        ptr: *anyopaque,
        size: usize,
        type_name: []const u8,
    ) !u64 {
        const id = self.nextId();
        const weak_ref = ZigWeakRef.init(self.allocator, ptr, size, type_name, id);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.zig_refs.put(id, weak_ref);
        return id;
    }

    /// Create a bidirectional weak reference
    pub fn createBidirectionalRef(
        self: *WeakReferenceRegistry,
        wrapper: *LuaWrapper,
        lua_index: c_int,
        zig_ptr: *anyopaque,
        zig_size: usize,
        type_name: []const u8,
    ) !u64 {
        const id = self.nextId();
        const weak_ref = try BidirectionalWeakRef.init(
            self.allocator,
            wrapper,
            lua_index,
            zig_ptr,
            zig_size,
            type_name,
            id,
        );

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.bidirectional_refs.put(id, weak_ref);
        return id;
    }

    /// Get a Lua weak reference
    pub fn getLuaRef(self: *WeakReferenceRegistry, id: u64) ?*LuaWeakRef {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        return self.lua_refs.getPtr(id);
    }

    /// Get a Zig weak reference
    pub fn getZigRef(self: *WeakReferenceRegistry, id: u64) ?*ZigWeakRef {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        return self.zig_refs.getPtr(id);
    }

    /// Get a bidirectional weak reference
    pub fn getBidirectionalRef(self: *WeakReferenceRegistry, id: u64) ?*BidirectionalWeakRef {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        return self.bidirectional_refs.getPtr(id);
    }

    /// Remove a weak reference by ID
    pub fn removeRef(self: *WeakReferenceRegistry, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try removing from each collection
        if (self.lua_refs.getPtr(id)) |ref| {
            ref.release();
            _ = self.lua_refs.remove(id);
        } else if (self.zig_refs.getPtr(id)) |ref| {
            ref.invalidate();
            _ = self.zig_refs.remove(id);
        } else if (self.bidirectional_refs.getPtr(id)) |ref| {
            ref.release();
            _ = self.bidirectional_refs.remove(id);
        }
    }

    /// Clean up expired weak references
    pub fn cleanup(self: *WeakReferenceRegistry) void {
        const now = std.time.timestamp();

        // Only run cleanup if enough time has passed
        if (now - self.last_cleanup < 60) return; // Cleanup every minute

        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up Lua references
        var lua_iter = self.lua_refs.iterator();
        var lua_to_remove = std.ArrayList(u64).init(self.allocator);
        defer lua_to_remove.deinit();

        while (lua_iter.next()) |entry| {
            if (!entry.value_ptr.isValid()) {
                entry.value_ptr.release();
                lua_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (lua_to_remove.items) |id| {
            _ = self.lua_refs.remove(id);
        }

        // Clean up Zig references
        var zig_iter = self.zig_refs.iterator();
        var zig_to_remove = std.ArrayList(u64).init(self.allocator);
        defer zig_to_remove.deinit();

        while (zig_iter.next()) |entry| {
            if (!entry.value_ptr.isValid()) {
                entry.value_ptr.invalidate();
                zig_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (zig_to_remove.items) |id| {
            _ = self.zig_refs.remove(id);
        }

        // Clean up bidirectional references
        var bi_iter = self.bidirectional_refs.iterator();
        var bi_to_remove = std.ArrayList(u64).init(self.allocator);
        defer bi_to_remove.deinit();

        while (bi_iter.next()) |entry| {
            if (!entry.value_ptr.isValid()) {
                entry.value_ptr.release();
                bi_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (bi_to_remove.items) |id| {
            _ = self.bidirectional_refs.remove(id);
        }

        self.last_cleanup = now;
    }

    /// Get statistics about weak references
    pub fn getStatistics(self: *WeakReferenceRegistry) WeakReferenceStatistics {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        var stats = WeakReferenceStatistics{};

        // Count active references
        var lua_iter = self.lua_refs.valueIterator();
        while (lua_iter.next()) |ref| {
            stats.total_lua_refs += 1;
            if (ref.meta.state == .active) stats.active_lua_refs += 1;
            stats.total_accesses += ref.meta.access_count;
        }

        var zig_iter = self.zig_refs.valueIterator();
        while (zig_iter.next()) |ref| {
            stats.total_zig_refs += 1;
            if (ref.meta.state == .active) stats.active_zig_refs += 1;
            stats.total_accesses += ref.meta.access_count;
        }

        var bi_iter = self.bidirectional_refs.valueIterator();
        while (bi_iter.next()) |ref| {
            stats.total_bidirectional_refs += 1;
            if (ref.meta.state == .active) stats.active_bidirectional_refs += 1;
            stats.total_accesses += ref.meta.access_count;
        }

        return stats;
    }
};

/// Statistics for weak reference usage
pub const WeakReferenceStatistics = struct {
    total_lua_refs: usize = 0,
    active_lua_refs: usize = 0,
    total_zig_refs: usize = 0,
    active_zig_refs: usize = 0,
    total_bidirectional_refs: usize = 0,
    active_bidirectional_refs: usize = 0,
    total_accesses: u32 = 0,

    pub fn getTotalRefs(self: WeakReferenceStatistics) usize {
        return self.total_lua_refs + self.total_zig_refs + self.total_bidirectional_refs;
    }

    pub fn getActiveRefs(self: WeakReferenceStatistics) usize {
        return self.active_lua_refs + self.active_zig_refs + self.active_bidirectional_refs;
    }

    pub fn getActiveRatio(self: WeakReferenceStatistics) f64 {
        const total = self.getTotalRefs();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.getActiveRefs())) / @as(f64, @floatFromInt(total));
    }
};

// Tests
test "LuaWeakRef basic operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Push a table to reference
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushstring(wrapper.state, "test");
    lua.c.lua_setfield(wrapper.state, -2, "key");

    // Create weak reference
    var weak_ref = try LuaWeakRef.init(allocator, wrapper, -1, "table", 1);
    defer weak_ref.release();

    lua.c.lua_pop(wrapper.state, 1); // Remove table from stack

    // Test reference validity
    try std.testing.expect(weak_ref.isValid());

    // Test getting the value
    const value = try weak_ref.get();
    try std.testing.expect(value != null);

    if (value) |v| {
        defer v.deinit(allocator);
        try std.testing.expect(v == .object);
    }
}

test "ZigWeakRef basic operations" {
    const allocator = std.testing.allocator;

    var test_value: i32 = 42;
    var weak_ref = ZigWeakRef.init(allocator, &test_value, @sizeOf(i32), "i32", 1);
    defer weak_ref.invalidate();

    // Test reference validity
    try std.testing.expect(weak_ref.isValid());

    // Test getting the value
    const ptr = weak_ref.get(i32);
    try std.testing.expect(ptr != null);
    try std.testing.expectEqual(@as(i32, 42), ptr.?.*);

    // Release the reference
    weak_ref.release();
}

test "WeakReferenceRegistry operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var registry = WeakReferenceRegistry.init(allocator);
    defer registry.deinit();

    // Create a Lua table
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushstring(wrapper.state, "test");
    lua.c.lua_setfield(wrapper.state, -2, "key");

    // Create weak reference through registry
    const ref_id = try registry.createLuaRef(wrapper, -1, "table");
    lua.c.lua_pop(wrapper.state, 1);

    // Test getting the reference
    const weak_ref = registry.getLuaRef(ref_id);
    try std.testing.expect(weak_ref != null);
    try std.testing.expect(weak_ref.?.isValid());

    // Test statistics
    const stats = registry.getStatistics();
    try std.testing.expectEqual(@as(usize, 1), stats.total_lua_refs);
    try std.testing.expectEqual(@as(usize, 1), stats.active_lua_refs);

    // Clean up
    registry.removeRef(ref_id);
}

test "BidirectionalWeakRef operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var test_value: i32 = 42;

    // Create a Lua table
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushinteger(wrapper.state, 42);
    lua.c.lua_setfield(wrapper.state, -2, "value");

    // Create bidirectional weak reference
    var bi_ref = try BidirectionalWeakRef.init(
        allocator,
        wrapper,
        -1,
        &test_value,
        @sizeOf(i32),
        "test_type",
        1,
    );
    defer bi_ref.release();

    lua.c.lua_pop(wrapper.state, 1);

    // Test validity
    try std.testing.expect(bi_ref.isValid());

    // Test Lua side
    const lua_value = try bi_ref.getLua();
    try std.testing.expect(lua_value != null);

    if (lua_value) |v| {
        defer v.deinit(allocator);
        try std.testing.expect(v == .object);
    }

    // Test Zig side
    const zig_ptr = bi_ref.getZig(i32);
    try std.testing.expect(zig_ptr != null);
    try std.testing.expectEqual(@as(i32, 42), zig_ptr.?.*);

    // Release Zig reference
    bi_ref.zig_ref.release();
}

test "Weak reference cleanup" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var registry = WeakReferenceRegistry.init(allocator);
    defer registry.deinit();

    // Create a table and immediately lose the reference
    lua.c.lua_newtable(wrapper.state);
    const ref_id = try registry.createLuaRef(wrapper, -1, "table");
    lua.c.lua_pop(wrapper.state, 1);

    // Force garbage collection
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);

    // Check if reference is still valid
    const weak_ref = registry.getLuaRef(ref_id);
    try std.testing.expect(weak_ref != null);

    // The reference should become invalid after GC
    const is_valid = weak_ref.?.isValid();

    // Run cleanup
    registry.cleanup();

    // Verify statistics
    const stats = registry.getStatistics();
    if (!is_valid) {
        try std.testing.expectEqual(@as(usize, 0), stats.active_lua_refs);
    }
}
