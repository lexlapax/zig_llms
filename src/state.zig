// ABOUTME: Thread-safe state management for agents with versioning
// ABOUTME: Provides shared state across agent hierarchies with atomic updates

const std = @import("std");
const types = @import("types.zig");

// State snapshot for rollback support
pub const StateSnapshot = struct {
    data: std.StringHashMap(std.json.Value),
    artifacts: std.StringHashMap([]const u8),
    messages: []types.Message,
    metadata: std.StringHashMap(std.json.Value),
    version: u32,
    timestamp: i64,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *StateSnapshot) void {
        self.data.deinit();
        self.artifacts.deinit();
        self.allocator.free(self.messages);
        self.metadata.deinit();
    }
};

pub const State = struct {
    data: std.StringHashMap(std.json.Value),
    artifacts: std.StringHashMap([]const u8),
    messages: std.ArrayList(types.Message),
    metadata: std.StringHashMap(std.json.Value),
    version: u32,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) State {
        return State{
            .data = std.StringHashMap(std.json.Value).init(allocator),
            .artifacts = std.StringHashMap([]const u8).init(allocator),
            .messages = std.ArrayList(types.Message).init(allocator),
            .metadata = std.StringHashMap(std.json.Value).init(allocator),
            .version = 0,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *State) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.data.deinit();
        self.artifacts.deinit();
        self.messages.deinit();
        self.metadata.deinit();
    }
    
    pub fn update(self: *State, key: []const u8, value: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.data.put(key, value);
        self.version += 1;
    }
    
    pub fn get(self: *State, key: []const u8) ?std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.data.get(key);
    }
    
    pub fn addMessage(self: *State, message: types.Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.messages.append(message);
        self.version += 1;
    }
    
    pub fn getMessages(self: *State) []const types.Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.messages.items;
    }
    
    pub fn setArtifact(self: *State, key: []const u8, content: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.artifacts.put(key, content);
        self.version += 1;
    }
    
    pub fn getArtifact(self: *State, key: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.artifacts.get(key);
    }
    
    pub fn getVersion(self: *State) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.version;
    }
    
    pub fn clear(self: *State) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        self.data.clearRetainingCapacity();
        self.artifacts.clearRetainingCapacity();
        self.messages.clearRetainingCapacity();
        self.metadata.clearRetainingCapacity();
        self.version = 0;
    }
    
    pub fn clone(self: *State, allocator: std.mem.Allocator) !State {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var new_state = State.init(allocator);
        
        // Clone data
        var data_iter = self.data.iterator();
        while (data_iter.next()) |entry| {
            try new_state.data.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // Clone artifacts
        var artifact_iter = self.artifacts.iterator();
        while (artifact_iter.next()) |entry| {
            try new_state.artifacts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // Clone messages
        try new_state.messages.appendSlice(self.messages.items);
        
        // Clone metadata
        var metadata_iter = self.metadata.iterator();
        while (metadata_iter.next()) |entry| {
            try new_state.metadata.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        new_state.version = self.version;
        
        return new_state;
    }
    
    // Create a snapshot for rollback support
    pub fn snapshot(self: *State) !StateSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var snap_data = std.StringHashMap(std.json.Value).init(self.allocator);
        var snap_artifacts = std.StringHashMap([]const u8).init(self.allocator);
        var snap_metadata = std.StringHashMap(std.json.Value).init(self.allocator);
        
        // Copy data
        var data_iter = self.data.iterator();
        while (data_iter.next()) |entry| {
            try snap_data.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // Copy artifacts
        var artifact_iter = self.artifacts.iterator();
        while (artifact_iter.next()) |entry| {
            try snap_artifacts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        // Copy messages
        const messages_copy = try self.allocator.alloc(types.Message, self.messages.items.len);
        @memcpy(messages_copy, self.messages.items);
        
        // Copy metadata
        var metadata_iter = self.metadata.iterator();
        while (metadata_iter.next()) |entry| {
            try snap_metadata.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        return StateSnapshot{
            .data = snap_data,
            .artifacts = snap_artifacts,
            .messages = messages_copy,
            .metadata = snap_metadata,
            .version = self.version,
            .timestamp = std.time.timestamp(),
            .allocator = self.allocator,
        };
    }
    
    // Restore from snapshot
    pub fn restore(self: *State, snap: StateSnapshot) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clear current state
        self.data.clearRetainingCapacity();
        self.artifacts.clearRetainingCapacity();
        self.messages.clearRetainingCapacity();
        self.metadata.clearRetainingCapacity();
        
        // Restore from snapshot
        var data_iter = snap.data.iterator();
        while (data_iter.next()) |entry| {
            try self.data.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        var artifact_iter = snap.artifacts.iterator();
        while (artifact_iter.next()) |entry| {
            try self.artifacts.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        try self.messages.appendSlice(snap.messages);
        
        var metadata_iter = snap.metadata.iterator();
        while (metadata_iter.next()) |entry| {
            try self.metadata.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        
        self.version = snap.version;
    }
    
    // Batch update for atomic operations
    pub fn batchUpdate(self: *State, updates: []const StateUpdate) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Apply all updates atomically
        for (updates) |upd| {
            switch (upd) {
                .data => |d| try self.data.put(d.key, d.value),
                .artifact => |a| try self.artifacts.put(a.key, a.content),
                .message => |m| try self.messages.append(m),
                .metadata => |md| try self.metadata.put(md.key, md.value),
            }
        }
        
        self.version += 1;
    }
    
    // Watch for changes with callback
    pub fn watch(self: *State, key: []const u8, callback: StateWatchCallback, context: ?*anyopaque) !void {
        // This would require a more complex implementation with a separate thread
        // For now, we'll just store the watch request
        _ = self;
        _ = key;
        _ = callback;
        _ = context;
        // TODO: Implement proper watch mechanism
    }
    
    // Export state as JSON
    pub fn toJson(self: *State, allocator: std.mem.Allocator) !std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var root = std.json.ObjectMap.init(allocator);
        errdefer root.deinit();
        
        // Convert data
        var data_obj = std.json.ObjectMap.init(allocator);
        var data_iter = self.data.iterator();
        while (data_iter.next()) |entry| {
            try data_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try root.put("data", .{ .object = data_obj });
        
        // Convert artifacts
        var artifacts_obj = std.json.ObjectMap.init(allocator);
        var artifact_iter = self.artifacts.iterator();
        while (artifact_iter.next()) |entry| {
            try artifacts_obj.put(entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }
        try root.put("artifacts", .{ .object = artifacts_obj });
        
        // Convert messages
        var messages_array = std.json.Array.init(allocator);
        for (self.messages.items) |msg| {
            var msg_obj = std.json.ObjectMap.init(allocator);
            try msg_obj.put("role", .{ .string = @tagName(msg.role) });
            const content_str = switch (msg.content) {
                .text => |t| t,
                .json => |j| try std.json.stringifyAlloc(allocator, j, .{}),
            };
            defer if (msg.content == .json) allocator.free(content_str);
            try msg_obj.put("content", .{ .string = content_str });
            try messages_array.append(.{ .object = msg_obj });
        }
        try root.put("messages", .{ .array = messages_array });
        
        // Convert metadata
        var metadata_obj = std.json.ObjectMap.init(allocator);
        var metadata_iter = self.metadata.iterator();
        while (metadata_iter.next()) |entry| {
            try metadata_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try root.put("metadata", .{ .object = metadata_obj });
        
        try root.put("version", .{ .integer = @as(i64, @intCast(self.version)) });
        
        return .{ .object = root };
    }
};

// State update types for batch operations
pub const StateUpdate = union(enum) {
    data: struct {
        key: []const u8,
        value: std.json.Value,
    },
    artifact: struct {
        key: []const u8,
        content: []const u8,
    },
    message: types.Message,
    metadata: struct {
        key: []const u8,
        value: std.json.Value,
    },
};

// Callback for state watchers
pub const StateWatchCallback = *const fn (key: []const u8, old_value: ?std.json.Value, new_value: ?std.json.Value, context: ?*anyopaque) void;

// Shared state pool for agent hierarchies
pub const StatePool = struct {
    states: std.StringHashMap(*State),
    parent_child: std.StringHashMap(std.ArrayList([]const u8)),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) StatePool {
        return .{
            .states = std.StringHashMap(*State).init(allocator),
            .parent_child = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *StatePool) void {
        var state_iter = self.states.iterator();
        while (state_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.states.deinit();
        
        var pc_iter = self.parent_child.iterator();
        while (pc_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.parent_child.deinit();
    }
    
    pub fn createState(self: *StatePool, id: []const u8) !*State {
        const state = try self.allocator.create(State);
        state.* = State.init(self.allocator);
        try self.states.put(id, state);
        return state;
    }
    
    pub fn getState(self: *StatePool, id: []const u8) ?*State {
        return self.states.get(id);
    }
    
    pub fn linkStates(self: *StatePool, parent_id: []const u8, child_id: []const u8) !void {
        var children = self.parent_child.get(parent_id) orelse
            std.ArrayList([]const u8).init(self.allocator);
        try children.append(child_id);
        try self.parent_child.put(parent_id, children);
    }
    
    pub fn propagateUpdate(self: *StatePool, from_id: []const u8, key: []const u8, value: std.json.Value) !void {
        // Update the source state
        if (self.getState(from_id)) |state| {
            try state.update(key, value);
        }
        
        // Propagate to children
        if (self.parent_child.get(from_id)) |children| {
            for (children.items) |child_id| {
                try self.propagateUpdate(child_id, key, value);
            }
        }
    }
};

test "state management" {
    const allocator = std.testing.allocator;
    
    var state = State.init(allocator);
    defer state.deinit();
    
    try state.update("test_key", std.json.Value{ .string = "test_value" });
    
    const value = state.get("test_key");
    try std.testing.expect(value != null);
    try std.testing.expectEqual(@as(u32, 1), state.getVersion());
    
    const message = types.Message{
        .role = .user,
        .content = .{ .text = "Test message" },
    };
    try state.addMessage(message);
    
    const messages = state.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(@as(u32, 2), state.getVersion());
}

test "state snapshot and restore" {
    const allocator = std.testing.allocator;
    
    var state = State.init(allocator);
    defer state.deinit();
    
    // Set initial state
    try state.update("key1", .{ .string = "value1" });
    try state.update("key2", .{ .integer = 42 });
    try state.setArtifact("artifact1", "content1");
    
    const initial_version = state.getVersion();
    
    // Take snapshot
    var snapshot = try state.snapshot();
    defer snapshot.deinit();
    
    // Modify state
    try state.update("key1", .{ .string = "modified" });
    try state.update("key3", .{ .bool = true });
    
    try std.testing.expect(state.getVersion() > initial_version);
    
    // Restore from snapshot
    try state.restore(snapshot);
    
    // Verify restored state
    try std.testing.expectEqual(initial_version, state.getVersion());
    const restored_value = state.get("key1").?;
    try std.testing.expectEqualStrings("value1", restored_value.string);
    try std.testing.expect(state.get("key3") == null);
}

test "batch updates" {
    const allocator = std.testing.allocator;
    
    var state = State.init(allocator);
    defer state.deinit();
    
    const updates = [_]StateUpdate{
        .{ .data = .{ .key = "key1", .value = .{ .string = "value1" } } },
        .{ .data = .{ .key = "key2", .value = .{ .integer = 123 } } },
        .{ .artifact = .{ .key = "file1", .content = "file content" } },
        .{ .message = .{ .role = .user, .content = .{ .text = "Hello" } } },
        .{ .metadata = .{ .key = "meta1", .value = .{ .bool = true } } },
    };
    
    try state.batchUpdate(&updates);
    
    // Verify all updates were applied
    try std.testing.expectEqual(@as(u32, 1), state.getVersion());
    try std.testing.expect(state.get("key1") != null);
    try std.testing.expect(state.get("key2") != null);
    try std.testing.expect(state.getArtifact("file1") != null);
    try std.testing.expectEqual(@as(usize, 1), state.getMessages().len);
}

test "state pool" {
    const allocator = std.testing.allocator;
    
    var pool = StatePool.init(allocator);
    defer pool.deinit();
    
    // Create states
    const parent_state = try pool.createState("parent");
    const child_state = try pool.createState("child");
    
    // Link states
    try pool.linkStates("parent", "child");
    
    // Test propagation
    try pool.propagateUpdate("parent", "shared_key", .{ .string = "shared_value" });
    
    // Verify both states have the update
    const parent_value = parent_state.get("shared_key");
    const child_value = child_state.get("shared_key");
    
    try std.testing.expect(parent_value != null);
    try std.testing.expect(child_value != null);
    try std.testing.expectEqualStrings("shared_value", parent_value.?.string);
    try std.testing.expectEqualStrings("shared_value", child_value.?.string);
}