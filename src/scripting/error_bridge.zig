// ABOUTME: Error handling bridge for scripting engines
// ABOUTME: Provides unified error representation across all script languages

const std = @import("std");

/// Script error codes
pub const ScriptErrorCode = enum {
    syntax_error,
    runtime_error,
    type_error,
    reference_error,
    range_error,
    memory_error,
    timeout_error,
    permission_error,
    module_error,
    unknown_error,
    
    pub fn toString(self: ScriptErrorCode) []const u8 {
        return switch (self) {
            .syntax_error => "SyntaxError",
            .runtime_error => "RuntimeError",
            .type_error => "TypeError",
            .reference_error => "ReferenceError",
            .range_error => "RangeError",
            .memory_error => "MemoryError",
            .timeout_error => "TimeoutError",
            .permission_error => "PermissionError",
            .module_error => "ModuleError",
            .unknown_error => "UnknownError",
        };
    }
};

/// Source location information
pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,
    
    pub fn format(self: SourceLocation, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}:{}:{}", .{ self.file, self.line, self.column });
    }
};

/// Stack trace frame
pub const StackFrame = struct {
    function_name: []const u8,
    location: ?SourceLocation,
    is_native: bool,
    
    pub fn format(self: StackFrame, allocator: std.mem.Allocator) ![]u8 {
        if (self.location) |loc| {
            const loc_str = try loc.format(allocator);
            defer allocator.free(loc_str);
            return std.fmt.allocPrint(allocator, "  at {s} ({s})", .{ self.function_name, loc_str });
        } else {
            return std.fmt.allocPrint(allocator, "  at {s} (native)", .{self.function_name});
        }
    }
};

/// Script error representation
pub const ScriptError = struct {
    code: ScriptErrorCode,
    message: []const u8,
    source_location: ?SourceLocation,
    stack_trace: ?[]const StackFrame,
    engine_error: ?[]const u8, // Original engine-specific error message
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        code: ScriptErrorCode,
        message: []const u8,
    ) !ScriptError {
        return ScriptError{
            .code = code,
            .message = try allocator.dupe(u8, message),
            .source_location = null,
            .stack_trace = null,
            .engine_error = null,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ScriptError) void {
        self.allocator.free(self.message);
        
        if (self.engine_error) |err| {
            self.allocator.free(err);
        }
        
        if (self.stack_trace) |frames| {
            for (frames) |frame| {
                self.allocator.free(frame.function_name);
                if (frame.location) |loc| {
                    self.allocator.free(loc.file);
                }
            }
            self.allocator.free(frames);
        }
        
        if (self.source_location) |loc| {
            self.allocator.free(loc.file);
        }
    }
    
    pub fn setSourceLocation(self: *ScriptError, file: []const u8, line: u32, column: u32) !void {
        if (self.source_location) |loc| {
            self.allocator.free(loc.file);
        }
        
        self.source_location = SourceLocation{
            .file = try self.allocator.dupe(u8, file),
            .line = line,
            .column = column,
        };
    }
    
    pub fn setEngineError(self: *ScriptError, engine_error: []const u8) !void {
        if (self.engine_error) |err| {
            self.allocator.free(err);
        }
        self.engine_error = try self.allocator.dupe(u8, engine_error);
    }
    
    pub fn addStackFrame(self: *ScriptError, frame: StackFrame) !void {
        const owned_frame = StackFrame{
            .function_name = try self.allocator.dupe(u8, frame.function_name),
            .location = if (frame.location) |loc| SourceLocation{
                .file = try self.allocator.dupe(u8, loc.file),
                .line = loc.line,
                .column = loc.column,
            } else null,
            .is_native = frame.is_native,
        };
        
        if (self.stack_trace) |frames| {
            var new_frames = try self.allocator.alloc(StackFrame, frames.len + 1);
            @memcpy(new_frames[0..frames.len], frames);
            new_frames[frames.len] = owned_frame;
            self.allocator.free(frames);
            self.stack_trace = new_frames;
        } else {
            var frames = try self.allocator.alloc(StackFrame, 1);
            frames[0] = owned_frame;
            self.stack_trace = frames;
        }
    }
    
    pub fn format(self: ScriptError, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        const writer = result.writer();
        
        // Error type and message
        try writer.print("{s}: {s}\n", .{ self.code.toString(), self.message });
        
        // Source location
        if (self.source_location) |loc| {
            const loc_str = try loc.format(allocator);
            defer allocator.free(loc_str);
            try writer.print("    at {s}\n", .{loc_str});
        }
        
        // Stack trace
        if (self.stack_trace) |frames| {
            try writer.writeAll("\nStack trace:\n");
            for (frames) |frame| {
                const frame_str = try frame.format(allocator);
                defer allocator.free(frame_str);
                try writer.print("{s}\n", .{frame_str});
            }
        }
        
        // Engine-specific error
        if (self.engine_error) |err| {
            try writer.print("\nEngine error: {s}\n", .{err});
        }
        
        return try result.toOwnedSlice();
    }
    
    /// Convert to a JSON-serializable structure
    pub fn toJson(self: ScriptError, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        
        try obj.put("code", .{ .string = self.code.toString() });
        try obj.put("message", .{ .string = self.message });
        
        if (self.source_location) |loc| {
            var loc_obj = std.json.ObjectMap.init(allocator);
            try loc_obj.put("file", .{ .string = loc.file });
            try loc_obj.put("line", .{ .integer = @intCast(loc.line) });
            try loc_obj.put("column", .{ .integer = @intCast(loc.column) });
            try obj.put("source_location", .{ .object = loc_obj });
        }
        
        if (self.stack_trace) |frames| {
            var frames_array = std.json.Array.init(allocator);
            for (frames) |frame| {
                var frame_obj = std.json.ObjectMap.init(allocator);
                try frame_obj.put("function", .{ .string = frame.function_name });
                try frame_obj.put("is_native", .{ .bool = frame.is_native });
                
                if (frame.location) |loc| {
                    var loc_obj = std.json.ObjectMap.init(allocator);
                    try loc_obj.put("file", .{ .string = loc.file });
                    try loc_obj.put("line", .{ .integer = @intCast(loc.line) });
                    try loc_obj.put("column", .{ .integer = @intCast(loc.column) });
                    try frame_obj.put("location", .{ .object = loc_obj });
                }
                
                try frames_array.append(.{ .object = frame_obj });
            }
            try obj.put("stack_trace", .{ .array = frames_array });
        }
        
        if (self.engine_error) |err| {
            try obj.put("engine_error", .{ .string = err });
        }
        
        return std.json.Value{ .object = obj };
    }
};

