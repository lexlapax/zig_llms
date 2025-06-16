// ABOUTME: Protected call wrapper for Lua with advanced error handling
// ABOUTME: Provides safe function calls with error recovery and debugging support

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const ScriptError = @import("../error_bridge.zig").ScriptError;

/// Error types for protected calls
pub const PCallError = error{
    RuntimeError,
    MemoryError,
    ErrorInErrorHandler,
    GCError,
    InvalidState,
    StackOverflow,
    InvalidArgument,
} || std.mem.Allocator.Error;

/// Options for protected calls
pub const PCallOptions = struct {
    /// Error handler function index (0 = none)
    error_handler: c_int = 0,
    /// Whether to use debug.traceback as error handler
    use_traceback: bool = true,
    /// Maximum allowed execution time in milliseconds (0 = unlimited)
    timeout_ms: u32 = 0,
    /// Whether to check stack space before call
    check_stack: bool = true,
    /// Minimum stack slots to reserve
    min_stack_slots: c_int = 20,
    /// Whether to yield periodically for cooperative multitasking
    yield_instructions: u32 = 0,
};

/// Result of a protected call
pub const PCallResult = struct {
    /// Number of return values on the stack
    return_count: c_int,
    /// Execution time in microseconds
    execution_time_us: u64,
    /// Whether the call was interrupted by timeout
    timed_out: bool = false,

    pub fn popResults(self: PCallResult, wrapper: *lua.LuaWrapper) void {
        if (self.return_count > 0) {
            wrapper.pop(self.return_count);
        }
    }
};

/// Debug hook data for timeouts and yielding
const HookData = struct {
    start_time: i64,
    timeout_ms: u32,
    yield_instructions: u32,
    instruction_count: u32 = 0,
    timed_out: bool = false,
    wrapper: *lua.LuaWrapper,
};

