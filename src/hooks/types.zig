// ABOUTME: Base hook interfaces and types for the comprehensive hook system
// ABOUTME: Provides extensible hook points for agents and workflows with lifecycle management

const std = @import("std");
const RunContext = @import("../context.zig").RunContext;
const Agent = @import("../agent.zig").Agent;

// Hook point enumeration
pub const HookPoint = enum {
    // Agent lifecycle hooks
    agent_init,
    agent_before_run,
    agent_after_run,
    agent_cleanup,
    agent_error,
    
    // Workflow hooks
    workflow_start,
    workflow_step_start,
    workflow_step_complete,
    workflow_step_error,
    workflow_complete,
    workflow_error,
    
    // Tool hooks
    tool_before_execute,
    tool_after_execute,
    tool_error,
    
    // Provider hooks
    provider_before_request,
    provider_after_response,
    provider_error,
    
    // Memory hooks
    memory_before_save,
    memory_after_load,
    
    // Custom hook points
    custom,
    
    pub fn toString(self: HookPoint) []const u8 {
        return @tagName(self);
    }
};

// Hook priority for ordering
pub const HookPriority = enum(i32) {
    highest = -1000,
    high = -100,
    normal = 0,
    low = 100,
    lowest = 1000,
    
    pub fn compare(a: HookPriority, b: HookPriority) std.math.Order {
        return std.math.order(@intFromEnum(a), @intFromEnum(b));
    }
};

// Hook execution result
pub const HookResult = struct {
    // Whether to continue processing
    continue_processing: bool = true,
    
    // Modified data (if any)
    modified_data: ?std.json.Value = null,
    
    // Metrics or telemetry data
    metrics: ?std.json.Value = null,
    
    // Error if hook failed
    error_info: ?ErrorInfo = null,
    
    pub const ErrorInfo = struct {
        message: []const u8,
        error_type: []const u8,
        recoverable: bool = true,
        retry_after_ms: ?u32 = null,
    };
    
    pub fn shouldContinue(self: *const HookResult) bool {
        return self.continue_processing and self.error_info == null;
    }
};

// Hook execution context
pub const HookContext = struct {
    // Hook point being executed
    point: HookPoint,
    
    // Agent executing the hook (if applicable)
    agent: ?*Agent = null,
    
    // Run context
    run_context: *RunContext,
    
    // Input data for the hook
    input_data: ?std.json.Value = null,
    
    // Output data from previous processing
    output_data: ?std.json.Value = null,
    
    // Additional metadata
    metadata: std.StringHashMap(std.json.Value),
    
    // Timing information
    start_time: i64,
    
    // Hook chain position
    hook_index: usize = 0,
    total_hooks: usize = 0,
    
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        point: HookPoint,
        run_context: *RunContext,
    ) HookContext {
        return .{
            .point = point,
            .run_context = run_context,
            .metadata = std.StringHashMap(std.json.Value).init(allocator),
            .start_time = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HookContext) void {
        self.metadata.deinit();
    }
    
    pub fn setMetadata(self: *HookContext, key: []const u8, value: std.json.Value) !void {
        try self.metadata.put(key, value);
    }
    
    pub fn getMetadata(self: *const HookContext, key: []const u8) ?std.json.Value {
        return self.metadata.get(key);
    }
    
    pub fn getElapsedMs(self: *const HookContext) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }
};

// Base hook interface
pub const Hook = struct {
    // Unique identifier
    id: []const u8,
    
    // Human-readable name
    name: []const u8,
    
    // Description
    description: []const u8,
    
    // Hook implementation
    vtable: *const VTable,
    
    // Priority for ordering
    priority: HookPriority = .normal,
    
    // Which hook points this hook handles
    supported_points: []const HookPoint,
    
    // Whether the hook is enabled
    enabled: bool = true,
    
    // Configuration
    config: ?std.json.Value = null,
    
    pub const VTable = struct {
        // Execute the hook
        execute: *const fn (hook: *Hook, context: *HookContext) anyerror!HookResult,
        
        // Initialize the hook
        init: ?*const fn (hook: *Hook, allocator: std.mem.Allocator) anyerror!void = null,
        
        // Cleanup the hook
        deinit: ?*const fn (hook: *Hook) void = null,
        
        // Validate hook configuration
        validate: ?*const fn (hook: *Hook) anyerror!void = null,
        
        // Get hook metrics
        getMetrics: ?*const fn (hook: *Hook, allocator: std.mem.Allocator) anyerror!std.json.Value = null,
    };
    
    pub fn execute(self: *Hook, context: *HookContext) !HookResult {
        if (!self.enabled) {
            return HookResult{ .continue_processing = true };
        }
        
        // Check if this hook handles the current point
        var handles_point = false;
        for (self.supported_points) |point| {
            if (point == context.point or point == .custom) {
                handles_point = true;
                break;
            }
        }
        
        if (!handles_point) {
            return HookResult{ .continue_processing = true };
        }
        
        return self.vtable.execute(self, context);
    }
    
    pub fn init(self: *Hook, allocator: std.mem.Allocator) !void {
        if (self.vtable.init) |init_fn| {
            try init_fn(self, allocator);
        }
    }
    
    pub fn deinit(self: *Hook) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
    
    pub fn validate(self: *Hook) !void {
        if (self.vtable.validate) |validate_fn| {
            try validate_fn(self);
        }
    }
    
    pub fn supportsPoint(self: *const Hook, point: HookPoint) bool {
        for (self.supported_points) |supported| {
            if (supported == point or supported == .custom) {
                return true;
            }
        }
        return false;
    }
};

