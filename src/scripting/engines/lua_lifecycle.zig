// ABOUTME: Advanced lua_State lifecycle management with pooling and isolation
// ABOUTME: Provides state pooling, cleanup, snapshots, and thread-safe operations

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const ScriptContext = @import("../context.zig").ScriptContext;
const EngineConfig = @import("../interface.zig").EngineConfig;

/// Lua state lifecycle errors
pub const LifecycleError = error{
    StateCreationFailed,
    StateResetFailed,
    PoolExhausted,
    InvalidState,
    SnapshotFailed,
    RestoreFailed,
} || std.mem.Allocator.Error;

/// State lifecycle stage
pub const LifecycleStage = enum {
    uninitialized,
    created,
    configured,
    active,
    suspended,
    cleanup,
    destroyed,
};

/// State usage statistics
pub const StateStats = struct {
    creation_time: i64,
    last_used: i64,
    execution_count: u64,
    error_count: u32,
    gc_collections: u32,
    memory_peak: usize,
    reset_count: u32,

    pub fn init() StateStats {
        const now = std.time.milliTimestamp();
        return StateStats{
            .creation_time = now,
            .last_used = now,
            .execution_count = 0,
            .error_count = 0,
            .gc_collections = 0,
            .memory_peak = 0,
            .reset_count = 0,
        };
    }

    pub fn recordUsage(self: *StateStats) void {
        self.last_used = std.time.milliTimestamp();
        self.execution_count += 1;
    }

    pub fn recordError(self: *StateStats) void {
        self.error_count += 1;
    }

    pub fn recordReset(self: *StateStats) void {
        self.reset_count += 1;
    }

    pub fn getAge(self: *const StateStats) i64 {
        return std.time.milliTimestamp() - self.creation_time;
    }

    pub fn getIdleTime(self: *const StateStats) i64 {
        return std.time.milliTimestamp() - self.last_used;
    }
};

