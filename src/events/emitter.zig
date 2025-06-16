// ABOUTME: Event emitter with pattern matching and subscription management
// ABOUTME: Provides pub/sub functionality with wildcard patterns and async delivery

const std = @import("std");
const types = @import("types.zig");
const Event = types.Event;
const EventCategory = types.EventCategory;
const EventSeverity = types.EventSeverity;

// Event handler function type
pub const EventHandler = *const fn (event: *const Event, context: ?*anyopaque) void;
pub const AsyncEventHandler = *const fn (event: *const Event, context: ?*anyopaque) anyerror!void;

// Subscription options
pub const SubscriptionOptions = struct {
    async_delivery: bool = false,
    filter_severity: ?EventSeverity = null,
    filter_categories: ?[]const EventCategory = null,
    filter_tags: ?[]const []const u8 = null,
    max_retries: u8 = 0,
    retry_delay_ms: u32 = 100,
};

// Subscription
pub const Subscription = struct {
    id: []const u8,
    pattern: []const u8,
    handler: EventHandler,
    async_handler: ?AsyncEventHandler = null,
    context: ?*anyopaque = null,
    options: SubscriptionOptions,
    active: bool = true,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Subscription) void {
        self.allocator.free(self.id);
    }

    pub fn matches(self: *const Subscription, event: *const Event) bool {
        if (!self.active) return false;

        // Check pattern match
        if (!matchesPattern(event.name, self.pattern)) return false;

        // Check severity filter
        if (self.options.filter_severity) |min_severity| {
            if (@intFromEnum(event.severity) < @intFromEnum(min_severity)) return false;
        }

        // Check category filter
        if (self.options.filter_categories) |categories| {
            var found = false;
            for (categories) |cat| {
                if (cat == event.category) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }

        // Check tag filter
        if (self.options.filter_tags) |required_tags| {
            for (required_tags) |required_tag| {
                var found = false;
                for (event.metadata.tags) |event_tag| {
                    if (std.mem.eql(u8, required_tag, event_tag)) {
                        found = true;
                        break;
                    }
                }
                if (!found) return false;
            }
        }

        return true;
    }
};

