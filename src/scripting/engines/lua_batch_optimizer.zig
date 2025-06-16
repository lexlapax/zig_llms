// ABOUTME: Lua API call batch optimization system for improved performance
// ABOUTME: Provides batching, memoization, and profiling for frequently used bridge functions

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../context.zig").ScriptContext;
const LuaValueConverter = @import("lua_value_converter.zig");

/// Batch optimization errors
pub const BatchOptimizationError = error{
    BatchFull,
    InvalidBatchId,
    OptimizationFailed,
    CacheError,
    ProfilingDisabled,
} || std.mem.Allocator.Error;

/// Configuration for batch optimization
pub const BatchConfig = struct {
    max_batch_size: usize = 10,
    batch_timeout_ms: u64 = 100,
    enable_memoization: bool = true,
    cache_size: usize = 1000,
    cache_ttl_ms: u64 = 5 * 60 * 1000, // 5 minutes
    enable_profiling: bool = true,
    profile_sample_rate: f32 = 0.1, // 10% sampling
};

/// A single API call in a batch
pub const BatchedCall = struct {
    bridge_name: []const u8,
    function_name: []const u8,
    args: []ScriptValue,
    callback_ref: ?c_int = null, // Lua function reference for async completion
    priority: CallPriority = .normal,

    pub const CallPriority = enum {
        low,
        normal,
        high,
        critical,
    };

    pub fn deinit(self: *BatchedCall, allocator: std.mem.Allocator) void {
        for (self.args) |*arg| {
            arg.deinit(allocator);
        }
        allocator.free(self.args);
        allocator.free(self.bridge_name);
        allocator.free(self.function_name);
    }
};

/// Result of a batched API call
pub const BatchResult = struct {
    success: bool,
    result: ?ScriptValue = null,
    error_message: ?[]const u8 = null,
    execution_time_ns: u64,
    cache_hit: bool = false,

    pub fn deinit(self: *BatchResult, allocator: std.mem.Allocator) void {
        if (self.result) |*result| {
            result.deinit(allocator);
        }
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
    }
};

/// Cache entry for memoized function calls
const CacheEntry = struct {
    key_hash: u64,
    result: ScriptValue,
    timestamp: i64,
    hit_count: u64 = 1,

    pub fn isExpired(self: *const CacheEntry, ttl_ms: u64) bool {
        const now = std.time.milliTimestamp();
        return (now - self.timestamp) > ttl_ms;
    }

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
    }
};

/// Performance metrics for profiling
pub const ProfileMetrics = struct {
    total_calls: u64 = 0,
    total_execution_time_ns: u64 = 0,
    batch_count: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    avg_batch_size: f64 = 0.0,

    pub fn getAverageCallTime(self: *const ProfileMetrics) f64 {
        if (self.total_calls == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_execution_time_ns)) / @as(f64, @floatFromInt(self.total_calls));
    }

    pub fn getCacheHitRate(self: *const ProfileMetrics) f64 {
        const total_cache_access = self.cache_hits + self.cache_misses;
        if (total_cache_access == 0) return 0.0;
        return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total_cache_access));
    }
};