/// State snapshot for rollback capability
pub const StateSnapshot = struct {
    stack_size: c_int,
    global_backup: ?[]u8,
    gc_count: c_int,
    timestamp: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, state: lua.LuaState) !StateSnapshot {
        if (!lua.lua_enabled) {
            return StateSnapshot{
                .stack_size = 0,
                .global_backup = null,
                .gc_count = 0,
                .timestamp = std.time.milliTimestamp(),
                .allocator = allocator,
            };
        }

        const stack_size = lua.c.lua_gettop(state);
        const gc_count = lua.c.lua_gc(state, lua.c.LUA_GCCOUNT, 0);

        // TODO: Implement global environment serialization
        const global_backup: ?[]u8 = null;

        return StateSnapshot{
            .stack_size = stack_size,
            .global_backup = global_backup,
            .gc_count = gc_count,
            .timestamp = std.time.milliTimestamp(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StateSnapshot) void {
        if (self.global_backup) |backup| {
            self.allocator.free(backup);
        }
    }

    pub fn restore(self: *const StateSnapshot, state: lua.LuaState) !void {
        if (!lua.lua_enabled) return;

        // Restore stack size
        lua.c.lua_settop(state, self.stack_size);

        // TODO: Restore global environment from backup
        // For now, we just restore the stack size and force GC

        // Force GC to match snapshot state
        _ = lua.c.lua_gc(state, lua.c.LUA_GCCOLLECT, 0);
    }
};

/// Enhanced lua_State wrapper with lifecycle management
pub const ManagedLuaState = struct {
    const Self = @This();

    state: lua.LuaState,
    wrapper: *lua.LuaWrapper,
    allocator: std.mem.Allocator,
    stage: LifecycleStage,
    stats: StateStats,
    config: EngineConfig,
    isolation_level: IsolationLevel,
    snapshots: std.ArrayList(StateSnapshot),
    mutex: std.Thread.Mutex,

    pub const IsolationLevel = enum {
        none,       // No isolation
        basic,      // Basic environment restrictions
        strict,     // Full sandboxing
    };

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        if (!lua.lua_enabled) {
            return LifecycleError.StateCreationFailed;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const wrapper = try lua.LuaWrapper.init(allocator);
        errdefer wrapper.deinit();

        self.* = Self{
            .state = wrapper.state,
            .wrapper = wrapper,
            .allocator = allocator,
            .stage = .created,
            .stats = StateStats.init(),
            .config = config,
            .isolation_level = switch (config.sandbox_level) {
                .none => .none,
                .restricted => .basic,
                .strict => .strict,
            },
            .snapshots = std.ArrayList(StateSnapshot).init(allocator),
            .mutex = std.Thread.Mutex{},
        };

        try self.configure();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.stage = .cleanup;
        
        // Clean up snapshots
        for (self.snapshots.items) |*snapshot| {
            snapshot.deinit();
        }
        self.snapshots.deinit();

        self.wrapper.deinit();
        self.stage = .destroyed;
        self.allocator.destroy(self);
    }

    fn configure(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!lua.lua_enabled) return;

        self.stage = .configured;

        // Configure memory limits
        if (self.config.max_memory_bytes > 0) {
            // TODO: Set up custom allocator with memory limits
        }

        // Configure isolation level
        switch (self.isolation_level) {
            .none => {
                // No restrictions
            },
            .basic => {
                try self.setupBasicSandbox();
            },
            .strict => {
                try self.setupStrictSandbox();
            },
        }

        // Configure garbage collection
        self.configureGC();
        
        self.stage = .active;
    }

    fn setupBasicSandbox(self: *Self) !void {
        if (!lua.lua_enabled) return;

        // Remove dangerous functions
        const dangerous_globals = [_][]const u8{
            "dofile", "loadfile", "require", "io", "os", "debug",
            "package", "getfenv", "setfenv", "load", "loadstring",
        };

        for (dangerous_globals) |global| {
            try self.wrapper.pushString(global);
            self.wrapper.pushNil();
            self.wrapper.setTable(lua.c.LUA_GLOBALSINDEX);
        }
    }

    fn setupStrictSandbox(self: *Self) !void {
        if (!lua.lua_enabled) return;

        try self.setupBasicSandbox();

        // Create restricted environment
        self.wrapper.createTable(0, 10);

        // Add only safe functions
        const safe_globals = [_][]const u8{
            "print", "tostring", "tonumber", "type", "next", "pairs", "ipairs",
            "math", "string", "table",
        };

        for (safe_globals) |global| {
            try self.wrapper.getGlobal(global);
            try self.wrapper.setField(-2, global);
        }

        // Set as global environment
        try self.wrapper.setGlobal("_ENV");
    }

    fn configureGC(self: *Self) void {
        if (!lua.lua_enabled) return;

        // Configure generational GC (Lua 5.4 feature)
        _ = lua.c.lua_gc(self.state, lua.c.LUA_GCGEN, 0, 0);

        // Set GC parameters based on config
        if (self.config.max_memory_bytes > 0) {
            const kb_limit = @as(c_int, @intCast(self.config.max_memory_bytes / 1024));
            _ = lua.c.lua_gc(self.state, lua.c.LUA_GCKEYWORD, kb_limit);
        }
    }

    pub fn reset(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!lua.lua_enabled) return LifecycleError.StateResetFailed;

        self.stage = .cleanup;

        // Clear stack
        lua.c.lua_settop(self.state, 0);

        // Reset global environment
        try self.resetGlobals();

        // Force garbage collection
        _ = lua.c.lua_gc(self.state, lua.c.LUA_GCCOLLECT, 0);

        // Reconfigure isolation
        try self.configure();

        self.stats.recordReset();
        self.stage = .active;
    }

    fn resetGlobals(self: *Self) !void {
        if (!lua.lua_enabled) return;

        // Get clean global table
        self.wrapper.createTable(0, 0);
        
        // Restore standard libraries
        lua.c.luaL_openlibs(self.state);
        
        // Reapply sandbox restrictions
        switch (self.isolation_level) {
            .none => {},
            .basic => try self.setupBasicSandbox(),
            .strict => try self.setupStrictSandbox(),
        }
    }

    pub fn createSnapshot(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const snapshot = try StateSnapshot.init(self.allocator, self.state);
        try self.snapshots.append(snapshot);
    }

    pub fn restoreSnapshot(self: *Self, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.snapshots.items.len) {
            return LifecycleError.InvalidState;
        }

        const snapshot = &self.snapshots.items[index];
        try snapshot.restore(self.state);
    }

    pub fn removeSnapshot(self: *Self, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (index >= self.snapshots.items.len) {
            return LifecycleError.InvalidState;
        }

        var snapshot = self.snapshots.swapRemove(index);
        snapshot.deinit();
    }

    pub fn execute(self: *Self, code: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stage != .active) {
            return LifecycleError.InvalidState;
        }

        self.wrapper.doString(code) catch |err| {
            self.stats.recordError();
            return err;
        };

        self.stats.recordUsage();
    }

    pub fn suspendState(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.stage == .active) {
            self.stage = .suspended;
        }
    }

    pub fn resumeState(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.stage == .suspended) {
            self.stage = .active;
        }
    }

    pub fn getStats(self: *Self) StateStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    pub fn getMemoryUsage(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!lua.lua_enabled) return 0;
        
        const count_kb = lua.c.lua_gc(self.state, lua.c.LUA_GCCOUNT, 0);
        const count_b = lua.c.lua_gc(self.state, lua.c.LUA_GCCOUNTB, 0);
        return @as(usize, @intCast(count_kb)) * 1024 + @as(usize, @intCast(count_b));
    }

    pub fn collectGarbage(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (!lua.lua_enabled) return;
        
        _ = lua.c.lua_gc(self.state, lua.c.LUA_GCCOLLECT, 0);
        self.stats.gc_collections += 1;
    }

    pub fn isHealthy(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.stage == .active and 
               self.stats.error_count < 100 and // Arbitrary threshold
               self.getMemoryUsage() < (self.config.max_memory_bytes * 2); // 200% of limit
    }
};

