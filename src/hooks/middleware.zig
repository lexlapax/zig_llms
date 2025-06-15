// ABOUTME: Hook middleware pattern for composable hook processing pipelines
// ABOUTME: Provides middleware functionality for pre/post processing of hook execution

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const context_mod = @import("context.zig");
const EnhancedHookContext = context_mod.EnhancedHookContext;

// Middleware interface
pub const HookMiddleware = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        process: *const fn (
            middleware: *HookMiddleware,
            hook: *Hook,
            context: *HookContext,
            next: NextFn,
        ) anyerror!HookResult,
        init: ?*const fn (middleware: *HookMiddleware, allocator: std.mem.Allocator) anyerror!void = null,
        deinit: ?*const fn (middleware: *HookMiddleware) void = null,
    };
    
    pub const NextFn = *const fn (hook: *Hook, context: *HookContext) anyerror!HookResult;
    
    pub fn process(
        self: *HookMiddleware,
        hook: *Hook,
        context: *HookContext,
        next: NextFn,
    ) !HookResult {
        return self.vtable.process(self, hook, context, next);
    }
    
    pub fn init(self: *HookMiddleware, allocator: std.mem.Allocator) !void {
        if (self.vtable.init) |init_fn| {
            try init_fn(self, allocator);
        }
    }
    
    pub fn deinit(self: *HookMiddleware) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Middleware chain
pub const MiddlewareChain = struct {
    middlewares: std.ArrayList(*HookMiddleware),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MiddlewareChain {
        return .{
            .middlewares = std.ArrayList(*HookMiddleware).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MiddlewareChain) void {
        self.middlewares.deinit();
    }
    
    pub fn addMiddleware(self: *MiddlewareChain, middleware: *HookMiddleware) !void {
        try self.middlewares.append(middleware);
    }
    
    pub fn execute(self: *const MiddlewareChain, hook: *Hook, context: *HookContext) !HookResult {
        if (self.middlewares.items.len == 0) {
            return hook.execute(context);
        }
        
        return self.executeMiddleware(0, hook, context);
    }
    
    fn executeMiddleware(self: *const MiddlewareChain, index: usize, hook: *Hook, context: *HookContext) !HookResult {
        if (index >= self.middlewares.items.len) {
            return hook.execute(context);
        }
        
        const middleware = self.middlewares.items[index];
        
        const ChainContext = struct {
            chain: *const MiddlewareChain,
            next_index: usize,
            
            fn next(ctx: *const @This(), h: *Hook, c: *HookContext) !HookResult {
                return ctx.chain.executeMiddleware(ctx.next_index, h, c);
            }
        };
        
        const chain_context = ChainContext{
            .chain = self,
            .next_index = index + 1,
        };
        
        return middleware.process(
            middleware,
            hook,
            context,
            struct {
                fn nextWrapper(h: *Hook, c: *HookContext) !HookResult {
                    return chain_context.next(&chain_context, h, c);
                }
            }.nextWrapper,
        );
    }
};

// Predefined middleware

// Logging middleware
pub const LoggingMiddleware = struct {
    middleware: HookMiddleware,
    log_level: std.log.Level,
    include_timing: bool,
    include_result: bool,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: struct {
        log_level: std.log.Level = .info,
        include_timing: bool = true,
        include_result: bool = false,
    }) !*LoggingMiddleware {
        const self = try allocator.create(LoggingMiddleware);
        self.* = .{
            .middleware = .{
                .vtable = &.{
                    .process = process,
                    .deinit = deinit,
                },
            },
            .log_level = config.log_level,
            .include_timing = config.include_timing,
            .include_result = config.include_result,
            .allocator = allocator,
        };
        return self;
    }
    
    fn process(
        middleware: *HookMiddleware,
        hook: *Hook,
        context: *HookContext,
        next: HookMiddleware.NextFn,
    ) !HookResult {
        const self = @fieldParentPtr(LoggingMiddleware, "middleware", middleware);
        
        const start_time = if (self.include_timing) std.time.milliTimestamp() else 0;
        
        std.log.scoped(.hook_middleware).debug(
            "Executing hook '{s}' at point '{s}'",
            .{ hook.id, context.point.toString() },
        );
        
        const result = next(hook, context) catch |err| {
            std.log.scoped(.hook_middleware).err(
                "Hook '{s}' failed: {s}",
                .{ hook.id, @errorName(err) },
            );
            return err;
        };
        
        if (self.include_timing) {
            const duration = std.time.milliTimestamp() - start_time;
            std.log.scoped(.hook_middleware).debug(
                "Hook '{s}' completed in {d}ms",
                .{ hook.id, duration },
            );
        }
        
        if (self.include_result and result.modified_data != null) {
            const result_str = std.json.stringifyAlloc(
                self.allocator,
                result.modified_data.?,
                .{},
            ) catch "<stringify failed>";
            defer if (!std.mem.eql(u8, result_str, "<stringify failed>"))
                self.allocator.free(result_str);
            
            std.log.scoped(.hook_middleware).debug(
                "Hook '{s}' result: {s}",
                .{ hook.id, result_str },
            );
        }
        
        return result;
    }
    
    fn deinit(middleware: *HookMiddleware) void {
        const self = @fieldParentPtr(LoggingMiddleware, "middleware", middleware);
        self.allocator.destroy(self);
    }
};

