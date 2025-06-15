// ABOUTME: Error handling strategies and recovery mechanisms for workflows
// ABOUTME: Provides comprehensive error handling including retry, compensation, and circuit breakers

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const RunContext = @import("../context.zig").RunContext;

// Workflow error types
pub const WorkflowError = error{
    StepExecutionFailed,
    TimeoutExceeded,
    ValidationFailed,
    ResourceUnavailable,
    CircuitBreakerOpen,
    CompensationFailed,
    RetryLimitExceeded,
    PreconditionFailed,
    PostconditionFailed,
    WorkflowAborted,
};

// Error details
pub const ErrorDetails = struct {
    error_type: []const u8,
    message: []const u8,
    step_id: ?[]const u8 = null,
    timestamp: i64,
    context: ?std.json.Value = null,
    stack_trace: ?[]const u8 = null,
    retry_count: u8 = 0,
    is_retriable: bool = true,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, err: anyerror, message: []const u8) ErrorDetails {
        return .{
            .error_type = @errorName(err),
            .message = message,
            .timestamp = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ErrorDetails) void {
        _ = self;
    }
    
    pub fn toJson(self: *const ErrorDetails) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        try obj.put("error_type", .{ .string = self.error_type });
        try obj.put("message", .{ .string = self.message });
        try obj.put("timestamp", .{ .integer = self.timestamp });
        try obj.put("retry_count", .{ .integer = self.retry_count });
        try obj.put("is_retriable", .{ .bool = self.is_retriable });
        
        if (self.step_id) |id| {
            try obj.put("step_id", .{ .string = id });
        }
        
        if (self.context) |ctx| {
            try obj.put("context", ctx);
        }
        
        if (self.stack_trace) |trace| {
            try obj.put("stack_trace", .{ .string = trace });
        }
        
        return .{ .object = obj };
    }
};

// Error handling strategy
pub const ErrorHandlingStrategy = struct {
    retry_policy: ?RetryPolicy = null,
    fallback_strategy: ?FallbackStrategy = null,
    circuit_breaker: ?CircuitBreaker = null,
    compensation_handler: ?CompensationHandler = null,
    error_filters: std.ArrayList(ErrorFilter),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ErrorHandlingStrategy {
        return .{
            .error_filters = std.ArrayList(ErrorFilter).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ErrorHandlingStrategy) void {
        for (self.error_filters.items) |*filter| {
            filter.deinit();
        }
        self.error_filters.deinit();
        
        if (self.circuit_breaker) |*cb| {
            cb.deinit();
        }
    }
    
    pub fn addErrorFilter(self: *ErrorHandlingStrategy, filter: ErrorFilter) !void {
        try self.error_filters.append(filter);
    }
    
    pub fn shouldRetry(self: *const ErrorHandlingStrategy, error_details: *const ErrorDetails) bool {
        // Check error filters
        for (self.error_filters.items) |*filter| {
            if (filter.matches(error_details) and !filter.is_retriable) {
                return false;
            }
        }
        
        // Check retry policy
        if (self.retry_policy) |policy| {
            return policy.shouldRetry(error_details);
        }
        
        return error_details.is_retriable;
    }
};

// Retry policy
pub const RetryPolicy = struct {
    max_attempts: u8 = 3,
    initial_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 60000,
    backoff_type: BackoffType = .exponential,
    jitter: bool = true,
    retriable_errors: ?[]const []const u8 = null,
    
    pub const BackoffType = enum {
        fixed,
        linear,
        exponential,
        fibonacci,
    };
    
    pub fn shouldRetry(self: *const RetryPolicy, error_details: *const ErrorDetails) bool {
        if (error_details.retry_count >= self.max_attempts) {
            return false;
        }
        
        if (self.retriable_errors) |errors| {
            for (errors) |err| {
                if (std.mem.eql(u8, error_details.error_type, err)) {
                    return true;
                }
            }
            return false;
        }
        
        return error_details.is_retriable;
    }
    
    pub fn getDelay(self: *const RetryPolicy, retry_count: u8) u32 {
        var delay = switch (self.backoff_type) {
            .fixed => self.initial_delay_ms,
            .linear => self.initial_delay_ms * (retry_count + 1),
            .exponential => blk: {
                const multiplier = std.math.pow(u32, 2, retry_count);
                break :blk self.initial_delay_ms * multiplier;
            },
            .fibonacci => blk: {
                var a: u32 = 0;
                var b: u32 = self.initial_delay_ms;
                var i: u8 = 0;
                while (i < retry_count) : (i += 1) {
                    const temp = a + b;
                    a = b;
                    b = temp;
                }
                break :blk b;
            },
        };
        
        delay = @min(delay, self.max_delay_ms);
        
        if (self.jitter) {
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.microTimestamp())));
            const jitter_amount = @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay)) * 0.1));
            const jitter = rng.random().intRangeAtMost(u32, 0, jitter_amount);
            delay = delay + jitter - (jitter_amount / 2);
        }
        
        return delay;
    }
};

