// ABOUTME: Main event system module that provides unified event handling
// ABOUTME: Combines event types, emitter, filtering, recording, and replay functionality

const std = @import("std");

// Re-export all event modules
pub const types = @import("events/types.zig");
pub const emitter = @import("events/emitter.zig");
pub const filter = @import("events/filter.zig");
pub const recorder = @import("events/recorder.zig");

// Re-export commonly used types
pub const Event = types.Event;
pub const EventBuilder = types.EventBuilder;
pub const EventCategory = types.EventCategory;
pub const EventSeverity = types.EventSeverity;
pub const EventMetadata = types.EventMetadata;

pub const EventEmitter = emitter.EventEmitter;
pub const EventHandler = emitter.EventHandler;
pub const AsyncEventHandler = emitter.AsyncEventHandler;
pub const Subscription = emitter.Subscription;
pub const SubscriptionOptions = emitter.SubscriptionOptions;

pub const EventFilter = filter.EventFilter;
pub const FilterBuilder = filter.FilterBuilder;
pub const FilterExpression = filter.FilterExpression;
pub const FilterCondition = filter.FilterCondition;
pub const FilterField = filter.FilterField;
pub const FilterOp = filter.FilterOp;
pub const FilterValue = filter.FilterValue;

pub const EventRecorder = recorder.EventRecorder;
pub const EventReplayer = recorder.EventReplayer;
pub const StorageBackend = recorder.StorageBackend;
pub const MemoryBackend = recorder.MemoryBackend;
pub const FileBackend = recorder.FileBackend;

// Common event types
pub const AgentEvent = types.AgentEvent;
pub const ToolEvent = types.ToolEvent;
pub const WorkflowEvent = types.WorkflowEvent;

