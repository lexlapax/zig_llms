// ABOUTME: Structured logging hooks for comprehensive execution tracking
// ABOUTME: Provides configurable logging with multiple output formats and filtering

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;
const context_mod = @import("context.zig");
const EnhancedHookContext = context_mod.EnhancedHookContext;

// Log levels
pub const LogLevel = enum(u8) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,
    fatal = 5,
    
    pub fn toString(self: LogLevel) []const u8 {
        return @tagName(self);
    }
    
    pub fn fromString(str: []const u8) ?LogLevel {
        return std.meta.stringToEnum(LogLevel, str);
    }
    
    pub fn isEnabled(self: LogLevel, min_level: LogLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(min_level);
    }
};

// Log entry structure
pub const LogEntry = struct {
    timestamp: i64,
    level: LogLevel,
    hook_point: HookPoint,
    hook_id: []const u8,
    agent_id: ?[]const u8 = null,
    message: []const u8,
    fields: std.StringHashMap(std.json.Value),
    duration_ms: ?i64 = null,
    error_info: ?ErrorInfo = null,
    
    pub const ErrorInfo = struct {
        error_type: []const u8,
        message: []const u8,
        stack_trace: ?[]const u8 = null,
    };
    
    pub fn init(allocator: std.mem.Allocator, level: LogLevel, message: []const u8) LogEntry {
        return .{
            .timestamp = std.time.milliTimestamp(),
            .level = level,
            .hook_point = .custom,
            .hook_id = "",
            .message = message,
            .fields = std.StringHashMap(std.json.Value).init(allocator),
        };
    }
    
    pub fn deinit(self: *LogEntry) void {
        self.fields.deinit();
    }
    
    pub fn addField(self: *LogEntry, key: []const u8, value: std.json.Value) !void {
        try self.fields.put(key, value);
    }
};

// Log formatter interface
pub const LogFormatter = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        format: *const fn (formatter: *LogFormatter, entry: *const LogEntry, writer: anytype) anyerror!void,
        deinit: ?*const fn (formatter: *LogFormatter) void = null,
    };
    
    pub fn format(self: *LogFormatter, entry: *const LogEntry, writer: anytype) !void {
        return self.vtable.format(self, entry, writer);
    }
    
    pub fn deinit(self: *LogFormatter) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// JSON formatter
pub const JsonFormatter = struct {
    formatter: LogFormatter,
    pretty: bool,
    include_metadata: bool,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, pretty: bool, include_metadata: bool) !*JsonFormatter {
        const self = try allocator.create(JsonFormatter);
        self.* = .{
            .formatter = .{
                .vtable = &.{
                    .format = format,
                    .deinit = deinit,
                },
            },
            .pretty = pretty,
            .include_metadata = include_metadata,
            .allocator = allocator,
        };
        return self;
    }
    
    fn format(formatter: *LogFormatter, entry: *const LogEntry, writer: anytype) !void {
        const self = @fieldParentPtr(JsonFormatter, "formatter", formatter);
        
        var obj = std.json.ObjectMap.init(self.allocator);
        defer obj.deinit();
        
        try obj.put("timestamp", .{ .integer = entry.timestamp });
        try obj.put("level", .{ .string = entry.level.toString() });
        try obj.put("message", .{ .string = entry.message });
        
        if (self.include_metadata) {
            try obj.put("hook_point", .{ .string = entry.hook_point.toString() });
            try obj.put("hook_id", .{ .string = entry.hook_id });
            
            if (entry.agent_id) |agent_id| {
                try obj.put("agent_id", .{ .string = agent_id });
            }
            
            if (entry.duration_ms) |duration| {
                try obj.put("duration_ms", .{ .integer = duration });
            }
        }
        
        // Add custom fields
        var field_iter = entry.fields.iterator();
        while (field_iter.next()) |field| {
            try obj.put(field.key_ptr.*, field.value_ptr.*);
        }
        
        // Add error info if present
        if (entry.error_info) |err_info| {
            var err_obj = std.json.ObjectMap.init(self.allocator);
            try err_obj.put("type", .{ .string = err_info.error_type });
            try err_obj.put("message", .{ .string = err_info.message });
            if (err_info.stack_trace) |trace| {
                try err_obj.put("stack_trace", .{ .string = trace });
            }
            try obj.put("error", .{ .object = err_obj });
        }
        
        const options = if (self.pretty) std.json.StringifyOptions{ .whitespace = .indent_2 } else .{};
        try std.json.stringify(std.json.Value{ .object = obj }, options, writer);
        try writer.writeByte('\n');
    }
    
    fn deinit(formatter: *LogFormatter) void {
        const self = @fieldParentPtr(JsonFormatter, "formatter", formatter);
        self.allocator.destroy(self);
    }
};

