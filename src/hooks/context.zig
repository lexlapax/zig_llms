// ABOUTME: Enhanced hook execution context with data propagation and state management
// ABOUTME: Provides rich context for hooks including metrics, tracing, and data transformation

const std = @import("std");
const types = @import("types.zig");
const RunContext = @import("../context.zig").RunContext;
const Agent = @import("../agent.zig").Agent;
const State = @import("../state.zig").State;

// Enhanced hook context with additional capabilities
pub const EnhancedHookContext = struct {
    // Base context
    base: types.HookContext,

    // State for data propagation between hooks
    state: *State,

    // Parent context for nested hook execution
    parent: ?*EnhancedHookContext = null,

    // Child contexts
    children: std.ArrayList(*EnhancedHookContext),

    // Execution metrics
    metrics: ExecutionMetrics,

    // Trace information
    trace: TraceInfo,

    // Error accumulator
    errors: std.ArrayList(ErrorInfo),

    // Data transformations applied
    transformations: std.ArrayList(Transformation),

    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        point: types.HookPoint,
        run_context: *RunContext,
    ) !EnhancedHookContext {
        const state = try allocator.create(State);
        state.* = State.init(allocator);

        return .{
            .base = types.HookContext.init(allocator, point, run_context),
            .state = state,
            .children = std.ArrayList(*EnhancedHookContext).init(allocator),
            .metrics = ExecutionMetrics.init(),
            .trace = TraceInfo.init(allocator),
            .errors = std.ArrayList(ErrorInfo).init(allocator),
            .transformations = std.ArrayList(Transformation).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *EnhancedHookContext) void {
        self.base.deinit();
        self.state.deinit();
        self.allocator.destroy(self.state);

        for (self.children.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.children.deinit();

        self.trace.deinit();
        self.errors.deinit();
        self.transformations.deinit();
    }

    // Create a child context
    pub fn createChild(self: *EnhancedHookContext, point: types.HookPoint) !*EnhancedHookContext {
        const child = try self.allocator.create(EnhancedHookContext);
        child.* = try EnhancedHookContext.init(self.allocator, point, self.base.run_context);
        child.parent = self;

        // Share state with parent
        child.state.deinit();
        self.allocator.destroy(child.state);
        child.state = self.state;

        try self.children.append(child);
        return child;
    }

    // State management
    pub fn setState(self: *EnhancedHookContext, key: []const u8, value: std.json.Value) !void {
        try self.state.set(key, value);
        try self.recordTransformation(.{ .set = .{ .key = key, .value = value } });
    }

    pub fn getState(self: *const EnhancedHookContext, key: []const u8) ?std.json.Value {
        return self.state.get(key);
    }

    pub fn updateState(
        self: *EnhancedHookContext,
        key: []const u8,
        updater: *const fn (old: ?std.json.Value) std.json.Value,
    ) !void {
        const old_value = self.state.get(key);
        const new_value = updater(old_value);
        try self.state.set(key, new_value);
        try self.recordTransformation(.{
            .update = .{
                .key = key,
                .old_value = old_value,
                .new_value = new_value,
            },
        });
    }

    // Data propagation
    pub fn propagateData(self: *EnhancedHookContext, data: std.json.Value) !void {
        self.base.output_data = data;
        try self.recordTransformation(.{ .propagate = .{ .data = data } });
    }

    // Metrics recording
    pub fn recordMetric(self: *EnhancedHookContext, name: []const u8, value: MetricValue) !void {
        try self.metrics.record(name, value);
    }

    pub fn startTimer(self: *EnhancedHookContext, name: []const u8) void {
        self.metrics.startTimer(name);
    }

    pub fn stopTimer(self: *EnhancedHookContext, name: []const u8) void {
        self.metrics.stopTimer(name);
    }

    // Tracing
    pub fn startSpan(self: *EnhancedHookContext, name: []const u8) !*TraceSpan {
        return self.trace.startSpan(name);
    }

    pub fn addTraceAttribute(self: *EnhancedHookContext, key: []const u8, value: []const u8) !void {
        try self.trace.addAttribute(key, value);
    }

    // Error handling
    pub fn recordError(self: *EnhancedHookContext, err: ErrorInfo) !void {
        try self.errors.append(err);
    }

    pub fn hasErrors(self: *const EnhancedHookContext) bool {
        return self.errors.items.len > 0;
    }

    pub fn getErrors(self: *const EnhancedHookContext) []const ErrorInfo {
        return self.errors.items;
    }

    // Transformation recording
    fn recordTransformation(self: *EnhancedHookContext, transform: Transformation) !void {
        try self.transformations.append(transform);
    }

    // Context information
    pub fn getPath(self: *const EnhancedHookContext, allocator: std.mem.Allocator) ![]const u8 {
        var path_parts = std.ArrayList([]const u8).init(allocator);
        defer path_parts.deinit();

        // Build path from root to current
        var current: ?*const EnhancedHookContext = self;
        while (current) |ctx| {
            try path_parts.insert(0, ctx.base.point.toString());
            current = ctx.parent;
        }

        return try std.mem.join(allocator, "/", path_parts.items);
    }

    pub fn getDepth(self: *const EnhancedHookContext) usize {
        var depth: usize = 0;
        var current = self.parent;
        while (current) |parent| {
            depth += 1;
            current = parent.parent;
        }
        return depth;
    }

    // Export context data
    pub fn exportToJson(self: *const EnhancedHookContext, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();

        try obj.put("point", .{ .string = self.base.point.toString() });
        try obj.put("elapsed_ms", .{ .integer = self.base.getElapsedMs() });
        try obj.put("depth", .{ .integer = @as(i64, @intCast(self.getDepth())) });

        if (try self.getPath(allocator)) |path| {
            try obj.put("path", .{ .string = path });
        }

        // Add state
        if (try self.state.toJson(allocator)) |state_json| {
            try obj.put("state", state_json);
        }

        // Add metrics
        if (try self.metrics.toJson(allocator)) |metrics_json| {
            try obj.put("metrics", metrics_json);
        }

        // Add errors
        if (self.errors.items.len > 0) {
            var errors_array = std.json.Array.init(allocator);
            for (self.errors.items) |err| {
                try errors_array.append(try err.toJson(allocator));
            }
            try obj.put("errors", .{ .array = errors_array });
        }

        return .{ .object = obj };
    }
};

// Execution metrics
pub const ExecutionMetrics = struct {
    counters: std.StringHashMap(i64),
    gauges: std.StringHashMap(f64),
    timers: std.StringHashMap(Timer),
    allocator: std.mem.Allocator,

    const Timer = struct {
        start_time: i64,
        end_time: ?i64 = null,

        pub fn getDuration(self: *const Timer) ?i64 {
            if (self.end_time) |end| {
                return end - self.start_time;
            }
            return null;
        }
    };

    pub fn init() ExecutionMetrics {
        return .{
            .counters = std.StringHashMap(i64).init(std.heap.page_allocator),
            .gauges = std.StringHashMap(f64).init(std.heap.page_allocator),
            .timers = std.StringHashMap(Timer).init(std.heap.page_allocator),
            .allocator = std.heap.page_allocator,
        };
    }

    pub fn deinit(self: *ExecutionMetrics) void {
        self.counters.deinit();
        self.gauges.deinit();
        self.timers.deinit();
    }

    pub fn record(self: *ExecutionMetrics, name: []const u8, value: MetricValue) !void {
        switch (value) {
            .counter => |v| {
                const result = try self.counters.getOrPut(name);
                if (result.found_existing) {
                    result.value_ptr.* += v;
                } else {
                    result.value_ptr.* = v;
                }
            },
            .gauge => |v| try self.gauges.put(name, v),
            .duration => |v| {
                try self.timers.put(name, .{
                    .start_time = std.time.milliTimestamp() - v,
                    .end_time = std.time.milliTimestamp(),
                });
            },
        }
    }

    pub fn startTimer(self: *ExecutionMetrics, name: []const u8) void {
        self.timers.put(name, .{ .start_time = std.time.milliTimestamp() }) catch {};
    }

    pub fn stopTimer(self: *ExecutionMetrics, name: []const u8) void {
        if (self.timers.getPtr(name)) |timer| {
            timer.end_time = std.time.milliTimestamp();
        }
    }

    pub fn toJson(self: *const ExecutionMetrics, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();

        // Add counters
        var counters_obj = std.json.ObjectMap.init(allocator);
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            try counters_obj.put(entry.key_ptr.*, .{ .integer = entry.value_ptr.* });
        }
        try obj.put("counters", .{ .object = counters_obj });

        // Add gauges
        var gauges_obj = std.json.ObjectMap.init(allocator);
        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            try gauges_obj.put(entry.key_ptr.*, .{ .float = entry.value_ptr.* });
        }
        try obj.put("gauges", .{ .object = gauges_obj });

        // Add timers
        var timers_obj = std.json.ObjectMap.init(allocator);
        var timer_iter = self.timers.iterator();
        while (timer_iter.next()) |entry| {
            if (entry.value_ptr.getDuration()) |duration| {
                try timers_obj.put(entry.key_ptr.*, .{ .integer = duration });
            }
        }
        try obj.put("timers", .{ .object = timers_obj });

        return .{ .object = obj };
    }
};

