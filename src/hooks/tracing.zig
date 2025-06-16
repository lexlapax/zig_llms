// ABOUTME: Distributed tracing support for tracking execution across agents and workflows
// ABOUTME: Implements OpenTelemetry-compatible tracing with spans, contexts, and exporters

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;
const context_mod = @import("context.zig");

// Trace ID and Span ID types
pub const TraceId = [16]u8;
pub const SpanId = [8]u8;

// Span status
pub const SpanStatus = enum {
    unset,
    ok,
    err,

    pub fn toString(self: SpanStatus) []const u8 {
        return @tagName(self);
    }
};

// Span kind
pub const SpanKind = enum {
    internal,
    server,
    client,
    producer,
    consumer,

    pub fn toString(self: SpanKind) []const u8 {
        return @tagName(self);
    }
};

// Span attributes
pub const SpanAttributes = std.StringHashMap(AttributeValue);

pub const AttributeValue = union(enum) {
    string: []const u8,
    bool: bool,
    int: i64,
    float: f64,
    string_array: []const []const u8,
    bool_array: []const bool,
    int_array: []const i64,
    float_array: []const f64,
};

// Span event
pub const SpanEvent = struct {
    name: []const u8,
    timestamp: i64,
    attributes: SpanAttributes,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) SpanEvent {
        return .{
            .name = name,
            .timestamp = std.time.microTimestamp(),
            .attributes = SpanAttributes.init(allocator),
        };
    }

    pub fn deinit(self: *SpanEvent) void {
        self.attributes.deinit();
    }
};

// Span link
pub const SpanLink = struct {
    trace_id: TraceId,
    span_id: SpanId,
    attributes: SpanAttributes,

    pub fn init(allocator: std.mem.Allocator, trace_id: TraceId, span_id: SpanId) SpanLink {
        return .{
            .trace_id = trace_id,
            .span_id = span_id,
            .attributes = SpanAttributes.init(allocator),
        };
    }

    pub fn deinit(self: *SpanLink) void {
        self.attributes.deinit();
    }
};

// Span data
pub const Span = struct {
    trace_id: TraceId,
    span_id: SpanId,
    parent_span_id: ?SpanId,
    name: []const u8,
    kind: SpanKind,
    start_time: i64,
    end_time: ?i64,
    status: SpanStatus,
    status_message: ?[]const u8,
    attributes: SpanAttributes,
    events: std.ArrayList(SpanEvent),
    links: std.ArrayList(SpanLink),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        trace_id: TraceId,
        span_id: SpanId,
        name: []const u8,
        kind: SpanKind,
    ) Span {
        return .{
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = null,
            .name = name,
            .kind = kind,
            .start_time = std.time.microTimestamp(),
            .end_time = null,
            .status = .unset,
            .status_message = null,
            .attributes = SpanAttributes.init(allocator),
            .events = std.ArrayList(SpanEvent).init(allocator),
            .links = std.ArrayList(SpanLink).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Span) void {
        self.attributes.deinit();
        for (self.events.items) |*event| {
            event.deinit();
        }
        self.events.deinit();
        for (self.links.items) |*link| {
            link.deinit();
        }
        self.links.deinit();
    }

    pub fn end(self: *Span) void {
        if (self.end_time == null) {
            self.end_time = std.time.microTimestamp();
        }
    }

    pub fn setStatus(self: *Span, status: SpanStatus, message: ?[]const u8) void {
        self.status = status;
        self.status_message = message;
    }

    pub fn setAttribute(self: *Span, key: []const u8, value: AttributeValue) !void {
        try self.attributes.put(key, value);
    }

    pub fn addEvent(self: *Span, event: SpanEvent) !void {
        try self.events.append(event);
    }

    pub fn addLink(self: *Span, link: SpanLink) !void {
        try self.links.append(link);
    }

    pub fn duration(self: *const Span) ?i64 {
        if (self.end_time) |end| {
            return end - self.start_time;
        }
        return null;
    }
};

