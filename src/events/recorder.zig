// ABOUTME: Event recorder for persistence and replay capabilities
// ABOUTME: Provides event storage, retrieval, and replay functionality with multiple backends

const std = @import("std");
const types = @import("types.zig");
const filter = @import("filter.zig");
const Event = types.Event;
const EventFilter = filter.EventFilter;
const FilterExpression = filter.FilterExpression;

// Storage backend interface
pub const StorageBackend = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        store: *const fn (backend: *StorageBackend, event: *const Event) anyerror!void,
        retrieve: *const fn (backend: *StorageBackend, filter_expr: ?*const FilterExpression, limit: ?usize, allocator: std.mem.Allocator) anyerror![]Event,
        retrieveByIds: *const fn (backend: *StorageBackend, ids: []const []const u8, allocator: std.mem.Allocator) anyerror![]Event,
        deleteByIds: *const fn (backend: *StorageBackend, ids: []const []const u8) anyerror!usize,
        deleteByFilter: *const fn (backend: *StorageBackend, filter_expr: *const FilterExpression) anyerror!usize,
        count: *const fn (backend: *StorageBackend, filter_expr: ?*const FilterExpression) anyerror!usize,
        clear: *const fn (backend: *StorageBackend) anyerror!void,
        close: *const fn (backend: *StorageBackend) void,
    };
    
    pub fn store(self: *StorageBackend, event: *const Event) !void {
        return self.vtable.store(self, event);
    }
    
    pub fn retrieve(self: *StorageBackend, filter_expr: ?*const FilterExpression, limit: ?usize, allocator: std.mem.Allocator) ![]Event {
        return self.vtable.retrieve(self, filter_expr, limit, allocator);
    }
    
    pub fn retrieveByIds(self: *StorageBackend, ids: []const []const u8, allocator: std.mem.Allocator) ![]Event {
        return self.vtable.retrieveByIds(self, ids, allocator);
    }
    
    pub fn deleteByIds(self: *StorageBackend, ids: []const []const u8) !usize {
        return self.vtable.deleteByIds(self, ids);
    }
    
    pub fn deleteByFilter(self: *StorageBackend, filter_expr: *const FilterExpression) !usize {
        return self.vtable.deleteByFilter(self, filter_expr);
    }
    
    pub fn count(self: *StorageBackend, filter_expr: ?*const FilterExpression) !usize {
        return self.vtable.count(self, filter_expr);
    }
    
    pub fn clear(self: *StorageBackend) !void {
        return self.vtable.clear(self);
    }
    
    pub fn close(self: *StorageBackend) void {
        self.vtable.close(self);
    }
};

