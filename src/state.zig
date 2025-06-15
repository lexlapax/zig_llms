// ABOUTME: Thread-safe state management for agents with versioning
// ABOUTME: Provides shared state across agent hierarchies with atomic updates

const std = @import("std");
const types = @import("types.zig");

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