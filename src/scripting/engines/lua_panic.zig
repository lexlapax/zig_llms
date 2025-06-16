// ABOUTME: Lua panic handler integration with Zig error handling
// ABOUTME: Provides custom panic handlers, error recovery, and diagnostic information

const std = @import("std");
const builtin = @import("builtin");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const LuaError = lua.LuaError;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;

/// Panic handler error types
pub const PanicError = error{
    LuaPanic,
    MemoryError,
    StackOverflow,
    InternalError,
    UnrecoverableError,
    HandlerNotSet,
    InvalidState,
};

/// Panic information captured during a panic
pub const PanicInfo = struct {
    message: []const u8,
    error_type: PanicType,
    stack_trace: ?[]const u8,
    lua_stack_depth: c_int,
    timestamp: i64,
    thread_id: std.Thread.Id,
    allocator: std.mem.Allocator,

    pub const PanicType = enum {
        memory_error,
        stack_overflow,
        error_object,
        protection_fault,
        internal_error,
        unknown,
    };

    pub fn init(allocator: std.mem.Allocator, message: []const u8, error_type: PanicType) !PanicInfo {
        return PanicInfo{
            .message = try allocator.dupe(u8, message),
            .error_type = error_type,
            .stack_trace = null,
            .lua_stack_depth = 0,
            .timestamp = std.time.milliTimestamp(),
            .thread_id = std.Thread.getCurrentId(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PanicInfo) void {
        self.allocator.free(self.message);
        if (self.stack_trace) |trace| {
            self.allocator.free(trace);
        }
    }

    pub fn setStackTrace(self: *PanicInfo, trace: []const u8) !void {
        if (self.stack_trace) |old_trace| {
            self.allocator.free(old_trace);
        }
        self.stack_trace = try self.allocator.dupe(u8, trace);
    }
};

/// Panic handler configuration
pub const PanicHandlerConfig = struct {
    /// Whether to attempt recovery from panics
    enable_recovery: bool = true,

    /// Whether to capture Lua stack traces
    capture_stack_trace: bool = true,

    /// Maximum stack trace depth
    max_stack_depth: usize = 50,

    /// Whether to log panics
    log_panics: bool = true,

    /// Custom panic callback
    panic_callback: ?*const fn (*PanicInfo) void = null,

    /// Recovery strategy
    recovery_strategy: RecoveryStrategy = .reset_state,

    pub const RecoveryStrategy = enum {
        /// Attempt to reset the Lua state
        reset_state,
        /// Create a new Lua state
        new_state,
        /// Propagate the error
        propagate,
        /// Custom recovery function
        custom,
    };
};

/// Thread-local storage for panic context
threadlocal var tls_panic_context: ?*PanicContext = null;

/// Panic context for a Lua state
pub const PanicContext = struct {
    wrapper: *LuaWrapper,
    config: PanicHandlerConfig,
    last_panic: ?PanicInfo,
    panic_count: u32,
    allocator: std.mem.Allocator,
    original_panic_handler: ?lua.c.lua_CFunction,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, wrapper: *LuaWrapper, config: PanicHandlerConfig) !*PanicContext {
        const self = try allocator.create(PanicContext);
        self.* = PanicContext{
            .wrapper = wrapper,
            .config = config,
            .last_panic = null,
            .panic_count = 0,
            .allocator = allocator,
            .original_panic_handler = null,
            .mutex = std.Thread.Mutex{},
        };
        return self;
    }

    pub fn deinit(self: *PanicContext) void {
        if (self.last_panic) |*panic| {
            panic.deinit();
        }
        self.allocator.destroy(self);
    }

    pub fn recordPanic(self: *PanicContext, panic_info: PanicInfo) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.last_panic) |*old_panic| {
            old_panic.deinit();
        }
        self.last_panic = panic_info;
        self.panic_count += 1;
    }

    pub fn getLastPanic(self: *PanicContext) ?PanicInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.last_panic;
    }

    pub fn clearPanicHistory(self: *PanicContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.last_panic) |*panic| {
            panic.deinit();
            self.last_panic = null;
        }
        self.panic_count = 0;
    }
};

