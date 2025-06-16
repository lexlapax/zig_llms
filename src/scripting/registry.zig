// ABOUTME: Engine registry and discovery system for scripting engines
// ABOUTME: Manages available engines and provides factory methods

const std = @import("std");
const ScriptingEngine = @import("interface.zig").ScriptingEngine;
const EngineConfig = @import("interface.zig").EngineConfig;
const LuaEngine = @import("engines/lua_engine.zig").LuaEngine;

/// Engine factory function signature
pub const EngineFactory = *const fn (allocator: std.mem.Allocator, config: EngineConfig) anyerror!*ScriptingEngine;

/// Engine registration info
pub const EngineInfo = struct {
    /// Engine name (e.g., "lua", "quickjs", "wren", "python")
    name: []const u8,

    /// Display name (e.g., "Lua 5.4", "QuickJS ES2020")
    display_name: []const u8,

    /// Engine version
    version: []const u8,

    /// Supported file extensions
    extensions: []const []const u8,

    /// Factory function to create engine instance
    factory: EngineFactory,

    /// Engine features
    features: ScriptingEngine.EngineFeatures,

    /// Description
    description: []const u8,
};

/// Global engine registry
pub const EngineRegistry = struct {
    const Self = @This();

    /// Registered engines
    engines: std.StringHashMap(EngineInfo),

    /// Default engine name
    default_engine: ?[]const u8,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Mutex for thread safety
    mutex: std.Thread.Mutex,

    /// Singleton instance
    var instance: ?*Self = null;
    var instance_mutex = std.Thread.Mutex{};

    /// Get or create singleton instance
    pub fn getInstance(allocator: std.mem.Allocator) !*Self {
        instance_mutex.lock();
        defer instance_mutex.unlock();

        if (instance) |inst| {
            return inst;
        }

        const self = try allocator.create(Self);
        self.* = Self{
            .engines = std.StringHashMap(EngineInfo).init(allocator),
            .default_engine = null,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };

        instance = self;
        return self;
    }

    /// Deinitialize the registry
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.engines.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.engines.deinit();

        if (self.default_engine) |engine| {
            self.allocator.free(engine);
        }

        instance_mutex.lock();
        defer instance_mutex.unlock();

        if (instance == self) {
            instance = null;
        }

        self.allocator.destroy(self);
    }

    /// Register an engine
    pub fn registerEngine(self: *Self, info: EngineInfo) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_name = try self.allocator.dupe(u8, info.name);
        try self.engines.put(owned_name, info);

        // Set as default if it's the first engine
        if (self.default_engine == null) {
            self.default_engine = try self.allocator.dupe(u8, info.name);
        }
    }

    /// Unregister an engine
    pub fn unregisterEngine(self: *Self, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.engines.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);

            // Clear default if it was this engine
            if (self.default_engine) |default| {
                if (std.mem.eql(u8, default, name)) {
                    self.allocator.free(default);
                    self.default_engine = null;

                    // Set new default to first available engine
                    var iter = self.engines.iterator();
                    if (iter.next()) |entry| {
                        self.default_engine = self.allocator.dupe(u8, entry.key_ptr.*) catch null;
                    }
                }
            }

            return true;
        }

        return false;
    }

    /// Get engine info by name
    pub fn getEngine(self: *Self, name: []const u8) ?EngineInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.engines.get(name);
    }

    /// Get engine by file extension
    pub fn getEngineByExtension(self: *Self, extension: []const u8) ?EngineInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.engines.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.extensions) |ext| {
                if (std.mem.eql(u8, ext, extension)) {
                    return entry.value_ptr.*;
                }
            }
        }

        return null;
    }

    /// Create engine instance
    pub fn createEngine(self: *Self, name: []const u8, config: EngineConfig) !*ScriptingEngine {
        const info = self.getEngine(name) orelse return error.EngineNotFound;
        return try info.factory(self.allocator, config);
    }

    /// Create default engine instance
    pub fn createDefaultEngine(self: *Self, config: EngineConfig) !*ScriptingEngine {
        self.mutex.lock();
        const default = self.default_engine orelse {
            self.mutex.unlock();
            return error.NoDefaultEngine;
        };
        self.mutex.unlock();

        return try self.createEngine(default, config);
    }

    /// Set default engine
    pub fn setDefaultEngine(self: *Self, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.engines.contains(name)) {
            return error.EngineNotFound;
        }

        if (self.default_engine) |old| {
            self.allocator.free(old);
        }

        self.default_engine = try self.allocator.dupe(u8, name);
    }

    /// Get list of registered engines
    pub fn listEngines(self: *Self, allocator: std.mem.Allocator) ![]EngineInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = try allocator.alloc(EngineInfo, self.engines.count());
        var iter = self.engines.iterator();
        var i: usize = 0;

        while (iter.next()) |entry| {
            list[i] = entry.value_ptr.*;
            i += 1;
        }

        return list;
    }

    /// Check if engine is registered
    pub fn hasEngine(self: *Self, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.engines.contains(name);
    }

    /// Get engine count
    pub fn getEngineCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.engines.count();
    }
};