// Error handling middleware
pub const ErrorHandlingMiddleware = struct {
    middleware: HookMiddleware,
    retry_count: u8,
    retry_delay_ms: u32,
    fallback_result: ?HookResult,
    error_handler: ?*const fn (err: anyerror, hook: *Hook, context: *HookContext) anyerror!HookResult,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: struct {
        retry_count: u8 = 3,
        retry_delay_ms: u32 = 1000,
        fallback_result: ?HookResult = null,
        error_handler: ?*const fn (err: anyerror, hook: *Hook, context: *HookContext) anyerror!HookResult = null,
    }) !*ErrorHandlingMiddleware {
        const self = try allocator.create(ErrorHandlingMiddleware);
        self.* = .{
            .middleware = .{
                .vtable = &.{
                    .process = process,
                    .deinit = deinit,
                },
            },
            .retry_count = config.retry_count,
            .retry_delay_ms = config.retry_delay_ms,
            .fallback_result = config.fallback_result,
            .error_handler = config.error_handler,
            .allocator = allocator,
        };
        return self;
    }
    
    fn process(
        middleware: *HookMiddleware,
        hook: *Hook,
        context: *HookContext,
        next: HookMiddleware.NextFn,
    ) !HookResult {
        const self = @fieldParentPtr(ErrorHandlingMiddleware, "middleware", middleware);
        
        var attempts: u8 = 0;
        while (attempts <= self.retry_count) : (attempts += 1) {
            if (attempts > 0) {
                std.time.sleep(self.retry_delay_ms * std.time.ns_per_ms);
            }
            
            const result = next(hook, context) catch |err| {
                if (attempts < self.retry_count) {
                    std.log.warn(
                        "Hook '{s}' failed (attempt {d}/{d}): {s}",
                        .{ hook.id, attempts + 1, self.retry_count + 1, @errorName(err) },
                    );
                    continue;
                }
                
                // All retries exhausted
                if (self.error_handler) |handler| {
                    return handler(err, hook, context);
                }
                
                if (self.fallback_result) |fallback| {
                    return fallback;
                }
                
                return err;
            };
            
            return result;
        }
        
        unreachable;
    }
    
    fn deinit(middleware: *HookMiddleware) void {
        const self = @fieldParentPtr(ErrorHandlingMiddleware, "middleware", middleware);
        self.allocator.destroy(self);
    }
};

