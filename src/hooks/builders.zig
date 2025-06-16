// ABOUTME: Fluent builders for constructing hooks with convenient APIs
// ABOUTME: Provides builder patterns for common hook types and configurations

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookConfig = types.HookConfig;
const HookPoint = types.HookPoint;
const HookPriority = types.HookPriority;
const HookResult = types.HookResult;
const HookContext = types.HookContext;
const HookCategory = types.HookCategory;

// Generic hook builder
pub const HookBuilder = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    description: []const u8,
    category: HookCategory = .custom,
    priority: HookPriority = .normal,
    supported_points: std.ArrayList(HookPoint),
    enabled: bool = true,
    config: std.json.ObjectMap,
    execute_fn: ?*const fn (hook: *Hook, context: *HookContext) anyerror!HookResult = null,
    init_fn: ?*const fn (hook: *Hook, allocator: std.mem.Allocator) anyerror!void = null,
    deinit_fn: ?*const fn (hook: *Hook) void = null,
    validate_fn: ?*const fn (hook: *Hook) anyerror!void = null,

    pub fn init(allocator: std.mem.Allocator, id: []const u8) HookBuilder {
        return .{
            .allocator = allocator,
            .id = id,
            .name = id,
            .description = "",
            .supported_points = std.ArrayList(HookPoint).init(allocator),
            .config = std.json.ObjectMap.init(allocator),
        };
    }

    pub fn deinit(self: *HookBuilder) void {
        self.supported_points.deinit();
        self.config.deinit();
    }

    pub fn withName(self: *HookBuilder, name: []const u8) *HookBuilder {
        self.name = name;
        return self;
    }

    pub fn withDescription(self: *HookBuilder, description: []const u8) *HookBuilder {
        self.description = description;
        return self;
    }

    pub fn withCategory(self: *HookBuilder, category: HookCategory) *HookBuilder {
        self.category = category;
        return self;
    }

    pub fn withPriority(self: *HookBuilder, priority: HookPriority) *HookBuilder {
        self.priority = priority;
        return self;
    }

    pub fn forPoint(self: *HookBuilder, point: HookPoint) !*HookBuilder {
        try self.supported_points.append(point);
        return self;
    }

    pub fn forPoints(self: *HookBuilder, points: []const HookPoint) !*HookBuilder {
        try self.supported_points.appendSlice(points);
        return self;
    }

    pub fn forAllPoints(self: *HookBuilder) !*HookBuilder {
        try self.supported_points.append(.custom);
        return self;
    }

    pub fn withConfig(self: *HookBuilder, key: []const u8, value: std.json.Value) !*HookBuilder {
        try self.config.put(key, value);
        return self;
    }

    pub fn withExecute(self: *HookBuilder, execute_fn: *const fn (hook: *Hook, context: *HookContext) anyerror!HookResult) *HookBuilder {
        self.execute_fn = execute_fn;
        return self;
    }

    pub fn withInit(self: *HookBuilder, init_fn: *const fn (hook: *Hook, allocator: std.mem.Allocator) anyerror!void) *HookBuilder {
        self.init_fn = init_fn;
        return self;
    }

    pub fn withDeinit(self: *HookBuilder, deinit_fn: *const fn (hook: *Hook) void) *HookBuilder {
        self.deinit_fn = deinit_fn;
        return self;
    }

    pub fn withValidate(self: *HookBuilder, validate_fn: *const fn (hook: *Hook) anyerror!void) *HookBuilder {
        self.validate_fn = validate_fn;
        return self;
    }

    pub fn disabled(self: *HookBuilder) *HookBuilder {
        self.enabled = false;
        return self;
    }

    pub fn build(self: *HookBuilder) !*Hook {
        if (self.execute_fn == null) {
            return error.ExecuteFunctionRequired;
        }

        const hook = try self.allocator.create(Hook);

        const vtable = try self.allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = self.execute_fn.?,
            .init = self.init_fn,
            .deinit = self.deinit_fn,
            .validate = self.validate_fn,
        };

        hook.* = .{
            .id = try self.allocator.dupe(u8, self.id),
            .name = try self.allocator.dupe(u8, self.name),
            .description = try self.allocator.dupe(u8, self.description),
            .vtable = vtable,
            .priority = self.priority,
            .supported_points = try self.supported_points.toOwnedSlice(),
            .enabled = self.enabled,
            .config = if (self.config.count() > 0) .{ .object = self.config } else null,
        };

        return hook;
    }
};

