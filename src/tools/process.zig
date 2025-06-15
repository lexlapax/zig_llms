// ABOUTME: Process execution tool for running system commands and external programs
// ABOUTME: Provides secure process execution with safety controls, timeouts, and output capture

const std = @import("std");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;

// Process execution types
pub const ProcessMode = enum {
    execute,     // Run command and wait for completion
    spawn,       // Start process in background
    shell,       // Execute via shell
    script,      // Execute script file
    
    pub fn toString(self: ProcessMode) []const u8 {
        return @tagName(self);
    }
};

// Process tool error types
pub const ProcessToolError = error{
    CommandNotAllowed,
    InvalidCommand,
    ExecutionFailed,
    Timeout,
    UnsafeOperation,
    PermissionDenied,
    CommandNotFound,
};

// Safety configuration for process execution
pub const ProcessSafetyConfig = struct {
    allowed_commands: []const []const u8 = &[_][]const u8{},
    blocked_commands: []const []const u8 = &[_][]const u8{ "rm", "del", "format", "mkfs", "dd" },
    allow_shell_execution: bool = false,
    allow_background_processes: bool = false,
    timeout_seconds: u32 = 30,
    max_output_size: usize = 1024 * 1024, // 1MB
    sandbox_directory: ?[]const u8 = null,
    env_whitelist: []const []const u8 = &[_][]const u8{ "PATH", "HOME", "USER" },
    max_args: usize = 100,
    read_only: bool = false,
};

