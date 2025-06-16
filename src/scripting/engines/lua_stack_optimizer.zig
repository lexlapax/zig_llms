// ABOUTME: Lua stack pre-sizing optimization system for performance
// ABOUTME: Provides intelligent stack management and optimization strategies

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;

/// Stack optimization errors
pub const StackOptimizationError = error{
    StackOverflow,
    InvalidStackState,
    OptimizationFailed,
    InsufficientStack,
} || std.mem.Allocator.Error;

/// Stack usage patterns for different operations
pub const StackUsagePattern = enum {
    minimal, // 1-2 stack slots
    small, // 3-8 stack slots
    medium, // 9-16 stack slots
    large, // 17-32 stack slots
    very_large, // 33+ stack slots

    pub fn getSlotCount(self: StackUsagePattern) usize {
        return switch (self) {
            .minimal => 2,
            .small => 8,
            .medium => 16,
            .large => 32,
            .very_large => 64,
        };
    }
};

/// Function signature analysis for stack prediction
pub const FunctionSignature = struct {
    name: []const u8,
    min_args: usize,
    max_args: ?usize, // null for variadic
    return_count: usize,
    stack_pattern: StackUsagePattern,
    temporary_slots: usize = 0, // Additional temporary slots needed
};

/// Stack optimization statistics
pub const StackStats = struct {
    total_operations: u64 = 0,
    successful_predictions: u64 = 0,
    over_allocations: u64 = 0,
    under_allocations: u64 = 0,
    stack_overflows: u64 = 0,
    max_stack_used: usize = 0,
    avg_stack_used: f64 = 0.0,

    pub fn getPredictionAccuracy(self: *const StackStats) f64 {
        if (self.total_operations == 0) return 0.0;
        return @as(f64, @floatFromInt(self.successful_predictions)) / @as(f64, @floatFromInt(self.total_operations));
    }

    pub fn getOverAllocationRate(self: *const StackStats) f64 {
        if (self.total_operations == 0) return 0.0;
        return @as(f64, @floatFromInt(self.over_allocations)) / @as(f64, @floatFromInt(self.total_operations));
    }
};

/// Stack optimization configuration
pub const StackOptimizerConfig = struct {
    enable_predictive_sizing: bool = true,
    enable_adaptive_learning: bool = true,
    enable_stack_monitoring: bool = true,
    safety_margin_slots: usize = 4,
    max_prealloc_slots: usize = 256,
    learning_window_size: usize = 1000,
};

/// Historical stack usage data for learning
const StackUsageHistory = struct {
    function_name: []const u8,
    arg_count: usize,
    actual_stack_used: usize,
    predicted_stack: usize,
    timestamp: i64,

    pub fn deinit(self: *StackUsageHistory, allocator: std.mem.Allocator) void {
        allocator.free(self.function_name);
    }
};