// Hook chain for composing multiple hooks
pub const HookChain = struct {
    hooks: std.ArrayList(*Hook),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HookChain {
        return .{
            .hooks = std.ArrayList(*Hook).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HookChain) void {
        self.hooks.deinit();
    }
    
    pub fn addHook(self: *HookChain, hook: *Hook) !void {
        try self.hooks.append(hook);
        self.sortByPriority();
    }
    
    pub fn removeHook(self: *HookChain, hook_id: []const u8) bool {
        var i: usize = 0;
        while (i < self.hooks.items.len) {
            if (std.mem.eql(u8, self.hooks.items[i].id, hook_id)) {
                _ = self.hooks.orderedRemove(i);
                return true;
            }
            i += 1;
        }
        return false;
    }
    
    pub fn execute(self: *HookChain, context: *HookContext) !HookResult {
        var result = HookResult{};
        
        context.total_hooks = self.hooks.items.len;
        
        for (self.hooks.items, 0..) |hook, i| {
            context.hook_index = i;
            
            const hook_result = try hook.execute(context);
            
            // Merge results
            if (hook_result.modified_data) |data| {
                result.modified_data = data;
                context.input_data = data; // Pass to next hook
            }
            
            if (hook_result.metrics) |metrics| {
                // TODO: Merge metrics
                result.metrics = metrics;
            }
            
            if (hook_result.error_info) |error_info| {
                result.error_info = error_info;
                result.continue_processing = error_info.recoverable;
            }
            
            if (!hook_result.continue_processing) {
                result.continue_processing = false;
                break;
            }
        }
        
        return result;
    }
    
    fn sortByPriority(self: *HookChain) void {
        std.sort.sort(*Hook, self.hooks.items, {}, struct {
            fn lessThan(_: void, a: *Hook, b: *Hook) bool {
                return a.priority.compare(b.priority) == .lt;
            }
        }.lessThan);
    }
    
    pub fn getHooksByPoint(self: *const HookChain, point: HookPoint, allocator: std.mem.Allocator) ![]*Hook {
        var matching = std.ArrayList(*Hook).init(allocator);
        errdefer matching.deinit();
        
        for (self.hooks.items) |hook| {
            if (hook.supportsPoint(point)) {
                try matching.append(hook);
            }
        }
        
        return try matching.toOwnedSlice();
    }
};

// Hook configuration
pub const HookConfig = struct {
    // Hook identifier
    id: []const u8,
    
    // Hook type/implementation
    hook_type: []const u8,
    
    // Priority
    priority: HookPriority = .normal,
    
    // Enabled state
    enabled: bool = true,
    
    // Hook-specific configuration
    config: ?std.json.Value = null,
    
    // Which points to hook into
    hook_points: []const HookPoint,
};

// Hook factory function type
pub const HookFactory = *const fn (allocator: std.mem.Allocator, config: HookConfig) anyerror!*Hook;

// Common hook categories
pub const HookCategory = enum {
    metrics,
    logging,
    tracing,
    validation,
    caching,
    rate_limiting,
    security,
    custom,
    
    pub fn toString(self: HookCategory) []const u8 {
        return @tagName(self);
    }
};

// Hook metadata for discovery
pub const HookMetadata = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    category: HookCategory,
    version: []const u8,
    author: ?[]const u8 = null,
    supported_points: []const HookPoint,
    configuration_schema: ?std.json.Value = null,
};

// Tests
test "hook execution" {
    const allocator = std.testing.allocator;
    
    // Create a simple test hook
    const TestHook = struct {
        hook: Hook,
        execute_count: usize = 0,
        
        pub fn execute(hook: *Hook, context: *HookContext) !HookResult {
            _ = context;
            const self = @fieldParentPtr(@This(), "hook", hook);
            self.execute_count += 1;
            
            return HookResult{
                .continue_processing = true,
                .modified_data = .{ .string = "modified" },
            };
        }
    };
    
    var test_hook = TestHook{
        .hook = .{
            .id = "test_hook",
            .name = "Test Hook",
            .description = "A test hook",
            .vtable = &.{
                .execute = TestHook.execute,
            },
            .supported_points = &[_]HookPoint{.agent_before_run},
        },
    };
    
    // Create context
    var run_context = try RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    // Execute hook
    const result = try test_hook.hook.execute(&context);
    
    try std.testing.expect(result.continue_processing);
    try std.testing.expect(result.modified_data != null);
    try std.testing.expectEqual(@as(usize, 1), test_hook.execute_count);
}

test "hook chain" {
    const allocator = std.testing.allocator;
    
    // Create test hooks
    var hooks = [_]Hook{
        .{
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
            .priority = .high,
            .supported_points = &[_]HookPoint{.agent_before_run},
        },
        .{
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
            .priority = .low,
            .supported_points = &[_]HookPoint{.agent_before_run},
        },
    };
    
    var chain = HookChain.init(allocator);
    defer chain.deinit();
    
    try chain.addHook(&hooks[0]);
    try chain.addHook(&hooks[1]);
    
    // Verify hooks are sorted by priority
    try std.testing.expectEqualStrings("hook1", chain.hooks.items[0].id);
    try std.testing.expectEqualStrings("hook2", chain.hooks.items[1].id);
    
    // Create context
    var run_context = try RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    // Execute chain
    const result = try chain.execute(&context);
    try std.testing.expect(result.continue_processing);
}