// Process result structure
pub const ProcessResult = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    duration_ms: u64,
    pid: ?std.os.pid_t = null,
    
    pub fn deinit(self: *ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

// Process execution tool
pub const ProcessTool = struct {
    base: BaseTool,
    safety_config: ProcessSafetyConfig,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, safety_config: ProcessSafetyConfig) !*ProcessTool {
        const self = try allocator.create(ProcessTool);
        
        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "process_execution",
            .description = "Execute system commands and external programs",
            .version = "1.0.0",
            .category = .system,
            .capabilities = &[_][]const u8{ "command_execution", "process_management", "script_execution" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Execute a simple command",
                    .input = .{ .object = try createExampleInput(allocator, "execute", "echo", &[_][]const u8{"Hello World"}) },
                    .output = .{ .object = try createExampleOutput(allocator, true, 0, "Hello World\n") },
                },
                .{
                    .description = "List directory contents",
                    .input = .{ .object = try createExampleInput(allocator, "execute", "ls", &[_][]const u8{"-la"}) },
                    .output = .{ .object = try createExampleOutput(allocator, true, 0, "Directory listing...") },
                },
            },
        };
        
        self.* = .{
            .base = BaseTool.init(metadata),
            .safety_config = safety_config,
            .allocator = allocator,
        };
        
        // Set vtable
        self.base.tool.vtable = &.{
            .execute = execute,
            .validate = validate,
            .deinit = deinit,
        };
        
        return self;
    }
    
    fn execute(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const self = @fieldParentPtr(ProcessTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        
        // Parse input
        const mode_str = input.object.get("mode") orelse return error.MissingMode;
        const command_val = input.object.get("command") orelse return error.MissingCommand;
        
        if (mode_str != .string or command_val != .string) {
            return error.InvalidInput;
        }
        
        const mode = std.meta.stringToEnum(ProcessMode, mode_str.string) orelse {
            return error.InvalidMode;
        };
        
        const command = command_val.string;
        
        // Parse arguments
        var args = std.ArrayList([]const u8).init(allocator);
        defer args.deinit();
        
        if (input.object.get("args")) |args_val| {
            if (args_val == .array) {
                for (args_val.array.items) |arg| {
                    if (arg == .string) {
                        try args.append(arg.string);
                    }
                }
            }
        }
        
        // Validate command safety
        try self.validateCommand(command, args.items);
        
        // Parse optional parameters
        const timeout = if (input.object.get("timeout")) |t| 
            @as(u32, @intCast(t.integer))
        else 
            self.safety_config.timeout_seconds;
            
        const working_dir = if (input.object.get("working_dir")) |wd|
            if (wd == .string) wd.string else null
        else 
            null;
        
        // Execute based on mode
        return switch (mode) {
            .execute => self.executeCommand(command, args.items, timeout, working_dir, allocator),
            .spawn => self.spawnProcess(command, args.items, working_dir, allocator),
            .shell => self.executeShell(command, timeout, working_dir, allocator),
            .script => self.executeScript(command, args.items, timeout, working_dir, allocator),
        };
    }
    
    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;
        
        // Basic validation
        if (input != .object) return false;
        
        const mode = input.object.get("mode") orelse return false;
        const command = input.object.get("command") orelse return false;
        
        if (mode != .string or command != .string) return false;
        
        // Validate mode is supported
        const process_mode = std.meta.stringToEnum(ProcessMode, mode.string) orelse return false;
        _ = process_mode;
        
        // Validate args if present
        if (input.object.get("args")) |args| {
            if (args != .array) return false;
            for (args.array.items) |arg| {
                if (arg != .string) return false;
            }
        }
        
        // Validate timeout if present
        if (input.object.get("timeout")) |timeout| {
            if (timeout != .integer or timeout.integer < 0) return false;
        }
        
        return true;
    }
    
    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(ProcessTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }
    
    fn validateCommand(self: *const ProcessTool, command: []const u8, args: []const []const u8) !void {
        // Check if command is blocked
        for (self.safety_config.blocked_commands) |blocked| {
            if (std.mem.eql(u8, command, blocked) or std.mem.endsWith(u8, command, blocked)) {
                return ProcessToolError.CommandNotAllowed;
            }
        }
        
        // Check if command is in allow list (if configured)
        if (self.safety_config.allowed_commands.len > 0) {
            var allowed = false;
            for (self.safety_config.allowed_commands) |allowed_cmd| {
                if (std.mem.eql(u8, command, allowed_cmd)) {
                    allowed = true;
                    break;
                }
            }
            if (!allowed) {
                return ProcessToolError.CommandNotAllowed;
            }
        }
        
        // Check argument count
        if (args.len > self.safety_config.max_args) {
            return ProcessToolError.UnsafeOperation;
        }
        
        // Check for dangerous argument patterns
        for (args) |arg| {
            if (std.mem.indexOf(u8, arg, "..") != null or
                std.mem.indexOf(u8, arg, "&&") != null or
                std.mem.indexOf(u8, arg, "|") != null or
                std.mem.indexOf(u8, arg, ";") != null)
            {
                return ProcessToolError.UnsafeOperation;
            }
        }
        
        // Additional safety checks
        if (self.safety_config.read_only) {
            // Check for write operations
            const write_indicators = [_][]const u8{ ">", ">>", "rm", "del", "mv", "cp", "mkdir", "rmdir" };
            for (write_indicators) |indicator| {
                if (std.mem.indexOf(u8, command, indicator) != null) {
                    return ProcessToolError.UnsafeOperation;
                }
                for (args) |arg| {
                    if (std.mem.indexOf(u8, arg, indicator) != null) {
                        return ProcessToolError.UnsafeOperation;
                    }
                }
            }
        }
    }
    
    fn executeCommand(
        self: *const ProcessTool,
        command: []const u8,
        args: []const []const u8,
        timeout_seconds: u32,
        working_dir: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !ToolResult {
        const start_time = std.time.milliTimestamp();
        
        // Prepare arguments array
        var argv = std.ArrayList([]const u8).init(allocator);
        defer argv.deinit();
        
        try argv.append(command);
        try argv.appendSlice(args);
        
        // Prepare environment
        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        
        // Copy whitelisted environment variables
        for (self.safety_config.env_whitelist) |env_var| {
            if (std.os.getenv(env_var)) |value| {
                try env_map.put(env_var, value);
            }
        }
        
        // Execute process
        var child = std.ChildProcess.init(argv.items, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdin_behavior = .Ignore;
        child.env_map = &env_map;
        
        if (working_dir) |cwd| {
            // Validate working directory is safe
            if (self.safety_config.sandbox_directory) |sandbox| {
                const resolved_cwd = std.fs.cwd().realpathAlloc(allocator, cwd) catch {
                    return ToolResult.failure("Invalid working directory");
                };
                defer allocator.free(resolved_cwd);
                
                const resolved_sandbox = std.fs.cwd().realpathAlloc(allocator, sandbox) catch {
                    return ToolResult.failure("Invalid sandbox directory");
                };
                defer allocator.free(resolved_sandbox);
                
                if (!std.mem.startsWith(u8, resolved_cwd, resolved_sandbox)) {
                    return ToolResult.failure("Working directory outside sandbox");
                }
            }
            child.cwd = cwd;
        }
        
        // Start process
        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("Command not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to start process"),
        };
        
        // Read output with timeout
        const stdout = child.stdout.?.readToEndAlloc(allocator, self.safety_config.max_output_size) catch |err| switch (err) {
            error.StreamTooLong => return ToolResult.failure("Output too large"),
            else => try allocator.dupe(u8, ""),
        };
        
        const stderr = child.stderr.?.readToEndAlloc(allocator, self.safety_config.max_output_size) catch |err| switch (err) {
            error.StreamTooLong => return ToolResult.failure("Error output too large"),
            else => try allocator.dupe(u8, ""),
        };
        
        // Wait for process with timeout
        const term = self.waitWithTimeout(&child, timeout_seconds) catch {
            _ = child.kill() catch {};
            return ToolResult.failure("Process execution timeout");
        };
        
        const duration = std.time.milliTimestamp() - start_time;
        
        const exit_code = switch (term) {
            .Exited => |code| code,
            .Signal => |signal| -@as(i32, @intCast(signal)),
            else => -1,
        };
        
        // Build result
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("exit_code", .{ .integer = @as(i64, @intCast(exit_code)) });
        try result_obj.put("stdout", .{ .string = stdout });
        try result_obj.put("stderr", .{ .string = stderr });
        try result_obj.put("duration_ms", .{ .integer = duration });
        try result_obj.put("command", .{ .string = command });
        
        if (exit_code == 0) {
            return ToolResult.success(.{ .object = result_obj });
        } else {
            const error_msg = if (stderr.len > 0) stderr else "Command failed";
            return ToolResult.failure(error_msg);
        }
    }
    
    fn waitWithTimeout(self: *const ProcessTool, child: *std.ChildProcess, timeout_seconds: u32) !std.ChildProcess.Term {
        _ = self;
        
        // Simple timeout implementation - in a real implementation,
        // you'd want to use async I/O or threads for proper timeout handling
        const timeout_ms = timeout_seconds * 1000;
        const start_time = std.time.milliTimestamp();
        
        while (true) {
            if (child.poll()) {
                return child.wait();
            }
            
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed > timeout_ms) {
                return ProcessToolError.Timeout;
            }
            
            std.time.sleep(10 * std.time.ns_per_ms); // Sleep 10ms
        }
    }
    
    fn spawnProcess(
        self: *const ProcessTool,
        command: []const u8,
        args: []const []const u8,
        working_dir: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !ToolResult {
        if (!self.safety_config.allow_background_processes) {
            return ToolResult.failure("Background processes not allowed");
        }
        
        // Prepare arguments array
        var argv = std.ArrayList([]const u8).init(allocator);
        defer argv.deinit();
        
        try argv.append(command);
        try argv.appendSlice(args);
        
        // Spawn process
        var child = std.ChildProcess.init(argv.items, allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.stdin_behavior = .Ignore;
        
        if (working_dir) |cwd| {
            child.cwd = cwd;
        }
        
        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("Command not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to spawn process"),
        };
        
        const pid = child.id;
        
        // Detach the process
        child.detach();
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("pid", .{ .integer = @as(i64, @intCast(pid)) });
        try result_obj.put("command", .{ .string = command });
        try result_obj.put("status", .{ .string = "spawned" });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn executeShell(
        self: *const ProcessTool,
        command: []const u8,
        timeout_seconds: u32,
        working_dir: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !ToolResult {
        if (!self.safety_config.allow_shell_execution) {
            return ToolResult.failure("Shell execution not allowed");
        }
        
        // Determine shell
        const shell = if (std.os.getenv("SHELL")) |sh| sh else "/bin/sh";
        
        return self.executeCommand(shell, &[_][]const u8{ "-c", command }, timeout_seconds, working_dir, allocator);
    }
    
    fn executeScript(
        self: *const ProcessTool,
        script_path: []const u8,
        args: []const []const u8,
        timeout_seconds: u32,
        working_dir: ?[]const u8,
        allocator: std.mem.Allocator,
    ) !ToolResult {
        // Check if script file exists and is readable
        std.fs.cwd().access(script_path, .{}) catch {
            return ToolResult.failure("Script file not found or not accessible");
        }
        
        // Determine interpreter based on file extension
        const interpreter = blk: {
            if (std.mem.endsWith(u8, script_path, ".py")) {
                break :blk "python3";
            } else if (std.mem.endsWith(u8, script_path, ".js")) {
                break :blk "node";
            } else if (std.mem.endsWith(u8, script_path, ".sh")) {
                break :blk "bash";
            } else {
                // Try to execute directly
                break :blk script_path;
            }
        };
        
        var script_args = std.ArrayList([]const u8).init(allocator);
        defer script_args.deinit();
        
        if (!std.mem.eql(u8, interpreter, script_path)) {
            try script_args.append(script_path);
        }
        try script_args.appendSlice(args);
        
        return self.executeCommand(interpreter, script_args.items, timeout_seconds, working_dir, allocator);
    }
};

// Helper functions for schema creation
fn createInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });
    
    var properties = std.json.ObjectMap.init(allocator);
    
    var mode_prop = std.json.ObjectMap.init(allocator);
    try mode_prop.put("type", .{ .string = "string" });
    try mode_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "execute" },
        .{ .string = "spawn" },
        .{ .string = "shell" },
        .{ .string = "script" },
    })) });
    try mode_prop.put("description", .{ .string = "Process execution mode" });
    try properties.put("mode", .{ .object = mode_prop });
    
    var command_prop = std.json.ObjectMap.init(allocator);
    try command_prop.put("type", .{ .string = "string" });
    try command_prop.put("description", .{ .string = "Command to execute" });
    try properties.put("command", .{ .object = command_prop });
    
    var args_prop = std.json.ObjectMap.init(allocator);
    try args_prop.put("type", .{ .string = "array" });
    var args_items = std.json.ObjectMap.init(allocator);
    try args_items.put("type", .{ .string = "string" });
    try args_prop.put("items", .{ .object = args_items });
    try args_prop.put("description", .{ .string = "Command arguments" });
    try properties.put("args", .{ .object = args_prop });
    
    var timeout_prop = std.json.ObjectMap.init(allocator);
    try timeout_prop.put("type", .{ .string = "integer" });
    try timeout_prop.put("minimum", .{ .integer = 1 });
    try timeout_prop.put("maximum", .{ .integer = 300 });
    try timeout_prop.put("description", .{ .string = "Execution timeout in seconds" });
    try properties.put("timeout", .{ .object = timeout_prop });
    
    var working_dir_prop = std.json.ObjectMap.init(allocator);
    try working_dir_prop.put("type", .{ .string = "string" });
    try working_dir_prop.put("description", .{ .string = "Working directory for execution" });
    try properties.put("working_dir", .{ .object = working_dir_prop });
    
    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "mode" },
        .{ .string = "command" },
    })) });
    
    return .{ .object = schema };
}