// Fallback strategy
pub const FallbackStrategy = struct {
    fallback_type: FallbackType,
    
    pub const FallbackType = union(enum) {
        default_value: std.json.Value,
        fallback_step: []const u8,
        fallback_workflow: []const u8,
        custom_handler: *const fn (error_details: *const ErrorDetails, context: *WorkflowExecutionContext) anyerror!std.json.Value,
    };
    
    pub fn execute(self: *const FallbackStrategy, error_details: *const ErrorDetails, context: *WorkflowExecutionContext) !std.json.Value {
        return switch (self.fallback_type) {
            .default_value => |value| value,
            .fallback_step => |step_id| blk: {
                _ = step_id;
                // TODO: Execute specific fallback step
                break :blk error.FallbackStepNotImplemented;
            },
            .fallback_workflow => |workflow_id| blk: {
                _ = workflow_id;
                // TODO: Execute fallback workflow
                break :blk error.FallbackWorkflowNotImplemented;
            },
            .custom_handler => |handler| try handler(error_details, context),
        };
    }
};

// Circuit breaker
pub const CircuitBreaker = struct {
    state: State = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    last_failure_time: ?i64 = null,
    last_state_change: i64,
    config: Config,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,
    
    pub const State = enum {
        closed,
        open,
        half_open,
    };
    
    pub const Config = struct {
        failure_threshold: u32 = 5,
        success_threshold: u32 = 2,
        timeout_ms: u32 = 60000,
        half_open_max_attempts: u32 = 3,
    };
    
    pub fn init(allocator: std.mem.Allocator, config: Config) CircuitBreaker {
        return .{
            .config = config,
            .last_state_change = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *CircuitBreaker) void {
        _ = self;
    }
    
    pub fn allowRequest(self: *CircuitBreaker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        switch (self.state) {
            .closed => return true,
            .open => {
                const now = std.time.milliTimestamp();
                if (now - self.last_state_change >= self.config.timeout_ms) {
                    self.state = .half_open;
                    self.last_state_change = now;
                    self.failure_count = 0;
                    self.success_count = 0;
                    return true;
                }
                return false;
            },
            .half_open => return self.success_count + self.failure_count < self.config.half_open_max_attempts,
        }
    }
    
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.config.success_threshold) {
                    self.state = .closed;
                    self.last_state_change = std.time.milliTimestamp();
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .open => {},
        }
    }
    
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const now = std.time.milliTimestamp();
        self.last_failure_time = now;
        
        switch (self.state) {
            .closed => {
                self.failure_count += 1;
                if (self.failure_count >= self.config.failure_threshold) {
                    self.state = .open;
                    self.last_state_change = now;
                }
            },
            .half_open => {
                self.state = .open;
                self.last_state_change = now;
                self.failure_count = 0;
                self.success_count = 0;
            },
            .open => {},
        }
    }
    
    pub fn getState(self: *CircuitBreaker) State {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
};