// Event emitter
pub const EventEmitter = struct {
    allocator: std.mem.Allocator,
    subscriptions: std.StringHashMap(Subscription),
    event_queue: std.ArrayList(Event),
    mutex: std.Thread.Mutex = .{},
    worker_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    config: EmitterConfig,

    pub const EmitterConfig = struct {
        max_queue_size: usize = 10000,
        async_processing: bool = true,
        batch_size: usize = 100,
        flush_interval_ms: u32 = 100,
        error_handler: ?*const fn (err: anyerror, event: *const Event) void = null,
    };

    pub fn init(allocator: std.mem.Allocator, config: EmitterConfig) EventEmitter {
        return .{
            .allocator = allocator,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .event_queue = std.ArrayList(Event).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *EventEmitter) void {
        if (self.running.load(.acquire)) {
            self.stop();
        }

        // Clean up subscriptions
        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.subscriptions.deinit();

        // Clean up queued events
        for (self.event_queue.items) |*event| {
            event.deinit();
        }
        self.event_queue.deinit();
    }

    pub fn start(self: *EventEmitter) !void {
        if (self.running.swap(true, .acq_rel)) {
            return; // Already running
        }

        if (self.config.async_processing) {
            self.worker_thread = try std.Thread.spawn(.{}, processEvents, .{self});
        }
    }

    pub fn stop(self: *EventEmitter) void {
        self.running.store(false, .release);

        if (self.worker_thread) |thread| {
            thread.join();
            self.worker_thread = null;
        }

        // Process remaining events
        self.flushEvents();
    }

    pub fn subscribe(
        self: *EventEmitter,
        pattern: []const u8,
        handler: EventHandler,
        options: SubscriptionOptions,
    ) ![]const u8 {
        const id = try generateSubscriptionId(self.allocator);

        const subscription = Subscription{
            .id = id,
            .pattern = pattern,
            .handler = handler,
            .options = options,
            .allocator = self.allocator,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.subscriptions.put(id, subscription);
        return id;
    }

    pub fn subscribeAsync(
        self: *EventEmitter,
        pattern: []const u8,
        handler: AsyncEventHandler,
        options: SubscriptionOptions,
    ) ![]const u8 {
        const id = try generateSubscriptionId(self.allocator);

        var opts = options;
        opts.async_delivery = true;

        const subscription = Subscription{
            .id = id,
            .pattern = pattern,
            .handler = dummyHandler,
            .async_handler = handler,
            .options = opts,
            .allocator = self.allocator,
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.subscriptions.put(id, subscription);
        return id;
    }

    pub fn unsubscribe(self: *EventEmitter, subscription_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.fetchRemove(subscription_id)) |entry| {
            var sub = entry.value;
            sub.deinit();
            return true;
        }
        return false;
    }

    pub fn emit(self: *EventEmitter, event: Event) !void {
        if (self.config.async_processing and self.running.load(.acquire)) {
            // Queue event for async processing
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.event_queue.items.len >= self.config.max_queue_size) {
                return error.QueueFull;
            }

            try self.event_queue.append(event);
        } else {
            // Process synchronously
            self.processEvent(&event);
        }
    }

    pub fn emitNow(self: *EventEmitter, event: *const Event) void {
        self.processEvent(event);
    }

    fn processEvent(self: *EventEmitter, event: *const Event) void {
        self.mutex.lock();
        var subs_copy = std.ArrayList(Subscription).init(self.allocator);
        defer subs_copy.deinit();

        // Copy matching subscriptions to avoid holding lock during callbacks
        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.matches(event)) {
                subs_copy.append(entry.value_ptr.*) catch continue;
            }
        }
        self.mutex.unlock();

        // Process subscriptions
        for (subs_copy.items) |sub| {
            if (sub.options.async_delivery) {
                if (sub.async_handler) |handler| {
                    self.processAsyncHandler(handler, event, sub.context, &sub.options);
                }
            } else {
                sub.handler(event, sub.context);
            }
        }
    }

    fn processAsyncHandler(
        self: *EventEmitter,
        handler: AsyncEventHandler,
        event: *const Event,
        context: ?*anyopaque,
        options: *const SubscriptionOptions,
    ) void {
        var retries: u8 = 0;

        while (retries <= options.max_retries) : (retries += 1) {
            if (retries > 0) {
                std.time.sleep(options.retry_delay_ms * std.time.ns_per_ms);
            }

            handler(event, context) catch |err| {
                if (retries >= options.max_retries) {
                    if (self.config.error_handler) |error_handler| {
                        error_handler(err, event);
                    }
                    return;
                }
                continue;
            };

            return; // Success
        }
    }

    fn processEvents(self: *EventEmitter) void {
        while (self.running.load(.acquire)) {
            self.flushEvents();
            std.time.sleep(self.config.flush_interval_ms * std.time.ns_per_ms);
        }
    }

    fn flushEvents(self: *EventEmitter) void {
        while (true) {
            self.mutex.lock();

            if (self.event_queue.items.len == 0) {
                self.mutex.unlock();
                break;
            }

            // Get batch of events
            const batch_size = @min(self.config.batch_size, self.event_queue.items.len);
            var batch = std.ArrayList(Event).init(self.allocator);
            defer batch.deinit();

            var i: usize = 0;
            while (i < batch_size) : (i += 1) {
                batch.append(self.event_queue.orderedRemove(0)) catch break;
            }

            self.mutex.unlock();

            // Process batch
            for (batch.items) |*event| {
                self.processEvent(event);
                event.deinit();
            }
        }
    }

    pub fn getActiveSubscriptions(self: *EventEmitter) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        var count: usize = 0;
        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.active) count += 1;
        }
        return count;
    }

    pub fn pauseSubscription(self: *EventEmitter, subscription_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.getPtr(subscription_id)) |sub| {
            sub.active = false;
            return true;
        }
        return false;
    }

    pub fn resumeSubscription(self: *EventEmitter, subscription_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subscriptions.getPtr(subscription_id)) |sub| {
            sub.active = true;
            return true;
        }
        return false;
    }
};

