// ABOUTME: Lua script execution with comprehensive error handling and stack management
// ABOUTME: Provides safe execution, error recovery, and detailed error reporting

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptError = @import("../error_bridge.zig").ScriptError;
const value_converter = @import("lua_value_converter.zig");

/// Execution errors specific to Lua
pub const ExecutionError = error{
    CompilationFailed,
    RuntimeError,
    MemoryError,
    ErrorInErrorHandler,
    StackOverflow,
    InvalidBytecode,
    SyntaxError,
    TypeMismatch,
} || std.mem.Allocator.Error;

/// Execution options for script running
pub const ExecutionOptions = struct {
    /// Name for error reporting (e.g., filename or chunk name)
    name: []const u8 = "chunk",
    /// Whether to allow bytecode execution
    allow_bytecode: bool = false,
    /// Stack size to reserve before execution
    stack_reserve: c_int = 20,
    /// Timeout in milliseconds (0 = no timeout)
    timeout_ms: u32 = 0,
    /// Whether to capture stack trace on error
    capture_stack_trace: bool = true,
    /// Maximum stack trace depth
    max_trace_depth: usize = 10,
};

/// Result of script execution
pub const ExecutionResult = struct {
    /// Return values from the script
    values: []ScriptValue,
    /// Execution time in microseconds
    execution_time_us: u64,
    /// Memory allocated during execution
    memory_allocated: usize,
    /// Number of garbage collections triggered
    gc_count: u32,
    
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ExecutionResult) void {
        for (self.values) |*value| {
            value.deinit(self.allocator);
        }
        self.allocator.free(self.values);
    }
};

/// Error information with Lua-specific details
pub const LuaErrorInfo = struct {
    /// Error message
    message: []const u8,
    /// Error type
    error_type: ErrorType,
    /// Stack trace if available
    stack_trace: ?[]StackFrame,
    /// Source location if available
    source_location: ?SourceLocation,
    /// Lua stack dump at error time
    stack_dump: ?[]const u8,
    
    allocator: std.mem.Allocator,
    
    pub const ErrorType = enum {
        syntax,
        runtime,
        memory,
        type_error,
        api_misuse,
        unknown,
    };
    
    pub const StackFrame = struct {
        function_name: ?[]const u8,
        source: []const u8,
        line: i32,
        is_native: bool,
    };
    
    pub const SourceLocation = struct {
        file: []const u8,
        line: i32,
        column: i32,
    };
    
    pub fn deinit(self: *LuaErrorInfo) void {
        self.allocator.free(self.message);
        if (self.stack_trace) |trace| {
            for (trace) |frame| {
                if (frame.function_name) |name| {
                    self.allocator.free(name);
                }
                self.allocator.free(frame.source);
            }
            self.allocator.free(trace);
        }
        if (self.source_location) |loc| {
            self.allocator.free(loc.file);
        }
        if (self.stack_dump) |dump| {
            self.allocator.free(dump);
        }
    }
};