/// lua_State pool for performance optimization
pub const LuaStatePool = struct {
    const Self = @This();

    available_states: std.ArrayList(*ManagedLuaState),
    in_use_states: std.AutoHashMap(*ManagedLuaState, bool),
    allocator: std.mem.Allocator,
    config: EngineConfig,
    max_pool_size: usize,
    max_idle_time: i64, // milliseconds
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig, max_pool_size: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .available_states = std.ArrayList(*ManagedLuaState).init(allocator),
            .in_use_states = std.AutoHashMap(*ManagedLuaState, bool).init(allocator),
            .allocator = allocator,
            .config = config,
            .max_pool_size = max_pool_size,
            .max_idle_time = 5 * 60 * 1000, // 5 minutes
            .mutex = std.Thread.Mutex{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up available states
        for (self.available_states.items) |state| {
            state.deinit();
        }
        self.available_states.deinit();

        // Clean up in-use states
        var iterator = self.in_use_states.iterator();
        while (iterator.next()) |entry| {
            entry.key_ptr.*.deinit();
        }
        self.in_use_states.deinit();

        self.allocator.destroy(self);
    }

    pub fn acquire(self: *Self) !*ManagedLuaState {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try to reuse available state
        while (self.available_states.items.len > 0) {
            const state = self.available_states.pop();
            
            // Check if state is still healthy
            if (state.isHealthy()) {
                try state.reset();
                try self.in_use_states.put(state, true);
                return state;
            } else {
                // State is unhealthy, destroy it
                state.deinit();
            }
        }

        // Create new state if pool not at capacity
        if (self.getTotalStates() < self.max_pool_size) {
            const state = try ManagedLuaState.init(self.allocator, self.config);
            try self.in_use_states.put(state, true);
            return state;
        }

        return LifecycleError.PoolExhausted;
    }

    pub fn release(self: *Self, state: *ManagedLuaState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.in_use_states.remove(state);
        
        // Check if we should keep this state in the pool
        if (state.isHealthy() and self.available_states.items.len < self.max_pool_size) {
            state.suspendState();
            self.available_states.append(state) catch {
                // Pool full, destroy state
                state.deinit();
            };
        } else {
            state.deinit();
        }
    }

    pub fn cleanup(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove idle states
        var i: usize = 0;
        while (i < self.available_states.items.len) {
            const state = self.available_states.items[i];
            const stats = state.getStats();
            
            if (stats.getIdleTime() > self.max_idle_time) {
                _ = self.available_states.swapRemove(i);
                state.deinit();
            } else {
                i += 1;
            }
        }
    }

    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return PoolStats{
            .available_count = self.available_states.items.len,
            .in_use_count = self.in_use_states.count(),
            .max_pool_size = self.max_pool_size,
        };
    }

    fn getTotalStates(self: *Self) usize {
        return self.available_states.items.len + self.in_use_states.count();
    }

    pub const PoolStats = struct {
        available_count: usize,
        in_use_count: usize,
        max_pool_size: usize,
    };
};

// Tests
test "ManagedLuaState lifecycle" {
    if (!lua.lua_enabled) return;
    
    const allocator = std.testing.allocator;
    const config = EngineConfig{};
    
    const state = try ManagedLuaState.init(allocator, config);
    defer state.deinit();
    
    try std.testing.expect(state.stage == .active);
    
    // Test execution
    try state.execute("x = 42");
    
    const stats = state.getStats();
    try std.testing.expect(stats.execution_count == 1);
    
    // Test reset
    try state.reset();
    try std.testing.expect(state.stage == .active);
}

test "LuaStatePool operations" {
    if (!lua.lua_enabled) return;
    
    const allocator = std.testing.allocator;
    const config = EngineConfig{};
    
    const pool = try LuaStatePool.init(allocator, config, 2);
    defer pool.deinit();
    
    // Acquire state
    const state1 = try pool.acquire();
    const state2 = try pool.acquire();
    
    // Pool should be at capacity
    try std.testing.expectError(LifecycleError.PoolExhausted, pool.acquire());
    
    // Release and reacquire
    pool.release(state1);
    const state3 = try pool.acquire();
    
    pool.release(state2);
    pool.release(state3);
    
    const stats = pool.getStats();
    try std.testing.expect(stats.available_count <= 2);
}