/// Protected call wrapper
pub const PCallWrapper = struct {
    wrapper: *lua.LuaWrapper,
    allocator: std.mem.Allocator,
    default_options: PCallOptions,
    error_handler_ref: ?c_int = null,

    pub fn init(wrapper: *lua.LuaWrapper, allocator: std.mem.Allocator) PCallWrapper {
        return PCallWrapper{
            .wrapper = wrapper,
            .allocator = allocator,
            .default_options = PCallOptions{},
        };
    }

    pub fn deinit(self: *PCallWrapper) void {
        if (self.error_handler_ref) |ref| {
            self.wrapper.unref(lua.LUA_REGISTRYINDEX, ref);
            self.error_handler_ref = null;
        }
    }

    /// Set up default error handler
    pub fn setupErrorHandler(self: *PCallWrapper) !void {
        if (!lua.lua_enabled) return;

        // Push debug.traceback function
        try self.wrapper.getGlobal("debug");
        if (self.wrapper.isNil(-1)) {
            self.wrapper.pop(1);
            return; // debug library not available
        }

        try self.wrapper.getField(-1, "traceback");
        self.wrapper.remove(-2); // Remove debug table

        if (!self.wrapper.isFunction(-1)) {
            self.wrapper.pop(1);
            return;
        }

        // Store reference
        self.error_handler_ref = self.wrapper.ref(lua.LUA_REGISTRYINDEX);
    }

    /// Perform a protected call
    pub fn call(
        self: *PCallWrapper,
        nargs: c_int,
        nresults: c_int,
        options: ?PCallOptions,
    ) PCallError!PCallResult {
        if (!lua.lua_enabled) return PCallError.InvalidState;

        const opts = options orelse self.default_options;
        const start_time = std.time.microTimestamp();

        // Check stack space
        if (opts.check_stack) {
            const required = nargs + opts.min_stack_slots;
            if (!lua.c.lua_checkstack(self.wrapper.state, required)) {
                return PCallError.StackOverflow;
            }
        }

        // Determine error handler
        var error_handler: c_int = 0;
        if (opts.error_handler != 0) {
            error_handler = opts.error_handler;
        } else if (opts.use_traceback and self.error_handler_ref != null) {
            // Push error handler
            lua.c.lua_rawgeti(self.wrapper.state, lua.LUA_REGISTRYINDEX, self.error_handler_ref.?);
            error_handler = -(nargs + 2); // Below function and args
        }

        // Set up timeout hook if needed
        var hook_data: ?HookData = null;
        if (opts.timeout_ms > 0 or opts.yield_instructions > 0) {
            hook_data = HookData{
                .start_time = std.time.milliTimestamp(),
                .timeout_ms = opts.timeout_ms,
                .yield_instructions = opts.yield_instructions,
                .wrapper = self.wrapper,
            };

            lua.c.lua_sethook(
                self.wrapper.state,
                timeoutHook,
                lua.c.LUA_MASKCOUNT,
                if (opts.yield_instructions > 0) opts.yield_instructions else 1000,
            );
        }
        defer {
            if (hook_data != null) {
                lua.c.lua_sethook(self.wrapper.state, null, 0, 0);
            }
        }

        // Perform the protected call
        const result = lua.c.lua_pcall(
            self.wrapper.state,
            nargs,
            nresults,
            error_handler,
        );

        // Remove error handler if we pushed it
        if (error_handler != 0 and opts.error_handler == 0) {
            self.wrapper.remove(error_handler);
        }

        const end_time = std.time.microTimestamp();
        const execution_time = @as(u64, @intCast(end_time - start_time));

        // Check for timeout
        const timed_out = if (hook_data) |*data| data.timed_out else false;

        if (result != lua.LUA_OK) {
            // Error occurred, message is on stack
            defer self.wrapper.pop(1); // Remove error message

            const error_msg = self.wrapper.toString(-1) catch "Unknown error";

            // Log the error with context
            std.log.err("Lua pcall error: {s}", .{error_msg});

            if (timed_out) {
                return PCallError.RuntimeError; // Timeout is a runtime error
            }

            return switch (result) {
                lua.LUA_ERRRUN => PCallError.RuntimeError,
                lua.LUA_ERRMEM => PCallError.MemoryError,
                lua.LUA_ERRERR => PCallError.ErrorInErrorHandler,
                else => PCallError.RuntimeError,
            };
        }

        return PCallResult{
            .return_count = nresults,
            .execution_time_us = execution_time,
            .timed_out = timed_out,
        };
    }

    /// Call a global function by name
    pub fn callGlobal(
        self: *PCallWrapper,
        name: []const u8,
        args: []const lua.LuaValue,
        nresults: c_int,
        options: ?PCallOptions,
    ) !PCallResult {
        try self.wrapper.getGlobal(name);
        if (!self.wrapper.isFunction(-1)) {
            self.wrapper.pop(1);
            return PCallError.InvalidArgument;
        }

        // Push arguments
        for (args) |arg| {
            try pushLuaValue(self.wrapper, arg);
        }

        return self.call(@intCast(args.len), nresults, options);
    }

    /// Call a method on a table
    pub fn callMethod(
        self: *PCallWrapper,
        table_index: c_int,
        method_name: []const u8,
        args: []const lua.LuaValue,
        nresults: c_int,
        options: ?PCallOptions,
    ) !PCallResult {
        // Get the method
        self.wrapper.pushValue(table_index);
        try self.wrapper.getField(-1, method_name);

        if (!self.wrapper.isFunction(-1)) {
            self.wrapper.pop(2); // method and table
            return PCallError.InvalidArgument;
        }

        // Move table to be first argument (self)
        self.wrapper.insert(-2);

        // Push remaining arguments
        for (args) |arg| {
            try pushLuaValue(self.wrapper, arg);
        }

        return self.call(@intCast(args.len + 1), nresults, options);
    }

    /// Resume a coroutine with protected call semantics
    pub fn resumeCoroutine(
        self: *PCallWrapper,
        thread: ?*lua.c.lua_State,
        nargs: c_int,
        options: ?PCallOptions,
    ) !PCallResult {
        if (!lua.lua_enabled) return PCallError.InvalidState;

        _ = options; // Options reserved for future use (e.g., timeout handling)
        const start_time = std.time.microTimestamp();

        // Check if thread is resumable
        const status = lua.c.lua_status(thread);
        if (status != lua.LUA_OK and status != lua.LUA_YIELD) {
            return PCallError.InvalidState;
        }

        // Resume the coroutine
        var nresults: c_int = 0;
        const result = lua.c.lua_resume(thread, self.wrapper.state, nargs, &nresults);

        const end_time = std.time.microTimestamp();
        const execution_time = @as(u64, @intCast(end_time - start_time));

        if (result != lua.LUA_OK and result != lua.LUA_YIELD) {
            // Error occurred
            const error_msg = lua.c.lua_tostring(thread, -1) orelse "Unknown error";
            std.log.err("Lua coroutine error: {s}", .{error_msg});

            return switch (result) {
                lua.LUA_ERRRUN => PCallError.RuntimeError,
                lua.LUA_ERRMEM => PCallError.MemoryError,
                lua.LUA_ERRERR => PCallError.ErrorInErrorHandler,
                else => PCallError.RuntimeError,
            };
        }

        return PCallResult{
            .return_count = nresults,
            .execution_time_us = execution_time,
            .timed_out = false,
        };
    }

    /// Create a sandboxed environment for calls
    pub fn createSandbox(self: *PCallWrapper) !c_int {
        if (!lua.lua_enabled) return PCallError.InvalidState;

        // Create new environment table
        self.wrapper.createTable(0, 10);
        const env_index = self.wrapper.getTop();

        // Add safe global functions
        const safe_globals = [_][]const u8{
            "assert",   "error",  "ipairs",   "next",     "pairs", "pcall",
            "print",    "select", "tonumber", "tostring", "type",  "unpack",
            "_VERSION", "xpcall",
        };

        for (safe_globals) |name| {
            try self.wrapper.getGlobal(name);
            try self.wrapper.setField(env_index, name);
        }

        // Add safe libraries
        const safe_libs = [_]struct { name: []const u8, fields: []const []const u8 }{
            .{ .name = "math", .fields = &[_][]const u8{} }, // All math functions are safe
            .{ .name = "string", .fields = &[_][]const u8{} }, // All string functions are safe
            .{ .name = "table", .fields = &[_][]const u8{} }, // All table functions are safe
            .{
                .name = "os",
                .fields = &[_][]const u8{ "clock", "date", "difftime", "time" }, // Only time functions
            },
        };

        for (safe_libs) |lib| {
            try self.wrapper.getGlobal(lib.name);
            if (!self.wrapper.isNil(-1)) {
                if (lib.fields.len == 0) {
                    // Include entire library
                    try self.wrapper.setField(env_index, lib.name);
                } else {
                    // Create filtered table
                    self.wrapper.createTable(0, @intCast(lib.fields.len));
                    const filtered_index = self.wrapper.getTop();

                    for (lib.fields) |field| {
                        try self.wrapper.getField(-2, field);
                        try self.wrapper.setField(filtered_index, field);
                    }

                    self.wrapper.remove(-2); // Remove original library
                    try self.wrapper.setField(env_index, lib.name);
                }
            } else {
                self.wrapper.pop(1);
            }
        }

        return env_index;
    }
};

