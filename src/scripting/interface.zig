// ABOUTME: Core scripting engine interface for multi-language support
// ABOUTME: Provides abstract interface that all scripting engines must implement

const std = @import("std");
const ScriptValue = @import("value_bridge.zig").ScriptValue;
const ScriptError = @import("error_bridge.zig").ScriptError;
const ScriptContext = @import("context.zig").ScriptContext;

/// Configuration for initializing a scripting engine
pub const EngineConfig = struct {
    /// Maximum memory allowed for the engine (0 = unlimited)
    max_memory_bytes: usize = 0,

    /// Maximum execution time in milliseconds (0 = unlimited)
    max_execution_time_ms: u32 = 0,

    /// Whether to enable debugging features
    enable_debugging: bool = false,

    /// Custom allocator for the engine (null = use default)
    allocator: ?std.mem.Allocator = null,

    /// Security sandbox level
    sandbox_level: SandboxLevel = .restricted,

    /// Enable state snapshots for rollback capabilities
    enable_snapshots: bool = false,

    /// Maximum number of snapshots to keep per state
    max_snapshots: usize = 10,

    /// Maximum total size of all snapshots in bytes
    max_snapshot_size_bytes: usize = 50 * 1024 * 1024, // 50MB default

    /// Enable panic handler for error recovery
    enable_panic_handler: bool = false,

    /// Panic handler recovery strategy
    panic_recovery_strategy: PanicRecoveryStrategy = .reset_state,

    pub const PanicRecoveryStrategy = enum {
        /// Attempt to reset the Lua state
        reset_state,
        /// Create a new Lua state
        new_state,
        /// Propagate the error
        propagate,
    };

    pub const SandboxLevel = enum {
        /// No restrictions
        none,
        /// Default restrictions (no file system, network)
        restricted,
        /// Maximum isolation
        strict,
    };
};

