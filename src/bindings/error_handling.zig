// ABOUTME: Structured error handling system for C-API with detailed error contexts
// ABOUTME: Provides error tracking, formatting, and reporting for external language integration

const std = @import("std");

// Maximum error message length
pub const MAX_ERROR_MESSAGE_LEN = 512;
pub const MAX_ERROR_CONTEXT_LEN = 256;
pub const MAX_ERROR_STACK_DEPTH = 16;

// Error severity levels
pub const ErrorSeverity = enum(c_int) {
    info = 0,
    warning = 1,
    error = 2,
    critical = 3,
    fatal = 4,
    
    pub fn toString(self: ErrorSeverity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .warning => "WARNING",
            .error => "ERROR", 
            .critical => "CRITICAL",
            .fatal => "FATAL",
        };
    }
};

// Error categories for better organization
pub const ErrorCategory = enum(c_int) {
    general = 0,
    memory = 1,
    network = 2,
    validation = 3,
    agent = 4,
    tool = 5,
    workflow = 6,
    provider = 7,
    json = 8,
    file_io = 9,
    permission = 10,
    timeout = 11,
    
    pub fn toString(self: ErrorCategory) []const u8 {
        return switch (self) {
            .general => "GENERAL",
            .memory => "MEMORY",
            .network => "NETWORK",
            .validation => "VALIDATION",
            .agent => "AGENT",
            .tool => "TOOL",
            .workflow => "WORKFLOW",
            .provider => "PROVIDER",
            .json => "JSON",
            .file_io => "FILE_IO",
            .permission => "PERMISSION",
            .timeout => "TIMEOUT",
        };
    }
};

// Detailed error information
pub const ErrorInfo = struct {
    code: c_int,
    category: ErrorCategory,
    severity: ErrorSeverity,
    message: [MAX_ERROR_MESSAGE_LEN]u8,
    context: [MAX_ERROR_CONTEXT_LEN]u8,
    timestamp: i64,
    thread_id: u32,
    source_location: ?SourceLocation = null,
    
    pub const SourceLocation = struct {
        file: []const u8,
        function: []const u8,
        line: u32,
    };
    
    pub fn init(
        code: c_int,
        category: ErrorCategory,
        severity: ErrorSeverity,
        message: []const u8,
        context: []const u8,
    ) ErrorInfo {
        var error_info = ErrorInfo{
            .code = code,
            .category = category,
            .severity = severity,
            .message = [_]u8{0} ** MAX_ERROR_MESSAGE_LEN,
            .context = [_]u8{0} ** MAX_ERROR_CONTEXT_LEN,
            .timestamp = std.time.milliTimestamp(),
            .thread_id = std.Thread.getCurrentId(),
        };
        
        // Copy message with bounds checking
        const msg_len = @min(message.len, MAX_ERROR_MESSAGE_LEN - 1);
        @memcpy(error_info.message[0..msg_len], message[0..msg_len]);
        error_info.message[msg_len] = 0;
        
        // Copy context with bounds checking  
        const ctx_len = @min(context.len, MAX_ERROR_CONTEXT_LEN - 1);
        @memcpy(error_info.context[0..ctx_len], context[0..ctx_len]);
        error_info.context[ctx_len] = 0;
        
        return error_info;
    }
    
    pub fn setSourceLocation(self: *ErrorInfo, file: []const u8, function: []const u8, line: u32) void {
        self.source_location = SourceLocation{
            .file = file,
            .function = function,
            .line = line,
        };
    }
    
    pub fn formatMessage(self: *const ErrorInfo, allocator: std.mem.Allocator) ![]u8 {
        const message_str = std.mem.sliceTo(&self.message, 0);
        const context_str = std.mem.sliceTo(&self.context, 0);
        
        if (self.source_location) |loc| {
            return try std.fmt.allocPrint(allocator,
                "[{s}:{s}] {s} in {s}: {s} (context: {s}) at {s}:{s}:{d}",
                .{
                    self.category.toString(),
                    self.severity.toString(),
                    message_str,
                    loc.function,
                    context_str,
                    loc.file,
                    loc.function,
                    loc.line,
                }
            );
        } else {
            return try std.fmt.allocPrint(allocator,
                "[{s}:{s}] {s} (context: {s})",
                .{
                    self.category.toString(),
                    self.severity.toString(),
                    message_str,
                    context_str,
                }
            );
        }
    }
};