/// Error recovery strategies
pub const ErrorRecovery = enum {
    /// Stop execution immediately
    stop,
    /// Continue execution with default value
    continue_with_default,
    /// Retry the operation
    retry,
    /// Skip the current operation
    skip,
    /// Propagate to parent context
    propagate,
};

/// Error handler callback
pub const ErrorHandler = struct {
    context: *anyopaque,
    callback: *const fn (context: *anyopaque, err: *const ScriptError) ErrorRecovery,
    
    pub fn handle(self: *const ErrorHandler, err: *const ScriptError) ErrorRecovery {
        return self.callback(self.context, err);
    }
};

// Tests
test "ScriptError creation and formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var err = try ScriptError.init(allocator, .type_error, "Cannot read property 'foo' of undefined");
    defer err.deinit();
    
    try err.setSourceLocation("test.js", 10, 5);
    
    try err.addStackFrame(.{
        .function_name = "doSomething",
        .location = .{
            .file = "test.js",
            .line = 10,
            .column = 5,
        },
        .is_native = false,
    });
    
    try err.addStackFrame(.{
        .function_name = "main",
        .location = .{
            .file = "test.js",
            .line = 20,
            .column = 1,
        },
        .is_native = false,
    });
    
    const formatted = try err.format(allocator);
    defer allocator.free(formatted);
    
    try testing.expect(std.mem.indexOf(u8, formatted, "TypeError") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Cannot read property 'foo' of undefined") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "test.js:10:5") != null);
}

test "ScriptError JSON serialization" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var err = try ScriptError.init(allocator, .syntax_error, "Unexpected token");
    defer err.deinit();
    
    try err.setSourceLocation("script.lua", 5, 10);
    try err.setEngineError("unexpected symbol near ')'");
    
    const json_value = try err.toJson(allocator);
    defer json_value.object.deinit();
    
    try testing.expectEqualStrings(json_value.object.get("code").?.string, "SyntaxError");
    try testing.expectEqualStrings(json_value.object.get("message").?.string, "Unexpected token");
    
    const loc = json_value.object.get("source_location").?.object;
    try testing.expectEqualStrings(loc.get("file").?.string, "script.lua");
    try testing.expectEqual(@as(i64, 5), loc.get("line").?.integer);
    try testing.expectEqual(@as(i64, 10), loc.get("column").?.integer);
}

test "ScriptErrorCode string conversion" {
    const testing = std.testing;
    
    try testing.expectEqualStrings("SyntaxError", ScriptErrorCode.syntax_error.toString());
    try testing.expectEqualStrings("TypeError", ScriptErrorCode.type_error.toString());
    try testing.expectEqualStrings("RuntimeError", ScriptErrorCode.runtime_error.toString());
    try testing.expectEqualStrings("MemoryError", ScriptErrorCode.memory_error.toString());
}