// Caching middleware
pub const CachingMiddleware = struct {
    middleware: HookMiddleware,
    cache: std.StringHashMap(CacheEntry),
    ttl_ms: u64,
    max_entries: usize,
    key_generator: ?*const fn (hook: *Hook, context: *HookContext, allocator: std.mem.Allocator) anyerror![]u8,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    
    const CacheEntry = struct {
        result: HookResult,
        timestamp: i64,
        hit_count: u32,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: struct {
        ttl_ms: u64 = 60000, // 1 minute default
        max_entries: usize = 1000,
        key_generator: ?*const fn (hook: *Hook, context: *HookContext, allocator: std.mem.Allocator) anyerror![]u8 = null,
    }) !*CachingMiddleware {
        const self = try allocator.create(CachingMiddleware);
        self.* = .{
            .middleware = .{
                .vtable = &.{
                    .process = process,
                    .deinit = deinit,
                },
            },
            .cache = std.StringHashMap(CacheEntry).init(allocator),
            .ttl_ms = config.ttl_ms,
            .max_entries = config.max_entries,
            .key_generator = config.key_generator,
            .mutex = .{},
            .allocator = allocator,
        };
        return self;
    }
    
    fn process(
        middleware: *HookMiddleware,
        hook: *Hook,
        context: *HookContext,
        next: HookMiddleware.NextFn,
    ) !HookResult {
        const self = @fieldParentPtr(CachingMiddleware, "middleware", middleware);
        
        // Generate cache key
        const key = if (self.key_generator) |gen|
            try gen(hook, context, self.allocator)
        else
            try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ hook.id, context.point.toString() });
        defer self.allocator.free(key);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check cache
        if (self.cache.get(key)) |*entry| {
            const now = std.time.milliTimestamp();
            if (now - entry.timestamp < @as(i64, @intCast(self.ttl_ms))) {
                entry.hit_count += 1;
                return entry.result;
            }
            
            // Entry expired, remove it
            _ = self.cache.remove(key);
        }
        
        // Not in cache or expired, execute hook
        self.mutex.unlock();
        const result = try next(hook, context);
        self.mutex.lock();
        
        // Cache the result
        if (self.cache.count() >= self.max_entries) {
            // Evict oldest entry
            var oldest_key: ?[]const u8 = null;
            var oldest_time: i64 = std.math.maxInt(i64);
            
            var iter = self.cache.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.timestamp < oldest_time) {
                    oldest_time = entry.value_ptr.timestamp;
                    oldest_key = entry.key_ptr.*;
                }
            }
            
            if (oldest_key) |old_key| {
                _ = self.cache.remove(old_key);
            }
        }
        
        try self.cache.put(try self.allocator.dupe(u8, key), .{
            .result = result,
            .timestamp = std.time.milliTimestamp(),
            .hit_count = 0,
        });
        
        return result;
    }
    
    fn deinit(middleware: *HookMiddleware) void {
        const self = @fieldParentPtr(CachingMiddleware, "middleware", middleware);
        
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
        
        self.allocator.destroy(self);
    }
};