/// Module definition for exposing zig_llms APIs to scripts
pub const ScriptModule = struct {
    /// Module name (e.g., "zigllms.agent", "zigllms.tool")
    name: []const u8,

    /// Module functions
    functions: []const FunctionDef,

    /// Module constants
    constants: []const ConstantDef,

    /// Module metadata
    description: []const u8 = "",
    version: []const u8 = "1.0.0",

    pub const FunctionDef = struct {
        name: []const u8,
        arity: ?u8 = null, // null = variadic
        callback: *const fn (context: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue,
        description: []const u8 = "",
    };

    pub const ConstantDef = struct {
        name: []const u8,
        value: ScriptValue,
        description: []const u8 = "",
    };
};

/// Function reference for script callbacks
pub const ScriptFunction = struct {
    context: *ScriptContext,
    engine_ref: *anyopaque, // Engine-specific function reference

    pub fn call(self: *ScriptFunction, args: []const ScriptValue) !ScriptValue {
        return self.context.executeFunction(self, args);
    }

    pub fn deinit(self: *ScriptFunction) void {
        self.context.releaseFunction(self);
    }
};

/// Core scripting engine interface that all engines must implement
pub const ScriptingEngine = struct {
    const Self = @This();

    // Engine metadata
    name: []const u8,
    version: []const u8,
    supported_extensions: []const []const u8,
    features: EngineFeatures,

    // VTable for polymorphic operations
    vtable: *const VTable,

    // Engine-specific implementation pointer
    impl: *anyopaque,

    pub const EngineFeatures = struct {
        async_support: bool = false,
        debugging: bool = false,
        sandboxing: bool = true,
        hot_reload: bool = false,
        native_json: bool = false,
        native_regex: bool = false,
    };

    pub const VTable = struct {
        // Lifecycle management
        init: *const fn (allocator: std.mem.Allocator, config: EngineConfig) anyerror!*Self,
        deinit: *const fn (self: *Self) void,

        // Context management
        createContext: *const fn (self: *Self, context_name: []const u8) anyerror!*ScriptContext,
        destroyContext: *const fn (self: *Self, context: *ScriptContext) void,

        // Script execution
        loadScript: *const fn (context: *ScriptContext, source: []const u8, name: []const u8) anyerror!void,
        loadFile: *const fn (context: *ScriptContext, path: []const u8) anyerror!void,
        executeScript: *const fn (context: *ScriptContext, source: []const u8) anyerror!ScriptValue,
        executeFunction: *const fn (context: *ScriptContext, func_name: []const u8, args: []const ScriptValue) anyerror!ScriptValue,

        // Module system
        registerModule: *const fn (context: *ScriptContext, module: *const ScriptModule) anyerror!void,
        importModule: *const fn (context: *ScriptContext, module_name: []const u8) anyerror!void,

        // Global variable management
        setGlobal: *const fn (context: *ScriptContext, name: []const u8, value: ScriptValue) anyerror!void,
        getGlobal: *const fn (context: *ScriptContext, name: []const u8) anyerror!ScriptValue,

        // Error handling
        getLastError: *const fn (context: *ScriptContext) ?ScriptError,
        clearErrors: *const fn (context: *ScriptContext) void,

        // Memory management
        collectGarbage: *const fn (context: *ScriptContext) void,
        getMemoryUsage: *const fn (context: *ScriptContext) usize,

        // Debugging support (optional)
        setBreakpoint: ?*const fn (context: *ScriptContext, file: []const u8, line: u32) anyerror!void = null,
        removeBreakpoint: ?*const fn (context: *ScriptContext, file: []const u8, line: u32) void = null,
        getStackTrace: ?*const fn (context: *ScriptContext) anyerror![]const u8 = null,
    };

    // Convenience methods that delegate to vtable
    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        _ = allocator;
        _ = config;
        return error.NotImplemented; // Engines create instances, not this interface
    }

    pub fn deinit(self: *Self) void {
        self.vtable.deinit(self);
    }

    pub fn createContext(self: *Self, name: []const u8) !*ScriptContext {
        return self.vtable.createContext(self, name);
    }

    pub fn destroyContext(self: *Self, context: *ScriptContext) void {
        self.vtable.destroyContext(self, context);
    }

    pub fn loadScript(self: *Self, context: *ScriptContext, source: []const u8, name: []const u8) !void {
        return self.vtable.loadScript(context, source, name);
    }

    pub fn executeScript(self: *Self, context: *ScriptContext, source: []const u8) !ScriptValue {
        return self.vtable.executeScript(context, source);
    }

    pub fn executeFunction(self: *Self, context: *ScriptContext, func_name: []const u8, args: []const ScriptValue) !ScriptValue {
        return self.vtable.executeFunction(context, func_name, args);
    }

    pub fn registerModule(self: *Self, context: *ScriptContext, module: *const ScriptModule) !void {
        return self.vtable.registerModule(context, module);
    }

    pub fn setGlobal(self: *Self, context: *ScriptContext, name: []const u8, value: ScriptValue) !void {
        return self.vtable.setGlobal(context, name, value);
    }

    pub fn getGlobal(self: *Self, context: *ScriptContext, name: []const u8) !ScriptValue {
        return self.vtable.getGlobal(context, name);
    }

    pub fn getLastError(self: *Self, context: *ScriptContext) ?ScriptError {
        return self.vtable.getLastError(context);
    }

    pub fn clearErrors(self: *Self, context: *ScriptContext) void {
        self.vtable.clearErrors(context);
    }

    pub fn collectGarbage(self: *Self, context: *ScriptContext) void {
        self.vtable.collectGarbage(context);
    }

    pub fn getMemoryUsage(self: *Self, context: *ScriptContext) usize {
        return self.vtable.getMemoryUsage(context);
    }
};

// Tests
test "ScriptingEngine interface" {
    const testing = std.testing;

    // Test EngineConfig defaults
    const config = EngineConfig{};
    try testing.expectEqual(@as(usize, 0), config.max_memory_bytes);
    try testing.expectEqual(@as(u32, 0), config.max_execution_time_ms);
    try testing.expectEqual(false, config.enable_debugging);
    try testing.expectEqual(EngineConfig.SandboxLevel.restricted, config.sandbox_level);
}

test "ScriptModule structure" {
    const testing = std.testing;

    // Test module definition
    const test_module = ScriptModule{
        .name = "test_module",
        .functions = &[_]ScriptModule.FunctionDef{
            .{
                .name = "test_func",
                .arity = 2,
                .callback = struct {
                    fn callback(context: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue {
                        _ = context;
                        _ = args;
                        return ScriptValue.nil;
                    }
                }.callback,
                .description = "Test function",
            },
        },
        .constants = &[_]ScriptModule.ConstantDef{
            .{
                .name = "TEST_CONST",
                .value = ScriptValue{ .integer = 42 },
                .description = "Test constant",
            },
        },
        .description = "Test module",
    };

    try testing.expectEqualStrings("test_module", test_module.name);
    try testing.expectEqual(@as(usize, 1), test_module.functions.len);
    try testing.expectEqual(@as(usize, 1), test_module.constants.len);
}
