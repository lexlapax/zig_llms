// ABOUTME: lua_State snapshot system for rollback capabilities
// ABOUTME: Provides state serialization, restoration, and versioning

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const LuaError = lua.LuaError;

/// Snapshot error types
pub const SnapshotError = error{
    SnapshotNotFound,
    InvalidSnapshot,
    SerializationFailed,
    DeserializationFailed,
    UnsupportedType,
    CircularReference,
    SnapshotLimitExceeded,
    CorruptedData,
    IncompatibleVersion,
};

/// Snapshot metadata
pub const SnapshotMetadata = struct {
    id: []const u8,
    timestamp: i64,
    size_bytes: usize,
    checksum: u32,
    description: ?[]const u8,
    tags: std.StringHashMap([]const u8),
    parent_id: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, id: []const u8, description: ?[]const u8) !SnapshotMetadata {
        return SnapshotMetadata{
            .id = try allocator.dupe(u8, id),
            .timestamp = std.time.milliTimestamp(),
            .size_bytes = 0,
            .checksum = 0,
            .description = if (description) |desc| try allocator.dupe(u8, desc) else null,
            .tags = std.StringHashMap([]const u8).init(allocator),
            .parent_id = null,
        };
    }

    pub fn deinit(self: *SnapshotMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.description) |desc| {
            allocator.free(desc);
        }
        if (self.parent_id) |pid| {
            allocator.free(pid);
        }
        self.tags.deinit();
    }
};

/// Serialized value representation
pub const SerializedValue = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: SerializedTable,
    function: SerializedFunction,
    userdata: SerializedUserdata,
    thread: SerializedThread,

    pub const SerializedTable = struct {
        entries: std.ArrayList(TableEntry),
        metatable: ?*SerializedValue,

        pub const TableEntry = struct {
            key: *SerializedValue,
            value: *SerializedValue,
        };
    };

    pub const SerializedFunction = struct {
        bytecode: []const u8,
        upvalues: std.ArrayList(*SerializedValue),
        environment: ?*SerializedValue,
    };

    pub const SerializedUserdata = struct {
        type_name: []const u8,
        data: []const u8,
        metatable: ?*SerializedValue,
    };

    pub const SerializedThread = struct {
        status: ThreadStatus,
        stack: std.ArrayList(*SerializedValue),

        pub const ThreadStatus = enum {
            suspended,
            running,
            dead,
        };
    };

    pub fn deinit(self: *SerializedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .nil, .boolean, .number => {},
            .string => |s| allocator.free(s),
            .table => |*t| {
                for (t.entries.items) |entry| {
                    entry.key.deinit(allocator);
                    allocator.destroy(entry.key);
                    entry.value.deinit(allocator);
                    allocator.destroy(entry.value);
                }
                t.entries.deinit();
                if (t.metatable) |mt| {
                    mt.deinit(allocator);
                    allocator.destroy(mt);
                }
            },
            .function => |*f| {
                allocator.free(f.bytecode);
                for (f.upvalues.items) |uv| {
                    uv.deinit(allocator);
                    allocator.destroy(uv);
                }
                f.upvalues.deinit();
                if (f.environment) |env| {
                    env.deinit(allocator);
                    allocator.destroy(env);
                }
            },
            .userdata => |*u| {
                allocator.free(u.type_name);
                allocator.free(u.data);
                if (u.metatable) |mt| {
                    mt.deinit(allocator);
                    allocator.destroy(mt);
                }
            },
            .thread => |*t| {
                for (t.stack.items) |item| {
                    item.deinit(allocator);
                    allocator.destroy(item);
                }
                t.stack.deinit();
            },
        }
    }
};