// Global event system management
pub const EventSystem = struct {
    allocator: std.mem.Allocator,
    emitter_instance: *EventEmitter,
    recorder_instance: ?*EventRecorder = null,
    initialized: bool = false,
    
    var global_system: ?*EventSystem = null;
    var global_mutex = std.Thread.Mutex{};
    
    pub fn init(allocator: std.mem.Allocator, config: SystemConfig) !*EventSystem {
        global_mutex.lock();
        defer global_mutex.unlock();
        
        if (global_system != null) {
            return error.EventSystemAlreadyInitialized;
        }
        
        const system = try allocator.create(EventSystem);
        errdefer allocator.destroy(system);
        
        // Create emitter
        const emitter_instance = try allocator.create(EventEmitter);
        emitter_instance.* = EventEmitter.init(allocator, config.emitter_config);
        try emitter_instance.start();
        
        // Create recorder if configured
        var recorder_instance: ?*EventRecorder = null;
        if (config.enable_recording) {
            const backend = switch (config.storage_backend) {
                .memory => blk: {
                    const mem_backend = try allocator.create(MemoryBackend);
                    mem_backend.* = MemoryBackend.init(allocator);
                    break :blk &mem_backend.backend;
                },
                .file => |path| blk: {
                    const file_backend = try allocator.create(FileBackend);
                    file_backend.* = FileBackend.init(allocator, path);
                    break :blk &file_backend.backend;
                },
            };
            
            recorder_instance = try allocator.create(EventRecorder);
            recorder_instance.?.* = EventRecorder.init(allocator, backend, config.recorder_config);
            
            // Auto-subscribe recorder to emitter
            const record_handler = struct {
                fn handle(event: *const Event, context: ?*anyopaque) void {
                    if (context) |ctx| {
                        const rec: *EventRecorder = @ptrCast(@alignCast(ctx));
                        rec.record(event) catch {};
                    }
                }
            }.handle;
            
            _ = try emitter_instance.subscribe("*", record_handler, .{});
            
            // Update subscription to include recorder as context
            var iter = emitter_instance.subscriptions.iterator();
            if (iter.next()) |entry| {
                entry.value_ptr.context = recorder_instance.?;
            }
        }
        
        system.* = EventSystem{
            .allocator = allocator,
            .emitter_instance = emitter_instance,
            .recorder_instance = recorder_instance,
            .initialized = true,
        };
        
        global_system = system;
        return system;
    }
    
    pub fn deinit(self: *EventSystem) void {
        global_mutex.lock();
        defer global_mutex.unlock();
        
        if (self.recorder_instance) |rec| {
            rec.deinit();
            
            // Clean up backend
            rec.backend.close();
            
            self.allocator.destroy(rec);
        }
        
        self.emitter_instance.stop();
        self.emitter_instance.deinit();
        self.allocator.destroy(self.emitter_instance);
        
        self.allocator.destroy(self);
        
        if (global_system == self) {
            global_system = null;
        }
    }
    
    pub fn getGlobal() !*EventSystem {
        global_mutex.lock();
        defer global_mutex.unlock();
        
        if (global_system) |system| {
            return system;
        }
        
        return error.EventSystemNotInitialized;
    }
    
    pub fn emit(self: *EventSystem, event: Event) !void {
        return self.emitter_instance.emit(event);
    }
    
    pub fn subscribe(
        self: *EventSystem,
        pattern: []const u8,
        handler: EventHandler,
        options: SubscriptionOptions,
    ) ![]const u8 {
        return self.emitter_instance.subscribe(pattern, handler, options);
    }
    
    pub fn unsubscribe(self: *EventSystem, subscription_id: []const u8) bool {
        return self.emitter_instance.unsubscribe(subscription_id);
    }
    
    pub fn query(self: *EventSystem, filter_expr: ?*const FilterExpression, limit: ?usize) ![]Event {
        if (self.recorder_instance) |rec| {
            return rec.query(filter_expr, limit);
        }
        return error.RecordingNotEnabled;
    }
    
    pub fn replay(self: *EventSystem, config: recorder.EventReplayer.ReplayConfig) !void {
        if (self.recorder_instance) |rec| {
            const events = try rec.query(config.filter_expr, null);
            var replayer = recorder.EventReplayer.init(self.allocator, events, config);
            defer replayer.deinit();
            
            try replayer.replay();
        } else {
            return error.RecordingNotEnabled;
        }
    }
    
    pub fn replayFromFile(self: *EventSystem, file_path: []const u8, config: recorder.EventReplayer.ReplayConfig) !void {
        var file_backend = FileBackend.init(self.allocator, file_path);
        defer file_backend.backend.close();
        
        const events = try file_backend.backend.retrieve(config.filter_expr, null, self.allocator);
        var replayer = recorder.EventReplayer.init(self.allocator, events, config);
        defer replayer.deinit();
        
        try replayer.replay();
    }
    
    pub const SystemConfig = struct {
        emitter_config: EventEmitter.EmitterConfig = .{},
        recorder_config: EventRecorder.RecorderConfig = .{},
        enable_recording: bool = true,
        storage_backend: StorageBackendType = .memory,
    };
    
    pub const StorageBackendType = union(enum) {
        memory,
        file: []const u8,
    };
};

// Convenience functions
pub fn emit(event: Event) !void {
    const system = try EventSystem.getGlobal();
    return system.emit(event);
}

pub fn subscribe(pattern: []const u8, handler: EventHandler, options: SubscriptionOptions) ![]const u8 {
    const system = try EventSystem.getGlobal();
    return system.subscribe(pattern, handler, options);
}

pub fn unsubscribe(subscription_id: []const u8) !bool {
    const system = try EventSystem.getGlobal();
    return system.unsubscribe(subscription_id);
}

pub fn query(filter_expr: ?*const FilterExpression, limit: ?usize) ![]Event {
    const system = try EventSystem.getGlobal();
    return system.query(filter_expr, limit);
}

pub fn replay(config: recorder.EventReplayer.ReplayConfig) !void {
    const system = try EventSystem.getGlobal();
    return system.replay(config);
}

// Helper for creating common events
pub fn agentStarted(allocator: std.mem.Allocator, agent_id: []const u8, agent_type: []const u8) !void {
    var event = try AgentEvent.started(allocator, agent_id, agent_type);
    defer event.deinit();
    try emit(event);
}

pub fn agentCompleted(allocator: std.mem.Allocator, agent_id: []const u8, duration_ms: u64) !void {
    var event = try AgentEvent.completed(allocator, agent_id, duration_ms);
    defer event.deinit();
    try emit(event);
}

