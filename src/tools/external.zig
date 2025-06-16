// ABOUTME: External tool callback support for integrating non-Zig tools
// ABOUTME: Provides FFI, process spawning, and plugin architecture support

const std = @import("std");
const tool_mod = @import("../tool.zig");
const Tool = tool_mod.Tool;
const ToolMetadata = Tool.ToolMetadata;
const RunContext = @import("../context.zig").RunContext;

// External tool interface types
pub const ExternalToolType = enum {
    ffi, // Foreign Function Interface (C ABI)
    process, // External process
    script, // Script interpreter (Python, Lua, etc.)
    plugin, // Dynamic library plugin
    http, // HTTP endpoint
    grpc, // gRPC service
};

// External tool callback
pub const ExternalToolCallback = struct {
    tool: Tool,
    external_type: ExternalToolType,
    config: ExternalToolConfig,
    state: ?*anyopaque = null,
    allocator: std.mem.Allocator,

    const vtable = Tool.VTable{
        .execute = execute,
        .validate = validate,
        .cleanup = cleanup,
        .describe = describe,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        metadata: ToolMetadata,
        external_type: ExternalToolType,
        config: ExternalToolConfig,
    ) !*ExternalToolCallback {
        const self = try allocator.create(ExternalToolCallback);
        self.* = .{
            .tool = Tool{
                .metadata = metadata,
                .vtable = &vtable,
                .state = null,
            },
            .external_type = external_type,
            .config = config,
            .state = null,
            .allocator = allocator,
        };
        self.tool.state = self;
        return self;
    }

    pub fn deinit(self: *ExternalToolCallback) void {
        self.config.deinit();
        self.allocator.destroy(self);
    }

    fn execute(tool: *Tool, context: *RunContext, input: std.json.Value) !std.json.Value {
        const self: *ExternalToolCallback = @ptrCast(@alignCast(tool.state.?));

        return switch (self.external_type) {
            .ffi => try self.executeFfi(context, input),
            .process => try self.executeProcess(context, input),
            .script => try self.executeScript(context, input),
            .plugin => try self.executePlugin(context, input),
            .http => try self.executeHttp(context, input),
            .grpc => try self.executeGrpc(context, input),
        };
    }

    fn validate(tool: *Tool, input: std.json.Value) !void {
        // Use base validation
        const validation_result = try tool.metadata.input_schema.validate(input);
        if (!validation_result.valid) {
            return error.InvalidInput;
        }
    }

    fn cleanup(tool: *Tool) void {
        const self: *ExternalToolCallback = @ptrCast(@alignCast(tool.state.?));

        switch (self.external_type) {
            .plugin => {
                if (self.config.plugin.handle) |handle| {
                    std.DynLib.close(handle);
                }
            },
            else => {},
        }
    }

    fn describe(tool: *Tool, allocator: std.mem.Allocator) ![]const u8 {
        const self: *ExternalToolCallback = @ptrCast(@alignCast(tool.state.?));

        return std.fmt.allocPrint(allocator, "External Tool: {s}\nType: {s}\nDescription: {s}", .{ tool.metadata.name, @tagName(self.external_type), tool.metadata.description });
    }

    fn executeFfi(self: *ExternalToolCallback, context: *RunContext, input: std.json.Value) !std.json.Value {
        _ = context;

        const config = self.config.ffi;

        // Convert input to JSON string
        const input_str = try std.json.stringifyAlloc(self.allocator, input, .{});
        defer self.allocator.free(input_str);

        // Call the function
        const result_ptr = config.execute_fn(input_str.ptr, input_str.len);
        if (result_ptr == null) {
            return error.ExternalExecutionFailed;
        }

        // Get result length
        const result_len = config.get_result_len_fn();

        // Copy result
        const result_str = try self.allocator.alloc(u8, result_len);
        defer self.allocator.free(result_str);
        @memcpy(result_str, result_ptr[0..result_len]);

        // Free external memory
        config.free_result_fn(result_ptr);

        // Parse result
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_str, .{});
        return parsed.value;
    }

    fn executeProcess(self: *ExternalToolCallback, context: *RunContext, input: std.json.Value) !std.json.Value {
        _ = context;

        const config = self.config.process;

        // Prepare arguments
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append(config.path);
        try args.appendSlice(config.args);

        // Convert input to JSON
        const input_str = try std.json.stringifyAlloc(self.allocator, input, .{});
        defer self.allocator.free(input_str);

        // Create process
        var child = std.process.Child.init(args.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        // Set environment variables
        if (config.env) |env| {
            child.env_map = env;
        }

        // Spawn process
        try child.spawn();

        // Write input
        try child.stdin.?.writeAll(input_str);
        child.stdin.?.close();
        child.stdin = null;

        // Read output
        const stdout = try child.stdout.?.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);

        // Wait for completion
        const result = try child.wait();

        if (result != .Exited or result.Exited != 0) {
            std.log.err("External process failed: {s}", .{stderr});
            return error.ExternalProcessFailed;
        }

        // Parse output
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, stdout, .{});
        return parsed.value;
    }

    fn executeScript(self: *ExternalToolCallback, context: *RunContext, input: std.json.Value) !std.json.Value {
        const config = self.config.script;

        // Determine interpreter
        const interpreter = switch (config.language) {
            .python => "python3",
            .javascript => "node",
            .lua => "lua",
            .ruby => "ruby",
            .custom => config.interpreter.?,
        };

        // Prepare script execution
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append(interpreter);
        try args.append(config.script_path);

        // Use process execution
        const process_config = ExternalToolConfig{ .process = .{
            .path = interpreter,
            .args = args.items[1..],
        } };
        self.config = process_config;
        defer {
            self.config = ExternalToolConfig{ .script = config };
        }

        return try self.executeProcess(context, input);
    }

    fn executePlugin(self: *ExternalToolCallback, context: *RunContext, input: std.json.Value) !std.json.Value {
        _ = context;

        const config = self.config.plugin;

        // Load plugin if not loaded
        if (config.handle == null) {
            config.handle = try std.DynLib.open(config.path);
        }

        const handle = config.handle.?;

        // Get function pointers
        const init_fn = handle.lookup(*const fn () callconv(.C) void, "tool_init");
        const execute_fn = handle.lookup(*const fn ([*c]const u8, usize) callconv(.C) [*c]const u8, "tool_execute") orelse return error.SymbolNotFound;
        const cleanup_fn = handle.lookup(*const fn () callconv(.C) void, "tool_cleanup");

        // Initialize if available
        if (init_fn) |initFn| {
            initFn();
        }

        // Convert input
        const input_str = try std.json.stringifyAlloc(self.allocator, input, .{});
        defer self.allocator.free(input_str);

        // Execute
        const result_ptr = execute_fn(input_str.ptr, input_str.len);
        if (result_ptr == null) {
            return error.PluginExecutionFailed;
        }

        // Copy result
        const result_str = std.mem.span(result_ptr);
        const result_copy = try self.allocator.dupe(u8, result_str);
        defer self.allocator.free(result_copy);

        // Cleanup if available
        if (cleanup_fn) |cleanupFn| {
            cleanupFn();
        }

        // Parse result
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result_copy, .{});
        return parsed.value;
    }

    fn executeHttp(self: *ExternalToolCallback, context: *RunContext, input: std.json.Value) !std.json.Value {
        _ = self;
        _ = context;
        _ = input;
        // TODO: Implement HTTP client execution
        return error.NotImplemented;
    }

    fn executeGrpc(self: *ExternalToolCallback, context: *RunContext, input: std.json.Value) !std.json.Value {
        _ = self;
        _ = context;
        _ = input;
        // TODO: Implement gRPC client execution
        return error.NotImplemented;
    }
};