/// Lua state snapshot
pub const StateSnapshot = struct {
    metadata: SnapshotMetadata,
    globals: SerializedValue,
    registry: SerializedValue,
    memory_usage: usize,
    gc_state: GCState,
    allocator: std.mem.Allocator,

    pub const GCState = struct {
        threshold: usize,
        debt: i32,
        step_size: usize,
        pause: u32,
        step_mul: u32,
    };

    pub fn init(allocator: std.mem.Allocator, metadata: SnapshotMetadata) !*StateSnapshot {
        const self = try allocator.create(StateSnapshot);
        self.* = StateSnapshot{
            .metadata = metadata,
            .globals = .nil,
            .registry = .nil,
            .memory_usage = 0,
            .gc_state = GCState{
                .threshold = 0,
                .debt = 0,
                .step_size = 0,
                .pause = 200,
                .step_mul = 200,
            },
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *StateSnapshot) void {
        self.metadata.deinit(self.allocator);
        self.globals.deinit(self.allocator);
        self.registry.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Snapshot serializer
pub const SnapshotSerializer = struct {
    wrapper: *LuaWrapper,
    allocator: std.mem.Allocator,
    visited_tables: std.AutoHashMap(usize, *SerializedValue),
    max_depth: usize,
    current_depth: usize,
    options: SerializationOptions,

    pub const SerializationOptions = struct {
        include_functions: bool = true,
        include_userdata: bool = false,
        include_threads: bool = false,
        include_metatables: bool = true,
        max_table_depth: usize = 100,
        max_string_length: usize = 1024 * 1024, // 1MB
        follow_upvalues: bool = true,
    };

    pub fn init(wrapper: *LuaWrapper, allocator: std.mem.Allocator, options: SerializationOptions) SnapshotSerializer {
        return SnapshotSerializer{
            .wrapper = wrapper,
            .allocator = allocator,
            .visited_tables = std.AutoHashMap(usize, *SerializedValue).init(allocator),
            .max_depth = options.max_table_depth,
            .current_depth = 0,
            .options = options,
        };
    }

    pub fn deinit(self: *SnapshotSerializer) void {
        self.visited_tables.deinit();
    }

    pub fn createSnapshot(self: *SnapshotSerializer, id: []const u8, description: ?[]const u8) !*StateSnapshot {
        const metadata = try SnapshotMetadata.init(self.allocator, id, description);
        const snapshot = try StateSnapshot.init(self.allocator, metadata);
        errdefer snapshot.deinit();

        // Clear visited tables for new snapshot
        self.visited_tables.clearRetainingCapacity();

        // Serialize globals
        lua.c.lua_pushglobaltable(self.wrapper.state);
        snapshot.globals = try self.serializeValue(-1);
        lua.c.lua_pop(self.wrapper.state, 1);

        // Serialize registry (selectively)
        lua.c.lua_pushvalue(self.wrapper.state, lua.c.LUA_REGISTRYINDEX);
        snapshot.registry = try self.serializeRegistryTable(-1);
        lua.c.lua_pop(self.wrapper.state, 1);

        // Capture GC state
        snapshot.gc_state = self.captureGCState();

        // Calculate memory usage
        const count_kb = lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCCOUNT, 0);
        const count_b = lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCCOUNTB, 0);
        snapshot.memory_usage = @as(usize, @intCast(count_kb)) * 1024 + @as(usize, @intCast(count_b));

        // Update metadata
        snapshot.metadata.size_bytes = self.calculateSnapshotSize(snapshot);
        snapshot.metadata.checksum = self.calculateChecksum(snapshot);

        return snapshot;
    }

    fn serializeValue(self: *SnapshotSerializer, index: i32) !SerializedValue {
        const lua_type = lua.c.lua_type(self.wrapper.state, index);

        switch (lua_type) {
            lua.c.LUA_TNIL => return .nil,

            lua.c.LUA_TBOOLEAN => {
                const value = lua.c.lua_toboolean(self.wrapper.state, index);
                return SerializedValue{ .boolean = value != 0 };
            },

            lua.c.LUA_TNUMBER => {
                const value = lua.c.lua_tonumber(self.wrapper.state, index);
                return SerializedValue{ .number = value };
            },

            lua.c.LUA_TSTRING => {
                var len: usize = 0;
                const str = lua.c.lua_tolstring(self.wrapper.state, index, &len);
                if (len > self.options.max_string_length) {
                    return SnapshotError.SerializationFailed;
                }
                const str_slice = str[0..len];
                const str_copy = try self.allocator.dupe(u8, str_slice);
                return SerializedValue{ .string = str_copy };
            },

            lua.c.LUA_TTABLE => {
                return try self.serializeTable(index);
            },

            lua.c.LUA_TFUNCTION => {
                if (!self.options.include_functions) {
                    return .nil;
                }
                return try self.serializeFunction(index);
            },

            lua.c.LUA_TUSERDATA => {
                if (!self.options.include_userdata) {
                    return .nil;
                }
                return try self.serializeUserdata(index);
            },

            lua.c.LUA_TTHREAD => {
                if (!self.options.include_threads) {
                    return .nil;
                }
                return try self.serializeThread(index);
            },

            else => return .nil,
        }
    }

    fn serializeTable(self: *SnapshotSerializer, index: i32) !SerializedValue {
        // Check for circular references
        const table_ptr = @as(usize, @intFromPtr(lua.c.lua_topointer(self.wrapper.state, index)));
        if (self.visited_tables.get(table_ptr)) |existing| {
            // Return reference to existing serialized table
            return SerializedValue{ .table = existing.table };
        }

        // Check depth limit
        if (self.current_depth >= self.max_depth) {
            return SnapshotError.SerializationFailed;
        }

        self.current_depth += 1;
        defer self.current_depth -= 1;

        // Create new serialized table
        var entries = std.ArrayList(SerializedValue.SerializedTable.TableEntry).init(self.allocator);
        errdefer {
            for (entries.items) |entry| {
                entry.key.deinit(self.allocator);
                self.allocator.destroy(entry.key);
                entry.value.deinit(self.allocator);
                self.allocator.destroy(entry.value);
            }
            entries.deinit();
        }

        // Create placeholder to handle circular references
        const result = try self.allocator.create(SerializedValue);
        result.* = SerializedValue{ .table = .{
            .entries = entries,
            .metatable = null,
        } };
        try self.visited_tables.put(table_ptr, result);

        // Serialize table entries
        lua.c.lua_pushnil(self.wrapper.state);
        while (lua.c.lua_next(self.wrapper.state, index - 1) != 0) {
            // key at -2, value at -1
            const key = try self.allocator.create(SerializedValue);
            key.* = try self.serializeValue(-2);

            const value = try self.allocator.create(SerializedValue);
            value.* = try self.serializeValue(-1);

            try result.table.entries.append(.{
                .key = key,
                .value = value,
            });

            lua.c.lua_pop(self.wrapper.state, 1); // Remove value, keep key
        }

        // Serialize metatable if enabled
        if (self.options.include_metatables) {
            if (lua.c.lua_getmetatable(self.wrapper.state, index) != 0) {
                const mt = try self.allocator.create(SerializedValue);
                mt.* = try self.serializeValue(-1);
                result.table.metatable = mt;
                lua.c.lua_pop(self.wrapper.state, 1);
            }
        }

        return result.*;
    }

    fn serializeFunction(self: *SnapshotSerializer, index: i32) !SerializedValue {
        _ = index;

        // For now, we'll store a placeholder
        // Full function serialization would require:
        // 1. lua_dump to get bytecode
        // 2. Upvalue serialization
        // 3. Environment table serialization

        return SerializedValue{ .function = .{
            .bytecode = try self.allocator.dupe(u8, ""),
            .upvalues = std.ArrayList(*SerializedValue).init(self.allocator),
            .environment = null,
        } };
    }

    fn serializeUserdata(self: *SnapshotSerializer, index: i32) !SerializedValue {
        _ = index;

        // Userdata serialization would require custom handlers
        // For now, store type information only

        return SerializedValue{ .userdata = .{
            .type_name = try self.allocator.dupe(u8, "unknown"),
            .data = try self.allocator.dupe(u8, ""),
            .metatable = null,
        } };
    }

    fn serializeThread(self: *SnapshotSerializer, index: i32) !SerializedValue {
        _ = index;

        // Thread serialization is complex
        // Would need to capture call stack, local variables, etc.

        return SerializedValue{ .thread = .{
            .status = .suspended,
            .stack = std.ArrayList(*SerializedValue).init(self.allocator),
        } };
    }

    fn serializeRegistryTable(self: *SnapshotSerializer, index: i32) !SerializedValue {
        // Only serialize safe registry entries
        // Skip internal Lua entries and potentially dangerous references
        _ = self;
        _ = index;

        return .nil; // Placeholder for now
    }

    fn captureGCState(self: *SnapshotSerializer) StateSnapshot.GCState {
        return StateSnapshot.GCState{
            .threshold = 0, // Would need Lua internals access
            .debt = 0,
            .step_size = 0,
            .pause = @as(u32, @intCast(lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCGETPAUSE, 0))),
            .step_mul = @as(u32, @intCast(lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCGETSTEPMUL, 0))),
        };
    }

    fn calculateSnapshotSize(self: *SnapshotSerializer, snapshot: *StateSnapshot) usize {
        _ = self;
        // Calculate actual memory usage of snapshot
        // This is a simplified version
        return snapshot.memory_usage;
    }

    fn calculateChecksum(self: *SnapshotSerializer, snapshot: *StateSnapshot) u32 {
        _ = self;
        // Calculate checksum for data integrity
        // Using a simple hash for now
        return std.hash.crc32(std.mem.asBytes(&snapshot.memory_usage));
    }
};