// Lambda hook builder for simple inline hooks
pub const LambdaHookBuilder = struct {
    builder: HookBuilder,
    lambda_state: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, id: []const u8) LambdaHookBuilder {
        return .{
            .builder = HookBuilder.init(allocator, id),
        };
    }

    pub fn deinit(self: *LambdaHookBuilder) void {
        self.builder.deinit();
    }

    pub fn withLambda(
        self: *LambdaHookBuilder,
        comptime lambda: fn (context: *HookContext) anyerror!HookResult,
    ) !*LambdaHookBuilder {
        const Lambda = struct {
            fn execute(hook: *Hook, context: *HookContext) !HookResult {
                _ = hook;
                return lambda(context);
            }
        };

        self.builder.execute_fn = Lambda.execute;
        return self;
    }

    pub fn withStatefulLambda(
        self: *LambdaHookBuilder,
        state: *anyopaque,
        comptime lambda: fn (state: *anyopaque, context: *HookContext) anyerror!HookResult,
    ) !*LambdaHookBuilder {
        self.lambda_state = state;

        const Lambda = struct {
            fn execute(hook: *Hook, context: *HookContext) !HookResult {
                _ = hook;
                const builder_state = @as(*anyopaque, @ptrCast(@alignCast(hook.config.?.object.get("__state__").?.integer)));
                return lambda(builder_state, context);
            }
        };

        try self.builder.withConfig("__state__", .{ .integer = @intFromPtr(state) });
        self.builder.execute_fn = Lambda.execute;
        return self;
    }

    pub fn build(self: *LambdaHookBuilder) !*Hook {
        return self.builder.build();
    }

    // Proxy methods to builder
    pub fn withName(self: *LambdaHookBuilder, name: []const u8) *LambdaHookBuilder {
        _ = self.builder.withName(name);
        return self;
    }

    pub fn withDescription(self: *LambdaHookBuilder, description: []const u8) *LambdaHookBuilder {
        _ = self.builder.withDescription(description);
        return self;
    }

    pub fn withPriority(self: *LambdaHookBuilder, priority: HookPriority) *LambdaHookBuilder {
        _ = self.builder.withPriority(priority);
        return self;
    }

    pub fn forPoint(self: *LambdaHookBuilder, point: HookPoint) !*LambdaHookBuilder {
        _ = try self.builder.forPoint(point);
        return self;
    }
};