fn createOutputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });
    
    var properties = std.json.ObjectMap.init(allocator);
    
    var success_prop = std.json.ObjectMap.init(allocator);
    try success_prop.put("type", .{ .string = "boolean" });
    try properties.put("success", .{ .object = success_prop });
    
    var data_prop = std.json.ObjectMap.init(allocator);
    try data_prop.put("type", .{ .string = "object" });
    
    var data_props = std.json.ObjectMap.init(allocator);
    
    var exit_code_prop = std.json.ObjectMap.init(allocator);
    try exit_code_prop.put("type", .{ .string = "integer" });
    try data_props.put("exit_code", .{ .object = exit_code_prop });
    
    var stdout_prop = std.json.ObjectMap.init(allocator);
    try stdout_prop.put("type", .{ .string = "string" });
    try data_props.put("stdout", .{ .object = stdout_prop });
    
    var stderr_prop = std.json.ObjectMap.init(allocator);
    try stderr_prop.put("type", .{ .string = "string" });
    try data_props.put("stderr", .{ .object = stderr_prop });
    
    var duration_prop = std.json.ObjectMap.init(allocator);
    try duration_prop.put("type", .{ .string = "integer" });
    try data_props.put("duration_ms", .{ .object = duration_prop });
    
    try data_prop.put("properties", .{ .object = data_props });
    try properties.put("data", .{ .object = data_prop });
    
    var error_prop = std.json.ObjectMap.init(allocator);
    try error_prop.put("type", .{ .string = "string" });
    try properties.put("error", .{ .object = error_prop });
    
    try schema.put("properties", .{ .object = properties });
    
    return .{ .object = schema };
}