// In-memory storage backend
pub const MemoryBackend = struct {
    backend: StorageBackend,
    events: std.ArrayList(Event),
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MemoryBackend {
        return .{
            .backend = .{
                .vtable = &vtable,
            },
            .events = std.ArrayList(Event).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MemoryBackend) void {
        for (self.events.items) |*event| {
            event.deinit();
        }
        self.events.deinit();
    }
    
    const vtable = StorageBackend.VTable{
        .store = store,
        .retrieve = retrieve,
        .retrieveByIds = retrieveByIds,
        .deleteByIds = deleteByIds,
        .deleteByFilter = deleteByFilter,
        .count = count,
        .clear = clear,
        .close = close,
    };
    
    fn store(backend: *StorageBackend, event: *const Event) !void {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const cloned = try event.clone(self.allocator);
        try self.events.append(cloned);
    }
    
    fn retrieve(backend: *StorageBackend, filter_expr: ?*const FilterExpression, limit: ?usize, allocator: std.mem.Allocator) ![]Event {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var results = std.ArrayList(Event).init(allocator);
        errdefer {
            for (results.items) |*e| e.deinit();
            results.deinit();
        }
        
        for (self.events.items) |*event| {
            if (filter_expr) |expr| {
                if (!expr.matches(event)) continue;
            }
            
            try results.append(try event.clone(allocator));
            
            if (limit) |max| {
                if (results.items.len >= max) break;
            }
        }
        
        return try results.toOwnedSlice();
    }
    
    fn retrieveByIds(backend: *StorageBackend, ids: []const []const u8, allocator: std.mem.Allocator) ![]Event {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var results = std.ArrayList(Event).init(allocator);
        errdefer {
            for (results.items) |*e| e.deinit();
            results.deinit();
        }
        
        for (self.events.items) |*event| {
            for (ids) |id| {
                if (std.mem.eql(u8, event.id, id)) {
                    try results.append(try event.clone(allocator));
                    break;
                }
            }
        }
        
        return try results.toOwnedSlice();
    }
    
    fn deleteByIds(backend: *StorageBackend, ids: []const []const u8) !usize {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var deleted: usize = 0;
        var i: usize = 0;
        
        while (i < self.events.items.len) {
            var found = false;
            for (ids) |id| {
                if (std.mem.eql(u8, self.events.items[i].id, id)) {
                    found = true;
                    break;
                }
            }
            
            if (found) {
                var event = self.events.orderedRemove(i);
                event.deinit();
                deleted += 1;
            } else {
                i += 1;
            }
        }
        
        return deleted;
    }
    
    fn deleteByFilter(backend: *StorageBackend, filter_expr: *const FilterExpression) !usize {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var deleted: usize = 0;
        var i: usize = 0;
        
        while (i < self.events.items.len) {
            if (filter_expr.matches(&self.events.items[i])) {
                var event = self.events.orderedRemove(i);
                event.deinit();
                deleted += 1;
            } else {
                i += 1;
            }
        }
        
        return deleted;
    }
    
    fn count(backend: *StorageBackend, filter_expr: ?*const FilterExpression) !usize {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (filter_expr) |expr| {
            var matching: usize = 0;
            for (self.events.items) |*event| {
                if (expr.matches(event)) matching += 1;
            }
            return matching;
        }
        
        return self.events.items.len;
    }
    
    fn clear(backend: *StorageBackend) !void {
        const self: *MemoryBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        for (self.events.items) |*event| {
            event.deinit();
        }
        self.events.clearRetainingCapacity();
    }
    
    fn close(backend: *StorageBackend) void {
        _ = backend;
        // No-op for memory backend
    }
};

// File-based storage backend
pub const FileBackend = struct {
    backend: StorageBackend,
    file_path: []const u8,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    
    pub fn init(allocator: std.mem.Allocator, file_path: []const u8) FileBackend {
        return .{
            .backend = .{
                .vtable = &vtable,
            },
            .file_path = file_path,
            .allocator = allocator,
        };
    }
    
    const vtable = StorageBackend.VTable{
        .store = store,
        .retrieve = retrieve,
        .retrieveByIds = retrieveByIds,
        .deleteByIds = deleteByIds,
        .deleteByFilter = deleteByFilter,
        .count = count,
        .clear = clear,
        .close = close,
    };
    
    fn store(backend: *StorageBackend, event: *const Event) !void {
        const self: *FileBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Append to file
        const file = try std.fs.cwd().createFile(self.file_path, .{
            .truncate = false,
            .read = true,
        });
        defer file.close();
        
        try file.seekToEnd();
        
        const json = try event.toJson();
        try std.json.stringify(json, .{}, file.writer());
        try file.writer().writeAll("\n");
    }
    
    fn retrieve(backend: *StorageBackend, filter_expr: ?*const FilterExpression, limit: ?usize, allocator: std.mem.Allocator) ![]Event {
        const self: *FileBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                return allocator.alloc(Event, 0);
            }
            return err;
        };
        defer file.close();
        
        var results = std.ArrayList(Event).init(allocator);
        errdefer {
            for (results.items) |*e| e.deinit();
            results.deinit();
        }
        
        var buf_reader = std.io.bufferedReader(file.reader());
        var reader = buf_reader.reader();
        
        var line_buf: [65536]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (line.len == 0) continue;
            
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
            defer parsed.deinit();
            
            const event = Event.fromJson(allocator, parsed.value) catch continue;
            
            if (filter_expr) |expr| {
                if (!expr.matches(&event)) {
                    var mut_event = event;
                    mut_event.deinit();
                    continue;
                }
            }
            
            try results.append(event);
            
            if (limit) |max| {
                if (results.items.len >= max) break;
            }
        }
        
        return try results.toOwnedSlice();
    }
    
    fn retrieveByIds(backend: *StorageBackend, ids: []const []const u8, allocator: std.mem.Allocator) ![]Event {
        // Build a filter expression for IDs
        var builder = filter.FilterBuilder.init(allocator);
        defer builder.deinit();
        
        if (ids.len > 0) {
            _ = try builder.where(.id, .in, .{ .string_list = ids });
        }
        
        if (builder.build()) |expr| {
            defer {
                expr.deinit(allocator);
                allocator.destroy(expr);
            }
            return retrieve(backend, expr, null, allocator);
        }
        
        return allocator.alloc(Event, 0);
    }
    
    fn deleteByIds(backend: *StorageBackend, ids: []const []const u8) !usize {
        _ = backend;
        _ = ids;
        // For file backend, we'd need to rewrite the entire file
        // This is a simplified implementation
        return error.NotImplemented;
    }
    
    fn deleteByFilter(backend: *StorageBackend, filter_expr: *const FilterExpression) !usize {
        _ = backend;
        _ = filter_expr;
        // For file backend, we'd need to rewrite the entire file
        // This is a simplified implementation
        return error.NotImplemented;
    }
    
    fn count(backend: *StorageBackend, filter_expr: ?*const FilterExpression) !usize {
        const events = try retrieve(backend, filter_expr, null, backend.allocator);
        defer {
            for (events) |*event| {
                var mut_event = event;
                mut_event.deinit();
            }
            backend.allocator.free(events);
        }
        return events.len;
    }
    
    fn clear(backend: *StorageBackend) !void {
        const self: *FileBackend = @fieldParentPtr("backend", backend);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Truncate file
        const file = try std.fs.cwd().createFile(self.file_path, .{ .truncate = true });
        file.close();
    }
    
    fn close(backend: *StorageBackend) void {
        _ = backend;
        // No-op for file backend
    }
};