/// Lua stack optimizer
pub const LuaStackOptimizer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: StackOptimizerConfig,

    // Function signature database
    function_signatures: std.StringHashMap(FunctionSignature),

    // Learning system
    usage_history: std.ArrayList(StackUsageHistory),
    learned_patterns: std.StringHashMap(StackUsagePattern),

    // Statistics
    stats: StackStats,

    // Monitoring
    current_operations: std.StringHashMap(StackMonitor),

    const StackMonitor = struct {
        start_stack_top: c_int,
        predicted_slots: usize,
        start_time: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: StackOptimizerConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = config,
            .function_signatures = std.StringHashMap(FunctionSignature).init(allocator),
            .usage_history = std.ArrayList(StackUsageHistory).init(allocator),
            .learned_patterns = std.StringHashMap(StackUsagePattern).init(allocator),
            .stats = StackStats{},
            .current_operations = std.StringHashMap(StackMonitor).init(allocator),
        };

        // Initialize with built-in function signatures
        try self.initializeBuiltinSignatures();

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up function signatures
        var sig_iter = self.function_signatures.iterator();
        while (sig_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.name);
        }
        self.function_signatures.deinit();

        // Clean up usage history
        for (self.usage_history.items) |*history| {
            history.deinit(self.allocator);
        }
        self.usage_history.deinit();

        // Clean up learned patterns
        var pattern_iter = self.learned_patterns.iterator();
        while (pattern_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.learned_patterns.deinit();

        // Clean up current operations
        var op_iter = self.current_operations.iterator();
        while (op_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.current_operations.deinit();

        self.allocator.destroy(self);
    }

    /// Pre-size Lua stack for optimal performance
    pub fn presizeStack(
        self: *Self,
        wrapper: *LuaWrapper,
        function_name: []const u8,
        arg_count: usize,
    ) StackOptimizationError!usize {
        const predicted_slots = self.predictStackUsage(function_name, arg_count);

        // Add safety margin
        const total_slots = predicted_slots + self.config.safety_margin_slots;
        const clamped_slots = @min(total_slots, self.config.max_prealloc_slots);

        // Check if we have enough stack space
        if (lua.c.lua_checkstack(wrapper.state, @intCast(clamped_slots)) == 0) {
            self.stats.stack_overflows += 1;
            return StackOptimizationError.StackOverflow;
        }

        // Start monitoring if enabled
        if (self.config.enable_stack_monitoring) {
            try self.startMonitoring(function_name, predicted_slots, wrapper.state);
        }

        return clamped_slots;
    }

    /// Predict stack usage for a function call
    fn predictStackUsage(self: *Self, function_name: []const u8, arg_count: usize) usize {
        // Check learned patterns first
        if (self.config.enable_adaptive_learning) {
            if (self.learned_patterns.get(function_name)) |pattern| {
                return pattern.getSlotCount() + arg_count;
            }
        }

        // Check function signature database
        if (self.function_signatures.get(function_name)) |signature| {
            return signature.stack_pattern.getSlotCount() +
                signature.temporary_slots +
                @max(arg_count, signature.min_args);
        }

        // Fallback to heuristic based on argument count
        const base_slots = self.predictFromArgCount(arg_count);

        // Record this as a learning opportunity
        if (self.config.enable_adaptive_learning) {
            self.recordUnknownFunction(function_name, arg_count, base_slots);
        }

        return base_slots;
    }

    /// Predict stack usage based on argument count heuristic
    fn predictFromArgCount(self: *Self, arg_count: usize) usize {
        _ = self;

        // Heuristic: base requirements + args + some buffer for processing
        const base_processing = 4; // Minimum slots for function processing
        const processing_buffer = (arg_count / 3) + 1; // Buffer grows with complexity

        return base_processing + arg_count + processing_buffer;
    }

    /// Finish monitoring a function call and update statistics
    pub fn finishMonitoring(
        self: *Self,
        wrapper: *LuaWrapper,
        function_name: []const u8,
    ) void {
        if (!self.config.enable_stack_monitoring) return;

        const monitor = self.current_operations.get(function_name) orelse return;

        const current_stack_top = lua.c.lua_gettop(wrapper.state);
        const actual_stack_used = @as(usize, @intCast(@max(0, current_stack_top - monitor.start_stack_top)));

        // Update statistics
        self.updateStatistics(monitor.predicted_slots, actual_stack_used);

        // Record for learning
        if (self.config.enable_adaptive_learning) {
            self.recordUsageHistory(function_name, 0, actual_stack_used, monitor.predicted_slots);
        }

        // Remove from current operations
        _ = self.current_operations.remove(function_name);
    }

    /// Start monitoring a function call
    fn startMonitoring(
        self: *Self,
        function_name: []const u8,
        predicted_slots: usize,
        L: *lua.c.lua_State,
    ) !void {
        const monitor = StackMonitor{
            .start_stack_top = lua.c.lua_gettop(L),
            .predicted_slots = predicted_slots,
            .start_time = std.time.milliTimestamp(),
        };

        const key = try self.allocator.dupe(u8, function_name);
        try self.current_operations.put(key, monitor);
    }

    /// Update prediction statistics
    fn updateStatistics(self: *Self, predicted: usize, actual: usize) void {
        self.stats.total_operations += 1;

        // Update max stack used
        self.stats.max_stack_used = @max(self.stats.max_stack_used, actual);

        // Update average stack used
        const total_stack = self.stats.avg_stack_used * @as(f64, @floatFromInt(self.stats.total_operations - 1));
        self.stats.avg_stack_used = (total_stack + @as(f64, @floatFromInt(actual))) / @as(f64, @floatFromInt(self.stats.total_operations));

        // Check prediction accuracy
        const tolerance = 2; // Allow 2 slot tolerance
        if (actual <= predicted + tolerance and actual >= predicted - tolerance) {
            self.stats.successful_predictions += 1;
        } else if (predicted > actual) {
            self.stats.over_allocations += 1;
        } else {
            self.stats.under_allocations += 1;
        }
    }

    /// Record usage history for learning
    fn recordUsageHistory(
        self: *Self,
        function_name: []const u8,
        arg_count: usize,
        actual_stack: usize,
        predicted_stack: usize,
    ) void {
        // Limit history size
        if (self.usage_history.items.len >= self.config.learning_window_size) {
            var old_entry = self.usage_history.orderedRemove(0);
            old_entry.deinit(self.allocator);
        }

        const history = StackUsageHistory{
            .function_name = self.allocator.dupe(u8, function_name) catch return,
            .arg_count = arg_count,
            .actual_stack_used = actual_stack,
            .predicted_stack = predicted_stack,
            .timestamp = std.time.milliTimestamp(),
        };

        self.usage_history.append(history) catch return;

        // Update learned patterns
        self.updateLearnedPatterns(function_name);
    }

    /// Update learned patterns based on usage history
    fn updateLearnedPatterns(self: *Self, function_name: []const u8) void {
        // Collect recent usage data for this function
        var total_usage: usize = 0;
        var sample_count: usize = 0;

        for (self.usage_history.items) |history| {
            if (std.mem.eql(u8, history.function_name, function_name)) {
                total_usage += history.actual_stack_used;
                sample_count += 1;
            }
        }

        if (sample_count == 0) return;

        // Calculate average usage and determine pattern
        const avg_usage = total_usage / sample_count;
        const pattern = classifyStackUsage(avg_usage);

        // Update learned pattern
        const key = self.allocator.dupe(u8, function_name) catch return;
        self.learned_patterns.put(key, pattern) catch return;
    }

    /// Record an unknown function for future learning
    fn recordUnknownFunction(self: *Self, function_name: []const u8, arg_count: usize, predicted_slots: usize) void {
        _ = self;
        _ = function_name;
        _ = arg_count;
        _ = predicted_slots;

        // This could trigger more aggressive monitoring for unknown functions
        // or add them to a learning queue
    }

    /// Initialize built-in function signatures
    fn initializeBuiltinSignatures(self: *Self) !void {
        const signatures = [_]FunctionSignature{
            // Agent bridge functions
            .{
                .name = "agent.create",
                .min_args = 1,
                .max_args = 1,
                .return_count = 1,
                .stack_pattern = .small,
                .temporary_slots = 3,
            },
            .{
                .name = "agent.run",
                .min_args = 2,
                .max_args = 3,
                .return_count = 1,
                .stack_pattern = .medium,
                .temporary_slots = 5,
            },

            // Tool bridge functions
            .{
                .name = "tool.execute",
                .min_args = 2,
                .max_args = 3,
                .return_count = 1,
                .stack_pattern = .medium,
                .temporary_slots = 4,
            },
            .{
                .name = "tool.list",
                .min_args = 0,
                .max_args = 0,
                .return_count = 1,
                .stack_pattern = .small,
                .temporary_slots = 2,
            },

            // Workflow bridge functions
            .{
                .name = "workflow.create",
                .min_args = 1,
                .max_args = 1,
                .return_count = 1,
                .stack_pattern = .large,
                .temporary_slots = 8,
            },
            .{
                .name = "workflow.execute",
                .min_args = 1,
                .max_args = 3,
                .return_count = 1,
                .stack_pattern = .very_large,
                .temporary_slots = 12,
            },

            // Provider bridge functions
            .{
                .name = "provider.chat",
                .min_args = 1,
                .max_args = 2,
                .return_count = 1,
                .stack_pattern = .large,
                .temporary_slots = 6,
            },

            // Common Lua operations
            .{
                .name = "table.insert",
                .min_args = 2,
                .max_args = 3,
                .return_count = 0,
                .stack_pattern = .minimal,
                .temporary_slots = 1,
            },
            .{
                .name = "string.format",
                .min_args = 1,
                .max_args = null, // variadic
                .return_count = 1,
                .stack_pattern = .small,
                .temporary_slots = 2,
            },
        };

        for (signatures) |signature| {
            const key = try self.allocator.dupe(u8, signature.name);
            const sig = FunctionSignature{
                .name = try self.allocator.dupe(u8, signature.name),
                .min_args = signature.min_args,
                .max_args = signature.max_args,
                .return_count = signature.return_count,
                .stack_pattern = signature.stack_pattern,
                .temporary_slots = signature.temporary_slots,
            };

            try self.function_signatures.put(key, sig);
        }
    }

    /// Get current statistics
    pub fn getStatistics(self: *const Self) StackStats {
        return self.stats;
    }

    /// Clear usage history and learned patterns
    pub fn clearLearningData(self: *Self) void {
        // Clear usage history
        for (self.usage_history.items) |*history| {
            history.deinit(self.allocator);
        }
        self.usage_history.clearRetainingCapacity();

        // Clear learned patterns
        var iter = self.learned_patterns.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.learned_patterns.clearRetainingCapacity();
    }

    /// Get learned patterns
    pub fn getLearnedPatterns(self: *Self) std.StringHashMap(StackUsagePattern) {
        return self.learned_patterns;
    }
};

/// Classify stack usage into patterns
fn classifyStackUsage(usage: usize) StackUsagePattern {
    return if (usage <= 2) .minimal else if (usage <= 8) .small else if (usage <= 16) .medium else if (usage <= 32) .large else .very_large;
}

/// Convenience function to presize stack with optimizer
pub fn presizeStackForCall(
    optimizer: *LuaStackOptimizer,
    wrapper: *LuaWrapper,
    function_name: []const u8,
    arg_count: usize,
) !usize {
    return optimizer.presizeStack(wrapper, function_name, arg_count);
}

/// Convenience function to finish monitoring
pub fn finishStackMonitoring(
    optimizer: *LuaStackOptimizer,
    wrapper: *LuaWrapper,
    function_name: []const u8,
) void {
    optimizer.finishMonitoring(wrapper, function_name);
}