fn createExampleInput(allocator: std.mem.Allocator, mode: []const u8, command: []const u8, args: []const []const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("mode", .{ .string = mode });
    try input.put("command", .{ .string = command });
    
    if (args.len > 0) {
        var args_array = std.ArrayList(std.json.Value).init(allocator);
        for (args) |arg| {
            try args_array.append(.{ .string = arg });
        }
        try input.put("args", .{ .array = std.json.Array.fromOwnedSlice(allocator, try args_array.toOwnedSlice()) });
    }
    
    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, exit_code: i32, stdout: []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });
    
    var data = std.json.ObjectMap.init(allocator);
    try data.put("exit_code", .{ .integer = @as(i64, @intCast(exit_code)) });
    try data.put("stdout", .{ .string = stdout });
    try data.put("stderr", .{ .string = "" });
    try data.put("duration_ms", .{ .integer = 100 });
    
    try output.put("data", .{ .object = data });
    
    return output;
}

// Builder function for easy creation
pub fn createProcessTool(allocator: std.mem.Allocator, safety_config: ProcessSafetyConfig) !*Tool {
    const process_tool = try ProcessTool.init(allocator, safety_config);
    return &process_tool.base.tool;
}

// Tests
test "process tool creation" {
    const allocator = std.testing.allocator;
    
    const tool_ptr = try createProcessTool(allocator, .{});
    defer tool_ptr.deinit();
    
    try std.testing.expectEqualStrings("process_execution", tool_ptr.metadata.name);
}