// Composite hook builder for combining multiple hooks
pub const CompositeHookBuilder = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    name: []const u8,
    hooks: std.ArrayList(*Hook),
    merge_strategy: MergeStrategy = .all,

    pub const MergeStrategy = enum {
        all, // All hooks must succeed
        any, // Any hook success is enough
        first, // Use first successful result
        last, // Use last successful result
        merge_data, // Merge all modified data
    };

    pub fn init(allocator: std.mem.Allocator, id: []const u8) CompositeHookBuilder {
        return .{
            .allocator = allocator,
            .id = id,
            .name = id,
            .hooks = std.ArrayList(*Hook).init(allocator),
        };
    }

    pub fn deinit(self: *CompositeHookBuilder) void {
        self.hooks.deinit();
    }

    pub fn withName(self: *CompositeHookBuilder, name: []const u8) *CompositeHookBuilder {
        self.name = name;
        return self;
    }

    pub fn withMergeStrategy(self: *CompositeHookBuilder, strategy: MergeStrategy) *CompositeHookBuilder {
        self.merge_strategy = strategy;
        return self;
    }

    pub fn addHook(self: *CompositeHookBuilder, hook: *Hook) !*CompositeHookBuilder {
        try self.hooks.append(hook);
        return self;
    }

    pub fn addHooks(self: *CompositeHookBuilder, hooks: []*Hook) !*CompositeHookBuilder {
        try self.hooks.appendSlice(hooks);
        return self;
    }

    pub fn build(self: *CompositeHookBuilder) !*Hook {
        const state = try self.allocator.create(CompositeState);
        state.* = .{
            .hooks = try self.hooks.toOwnedSlice(),
            .merge_strategy = self.merge_strategy,
            .allocator = self.allocator,
        };

        const vtable = try self.allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = compositeExecute,
            .deinit = compositeDeinit,
        };

        // Collect all supported points from sub-hooks
        var all_points = std.ArrayList(HookPoint).init(self.allocator);
        defer all_points.deinit();

        for (state.hooks) |hook| {
            try all_points.appendSlice(hook.supported_points);
        }

        const hook = try self.allocator.create(Hook);
        hook.* = .{
            .id = try self.allocator.dupe(u8, self.id),
            .name = try self.allocator.dupe(u8, self.name),
            .description = "Composite hook",
            .vtable = vtable,
            .priority = .normal,
            .supported_points = try all_points.toOwnedSlice(),
            .enabled = true,
            .config = .{ .integer = @intFromPtr(state) },
        };

        return hook;
    }

    const CompositeState = struct {
        hooks: []*Hook,
        merge_strategy: MergeStrategy,
        allocator: std.mem.Allocator,
    };

    fn compositeExecute(hook: *Hook, context: *HookContext) !HookResult {
        const state = @as(*CompositeState, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        var result = HookResult{};
        var any_success = false;
        var all_success = true;

        for (state.hooks) |sub_hook| {
            const sub_result = sub_hook.execute(context) catch |err| {
                all_success = false;
                if (state.merge_strategy == .all) {
                    return err;
                }
                continue;
            };

            any_success = true;

            if (!sub_result.continue_processing) {
                result.continue_processing = false;
                if (state.merge_strategy == .first) {
                    return sub_result;
                }
            }

            if (sub_result.modified_data) |data| {
                switch (state.merge_strategy) {
                    .first => if (result.modified_data == null) {
                        result.modified_data = data;
                    },
                    .last => result.modified_data = data,
                    .merge_data => {
                        // TODO: Implement data merging
                        result.modified_data = data;
                    },
                    else => result.modified_data = data,
                }
            }

            if (sub_result.error_info) |err_info| {
                result.error_info = err_info;
            }
        }

        switch (state.merge_strategy) {
            .all => if (!all_success) return error.NotAllHooksSucceeded,
            .any => if (!any_success) return error.NoHooksSucceeded,
            else => {},
        }

        return result;
    }

    fn compositeDeinit(hook: *Hook) void {
        const state = @as(*CompositeState, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
        state.allocator.free(state.hooks);
        state.allocator.destroy(state);
    }
};

// Predefined hook builders for common use cases
pub const CommonHooks = struct {
    // Logging hook builder
    pub fn logging(allocator: std.mem.Allocator, id: []const u8) !*HookBuilder {
        var builder = HookBuilder.init(allocator, id);
        return builder
            .withName("Logging Hook")
            .withDescription("Logs hook execution details")
            .withCategory(.logging)
            .withExecute(loggingExecute);
    }

    fn loggingExecute(hook: *Hook, context: *HookContext) !HookResult {
        const level = if (hook.config) |cfg|
            if (cfg.object.get("level")) |lvl|
                if (lvl == .string) lvl.string else "info"
            else
                "info"
        else
            "info";

        std.log.info("[{s}] Hook '{s}' at point '{s}'", .{ level, hook.id, context.point.toString() });

        if (context.input_data) |input| {
            const input_str = try std.json.stringifyAlloc(context.allocator, input, .{});
            defer context.allocator.free(input_str);
            std.log.debug("  Input: {s}", .{input_str});
        }

        return HookResult{ .continue_processing = true };
    }

    // Metrics hook builder
    pub fn metrics(allocator: std.mem.Allocator, id: []const u8) !*HookBuilder {
        var builder = HookBuilder.init(allocator, id);
        return builder
            .withName("Metrics Hook")
            .withDescription("Collects execution metrics")
            .withCategory(.metrics)
            .withExecute(metricsExecute);
    }

    fn metricsExecute(hook: *Hook, context: *HookContext) !HookResult {
        _ = hook;

        // Record execution metrics
        const metrics_key = try std.fmt.allocPrint(context.allocator, "hook.{s}.executions", .{context.point.toString()});
        defer context.allocator.free(metrics_key);

        // TODO: Integrate with actual metrics system
        _ = metrics_key;

        return HookResult{
            .continue_processing = true,
            .metrics = .{ .object = std.json.ObjectMap.init(context.allocator) },
        };
    }

    // Validation hook builder
    pub fn validation(allocator: std.mem.Allocator, id: []const u8) !*HookBuilder {
        var builder = HookBuilder.init(allocator, id);
        return builder
            .withName("Validation Hook")
            .withDescription("Validates input/output data")
            .withCategory(.validation)
            .withExecute(validationExecute);
    }

    fn validationExecute(hook: *Hook, context: *HookContext) !HookResult {
        if (hook.config) |cfg| {
            if (cfg.object.get("schema")) |schema| {
                // TODO: Implement schema validation
                _ = schema;
            }
        }

        return HookResult{ .continue_processing = true };
    }

    // Caching hook builder
    pub fn caching(allocator: std.mem.Allocator, id: []const u8) !*HookBuilder {
        var builder = HookBuilder.init(allocator, id);
        return builder
            .withName("Caching Hook")
            .withDescription("Caches execution results")
            .withCategory(.caching)
            .withExecute(cachingExecute);
    }

    fn cachingExecute(hook: *Hook, context: *HookContext) !HookResult {
        _ = hook;
        _ = context;

        // TODO: Implement caching logic
        return HookResult{ .continue_processing = true };
    }

    // Rate limiting hook builder
    pub fn rateLimiting(allocator: std.mem.Allocator, id: []const u8) !*HookBuilder {
        var builder = HookBuilder.init(allocator, id);
        return builder
            .withName("Rate Limiting Hook")
            .withDescription("Enforces rate limits")
            .withCategory(.rate_limiting)
            .withExecute(rateLimitingExecute);
    }

    fn rateLimitingExecute(hook: *Hook, context: *HookContext) !HookResult {
        _ = hook;
        _ = context;

        // TODO: Implement rate limiting logic
        return HookResult{ .continue_processing = true };
    }
};

// Tests
test "hook builder" {
    const allocator = std.testing.allocator;

    var builder = HookBuilder.init(allocator, "test_hook");
    defer builder.deinit();

    const hook = try builder
        .withName("Test Hook")
        .withDescription("A test hook")
        .withPriority(.high)
        .forPoint(.agent_before_run)
        .withConfig("enabled", .{ .bool = true })
        .withExecute(struct {
            fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                _ = h;
                _ = ctx;
                return HookResult{ .continue_processing = true };
            }
        }.execute)
        .build();
    defer {
        allocator.free(hook.id);
        allocator.free(hook.name);
        allocator.free(hook.description);
        allocator.free(hook.supported_points);
        allocator.destroy(hook.vtable);
        allocator.destroy(hook);
    }

    try std.testing.expectEqualStrings("test_hook", hook.id);
    try std.testing.expectEqualStrings("Test Hook", hook.name);
    try std.testing.expect(hook.priority == .high);
    try std.testing.expectEqual(@as(usize, 1), hook.supported_points.len);
}

