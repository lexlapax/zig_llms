// ABOUTME: Script execution context management with security and isolation
// ABOUTME: Provides context isolation, resource limits, and module management

const std = @import("std");
const ScriptValue = @import("value_bridge.zig").ScriptValue;
const ScriptError = @import("error_bridge.zig").ScriptError;
const ScriptModule = @import("interface.zig").ScriptModule;
const ScriptFunction = @import("interface.zig").ScriptFunction;

/// Security permissions for script contexts
pub const SecurityPermissions = struct {
    /// Can read files
    file_read: bool = false,
    /// Can write files
    file_write: bool = false,
    /// Can execute processes
    process_execute: bool = false,
    /// Can make network requests
    network_access: bool = false,
    /// Can access environment variables
    env_access: bool = false,
    /// Can load native modules
    native_modules: bool = false,
    /// Allowed module imports (null = all allowed)
    allowed_modules: ?[]const []const u8 = null,
    /// Maximum call stack depth
    max_stack_depth: u32 = 1000,
};

/// Resource limits for script execution
pub const ResourceLimits = struct {
    /// Maximum memory in bytes (0 = unlimited)
    max_memory_bytes: usize = 0,
    /// Maximum execution time in milliseconds (0 = unlimited)
    max_execution_time_ms: u32 = 0,
    /// Maximum number of allocations
    max_allocations: usize = 100000,
    /// Maximum output size in bytes
    max_output_size: usize = 10 * 1024 * 1024, // 10MB
};

/// Execution statistics
pub const ExecutionStats = struct {
    /// Total execution time in milliseconds
    execution_time_ms: u64 = 0,
    /// Memory currently allocated
    memory_allocated: usize = 0,
    /// Peak memory usage
    peak_memory: usize = 0,
    /// Number of allocations
    allocation_count: usize = 0,
    /// Number of garbage collections
    gc_count: u32 = 0,
    /// Number of function calls
    function_calls: u64 = 0,
};