// Error stack for tracking error chains
pub const ErrorStack = struct {
    errors: [MAX_ERROR_STACK_DEPTH]ErrorInfo,
    count: usize,
    mutex: std.Thread.Mutex,
    
    pub fn init() ErrorStack {
        return ErrorStack{
            .errors = [_]ErrorInfo{undefined} ** MAX_ERROR_STACK_DEPTH,
            .count = 0,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn push(self: *ErrorStack, error_info: ErrorInfo) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.count < MAX_ERROR_STACK_DEPTH) {
            self.errors[self.count] = error_info;
            self.count += 1;
        } else {
            // Shift errors down and add new one at top
            std.mem.copyForwards(ErrorInfo, self.errors[0..MAX_ERROR_STACK_DEPTH-1], self.errors[1..MAX_ERROR_STACK_DEPTH]);
            self.errors[MAX_ERROR_STACK_DEPTH - 1] = error_info;
        }
    }
    
    pub fn pop(self: *ErrorStack) ?ErrorInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.count > 0) {
            self.count -= 1;
            return self.errors[self.count];
        }
        return null;
    }
    
    pub fn peek(self: *ErrorStack) ?ErrorInfo {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.count > 0) {
            return self.errors[self.count - 1];
        }
        return null;
    }
    
    pub fn clear(self: *ErrorStack) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count = 0;
    }
    
    pub fn getCount(self: *ErrorStack) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
    
    pub fn formatStack(self: *ErrorStack, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var stack_msg = std.ArrayList(u8).init(allocator);
        const writer = stack_msg.writer();
        
        try writer.writeAll("Error Stack Trace:\n");
        
        var i: usize = self.count;
        while (i > 0) {
            i -= 1;
            const error_info = self.errors[i];
            const formatted = try error_info.formatMessage(allocator);
            defer allocator.free(formatted);
            
            try writer.print("  #{d}: {s}\n", .{ self.count - i, formatted });
        }
        
        return try stack_msg.toOwnedSlice();
    }
};

// Global error handling state
var global_error_stack: ErrorStack = undefined;
var global_error_handler_initialized: bool = false;

// Error handler callback type
pub const ErrorHandlerCallback = *const fn (error_info: *const ErrorInfo) callconv(.C) void;
var global_error_callback: ?ErrorHandlerCallback = null;

// Initialize error handling system
pub fn initErrorHandling() void {
    if (!global_error_handler_initialized) {
        global_error_stack = ErrorStack.init();
        global_error_handler_initialized = true;
    }
}

// Cleanup error handling system
pub fn deinitErrorHandling() void {
    if (global_error_handler_initialized) {
        global_error_stack.clear();
        global_error_callback = null;
        global_error_handler_initialized = false;
    }
}

// Set global error callback
pub fn setErrorCallback(callback: ErrorHandlerCallback) void {
    global_error_callback = callback;
}

// Report an error
pub fn reportError(
    code: c_int,
    category: ErrorCategory,
    severity: ErrorSeverity,
    message: []const u8,
    context: []const u8,
) void {
    if (!global_error_handler_initialized) {
        initErrorHandling();
    }
    
    const error_info = ErrorInfo.init(code, category, severity, message, context);
    
    // Add to stack
    global_error_stack.push(error_info);
    
    // Call callback if set
    if (global_error_callback) |callback| {
        callback(&error_info);
    }
    
    // Log critical/fatal errors
    if (severity == .critical or severity == .fatal) {
        const msg_str = std.mem.sliceTo(&error_info.message, 0);
        const ctx_str = std.mem.sliceTo(&error_info.context, 0);
        std.log.err("{s}: {s} (context: {s})", .{ severity.toString(), msg_str, ctx_str });
    }
}

// Convenience functions for common error types
pub fn reportMemoryError(message: []const u8, context: []const u8) void {
    reportError(-3, .memory, .error, message, context);
}

pub fn reportValidationError(message: []const u8, context: []const u8) void {
    reportError(-2, .validation, .error, message, context);
}

pub fn reportAgentError(message: []const u8, context: []const u8) void {
    reportError(-5, .agent, .error, message, context);
}

pub fn reportToolError(message: []const u8, context: []const u8) void {
    reportError(-6, .tool, .error, message, context);
}

pub fn reportWorkflowError(message: []const u8, context: []const u8) void {
    reportError(-7, .workflow, .error, message, context);
}

pub fn reportJsonError(message: []const u8, context: []const u8) void {
    reportError(-9, .json, .error, message, context);
}