test "lambda hook builder" {
    const allocator = std.testing.allocator;

    var builder = LambdaHookBuilder.init(allocator, "lambda_hook");
    defer builder.deinit();

    const hook = try builder
        .withName("Lambda Hook")
        .forPoint(.agent_after_run)
        .withLambda(struct {
            fn lambda(context: *HookContext) !HookResult {
                _ = context;
                return HookResult{
                    .continue_processing = true,
                    .modified_data = .{ .string = "modified by lambda" },
                };
            }
        }.lambda)
        .build();
    defer {
        allocator.free(hook.id);
        allocator.free(hook.name);
        allocator.free(hook.description);
        allocator.free(hook.supported_points);
        allocator.destroy(hook.vtable);
        allocator.destroy(hook);
    }

    try std.testing.expectEqualStrings("lambda_hook", hook.id);
}

test "composite hook builder" {
    const allocator = std.testing.allocator;

    // Create sub-hooks
    var hook1 = Hook{
        .id = "hook1",
        .name = "Hook 1",
        .description = "First hook",
        .vtable = &.{
            .execute = struct {
                fn execute(hook: *Hook, context: *HookContext) !HookResult {
                    _ = hook;
                    _ = context;
                    return HookResult{ .continue_processing = true };
                }
            }.execute,
        },
        .supported_points = &[_]HookPoint{.agent_before_run},
    };

    var hook2 = Hook{
        .id = "hook2",
        .name = "Hook 2",
        .description = "Second hook",
        .vtable = &.{
            .execute = struct {
                fn execute(hook: *Hook, context: *HookContext) !HookResult {
                    _ = hook;
                    _ = context;
                    return HookResult{ .continue_processing = true };
                }
            }.execute,
        },
        .supported_points = &[_]HookPoint{.agent_after_run},
    };

    var builder = CompositeHookBuilder.init(allocator, "composite_hook");
    defer builder.deinit();

    const composite = try builder
        .withName("Composite Hook")
        .withMergeStrategy(.all)
        .addHook(&hook1)
        .addHook(&hook2)
        .build();
    defer {
        allocator.free(composite.id);
        allocator.free(composite.name);
        allocator.free(composite.supported_points);
        composite.vtable.deinit.?(composite);
        allocator.destroy(composite.vtable);
        allocator.destroy(composite);
    }

    try std.testing.expectEqualStrings("composite_hook", composite.id);
    try std.testing.expectEqual(@as(usize, 2), composite.supported_points.len);
}