// Metric value types
pub const MetricValue = union(enum) {
    counter: i64,
    gauge: f64,
    duration: i64, // milliseconds
};

// Trace information
pub const TraceInfo = struct {
    trace_id: []const u8,
    spans: std.ArrayList(*TraceSpan),
    attributes: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TraceInfo {
        return .{
            .trace_id = generateTraceId(allocator) catch "unknown",
            .spans = std.ArrayList(*TraceSpan).init(allocator),
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraceInfo) void {
        for (self.spans.items) |span| {
            span.deinit();
            self.allocator.destroy(span);
        }
        self.spans.deinit();
        self.attributes.deinit();
    }

    pub fn startSpan(self: *TraceInfo, name: []const u8) !*TraceSpan {
        const span = try self.allocator.create(TraceSpan);
        span.* = TraceSpan.init(self.allocator, name);
        try self.spans.append(span);
        return span;
    }

    pub fn addAttribute(self: *TraceInfo, key: []const u8, value: []const u8) !void {
        try self.attributes.put(key, value);
    }

    fn generateTraceId(allocator: std.mem.Allocator) ![]const u8 {
        const timestamp = @as(u64, @intCast(std.time.microTimestamp()));
        var rng = std.Random.DefaultPrng.init(timestamp);
        const random = rng.random().int(u32);
        return std.fmt.allocPrint(allocator, "{x}-{x}", .{ timestamp, random });
    }
};

// Trace span
pub const TraceSpan = struct {
    name: []const u8,
    start_time: i64,
    end_time: ?i64 = null,
    attributes: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) TraceSpan {
        return .{
            .name = name,
            .start_time = std.time.microTimestamp(),
            .attributes = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TraceSpan) void {
        self.attributes.deinit();
    }

    pub fn end(self: *TraceSpan) void {
        self.end_time = std.time.microTimestamp();
    }

    pub fn addAttribute(self: *TraceSpan, key: []const u8, value: []const u8) !void {
        try self.attributes.put(key, value);
    }

    pub fn getDuration(self: *const TraceSpan) ?i64 {
        if (self.end_time) |end_time| {
            return end_time - self.start_time;
        }
        return null;
    }
};

// Error information
pub const ErrorInfo = struct {
    error_type: []const u8,
    message: []const u8,
    timestamp: i64,
    hook_id: ?[]const u8 = null,
    recoverable: bool = true,

    pub fn toJson(self: *const ErrorInfo, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();

        try obj.put("error_type", .{ .string = self.error_type });
        try obj.put("message", .{ .string = self.message });
        try obj.put("timestamp", .{ .integer = self.timestamp });
        try obj.put("recoverable", .{ .bool = self.recoverable });

        if (self.hook_id) |id| {
            try obj.put("hook_id", .{ .string = id });
        }

        return .{ .object = obj };
    }
};

// Data transformation types
pub const Transformation = union(enum) {
    set: struct {
        key: []const u8,
        value: std.json.Value,
    },
    update: struct {
        key: []const u8,
        old_value: ?std.json.Value,
        new_value: std.json.Value,
    },
    propagate: struct {
        data: std.json.Value,
    },
    custom: struct {
        type: []const u8,
        data: std.json.Value,
    },
};

// Context builder for fluent API
pub const HookContextBuilder = struct {
    allocator: std.mem.Allocator,
    point: types.HookPoint,
    run_context: *RunContext,
    agent: ?*Agent = null,
    input_data: ?std.json.Value = null,
    metadata: std.StringHashMap(std.json.Value),

    pub fn init(
        allocator: std.mem.Allocator,
        point: types.HookPoint,
        run_context: *RunContext,
    ) HookContextBuilder {
        return .{
            .allocator = allocator,
            .point = point,
            .run_context = run_context,
            .metadata = std.StringHashMap(std.json.Value).init(allocator),
        };
    }

    pub fn deinit(self: *HookContextBuilder) void {
        self.metadata.deinit();
    }

    pub fn withAgent(self: *HookContextBuilder, agent: *Agent) *HookContextBuilder {
        self.agent = agent;
        return self;
    }

    pub fn withInputData(self: *HookContextBuilder, data: std.json.Value) *HookContextBuilder {
        self.input_data = data;
        return self;
    }

    pub fn withMetadata(self: *HookContextBuilder, key: []const u8, value: std.json.Value) !*HookContextBuilder {
        try self.metadata.put(key, value);
        return self;
    }

    pub fn build(self: *HookContextBuilder) !*EnhancedHookContext {
        const context = try self.allocator.create(EnhancedHookContext);
        context.* = try EnhancedHookContext.init(self.allocator, self.point, self.run_context);

        context.base.agent = self.agent;
        context.base.input_data = self.input_data;

        // Copy metadata
        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            try context.base.setMetadata(entry.key_ptr.*, entry.value_ptr.*);
        }

        return context;
    }
};

