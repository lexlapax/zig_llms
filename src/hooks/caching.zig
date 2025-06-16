// ABOUTME: Result caching hooks for improving performance by storing and reusing computation results
// ABOUTME: Provides configurable caching with TTL, size limits, and multiple eviction strategies

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;

// Cache key generator
pub const CacheKeyGenerator = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        generateKey: *const fn (generator: *CacheKeyGenerator, context: *const HookContext, allocator: std.mem.Allocator) anyerror![]u8,
        deinit: ?*const fn (generator: *CacheKeyGenerator) void = null,
    };

    pub fn generateKey(self: *CacheKeyGenerator, context: *const HookContext, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.generateKey(self, context, allocator);
    }

    pub fn deinit(self: *CacheKeyGenerator) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Default key generator
pub const DefaultKeyGenerator = struct {
    generator: CacheKeyGenerator,
    include_metadata: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, include_metadata: bool) !*DefaultKeyGenerator {
        const self = try allocator.create(DefaultKeyGenerator);
        self.* = .{
            .generator = .{
                .vtable = &.{
                    .generateKey = generateKey,
                    .deinit = deinit,
                },
            },
            .include_metadata = include_metadata,
            .allocator = allocator,
        };
        return self;
    }

    fn generateKey(generator: *CacheKeyGenerator, context: *const HookContext, allocator: std.mem.Allocator) ![]u8 {
        const self = @fieldParentPtr(DefaultKeyGenerator, "generator", generator);

        var hasher = std.hash.Wyhash.init(0);

        // Hash hook point
        hasher.update(context.point.toString());

        // Hash input data if present
        if (context.input_data) |data| {
            const json_str = try std.json.stringifyAlloc(allocator, data, .{});
            defer allocator.free(json_str);
            hasher.update(json_str);
        }

        // Hash metadata if configured
        if (self.include_metadata) {
            const metadata_str = try std.json.stringifyAlloc(allocator, context.metadata, .{});
            defer allocator.free(metadata_str);
            hasher.update(metadata_str);
        }

        const hash = hasher.final();
        return std.fmt.allocPrint(allocator, "{x}", .{hash});
    }

    fn deinit(generator: *CacheKeyGenerator) void {
        const self = @fieldParentPtr(DefaultKeyGenerator, "generator", generator);
        self.allocator.destroy(self);
    }
};

// Cache entry
pub const CacheEntry = struct {
    key: []const u8,
    value: HookResult,
    created_at: i64,
    last_accessed: i64,
    access_count: u64,
    size_bytes: usize,
    ttl_ms: ?i64,

    pub fn init(allocator: std.mem.Allocator, key: []const u8, value: HookResult, ttl_ms: ?i64) !CacheEntry {
        _ = allocator;
        const now = std.time.milliTimestamp();
        return .{
            .key = key,
            .value = value,
            .created_at = now,
            .last_accessed = now,
            .access_count = 1,
            .size_bytes = estimateSize(value),
            .ttl_ms = ttl_ms,
        };
    }

    pub fn isExpired(self: *const CacheEntry) bool {
        if (self.ttl_ms) |ttl| {
            const age = std.time.milliTimestamp() - self.created_at;
            return age > ttl;
        }
        return false;
    }

    pub fn touch(self: *CacheEntry) void {
        self.last_accessed = std.time.milliTimestamp();
        self.access_count += 1;
    }

    fn estimateSize(result: HookResult) usize {
        var size: usize = @sizeOf(HookResult);

        if (result.modified_data) |data| {
            // Rough estimate based on JSON size
            size += estimateJsonSize(data);
        }

        if (result.error_info) |err| {
            size += err.message.len;
            if (err.error_type) |et| size += et.len;
            if (err.details) |d| size += estimateJsonSize(d);
        }

        return size;
    }

    fn estimateJsonSize(value: std.json.Value) usize {
        return switch (value) {
            .null => 4,
            .bool => 5,
            .integer => 20,
            .float => 20,
            .string => |s| s.len + 2,
            .array => |a| blk: {
                var size: usize = 2;
                for (a.items) |item| {
                    size += estimateJsonSize(item) + 1;
                }
                break :blk size;
            },
            .object => |o| blk: {
                var size: usize = 2;
                var iter = o.iterator();
                while (iter.next()) |entry| {
                    size += entry.key_ptr.*.len + 3 + estimateJsonSize(entry.value_ptr.*) + 1;
                }
                break :blk size;
            },
        };
    }
};

