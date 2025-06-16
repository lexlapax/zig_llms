// ABOUTME: Advanced lua_State lifecycle management with pooling and isolation
// ABOUTME: Provides state pooling, cleanup, snapshots, and thread-safe operations

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const ScriptContext = @import("../context.zig").ScriptContext;
const EngineConfig = @import("../interface.zig").EngineConfig;
const snapshot_mod = @import("lua_snapshot.zig");
const SnapshotManager = snapshot_mod.SnapshotManager;
const SnapshotSerializer = snapshot_mod.SnapshotSerializer;
const SnapshotDeserializer = snapshot_mod.SnapshotDeserializer;

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
    snapshot_manager: ?*SnapshotManager,

    pub const IsolationLevel = enum {
        none, // No isolation
        basic, // Basic environment restrictions
        strict, // Full sandboxing
    };

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        if (!lua.lua_enabled) {
            return LifecycleError.StateCreationFailed;
        }

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Create wrapper with custom allocator if memory limit is set
        const wrapper = if (config.max_memory_bytes > 0)
            try lua.LuaWrapper.initWithCustomAllocator(
                allocator,
                config.max_memory_bytes,
                config.enable_debugging,
            )
        else
            try lua.LuaWrapper.init(allocator);
        errdefer wrapper.deinit();

        // Create snapshot manager if snapshots are enabled
        const snapshot_manager = if (config.enable_snapshots)
            try SnapshotManager.init(
                allocator,
                config.max_snapshots,
                config.max_snapshot_size_bytes,
            )
        else
            null;
        errdefer if (snapshot_manager) |sm| sm.deinit();

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
            .snapshot_manager = snapshot_manager,
        };

        try self.configure();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.stage = .cleanup;

        // Clean up old snapshot system
        for (self.snapshots.items) |*snapshot| {
            snapshot.deinit();
        }
        self.snapshots.deinit();

        // Clean up new snapshot manager
        if (self.snapshot_manager) |sm| {
            sm.deinit();
        }

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
            "dofile",  "loadfile", "require", "io",   "os",         "debug",
            "package", "getfenv",  "setfenv", "load", "loadstring",
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
            "math",  "string",   "table",
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
            // Set garbage collection threshold based on memory limit
            // The GC will run more aggressively as we approach the memory limit
            const kb_limit = @as(c_int, @intCast(self.config.max_memory_bytes / 1024));
            _ = lua.c.lua_gc(self.state, lua.c.LUA_GCSETPAUSE, @divFloor(kb_limit, 10));
            _ = lua.c.lua_gc(self.state, lua.c.LUA_GCSETSTEPMUL, 200);
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

        if (self.snapshot_manager) |sm| {
            // Use new comprehensive snapshot system
            var serializer = SnapshotSerializer.init(self.wrapper, self.allocator, .{});
            defer serializer.deinit();

            const snapshot_id = try std.fmt.allocPrint(self.allocator, "snapshot_{d}", .{std.time.milliTimestamp()});
            defer self.allocator.free(snapshot_id);

            const snapshot = try serializer.createSnapshot(snapshot_id, "State snapshot");
            try sm.addSnapshot(snapshot);
        } else {
            // Fall back to old simple snapshot system
            const snapshot = try StateSnapshot.init(self.allocator, self.state);
            try self.snapshots.append(snapshot);
        }
    }

    pub fn restoreSnapshot(self: *Self, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.snapshot_manager) |sm| {
            // Get snapshot by index from list
            const snapshots = try sm.listSnapshots(self.allocator);
            defer {
                for (snapshots) |*s| s.deinit(self.allocator);
                self.allocator.free(snapshots);
            }

            if (index >= snapshots.len) {
                return LifecycleError.InvalidState;
            }

            const snapshot = sm.getSnapshot(snapshots[index].id) orelse return LifecycleError.InvalidState;

            // Use deserializer to restore
            var deserializer = SnapshotDeserializer.init(self.wrapper, self.allocator);
            defer deserializer.deinit();

            try deserializer.restoreSnapshot(snapshot);
        } else {
            // Fall back to old simple restore
            if (index >= self.snapshots.items.len) {
                return LifecycleError.InvalidState;
            }

            const snapshot = &self.snapshots.items[index];
            try snapshot.restore(self.state);
        }
    }

    pub fn removeSnapshot(self: *Self, index: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.snapshot_manager) |sm| {
            // Get snapshot by index from list
            const snapshots = try sm.listSnapshots(self.allocator);
            defer {
                for (snapshots) |*s| s.deinit(self.allocator);
                self.allocator.free(snapshots);
            }

            if (index >= snapshots.len) {
                return LifecycleError.InvalidState;
            }

            try sm.removeSnapshot(snapshots[index].id);
        } else {
            // Fall back to old simple remove
            if (index >= self.snapshots.items.len) {
                return LifecycleError.InvalidState;
            }

            var snapshot = self.snapshots.swapRemove(index);
            snapshot.deinit();
        }
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

        // If using custom allocator, get precise stats
        if (self.wrapper.getAllocationStats()) |stats| {
            return stats.total_allocated;
        }

        // Fallback to Lua GC stats
        const count_kb = lua.c.lua_gc(self.state, lua.c.LUA_GCCOUNT, @as(c_int, 0));
        const count_b = lua.c.lua_gc(self.state, lua.c.LUA_GCCOUNTB, @as(c_int, 0));
        return @as(usize, @intCast(count_kb)) * 1024 + @as(usize, @intCast(count_b));
    }

    pub fn getAllocationStats(self: *Self) ?@import("lua_allocator.zig").AllocationStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.wrapper.getAllocationStats();
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

    pub fn createSnapshotWithId(self: *Self, id: []const u8, description: ?[]const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sm = self.snapshot_manager orelse return LifecycleError.SnapshotFailed;

        var serializer = SnapshotSerializer.init(self.wrapper, self.allocator, .{});
        defer serializer.deinit();

        const snapshot = try serializer.createSnapshot(id, description);
        try sm.addSnapshot(snapshot);
    }

    pub fn restoreSnapshotById(self: *Self, id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sm = self.snapshot_manager orelse return LifecycleError.RestoreFailed;
        const snapshot = sm.getSnapshot(id) orelse return LifecycleError.SnapshotFailed;

        var deserializer = SnapshotDeserializer.init(self.wrapper, self.allocator);
        defer deserializer.deinit();

        try deserializer.restoreSnapshot(snapshot);

        // Update stats
        self.stats.recordReset();
        self.stage = .active;
    }

    pub fn listSnapshots(self: *Self) ![]snapshot_mod.SnapshotMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sm = self.snapshot_manager orelse {
            // Return empty list if no snapshot manager
            return self.allocator.alloc(snapshot_mod.SnapshotMetadata, 0);
        };

        return try sm.listSnapshots(self.allocator);
    }

    pub fn getSnapshotCount(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.snapshot_manager) |sm| {
            return sm.snapshots.count();
        }
        return self.snapshots.items.len;
    }
};