// Event recorder
pub const EventRecorder = struct {
    allocator: std.mem.Allocator,
    backend: *StorageBackend,
    filters: std.ArrayList(EventFilter),
    recording: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    config: RecorderConfig,
    
    pub const RecorderConfig = struct {
        auto_flush: bool = true,
        flush_interval_ms: u32 = 1000,
        max_buffer_size: usize = 1000,
        compress: bool = false,
        rotate_size_mb: ?usize = null,
        rotate_count: ?usize = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, backend: *StorageBackend, config: RecorderConfig) EventRecorder {
        return .{
            .allocator = allocator,
            .backend = backend,
            .filters = std.ArrayList(EventFilter).init(allocator),
            .config = config,
        };
    }
    
    pub fn deinit(self: *EventRecorder) void {
        for (self.filters.items) |*f| {
            f.deinit();
        }
        self.filters.deinit();
    }
    
    pub fn addFilter(self: *EventRecorder, event_filter: EventFilter) !void {
        try self.filters.append(event_filter);
    }
    
    pub fn removeFilter(self: *EventRecorder, name: []const u8) bool {
        for (self.filters.items, 0..) |*f, i| {
            if (std.mem.eql(u8, f.name, name)) {
                f.deinit();
                _ = self.filters.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
    
    pub fn record(self: *EventRecorder, event: *const Event) !void {
        if (!self.recording.load(.acquire)) return;
        
        // Check filters
        for (self.filters.items) |*f| {
            if (!f.matches(event)) return;
        }
        
        try self.backend.store(event);
    }
    
    pub fn query(self: *EventRecorder, filter_expr: ?*const FilterExpression, limit: ?usize) ![]Event {
        return self.backend.retrieve(filter_expr, limit, self.allocator);
    }
    
    pub fn queryByIds(self: *EventRecorder, ids: []const []const u8) ![]Event {
        return self.backend.retrieveByIds(ids, self.allocator);
    }
    
    pub fn getCount(self: *EventRecorder, filter_expr: ?*const FilterExpression) !usize {
        return self.backend.count(filter_expr);
    }
    
    pub fn deleteEvents(self: *EventRecorder, ids: []const []const u8) !usize {
        return self.backend.deleteByIds(ids);
    }
    
    pub fn deleteByFilter(self: *EventRecorder, filter_expr: *const FilterExpression) !usize {
        return self.backend.deleteByFilter(filter_expr);
    }
    
    pub fn clear(self: *EventRecorder) !void {
        return self.backend.clear();
    }
    
    pub fn startRecording(self: *EventRecorder) void {
        self.recording.store(true, .release);
    }
    
    pub fn stopRecording(self: *EventRecorder) void {
        self.recording.store(false, .release);
    }
    
    pub fn isRecording(self: *EventRecorder) bool {
        return self.recording.load(.acquire);
    }
};

// Event replay functionality
pub const EventReplayer = struct {
    allocator: std.mem.Allocator,
    events: []Event,
    current_index: usize = 0,
    config: ReplayConfig,
    
    pub const ReplayConfig = struct {
        speed_multiplier: f32 = 1.0,
        respect_timestamps: bool = true,
        filter_expr: ?*FilterExpression = null,
        callback: ?*const fn (event: *const Event, context: ?*anyopaque) void = null,
        context: ?*anyopaque = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, events: []Event, config: ReplayConfig) EventReplayer {
        return .{
            .allocator = allocator,
            .events = events,
            .config = config,
        };
    }
    
    pub fn deinit(self: *EventReplayer) void {
        for (self.events) |*event| {
            event.deinit();
        }
        self.allocator.free(self.events);
    }
    
    pub fn replay(self: *EventReplayer) !void {
        if (self.events.len == 0) return;
        
        const start_time = std.time.milliTimestamp();
        const first_event_time = self.events[0].metadata.timestamp;
        
        for (self.events) |*event| {
            // Apply filter if configured
            if (self.config.filter_expr) |expr| {
                if (!expr.matches(event)) continue;
            }
            
            // Respect timestamps if configured
            if (self.config.respect_timestamps and self.events.len > 1) {
                const time_diff = event.metadata.timestamp - first_event_time;
                const scaled_diff = @as(i64, @intFromFloat(@as(f64, @floatFromInt(time_diff)) / self.config.speed_multiplier));
                const elapsed = std.time.milliTimestamp() - start_time;
                
                if (scaled_diff > elapsed) {
                    const sleep_ms = @as(u64, @intCast(scaled_diff - elapsed));
                    std.time.sleep(sleep_ms * std.time.ns_per_ms);
                }
            }
            
            // Execute callback
            if (self.config.callback) |callback| {
                callback(event, self.config.context);
            }
            
            self.current_index += 1;
        }
    }
    
    pub fn replayNext(self: *EventReplayer) ?*const Event {
        if (self.current_index >= self.events.len) return null;
        
        const event = &self.events[self.current_index];
        
        // Apply filter if configured
        if (self.config.filter_expr) |expr| {
            if (!expr.matches(event)) {
                self.current_index += 1;
                return self.replayNext();
            }
        }
        
        self.current_index += 1;
        return event;
    }
    
    pub fn reset(self: *EventReplayer) void {
        self.current_index = 0;
    }
    
    pub fn seekToTime(self: *EventReplayer, timestamp: i64) void {
        for (self.events, 0..) |*event, i| {
            if (event.metadata.timestamp >= timestamp) {
                self.current_index = i;
                return;
            }
        }
        self.current_index = self.events.len;
    }
};

// Tests
test "memory backend storage" {
    const allocator = std.testing.allocator;
    
    var backend = MemoryBackend.init(allocator);
    defer backend.deinit();
    
    var event = try types.Event.init(
        allocator,
        "test.event",
        .custom,
        .info,
        "test",
        .{ .null = {} },
    );
    defer event.deinit();
    
    try backend.backend.store(&event);
    
    const count = try backend.backend.count(null);
    try std.testing.expectEqual(@as(usize, 1), count);
    
    const events = try backend.backend.retrieve(null, null, allocator);
    defer {
        for (events) |*e| {
            var mut_event = e;
            mut_event.deinit();
        }
        allocator.free(events);
    }
    
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test.event", events[0].name);
}

test "event recorder with filter" {
    const allocator = std.testing.allocator;
    
    var backend = MemoryBackend.init(allocator);
    defer backend.deinit();
    
    var recorder = EventRecorder.init(allocator, &backend.backend, .{});
    defer recorder.deinit();
    
    // Add a filter for warning and above
    var event_filter = EventFilter.init(allocator, "severity_filter");
    defer event_filter.deinit();
    
    var builder = filter.FilterBuilder.init(allocator);
    defer builder.deinit();
    
    _ = try builder.where(.severity, .gte, .{ .severity = .warning });
    if (builder.build()) |expr| {
        event_filter.setExpression(expr);
    }
    
    try recorder.addFilter(event_filter);
    
    // Record info event (should be filtered out)
    var info_event = try types.Event.init(
        allocator,
        "test.info",
        .custom,
        .info,
        "test",
        .{ .null = {} },
    );
    defer info_event.deinit();
    try recorder.record(&info_event);
    
    // Record warning event (should be recorded)
    var warning_event = try types.Event.init(
        allocator,
        "test.warning",
        .custom,
        .warning,
        "test",
        .{ .null = {} },
    );
    defer warning_event.deinit();
    try recorder.record(&warning_event);
    
    const count = try recorder.getCount(null);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "event replay" {
    const allocator = std.testing.allocator;
    
    var events = try allocator.alloc(Event, 3);
    
    for (0..3) |i| {
        events[i] = try types.Event.init(
            allocator,
            "test.event",
            .custom,
            .info,
            "test",
            .{ .null = {} },
        );
        events[i].metadata.timestamp = @as(i64, @intCast(i * 1000));
    }
    
    var replayer = EventReplayer.init(allocator, events, .{
        .respect_timestamps = false,
    });
    defer replayer.deinit();
    
    var count: usize = 0;
    while (replayer.replayNext()) |_| {
        count += 1;
    }
    
    try std.testing.expectEqual(@as(usize, 3), count);
    
    // Test reset
    replayer.reset();
    try std.testing.expect(replayer.replayNext() != null);
}