// Trace context
pub const TraceContext = struct {
    trace_id: TraceId,
    span_id: SpanId,
    trace_flags: u8,
    trace_state: ?[]const u8,

    pub fn init(trace_id: TraceId, span_id: SpanId) TraceContext {
        return .{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_flags = 0x01, // Sampled
            .trace_state = null,
        };
    }

    pub fn generateTraceId() TraceId {
        var id: TraceId = undefined;
        std.crypto.random.bytes(&id);
        return id;
    }

    pub fn generateSpanId() SpanId {
        var id: SpanId = undefined;
        std.crypto.random.bytes(&id);
        return id;
    }

    // W3C Trace Context format
    pub fn toW3CHeader(self: *const TraceContext, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "00-{}-{}-{x:0>2}",
            .{
                std.fmt.fmtSliceHexLower(&self.trace_id),
                std.fmt.fmtSliceHexLower(&self.span_id),
                self.trace_flags,
            },
        );
    }

    pub fn fromW3CHeader(header: []const u8) !TraceContext {
        if (header.len < 55) return error.InvalidTraceHeader;

        var parts = std.mem.tokenize(u8, header, "-");

        const version = parts.next() orelse return error.InvalidTraceHeader;
        if (!std.mem.eql(u8, version, "00")) return error.UnsupportedVersion;

        const trace_id_str = parts.next() orelse return error.InvalidTraceHeader;
        if (trace_id_str.len != 32) return error.InvalidTraceId;

        const span_id_str = parts.next() orelse return error.InvalidTraceHeader;
        if (span_id_str.len != 16) return error.InvalidSpanId;

        const flags_str = parts.next() orelse return error.InvalidTraceHeader;
        if (flags_str.len != 2) return error.InvalidFlags;

        var trace_id: TraceId = undefined;
        _ = try std.fmt.hexToBytes(&trace_id, trace_id_str);

        var span_id: SpanId = undefined;
        _ = try std.fmt.hexToBytes(&span_id, span_id_str);

        const trace_flags = try std.fmt.parseInt(u8, flags_str, 16);

        return TraceContext{
            .trace_id = trace_id,
            .span_id = span_id,
            .trace_flags = trace_flags,
            .trace_state = null,
        };
    }
};

// Span processor interface
pub const SpanProcessor = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        onStart: *const fn (processor: *SpanProcessor, span: *Span) void,
        onEnd: *const fn (processor: *SpanProcessor, span: *Span) void,
        forceFlush: *const fn (processor: *SpanProcessor) anyerror!void,
        shutdown: *const fn (processor: *SpanProcessor) void,
    };

    pub fn onStart(self: *SpanProcessor, span: *Span) void {
        self.vtable.onStart(self, span);
    }

    pub fn onEnd(self: *SpanProcessor, span: *Span) void {
        self.vtable.onEnd(self, span);
    }

    pub fn forceFlush(self: *SpanProcessor) !void {
        return self.vtable.forceFlush(self);
    }

    pub fn shutdown(self: *SpanProcessor) void {
        self.vtable.shutdown(self);
    }
};

// Span exporter interface
pub const SpanExporter = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        exportSpans: *const fn (exporter: *SpanExporter, spans: []const *Span) anyerror!void,
        shutdown: *const fn (exporter: *SpanExporter) void,
    };

    pub fn exportSpans(self: *SpanExporter, spans: []const *Span) !void {
        return self.vtable.exportSpans(self, spans);
    }

    pub fn shutdown(self: *SpanExporter) void {
        self.vtable.shutdown(self);
    }
};