pub fn agentFailed(allocator: std.mem.Allocator, agent_id: []const u8, error_message: []const u8) !void {
    var event = try AgentEvent.failed(allocator, agent_id, error_message);
    defer event.deinit();
    try emit(event);
}

pub fn toolInvoked(allocator: std.mem.Allocator, tool_name: []const u8, input: std.json.Value) !void {
    var event = try ToolEvent.invoked(allocator, tool_name, input);
    defer event.deinit();
    try emit(event);
}

pub fn toolSucceeded(allocator: std.mem.Allocator, tool_name: []const u8, output: std.json.Value, duration_ms: u64) !void {
    var event = try ToolEvent.succeeded(allocator, tool_name, output, duration_ms);
    defer event.deinit();
    try emit(event);
}

pub fn toolFailed(allocator: std.mem.Allocator, tool_name: []const u8, error_message: []const u8) !void {
    var event = try ToolEvent.failed(allocator, tool_name, error_message);
    defer event.deinit();
    try emit(event);
}

// Tests
test "event system initialization" {
    const allocator = std.testing.allocator;
    
    const system = try EventSystem.init(allocator, .{
        .enable_recording = true,
        .storage_backend = .memory,
    });
    defer system.deinit();
    
    try std.testing.expect(system.initialized);
    try std.testing.expect(system.recorder_instance != null);
}

test "event system emit and query" {
    const allocator = std.testing.allocator;
    
    const system = try EventSystem.init(allocator, .{
        .enable_recording = true,
        .storage_backend = .memory,
        .emitter_config = .{ .async_processing = false },
    });
    defer system.deinit();
    
    // Emit some events
    var event1 = try Event.init(
        allocator,
        "test.event1",
        .custom,
        .info,
        "test",
        .{ .null = {} },
    );
    defer event1.deinit();
    try system.emit(event1);
    
    var event2 = try Event.init(
        allocator,
        "test.event2",
        .custom,
        .warning,
        "test",
        .{ .null = {} },
    );
    defer event2.deinit();
    try system.emit(event2);
    
    // Query all events
    const all_events = try system.query(null, null);
    defer {
        for (all_events) |*e| {
            var mut_event = e;
            mut_event.deinit();
        }
        allocator.free(all_events);
    }
    
    try std.testing.expectEqual(@as(usize, 2), all_events.len);
    
    // Query with filter
    var builder = FilterBuilder.init(allocator);
    defer builder.deinit();
    
    _ = try builder.where(.severity, .gte, .{ .severity = .warning });
    
    if (builder.build()) |filter_expr| {
        defer {
            filter_expr.deinit(allocator);
            allocator.destroy(filter_expr);
        }
        
        const filtered_events = try system.query(filter_expr, null);
        defer {
            for (filtered_events) |*e| {
                var mut_event = e;
                mut_event.deinit();
            }
            allocator.free(filtered_events);
        }
        
        try std.testing.expectEqual(@as(usize, 1), filtered_events.len);
        try std.testing.expectEqualStrings("test.event2", filtered_events[0].name);
    }
}

test "event replay" {
    const allocator = std.testing.allocator;
    
    const system = try EventSystem.init(allocator, .{
        .enable_recording = true,
        .storage_backend = .memory,
        .emitter_config = .{ .async_processing = false },
    });
    defer system.deinit();
    
    // Emit some events
    for (0..3) |i| {
        var event = try Event.init(
            allocator,
            "replay.test",
            .custom,
            .info,
            "test",
            .{ .null = {} },
        );
        event.metadata.timestamp = @as(i64, @intCast(i * 100));
        defer event.deinit();
        try system.emit(event);
    }
    
    // Test context for replay callback
    const TestContext = struct {
        count: usize = 0,
    };
    
    var context = TestContext{};
    
    const replay_handler = struct {
        fn handle(event: *const Event, ctx: ?*anyopaque) void {
            _ = event;
            if (ctx) |c| {
                const test_ctx: *TestContext = @ptrCast(@alignCast(c));
                test_ctx.count += 1;
            }
        }
    }.handle;
    
    // Replay events
    try system.replay(.{
        .respect_timestamps = false,
        .callback = replay_handler,
        .context = &context,
    });
    
    try std.testing.expectEqual(@as(usize, 3), context.count);
}