// Compensation handler
pub const CompensationHandler = struct {
    compensations: std.StringHashMap(CompensationAction),
    allocator: std.mem.Allocator,
    
    pub const CompensationAction = struct {
        action_type: ActionType,
        order: i32 = 0,
        
        pub const ActionType = union(enum) {
            undo_step: []const u8,
            run_workflow: []const u8,
            custom_handler: *const fn (context: *WorkflowExecutionContext) anyerror!void,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) CompensationHandler {
        return .{
            .compensations = std.StringHashMap(CompensationAction).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *CompensationHandler) void {
        self.compensations.deinit();
    }
    
    pub fn addCompensation(self: *CompensationHandler, step_id: []const u8, action: CompensationAction) !void {
        try self.compensations.put(step_id, action);
    }
    
    pub fn compensate(self: *CompensationHandler, failed_step: []const u8, context: *WorkflowExecutionContext) !void {
        // Get all compensations up to the failed step
        var compensations_to_run = std.ArrayList(struct { step_id: []const u8, action: CompensationAction }).init(self.allocator);
        defer compensations_to_run.deinit();
        
        var iter = self.compensations.iterator();
        while (iter.next()) |entry| {
            try compensations_to_run.append(.{ .step_id = entry.key_ptr.*, .action = entry.value_ptr.* });
            if (std.mem.eql(u8, entry.key_ptr.*, failed_step)) {
                break;
            }
        }
        
        // Sort by order (reverse)
        std.sort.sort(
            @TypeOf(compensations_to_run.items[0]),
            compensations_to_run.items,
            {},
            struct {
                fn lessThan(_: void, a: anytype, b: anytype) bool {
                    return a.action.order > b.action.order;
                }
            }.lessThan,
        );
        
        // Execute compensations
        for (compensations_to_run.items) |item| {
            try self.executeCompensation(item.action, context);
        }
    }
    
    fn executeCompensation(self: *CompensationHandler, action: CompensationAction, context: *WorkflowExecutionContext) !void {
        _ = self;
        switch (action.action_type) {
            .undo_step => |step_id| {
                _ = step_id;
                // TODO: Implement step undo logic
                return error.UndoNotImplemented;
            },
            .run_workflow => |workflow_id| {
                _ = workflow_id;
                // TODO: Run compensation workflow
                return error.CompensationWorkflowNotImplemented;
            },
            .custom_handler => |handler| {
                try handler(context);
            },
        }
    }
};

// Error filter
pub const ErrorFilter = struct {
    filter_type: FilterType,
    is_retriable: bool = true,
    
    pub const FilterType = union(enum) {
        error_type: []const u8,
        error_pattern: []const u8,
        custom_predicate: *const fn (error_details: *const ErrorDetails) bool,
    };
    
    pub fn deinit(self: *ErrorFilter) void {
        _ = self;
    }
    
    pub fn matches(self: *const ErrorFilter, error_details: *const ErrorDetails) bool {
        return switch (self.filter_type) {
            .error_type => |err_type| std.mem.eql(u8, error_details.error_type, err_type),
            .error_pattern => |pattern| blk: {
                _ = pattern;
                // TODO: Implement pattern matching
                break :blk false;
            },
            .custom_predicate => |predicate| predicate(error_details),
        };
    }
};

// Workflow error handler
pub const WorkflowErrorHandler = struct {
    strategy: ErrorHandlingStrategy,
    error_log: std.ArrayList(ErrorDetails),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) WorkflowErrorHandler {
        return .{
            .strategy = ErrorHandlingStrategy.init(allocator),
            .error_log = std.ArrayList(ErrorDetails).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WorkflowErrorHandler) void {
        self.strategy.deinit();
        for (self.error_log.items) |*error_detail| {
            error_detail.deinit();
        }
        self.error_log.deinit();
    }
    
    pub fn handleError(
        self: *WorkflowErrorHandler,
        err: anyerror,
        step_id: ?[]const u8,
        context: *WorkflowExecutionContext,
    ) !std.json.Value {
        var error_details = ErrorDetails.init(self.allocator, err, "Workflow step execution failed");
        error_details.step_id = step_id;
        
        // Log error
        try self.error_log.append(error_details);
        
        // Check circuit breaker
        if (self.strategy.circuit_breaker) |*cb| {
            if (!cb.allowRequest()) {
                return WorkflowError.CircuitBreakerOpen;
            }
            cb.recordFailure();
        }
        
        // Check if should retry
        if (self.strategy.shouldRetry(&error_details)) {
            if (self.strategy.retry_policy) |policy| {
                const delay = policy.getDelay(error_details.retry_count);
                std.time.sleep(delay * std.time.ns_per_ms);
                
                // Update retry count for next attempt
                if (self.error_log.items.len > 0) {
                    self.error_log.items[self.error_log.items.len - 1].retry_count += 1;
                }
                
                return WorkflowError.StepExecutionFailed; // Signal retry
            }
        }
        
        // Try fallback
        if (self.strategy.fallback_strategy) |fallback| {
            return fallback.execute(&error_details, context) catch {
                // Fallback also failed, try compensation
                if (self.strategy.compensation_handler) |*handler| {
                    if (step_id) |id| {
                        try handler.compensate(id, context);
                    }
                }
                return err;
            };
        }
        
        // No recovery possible
        return err;
    }
    
    pub fn recordSuccess(self: *WorkflowErrorHandler) void {
        if (self.strategy.circuit_breaker) |*cb| {
            cb.recordSuccess();
        }
    }
    
    pub fn getErrorLog(self: *const WorkflowErrorHandler) []const ErrorDetails {
        return self.error_log.items;
    }
};

// Tests
test "retry policy" {
    const policy = RetryPolicy{
        .max_attempts = 3,
        .initial_delay_ms = 100,
        .backoff_type = .exponential,
        .jitter = false,
    };
    
    try std.testing.expectEqual(@as(u32, 100), policy.getDelay(0));
    try std.testing.expectEqual(@as(u32, 200), policy.getDelay(1));
    try std.testing.expectEqual(@as(u32, 400), policy.getDelay(2));
}

test "circuit breaker" {
    const allocator = std.testing.allocator;
    
    var cb = CircuitBreaker.init(allocator, .{
        .failure_threshold = 3,
        .success_threshold = 2,
        .timeout_ms = 100,
    });
    defer cb.deinit();
    
    try std.testing.expect(cb.allowRequest());
    try std.testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
    
    // Record failures to open circuit
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    
    try std.testing.expectEqual(CircuitBreaker.State.open, cb.getState());
    try std.testing.expect(!cb.allowRequest());
    
    // Wait for timeout
    std.time.sleep(150 * std.time.ns_per_ms);
    
    // Should transition to half-open
    try std.testing.expect(cb.allowRequest());
    try std.testing.expectEqual(CircuitBreaker.State.half_open, cb.getState());
    
    // Record successes to close circuit
    cb.recordSuccess();
    cb.recordSuccess();
    
    try std.testing.expectEqual(CircuitBreaker.State.closed, cb.getState());
}

test "error handling strategy" {
    const allocator = std.testing.allocator;
    
    var strategy = ErrorHandlingStrategy.init(allocator);
    defer strategy.deinit();
    
    strategy.retry_policy = RetryPolicy{
        .max_attempts = 2,
        .retriable_errors = &[_][]const u8{"NetworkError"},
    };
    
    const error_details = ErrorDetails{
        .error_type = "NetworkError",
        .message = "Connection failed",
        .timestamp = std.time.milliTimestamp(),
        .retry_count = 0,
        .is_retriable = true,
        .allocator = allocator,
    };
    
    try std.testing.expect(strategy.shouldRetry(&error_details));
}