// Batch span processor
pub const BatchSpanProcessor = struct {
    processor: SpanProcessor,
    exporter: *SpanExporter,
    batch: std.ArrayList(*Span),
    max_batch_size: usize,
    export_timeout_ms: u64,
    last_export: i64,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        exporter: *SpanExporter,
        max_batch_size: usize,
        export_timeout_ms: u64,
    ) !*BatchSpanProcessor {
        const self = try allocator.create(BatchSpanProcessor);
        self.* = .{
            .processor = .{
                .vtable = &.{
                    .onStart = onStart,
                    .onEnd = onEnd,
                    .forceFlush = forceFlush,
                    .shutdown = shutdown,
                },
            },
            .exporter = exporter,
            .batch = std.ArrayList(*Span).init(allocator),
            .max_batch_size = max_batch_size,
            .export_timeout_ms = export_timeout_ms,
            .last_export = std.time.milliTimestamp(),
            .mutex = .{},
            .allocator = allocator,
        };
        return self;
    }

    fn onStart(processor: *SpanProcessor, span: *Span) void {
        _ = processor;
        _ = span;
        // No action on start for batch processor
    }

    fn onEnd(processor: *SpanProcessor, span: *Span) void {
        const self = @fieldParentPtr(BatchSpanProcessor, "processor", processor);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.batch.append(span) catch return;

        // Check if we should export
        const now = std.time.milliTimestamp();
        const should_export = self.batch.items.len >= self.max_batch_size or
            (now - self.last_export) >= @as(i64, @intCast(self.export_timeout_ms));

        if (should_export) {
            self.exportBatch() catch {};
        }
    }

    fn forceFlush(processor: *SpanProcessor) !void {
        const self = @fieldParentPtr(BatchSpanProcessor, "processor", processor);

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.exportBatch();
    }

    fn shutdown(processor: *SpanProcessor) void {
        const self = @fieldParentPtr(BatchSpanProcessor, "processor", processor);

        self.forceFlush(processor) catch {};
        self.batch.deinit();
        self.exporter.shutdown();
        self.allocator.destroy(self);
    }

    fn exportBatch(self: *BatchSpanProcessor) !void {
        if (self.batch.items.len == 0) return;

        const spans = try self.allocator.dupe(*Span, self.batch.items);
        defer self.allocator.free(spans);

        try self.exporter.exportSpans(spans);

        self.batch.clearRetainingCapacity();
        self.last_export = std.time.milliTimestamp();
    }
};

// Console span exporter
pub const ConsoleSpanExporter = struct {
    exporter: SpanExporter,
    pretty_print: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pretty_print: bool) !*ConsoleSpanExporter {
        const self = try allocator.create(ConsoleSpanExporter);
        self.* = .{
            .exporter = .{
                .vtable = &.{
                    .exportSpans = exportSpans,
                    .shutdown = shutdown,
                },
            },
            .pretty_print = pretty_print,
            .allocator = allocator,
        };
        return self;
    }

    fn exportSpans(exporter: *SpanExporter, spans: []const *Span) !void {
        const self = @fieldParentPtr(ConsoleSpanExporter, "exporter", exporter);

        const out = std.io.getStdOut().writer();

        for (spans) |span| {
            if (self.pretty_print) {
                try out.print("=== Span: {s} ===\n", .{span.name});
                try out.print("  Trace ID: {}\n", .{std.fmt.fmtSliceHexLower(&span.trace_id)});
                try out.print("  Span ID: {}\n", .{std.fmt.fmtSliceHexLower(&span.span_id)});
                if (span.parent_span_id) |parent| {
                    try out.print("  Parent ID: {}\n", .{std.fmt.fmtSliceHexLower(&parent)});
                }
                try out.print("  Kind: {s}\n", .{span.kind.toString()});
                try out.print("  Status: {s}\n", .{span.status.toString()});
                if (span.duration()) |dur| {
                    try out.print("  Duration: {d}μs\n", .{dur});
                }

                if (span.attributes.count() > 0) {
                    try out.writeAll("  Attributes:\n");
                    var iter = span.attributes.iterator();
                    while (iter.next()) |entry| {
                        try out.print("    {s}: ", .{entry.key_ptr.*});
                        try self.printAttributeValue(out, entry.value_ptr.*);
                        try out.writeByte('\n');
                    }
                }

                if (span.events.items.len > 0) {
                    try out.writeAll("  Events:\n");
                    for (span.events.items) |event| {
                        try out.print("    - {s} @ {d}\n", .{ event.name, event.timestamp });
                    }
                }

                try out.writeByte('\n');
            } else {
                // Compact format
                var obj = std.json.ObjectMap.init(self.allocator);
                defer obj.deinit();

                try obj.put("trace_id", .{ .string = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&span.trace_id)}) });
                try obj.put("span_id", .{ .string = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&span.span_id)}) });
                try obj.put("name", .{ .string = span.name });
                try obj.put("kind", .{ .string = span.kind.toString() });
                try obj.put("status", .{ .string = span.status.toString() });

                try std.json.stringify(std.json.Value{ .object = obj }, .{}, out);
                try out.writeByte('\n');
            }
        }
    }

    fn printAttributeValue(self: *ConsoleSpanExporter, writer: anytype, value: AttributeValue) !void {
        _ = self;
        switch (value) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .bool => |b| try writer.print("{}", .{b}),
            .int => |i| try writer.print("{d}", .{i}),
            .float => |f| try writer.print("{d}", .{f}),
            .string_array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |s, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("\"{s}\"", .{s});
                }
                try writer.writeByte(']');
            },
            .bool_array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |b, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{}", .{b});
                }
                try writer.writeByte(']');
            },
            .int_array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |n, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{n});
                }
                try writer.writeByte(']');
            },
            .float_array => |arr| {
                try writer.writeByte('[');
                for (arr, 0..) |f, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{f});
                }
                try writer.writeByte(']');
            },
        }
    }

    fn shutdown(exporter: *SpanExporter) void {
        const self = @fieldParentPtr(ConsoleSpanExporter, "exporter", exporter);
        self.allocator.destroy(self);
    }
};

