// ABOUTME: Conditional hook execution filters for fine-grained control
// ABOUTME: Provides filters to conditionally execute hooks based on various criteria

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;

// Base filter interface
pub const HookFilter = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        shouldExecute: *const fn (filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool,
        deinit: ?*const fn (filter: *HookFilter) void = null,
    };

    pub fn shouldExecute(self: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        return self.vtable.shouldExecute(self, hook, context);
    }

    pub fn deinit(self: *HookFilter) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Filtered hook wrapper
pub const FilteredHook = struct {
    hook: Hook,
    filter: *HookFilter,
    original_hook: *Hook,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, original: *Hook, filter: *HookFilter) !*FilteredHook {
        const self = try allocator.create(FilteredHook);

        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = filteredExecute,
            .init = if (original.vtable.init) |_| filteredInit else null,
            .deinit = filteredDeinit,
            .validate = if (original.vtable.validate) |_| filteredValidate else null,
        };

        self.* = .{
            .hook = .{
                .id = original.id,
                .name = original.name,
                .description = original.description,
                .vtable = vtable,
                .priority = original.priority,
                .supported_points = original.supported_points,
                .enabled = original.enabled,
                .config = original.config,
            },
            .filter = filter,
            .original_hook = original,
            .allocator = allocator,
        };

        return self;
    }

    pub fn deinit(self: *FilteredHook) void {
        self.allocator.destroy(self.hook.vtable);
        self.allocator.destroy(self);
    }

    fn filteredExecute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @fieldParentPtr(FilteredHook, "hook", hook);

        if (!self.filter.shouldExecute(self.filter, self.original_hook, context)) {
            return HookResult{ .continue_processing = true };
        }

        return self.original_hook.execute(context);
    }

    fn filteredInit(hook: *Hook, allocator: std.mem.Allocator) !void {
        const self = @fieldParentPtr(FilteredHook, "hook", hook);
        if (self.original_hook.vtable.init) |init_fn| {
            try init_fn(self.original_hook, allocator);
        }
    }

    fn filteredDeinit(hook: *Hook) void {
        const self = @fieldParentPtr(FilteredHook, "hook", hook);
        if (self.original_hook.vtable.deinit) |deinit_fn| {
            deinit_fn(self.original_hook);
        }
    }

    fn filteredValidate(hook: *Hook) !void {
        const self = @fieldParentPtr(FilteredHook, "hook", hook);
        if (self.original_hook.vtable.validate) |validate_fn| {
            try validate_fn(self.original_hook);
        }
    }
};

// Predefined filters

// Point filter - only execute at specific hook points
pub const PointFilter = struct {
    filter: HookFilter,
    points: []const HookPoint,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, points: []const HookPoint) !*PointFilter {
        const self = try allocator.create(PointFilter);
        self.* = .{
            .filter = .{
                .vtable = &.{
                    .shouldExecute = shouldExecute,
                    .deinit = deinit,
                },
            },
            .points = try allocator.dupe(HookPoint, points),
            .allocator = allocator,
        };
        return self;
    }

    fn shouldExecute(filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        _ = hook;
        const self = @fieldParentPtr(PointFilter, "filter", filter);

        for (self.points) |point| {
            if (point == context.point) {
                return true;
            }
        }
        return false;
    }

    fn deinit(filter: *HookFilter) void {
        const self = @fieldParentPtr(PointFilter, "filter", filter);
        self.allocator.free(self.points);
        self.allocator.destroy(self);
    }
};

// Predicate filter - execute based on custom predicate
pub const PredicateFilter = struct {
    filter: HookFilter,
    predicate: *const fn (hook: *const Hook, context: *const HookContext) bool,

    pub fn init(allocator: std.mem.Allocator, predicate: *const fn (hook: *const Hook, context: *const HookContext) bool) !*PredicateFilter {
        const self = try allocator.create(PredicateFilter);
        self.* = .{
            .filter = .{
                .vtable = &.{
                    .shouldExecute = shouldExecute,
                    .deinit = deinit,
                },
            },
            .predicate = predicate,
        };
        return self;
    }

    fn shouldExecute(filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        const self = @fieldParentPtr(PredicateFilter, "filter", filter);
        return self.predicate(hook, context);
    }

    fn deinit(filter: *HookFilter) void {
        const self = @fieldParentPtr(PredicateFilter, "filter", filter);
        self.allocator.destroy(self);
    }
};

