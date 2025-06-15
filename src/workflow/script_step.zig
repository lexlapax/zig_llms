// ABOUTME: Script step implementation for workflow scripting integration
// ABOUTME: Enables execution of embedded scripts within workflow steps using various interpreters

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const ScriptStepConfig = definition.ScriptStepConfig;
const RunContext = @import("../context.zig").RunContext;

// Re-export from definition
pub const ScriptLanguage = definition.ScriptStepConfig.ScriptLanguage;

// Script execution result
pub const ScriptExecutionResult = struct {
    success: bool,
    exit_code: ?i32 = null,
    stdout: ?[]const u8 = null,
    stderr: ?[]const u8 = null,
    result_value: ?std.json.Value = null,
    execution_time_ms: u64,
    error_message: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ScriptExecutionResult) void {
        if (self.stdout) |out| {
            self.allocator.free(out);
        }
        if (self.stderr) |err| {
            self.allocator.free(err);
        }
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }
    
    pub fn toJson(self: *ScriptExecutionResult) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        try obj.put("success", .{ .bool = self.success });
        try obj.put("execution_time_ms", .{ .integer = @as(i64, @intCast(self.execution_time_ms)) });
        
        if (self.exit_code) |code| {
            try obj.put("exit_code", .{ .integer = @as(i64, @intCast(code)) });
        }
        
        if (self.stdout) |out| {
            try obj.put("stdout", .{ .string = out });
        }
        
        if (self.stderr) |err| {
            try obj.put("stderr", .{ .string = err });
        }
        
        if (self.result_value) |value| {
            try obj.put("result_value", value);
        }
        
        if (self.error_message) |msg| {
            try obj.put("error_message", .{ .string = msg });
        }
        
        return .{ .object = obj };
    }
};