// Tracer
pub const Tracer = struct {
    name: []const u8,
    version: []const u8,
    processor: *SpanProcessor,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        version: []const u8,
        processor: *SpanProcessor,
    ) Tracer {
        return .{
            .name = name,
            .version = version,
            .processor = processor,
            .allocator = allocator,
        };
    }

    pub fn startSpan(
        self: *Tracer,
        name: []const u8,
        kind: SpanKind,
        parent_context: ?*const TraceContext,
    ) !*Span {
        const trace_id = if (parent_context) |ctx| ctx.trace_id else TraceContext.generateTraceId();
        const span_id = TraceContext.generateSpanId();

        const span = try self.allocator.create(Span);
        span.* = Span.init(self.allocator, trace_id, span_id, name, kind);

        if (parent_context) |ctx| {
            span.parent_span_id = ctx.span_id;
        }

        // Set default attributes
        try span.setAttribute("service.name", .{ .string = self.name });
        try span.setAttribute("service.version", .{ .string = self.version });

        self.processor.onStart(span);

        return span;
    }

    pub fn endSpan(self: *Tracer, span: *Span) void {
        span.end();
        self.processor.onEnd(span);
    }
};

// Tracing hook
pub const TracingHook = struct {
    hook: Hook,
    tracer: Tracer,
    active_spans: std.AutoHashMap(usize, *Span),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        tracer: Tracer,
    ) !*TracingHook {
        const self = try allocator.create(TracingHook);

        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = execute,
            .deinit = hookDeinit,
        };

        self.* = .{
            .hook = .{
                .id = id,
                .name = "Tracing Hook",
                .description = "Distributed tracing for hook execution",
                .vtable = vtable,
                .priority = .highest, // Run early to capture full execution
                .supported_points = &[_]HookPoint{.custom}, // Supports all points
                .config = .{ .integer = @intFromPtr(self) },
            },
            .tracer = tracer,
            .active_spans = std.AutoHashMap(usize, *Span).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };

        return self;
    }

    fn hookDeinit(hook: *Hook) void {
        const self = @as(*TracingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        // End any remaining spans
        var iter = self.active_spans.iterator();
        while (iter.next()) |entry| {
            self.tracer.endSpan(entry.value_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.active_spans.deinit();

        self.allocator.destroy(hook.vtable);
        self.allocator.destroy(self);
    }

    fn execute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @as(*TracingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        // Generate unique key for this execution
        const key = @intFromPtr(context);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we're starting or ending a span
        if (self.active_spans.get(key)) |span| {
            // End span
            span.end();

            // Add final attributes
            try span.setAttribute("hook.total_hooks", .{ .int = @as(i64, @intCast(context.total_hooks)) });

            self.tracer.endSpan(span);
            _ = self.active_spans.remove(key);

            span.deinit();
            self.allocator.destroy(span);
        } else {
            // Start new span
            const span_name = try std.fmt.allocPrint(
                self.allocator,
                "{s}@{s}",
                .{ hook.id, context.point.toString() },
            );
            defer self.allocator.free(span_name);

            // Extract parent context if available
            var parent_context: ?TraceContext = null;
            if (context.getMetadata("trace_context")) |ctx| {
                if (ctx == .string) {
                    parent_context = TraceContext.fromW3CHeader(ctx.string) catch null;
                }
            }

            const span = try self.tracer.startSpan(
                span_name,
                .internal,
                if (parent_context) |*ctx| ctx else null,
            );

            // Add span attributes
            try span.setAttribute("hook.id", .{ .string = hook.id });
            try span.setAttribute("hook.point", .{ .string = context.point.toString() });
            try span.setAttribute("hook.index", .{ .int = @as(i64, @intCast(context.hook_index)) });

            if (context.agent) |agent| {
                if (agent.state.metadata.get("agent_name")) |name| {
                    try span.setAttribute("agent.name", .{ .string = name.string });
                }
            }

            // Store span for later
            try self.active_spans.put(key, span);

            // Add trace context to hook context for propagation
            const trace_ctx = TraceContext.init(span.trace_id, span.span_id);
            const header = try trace_ctx.toW3CHeader(context.allocator);
            try context.setMetadata("trace_context", .{ .string = header });
        }

        return HookResult{ .continue_processing = true };
    }
};

// Builder for tracing hook
pub fn createTracingHook(
    allocator: std.mem.Allocator,
    id: []const u8,
    service_name: []const u8,
    service_version: []const u8,
) !*Hook {
    // Create console exporter
    const exporter = try ConsoleSpanExporter.init(allocator, true);

    // Create batch processor
    const processor = try BatchSpanProcessor.init(allocator, &exporter.exporter, 100, 5000);

    // Create tracer
    const tracer = Tracer.init(allocator, service_name, service_version, &processor.processor);

    // Create tracing hook
    const tracing_hook = try TracingHook.init(allocator, id, tracer);

    return &tracing_hook.hook;
}

// Tests
test "trace context" {
    const trace_id = TraceContext.generateTraceId();
    const span_id = TraceContext.generateSpanId();

    const ctx = TraceContext.init(trace_id, span_id);

    const allocator = std.testing.allocator;
    const header = try ctx.toW3CHeader(allocator);
    defer allocator.free(header);

    const parsed = try TraceContext.fromW3CHeader(header);

    try std.testing.expectEqualSlices(u8, &ctx.trace_id, &parsed.trace_id);
    try std.testing.expectEqualSlices(u8, &ctx.span_id, &parsed.span_id);
    try std.testing.expectEqual(ctx.trace_flags, parsed.trace_flags);
}

test "span lifecycle" {
    const allocator = std.testing.allocator;

    const trace_id = TraceContext.generateTraceId();
    const span_id = TraceContext.generateSpanId();

    var span = Span.init(allocator, trace_id, span_id, "test_span", .internal);
    defer span.deinit();

    try span.setAttribute("test.attribute", .{ .string = "test_value" });
    try span.setAttribute("test.number", .{ .int = 42 });

    var event = SpanEvent.init(allocator, "test_event");
    defer event.deinit();
    try event.attributes.put("event.detail", .{ .string = "something happened" });
    try span.addEvent(event);

    span.setStatus(.ok, "completed successfully");
    span.end();

    try std.testing.expect(span.end_time != null);
    try std.testing.expect(span.duration() != null);
    try std.testing.expectEqual(@as(usize, 2), span.attributes.count());
    try std.testing.expectEqual(@as(usize, 1), span.events.items.len);
}

test "tracer" {
    const allocator = std.testing.allocator;

    // Create a no-op exporter for testing
    const NoOpExporter = struct {
        exporter: SpanExporter,

        fn exportSpans(exp: *SpanExporter, spans: []const *Span) !void {
            _ = exp;
            _ = spans;
        }

        fn shutdown(exp: *SpanExporter) void {
            _ = exp;
        }
    };

    var noop = NoOpExporter{
        .exporter = .{
            .vtable = &.{
                .exportSpans = NoOpExporter.exportSpans,
                .shutdown = NoOpExporter.shutdown,
            },
        },
    };

    const processor = try BatchSpanProcessor.init(allocator, &noop.exporter, 10, 1000);
    defer processor.processor.shutdown();

    var tracer = Tracer.init(allocator, "test_service", "1.0.0", &processor.processor);

    const span = try tracer.startSpan("test_operation", .internal, null);
    defer {
        span.deinit();
        allocator.destroy(span);
    }

    try span.setAttribute("test.key", .{ .string = "test_value" });

    tracer.endSpan(span);

    try std.testing.expectEqualStrings("test_operation", span.name);
    try std.testing.expect(span.end_time != null);
}