// Text formatter
pub const TextFormatter = struct {
    formatter: LogFormatter,
    format_template: []const u8,
    use_colors: bool,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        format_template: []const u8,
        use_colors: bool,
    ) !*TextFormatter {
        const self = try allocator.create(TextFormatter);
        self.* = .{
            .formatter = .{
                .vtable = &.{
                    .format = format,
                    .deinit = deinit,
                },
            },
            .format_template = format_template,
            .use_colors = use_colors,
            .allocator = allocator,
        };
        return self;
    }
    
    fn format(formatter: *LogFormatter, entry: *const LogEntry, writer: anytype) !void {
        const self = @fieldParentPtr(TextFormatter, "formatter", formatter);
        
        // Format timestamp
        const timestamp_sec = @divTrunc(entry.timestamp, 1000);
        const timestamp_ms = @mod(entry.timestamp, 1000);
        
        // Apply color if enabled
        if (self.use_colors) {
            const color = switch (entry.level) {
                .trace => "\x1b[90m", // Gray
                .debug => "\x1b[36m", // Cyan
                .info => "\x1b[32m",  // Green
                .warn => "\x1b[33m",  // Yellow
                .err => "\x1b[31m",   // Red
                .fatal => "\x1b[35m", // Magenta
            };
            try writer.writeAll(color);
        }
        
        // Default format: [timestamp] LEVEL [hook_id@hook_point] message {fields}
        try writer.print("[{d}.{d:0>3}] {s: <5} ", .{ timestamp_sec, timestamp_ms, entry.level.toString() });
        
        if (entry.hook_id.len > 0) {
            try writer.print("[{s}@{s}] ", .{ entry.hook_id, entry.hook_point.toString() });
        }
        
        try writer.writeAll(entry.message);
        
        // Add fields
        if (entry.fields.count() > 0) {
            try writer.writeAll(" {");
            var first = true;
            var iter = entry.fields.iterator();
            while (iter.next()) |field| {
                if (!first) try writer.writeAll(", ");
                try writer.print("{s}=", .{field.key_ptr.*});
                try std.json.stringify(field.value_ptr.*, .{}, writer);
                first = false;
            }
            try writer.writeByte('}');
        }
        
        // Reset color
        if (self.use_colors) {
            try writer.writeAll("\x1b[0m");
        }
        
        try writer.writeByte('\n');
    }
    
    fn deinit(formatter: *LogFormatter) void {
        const self = @fieldParentPtr(TextFormatter, "formatter", formatter);
        self.allocator.destroy(self);
    }
};

// Log writer interface
pub const LogWriter = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        write: *const fn (writer: *LogWriter, entry: *const LogEntry) anyerror!void,
        flush: ?*const fn (writer: *LogWriter) anyerror!void = null,
        deinit: ?*const fn (writer: *LogWriter) void = null,
    };
    
    pub fn write(self: *LogWriter, entry: *const LogEntry) !void {
        return self.vtable.write(self, entry);
    }
    
    pub fn flush(self: *LogWriter) !void {
        if (self.vtable.flush) |flush_fn| {
            try flush_fn(self);
        }
    }
    
    pub fn deinit(self: *LogWriter) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// File log writer