/// Snapshot deserializer
pub const SnapshotDeserializer = struct {
    wrapper: *LuaWrapper,
    allocator: std.mem.Allocator,
    restored_tables: std.AutoHashMap(*const SerializedValue, i32),

    pub fn init(wrapper: *LuaWrapper, allocator: std.mem.Allocator) SnapshotDeserializer {
        return SnapshotDeserializer{
            .wrapper = wrapper,
            .allocator = allocator,
            .restored_tables = std.AutoHashMap(*const SerializedValue, i32).init(allocator),
        };
    }

    pub fn deinit(self: *SnapshotDeserializer) void {
        self.restored_tables.deinit();
    }

    pub fn restoreSnapshot(self: *SnapshotDeserializer, snapshot: *const StateSnapshot) !void {
        // Clear current state
        try self.clearState();

        // Clear restoration cache
        self.restored_tables.clearRetainingCapacity();

        // Restore globals
        try self.deserializeValue(&snapshot.globals);
        lua.c.lua_setglobal(self.wrapper.state, "_G");

        // Restore GC settings
        _ = lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCSETPAUSE, @as(c_int, @intCast(snapshot.gc_state.pause)));
        _ = lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCSETSTEPMUL, @as(c_int, @intCast(snapshot.gc_state.step_mul)));

        // Force garbage collection to clean up
        _ = lua.c.lua_gc(self.wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    }

    fn clearState(self: *SnapshotDeserializer) !void {
        // Create new clean global table
        lua.c.lua_newtable(self.wrapper.state);

        // Copy essential globals (like base libraries)
        lua.c.lua_pushglobaltable(self.wrapper.state);
        const essential_globals = [_][]const u8{
            "print", "tostring", "tonumber", "type",      "pairs", "ipairs",
            "math",  "string",   "table",    "coroutine",
        };

        for (essential_globals) |global| {
            lua.c.lua_getfield(self.wrapper.state, -1, global.ptr);
            if (!lua.c.lua_isnil(self.wrapper.state, -1)) {
                lua.c.lua_setfield(self.wrapper.state, -3, global.ptr);
            } else {
                lua.c.lua_pop(self.wrapper.state, 1);
            }
        }

        lua.c.lua_pop(self.wrapper.state, 1); // Remove old global table
        lua.c.lua_setglobal(self.wrapper.state, "_G");
    }

    fn deserializeValue(self: *SnapshotDeserializer, value: *const SerializedValue) !void {
        switch (value.*) {
            .nil => lua.c.lua_pushnil(self.wrapper.state),

            .boolean => |b| lua.c.lua_pushboolean(self.wrapper.state, if (b) 1 else 0),

            .number => |n| lua.c.lua_pushnumber(self.wrapper.state, n),

            .string => |s| _ = lua.c.lua_pushlstring(self.wrapper.state, s.ptr, s.len),

            .table => |*t| try self.deserializeTable(value, t),

            .function => |*f| try self.deserializeFunction(f),

            .userdata => |*u| try self.deserializeUserdata(u),

            .thread => |*t| try self.deserializeThread(t),
        }
    }

    fn deserializeTable(self: *SnapshotDeserializer, value_ptr: *const SerializedValue, table: *const SerializedValue.SerializedTable) !void {
        // Check if already restored
        if (self.restored_tables.get(value_ptr)) |stack_index| {
            lua.c.lua_pushvalue(self.wrapper.state, stack_index);
            return;
        }

        // Create new table
        lua.c.lua_newtable(self.wrapper.state);
        const table_index = lua.c.lua_gettop(self.wrapper.state);
        try self.restored_tables.put(value_ptr, table_index);

        // Restore entries
        for (table.entries.items) |entry| {
            try self.deserializeValue(entry.key);
            try self.deserializeValue(entry.value);
            lua.c.lua_settable(self.wrapper.state, table_index);
        }

        // Restore metatable
        if (table.metatable) |mt| {
            try self.deserializeValue(mt);
            _ = lua.c.lua_setmetatable(self.wrapper.state, table_index);
        }
    }

    fn deserializeFunction(self: *SnapshotDeserializer, func: *const SerializedValue.SerializedFunction) !void {
        _ = func;
        // Function deserialization would require:
        // 1. lua_load to load bytecode
        // 2. Upvalue restoration
        // 3. Environment restoration

        // For now, push nil
        lua.c.lua_pushnil(self.wrapper.state);
    }

    fn deserializeUserdata(self: *SnapshotDeserializer, userdata: *const SerializedValue.SerializedUserdata) !void {
        _ = userdata;
        // Userdata restoration would require custom handlers
        lua.c.lua_pushnil(self.wrapper.state);
    }

    fn deserializeThread(self: *SnapshotDeserializer, thread: *const SerializedValue.SerializedThread) !void {
        _ = thread;
        // Thread restoration is complex
        lua.c.lua_pushnil(self.wrapper.state);
    }
};