// Transformation middleware
pub const TransformationMiddleware = struct {
    middleware: HookMiddleware,
    input_transformer: ?*const fn (data: ?std.json.Value, allocator: std.mem.Allocator) anyerror!?std.json.Value,
    output_transformer: ?*const fn (result: HookResult, allocator: std.mem.Allocator) anyerror!HookResult,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, config: struct {
        input_transformer: ?*const fn (data: ?std.json.Value, allocator: std.mem.Allocator) anyerror!?std.json.Value = null,
        output_transformer: ?*const fn (result: HookResult, allocator: std.mem.Allocator) anyerror!HookResult = null,
    }) !*TransformationMiddleware {
        const self = try allocator.create(TransformationMiddleware);
        self.* = .{
            .middleware = .{
                .vtable = &.{
                    .process = process,
                    .deinit = deinit,
                },
            },
            .input_transformer = config.input_transformer,
            .output_transformer = config.output_transformer,
            .allocator = allocator,
        };
        return self;
    }
    
    fn process(
        middleware: *HookMiddleware,
        hook: *Hook,
        context: *HookContext,
        next: HookMiddleware.NextFn,
    ) !HookResult {
        const self = @fieldParentPtr(TransformationMiddleware, "middleware", middleware);
        
        // Transform input if transformer is provided
        if (self.input_transformer) |transformer| {
            const original_input = context.input_data;
            context.input_data = try transformer(original_input, self.allocator);
            defer context.input_data = original_input;
            
            const result = try next(hook, context);
            
            // Transform output if transformer is provided
            if (self.output_transformer) |out_transformer| {
                return out_transformer(result, self.allocator);
            }
            
            return result;
        }
        
        const result = try next(hook, context);
        
        // Transform output if transformer is provided
        if (self.output_transformer) |out_transformer| {
            return out_transformer(result, self.allocator);
        }
        
        return result;
    }
    
    fn deinit(middleware: *HookMiddleware) void {
        const self = @fieldParentPtr(TransformationMiddleware, "middleware", middleware);
        self.allocator.destroy(self);
    }
};

// Validation middleware
pub const ValidationMiddleware = struct {
    middleware: HookMiddleware,
    input_validator: ?*const fn (data: ?std.json.Value) anyerror!void,
    output_validator: ?*const fn (result: HookResult) anyerror!void,
    on_validation_error: ValidationErrorAction,
    allocator: std.mem.Allocator,
    
    pub const ValidationErrorAction = enum {
        propagate_error,
        skip_hook,
        use_default,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: struct {
        input_validator: ?*const fn (data: ?std.json.Value) anyerror!void = null,
        output_validator: ?*const fn (result: HookResult) anyerror!void = null,
        on_validation_error: ValidationErrorAction = .propagate_error,
    }) !*ValidationMiddleware {
        const self = try allocator.create(ValidationMiddleware);
        self.* = .{
            .middleware = .{
                .vtable = &.{
                    .process = process,
                    .deinit = deinit,
                },
            },
            .input_validator = config.input_validator,
            .output_validator = config.output_validator,
            .on_validation_error = config.on_validation_error,
            .allocator = allocator,
        };
        return self;
    }
    
    fn process(
        middleware: *HookMiddleware,
        hook: *Hook,
        context: *HookContext,
        next: HookMiddleware.NextFn,
    ) !HookResult {
        const self = @fieldParentPtr(ValidationMiddleware, "middleware", middleware);
        
        // Validate input
        if (self.input_validator) |validator| {
            validator(context.input_data) catch |err| {
                switch (self.on_validation_error) {
                    .propagate_error => return err,
                    .skip_hook => return HookResult{ .continue_processing = true },
                    .use_default => return HookResult{
                        .continue_processing = true,
                        .modified_data = .{ .null = {} },
                    },
                }
            };
        }
        
        const result = try next(hook, context);
        
        // Validate output
        if (self.output_validator) |validator| {
            validator(result) catch |err| {
                switch (self.on_validation_error) {
                    .propagate_error => return err,
                    .skip_hook => return HookResult{ .continue_processing = true },
                    .use_default => return HookResult{
                        .continue_processing = true,
                        .modified_data = .{ .null = {} },
                    },
                }
            };
        }
        
        return result;
    }
    
    fn deinit(middleware: *HookMiddleware) void {
        const self = @fieldParentPtr(ValidationMiddleware, "middleware", middleware);
        self.allocator.destroy(self);
    }
};