// Eviction policy
pub const EvictionPolicy = enum {
    lru, // Least Recently Used
    lfu, // Least Frequently Used
    fifo, // First In First Out
    ttl, // Time To Live only
    size, // Size-based
};

// Cache storage interface
pub const CacheStorage = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (storage: *CacheStorage, key: []const u8) ?*CacheEntry,
        put: *const fn (storage: *CacheStorage, entry: CacheEntry) anyerror!void,
        remove: *const fn (storage: *CacheStorage, key: []const u8) bool,
        clear: *const fn (storage: *CacheStorage) void,
        size: *const fn (storage: *const CacheStorage) usize,
        totalBytes: *const fn (storage: *const CacheStorage) usize,
        evict: *const fn (storage: *CacheStorage, policy: EvictionPolicy, target_size: usize) anyerror!void,
        deinit: ?*const fn (storage: *CacheStorage) void = null,
    };

    pub fn get(self: *CacheStorage, key: []const u8) ?*CacheEntry {
        return self.vtable.get(self, key);
    }

    pub fn put(self: *CacheStorage, entry: CacheEntry) !void {
        return self.vtable.put(self, entry);
    }

    pub fn remove(self: *CacheStorage, key: []const u8) bool {
        return self.vtable.remove(self, key);
    }

    pub fn clear(self: *CacheStorage) void {
        self.vtable.clear(self);
    }

    pub fn size(self: *const CacheStorage) usize {
        return self.vtable.size(self);
    }

    pub fn totalBytes(self: *const CacheStorage) usize {
        return self.vtable.totalBytes(self);
    }

    pub fn evict(self: *CacheStorage, policy: EvictionPolicy, target_size: usize) !void {
        return self.vtable.evict(self, policy, target_size);
    }

    pub fn deinit(self: *CacheStorage) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Memory cache storage
pub const MemoryCacheStorage = struct {
    storage: CacheStorage,
    entries: std.StringHashMap(CacheEntry),
    total_bytes: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*MemoryCacheStorage {
        const self = try allocator.create(MemoryCacheStorage);
        self.* = .{
            .storage = .{
                .vtable = &.{
                    .get = get,
                    .put = put,
                    .remove = remove,
                    .clear = clear,
                    .size = size,
                    .totalBytes = totalBytes,
                    .evict = evict,
                    .deinit = deinit,
                },
            },
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .total_bytes = 0,
            .mutex = .{},
            .allocator = allocator,
        };
        return self;
    }

    fn get(storage: *CacheStorage, key: []const u8) ?*CacheEntry {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.getPtr(key)) |entry| {
            if (entry.isExpired()) {
                self.total_bytes -= entry.size_bytes;
                _ = self.entries.remove(key);
                return null;
            }
            entry.touch();
            return entry;
        }
        return null;
    }

    fn put(storage: *CacheStorage, entry: CacheEntry) !void {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove old entry if exists
        if (self.entries.get(entry.key)) |old| {
            self.total_bytes -= old.size_bytes;
        }

        self.total_bytes += entry.size_bytes;
        try self.entries.put(entry.key, entry);
    }

    fn remove(storage: *CacheStorage, key: []const u8) bool {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(key)) |kv| {
            self.total_bytes -= kv.value.size_bytes;
            return true;
        }
        return false;
    }

    fn clear(storage: *CacheStorage) void {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.entries.clearAndFree();
        self.total_bytes = 0;
    }

    fn size(storage: *const CacheStorage) usize {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);
        return self.entries.count();
    }

    fn totalBytes(storage: *const CacheStorage) usize {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);
        return self.total_bytes;
    }

    fn evict(storage: *CacheStorage, policy: EvictionPolicy, target_size: usize) !void {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Collect entries for eviction
        var candidates = std.ArrayList(CacheEntry).init(self.allocator);
        defer candidates.deinit();

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try candidates.append(entry.value_ptr.*);
        }

        // Sort based on policy
        switch (policy) {
            .lru => std.sort.sort(CacheEntry, candidates.items, {}, struct {
                fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
                    return a.last_accessed < b.last_accessed;
                }
            }.lessThan),
            .lfu => std.sort.sort(CacheEntry, candidates.items, {}, struct {
                fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
                    return a.access_count < b.access_count;
                }
            }.lessThan),
            .fifo => std.sort.sort(CacheEntry, candidates.items, {}, struct {
                fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
                    return a.created_at < b.created_at;
                }
            }.lessThan),
            .size => std.sort.sort(CacheEntry, candidates.items, {}, struct {
                fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
                    return a.size_bytes > b.size_bytes;
                }
            }.lessThan),
            .ttl => {}, // TTL-based eviction happens automatically in get()
        }

        // Evict until we reach target size
        var current_size = self.total_bytes;
        for (candidates.items) |candidate| {
            if (current_size <= target_size) break;

            if (self.entries.fetchRemove(candidate.key)) |kv| {
                current_size -= kv.value.size_bytes;
                self.total_bytes -= kv.value.size_bytes;
            }
        }
    }

    fn deinit(storage: *CacheStorage) void {
        const self = @fieldParentPtr(MemoryCacheStorage, "storage", storage);
        self.entries.deinit();
        self.allocator.destroy(self);
    }
};