/// Main execution handler
pub const LuaExecutor = struct {
    wrapper: *lua.LuaWrapper,
    allocator: std.mem.Allocator,
    options: ExecutionOptions,
    
    pub fn init(wrapper: *lua.LuaWrapper, allocator: std.mem.Allocator, options: ExecutionOptions) LuaExecutor {
        return LuaExecutor{
            .wrapper = wrapper,
            .allocator = allocator,
            .options = options,
        };
    }
    
    /// Execute a script string
    pub fn executeString(self: *LuaExecutor, script: []const u8) !ExecutionResult {
        if (!lua.lua_enabled) return ExecutionError.RuntimeError;
        
        const start_time = std.time.microTimestamp();
        const initial_memory = self.getMemoryUsage();
        const initial_gc = self.getGCCount();
        
        // Check for bytecode if not allowed
        if (!self.options.allow_bytecode and script.len > 0 and script[0] == 0x1B) {
            return ExecutionError.InvalidBytecode;
        }
        
        // Reserve stack space
        if (!lua.c.lua_checkstack(self.wrapper.state, self.options.stack_reserve)) {
            return ExecutionError.StackOverflow;
        }
        
        // Track initial stack size
        const initial_top = self.wrapper.getTop();
        defer self.wrapper.setTop(initial_top);
        
        // Load the script
        const load_result = self.loadString(script) catch |err| {
            _ = self.handleError(initial_top);
            return err;
        };
        
        if (load_result != lua.LUA_OK) {
            const error_info = try self.extractErrorInfo();
            defer error_info.deinit();
            
            std.log.err("Lua compilation error: {s}", .{error_info.message});
            self.wrapper.pop(1); // Remove error message
            
            return switch (load_result) {
                lua.LUA_ERRSYNTAX => ExecutionError.SyntaxError,
                lua.LUA_ERRMEM => ExecutionError.MemoryError,
                else => ExecutionError.CompilationFailed,
            };
        }
        
        // Execute the loaded chunk
        const nresults = lua.c.LUA_MULTRET;
        const call_result = lua.c.lua_pcall(self.wrapper.state, 0, nresults, 0);
        
        if (call_result != lua.LUA_OK) {
            const error_info = try self.extractErrorInfo();
            defer error_info.deinit();
            
            std.log.err("Lua runtime error: {s}", .{error_info.message});
            self.wrapper.pop(1); // Remove error message
            
            return switch (call_result) {
                lua.LUA_ERRRUN => ExecutionError.RuntimeError,
                lua.LUA_ERRMEM => ExecutionError.MemoryError,
                lua.LUA_ERRERR => ExecutionError.ErrorInErrorHandler,
                else => ExecutionError.RuntimeError,
            };
        }
        
        // Collect return values
        const result_count = self.wrapper.getTop() - initial_top;
        var values = try self.allocator.alloc(ScriptValue, @intCast(result_count));
        errdefer self.allocator.free(values);
        
        for (0..@intCast(result_count)) |i| {
            const stack_idx = initial_top + @as(c_int, @intCast(i)) + 1;
            values[i] = try value_converter.luaToScriptValue(self.wrapper, stack_idx, self.allocator);
        }
        
        const end_time = std.time.microTimestamp();
        const final_memory = self.getMemoryUsage();
        const final_gc = self.getGCCount();
        
        return ExecutionResult{
            .values = values,
            .execution_time_us = @intCast(end_time - start_time),
            .memory_allocated = final_memory -| initial_memory,
            .gc_count = final_gc -| initial_gc,
            .allocator = self.allocator,
        };
    }
    
    /// Execute a script file
    pub fn executeFile(self: *LuaExecutor, path: []const u8) !ExecutionResult {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 10); // 10MB max
        defer self.allocator.free(content);
        
        // Update options with filename for better error reporting
        var file_options = self.options;
        file_options.name = path;
        var file_executor = LuaExecutor.init(self.wrapper, self.allocator, file_options);
        
        return file_executor.executeString(content);
    }
    
    /// Call a global function
    pub fn callFunction(self: *LuaExecutor, name: []const u8, args: []const ScriptValue) !ExecutionResult {
        if (!lua.lua_enabled) return ExecutionError.RuntimeError;
        
        const start_time = std.time.microTimestamp();
        const initial_memory = self.getMemoryUsage();
        const initial_gc = self.getGCCount();
        
        // Get the function
        try self.wrapper.getGlobal(name);
        if (!self.wrapper.isFunction(-1)) {
            self.wrapper.pop(1);
            return ExecutionError.TypeMismatch;
        }
        
        // Push arguments
        for (args) |arg| {
            try value_converter.scriptValueToLua(self.wrapper, arg);
        }
        
        // Call the function
        const call_result = lua.c.lua_pcall(
            self.wrapper.state,
            @intCast(args.len),
            lua.c.LUA_MULTRET,
            0
        );
        
        if (call_result != lua.LUA_OK) {
            const error_info = try self.extractErrorInfo();
            defer error_info.deinit();
            
            std.log.err("Function call error: {s}", .{error_info.message});
            self.wrapper.pop(1);
            
            return switch (call_result) {
                lua.LUA_ERRRUN => ExecutionError.RuntimeError,
                lua.LUA_ERRMEM => ExecutionError.MemoryError,
                lua.LUA_ERRERR => ExecutionError.ErrorInErrorHandler,
                else => ExecutionError.RuntimeError,
            };
        }
        
        // Collect results
        const result_count = self.wrapper.getTop();
        var values = try self.allocator.alloc(ScriptValue, @intCast(result_count));
        errdefer self.allocator.free(values);
        
        for (0..@intCast(result_count)) |i| {
            values[i] = try value_converter.luaToScriptValue(
                self.wrapper,
                @intCast(i + 1),
                self.allocator
            );
        }
        
        // Clean up stack
        self.wrapper.setTop(0);
        
        const end_time = std.time.microTimestamp();
        const final_memory = self.getMemoryUsage();
        const final_gc = self.getGCCount();
        
        return ExecutionResult{
            .values = values,
            .execution_time_us = @intCast(end_time - start_time),
            .memory_allocated = final_memory -| initial_memory,
            .gc_count = final_gc -| initial_gc,
            .allocator = self.allocator,
        };
    }
    
    /// Load a string without executing it
    fn loadString(self: *LuaExecutor, script: []const u8) !c_int {
        const script_z = try self.allocator.dupeZ(u8, script);
        defer self.allocator.free(script_z);
        
        const name_z = try self.allocator.dupeZ(u8, self.options.name);
        defer self.allocator.free(name_z);
        
        // Load in text mode only if bytecode not allowed
        const mode = if (self.options.allow_bytecode) "bt" else "t";
        
        return lua.c.luaL_loadbufferx(
            self.wrapper.state,
            script_z,
            script.len,
            name_z,
            mode
        );
    }
    
    /// Extract detailed error information
    fn extractErrorInfo(self: *LuaExecutor) !LuaErrorInfo {
        const error_msg = self.wrapper.toString(-1) catch "Unknown error";
        const msg_copy = try self.allocator.dupe(u8, error_msg);
        
        // Try to determine error type from message
        const error_type = self.classifyError(error_msg);
        
        // Extract stack trace if requested
        var stack_trace: ?[]LuaErrorInfo.StackFrame = null;
        if (self.options.capture_stack_trace) {
            stack_trace = try self.extractStackTrace();
        }
        
        // Extract source location from error message
        const source_location = self.parseSourceLocation(error_msg);
        
        // Capture stack dump for debugging
        const stack_dump = if (self.options.capture_stack_trace)
            try self.captureStackDump()
        else
            null;
        
        return LuaErrorInfo{
            .message = msg_copy,
            .error_type = error_type,
            .stack_trace = stack_trace,
            .source_location = source_location,
            .stack_dump = stack_dump,
            .allocator = self.allocator,
        };
    }
    
    /// Classify error type from message
    fn classifyError(self: *LuaExecutor, message: []const u8) LuaErrorInfo.ErrorType {
        _ = self;
        
        if (std.mem.indexOf(u8, message, "syntax error") != null) {
            return .syntax;
        } else if (std.mem.indexOf(u8, message, "out of memory") != null) {
            return .memory;
        } else if (std.mem.indexOf(u8, message, "attempt to") != null) {
            return .type_error;
        } else {
            return .runtime;
        }
    }
    
    /// Extract stack trace using debug API
    fn extractStackTrace(self: *LuaExecutor) !?[]LuaErrorInfo.StackFrame {
        if (!lua.lua_enabled) return null;
        
        var frames = std.ArrayList(LuaErrorInfo.StackFrame).init(self.allocator);
        defer frames.deinit();
        
        var level: c_int = 0;
        while (level < self.options.max_trace_depth) : (level += 1) {
            var ar: lua.c.lua_Debug = undefined;
            if (lua.c.lua_getstack(self.wrapper.state, level, &ar) == 0) {
                break;
            }
            
            // Get function info
            _ = lua.c.lua_getinfo(self.wrapper.state, "nSl", &ar);
            
            const function_name = if (ar.name != null)
                try self.allocator.dupe(u8, std.mem.span(ar.name))
            else
                null;
            
            const source = try self.allocator.dupe(u8, std.mem.span(ar.source));
            
            try frames.append(LuaErrorInfo.StackFrame{
                .function_name = function_name,
                .source = source,
                .line = ar.currentline,
                .is_native = ar.what[0] == 'C',
            });
        }
        
        return try frames.toOwnedSlice();
    }
    
    /// Parse source location from error message
    fn parseSourceLocation(self: *LuaExecutor, message: []const u8) ?LuaErrorInfo.SourceLocation {
        // Lua error format: "filename:line: message"
        const colon1 = std.mem.indexOf(u8, message, ":") orelse return null;
        const colon2 = std.mem.indexOfPos(u8, message, colon1 + 1, ":") orelse return null;
        
        const file = message[0..colon1];
        const line_str = message[colon1 + 1..colon2];
        
        const line = std.fmt.parseInt(i32, line_str, 10) catch return null;
        
        return LuaErrorInfo.SourceLocation{
            .file = self.allocator.dupe(u8, file) catch return null,
            .line = line,
            .column = 0, // Lua doesn't provide column info
        };
    }
    
    /// Capture current stack state for debugging
    fn captureStackDump(self: *LuaExecutor) !?[]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        const writer = buffer.writer();
        try writer.writeAll("Stack dump:\n");
        
        const top = self.wrapper.getTop();
        var i: c_int = 1;
        while (i <= top) : (i += 1) {
            const type_name = lua.c.lua_typename(self.wrapper.state, self.wrapper.getType(i));
            try writer.print("  [{d}] {s}", .{ i, type_name });
            
            // Try to get string representation
            if (self.wrapper.isString(i) or self.wrapper.isNumber(i)) {
                const str = self.wrapper.toString(i) catch "???";
                try writer.print(": {s}", .{str});
            }
            
            try writer.writeByte('\n');
        }
        
        return try buffer.toOwnedSlice();
    }
    
    /// Handle error by resetting stack to known state
    fn handleError(self: *LuaExecutor, initial_top: c_int) void {
        _ = self;
        _ = initial_top;
        // Stack cleanup is handled by defer in executeString
    }
    
    /// Get current memory usage
    fn getMemoryUsage(self: *LuaExecutor) usize {
        if (!lua.lua_enabled) return 0;
        
        const kb = lua.c.lua_gc(self.wrapper.state, lua.LUA_GCCOUNT, 0);
        const bytes = lua.c.lua_gc(self.wrapper.state, lua.LUA_GCCOUNTB, 0);
        return @as(usize, @intCast(kb)) * 1024 + @as(usize, @intCast(bytes));
    }
    
    /// Get garbage collection count
    fn getGCCount(self: *LuaExecutor) u32 {
        _ = self;
        if (!lua.lua_enabled) return 0;
        
        // This is a simplified count - in reality we'd need to track this ourselves
        return 0;
    }
};