/// Script execution context
pub const ScriptContext = struct {
    const Self = @This();

    /// Context name/identifier
    name: []const u8,

    /// Parent scripting engine
    engine: *anyopaque,

    /// Engine-specific context data
    engine_context: *anyopaque,

    /// Allocator for this context
    allocator: std.mem.Allocator,

    /// Security permissions
    permissions: SecurityPermissions,

    /// Resource limits
    limits: ResourceLimits,

    /// Execution statistics
    stats: ExecutionStats,

    /// Registered modules
    modules: std.StringHashMap(*ScriptModule),

    /// Global variables
    globals: std.StringHashMap(ScriptValue),

    /// Function cache
    function_cache: std.StringHashMap(*ScriptFunction),

    /// Error state
    last_error: ?ScriptError,

    /// Context state
    state: ContextState,

    /// Creation timestamp
    created_at: i64,

    /// Mutex for thread safety
    mutex: std.Thread.Mutex,

    pub const ContextState = enum {
        ready,
        executing,
        suspended,
        err,
        terminated,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        engine: *anyopaque,
        engine_context: *anyopaque,
    ) !*Self {
        const self = try allocator.create(Self);

        self.* = Self{
            .name = try allocator.dupe(u8, name),
            .engine = engine,
            .engine_context = engine_context,
            .allocator = allocator,
            .permissions = SecurityPermissions{},
            .limits = ResourceLimits{},
            .stats = ExecutionStats{},
            .modules = std.StringHashMap(*ScriptModule).init(allocator),
            .globals = std.StringHashMap(ScriptValue).init(allocator),
            .function_cache = std.StringHashMap(*ScriptFunction).init(allocator),
            .last_error = null,
            .state = .ready,
            .created_at = std.time.milliTimestamp(),
            .mutex = std.Thread.Mutex{},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up globals
        var globals_iter = self.globals.iterator();
        while (globals_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.globals.deinit();

        // Clean up modules
        var modules_iter = self.modules.iterator();
        while (modules_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.modules.deinit();

        // Clean up function cache
        var func_iter = self.function_cache.iterator();
        while (func_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.function_cache.deinit();

        // Clean up error
        if (self.last_error) |*err| {
            err.deinit();
        }

        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Set security permissions
    pub fn setPermissions(self: *Self, permissions: SecurityPermissions) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.permissions = permissions;
    }

    /// Set resource limits
    pub fn setLimits(self: *Self, limits: ResourceLimits) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.limits = limits;
    }

    /// Check if module is allowed
    pub fn isModuleAllowed(self: *Self, module_name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.permissions.allowed_modules) |allowed| {
            for (allowed) |allowed_module| {
                if (std.mem.eql(u8, allowed_module, module_name)) {
                    return true;
                }
            }
            return false;
        }

        return true; // All modules allowed if list is null
    }

    /// Register a module
    pub fn registerModule(self: *Self, module: *ScriptModule) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.isModuleAllowed(module.name)) {
            return error.ModuleNotAllowed;
        }

        const owned_name = try self.allocator.dupe(u8, module.name);
        try self.modules.put(owned_name, module);
    }

    /// Get a registered module
    pub fn getModule(self: *Self, name: []const u8) ?*ScriptModule {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.modules.get(name);
    }

    /// Set a global variable
    pub fn setGlobal(self: *Self, name: []const u8, value: ScriptValue) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_name = try self.allocator.dupe(u8, name);
        const owned_value = try value.clone(self.allocator);

        // Clean up existing value if any
        if (self.globals.fetchPut(owned_name, owned_value)) |kv| {
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
        }
    }

    /// Get a global variable
    pub fn getGlobal(self: *Self, name: []const u8) ?ScriptValue {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.globals.get(name);
    }

    /// Cache a function reference
    pub fn cacheFunction(self: *Self, name: []const u8, function: *ScriptFunction) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_name = try self.allocator.dupe(u8, name);
        try self.function_cache.put(owned_name, function);
    }

    /// Get cached function
    pub fn getCachedFunction(self: *Self, name: []const u8) ?*ScriptFunction {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.function_cache.get(name);
    }

    /// Execute a function (called by ScriptFunction)
    pub fn executeFunction(self: *Self, function: *ScriptFunction, args: []const ScriptValue) !ScriptValue {
        _ = self;
        _ = function;
        _ = args;
        // This is implemented by the specific engine
        return error.NotImplemented;
    }

    /// Release a function reference
    pub fn releaseFunction(self: *Self, function: *ScriptFunction) void {
        _ = self;
        _ = function;
        // This is implemented by the specific engine
    }

    /// Set last error
    pub fn setError(self: *Self, err: ScriptError) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.last_error) |*old_err| {
            old_err.deinit();
        }

        self.last_error = err;
        self.state = .err;
    }

    /// Get last error
    pub fn getLastError(self: *Self) ?ScriptError {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_error;
    }

    /// Clear errors
    pub fn clearErrors(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.last_error) |*err| {
            err.deinit();
            self.last_error = null;
        }

        if (self.state == .err) {
            self.state = .ready;
        }
    }

    /// Update execution statistics
    pub fn updateStats(self: *Self, update: struct {
        execution_time_ms: ?u64 = null,
        memory_allocated: ?usize = null,
        allocation_count: ?usize = null,
        gc_count: ?u32 = null,
        function_calls: ?u64 = null,
    }) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (update.execution_time_ms) |time| {
            self.stats.execution_time_ms += time;
        }

        if (update.memory_allocated) |mem| {
            self.stats.memory_allocated = mem;
            if (mem > self.stats.peak_memory) {
                self.stats.peak_memory = mem;
            }
        }

        if (update.allocation_count) |count| {
            self.stats.allocation_count = count;
        }

        if (update.gc_count) |count| {
            self.stats.gc_count += count;
        }

        if (update.function_calls) |calls| {
            self.stats.function_calls += calls;
        }
    }

    /// Get execution statistics
    pub fn getStats(self: *Self) ExecutionStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    /// Check resource limits
    pub fn checkLimits(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check memory limit
        if (self.limits.max_memory_bytes > 0 and self.stats.memory_allocated > self.limits.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }

        // Check allocation limit
        if (self.stats.allocation_count > self.limits.max_allocations) {
            return error.AllocationLimitExceeded;
        }

        // Check execution time limit
        if (self.limits.max_execution_time_ms > 0) {
            const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - self.created_at));
            if (elapsed > self.limits.max_execution_time_ms) {
                return error.TimeLimitExceeded;
            }
        }
    }

    /// Get context age in milliseconds
    pub fn getAge(self: *Self) i64 {
        return std.time.milliTimestamp() - self.created_at;
    }

    /// Check if context is in valid state for execution
    pub fn isReady(self: *Self) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .ready or self.state == .suspended;
    }

    /// Set context state
    pub fn setState(self: *Self, state: ContextState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = state;
    }
};