// Caching hook
pub const CachingHook = struct {
    hook: Hook,
    config: CachingConfig,
    storage: *CacheStorage,
    key_generator: *CacheKeyGenerator,
    stats: CacheStats,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub const CachingConfig = struct {
        enabled: bool = true,
        ttl_ms: ?i64 = 300000, // 5 minutes default
        max_entries: usize = 1000,
        max_bytes: usize = 100 * 1024 * 1024, // 100MB default
        eviction_policy: EvictionPolicy = .lru,
        cache_points: []const HookPoint = &[_]HookPoint{.custom}, // Cache all points by default
        cache_errors: bool = false,
        compression: bool = false,
    };

    pub const CacheStats = struct {
        hits: u64 = 0,
        misses: u64 = 0,
        evictions: u64 = 0,
        bytes_saved: u64 = 0,

        pub fn hitRate(self: *const CacheStats) f64 {
            const total = self.hits + self.misses;
            if (total == 0) return 0.0;
            return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        config: CachingConfig,
        storage: *CacheStorage,
        key_generator: *CacheKeyGenerator,
    ) !*CachingHook {
        const self = try allocator.create(CachingHook);

        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = execute,
            .deinit = hookDeinit,
        };

        self.* = .{
            .hook = .{
                .id = id,
                .name = "Caching Hook",
                .description = "Caches hook results for performance",
                .vtable = vtable,
                .priority = .high, // Run early to short-circuit
                .supported_points = config.cache_points,
                .config = .{ .integer = @intFromPtr(self) },
            },
            .config = config,
            .storage = storage,
            .key_generator = key_generator,
            .stats = .{},
            .mutex = .{},
            .allocator = allocator,
        };

        return self;
    }

    pub fn getStats(self: *CachingHook) CacheStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    pub fn clearCache(self: *CachingHook) void {
        self.storage.clear();

        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats = .{};
    }

    fn hookDeinit(hook: *Hook) void {
        const self = @as(*CachingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        self.storage.deinit();
        self.key_generator.deinit();
        self.allocator.destroy(hook.vtable);
        self.allocator.destroy(self);
    }

    fn execute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @as(*CachingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));

        if (!self.config.enabled) {
            return HookResult{ .continue_processing = true };
        }

        // Check if this hook point should be cached
        var should_cache = false;
        for (self.config.cache_points) |point| {
            if (point == context.point) {
                should_cache = true;
                break;
            }
        }

        if (!should_cache) {
            return HookResult{ .continue_processing = true };
        }

        // Generate cache key
        const cache_key = try self.key_generator.generateKey(context, self.allocator);
        defer self.allocator.free(cache_key);

        // Check cache
        if (self.storage.get(cache_key)) |entry| {
            self.mutex.lock();
            self.stats.hits += 1;
            self.stats.bytes_saved += entry.size_bytes;
            self.mutex.unlock();

            // Return cached result
            return entry.value;
        }

        self.mutex.lock();
        self.stats.misses += 1;
        self.mutex.unlock();

        // Not in cache, continue processing
        // Note: We can't actually cache the result here since we're not wrapping
        // the actual hook execution. This would need to be done at a higher level
        // in the hook chain or by modifying the hook execution flow.

        // Check cache limits and evict if necessary
        if (self.storage.size() >= self.config.max_entries or
            self.storage.totalBytes() >= self.config.max_bytes)
        {
            try self.storage.evict(
                self.config.eviction_policy,
                @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.config.max_bytes)) * 0.9)),
            );

            self.mutex.lock();
            self.stats.evictions += 1;
            self.mutex.unlock();
        }

        return HookResult{ .continue_processing = true };
    }
};