// External tool configuration
pub const ExternalToolConfig = union(ExternalToolType) {
    ffi: FfiConfig,
    process: ProcessConfig,
    script: ScriptConfig,
    plugin: PluginConfig,
    http: HttpConfig,
    grpc: GrpcConfig,

    pub fn deinit(self: *ExternalToolConfig) void {
        switch (self.*) {
            .process => |*config| {
                if (config.env) |env| {
                    env.deinit();
                }
            },
            else => {},
        }
    }
};

pub const FfiConfig = struct {
    execute_fn: *const fn ([*c]const u8, usize) callconv(.C) [*c]const u8,
    get_result_len_fn: *const fn () callconv(.C) usize,
    free_result_fn: *const fn ([*c]const u8) callconv(.C) void,
};

pub const ProcessConfig = struct {
    path: []const u8,
    args: []const []const u8 = &[_][]const u8{},
    env: ?std.process.EnvMap = null,
    working_dir: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

pub const ScriptConfig = struct {
    language: ScriptLanguage,
    script_path: []const u8,
    interpreter: ?[]const u8 = null,

    pub const ScriptLanguage = enum {
        python,
        javascript,
        lua,
        ruby,
        custom,
    };
};

pub const PluginConfig = struct {
    path: []const u8,
    handle: ?std.DynLib = null,
};

pub const HttpConfig = struct {
    endpoint: []const u8,
    method: []const u8 = "POST",
    headers: ?std.StringHashMap([]const u8) = null,
    timeout_ms: u32 = 30000,
};

pub const GrpcConfig = struct {
    endpoint: []const u8,
    service: []const u8,
    method: []const u8,
    timeout_ms: u32 = 30000,
};

// External tool builder
pub const ExternalToolBuilder = struct {
    allocator: std.mem.Allocator,
    metadata: ToolMetadata,
    external_type: ?ExternalToolType = null,
    config: ?ExternalToolConfig = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) ExternalToolBuilder {
        return .{
            .allocator = allocator,
            .metadata = .{
                .name = name,
                .description = "",
                .input_schema = undefined,
                .output_schema = undefined,
            },
        };
    }

    pub fn withDescription(self: *ExternalToolBuilder, description: []const u8) *ExternalToolBuilder {
        self.metadata.description = description;
        return self;
    }

    pub fn withSchemas(self: *ExternalToolBuilder, input: anytype, output: anytype) *ExternalToolBuilder {
        self.metadata.input_schema = input;
        self.metadata.output_schema = output;
        return self;
    }

    pub fn withProcess(self: *ExternalToolBuilder, path: []const u8, args: []const []const u8) *ExternalToolBuilder {
        self.external_type = .process;
        self.config = .{ .process = .{
            .path = path,
            .args = args,
        } };
        return self;
    }

    pub fn withScript(self: *ExternalToolBuilder, language: ScriptConfig.ScriptLanguage, path: []const u8) *ExternalToolBuilder {
        self.external_type = .script;
        self.config = .{ .script = .{
            .language = language,
            .script_path = path,
        } };
        return self;
    }

    pub fn withPlugin(self: *ExternalToolBuilder, path: []const u8) *ExternalToolBuilder {
        self.external_type = .plugin;
        self.config = .{ .plugin = .{
            .path = path,
        } };
        return self;
    }

    pub fn build(self: *ExternalToolBuilder) !*ExternalToolCallback {
        if (self.external_type == null or self.config == null) {
            return error.IncompleteConfiguration;
        }

        return ExternalToolCallback.init(
            self.allocator,
            self.metadata,
            self.external_type.?,
            self.config.?,
        );
    }
};

// Test stubs for external tools
test "external tool builder" {
    const allocator = std.testing.allocator;
    const schema = @import("../schema/validator.zig");

    var input_schema = schema.Schema.init(allocator, .{ .string = .{} });
    defer input_schema.deinit();

    var output_schema = schema.Schema.init(allocator, .{ .string = .{} });
    defer output_schema.deinit();

    var builder = ExternalToolBuilder.init(allocator, "test_external");
    _ = builder.withDescription("Test external tool")
        .withSchemas(input_schema, output_schema)
        .withProcess("/usr/bin/echo", &[_][]const u8{"-n"});

    // Don't actually build in test to avoid process execution
    try std.testing.expect(builder.external_type == .process);
}