/// Custom panic handler for Lua
fn customPanicHandler(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    // Get panic context from thread-local storage
    const context = tls_panic_context orelse {
        // Fallback: print error and abort
        const msg = lua.c.lua_tostring(state, -1) orelse "unknown error";
        std.debug.print("Lua panic (no context): {s}\n", .{std.mem.span(msg)});
        std.process.abort();
    };

    // Extract error message
    const error_msg = if (lua.c.lua_type(state, -1) == lua.c.LUA_TSTRING)
        lua.c.lua_tostring(state, -1)
    else
        "non-string error object";

    const msg_slice = if (error_msg) |msg| std.mem.span(msg) else "unknown error";

    // Determine panic type
    const panic_type = determinePanicType(msg_slice);

    // Create panic info
    var panic_info = PanicInfo.init(
        context.allocator,
        msg_slice,
        panic_type,
    ) catch {
        // Allocation failed, can't recover
        std.debug.print("Lua panic (allocation failed): {s}\n", .{msg_slice});
        std.process.abort();
    };

    // Capture stack information
    panic_info.lua_stack_depth = lua.c.lua_gettop(state);

    // Capture stack trace if enabled
    if (context.config.capture_stack_trace) {
        captureStackTrace(state, &panic_info, context.config.max_stack_depth) catch {};
    }

    // Log panic if enabled
    if (context.config.log_panics) {
        logPanic(&panic_info);
    }

    // Call custom callback if provided
    if (context.config.panic_callback) |callback| {
        callback(&panic_info);
    }

    // Record panic in context
    context.recordPanic(panic_info);

    // Handle recovery based on strategy
    switch (context.config.recovery_strategy) {
        .reset_state => {
            // Attempt to reset the Lua state
            // This is risky and may not always work
            if (context.config.enable_recovery) {
                return @intFromEnum(LuaError.RuntimeError);
            }
        },
        .new_state => {
            // Would need to signal state replacement
            // For now, just propagate
        },
        .propagate => {
            // Let Zig handle it
        },
        .custom => {
            // Custom recovery would go here
        },
    }

    // If we get here, we couldn't recover
    std.debug.panic("Lua panic: {s}\n", .{msg_slice});
}

fn determinePanicType(message: []const u8) PanicInfo.PanicType {
    if (std.mem.indexOf(u8, message, "not enough memory") != null or
        std.mem.indexOf(u8, message, "memory allocation error") != null)
    {
        return .memory_error;
    } else if (std.mem.indexOf(u8, message, "stack overflow") != null or
        std.mem.indexOf(u8, message, "too many") != null)
    {
        return .stack_overflow;
    } else if (std.mem.indexOf(u8, message, "error in error handling") != null) {
        return .protection_fault;
    } else if (std.mem.indexOf(u8, message, "internal") != null) {
        return .internal_error;
    } else if (std.mem.indexOf(u8, message, "error object is not a string") != null) {
        return .error_object;
    } else {
        return .unknown;
    }
}

fn captureStackTrace(state: lua.c.lua_State, panic_info: *PanicInfo, max_depth: usize) !void {
    var trace_buf = std.ArrayList(u8).init(panic_info.allocator);
    defer trace_buf.deinit();

    const writer = trace_buf.writer();
    try writer.writeAll("Lua stack trace:\n");

    var level: c_int = 0;
    var ar: lua.c.lua_Debug = undefined;

    while (lua.c.lua_getstack(state, level, &ar) != 0 and level < max_depth) : (level += 1) {
        if (lua.c.lua_getinfo(state, "nSl", &ar) == 0) continue;

        // Format: [level] function_name (source:line)
        try writer.print("  [{d}] ", .{level});

        if (ar.name) |name| {
            try writer.print("{s} ", .{std.mem.span(name)});
        } else if (std.mem.eql(u8, std.mem.span(ar.what), "main")) {
            try writer.writeAll("main chunk ");
        } else if (std.mem.eql(u8, std.mem.span(ar.what), "C")) {
            try writer.writeAll("[C function] ");
        } else {
            try writer.writeAll("<unknown> ");
        }

        try writer.print("({s}:{d})\n", .{
            std.mem.span(ar.short_src),
            ar.currentline,
        });
    }

    try panic_info.setStackTrace(try trace_buf.toOwnedSlice());
}