/// Auto-discovery of engines
pub fn autoDiscoverEngines(allocator: std.mem.Allocator) !void {
    const registry = try EngineRegistry.getInstance(allocator);

    // Register Lua engine if available
    const lua = @import("../bindings/lua/lua.zig");
    if (lua.lua_enabled) {
        const lua_info = EngineInfo{
            .name = "lua",
            .display_name = "Lua 5.4",
            .version = "5.4.6",
            .extensions = &[_][]const u8{".lua"},
            .factory = LuaEngine.create,
            .features = .{
                .async_support = true,
                .debugging = true,
                .sandboxing = true,
                .hot_reload = false,
                .native_json = false,
                .native_regex = false,
            },
            .description = "Lua 5.4 scripting engine with coroutine support",
        };

        try registry.registerEngine(lua_info);
    }
}

// Tests
test "EngineRegistry singleton" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const registry1 = try EngineRegistry.getInstance(allocator);
    const registry2 = try EngineRegistry.getInstance(allocator);

    try testing.expectEqual(registry1, registry2);

    registry1.deinit();
}

test "EngineRegistry operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const registry = try EngineRegistry.getInstance(allocator);
    defer registry.deinit();

    // Mock engine factory
    const mockFactory = struct {
        fn create(alloc: std.mem.Allocator, config: EngineConfig) anyerror!*ScriptingEngine {
            _ = alloc;
            _ = config;
            return error.NotImplemented;
        }
    }.create;

    // Register test engine
    const test_engine = EngineInfo{
        .name = "test_engine",
        .display_name = "Test Engine 1.0",
        .version = "1.0.0",
        .extensions = &[_][]const u8{ ".test", ".tst" },
        .factory = mockFactory,
        .features = .{
            .async_support = true,
            .debugging = true,
        },
        .description = "Test engine for unit tests",
    };

    try registry.registerEngine(test_engine);

    // Test retrieval
    try testing.expect(registry.hasEngine("test_engine"));

    const retrieved = registry.getEngine("test_engine");
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("test_engine", retrieved.?.name);
    try testing.expectEqualStrings("1.0.0", retrieved.?.version);

    // Test by extension
    const by_ext = registry.getEngineByExtension(".test");
    try testing.expect(by_ext != null);
    try testing.expectEqualStrings("test_engine", by_ext.?.name);

    // Test default engine
    try testing.expectEqualStrings("test_engine", registry.default_engine.?);

    // Test listing
    const list = try registry.listEngines(allocator);
    defer allocator.free(list);
    try testing.expectEqual(@as(usize, 1), list.len);

    // Test unregister
    try testing.expect(registry.unregisterEngine("test_engine"));
    try testing.expect(!registry.hasEngine("test_engine"));
    try testing.expect(registry.default_engine == null);
}
