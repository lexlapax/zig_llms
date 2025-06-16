// ABOUTME: Performance metrics collection hook for monitoring agent and workflow execution
// ABOUTME: Provides comprehensive metrics tracking including latency, throughput, and resource usage

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;
const builders = @import("builders.zig");
const registry = @import("registry.zig");

// Metric types
pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary,

    pub fn toString(self: MetricType) []const u8 {
        return @tagName(self);
    }
};

// Metric value
pub const MetricValue = union(MetricType) {
    counter: i64,
    gauge: f64,
    histogram: HistogramValue,
    summary: SummaryValue,

    pub const HistogramValue = struct {
        count: u64,
        sum: f64,
        buckets: []const BucketCount,

        pub const BucketCount = struct {
            upper_bound: f64,
            count: u64,
        };
    };

    pub const SummaryValue = struct {
        count: u64,
        sum: f64,
        quantiles: []const Quantile,

        pub const Quantile = struct {
            quantile: f64,
            value: f64,
        };
    };
};

// Metric definition
pub const Metric = struct {
    name: []const u8,
    description: []const u8,
    type: MetricType,
    labels: std.StringHashMap([]const u8),
    value: MetricValue,
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, metric_type: MetricType) Metric {
        return .{
            .name = name,
            .description = "",
            .type = metric_type,
            .labels = std.StringHashMap([]const u8).init(allocator),
            .value = switch (metric_type) {
                .counter => .{ .counter = 0 },
                .gauge => .{ .gauge = 0.0 },
                .histogram => .{ .histogram = .{ .count = 0, .sum = 0, .buckets = &.{} } },
                .summary => .{ .summary = .{ .count = 0, .sum = 0, .quantiles = &.{} } },
            },
            .timestamp = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Metric) void {
        self.labels.deinit();
    }

    pub fn addLabel(self: *Metric, key: []const u8, value: []const u8) !void {
        try self.labels.put(key, value);
    }
};

// Metrics registry
pub const MetricsRegistry = struct {
    metrics: std.StringHashMap(*Metric),
    collectors: std.ArrayList(*MetricCollector),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return .{
            .metrics = std.StringHashMap(*Metric).init(allocator),
            .collectors = std.ArrayList(*MetricCollector).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        var iter = self.metrics.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.metrics.deinit();

        for (self.collectors.items) |collector| {
            collector.deinit();
        }
        self.collectors.deinit();
    }

    pub fn registerMetric(self: *MetricsRegistry, metric: *Metric) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.metrics.put(metric.name, metric);
    }

    pub fn getMetric(self: *MetricsRegistry, name: []const u8) ?*Metric {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.metrics.get(name);
    }

    pub fn incrementCounter(self: *MetricsRegistry, name: []const u8, value: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.metrics.get(name)) |metric| {
            if (metric.type == .counter) {
                metric.value.counter += value;
                metric.timestamp = std.time.milliTimestamp();
            }
        }
    }

    pub fn setGauge(self: *MetricsRegistry, name: []const u8, value: f64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.metrics.get(name)) |metric| {
            if (metric.type == .gauge) {
                metric.value.gauge = value;
                metric.timestamp = std.time.milliTimestamp();
            }
        }
    }

    pub fn observeHistogram(self: *MetricsRegistry, name: []const u8, value: f64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.metrics.get(name)) |metric| {
            if (metric.type == .histogram) {
                metric.value.histogram.count += 1;
                metric.value.histogram.sum += value;

                // Update bucket counts
                for (metric.value.histogram.buckets) |*bucket| {
                    if (value <= bucket.upper_bound) {
                        bucket.count += 1;
                    }
                }

                metric.timestamp = std.time.milliTimestamp();
            }
        }
    }

    pub fn collectAll(self: *MetricsRegistry, allocator: std.mem.Allocator) ![]Metric {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results = std.ArrayList(Metric).init(allocator);
        errdefer results.deinit();

        // Collect from registered metrics
        var iter = self.metrics.iterator();
        while (iter.next()) |entry| {
            try results.append(entry.value_ptr.*.*);
        }

        // Collect from collectors
        for (self.collectors.items) |collector| {
            const collected = try collector.collect(allocator);
            defer allocator.free(collected);
            try results.appendSlice(collected);
        }

        return try results.toOwnedSlice();
    }

    pub fn registerCollector(self: *MetricsRegistry, collector: *MetricCollector) !void {
        try self.collectors.append(collector);
    }
};

