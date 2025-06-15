// ABOUTME: Module system for automatic zig_llms API exposure to scripts
// ABOUTME: Generates and manages script bindings for all zig_llms functionality

const std = @import("std");
const ScriptModule = @import("interface.zig").ScriptModule;
const ScriptValue = @import("value_bridge.zig").ScriptValue;
const ScriptContext = @import("context.zig").ScriptContext;
const ScriptingEngine = @import("interface.zig").ScriptingEngine;

/// API Bridge interface for exposing zig_llms APIs
pub const APIBridge = struct {
    /// Module name (e.g., "agent", "tool", "workflow")
    name: []const u8,
    
    /// Get the module definition
    getModule: *const fn (allocator: std.mem.Allocator) anyerror!*ScriptModule,
    
    /// Initialize the bridge (register native functions, etc.)
    init: *const fn (engine: *ScriptingEngine, context: *ScriptContext) anyerror!void,
    
    /// Cleanup
    deinit: *const fn () void,
};

/// Module loader configuration
pub const ModuleLoaderConfig = struct {
    /// Enable lazy loading of modules
    lazy_loading: bool = true,
    
    /// Enable module caching
    caching: bool = true,
    
    /// Module path prefixes
    path_prefixes: []const []const u8 = &[_][]const u8{"zigllms"},
    
    /// Auto-import these modules into every context
    auto_imports: []const []const u8 = &[_][]const u8{},
};

/// Module system manager
pub const ModuleSystem = struct {
    const Self = @This();
    
    /// Registered API bridges
    bridges: std.StringHashMap(*const APIBridge),
    
    /// Loaded modules cache
    module_cache: std.StringHashMap(*ScriptModule),
    
    /// Configuration
    config: ModuleLoaderConfig,
    
    /// Allocator
    allocator: std.mem.Allocator,
    
    /// Mutex for thread safety
    mutex: std.Thread.Mutex,
    
    pub fn init(allocator: std.mem.Allocator, config: ModuleLoaderConfig) Self {
        return Self{
            .bridges = std.StringHashMap(*const APIBridge).init(allocator),
            .module_cache = std.StringHashMap(*ScriptModule).init(allocator),
            .config = config,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up bridges
        var bridge_iter = self.bridges.iterator();
        while (bridge_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.bridges.deinit();
        
        // Clean up cached modules
        var module_iter = self.module_cache.iterator();
        while (module_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.module_cache.deinit();
    }
    
    /// Register an API bridge
    pub fn registerBridge(self: *Self, bridge: *const APIBridge) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const owned_name = try self.allocator.dupe(u8, bridge.name);
        try self.bridges.put(owned_name, bridge);
    }
    
    /// Generate all bindings for an engine
    pub fn generateBindings(self: *Self, engine: *ScriptingEngine, context: *ScriptContext) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Register all API bridges
        var iter = self.bridges.iterator();
        while (iter.next()) |entry| {
            const bridge = entry.value_ptr.*;
            
            // Get or create module
            const module = if (self.config.caching) blk: {
                if (self.module_cache.get(bridge.name)) |cached| {
                    break :blk cached;
                }
                
                const new_module = try bridge.getModule(self.allocator);
                const owned_name = try self.allocator.dupe(u8, bridge.name);
                try self.module_cache.put(owned_name, new_module);
                break :blk new_module;
            } else try bridge.getModule(self.allocator);
            
            // Build full module name
            const full_name = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{
                self.config.path_prefixes[0],
                bridge.name,
            });
            defer self.allocator.free(full_name);
            
            // Create wrapper module with full name
            const wrapper = try self.allocator.create(ScriptModule);
            wrapper.* = module.*;
            wrapper.name = full_name;
            
            // Register module with engine
            try engine.registerModule(context, wrapper);
            
            // Initialize bridge
            try bridge.init(engine, context);
        }
        
        // Auto-import modules if configured
        for (self.config.auto_imports) |module_name| {
            try engine.vtable.importModule(context, module_name);
        }
    }
    
    /// Load a specific module
    pub fn loadModule(self: *Self, engine: *ScriptingEngine, context: *ScriptContext, module_name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Parse module name (e.g., "zigllms.agent" -> "agent")
        var parts = std.mem.tokenize(u8, module_name, ".");
        _ = parts.next(); // Skip prefix
        const bridge_name = parts.next() orelse return error.InvalidModuleName;
        
        const bridge = self.bridges.get(bridge_name) orelse return error.ModuleNotFound;
        
        // Get or create module
        const module = if (self.config.caching) blk: {
            if (self.module_cache.get(bridge_name)) |cached| {
                break :blk cached;
            }
            
            const new_module = try bridge.getModule(self.allocator);
            const owned_name = try self.allocator.dupe(u8, bridge_name);
            try self.module_cache.put(owned_name, new_module);
            break :blk new_module;
        } else try bridge.getModule(self.allocator);
        
        // Create wrapper with full name
        const wrapper = try self.allocator.create(ScriptModule);
        wrapper.* = module.*;
        wrapper.name = module_name;
        
        // Register and initialize
        try engine.registerModule(context, wrapper);
        try bridge.init(engine, context);
    }
    
    /// List available modules
    pub fn listModules(self: *Self, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var list = try allocator.alloc([]const u8, self.bridges.count());
        var iter = self.bridges.iterator();
        var i: usize = 0;
        
        while (iter.next()) |entry| {
            list[i] = try std.fmt.allocPrint(allocator, "{s}.{s}", .{
                self.config.path_prefixes[0],
                entry.key_ptr.*,
            });
            i += 1;
        }
        
        return list;
    }
};