/// lua_State pool for performance optimization
pub const LuaStatePool = struct {
    const Self = @This();

    available_states: std.ArrayList(*ManagedLuaState),
    in_use_states: std.AutoHashMap(*ManagedLuaState, StateMetadata),
    allocator: std.mem.Allocator,
    config: EngineConfig,
    pool_config: PoolConfig,
    mutex: std.Thread.Mutex,
    total_created: u32,
    total_recycled: u32,
    generation: u32,

    pub const PoolConfig = struct {
        min_pool_size: usize = 2,
        max_pool_size: usize = 8,
        max_idle_time_ms: i64 = 5 * 60 * 1000, // 5 minutes
        max_state_age_ms: i64 = 30 * 60 * 1000, // 30 minutes
        max_state_uses: u32 = 1000,
        enable_warmup: bool = true,
        validate_on_acquire: bool = true,
    };

    const StateMetadata = struct {
        created_at: i64,
        last_used: i64,
        use_count: u32,
        generation: u32,
    };

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig, max_pool_size: usize) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .available_states = std.ArrayList(*ManagedLuaState).init(allocator),
            .in_use_states = std.AutoHashMap(*ManagedLuaState, StateMetadata).init(allocator),
            .allocator = allocator,
            .config = config,
            .pool_config = PoolConfig{
                .max_pool_size = max_pool_size,
            },
            .mutex = std.Thread.Mutex{},
            .total_created = 0,
            .total_recycled = 0,
            .generation = 0,
        };

        // Warmup pool with minimum states if enabled
        if (self.pool_config.enable_warmup) {
            try self.warmupPool();
        }

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
            const metadata = self.getStateMetadata(state);

            // Check if state should be recycled based on age and use count
            if (self.shouldRecycleState(state, metadata)) {
                state.deinit();
                self.total_recycled += 1;
                continue;
            }

            // Validate state if enabled
            if (self.pool_config.validate_on_acquire and !self.validateState(state)) {
                state.deinit();
                self.total_recycled += 1;
                continue;
            }

            // State is good, prepare for use
            try state.reset();

            // Update metadata
            try self.in_use_states.put(state, StateMetadata{
                .created_at = metadata.created_at,
                .last_used = std.time.milliTimestamp(),
                .use_count = metadata.use_count + 1,
                .generation = metadata.generation,
            });

            return state;
        }

        // Create new state if pool not at capacity
        if (self.getTotalStates() < self.pool_config.max_pool_size) {
            const state = try ManagedLuaState.init(self.allocator, self.config);
            self.generation += 1;
            self.total_created += 1;

            try self.in_use_states.put(state, StateMetadata{
                .created_at = std.time.milliTimestamp(),
                .last_used = std.time.milliTimestamp(),
                .use_count = 1,
                .generation = self.generation,
            });

            return state;
        }

        return LifecycleError.PoolExhausted;
    }

    pub fn release(self: *Self, state: *ManagedLuaState) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const metadata = self.in_use_states.get(state);
        _ = self.in_use_states.remove(state);

        // Check if we should keep this state in the pool
        if (state.isHealthy() and
            self.available_states.items.len < self.pool_config.max_pool_size and
            (metadata == null or !self.shouldRecycleState(state, metadata.?)))
        {
            state.suspendState();
            self.available_states.append(state) catch {
                // Pool full, destroy state
                state.deinit();
                self.total_recycled += 1;
            };
        } else {
            state.deinit();
            self.total_recycled += 1;
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
            const metadata = self.getStateMetadata(state);

            const should_remove = stats.getIdleTime() > self.pool_config.max_idle_time_ms or
                (metadata != null and self.shouldRecycleState(state, metadata.?)) or
                self.available_states.items.len > self.pool_config.min_pool_size;

            if (should_remove) {
                _ = self.available_states.swapRemove(i);
                state.deinit();
                self.total_recycled += 1;
            } else {
                i += 1;
            }
        }

        // Ensure minimum pool size
        self.ensureMinimumStates() catch {};
    }

    pub fn getStats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var total_uses: u64 = 0;
        var total_age: i64 = 0;
        const now = std.time.milliTimestamp();
        var count: usize = 0;

        // Calculate averages from in-use states
        var iter = self.in_use_states.iterator();
        while (iter.next()) |entry| {
            total_uses += entry.value_ptr.use_count;
            total_age += now - entry.value_ptr.created_at;
            count += 1;
        }

        return PoolStats{
            .available_count = self.available_states.items.len,
            .in_use_count = self.in_use_states.count(),
            .total_count = self.getTotalStates(),
            .min_pool_size = self.pool_config.min_pool_size,
            .max_pool_size = self.pool_config.max_pool_size,
            .total_created = self.total_created,
            .total_recycled = self.total_recycled,
            .average_uses = if (count > 0) @as(f64, @floatFromInt(total_uses)) / @as(f64, @floatFromInt(count)) else 0,
            .average_age_ms = if (count > 0) @as(f64, @floatFromInt(total_age)) / @as(f64, @floatFromInt(count)) else 0,
        };
    }

    fn getTotalStates(self: *Self) usize {
        return self.available_states.items.len + self.in_use_states.count();
    }

    fn shouldRecycleState(self: *Self, state: *ManagedLuaState, metadata: StateMetadata) bool {
        _ = state;
        const now = std.time.milliTimestamp();

        // Check age
        if (self.pool_config.max_state_age_ms > 0 and
            (now - metadata.created_at) > self.pool_config.max_state_age_ms)
        {
            return true;
        }

        // Check use count
        if (self.pool_config.max_state_uses > 0 and
            metadata.use_count >= self.pool_config.max_state_uses)
        {
            return true;
        }

        return false;
    }

    fn validateState(self: *Self, state: *ManagedLuaState) bool {
        _ = self;
        if (!lua.lua_enabled) return false;

        // Perform a simple operation to verify state integrity
        const wrapper = state.wrapper;
        const initial_top = wrapper.getTop();
        wrapper.pushNil();
        const success = wrapper.getTop() == initial_top + 1;
        wrapper.pop(1);

        return success and state.isHealthy();
    }

    fn getStateMetadata(self: *Self, state: *ManagedLuaState) ?StateMetadata {
        // First check in-use states
        if (self.in_use_states.get(state)) |metadata| {
            return metadata;
        }

        // For available states, we don't track metadata currently
        // Could enhance this by maintaining a separate metadata map
        return null;
    }

    fn warmupPool(self: *Self) !void {
        while (self.available_states.items.len < self.pool_config.min_pool_size) {
            const state = try ManagedLuaState.init(self.allocator, self.config);
            self.generation += 1;
            self.total_created += 1;

            state.suspendState();
            try self.available_states.append(state);
        }
    }

    fn ensureMinimumStates(self: *Self) !void {
        while (self.getTotalStates() < self.pool_config.min_pool_size) {
            const state = try ManagedLuaState.init(self.allocator, self.config);
            self.generation += 1;
            self.total_created += 1;

            state.suspendState();
            try self.available_states.append(state);
        }
    }

    pub const PoolStats = struct {
        available_count: usize,
        in_use_count: usize,
        total_count: usize,
        min_pool_size: usize,
        max_pool_size: usize,
        total_created: u32,
        total_recycled: u32,
        average_uses: f64,
        average_age_ms: f64,
    };
};