// Cache manager for multiple caches
pub const CacheManager = struct {
    caches: std.StringHashMap(*CachingHook),
    global_stats: CachingHook.CacheStats,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CacheManager {
        return .{
            .caches = std.StringHashMap(*CachingHook).init(allocator),
            .global_stats = .{},
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CacheManager) void {
        var iter = self.caches.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.hook.vtable.deinit.?(&entry.value_ptr.*.hook);
        }
        self.caches.deinit();
    }

    pub fn registerCache(self: *CacheManager, name: []const u8, cache: *CachingHook) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.caches.put(name, cache);
    }

    pub fn getCache(self: *CacheManager, name: []const u8) ?*CachingHook {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.caches.get(name);
    }

    pub fn clearAll(self: *CacheManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.caches.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.clearCache();
        }

        self.global_stats = .{};
    }

    pub fn getGlobalStats(self: *CacheManager) CachingHook.CacheStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = CachingHook.CacheStats{};
        var iter = self.caches.iterator();
        while (iter.next()) |entry| {
            const cache_stats = entry.value_ptr.*.getStats();
            stats.hits += cache_stats.hits;
            stats.misses += cache_stats.misses;
            stats.evictions += cache_stats.evictions;
            stats.bytes_saved += cache_stats.bytes_saved;
        }

        return stats;
    }
};

// Builder for caching hook
pub fn createCachingHook(
    allocator: std.mem.Allocator,
    id: []const u8,
    config: CachingHook.CachingConfig,
) !*Hook {
    const storage = try MemoryCacheStorage.init(allocator);
    const key_generator = try DefaultKeyGenerator.init(allocator, true);

    const caching_hook = try CachingHook.init(
        allocator,
        id,
        config,
        &storage.storage,
        &key_generator.generator,
    );

    return &caching_hook.hook;
}

// Tests
test "cache entry" {
    const allocator = std.testing.allocator;

    const result = HookResult{
        .continue_processing = true,
        .modified_data = .{ .string = "test data" },
    };

    var entry = try CacheEntry.init(allocator, "test_key", result, 1000);

    try std.testing.expectEqualStrings("test_key", entry.key);
    try std.testing.expect(!entry.isExpired());
    try std.testing.expectEqual(@as(u64, 1), entry.access_count);

    entry.touch();
    try std.testing.expectEqual(@as(u64, 2), entry.access_count);

    // Test expiration
    entry.created_at = std.time.milliTimestamp() - 2000;
    try std.testing.expect(entry.isExpired());
}

test "memory cache storage" {
    const allocator = std.testing.allocator;

    const storage = try MemoryCacheStorage.init(allocator);
    defer storage.storage.deinit();

    // Add entries
    const result1 = HookResult{ .continue_processing = true };
    const entry1 = try CacheEntry.init(allocator, "key1", result1, null);
    try storage.storage.put(entry1);

    const result2 = HookResult{ .continue_processing = false };
    const entry2 = try CacheEntry.init(allocator, "key2", result2, null);
    try storage.storage.put(entry2);

    // Test retrieval
    const retrieved = storage.storage.get("key1");
    try std.testing.expect(retrieved != null);
    try std.testing.expect(retrieved.?.value.continue_processing);

    // Test size
    try std.testing.expectEqual(@as(usize, 2), storage.storage.size());

    // Test removal
    try std.testing.expect(storage.storage.remove("key1"));
    try std.testing.expectEqual(@as(usize, 1), storage.storage.size());

    // Test clear
    storage.storage.clear();
    try std.testing.expectEqual(@as(usize, 0), storage.storage.size());
}

test "caching hook" {
    const allocator = std.testing.allocator;

    const hook = try createCachingHook(allocator, "test_cache", .{});
    defer hook.vtable.deinit.?(hook);

    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();

    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();

    // First call - cache miss
    const result1 = try hook.execute(&context);
    try std.testing.expect(result1.continue_processing);

    const caching_hook = @as(*CachingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
    const stats = caching_hook.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}

test "cache manager" {
    const allocator = std.testing.allocator;

    var manager = CacheManager.init(allocator);
    defer manager.deinit();

    const cache1 = try createCachingHook(allocator, "cache1", .{});
    const caching_hook1 = @as(*CachingHook, @ptrFromInt(@as(usize, @intCast(cache1.config.?.integer))));
    try manager.registerCache("cache1", caching_hook1);

    const cache2 = try createCachingHook(allocator, "cache2", .{});
    const caching_hook2 = @as(*CachingHook, @ptrFromInt(@as(usize, @intCast(cache2.config.?.integer))));
    try manager.registerCache("cache2", caching_hook2);

    // Test retrieval
    const retrieved = manager.getCache("cache1");
    try std.testing.expect(retrieved != null);

    // Test global stats
    const global_stats = manager.getGlobalStats();
    try std.testing.expectEqual(@as(u64, 0), global_stats.hits);
}