// Tests
test "enhanced hook context" {
    const allocator = std.testing.allocator;

    var run_context = try RunContext.init(allocator, .{});
    defer run_context.deinit();

    var context = try EnhancedHookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();

    // Test state management
    try context.setState("test_key", .{ .string = "test_value" });
    const value = context.getState("test_key");
    try std.testing.expect(value != null);
    try std.testing.expectEqualStrings("test_value", value.?.string);

    // Test metrics
    try context.recordMetric("counter", .{ .counter = 5 });
    try context.recordMetric("gauge", .{ .gauge = 3.14 });

    context.startTimer("operation");
    std.time.sleep(10 * std.time.ns_per_ms);
    context.stopTimer("operation");

    // Test child context
    const child = try context.createChild(.agent_after_run);
    try std.testing.expectEqual(@as(usize, 1), context.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), child.getDepth());

    // Test error recording
    try context.recordError(.{
        .error_type = "TestError",
        .message = "Test error message",
        .timestamp = std.time.milliTimestamp(),
    });
    try std.testing.expect(context.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), context.getErrors().len);
}

test "hook context builder" {
    const allocator = std.testing.allocator;

    var run_context = try RunContext.init(allocator, .{});
    defer run_context.deinit();

    var builder = HookContextBuilder.init(allocator, .agent_before_run, &run_context);
    defer builder.deinit();

    const context = try builder
        .withInputData(.{ .string = "test input" })
        .withMetadata("key", .{ .string = "value" })
        .build();
    defer {
        context.deinit();
        allocator.destroy(context);
    }

    try std.testing.expect(context.base.input_data != null);
    try std.testing.expectEqualStrings("test input", context.base.input_data.?.string);
    try std.testing.expect(context.base.getMetadata("key") != null);
}