pub const FileLogWriter = struct {
    writer: LogWriter,
    file: std.fs.File,
    formatter: *LogFormatter,
    buffer: std.ArrayList(u8),
    buffer_size: usize,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        formatter: *LogFormatter,
        buffer_size: usize,
    ) !*FileLogWriter {
        const file = try std.fs.cwd().createFile(file_path, .{ .truncate = false });
        errdefer file.close();
        
        // Seek to end
        try file.seekFromEnd(0);
        
        const self = try allocator.create(FileLogWriter);
        self.* = .{
            .writer = .{
                .vtable = &.{
                    .write = write,
                    .flush = flush,
                    .deinit = deinit,
                },
            },
            .file = file,
            .formatter = formatter,
            .buffer = std.ArrayList(u8).init(allocator),
            .buffer_size = buffer_size,
            .mutex = .{},
            .allocator = allocator,
        };
        
        try self.buffer.ensureTotalCapacity(buffer_size);
        
        return self;
    }
    
    fn write(writer: *LogWriter, entry: *const LogEntry) !void {
        const self = @fieldParentPtr(FileLogWriter, "writer", writer);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const initial_len = self.buffer.items.len;
        try self.formatter.format(self.formatter, entry, self.buffer.writer());
        
        // Flush if buffer is full
        if (self.buffer.items.len >= self.buffer_size) {
            try self.file.writeAll(self.buffer.items);
            self.buffer.clearRetainingCapacity();
        }
    }
    
    fn flush(writer: *LogWriter) !void {
        const self = @fieldParentPtr(FileLogWriter, "writer", writer);
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.buffer.items.len > 0) {
            try self.file.writeAll(self.buffer.items);
            self.buffer.clearRetainingCapacity();
        }
    }
    
    fn deinit(writer: *LogWriter) void {
        const self = @fieldParentPtr(FileLogWriter, "writer", writer);
        
        self.flush(writer) catch {};
        self.file.close();
        self.buffer.deinit();
        self.allocator.destroy(self);
    }
};

// Console log writer
pub const ConsoleLogWriter = struct {
    writer: LogWriter,
    formatter: *LogFormatter,
    stderr_for_errors: bool,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        formatter: *LogFormatter,
        stderr_for_errors: bool,
    ) !*ConsoleLogWriter {
        const self = try allocator.create(ConsoleLogWriter);
        self.* = .{
            .writer = .{
                .vtable = &.{
                    .write = write,
                    .deinit = deinit,
                },
            },
            .formatter = formatter,
            .stderr_for_errors = stderr_for_errors,
            .allocator = allocator,
        };
        return self;
    }
    
    fn write(writer: *LogWriter, entry: *const LogEntry) !void {
        const self = @fieldParentPtr(ConsoleLogWriter, "writer", writer);
        
        const out = if (self.stderr_for_errors and entry.level.isEnabled(.err))
            std.io.getStdErr().writer()
        else
            std.io.getStdOut().writer();
        
        try self.formatter.format(self.formatter, entry, out);
    }
    
    fn deinit(writer: *LogWriter) void {
        const self = @fieldParentPtr(ConsoleLogWriter, "writer", writer);
        self.allocator.destroy(self);
    }
};