// Pattern matching
fn matchesPattern(event_name: []const u8, pattern: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, event_name, pattern)) return true;

    // Wildcard match
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, event_name, prefix);
    }

    // Hierarchical match (e.g., "agent.*.started" matches "agent.llm.started")
    var event_parts = std.mem.tokenize(u8, event_name, ".");
    var pattern_parts = std.mem.tokenize(u8, pattern, ".");

    while (true) {
        const event_part = event_parts.next();
        const pattern_part = pattern_parts.next();

        if (event_part == null and pattern_part == null) return true;
        if (event_part == null or pattern_part == null) return false;

        if (std.mem.eql(u8, pattern_part.?, "*")) continue;
        if (!std.mem.eql(u8, event_part.?, pattern_part.?)) return false;
    }
}

fn generateSubscriptionId(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = @as(u64, @intCast(std.time.microTimestamp()));
    var rng = std.Random.DefaultPrng.init(timestamp);
    const random = rng.random().int(u32);

    return std.fmt.allocPrint(allocator, "sub-{x}-{x}", .{ timestamp, random });
}

fn dummyHandler(event: *const Event, context: ?*anyopaque) void {
    _ = event;
    _ = context;
}

// Global event emitter instance
var global_emitter: ?*EventEmitter = null;
var global_mutex = std.Thread.Mutex{};

pub fn getGlobalEmitter() !*EventEmitter {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_emitter) |emitter| {
        return emitter;
    }

    return error.GlobalEmitterNotInitialized;
}

pub fn initGlobalEmitter(allocator: std.mem.Allocator, config: EventEmitter.EmitterConfig) !void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_emitter != null) {
        return error.GlobalEmitterAlreadyInitialized;
    }

    const emitter = try allocator.create(EventEmitter);
    emitter.* = EventEmitter.init(allocator, config);
    try emitter.start();

    global_emitter = emitter;
}

pub fn deinitGlobalEmitter() void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_emitter) |emitter| {
        emitter.stop();
        emitter.deinit();
        emitter.allocator.destroy(emitter);
        global_emitter = null;
    }
}

// Tests
test "pattern matching" {
    try std.testing.expect(matchesPattern("agent.started", "agent.started"));
    try std.testing.expect(matchesPattern("agent.started", "agent.*"));
    try std.testing.expect(matchesPattern("agent.llm.started", "agent.*.started"));
    try std.testing.expect(!matchesPattern("tool.invoked", "agent.*"));
}

test "event emitter subscription" {
    const allocator = std.testing.allocator;

    var emitter = EventEmitter.init(allocator, .{ .async_processing = false });
    defer emitter.deinit();

    const TestContext = struct {
        received: bool = false,
    };

    var context = TestContext{};

    const handler = struct {
        fn handle(event: *const Event, ctx: ?*anyopaque) void {
            _ = event;
            if (ctx) |c| {
                const test_ctx: *TestContext = @ptrCast(@alignCast(c));
                test_ctx.received = true;
            }
        }
    }.handle;

    const sub_id = try emitter.subscribe("test.*", handler, .{});
    defer _ = emitter.unsubscribe(sub_id);

    // Update subscription to include context
    if (emitter.subscriptions.getPtr(sub_id)) |sub| {
        sub.context = &context;
    }

    var event = try types.Event.init(
        allocator,
        "test.event",
        .custom,
        .info,
        "test",
        .{ .null = {} },
    );
    defer event.deinit();

    try emitter.emit(event);

    try std.testing.expect(context.received);
}

test "event filtering" {
    const allocator = std.testing.allocator;

    var emitter = EventEmitter.init(allocator, .{ .async_processing = false });
    defer emitter.deinit();

    const handler = struct {
        fn handle(event: *const Event, ctx: ?*anyopaque) void {
            _ = event;
            _ = ctx;
        }
    }.handle;

    // Subscribe with severity filter
    const sub_id = try emitter.subscribe("*", handler, .{
        .filter_severity = .warning,
    });
    defer _ = emitter.unsubscribe(sub_id);

    const sub = emitter.subscriptions.get(sub_id).?;

    // Info event should not match
    var info_event = try types.Event.init(
        allocator,
        "test.info",
        .custom,
        .info,
        "test",
        .{ .null = {} },
    );
    defer info_event.deinit();
    try std.testing.expect(!sub.matches(&info_event));

    // Warning event should match
    var warning_event = try types.Event.init(
        allocator,
        "test.warning",
        .custom,
        .warning,
        "test",
        .{ .null = {} },
    );
    defer warning_event.deinit();
    try std.testing.expect(sub.matches(&warning_event));
}