/// Scoped state handle for automatic release
pub const ScopedLuaState = struct {
    pool: *LuaStatePool,
    state: *ManagedLuaState,

    pub fn init(pool: *LuaStatePool) !ScopedLuaState {
        return ScopedLuaState{
            .pool = pool,
            .state = try pool.acquire(),
        };
    }

    pub fn deinit(self: *ScopedLuaState) void {
        self.pool.release(self.state);
    }

    pub fn getState(self: *ScopedLuaState) *ManagedLuaState {
        return self.state;
    }

    pub fn getWrapper(self: *ScopedLuaState) *lua.LuaWrapper {
        return self.state.wrapper;
    }
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

test "LuaStatePool enhanced features" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const pool = try LuaStatePool.init(allocator, config, 5);
    defer pool.deinit();

    // Test initial pool warmup
    const initial_stats = pool.getStats();
    try std.testing.expect(initial_stats.available_count >= pool.pool_config.min_pool_size);

    // Test state acquisition and reuse
    const state1 = try pool.acquire();
    const state2 = try pool.acquire();

    try std.testing.expect(pool.getStats().in_use_count == 2);

    pool.release(state1);
    pool.release(state2);

    try std.testing.expect(pool.getStats().available_count >= 2);

    // Test that we get reused states
    const state3 = try pool.acquire();
    pool.release(state3);

    const stats = pool.getStats();
    try std.testing.expect(stats.total_created < 5); // Should reuse, not create new
}