// Logging hook
pub const LoggingHook = struct {
    hook: Hook,
    config: LoggingConfig,
    writers: std.ArrayList(*LogWriter),
    allocator: std.mem.Allocator,
    
    pub const LoggingConfig = struct {
        level: LogLevel = .info,
        include_inputs: bool = false,
        include_outputs: bool = false,
        include_metadata: bool = true,
        include_timing: bool = true,
        max_field_length: ?usize = 1000,
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        config: LoggingConfig,
    ) !*LoggingHook {
        const self = try allocator.create(LoggingHook);
        
        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = execute,
            .deinit = hookDeinit,
        };
        
        self.* = .{
            .hook = .{
                .id = id,
                .name = "Logging Hook",
                .description = "Structured logging for hook execution",
                .vtable = vtable,
                .priority = .highest, // Run early to capture all activity
                .supported_points = &[_]HookPoint{.custom}, // Supports all points
                .config = .{ .integer = @intFromPtr(self) },
            },
            .config = config,
            .writers = std.ArrayList(*LogWriter).init(allocator),
            .allocator = allocator,
        };
        
        return self;
    }
    
    pub fn addWriter(self: *LoggingHook, writer: *LogWriter) !void {
        try self.writers.append(writer);
    }
    
    fn hookDeinit(hook: *Hook) void {
        const self = @as(*LoggingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
        
        for (self.writers.items) |writer| {
            writer.deinit();
        }
        self.writers.deinit();
        
        self.allocator.destroy(hook.vtable);
        self.allocator.destroy(self);
    }
    
    fn execute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @as(*LoggingHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
        
        const start_time = std.time.milliTimestamp();
        
        // Create log entry
        var entry = LogEntry.init(self.allocator, .info, "Hook execution started");
        defer entry.deinit();
        
        entry.hook_point = context.point;
        entry.hook_id = hook.id;
        
        if (context.agent) |agent| {
            if (agent.state.metadata.get("agent_name")) |name| {
                entry.agent_id = name.string;
            }
        }
        
        // Add context metadata
        if (self.config.include_metadata) {
            try entry.addField("hook_index", .{ .integer = @as(i64, @intCast(context.hook_index)) });
            try entry.addField("total_hooks", .{ .integer = @as(i64, @intCast(context.total_hooks)) });
        }
        
        // Add input data if configured
        if (self.config.include_inputs and context.input_data != null) {
            const truncated = try self.truncateValue(context.input_data.?);
            try entry.addField("input", truncated);
        }
        
        // Log start
        if (self.config.level.isEnabled(entry.level)) {
            for (self.writers.items) |writer| {
                try writer.write(&entry);
            }
        }
        
        // Create completion entry
        var completion_entry = LogEntry.init(self.allocator, .info, "Hook execution completed");
        defer completion_entry.deinit();
        
        completion_entry.hook_point = context.point;
        completion_entry.hook_id = hook.id;
        completion_entry.agent_id = entry.agent_id;
        
        if (self.config.include_timing) {
            const duration = std.time.milliTimestamp() - start_time;
            completion_entry.duration_ms = duration;
            try completion_entry.addField("duration_ms", .{ .integer = duration });
        }
        
        // Note: We can't capture the actual output here since we're not wrapping the hook
        // This would need to be done at a higher level in the hook chain
        
        // Log completion
        if (self.config.level.isEnabled(completion_entry.level)) {
            for (self.writers.items) |writer| {
                try writer.write(&completion_entry);
            }
        }
        
        return HookResult{ .continue_processing = true };
    }
    
    fn truncateValue(self: *LoggingHook, value: std.json.Value) !std.json.Value {
        if (self.config.max_field_length == null) {
            return value;
        }
        
        const max_len = self.config.max_field_length.?;
        
        switch (value) {
            .string => |s| {
                if (s.len > max_len) {
                    const truncated = try std.fmt.allocPrint(self.allocator, "{s}... (truncated)", .{s[0..max_len]});
                    return .{ .string = truncated };
                }
                return value;
            },
            else => return value,
        }
    }
};

// Structured logger for general use
pub const StructuredLogger = struct {
    writers: std.ArrayList(*LogWriter),
    min_level: LogLevel,
    default_fields: std.StringHashMap(std.json.Value),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, min_level: LogLevel) StructuredLogger {
        return .{
            .writers = std.ArrayList(*LogWriter).init(allocator),
            .min_level = min_level,
            .default_fields = std.StringHashMap(std.json.Value).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *StructuredLogger) void {
        for (self.writers.items) |writer| {
            writer.deinit();
        }
        self.writers.deinit();
        self.default_fields.deinit();
    }
    
    pub fn addWriter(self: *StructuredLogger, writer: *LogWriter) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.writers.append(writer);
    }
    
    pub fn addDefaultField(self: *StructuredLogger, key: []const u8, value: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.default_fields.put(key, value);
    }
    
    pub fn log(self: *StructuredLogger, level: LogLevel, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        if (!level.isEnabled(self.min_level)) {
            return;
        }
        
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var entry = LogEntry.init(self.allocator, level, message);
        defer entry.deinit();
        
        // Add default fields
        var iter = self.default_fields.iterator();
        while (iter.next()) |field| {
            try entry.addField(field.key_ptr.*, field.value_ptr.*);
        }
        
        // Add provided fields
        if (fields) |f| {
            var field_iter = f.iterator();
            while (field_iter.next()) |field| {
                try entry.addField(field.key_ptr.*, field.value_ptr.*);
            }
        }
        
        // Write to all writers
        for (self.writers.items) |writer| {
            try writer.write(&entry);
        }
    }
    
    // Convenience methods
    pub fn trace(self: *StructuredLogger, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        try self.log(.trace, message, fields);
    }
    
    pub fn debug(self: *StructuredLogger, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        try self.log(.debug, message, fields);
    }
    
    pub fn info(self: *StructuredLogger, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        try self.log(.info, message, fields);
    }
    
    pub fn warn(self: *StructuredLogger, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        try self.log(.warn, message, fields);
    }
    
    pub fn err(self: *StructuredLogger, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        try self.log(.err, message, fields);
    }
    
    pub fn fatal(self: *StructuredLogger, message: []const u8, fields: ?std.StringHashMap(std.json.Value)) !void {
        try self.log(.fatal, message, fields);
    }
};