/// Timeout hook function
fn timeoutHook(state: ?*lua.c.lua_State, ar: ?*lua.c.lua_Debug) callconv(.C) void {
    _ = ar;

    if (!lua.lua_enabled or state == null) return;

    // Get hook data from registry (would need to be stored there)
    // For now, just implement a simple instruction counter
    // In a real implementation, we'd check elapsed time

    // This is a simplified version - real implementation would need
    // to properly track timeout state
}

/// Helper to push various Lua values
fn pushLuaValue(wrapper: *lua.LuaWrapper, value: lua.LuaValue) !void {
    switch (value) {
        .nil => wrapper.pushNil(),
        .boolean => |b| wrapper.pushBoolean(b),
        .integer => |i| wrapper.pushInteger(i),
        .number => |n| wrapper.pushNumber(n),
        .string => |s| try wrapper.pushString(s),
        .light_userdata => |ptr| lua.c.lua_pushlightuserdata(wrapper.state, ptr),
    }
}

/// Lua value types for arguments
pub const LuaValue = union(enum) {
    nil,
    boolean: bool,
    integer: lua.LuaInteger,
    number: lua.LuaNumber,
    string: []const u8,
    light_userdata: *anyopaque,
};

// Tests
test "PCallWrapper basic usage" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var pcall = PCallWrapper.init(wrapper, allocator);
    defer pcall.deinit();

    try pcall.setupErrorHandler();

    // Push a simple function
    try wrapper.doString(
        \\function test_add(a, b)
        \\    return a + b
        \\end
    );

    // Call the function
    const args = [_]LuaValue{
        .{ .integer = 10 },
        .{ .integer = 20 },
    };

    const result = try pcall.callGlobal("test_add", &args, 1, null);
    defer result.popResults(wrapper);

    try std.testing.expectEqual(@as(c_int, 1), result.return_count);

    const value = wrapper.toInteger(-1).?;
    try std.testing.expectEqual(@as(lua.LuaInteger, 30), value);
}

test "PCallWrapper error handling" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var pcall = PCallWrapper.init(wrapper, allocator);
    defer pcall.deinit();

    try pcall.setupErrorHandler();

    // Define a function that errors
    try wrapper.doString(
        \\function test_error()
        \\    error("Test error message")
        \\end
    );

    // Call should fail
    const result = pcall.callGlobal("test_error", &[_]LuaValue{}, 0, null);
    try std.testing.expectError(PCallError.RuntimeError, result);
}

test "PCallWrapper sandbox" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var pcall = PCallWrapper.init(wrapper, allocator);
    defer pcall.deinit();

    const sandbox_index = try pcall.createSandbox();
    defer wrapper.pop(1);

    // Verify safe functions exist
    try wrapper.getField(sandbox_index, "print");
    try std.testing.expect(wrapper.isFunction(-1));
    wrapper.pop(1);

    // Verify dangerous functions don't exist
    try wrapper.getField(sandbox_index, "dofile");
    try std.testing.expect(wrapper.isNil(-1));
    wrapper.pop(1);

    // Verify safe os functions exist
    try wrapper.getField(sandbox_index, "os");
    try wrapper.getField(-1, "clock");
    try std.testing.expect(wrapper.isFunction(-1));
    wrapper.pop(2);
}