// Tests
test "ScriptContext creation and management" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const dummy_engine: *anyopaque = undefined;
    const dummy_context: *anyopaque = undefined;

    const ctx = try ScriptContext.init(allocator, "test_context", dummy_engine, dummy_context);
    defer ctx.deinit();

    try testing.expectEqualStrings("test_context", ctx.name);
    try testing.expect(ctx.state == .ready);
    try testing.expect(ctx.isReady());

    // Test permissions
    ctx.setPermissions(.{
        .file_read = true,
        .file_write = false,
        .allowed_modules = &[_][]const u8{ "zigllms.agent", "zigllms.tool" },
    });

    try testing.expect(ctx.isModuleAllowed("zigllms.agent"));
    try testing.expect(ctx.isModuleAllowed("zigllms.tool"));
    try testing.expect(!ctx.isModuleAllowed("zigllms.workflow"));

    // Test resource limits
    ctx.setLimits(.{
        .max_memory_bytes = 1024 * 1024, // 1MB
        .max_execution_time_ms = 5000, // 5 seconds
    });

    try testing.expectEqual(@as(usize, 1024 * 1024), ctx.limits.max_memory_bytes);
}

test "ScriptContext global variables" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const dummy_engine: *anyopaque = undefined;
    const dummy_context: *anyopaque = undefined;

    const ctx = try ScriptContext.init(allocator, "test", dummy_engine, dummy_context);
    defer ctx.deinit();

    // Set and get globals
    try ctx.setGlobal("test_string", ScriptValue{ .string = try allocator.dupe(u8, "hello") });
    try ctx.setGlobal("test_number", ScriptValue{ .integer = 42 });
    try ctx.setGlobal("test_bool", ScriptValue{ .boolean = true });

    try testing.expect(ctx.getGlobal("test_string").?.string[0] == 'h');
    try testing.expect(ctx.getGlobal("test_number").?.integer == 42);
    try testing.expect(ctx.getGlobal("test_bool").?.boolean == true);
    try testing.expect(ctx.getGlobal("missing") == null);
}

test "ScriptContext statistics tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const dummy_engine: *anyopaque = undefined;
    const dummy_context: *anyopaque = undefined;

    const ctx = try ScriptContext.init(allocator, "test", dummy_engine, dummy_context);
    defer ctx.deinit();

    ctx.updateStats(.{
        .execution_time_ms = 100,
        .memory_allocated = 1024,
        .function_calls = 10,
    });

    const stats = ctx.getStats();
    try testing.expectEqual(@as(u64, 100), stats.execution_time_ms);
    try testing.expectEqual(@as(usize, 1024), stats.memory_allocated);
    try testing.expectEqual(@as(usize, 1024), stats.peak_memory);
    try testing.expectEqual(@as(u64, 10), stats.function_calls);

    // Update with higher memory usage
    ctx.updateStats(.{
        .memory_allocated = 2048,
    });

    const stats2 = ctx.getStats();
    try testing.expectEqual(@as(usize, 2048), stats2.memory_allocated);
    try testing.expectEqual(@as(usize, 2048), stats2.peak_memory);
}