/// Lua API batch optimizer
pub const LuaBatchOptimizer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: BatchConfig,

    // Batching
    current_batch: std.ArrayList(BatchedCall),
    batch_timer: std.time.Timer,
    batch_id_counter: u64 = 1,

    // Memoization cache
    cache: std.HashMap(u64, CacheEntry, std.HashMap.getAutoHashFn(u64), std.HashMap.getAutoEqlFn(u64), std.HashMap.default_max_load_percentage),
    cache_mutex: std.Thread.Mutex = .{},

    // Profiling
    metrics: ProfileMetrics,
    profile_samples: std.ArrayList(ProfileSample),
    profiling_mutex: std.Thread.Mutex = .{},

    const ProfileSample = struct {
        bridge_name: []const u8,
        function_name: []const u8,
        execution_time_ns: u64,
        batch_size: usize,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator, config: BatchConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .config = config,
            .current_batch = std.ArrayList(BatchedCall).init(allocator),
            .batch_timer = try std.time.Timer.start(),
            .cache = std.HashMap(u64, CacheEntry, std.HashMap.getAutoHashFn(u64), std.HashMap.getAutoEqlFn(u64), std.HashMap.default_max_load_percentage).init(allocator),
            .metrics = ProfileMetrics{},
            .profile_samples = std.ArrayList(ProfileSample).init(allocator),
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up current batch
        for (self.current_batch.items) |*call| {
            call.deinit(self.allocator);
        }
        self.current_batch.deinit();

        // Clean up cache
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        var cache_iter = self.cache.iterator();
        while (cache_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.deinit();

        // Clean up profiling data
        self.profiling_mutex.lock();
        defer self.profiling_mutex.unlock();

        for (self.profile_samples.items) |*sample| {
            self.allocator.free(sample.bridge_name);
            self.allocator.free(sample.function_name);
        }
        self.profile_samples.deinit();

        self.allocator.destroy(self);
    }

    /// Add a call to the current batch
    pub fn addCall(
        self: *Self,
        bridge_name: []const u8,
        function_name: []const u8,
        args: []const ScriptValue,
        callback_ref: ?c_int,
        priority: BatchedCall.CallPriority,
    ) !u64 {
        // Check if batch is full or timeout exceeded
        if (self.shouldFlushBatch()) {
            try self.flushBatch();
        }

        // Check cache first if memoization is enabled
        if (self.config.enable_memoization) {
            const cache_key = self.computeCacheKey(bridge_name, function_name, args);
            if (self.getCachedResult(cache_key)) |cached_result| {
                // TODO: Execute callback immediately with cached result
                self.recordCacheHit();
                return self.batch_id_counter;
            }
            self.recordCacheMiss();
        }

        // Create batched call
        const call = BatchedCall{
            .bridge_name = try self.allocator.dupe(u8, bridge_name),
            .function_name = try self.allocator.dupe(u8, function_name),
            .args = try self.cloneScriptValues(args),
            .callback_ref = callback_ref,
            .priority = priority,
        };

        try self.current_batch.append(call);

        const batch_id = self.batch_id_counter;
        self.batch_id_counter += 1;

        return batch_id;
    }

    /// Flush the current batch and execute all calls
    pub fn flushBatch(self: *Self) !void {
        if (self.current_batch.items.len == 0) return;

        const start_time = std.time.nanoTimestamp();

        // Sort batch by priority
        std.sort.sort(BatchedCall, self.current_batch.items, {}, comparePriority);

        // Execute all calls in the batch
        var results = std.ArrayList(BatchResult).init(self.allocator);
        defer {
            for (results.items) |*result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }

        for (self.current_batch.items) |*call| {
            const call_start = std.time.nanoTimestamp();

            // Execute the actual API call (placeholder - would call actual bridge)
            const result = self.executeCall(call) catch |err| BatchResult{
                .success = false,
                .error_message = try self.allocator.dupe(u8, @errorName(err)),
                .execution_time_ns = std.time.nanoTimestamp() - call_start,
            };

            try results.append(result);

            // Cache successful results if memoization is enabled
            if (self.config.enable_memoization and result.success and result.result != null) {
                const cache_key = self.computeCacheKey(call.bridge_name, call.function_name, call.args);
                try self.cacheResult(cache_key, result.result.?);
            }

            // Execute callback if provided
            if (call.callback_ref) |callback| {
                // TODO: Execute Lua callback with result
                _ = callback;
            }
        }

        const batch_execution_time = std.time.nanoTimestamp() - start_time;

        // Update metrics
        self.updateMetrics(self.current_batch.items.len, batch_execution_time);

        // Profile if enabled
        if (self.config.enable_profiling) {
            self.profileBatch(self.current_batch.items, batch_execution_time);
        }

        // Clean up batch
        for (self.current_batch.items) |*call| {
            call.deinit(self.allocator);
        }
        self.current_batch.clearRetainingCapacity();

        // Reset batch timer
        self.batch_timer.reset();
    }

    /// Check if the batch should be flushed
    fn shouldFlushBatch(self: *Self) bool {
        // Flush if batch is full
        if (self.current_batch.items.len >= self.config.max_batch_size) {
            return true;
        }

        // Flush if timeout exceeded and batch is not empty
        if (self.current_batch.items.len > 0) {
            const elapsed_ms = self.batch_timer.read() / std.time.ns_per_ms;
            if (elapsed_ms >= self.config.batch_timeout_ms) {
                return true;
            }
        }

        return false;
    }

    /// Execute a single API call (placeholder implementation)
    fn executeCall(self: *Self, call: *const BatchedCall) !BatchResult {
        _ = self;
        _ = call;

        // This is a placeholder - in the real implementation, this would
        // dispatch to the appropriate bridge function

        const execution_time = 1000000; // 1ms in nanoseconds

        return BatchResult{
            .success = true,
            .result = ScriptValue{ .string = "placeholder_result" },
            .execution_time_ns = execution_time,
        };
    }

    /// Compute cache key for function call
    fn computeCacheKey(self: *Self, bridge_name: []const u8, function_name: []const u8, args: []const ScriptValue) u64 {
        _ = self;

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(bridge_name);
        hasher.update(function_name);

        // Hash arguments (simplified - would need proper ScriptValue hashing)
        for (args) |arg| {
            switch (arg) {
                .nil => hasher.update("nil"),
                .boolean => |b| hasher.update(if (b) "true" else "false"),
                .integer => |i| {
                    const bytes = std.mem.asBytes(&i);
                    hasher.update(bytes);
                },
                .number => |n| {
                    const bytes = std.mem.asBytes(&n);
                    hasher.update(bytes);
                },
                .string => |s| hasher.update(s),
                else => hasher.update("complex"), // Simplified for complex types
            }
        }

        return hasher.final();
    }

    /// Get cached result if available
    fn getCachedResult(self: *Self, key: u64) ?ScriptValue {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        if (self.cache.getPtr(key)) |entry| {
            if (!entry.isExpired(self.config.cache_ttl_ms)) {
                entry.hit_count += 1;
                return entry.result; // Note: would need to clone for real use
            } else {
                // Remove expired entry
                var removed_entry = self.cache.remove(key).?;
                removed_entry.value.deinit(self.allocator);
            }
        }

        return null;
    }

    /// Cache a result
    fn cacheResult(self: *Self, key: u64, result: ScriptValue) !void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        // Check cache size limit
        if (self.cache.count() >= self.config.cache_size) {
            try self.evictOldestCacheEntry();
        }

        const entry = CacheEntry{
            .key_hash = key,
            .result = result, // Note: would need to clone for real use
            .timestamp = std.time.milliTimestamp(),
        };

        try self.cache.put(key, entry);
    }

    /// Evict the oldest cache entry
    fn evictOldestCacheEntry(self: *Self) !void {
        var oldest_key: ?u64 = null;
        var oldest_timestamp: i64 = std.math.maxInt(i64);

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_timestamp) {
                oldest_timestamp = entry.value_ptr.timestamp;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            var removed_entry = self.cache.remove(key).?;
            removed_entry.value.deinit(self.allocator);
        }
    }

    /// Clone ScriptValue array
    fn cloneScriptValues(self: *Self, values: []const ScriptValue) ![]ScriptValue {
        const cloned = try self.allocator.alloc(ScriptValue, values.len);

        for (values, 0..) |value, i| {
            cloned[i] = try value.clone(self.allocator);
        }

        return cloned;
    }

    /// Compare batch calls by priority
    fn comparePriority(context: void, a: BatchedCall, b: BatchedCall) bool {
        _ = context;
        return @intFromEnum(a.priority) > @intFromEnum(b.priority);
    }

    /// Update performance metrics
    fn updateMetrics(self: *Self, batch_size: usize, execution_time_ns: u64) void {
        self.metrics.total_calls += batch_size;
        self.metrics.total_execution_time_ns += execution_time_ns;
        self.metrics.batch_count += 1;

        // Update average batch size
        self.metrics.avg_batch_size = @as(f64, @floatFromInt(self.metrics.total_calls)) / @as(f64, @floatFromInt(self.metrics.batch_count));
    }

    /// Record cache hit
    fn recordCacheHit(self: *Self) void {
        self.metrics.cache_hits += 1;
    }

    /// Record cache miss
    fn recordCacheMiss(self: *Self) void {
        self.metrics.cache_misses += 1;
    }

    /// Profile batch execution
    fn profileBatch(self: *Self, calls: []const BatchedCall, execution_time_ns: u64) void {
        if (!self.config.enable_profiling) return;

        // Sample based on configured rate
        const random = std.rand.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
        if (random.random().float(f32) > self.config.profile_sample_rate) return;

        self.profiling_mutex.lock();
        defer self.profiling_mutex.unlock();

        const timestamp = std.time.milliTimestamp();

        for (calls) |call| {
            const sample = ProfileSample{
                .bridge_name = self.allocator.dupe(u8, call.bridge_name) catch continue,
                .function_name = self.allocator.dupe(u8, call.function_name) catch continue,
                .execution_time_ns = execution_time_ns / calls.len, // Approximate per-call time
                .batch_size = calls.len,
                .timestamp = timestamp,
            };

            self.profile_samples.append(sample) catch break;
        }
    }

    /// Get current performance metrics
    pub fn getMetrics(self: *Self) ProfileMetrics {
        return self.metrics;
    }

    /// Get profiling samples
    pub fn getProfileSamples(self: *Self) []const ProfileSample {
        self.profiling_mutex.lock();
        defer self.profiling_mutex.unlock();

        return self.profile_samples.items;
    }

    /// Clear profiling samples
    pub fn clearProfileSamples(self: *Self) void {
        self.profiling_mutex.lock();
        defer self.profiling_mutex.unlock();

        for (self.profile_samples.items) |*sample| {
            self.allocator.free(sample.bridge_name);
            self.allocator.free(sample.function_name);
        }
        self.profile_samples.clearRetainingCapacity();
    }

    /// Force flush the current batch
    pub fn forceFlush(self: *Self) !void {
        try self.flushBatch();
    }

    /// Clear the cache
    pub fn clearCache(self: *Self) void {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.clearRetainingCapacity();
    }
};