// Middleware builder for convenience
pub const MiddlewareBuilder = struct {
    allocator: std.mem.Allocator,
    chain: MiddlewareChain,
    
    pub fn init(allocator: std.mem.Allocator) MiddlewareBuilder {
        return .{
            .allocator = allocator,
            .chain = MiddlewareChain.init(allocator),
        };
    }
    
    pub fn deinit(self: *MiddlewareBuilder) void {
        self.chain.deinit();
    }
    
    pub fn withLogging(self: *MiddlewareBuilder, config: anytype) !*MiddlewareBuilder {
        const middleware = try LoggingMiddleware.init(self.allocator, config);
        try self.chain.addMiddleware(&middleware.middleware);
        return self;
    }
    
    pub fn withErrorHandling(self: *MiddlewareBuilder, config: anytype) !*MiddlewareBuilder {
        const middleware = try ErrorHandlingMiddleware.init(self.allocator, config);
        try self.chain.addMiddleware(&middleware.middleware);
        return self;
    }
    
    pub fn withCaching(self: *MiddlewareBuilder, config: anytype) !*MiddlewareBuilder {
        const middleware = try CachingMiddleware.init(self.allocator, config);
        try self.chain.addMiddleware(&middleware.middleware);
        return self;
    }
    
    pub fn withTransformation(self: *MiddlewareBuilder, config: anytype) !*MiddlewareBuilder {
        const middleware = try TransformationMiddleware.init(self.allocator, config);
        try self.chain.addMiddleware(&middleware.middleware);
        return self;
    }
    
    pub fn withValidation(self: *MiddlewareBuilder, config: anytype) !*MiddlewareBuilder {
        const middleware = try ValidationMiddleware.init(self.allocator, config);
        try self.chain.addMiddleware(&middleware.middleware);
        return self;
    }
    
    pub fn build(self: *MiddlewareBuilder) MiddlewareChain {
        const chain = self.chain;
        self.chain = MiddlewareChain.init(self.allocator);
        return chain;
    }
};

// Tests
test "middleware chain" {
    const allocator = std.testing.allocator;
    
    var chain = MiddlewareChain.init(allocator);
    defer chain.deinit();
    
    // Add logging middleware
    const logging = try LoggingMiddleware.init(allocator, .{});
    defer logging.middleware.deinit();
    try chain.addMiddleware(&logging.middleware);
    
    // Create test hook
    var hook = Hook{
        .id = "test",
        .name = "Test Hook",
        .description = "Test",
        .vtable = &.{
            .execute = struct {
                fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                    _ = h;
                    _ = ctx;
                    return HookResult{
                        .continue_processing = true,
                        .modified_data = .{ .string = "test result" },
                    };
                }
            }.execute,
        },
        .supported_points = &[_]types.HookPoint{.agent_before_run},
    };
    
    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = types.HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    const result = try chain.execute(&hook, &context);
    try std.testing.expect(result.continue_processing);
    try std.testing.expect(result.modified_data != null);
}

test "error handling middleware" {
    const allocator = std.testing.allocator;
    
    var chain = MiddlewareChain.init(allocator);
    defer chain.deinit();
    
    // Add error handling middleware
    const error_handler = try ErrorHandlingMiddleware.init(allocator, .{
        .retry_count = 2,
        .retry_delay_ms = 10,
        .fallback_result = HookResult{
            .continue_processing = true,
            .modified_data = .{ .string = "fallback" },
        },
    });
    defer error_handler.middleware.deinit();
    try chain.addMiddleware(&error_handler.middleware);
    
    // Create hook that fails
    var attempts: u8 = 0;
    var hook = Hook{
        .id = "failing",
        .name = "Failing Hook",
        .description = "Always fails",
        .vtable = &.{
            .execute = struct {
                fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                    _ = h;
                    _ = ctx;
                    attempts += 1;
                    return error.TestError;
                }
            }.execute,
        },
        .supported_points = &[_]types.HookPoint{.agent_before_run},
    };
    
    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = types.HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    const result = try chain.execute(&hook, &context);
    
    // Should have retried 3 times (initial + 2 retries)
    try std.testing.expectEqual(@as(u8, 3), attempts);
    
    // Should return fallback result
    try std.testing.expect(result.continue_processing);
    try std.testing.expectEqualStrings("fallback", result.modified_data.?.string);
}