/// Register all zig_llms API bridges
pub fn registerAllBridges(module_system: *ModuleSystem) !void {
    // These will be implemented in their respective files
    // For now, we'll create placeholder registrations
    
    const bridges = [_]struct {
        name: []const u8,
        file: []const u8,
    }{
        .{ .name = "agent", .file = "agent_bridge.zig" },
        .{ .name = "tool", .file = "tool_bridge.zig" },
        .{ .name = "workflow", .file = "workflow_bridge.zig" },
        .{ .name = "provider", .file = "provider_bridge.zig" },
        .{ .name = "event", .file = "event_bridge.zig" },
        .{ .name = "test", .file = "test_bridge.zig" },
        .{ .name = "schema", .file = "schema_bridge.zig" },
        .{ .name = "memory", .file = "memory_bridge.zig" },
        .{ .name = "hook", .file = "hook_bridge.zig" },
        .{ .name = "output", .file = "output_bridge.zig" },
    };
    
    _ = module_system;
    _ = bridges;
    
    // TODO: Import and register each bridge when implemented
}

/// Helper to create a module function that wraps a native function
pub fn createModuleFunction(
    comptime name: []const u8,
    comptime description: []const u8,
    comptime arity: ?u8,
    comptime func: anytype,
) ScriptModule.FunctionDef {
    const wrapper = struct {
        fn callback(context: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue {
            _ = context;
            return func(args);
        }
    }.callback;
    
    return ScriptModule.FunctionDef{
        .name = name,
        .arity = arity,
        .callback = wrapper,
        .description = description,
    };
}

/// Helper to create a module constant
pub fn createModuleConstant(
    comptime name: []const u8,
    value: ScriptValue,
    comptime description: []const u8,
) ScriptModule.ConstantDef {
    return ScriptModule.ConstantDef{
        .name = name,
        .value = value,
        .description = description,
    };
}

// Tests
test "ModuleSystem initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var module_system = ModuleSystem.init(allocator, .{});
    defer module_system.deinit();
    
    // Test with no bridges registered
    const modules = try module_system.listModules(allocator);
    defer allocator.free(modules);
    try testing.expectEqual(@as(usize, 0), modules.len);
}

test "ModuleSystem bridge registration" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var module_system = ModuleSystem.init(allocator, .{});
    defer module_system.deinit();
    
    // Create mock bridge
    const mock_bridge = struct {
        const bridge = APIBridge{
            .name = "test",
            .getModule = getModule,
            .init = init,
            .deinit = deinit,
        };
        
        fn getModule(alloc: std.mem.Allocator) anyerror!*ScriptModule {
            const module = try alloc.create(ScriptModule);
            module.* = ScriptModule{
                .name = "test",
                .functions = &[_]ScriptModule.FunctionDef{
                    createModuleFunction(
                        "testFunc",
                        "Test function",
                        1,
                        struct {
                            fn impl(args: []const ScriptValue) anyerror!ScriptValue {
                                _ = args;
                                return ScriptValue.nil;
                            }
                        }.impl,
                    ),
                },
                .constants = &[_]ScriptModule.ConstantDef{
                    createModuleConstant(
                        "TEST_CONST",
                        ScriptValue{ .integer = 42 },
                        "Test constant",
                    ),
                },
                .description = "Test module",
            };
            return module;
        }
        
        fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
            _ = engine;
            _ = context;
        }
        
        fn deinit() void {}
    };
    
    try module_system.registerBridge(&mock_bridge.bridge);
    
    const modules = try module_system.listModules(allocator);
    defer {
        for (modules) |module| {
            allocator.free(module);
        }
        allocator.free(modules);
    }
    
    try testing.expectEqual(@as(usize, 1), modules.len);
    try testing.expectEqualStrings("zigllms.test", modules[0]);
}

test "createModuleFunction helper" {
    const testing = std.testing;
    
    const func_def = createModuleFunction(
        "add",
        "Add two numbers",
        2,
        struct {
            fn add(args: []const ScriptValue) anyerror!ScriptValue {
                if (args.len != 2) return error.InvalidArguments;
                
                const a = switch (args[0]) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .number => |n| n,
                    else => return error.TypeMismatch,
                };
                
                const b = switch (args[1]) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .number => |n| n,
                    else => return error.TypeMismatch,
                };
                
                return ScriptValue{ .number = a + b };
            }
        }.add,
    );
    
    try testing.expectEqualStrings("add", func_def.name);
    try testing.expectEqual(@as(?u8, 2), func_def.arity);
    try testing.expectEqualStrings("Add two numbers", func_def.description);
}