// Tests
test "LuaExecutor basic execution" {
    if (!lua.lua_enabled) return;
    
    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();
    
    const options = ExecutionOptions{};
    var executor = LuaExecutor.init(wrapper, allocator, options);
    
    var result = try executor.executeString("return 42");
    defer result.deinit();
    
    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqual(ScriptValue{ .integer = 42 }, result.values[0]);
}

test "LuaExecutor error handling" {
    if (!lua.lua_enabled) return;
    
    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();
    
    const options = ExecutionOptions{};
    var executor = LuaExecutor.init(wrapper, allocator, options);
    
    // Syntax error
    const syntax_result = executor.executeString("return 42 +");
    try std.testing.expectError(ExecutionError.SyntaxError, syntax_result);
    
    // Runtime error
    const runtime_result = executor.executeString("return unknown_variable");
    try std.testing.expectError(ExecutionError.RuntimeError, runtime_result);
}

test "LuaExecutor function calls" {
    if (!lua.lua_enabled) return;
    
    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();
    
    const options = ExecutionOptions{};
    var executor = LuaExecutor.init(wrapper, allocator, options);
    
    // Define a function
    _ = try executor.executeString("function add(a, b) return a + b end");
    
    // Call the function
    const args = [_]ScriptValue{
        ScriptValue{ .integer = 10 },
        ScriptValue{ .integer = 20 },
    };
    
    var result = try executor.callFunction("add", &args);
    defer result.deinit();
    
    try std.testing.expectEqual(@as(usize, 1), result.values.len);
    try std.testing.expectEqual(ScriptValue{ .integer = 30 }, result.values[0]);
}