// Metric collector interface
pub const MetricCollector = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        collect: *const fn (collector: *MetricCollector, allocator: std.mem.Allocator) anyerror![]Metric,
        deinit: ?*const fn (collector: *MetricCollector) void = null,
    };

    pub fn collect(self: *MetricCollector, allocator: std.mem.Allocator) ![]Metric {
        return self.vtable.collect(self, allocator);
    }

    pub fn deinit(self: *MetricCollector) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Metrics hook
pub const MetricsHook = struct {
    hook: Hook,
    registry: *MetricsRegistry,
    config: MetricsConfig,
    execution_times: std.AutoHashMap(HookPoint, std.ArrayList(i64)),
    allocator: std.mem.Allocator,

    pub const MetricsConfig = struct {
        track_latency: bool = true,
        track_memory: bool = true,
        track_errors: bool = true,
        track_throughput: bool = true,
        latency_buckets: []const f64 = &[_]f64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 },
        export_interval_ms: u64 = 60000,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        registry: *MetricsRegistry,
        config: MetricsConfig,
    ) !*MetricsHook {
        const self = try allocator.create(MetricsHook);

        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = execute,
            .init = hookInit,
            .deinit = hookDeinit,
        };

        self.* = .{
            .hook = .{
                .id = id,
                .name = "Metrics Collection Hook",
                .description = "Collects execution metrics",
                .vtable = vtable,
                .priority = .high,
                .supported_points = &[_]HookPoint{.custom}, // Supports all points
                .config = .{ .integer = @intFromPtr(self) },
            },
            .registry = registry,
            .config = config,
            .execution_times = std.AutoHashMap(HookPoint, std.ArrayList(i64)).init(allocator),
            .allocator = allocator,
        };

        return self;
    }

    fn hookInit(hook: *Hook, allocator: std.mem.Allocator) !void {
        _ = allocator;
        const self = @as(*MetricsHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        // Register metrics
        if (self.config.track_latency) {
            const latency_metric = try self.allocator.create(Metric);
            latency_metric.* = Metric.init(self.allocator, "hook_execution_duration_ms", .histogram);
            latency_metric.description = "Hook execution duration in milliseconds";

            // Create buckets
            var buckets = try self.allocator.alloc(MetricValue.HistogramValue.BucketCount, self.config.latency_buckets.len);
            for (self.config.latency_buckets, 0..) |bound, i| {
                buckets[i] = .{ .upper_bound = bound, .count = 0 };
            }
            latency_metric.value.histogram.buckets = buckets;

            try self.registry.registerMetric(latency_metric);
        }

        if (self.config.track_errors) {
            const error_metric = try self.allocator.create(Metric);
            error_metric.* = Metric.init(self.allocator, "hook_errors_total", .counter);
            error_metric.description = "Total number of hook execution errors";
            try self.registry.registerMetric(error_metric);
        }

        if (self.config.track_throughput) {
            const throughput_metric = try self.allocator.create(Metric);
            throughput_metric.* = Metric.init(self.allocator, "hook_executions_total", .counter);
            throughput_metric.description = "Total number of hook executions";
            try self.registry.registerMetric(throughput_metric);
        }
    }

    fn hookDeinit(hook: *Hook) void {
        const self = @as(*MetricsHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        var iter = self.execution_times.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.execution_times.deinit();

        self.allocator.destroy(hook.vtable);
        self.allocator.destroy(self);
    }

    fn execute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @as(*MetricsHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        const start_time = std.time.milliTimestamp();
        const start_memory = if (self.config.track_memory) getCurrentMemoryUsage() else 0;

        // Track execution
        if (self.config.track_throughput) {
            try self.registry.incrementCounter("hook_executions_total", 1);
        }

        // Record start of execution
        const result = blk: {
            // Let the actual hook execution continue
            break :blk HookResult{ .continue_processing = true };
        };

        // Calculate metrics after execution
        const duration = std.time.milliTimestamp() - start_time;
        const memory_delta = if (self.config.track_memory) getCurrentMemoryUsage() - start_memory else 0;

        // Record latency
        if (self.config.track_latency) {
            try self.registry.observeHistogram("hook_execution_duration_ms", @as(f64, @floatFromInt(duration)));

            // Track per-point latency
            const point_result = try self.execution_times.getOrPut(context.point);
            if (!point_result.found_existing) {
                point_result.value_ptr.* = std.ArrayList(i64).init(self.allocator);
            }
            try point_result.value_ptr.append(duration);
        }

        // Add metrics to result
        var metrics_obj = std.json.ObjectMap.init(context.allocator);
        try metrics_obj.put("duration_ms", .{ .integer = duration });
        try metrics_obj.put("hook_point", .{ .string = context.point.toString() });

        if (self.config.track_memory) {
            try metrics_obj.put("memory_delta_bytes", .{ .integer = memory_delta });
        }

        return HookResult{
            .continue_processing = result.continue_processing,
            .modified_data = result.modified_data,
            .metrics = .{ .object = metrics_obj },
            .error_info = result.error_info,
        };
    }

    fn getCurrentMemoryUsage() i64 {
        // TODO: Implement actual memory usage tracking
        return 0;
    }
};

// System metrics collector
pub const SystemMetricsCollector = struct {
    collector: MetricCollector,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*SystemMetricsCollector {
        const self = try allocator.create(SystemMetricsCollector);
        self.* = .{
            .collector = .{
                .vtable = &.{
                    .collect = collect,
                    .deinit = deinit,
                },
            },
            .allocator = allocator,
        };
        return self;
    }

    fn collect(collector: *MetricCollector, allocator: std.mem.Allocator) ![]Metric {
        _ = collector;
        var metrics = std.ArrayList(Metric).init(allocator);
        errdefer metrics.deinit();

        // CPU usage
        var cpu_metric = Metric.init(allocator, "system_cpu_usage_percent", .gauge);
        cpu_metric.description = "Current CPU usage percentage";
        cpu_metric.value.gauge = try getCurrentCpuUsage();
        try metrics.append(cpu_metric);

        // Memory usage
        var memory_metric = Metric.init(allocator, "system_memory_usage_bytes", .gauge);
        memory_metric.description = "Current memory usage in bytes";
        memory_metric.value.gauge = @as(f64, @floatFromInt(try getCurrentMemoryUsage()));
        try metrics.append(memory_metric);

        // Thread count
        var thread_metric = Metric.init(allocator, "system_thread_count", .gauge);
        thread_metric.description = "Number of active threads";
        thread_metric.value.gauge = @as(f64, @floatFromInt(getActiveThreadCount()));
        try metrics.append(thread_metric);

        return try metrics.toOwnedSlice();
    }

    fn deinit(collector: *MetricCollector) void {
        const self = @fieldParentPtr(SystemMetricsCollector, "collector", collector);
        self.allocator.destroy(self);
    }

    fn getCurrentCpuUsage() !f64 {
        // TODO: Implement actual CPU usage tracking
        return 0.0;
    }

    fn getCurrentMemoryUsage() !usize {
        // TODO: Implement actual memory usage tracking
        return 0;
    }

    fn getActiveThreadCount() u32 {
        // TODO: Implement actual thread counting
        return 1;
    }
};

// Prometheus format exporter
pub const PrometheusExporter = struct {
    registry: *MetricsRegistry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, registry: *MetricsRegistry) PrometheusExporter {
        return .{
            .registry = registry,
            .allocator = allocator,
        };
    }

    pub fn exportMetrics(self: *PrometheusExporter, writer: anytype) !void {
        const metrics = try self.registry.collectAll(self.allocator);
        defer self.allocator.free(metrics);

        for (metrics) |metric| {
            // Write help text
            try writer.print("# HELP {s} {s}\n", .{ metric.name, metric.description });

            // Write type
            try writer.print("# TYPE {s} {s}\n", .{ metric.name, metric.type.toString() });

            // Write metric value
            switch (metric.value) {
                .counter => |v| {
                    try self.writeMetricLine(writer, metric.name, metric.labels, v);
                },
                .gauge => |v| {
                    try self.writeMetricLine(writer, metric.name, metric.labels, v);
                },
                .histogram => |v| {
                    // Write bucket counts
                    for (v.buckets) |bucket| {
                        var labels = try metric.labels.clone();
                        defer labels.deinit();
                        try labels.put("le", try std.fmt.allocPrint(self.allocator, "{d}", .{bucket.upper_bound}));

                        const bucket_name = try std.fmt.allocPrint(self.allocator, "{s}_bucket", .{metric.name});
                        defer self.allocator.free(bucket_name);

                        try self.writeMetricLine(writer, bucket_name, labels, bucket.count);
                    }

                    // Write sum and count
                    const sum_name = try std.fmt.allocPrint(self.allocator, "{s}_sum", .{metric.name});
                    defer self.allocator.free(sum_name);
                    try self.writeMetricLine(writer, sum_name, metric.labels, v.sum);

                    const count_name = try std.fmt.allocPrint(self.allocator, "{s}_count", .{metric.name});
                    defer self.allocator.free(count_name);
                    try self.writeMetricLine(writer, count_name, metric.labels, v.count);
                },
                .summary => |v| {
                    // Write quantiles
                    for (v.quantiles) |quantile| {
                        var labels = try metric.labels.clone();
                        defer labels.deinit();
                        try labels.put("quantile", try std.fmt.allocPrint(self.allocator, "{d}", .{quantile.quantile}));

                        try self.writeMetricLine(writer, metric.name, labels, quantile.value);
                    }

                    // Write sum and count
                    const sum_name = try std.fmt.allocPrint(self.allocator, "{s}_sum", .{metric.name});
                    defer self.allocator.free(sum_name);
                    try self.writeMetricLine(writer, sum_name, metric.labels, v.sum);

                    const count_name = try std.fmt.allocPrint(self.allocator, "{s}_count", .{metric.name});
                    defer self.allocator.free(count_name);
                    try self.writeMetricLine(writer, count_name, metric.labels, v.count);
                },
            }

            try writer.writeByte('\n');
        }
    }

    fn writeMetricLine(
        self: *PrometheusExporter,
        writer: anytype,
        name: []const u8,
        labels: std.StringHashMap([]const u8),
        value: anytype,
    ) !void {
        _ = self;
        try writer.writeAll(name);

        if (labels.count() > 0) {
            try writer.writeByte('{');
            var first = true;
            var iter = labels.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeByte(',');
                try writer.print("{s}=\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            }
            try writer.writeByte('}');
        }

        try writer.print(" {d}\n", .{value});
    }
};

// Builder for metrics hook
pub fn createMetricsHook(
    allocator: std.mem.Allocator,
    id: []const u8,
    registry: *MetricsRegistry,
    config: MetricsHook.MetricsConfig,
) !*Hook {
    const metrics_hook = try MetricsHook.init(allocator, id, registry, config);
    return &metrics_hook.hook;
}

// Global metrics registry
var global_registry: ?*MetricsRegistry = null;
var global_mutex: std.Thread.Mutex = .{};

pub fn getGlobalRegistry(allocator: std.mem.Allocator) !*MetricsRegistry {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_registry) |registry| {
        return registry;
    }

    global_registry = try allocator.create(MetricsRegistry);
    global_registry.?.* = MetricsRegistry.init(allocator);
    return global_registry.?;
}