pub fn reportTimeoutError(message: []const u8, context: []const u8) void {
    reportError(-10, .timeout, .error, message, context);
}

// Get last error
pub fn getLastError() ?ErrorInfo {
    if (!global_error_handler_initialized) {
        return null;
    }
    return global_error_stack.peek();
}

// Get error count
pub fn getErrorCount() usize {
    if (!global_error_handler_initialized) {
        return 0;
    }
    return global_error_stack.getCount();
}

// Clear all errors
pub fn clearErrors() void {
    if (global_error_handler_initialized) {
        global_error_stack.clear();
    }
}

// Format error stack as JSON
pub fn formatErrorStackAsJson(allocator: std.mem.Allocator) ![]u8 {
    if (!global_error_handler_initialized) {
        return try allocator.dupe(u8, "[]");
    }
    
    var errors_array = std.ArrayList(std.json.Value).init(allocator);
    defer errors_array.deinit();
    
    global_error_stack.mutex.lock();
    defer global_error_stack.mutex.unlock();
    
    for (0..global_error_stack.count) |i| {
        const error_info = global_error_stack.errors[i];
        
        var error_obj = std.json.ObjectMap.init(allocator);
        try error_obj.put("code", .{ .integer = @as(i64, @intCast(error_info.code)) });
        try error_obj.put("category", .{ .string = error_info.category.toString() });
        try error_obj.put("severity", .{ .string = error_info.severity.toString() });
        try error_obj.put("message", .{ .string = std.mem.sliceTo(&error_info.message, 0) });
        try error_obj.put("context", .{ .string = std.mem.sliceTo(&error_info.context, 0) });
        try error_obj.put("timestamp", .{ .integer = error_info.timestamp });
        try error_obj.put("thread_id", .{ .integer = @as(i64, @intCast(error_info.thread_id)) });
        
        if (error_info.source_location) |loc| {
            var location_obj = std.json.ObjectMap.init(allocator);
            try location_obj.put("file", .{ .string = loc.file });
            try location_obj.put("function", .{ .string = loc.function });
            try location_obj.put("line", .{ .integer = @as(i64, @intCast(loc.line)) });
            try error_obj.put("source_location", .{ .object = location_obj });
        }
        
        try errors_array.append(.{ .object = error_obj });
    }
    
    return try std.json.stringifyAlloc(allocator, std.json.Value{ .array = std.json.Array.fromOwnedSlice(allocator, try errors_array.toOwnedSlice()) }, .{});
}

// Error handling macros for convenience
pub fn REPORT_ERROR(comptime code: c_int, comptime category: ErrorCategory, comptime severity: ErrorSeverity, comptime message: []const u8, context: []const u8) void {
    reportError(code, category, severity, message, context);
}

// Tests
test "error info creation" {
    const error_info = ErrorInfo.init(-5, .agent, .error, "Test error", "Test context");
    
    try std.testing.expectEqual(@as(c_int, -5), error_info.code);
    try std.testing.expectEqual(ErrorCategory.agent, error_info.category);
    try std.testing.expectEqual(ErrorSeverity.error, error_info.severity);
    
    const message_str = std.mem.sliceTo(&error_info.message, 0);
    try std.testing.expectEqualStrings("Test error", message_str);
}

test "error stack operations" {
    var stack = ErrorStack.init();
    
    try std.testing.expectEqual(@as(usize, 0), stack.getCount());
    
    const error1 = ErrorInfo.init(-1, .general, .error, "Error 1", "Context 1");
    const error2 = ErrorInfo.init(-2, .memory, .critical, "Error 2", "Context 2");
    
    stack.push(error1);
    stack.push(error2);
    
    try std.testing.expectEqual(@as(usize, 2), stack.getCount());
    
    const popped = stack.pop();
    try std.testing.expect(popped != null);
    try std.testing.expectEqual(@as(c_int, -2), popped.?.code);
    
    try std.testing.expectEqual(@as(usize, 1), stack.getCount());
}

test "error handling system" {
    initErrorHandling();
    defer deinitErrorHandling();
    
    reportError(-10, .timeout, .warning, "Timeout occurred", "Function: test_func");
    
    try std.testing.expectEqual(@as(usize, 1), getErrorCount());
    
    const last_error = getLastError();
    try std.testing.expect(last_error != null);
    try std.testing.expectEqual(@as(c_int, -10), last_error.?.code);
    
    clearErrors();
    try std.testing.expectEqual(@as(usize, 0), getErrorCount());
}