/// Snapshot manager for managing multiple snapshots
pub const SnapshotManager = struct {
    snapshots: std.StringHashMap(*StateSnapshot),
    max_snapshots: usize,
    total_size_limit: usize,
    current_total_size: usize,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, max_snapshots: usize, total_size_limit: usize) !*SnapshotManager {
        const self = try allocator.create(SnapshotManager);
        self.* = SnapshotManager{
            .snapshots = std.StringHashMap(*StateSnapshot).init(allocator),
            .max_snapshots = max_snapshots,
            .total_size_limit = total_size_limit,
            .current_total_size = 0,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
        return self;
    }

    pub fn deinit(self: *SnapshotManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.snapshots.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.snapshots.deinit();
        self.allocator.destroy(self);
    }

    pub fn addSnapshot(self: *SnapshotManager, snapshot: *StateSnapshot) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check limits
        if (self.snapshots.count() >= self.max_snapshots) {
            return SnapshotError.SnapshotLimitExceeded;
        }

        if (self.current_total_size + snapshot.metadata.size_bytes > self.total_size_limit) {
            // Try to make room by removing old snapshots
            try self.evictOldSnapshots(snapshot.metadata.size_bytes);
        }

        // Add snapshot
        try self.snapshots.put(snapshot.metadata.id, snapshot);
        self.current_total_size += snapshot.metadata.size_bytes;
    }

    pub fn getSnapshot(self: *SnapshotManager, id: []const u8) ?*StateSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.snapshots.get(id);
    }

    pub fn removeSnapshot(self: *SnapshotManager, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.snapshots.fetchRemove(id)) |entry| {
            self.current_total_size -= entry.value.metadata.size_bytes;
            entry.value.deinit();
        } else {
            return SnapshotError.SnapshotNotFound;
        }
    }

    pub fn listSnapshots(self: *SnapshotManager, allocator: std.mem.Allocator) ![]SnapshotMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.ArrayList(SnapshotMetadata).init(allocator);
        errdefer list.deinit();

        var iter = self.snapshots.iterator();
        while (iter.next()) |entry| {
            const meta_copy = try SnapshotMetadata.init(
                allocator,
                entry.value_ptr.*.metadata.id,
                entry.value_ptr.*.metadata.description,
            );
            try list.append(meta_copy);
        }

        return try list.toOwnedSlice();
    }

    fn evictOldSnapshots(self: *SnapshotManager, needed_space: usize) !void {
        var freed_space: usize = 0;
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer to_remove.deinit();

        // Find oldest snapshots to remove
        var iter = self.snapshots.iterator();
        while (iter.next()) |entry| {
            if (freed_space >= needed_space) break;

            try to_remove.append(entry.key_ptr.*);
            freed_space += entry.value_ptr.*.metadata.size_bytes;
        }

        // Remove selected snapshots
        for (to_remove.items) |id| {
            if (self.snapshots.fetchRemove(id)) |entry| {
                self.current_total_size -= entry.value.metadata.size_bytes;
                entry.value.deinit();
            }
        }

        if (freed_space < needed_space) {
            return SnapshotError.SnapshotLimitExceeded;
        }
    }
};