// Tests
test "metrics registry" {
    const allocator = std.testing.allocator;

    var registry = MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Create and register a counter
    const counter = try allocator.create(Metric);
    counter.* = Metric.init(allocator, "test_counter", .counter);
    counter.description = "Test counter metric";

    try registry.registerMetric(counter);

    // Increment counter
    try registry.incrementCounter("test_counter", 5);

    const metric = registry.getMetric("test_counter");
    try std.testing.expect(metric != null);
    try std.testing.expectEqual(@as(i64, 5), metric.?.value.counter);
}

test "metrics hook" {
    const allocator = std.testing.allocator;

    var registry = MetricsRegistry.init(allocator);
    defer registry.deinit();

    const metrics_hook = try MetricsHook.init(allocator, "test_metrics", &registry, .{});
    defer metrics_hook.hook.vtable.deinit.?(&metrics_hook.hook);

    try metrics_hook.hook.init(allocator);

    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();

    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();

    const result = try metrics_hook.hook.execute(&context);
    try std.testing.expect(result.continue_processing);
    try std.testing.expect(result.metrics != null);
}

test "prometheus exporter" {
    const allocator = std.testing.allocator;

    var registry = MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Create test metric
    const gauge = try allocator.create(Metric);
    gauge.* = Metric.init(allocator, "test_gauge", .gauge);
    gauge.description = "Test gauge metric";
    gauge.value.gauge = 42.5;
    try gauge.addLabel("env", "test");

    try registry.registerMetric(gauge);

    // Export to string
    var exporter = PrometheusExporter.init(allocator, &registry);

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try exporter.exportMetrics(buffer.writer());

    const output = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "# HELP test_gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE test_gauge gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "test_gauge{env=\"test\"} 42.5") != null);
}