test "ScopedLuaState" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    const pool = try LuaStatePool.init(allocator, config, 3);
    defer pool.deinit();

    {
        var scoped = try ScopedLuaState.init(pool);
        defer scoped.deinit();

        const wrapper = scoped.getWrapper();
        try wrapper.doString("test_var = 123");

        try std.testing.expect(pool.getStats().in_use_count == 1);
    }

    // State should be automatically released
    try std.testing.expect(pool.getStats().in_use_count == 0);
    try std.testing.expect(pool.getStats().available_count > 0);
}

test "Pool recycling policies" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const config = EngineConfig{};

    // Create pool with strict recycling policies
    const pool = try LuaStatePool.init(allocator, config, 5);
    defer pool.deinit();

    // Manually set aggressive recycling for testing
    pool.pool_config.max_state_uses = 2;
    pool.pool_config.max_state_age_ms = 100;

    const state = try pool.acquire();
    pool.release(state);

    // Use the state again
    const state2 = try pool.acquire();
    pool.release(state2);

    // Third acquire should get a new state due to max_uses policy
    const state3 = try pool.acquire();
    pool.release(state3);

    const stats = pool.getStats();
    try std.testing.expect(stats.total_recycled > 0);

    // Test age-based recycling
    std.time.sleep(150 * std.time.ns_per_ms); // Sleep 150ms
    pool.cleanup();

    const cleanup_stats = pool.getStats();
    try std.testing.expect(cleanup_stats.total_count >= pool.pool_config.min_pool_size);
}