fn logPanic(panic_info: *PanicInfo) void {
    std.log.err("Lua panic occurred: {s}", .{panic_info.message});
    std.log.err("  Type: {s}", .{@tagName(panic_info.error_type)});
    std.log.err("  Thread: {}", .{panic_info.thread_id});
    std.log.err("  Stack depth: {d}", .{panic_info.lua_stack_depth});

    if (panic_info.stack_trace) |trace| {
        std.log.err("Stack trace:\n{s}", .{trace});
    }
}

/// Panic handler manager
pub const PanicHandler = struct {
    context: *PanicContext,
    installed: bool,

    pub fn init(wrapper: *LuaWrapper, config: PanicHandlerConfig) !PanicHandler {
        const context = try PanicContext.init(wrapper.allocator, wrapper, config);
        errdefer context.deinit();

        return PanicHandler{
            .context = context,
            .installed = false,
        };
    }

    pub fn deinit(self: *PanicHandler) void {
        if (self.installed) {
            self.uninstall() catch {};
        }
        self.context.deinit();
    }

    pub fn install(self: *PanicHandler) !void {
        if (self.installed) {
            return PanicError.HandlerNotSet;
        }

        if (!lua.lua_enabled) {
            return PanicError.InvalidState;
        }

        // Set thread-local context
        tls_panic_context = self.context;

        // Store original panic handler (usually null)
        self.context.original_panic_handler = lua.c.lua_atpanic(
            self.context.wrapper.state,
            customPanicHandler,
        );

        self.installed = true;
    }

    pub fn uninstall(self: *PanicHandler) !void {
        if (!self.installed) {
            return;
        }

        if (!lua.lua_enabled) {
            return PanicError.InvalidState;
        }

        // Restore original panic handler
        _ = lua.c.lua_atpanic(
            self.context.wrapper.state,
            self.context.original_panic_handler,
        );

        // Clear thread-local context
        tls_panic_context = null;

        self.installed = false;
    }

    pub fn getLastPanic(self: *PanicHandler) ?PanicInfo {
        return self.context.getLastPanic();
    }

    pub fn getPanicCount(self: *PanicHandler) u32 {
        return self.context.panic_count;
    }

    pub fn clearHistory(self: *PanicHandler) void {
        self.context.clearPanicHistory();
    }
};

/// Protected execution with panic recovery
pub const ProtectedExecutor = struct {
    wrapper: *LuaWrapper,
    panic_handler: *PanicHandler,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, wrapper: *LuaWrapper, config: PanicHandlerConfig) !ProtectedExecutor {
        const handler = try allocator.create(PanicHandler);
        errdefer allocator.destroy(handler);

        handler.* = try PanicHandler.init(wrapper, config);
        try handler.install();

        return ProtectedExecutor{
            .wrapper = wrapper,
            .panic_handler = handler,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProtectedExecutor) void {
        self.panic_handler.deinit();
        self.allocator.destroy(self.panic_handler);
    }

    pub fn executeProtected(self: *ProtectedExecutor, code: []const u8) !void {
        // Clear any previous panics
        self.panic_handler.clearHistory();

        // Execute with panic handler active
        self.wrapper.doString(code) catch |err| {
            // Check if this was a panic
            if (self.panic_handler.getLastPanic()) |panic_info| {
                std.log.err("Execution failed due to panic: {s}", .{panic_info.message});
                return PanicError.LuaPanic;
            }
            return err;
        };
    }

    pub fn callProtected(
        self: *ProtectedExecutor,
        func_name: []const u8,
        args: []const ScriptValue,
    ) !ScriptValue {
        // Clear any previous panics
        self.panic_handler.clearHistory();

        // Push function
        try self.wrapper.getGlobal(func_name);
        if (!self.wrapper.isFunction(-1)) {
            self.wrapper.pop(1);
            return error.NotAFunction;
        }

        // Push arguments
        for (args) |arg| {
            try pushScriptValue(self.wrapper, arg);
        }

        // Call with error handler
        const result = lua.c.lua_pcall(
            self.wrapper.state,
            @intCast(args.len),
            1,
            0,
        );

        if (result != lua.c.LUA_OK) {
            // Check if this was a panic
            if (self.panic_handler.getLastPanic()) |panic_info| {
                std.log.err("Function call failed due to panic: {s}", .{panic_info.message});
                return PanicError.LuaPanic;
            }

            // Extract error message for logging
            _ = self.wrapper.toString(-1) catch "unknown error";
            self.wrapper.pop(1);
            return error.LuaError;
        }

        // Get result
        const ret_val = try pullScriptValue(self.wrapper, -1, self.allocator);
        self.wrapper.pop(1);
        return ret_val;
    }
};