// Builder for logging hook
pub fn createLoggingHook(
    allocator: std.mem.Allocator,
    id: []const u8,
    config: LoggingHook.LoggingConfig,
) !*Hook {
    const logging_hook = try LoggingHook.init(allocator, id, config);
    
    // Add default console writer
    const formatter = try TextFormatter.init(allocator, "", true);
    const writer = try ConsoleLogWriter.init(allocator, &formatter.formatter, true);
    try logging_hook.addWriter(&writer.writer);
    
    return &logging_hook.hook;
}

// Tests
test "log entry" {
    const allocator = std.testing.allocator;
    
    var entry = LogEntry.init(allocator, .info, "Test message");
    defer entry.deinit();
    
    try entry.addField("user", .{ .string = "test_user" });
    try entry.addField("count", .{ .integer = 42 });
    
    try std.testing.expectEqual(LogLevel.info, entry.level);
    try std.testing.expectEqualStrings("Test message", entry.message);
    try std.testing.expectEqual(@as(usize, 2), entry.fields.count());
}

test "json formatter" {
    const allocator = std.testing.allocator;
    
    const formatter = try JsonFormatter.init(allocator, false, true);
    defer formatter.formatter.deinit();
    
    var entry = LogEntry.init(allocator, .info, "Test log");
    defer entry.deinit();
    
    entry.hook_id = "test_hook";
    entry.hook_point = .agent_before_run;
    try entry.addField("test_field", .{ .string = "test_value" });
    
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try formatter.formatter.format(&formatter.formatter, &entry, buffer.writer());
    
    const output = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "\"level\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"message\":\"Test log\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"test_field\":\"test_value\"") != null);
}

test "structured logger" {
    const allocator = std.testing.allocator;
    
    var logger = StructuredLogger.init(allocator, .info);
    defer logger.deinit();
    
    // Add default field
    try logger.addDefaultField("service", .{ .string = "test_service" });
    
    // Create in-memory writer for testing
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    const InMemoryWriter = struct {
        writer: LogWriter,
        buffer: *std.ArrayList(u8),
        formatter: *LogFormatter,
        
        fn write(w: *LogWriter, entry: *const LogEntry) !void {
            const self = @fieldParentPtr(@This(), "writer", w);
            try self.formatter.format(self.formatter, entry, self.buffer.writer());
        }
    };
    
    const formatter = try JsonFormatter.init(allocator, false, false);
    defer formatter.formatter.deinit();
    
    const mem_writer = try allocator.create(InMemoryWriter);
    mem_writer.* = .{
        .writer = .{
            .vtable = &.{
                .write = InMemoryWriter.write,
            },
        },
        .buffer = &buffer,
        .formatter = &formatter.formatter,
    };
    defer allocator.destroy(mem_writer);
    
    try logger.addWriter(&mem_writer.writer);
    
    // Log a message
    var fields = std.StringHashMap(std.json.Value).init(allocator);
    defer fields.deinit();
    try fields.put("user_id", .{ .integer = 123 });
    
    try logger.info("User logged in", fields);
    
    const output = buffer.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "\"message\":\"User logged in\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"service\":\"test_service\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"user_id\":123") != null);
}