test "process tool validation" {
    const allocator = std.testing.allocator;
    
    const tool_ptr = try createProcessTool(allocator, .{});
    defer tool_ptr.deinit();
    
    // Valid input
    var valid_input = std.json.ObjectMap.init(allocator);
    defer valid_input.deinit();
    try valid_input.put("mode", .{ .string = "execute" });
    try valid_input.put("command", .{ .string = "echo" });
    
    var args_array = std.ArrayList(std.json.Value).init(allocator);
    defer args_array.deinit();
    try args_array.append(.{ .string = "hello" });
    try valid_input.put("args", .{ .array = std.json.Array.fromOwnedSlice(allocator, try args_array.toOwnedSlice()) });
    
    const valid = try tool_ptr.validate(.{ .object = valid_input }, allocator);
    try std.testing.expect(valid);
    
    // Invalid input (missing command)
    var invalid_input = std.json.ObjectMap.init(allocator);
    defer invalid_input.deinit();
    try invalid_input.put("mode", .{ .string = "execute" });
    
    const invalid = try tool_ptr.validate(.{ .object = invalid_input }, allocator);
    try std.testing.expect(!invalid);
}

test "command safety validation" {
    const allocator = std.testing.allocator;
    
    // Create tool with restricted commands
    const safety_config = ProcessSafetyConfig{
        .allowed_commands = &[_][]const u8{"echo"},
        .blocked_commands = &[_][]const u8{"rm"},
    };
    
    const process_tool = try ProcessTool.init(allocator, safety_config);
    defer process_tool.allocator.destroy(process_tool);
    
    // Test allowed command
    process_tool.validateCommand("echo", &[_][]const u8{"hello"}) catch unreachable;
    
    // Test blocked command
    const blocked_result = process_tool.validateCommand("rm", &[_][]const u8{"-rf", "/"});
    try std.testing.expectError(ProcessToolError.CommandNotAllowed, blocked_result);
    
    // Test disallowed command (not in allow list)
    const disallowed_result = process_tool.validateCommand("ls", &[_][]const u8{});
    try std.testing.expectError(ProcessToolError.CommandNotAllowed, disallowed_result);
}