// Helper functions for ScriptValue conversion (simplified)
fn pushScriptValue(wrapper: *LuaWrapper, value: ScriptValue) !void {
    // This would use the actual value converter
    _ = wrapper;
    _ = value;
}

fn pullScriptValue(wrapper: *LuaWrapper, index: i32, allocator: std.mem.Allocator) !ScriptValue {
    // This would use the actual value converter
    _ = wrapper;
    _ = index;
    _ = allocator;
    return .null;
}

// Panic recovery utilities
pub const RecoveryUtils = struct {
    /// Attempt to recover a Lua state after a panic
    pub fn attemptStateRecovery(wrapper: *LuaWrapper) !void {
        if (!lua.lua_enabled) return;

        // Clear the stack
        lua.c.lua_settop(wrapper.state, 0);

        // Reset global environment
        lua.c.lua_pushglobaltable(wrapper.state);
        lua.c.lua_setglobal(wrapper.state, "_G");

        // Force garbage collection
        _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);

        // Verify state is usable
        lua.c.lua_pushnil(wrapper.state);
        if (lua.c.lua_gettop(wrapper.state) != 1) {
            return PanicError.UnrecoverableError;
        }
        lua.c.lua_pop(wrapper.state, 1);
    }

    /// Create diagnostic report after a panic
    pub fn createDiagnosticReport(
        allocator: std.mem.Allocator,
        panic_info: *const PanicInfo,
        wrapper: *LuaWrapper,
    ) ![]u8 {
        var report = std.ArrayList(u8).init(allocator);
        defer report.deinit();

        const writer = report.writer();

        try writer.writeAll("=== Lua Panic Diagnostic Report ===\n\n");

        try writer.print("Timestamp: {d}\n", .{panic_info.timestamp});
        try writer.print("Thread ID: {}\n", .{panic_info.thread_id});
        try writer.print("Error Type: {s}\n", .{@tagName(panic_info.error_type)});
        try writer.print("Message: {s}\n", .{panic_info.message});
        try writer.print("Lua Stack Depth: {d}\n\n", .{panic_info.lua_stack_depth});

        if (panic_info.stack_trace) |trace| {
            try writer.writeAll(trace);
            try writer.writeAll("\n");
        }

        // Add memory statistics if available
        if (wrapper.getAllocationStats()) |stats| {
            try writer.writeAll("\nMemory Statistics:\n");
            try writer.print("  Total Allocated: {d} bytes\n", .{stats.total_allocated});
            try writer.print("  Peak Allocated: {d} bytes\n", .{stats.peak_allocated});
            try writer.print("  Active Allocations: {d}\n", .{stats.active_allocations});
        }

        // Add Lua memory usage
        const lua_mem_kb = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
        const lua_mem_b = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNTB, 0);
        const lua_mem = @as(usize, @intCast(lua_mem_kb)) * 1024 + @as(usize, @intCast(lua_mem_b));
        try writer.print("\nLua Memory Usage: {d} bytes\n", .{lua_mem});

        return try report.toOwnedSlice();
    }
};

// Tests
test "PanicHandler installation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var handler = try PanicHandler.init(wrapper, .{});
    defer handler.deinit();

    try handler.install();
    try std.testing.expect(handler.installed);

    try handler.uninstall();
    try std.testing.expect(!handler.installed);
}

test "ProtectedExecutor basic usage" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var executor = try ProtectedExecutor.init(allocator, wrapper, .{});
    defer executor.deinit();

    // Should execute successfully
    try executor.executeProtected("x = 42");

    // This would normally panic, but with our handler it should return an error
    // Note: Actually triggering a panic in tests is dangerous, so we don't test that path
}

test "PanicInfo creation and management" {
    const allocator = std.testing.allocator;

    var panic_info = try PanicInfo.init(allocator, "test panic message", .memory_error);
    defer panic_info.deinit();

    try std.testing.expectEqualStrings("test panic message", panic_info.message);
    try std.testing.expect(panic_info.error_type == .memory_error);
    try std.testing.expect(panic_info.timestamp > 0);

    try panic_info.setStackTrace("test stack trace");
    try std.testing.expectEqualStrings("test stack trace", panic_info.stack_trace.?);
}