// Script step executor
pub const ScriptStepExecutor = struct {
    allocator: std.mem.Allocator,
    config: ExecutorConfig = .{},
    
    pub const ExecutorConfig = struct {
        timeout_ms: u32 = 30000,
        max_stdout_size: usize = 1024 * 1024, // 1MB
        max_stderr_size: usize = 1024 * 1024, // 1MB
        working_directory: ?[]const u8 = null,
        capture_output: bool = true,
        allow_network: bool = false,
        allow_filesystem: bool = false,
        sandbox_mode: bool = true,
    };
    
    pub fn init(allocator: std.mem.Allocator) ScriptStepExecutor {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn executeScriptStep(
        self: *ScriptStepExecutor,
        config: ScriptStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !ScriptExecutionResult {
        _ = run_context;
        const start_time = std.time.milliTimestamp();
        
        var result = ScriptExecutionResult{
            .success = true,
            .execution_time_ms = 0,
            .allocator = self.allocator,
        };
        
        // Prepare script context
        const script_context = try self.prepareScriptContext(execution_context);
        defer script_context.deinit();
        
        // Execute script directly (simplified API)
        try self.executeScript(config, script_context.value, &result);
        
        result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        return result;
    }
    
    fn executeScript(
        self: *ScriptStepExecutor,
        config: ScriptStepConfig,
        context: std.json.Value,
        result: *ScriptExecutionResult,
    ) !void {
        switch (config.language) {
            .javascript => try self.executeJavaScript(config.code, context, result),
            .python => try self.executePython(config.code, context, result),
            .lua => try self.executeLua(config.code, context, result),
            .shell => try self.executeShell(config.code, context, result),
        }
    }
    
    fn executeJavaScript(
        self: *ScriptStepExecutor,
        script: []const u8,
        context: std.json.Value,
        result: *ScriptExecutionResult,
    ) !void {
        // Execute JavaScript using Node.js
        try self.executeExternalScript("node", &[_][]const u8{"-e"}, script, context, result);
    }
    
    fn executePython(
        self: *ScriptStepExecutor,
        script: []const u8,
        context: std.json.Value,
        result: *ScriptExecutionResult,
    ) !void {
        // Execute Python script
        try self.executeExternalScript("python3", &[_][]const u8{"-c"}, script, context, result);
    }
    
    fn executeLua(
        self: *ScriptStepExecutor,
        script: []const u8,
        context: std.json.Value,
        result: *ScriptExecutionResult,
    ) !void {
        // Execute Lua script
        try self.executeExternalScript("lua", &[_][]const u8{"-e"}, script, context, result);
    }
    
    fn executeShell(
        self: *ScriptStepExecutor,
        script: []const u8,
        context: std.json.Value,
        result: *ScriptExecutionResult,
    ) !void {
        _ = context;
        
        // Execute shell script
        var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", script }, self.allocator);
        
        child.stdout_behavior = if (self.config.capture_output) .Pipe else .Inherit;
        child.stderr_behavior = if (self.config.capture_output) .Pipe else .Inherit;
        
        if (self.config.working_directory) |wd| {
            child.cwd = wd;
        }
        
        child.spawn() catch |err| {
            result.success = false;
            result.error_message = try std.fmt.allocPrint(self.allocator, 
                "Failed to spawn shell process: {s}", .{@errorName(err)});
            return;
        };
        
        // Capture output if configured
        if (self.config.capture_output) {
            var stdout_list = std.ArrayList(u8).init(self.allocator);
            var stderr_list = std.ArrayList(u8).init(self.allocator);
            
            if (child.stdout) |stdout| {
                stdout.reader().readAllArrayList(&stdout_list, self.config.max_stdout_size) catch {};
            }
            
            if (child.stderr) |stderr| {
                stderr.reader().readAllArrayList(&stderr_list, self.config.max_stderr_size) catch {};
            }
            
            result.stdout = try stdout_list.toOwnedSlice();
            result.stderr = try stderr_list.toOwnedSlice();
        }
        
        const term = child.wait() catch |err| {
            result.success = false;
            result.error_message = try std.fmt.allocPrint(self.allocator, 
                "Failed to wait for shell process: {s}", .{@errorName(err)});
            return;
        };
        
        switch (term) {
            .Exited => |code| {
                result.exit_code = @as(i32, @intCast(code));
                result.success = code == 0;
            },
            .Signal => |signal| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, 
                    "Process terminated by signal: {d}", .{signal});
            },
            .Stopped => |signal| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, 
                    "Process stopped by signal: {d}", .{signal});
            },
            .Unknown => |code| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, 
                    "Process terminated with unknown code: {d}", .{code});
            },
        }
    }
    
    fn executeExternalScript(
        self: *ScriptStepExecutor,
        interpreter: []const u8,
        args: []const []const u8,
        script: []const u8,
        context: std.json.Value,
        result: *ScriptExecutionResult,
    ) !void {
        // Prepare arguments
        var arg_list = std.ArrayList([]const u8).init(self.allocator);
        defer arg_list.deinit();
        
        try arg_list.append(interpreter);
        for (args) |arg| {
            try arg_list.append(arg);
        }
        
        // Add script as argument if not empty
        if (script.len > 0) {
            try arg_list.append(script);
        }
        
        // Prepare context as environment variable
        const context_json = try std.json.stringifyAlloc(self.allocator, context, .{});
        defer self.allocator.free(context_json);
        
        var child = std.process.Child.init(try arg_list.toOwnedSlice(), self.allocator);
        defer self.allocator.free(child.argv);
        
        child.stdout_behavior = if (self.config.capture_output) .Pipe else .Inherit;
        child.stderr_behavior = if (self.config.capture_output) .Pipe else .Inherit;
        
        // Set working directory
        if (self.config.working_directory) |wd| {
            child.cwd = wd;
        }
        
        // Set environment variables
        var env_map = std.process.EnvMap.init(self.allocator);
        defer env_map.deinit();
        
        // Copy existing environment
        try env_map.copy(std.process.getEnvMap(self.allocator) catch return);
        
        // Add context as WORKFLOW_CONTEXT
        try env_map.put("WORKFLOW_CONTEXT", context_json);
        
        child.env_map = &env_map;
        
        child.spawn() catch |err| {
            result.success = false;
            result.error_message = try std.fmt.allocPrint(self.allocator, 
                "Failed to spawn {s}: {s}", .{ interpreter, @errorName(err) });
            return;
        };
        
        // Capture output if configured
        if (self.config.capture_output) {
            var stdout_list = std.ArrayList(u8).init(self.allocator);
            var stderr_list = std.ArrayList(u8).init(self.allocator);
            
            if (child.stdout) |stdout| {
                stdout.reader().readAllArrayList(&stdout_list, self.config.max_stdout_size) catch {};
            }
            
            if (child.stderr) |stderr| {
                stderr.reader().readAllArrayList(&stderr_list, self.config.max_stderr_size) catch {};
            }
            
            result.stdout = try stdout_list.toOwnedSlice();
            result.stderr = try stderr_list.toOwnedSlice();
        }
        
        const term = child.wait() catch |err| {
            result.success = false;
            result.error_message = try std.fmt.allocPrint(self.allocator, 
                "Failed to wait for {s}: {s}", .{ interpreter, @errorName(err) });
            return;
        };
        
        switch (term) {
            .Exited => |code| {
                result.exit_code = @as(i32, @intCast(code));
                result.success = code == 0;
                
                // Try to parse stdout as JSON for result value
                if (result.stdout) |out| {
                    if (out.len > 0) {
                        if (std.json.parseFromSlice(std.json.Value, self.allocator, out, .{})) |parsed| {
                            result.result_value = parsed.value;
                        } else |_| {
                            // If not valid JSON, store as string
                            result.result_value = .{ .string = out };
                        }
                    }
                }
            },
            .Signal => |signal| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, 
                    "{s} terminated by signal: {d}", .{ interpreter, signal });
            },
            .Stopped => |signal| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, 
                    "{s} stopped by signal: {d}", .{ interpreter, signal });
            },
            .Unknown => |code| {
                result.success = false;
                result.error_message = try std.fmt.allocPrint(self.allocator, 
                    "{s} terminated with unknown code: {d}", .{ interpreter, code });
            },
        }
    }
    
    fn prepareScriptContext(
        self: *ScriptStepExecutor,
        execution_context: *WorkflowExecutionContext,
    ) !std.json.Parsed(std.json.Value) {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        // Add variables
        var variables_obj = std.json.ObjectMap.init(self.allocator);
        var var_iter = execution_context.variables.iterator();
        while (var_iter.next()) |entry| {
            try variables_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("variables", .{ .object = variables_obj });
        
        // Add step results
        var results_obj = std.json.ObjectMap.init(self.allocator);
        var result_iter = execution_context.step_results.iterator();
        while (result_iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("step_results", .{ .object = results_obj });
        
        // Add execution state
        try obj.put("execution_state", .{ .string = @tagName(execution_context.execution_state) });
        
        if (execution_context.current_step) |step| {
            try obj.put("current_step", .{ .string = step });
        }
        
        const json_value = std.json.Value{ .object = obj };
        
        // Convert to string and parse back to get a Parsed value
        const json_string = try std.json.stringifyAlloc(self.allocator, json_value, .{});
        defer self.allocator.free(json_string);
        
        return std.json.parseFromSlice(std.json.Value, self.allocator, json_string, .{});
    }
};

// Script step builder for fluent API
pub const ScriptStepBuilder = struct {
    allocator: std.mem.Allocator,
    config: ScriptStepConfig,
    
    pub fn init(allocator: std.mem.Allocator, language: ScriptLanguage) ScriptStepBuilder {
        return .{
            .allocator = allocator,
            .config = ScriptStepConfig{
                .language = language,
                .code = "",
            },
        };
    }
    
    pub fn withCode(self: *ScriptStepBuilder, code: []const u8) *ScriptStepBuilder {
        self.config.code = code;
        return self;
    }
    
    pub fn withEnvironment(self: *ScriptStepBuilder, env: std.StringHashMap([]const u8)) *ScriptStepBuilder {
        self.config.environment = env;
        return self;
    }
    
    pub fn build(self: *ScriptStepBuilder) ScriptStepConfig {
        return self.config;
    }
};

// Tests
test "script step executor initialization" {
    const allocator = std.testing.allocator;
    
    const executor = ScriptStepExecutor.init(allocator);
    try std.testing.expect(executor.config.timeout_ms == 30000);
    try std.testing.expect(executor.config.capture_output == true);
    try std.testing.expect(executor.config.sandbox_mode == true);
}

test "script step builder" {
    const allocator = std.testing.allocator;
    
    var builder = ScriptStepBuilder.init(allocator, .python);
    const config = builder.withCode("print('Hello, World!')")
        .build();
    
    try std.testing.expectEqual(ScriptLanguage.python, config.language);
    try std.testing.expectEqualStrings("print('Hello, World!')", config.code);
}

test "shell script execution" {
    const allocator = std.testing.allocator;
    
    var executor = ScriptStepExecutor.init(allocator);
    executor.config.timeout_ms = 1000; // 1 second timeout
    
    // Create test execution context
    var workflow = WorkflowDefinition.init(allocator, "test", "Test");
    defer workflow.deinit();
    
    var context = WorkflowExecutionContext.init(allocator, &workflow);
    defer context.deinit();
    
    try context.setVariable("test_var", .{ .string = "hello" });
    
    var run_context = RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();
    
    const config = ScriptStepConfig{
        .language = .shell,
        .code = "echo 'Hello from shell'",
    };
    
    var result = try executor.executeScriptStep(config, &context, &run_context);
    defer result.deinit();
    
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code.?);
    
    if (result.stdout) |out| {
        try std.testing.expect(std.mem.indexOf(u8, out, "Hello from shell") != null);
    }
}