// Tests
test "StateSnapshot creation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Set up some state
    try wrapper.doString("test_var = 42");
    try wrapper.doString("test_table = {a = 1, b = 'hello'}");

    // Create snapshot
    var serializer = SnapshotSerializer.init(wrapper, allocator, .{});
    defer serializer.deinit();

    const snapshot = try serializer.createSnapshot("test_snapshot", "Test snapshot");
    defer snapshot.deinit();

    try std.testing.expectEqualStrings("test_snapshot", snapshot.metadata.id);
    try std.testing.expect(snapshot.metadata.size_bytes > 0);
    try std.testing.expect(snapshot.memory_usage > 0);
}

test "SnapshotManager operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    const manager = try SnapshotManager.init(allocator, 5, 1024 * 1024);
    defer manager.deinit();

    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create and add snapshots
    var serializer = SnapshotSerializer.init(wrapper, allocator, .{});
    defer serializer.deinit();

    const snapshot1 = try serializer.createSnapshot("snap1", "First snapshot");
    try manager.addSnapshot(snapshot1);

    const snapshot2 = try serializer.createSnapshot("snap2", "Second snapshot");
    try manager.addSnapshot(snapshot2);

    // Retrieve snapshot
    const retrieved = manager.getSnapshot("snap1");
    try std.testing.expect(retrieved != null);

    // List snapshots
    const list = try manager.listSnapshots(allocator);
    defer {
        for (list) |*item| {
            item.deinit(allocator);
        }
        allocator.free(list);
    }
    try std.testing.expect(list.len == 2);

    // Remove snapshot
    try manager.removeSnapshot("snap2");
    try std.testing.expect(manager.getSnapshot("snap2") == null);
}