// Rate limit filter - limit execution frequency
pub const RateLimitFilter = struct {
    filter: HookFilter,
    max_executions: u32,
    window_ms: u64,
    executions: std.ArrayList(i64),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_executions: u32, window_ms: u64) !*RateLimitFilter {
        const self = try allocator.create(RateLimitFilter);
        self.* = .{
            .filter = .{
                .vtable = &.{
                    .shouldExecute = shouldExecute,
                    .deinit = deinit,
                },
            },
            .max_executions = max_executions,
            .window_ms = window_ms,
            .executions = std.ArrayList(i64).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
        return self;
    }

    fn shouldExecute(filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        _ = hook;
        _ = context;
        const self = @fieldParentPtr(RateLimitFilter, "filter", filter);

        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        const window_start = now - @as(i64, @intCast(self.window_ms));

        // Remove old executions outside the window
        var i: usize = 0;
        while (i < self.executions.items.len) {
            if (self.executions.items[i] < window_start) {
                _ = self.executions.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Check if we've exceeded the limit
        if (self.executions.items.len >= self.max_executions) {
            return false;
        }

        // Record this execution
        self.executions.append(now) catch return false;
        return true;
    }

    fn deinit(filter: *HookFilter) void {
        const self = @fieldParentPtr(RateLimitFilter, "filter", filter);
        self.executions.deinit();
        self.allocator.destroy(self);
    }
};

// Metadata filter - execute based on context metadata
pub const MetadataFilter = struct {
    filter: HookFilter,
    key: []const u8,
    value: ?std.json.Value,
    match_type: MatchType,
    allocator: std.mem.Allocator,

    pub const MatchType = enum {
        exists, // Key exists
        not_exists, // Key doesn't exist
        equals, // Value equals
        not_equals, // Value not equals
        contains, // String contains
        matches, // Regex match
    };

    pub fn init(
        allocator: std.mem.Allocator,
        key: []const u8,
        value: ?std.json.Value,
        match_type: MatchType,
    ) !*MetadataFilter {
        const self = try allocator.create(MetadataFilter);
        self.* = .{
            .filter = .{
                .vtable = &.{
                    .shouldExecute = shouldExecute,
                    .deinit = deinit,
                },
            },
            .key = try allocator.dupe(u8, key),
            .value = value,
            .match_type = match_type,
            .allocator = allocator,
        };
        return self;
    }

    fn shouldExecute(filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        _ = hook;
        const self = @fieldParentPtr(MetadataFilter, "filter", filter);

        const metadata_value = context.getMetadata(self.key);

        switch (self.match_type) {
            .exists => return metadata_value != null,
            .not_exists => return metadata_value == null,
            .equals => {
                if (metadata_value == null or self.value == null) return false;
                return std.meta.eql(metadata_value.?, self.value.?);
            },
            .not_equals => {
                if (metadata_value == null or self.value == null) return true;
                return !std.meta.eql(metadata_value.?, self.value.?);
            },
            .contains => {
                if (metadata_value == null or self.value == null) return false;
                if (metadata_value.? != .string or self.value.? != .string) return false;
                return std.mem.indexOf(u8, metadata_value.?.string, self.value.?.string) != null;
            },
            .matches => {
                // TODO: Implement regex matching
                return false;
            },
        }
    }

    fn deinit(filter: *HookFilter) void {
        const self = @fieldParentPtr(MetadataFilter, "filter", filter);
        self.allocator.free(self.key);
        self.allocator.destroy(self);
    }
};

// Composite filter - combine multiple filters
pub const CompositeFilter = struct {
    filter: HookFilter,
    filters: []*HookFilter,
    operator: LogicalOperator,
    allocator: std.mem.Allocator,

    pub const LogicalOperator = enum {
        @"and", // All filters must pass
        @"or", // Any filter must pass
        not, // Invert result (only uses first filter)
    };

    pub fn init(allocator: std.mem.Allocator, filters: []*HookFilter, operator: LogicalOperator) !*CompositeFilter {
        const self = try allocator.create(CompositeFilter);
        self.* = .{
            .filter = .{
                .vtable = &.{
                    .shouldExecute = shouldExecute,
                    .deinit = deinit,
                },
            },
            .filters = try allocator.dupe(*HookFilter, filters),
            .operator = operator,
            .allocator = allocator,
        };
        return self;
    }

    fn shouldExecute(filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        const self = @fieldParentPtr(CompositeFilter, "filter", filter);

        switch (self.operator) {
            .@"and" => {
                for (self.filters) |sub_filter| {
                    if (!sub_filter.shouldExecute(sub_filter, hook, context)) {
                        return false;
                    }
                }
                return true;
            },
            .@"or" => {
                for (self.filters) |sub_filter| {
                    if (sub_filter.shouldExecute(sub_filter, hook, context)) {
                        return true;
                    }
                }
                return false;
            },
            .not => {
                if (self.filters.len == 0) return true;
                return !self.filters[0].shouldExecute(self.filters[0], hook, context);
            },
        }
    }

    fn deinit(filter: *HookFilter) void {
        const self = @fieldParentPtr(CompositeFilter, "filter", filter);
        for (self.filters) |sub_filter| {
            sub_filter.deinit();
        }
        self.allocator.free(self.filters);
        self.allocator.destroy(self);
    }
};

// Time-based filter - execute only during specific time windows
pub const TimeWindowFilter = struct {
    filter: HookFilter,
    start_hour: u8,
    end_hour: u8,
    days_of_week: u8, // Bitmask: Sunday = 1, Monday = 2, etc.
    timezone_offset_minutes: i16,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        start_hour: u8,
        end_hour: u8,
        days_of_week: u8,
        timezone_offset_minutes: i16,
    ) !*TimeWindowFilter {
        const self = try allocator.create(TimeWindowFilter);
        self.* = .{
            .filter = .{
                .vtable = &.{
                    .shouldExecute = shouldExecute,
                    .deinit = deinit,
                },
            },
            .start_hour = start_hour,
            .end_hour = end_hour,
            .days_of_week = days_of_week,
            .timezone_offset_minutes = timezone_offset_minutes,
            .allocator = allocator,
        };
        return self;
    }

    fn shouldExecute(filter: *const HookFilter, hook: *const Hook, context: *const HookContext) bool {
        _ = hook;
        _ = context;
        const self = @fieldParentPtr(TimeWindowFilter, "filter", filter);

        // Get current time adjusted for timezone
        const now = std.time.timestamp();
        const adjusted_now = now + (@as(i64, self.timezone_offset_minutes) * 60);

        // Calculate day of week and hour
        const days_since_epoch = @divTrunc(adjusted_now, 86400);
        const day_of_week = @as(u8, @intCast(@mod(days_since_epoch + 4, 7))); // Thursday = 0 at epoch
        const seconds_today = @mod(adjusted_now, 86400);
        const current_hour = @as(u8, @intCast(@divTrunc(seconds_today, 3600)));

        // Check day of week
        const day_mask = @as(u8, 1) << @intCast(day_of_week);
        if ((self.days_of_week & day_mask) == 0) {
            return false;
        }

        // Check hour range
        if (self.start_hour <= self.end_hour) {
            return current_hour >= self.start_hour and current_hour < self.end_hour;
        } else {
            // Handles ranges that cross midnight
            return current_hour >= self.start_hour or current_hour < self.end_hour;
        }
    }

    fn deinit(filter: *HookFilter) void {
        const self = @fieldParentPtr(TimeWindowFilter, "filter", filter);
        self.allocator.destroy(self);
    }
};

// Filter builder for convenience
pub const FilterBuilder = struct {
    allocator: std.mem.Allocator,
    filters: std.ArrayList(*HookFilter),

    pub fn init(allocator: std.mem.Allocator) FilterBuilder {
        return .{
            .allocator = allocator,
            .filters = std.ArrayList(*HookFilter).init(allocator),
        };
    }

    pub fn deinit(self: *FilterBuilder) void {
        for (self.filters.items) |filter| {
            filter.deinit();
        }
        self.filters.deinit();
    }

    pub fn atPoints(self: *FilterBuilder, points: []const HookPoint) !*FilterBuilder {
        const filter = try PointFilter.init(self.allocator, points);
        try self.filters.append(&filter.filter);
        return self;
    }

    pub fn withPredicate(self: *FilterBuilder, predicate: *const fn (hook: *const Hook, context: *const HookContext) bool) !*FilterBuilder {
        const filter = try PredicateFilter.init(self.allocator, predicate);
        try self.filters.append(&filter.filter);
        return self;
    }

    pub fn withRateLimit(self: *FilterBuilder, max_executions: u32, window_ms: u64) !*FilterBuilder {
        const filter = try RateLimitFilter.init(self.allocator, max_executions, window_ms);
        try self.filters.append(&filter.filter);
        return self;
    }

    pub fn withMetadata(self: *FilterBuilder, key: []const u8, value: ?std.json.Value, match_type: MetadataFilter.MatchType) !*FilterBuilder {
        const filter = try MetadataFilter.init(self.allocator, key, value, match_type);
        try self.filters.append(&filter.filter);
        return self;
    }

    pub fn duringTimeWindow(self: *FilterBuilder, start_hour: u8, end_hour: u8, days_of_week: u8, timezone_offset_minutes: i16) !*FilterBuilder {
        const filter = try TimeWindowFilter.init(self.allocator, start_hour, end_hour, days_of_week, timezone_offset_minutes);
        try self.filters.append(&filter.filter);
        return self;
    }

    pub fn build(self: *FilterBuilder, operator: CompositeFilter.LogicalOperator) !*HookFilter {
        if (self.filters.items.len == 0) {
            return error.NoFiltersAdded;
        }

        if (self.filters.items.len == 1) {
            return self.filters.items[0];
        }

        const composite = try CompositeFilter.init(self.allocator, self.filters.items, operator);
        return &composite.filter;
    }
};

// Tests
test "point filter" {
    const allocator = std.testing.allocator;

    const filter = try PointFilter.init(allocator, &[_]HookPoint{ .agent_before_run, .agent_after_run });
    defer filter.filter.deinit();

    var hook = Hook{
        .id = "test",
        .name = "Test",
        .description = "Test hook",
        .vtable = undefined,
        .supported_points = &[_]HookPoint{.agent_before_run},
    };

    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();

    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();

    try std.testing.expect(filter.filter.shouldExecute(&filter.filter, &hook, &context));

    context.point = .agent_cleanup;
    try std.testing.expect(!filter.filter.shouldExecute(&filter.filter, &hook, &context));
}

test "rate limit filter" {
    const allocator = std.testing.allocator;

    const filter = try RateLimitFilter.init(allocator, 2, 1000); // 2 executions per second
    defer filter.filter.deinit();

    var hook = Hook{
        .id = "test",
        .name = "Test",
        .description = "Test hook",
        .vtable = undefined,
        .supported_points = &[_]HookPoint{.agent_before_run},
    };

    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();

    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();

    // First two should succeed
    try std.testing.expect(filter.filter.shouldExecute(&filter.filter, &hook, &context));
    try std.testing.expect(filter.filter.shouldExecute(&filter.filter, &hook, &context));

    // Third should fail
    try std.testing.expect(!filter.filter.shouldExecute(&filter.filter, &hook, &context));
}

test "filter builder" {
    const allocator = std.testing.allocator;

    var builder = FilterBuilder.init(allocator);
    defer builder.deinit();

    const filter = try builder
        .atPoints(&[_]HookPoint{.agent_before_run})
        .withRateLimit(10, 60000)
        .build(.@"and");
    defer filter.deinit();

    try std.testing.expect(filter == .filter);
}
