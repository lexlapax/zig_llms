// ABOUTME: Lua API bridge integration layer for exposing all zig_llms APIs to Lua scripts
// ABOUTME: Provides C function wrappers and registration system for all 10 API bridges

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const LuaValueConverter = @import("lua_value_converter.zig");

// Import all API bridges
const AgentBridge = @import("../api_bridges/agent_bridge.zig").AgentBridge;
const ToolBridge = @import("../api_bridges/tool_bridge.zig").ToolBridge;
const WorkflowBridge = @import("../api_bridges/workflow_bridge.zig").WorkflowBridge;
const ProviderBridge = @import("../api_bridges/provider_bridge.zig").ProviderBridge;
const EventBridge = @import("../api_bridges/event_bridge.zig").EventBridge;
const TestBridge = @import("../api_bridges/test_bridge.zig").TestBridge;
const SchemaBridge = @import("../api_bridges/schema_bridge.zig").SchemaBridge;
const MemoryBridge = @import("../api_bridges/memory_bridge.zig").MemoryBridge;
const HookBridge = @import("../api_bridges/hook_bridge.zig").HookBridge;
const OutputBridge = @import("../api_bridges/output_bridge.zig").OutputBridge;

// Import Lua C bridge implementations
const LuaAgentBridge = @import("lua_bridges/agent_bridge.zig");
const LuaToolBridge = @import("lua_bridges/tool_bridge.zig");
const LuaWorkflowBridge = @import("lua_bridges/workflow_bridge.zig");
const LuaProviderBridge = @import("lua_bridges/provider_bridge.zig");
const LuaEventBridge = @import("lua_bridges/event_bridge.zig");
const LuaTestBridge = @import("lua_bridges/test_bridge.zig");
const LuaSchemaBridge = @import("lua_bridges/schema_bridge.zig");
const LuaMemoryBridge = @import("lua_bridges/memory_bridge.zig");
const LuaHookBridge = @import("lua_bridges/hook_bridge.zig");
const LuaOutputBridge = @import("lua_bridges/output_bridge.zig");

/// Lua API bridge integration errors
pub const LuaAPIBridgeError = error{
    RegistrationFailed,
    BridgeNotFound,
    InvalidArguments,
    ScriptContextRequired,
    LuaNotEnabled,
} || std.mem.Allocator.Error;

/// Bridge registration information
pub const BridgeInfo = struct {
    name: []const u8,
    description: []const u8,
    version: []const u8,
    function_count: usize,
    registration_func: *const fn (*LuaWrapper, *ScriptContext) LuaAPIBridgeError!void,
    cleanup_func: ?*const fn () void = null,
};

/// Lua API bridge manager
pub const LuaAPIBridge = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    registered_bridges: std.StringHashMap(BridgeInfo),
    optimization_config: OptimizationConfig,
    metrics: BridgeMetrics,

    pub const OptimizationConfig = struct {
        enable_batching: bool = true,
        enable_stack_presize: bool = true,
        enable_memoization: bool = false,
        enable_profiling: bool = false,
        batch_size: usize = 10,
        stack_presize_hint: usize = 8,
        memoization_cache_size: usize = 1000,
    };

    pub const BridgeMetrics = struct {
        call_count: u64 = 0,
        total_execution_time_ns: u64 = 0,
        error_count: u64 = 0,
        cache_hits: u64 = 0,
        cache_misses: u64 = 0,

        pub fn getAverageCallTime(self: *const BridgeMetrics) f64 {
            if (self.call_count == 0) return 0.0;
            return @as(f64, @floatFromInt(self.total_execution_time_ns)) / @as(f64, @floatFromInt(self.call_count));
        }

        pub fn getCacheHitRate(self: *const BridgeMetrics) f64 {
            const total_cache_access = self.cache_hits + self.cache_misses;
            if (total_cache_access == 0) return 0.0;
            return @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total_cache_access));
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: OptimizationConfig) !*Self {
        if (!lua.lua_enabled) return LuaAPIBridgeError.LuaNotEnabled;

        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .registered_bridges = std.StringHashMap(BridgeInfo).init(allocator),
            .optimization_config = config,
            .metrics = BridgeMetrics{},
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Clean up all registered bridges
        var iter = self.registered_bridges.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.cleanup_func) |cleanup| {
                cleanup();
            }
        }

        self.registered_bridges.deinit();
        self.allocator.destroy(self);
    }

    /// Register all zig_llms API bridges with Lua
    pub fn registerAllBridges(self: *Self, wrapper: *LuaWrapper, context: *ScriptContext) !void {
        // Define all bridge registrations
        const bridges = [_]BridgeInfo{
            .{
                .name = "agent",
                .description = "Agent management and execution API",
                .version = "1.0.0",
                .function_count = LuaAgentBridge.FUNCTION_COUNT,
                .registration_func = LuaAgentBridge.register,
                .cleanup_func = LuaAgentBridge.cleanup,
            },
            .{
                .name = "tool",
                .description = "Tool registration and execution API",
                .version = "1.0.0",
                .function_count = LuaToolBridge.FUNCTION_COUNT,
                .registration_func = LuaToolBridge.register,
                .cleanup_func = LuaToolBridge.cleanup,
            },
            .{
                .name = "workflow",
                .description = "Workflow orchestration and execution API",
                .version = "1.0.0",
                .function_count = LuaWorkflowBridge.FUNCTION_COUNT,
                .registration_func = LuaWorkflowBridge.register,
                .cleanup_func = LuaWorkflowBridge.cleanup,
            },
            .{
                .name = "provider",
                .description = "LLM provider access and configuration API",
                .version = "1.0.0",
                .function_count = LuaProviderBridge.FUNCTION_COUNT,
                .registration_func = LuaProviderBridge.register,
                .cleanup_func = LuaProviderBridge.cleanup,
            },
            .{
                .name = "event",
                .description = "Event emission and subscription API",
                .version = "1.0.0",
                .function_count = LuaEventBridge.FUNCTION_COUNT,
                .registration_func = LuaEventBridge.register,
                .cleanup_func = LuaEventBridge.cleanup,
            },
            .{
                .name = "test",
                .description = "Testing and mocking framework API",
                .version = "1.0.0",
                .function_count = LuaTestBridge.FUNCTION_COUNT,
                .registration_func = LuaTestBridge.register,
                .cleanup_func = LuaTestBridge.cleanup,
            },
            .{
                .name = "schema",
                .description = "JSON schema validation and generation API",
                .version = "1.0.0",
                .function_count = LuaSchemaBridge.FUNCTION_COUNT,
                .registration_func = LuaSchemaBridge.register,
                .cleanup_func = LuaSchemaBridge.cleanup,
            },
            .{
                .name = "memory",
                .description = "Memory management and conversation history API",
                .version = "1.0.0",
                .function_count = LuaMemoryBridge.FUNCTION_COUNT,
                .registration_func = LuaMemoryBridge.register,
                .cleanup_func = LuaMemoryBridge.cleanup,
            },
            .{
                .name = "hook",
                .description = "Lifecycle hooks and middleware API",
                .version = "1.0.0",
                .function_count = LuaHookBridge.FUNCTION_COUNT,
                .registration_func = LuaHookBridge.register,
                .cleanup_func = LuaHookBridge.cleanup,
            },
            .{
                .name = "output",
                .description = "Output parsing and format detection API",
                .version = "1.0.0",
                .function_count = LuaOutputBridge.FUNCTION_COUNT,
                .registration_func = LuaOutputBridge.register,
                .cleanup_func = LuaOutputBridge.cleanup,
            },
        };

        // Create main zigllms global table
        lua.c.lua_newtable(wrapper.state);
        const zigllms_table_idx = lua.c.lua_gettop(wrapper.state);

        // Register each bridge
        for (bridges) |bridge_info| {
            std.log.info("Registering Lua bridge: {s}", .{bridge_info.name});

            // Create module table
            lua.c.lua_newtable(wrapper.state);
            const module_table_idx = lua.c.lua_gettop(wrapper.state);

            // Store reference to this table in the bridge registry for cleanup
            try self.registered_bridges.put(try self.allocator.dupe(u8, bridge_info.name), bridge_info);

            // Register the bridge functions
            try bridge_info.registration_func(wrapper, context);

            // Set module table in zigllms
            lua.c.lua_setfield(wrapper.state, zigllms_table_idx, bridge_info.name.ptr);

            std.log.info("Registered {s} bridge with {} functions", .{ bridge_info.name, bridge_info.function_count });
        }

        // Add version and metadata to zigllms table
        lua.c.lua_pushstring(wrapper.state, "1.0.0");
        lua.c.lua_setfield(wrapper.state, zigllms_table_idx, "version");

        lua.c.lua_pushstring(wrapper.state, "zig_llms Lua API Bridge");
        lua.c.lua_setfield(wrapper.state, zigllms_table_idx, "description");

        // Add utility functions
        self.registerUtilityFunctions(wrapper, zigllms_table_idx);

        // Set as global zigllms
        lua.c.lua_setglobal(wrapper.state, "zigllms");

        std.log.info("Successfully registered all {} API bridges", .{bridges.len});
    }

    /// Register utility functions for bridge management
    fn registerUtilityFunctions(self: *Self, wrapper: *LuaWrapper, table_idx: c_int) void {
        _ = self;

        // Help function
        lua.c.lua_pushcfunction(wrapper.state, luaHelp);
        lua.c.lua_setfield(wrapper.state, table_idx, "help");

        // List available modules
        lua.c.lua_pushcfunction(wrapper.state, luaListModules);
        lua.c.lua_setfield(wrapper.state, table_idx, "modules");

        // Get version info
        lua.c.lua_pushcfunction(wrapper.state, luaVersionInfo);
        lua.c.lua_setfield(wrapper.state, table_idx, "info");

        // Performance metrics
        lua.c.lua_pushcfunction(wrapper.state, luaGetMetrics);
        lua.c.lua_setfield(wrapper.state, table_idx, "metrics");
    }

    /// Get bridge by name
    pub fn getBridge(self: *Self, name: []const u8) ?BridgeInfo {
        return self.registered_bridges.get(name);
    }

    /// Record a bridge call for metrics
    pub fn recordCall(self: *Self, execution_time_ns: u64, success: bool) void {
        self.metrics.call_count += 1;
        self.metrics.total_execution_time_ns += execution_time_ns;
        if (!success) {
            self.metrics.error_count += 1;
        }
    }

    /// Record cache hit/miss for memoization
    pub fn recordCacheAccess(self: *Self, hit: bool) void {
        if (hit) {
            self.metrics.cache_hits += 1;
        } else {
            self.metrics.cache_misses += 1;
        }
    }
};

// Utility Lua C functions

/// zigllms.help() - Show available modules and functions
export fn luaHelp(L: ?*lua.c.lua_State) c_int {
    const help_text =
        \\zigllms - zig_llms Lua API Bridge
        \\
        \\Available modules:
        \\  agent     - Agent management and execution
        \\  tool      - Tool registration and execution  
        \\  workflow  - Workflow orchestration
        \\  provider  - LLM provider access
        \\  event     - Event emission and subscription
        \\  test      - Testing and mocking framework
        \\  schema    - JSON schema validation
        \\  memory    - Memory and conversation history
        \\  hook      - Lifecycle hooks and middleware
        \\  output    - Output parsing and formatting
        \\
        \\Utility functions:
        \\  zigllms.modules()  - List all available modules
        \\  zigllms.info()     - Get version and build information
        \\  zigllms.metrics()  - Get performance metrics
        \\
        \\Example usage:
        \\  local agent = zigllms.agent.create({name="assistant", provider="openai"})
        \\  local response = zigllms.agent.run(agent, "Hello, world!")
        \\  print(response.content)
    ;

    lua.c.lua_pushstring(L, help_text);
    return 1;
}

/// zigllms.modules() - List all available modules
export fn luaListModules(L: ?*lua.c.lua_State) c_int {
    const modules = [_][]const u8{ "agent", "tool", "workflow", "provider", "event", "test", "schema", "memory", "hook", "output" };

    lua.c.lua_createtable(L, @intCast(modules.len), 0);

    for (modules, 0..) |module, i| {
        lua.c.lua_pushstring(L, module.ptr);
        lua.c.lua_seti(L, -2, @intCast(i + 1));
    }

    return 1;
}

/// zigllms.info() - Get version and build information
export fn luaVersionInfo(L: ?*lua.c.lua_State) c_int {
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "1.0.0");
    lua.c.lua_setfield(L, -2, "version");

    lua.c.lua_pushstring(L, "zig_llms");
    lua.c.lua_setfield(L, -2, "library");

    lua.c.lua_pushstring(L, "Lua 5.4");
    lua.c.lua_setfield(L, -2, "lua_version");

    lua.c.lua_pushinteger(L, @intCast(std.time.timestamp()));
    lua.c.lua_setfield(L, -2, "build_time");

    lua.c.lua_pushstring(L, @tagName(std.builtin.target.os.tag));
    lua.c.lua_setfield(L, -2, "platform");

    return 1;
}

/// zigllms.metrics() - Get performance metrics
export fn luaGetMetrics(L: ?*lua.c.lua_State) c_int {
    // This would ideally access the actual metrics from the bridge manager
    // For now, return placeholder metrics
    lua.c.lua_newtable(L);

    lua.c.lua_pushinteger(L, 0);
    lua.c.lua_setfield(L, -2, "total_calls");

    lua.c.lua_pushnumber(L, 0.0);
    lua.c.lua_setfield(L, -2, "avg_call_time_ms");

    lua.c.lua_pushinteger(L, 0);
    lua.c.lua_setfield(L, -2, "error_count");

    lua.c.lua_pushnumber(L, 0.0);
    lua.c.lua_setfield(L, -2, "cache_hit_rate");

    return 1;
}

/// Presize Lua stack for optimal performance
pub fn presizeStack(wrapper: *LuaWrapper, expected_values: usize) void {
    if (expected_values > 0) {
        lua.c.lua_checkstack(wrapper.state, @intCast(expected_values));
    }
}

/// Common error handling wrapper for bridge functions
pub fn handleBridgeError(L: ?*lua.c.lua_State, err: anyerror) c_int {
    const error_msg = switch (err) {
        error.OutOfMemory => "Out of memory",
        error.InvalidArguments => "Invalid arguments provided",
        error.ScriptContextRequired => "Script context required",
        error.LuaNotEnabled => "Lua support not enabled",
        LuaAPIBridgeError.RegistrationFailed => "Bridge registration failed",
        LuaAPIBridgeError.BridgeNotFound => "Bridge not found",
        else => "Unknown error occurred",
    };

    return lua.c.luaL_error(L, "%s", error_msg.ptr);
}

/// Extract ScriptContext from Lua registry
pub fn getScriptContext(L: ?*lua.c.lua_State) ?*ScriptContext {
    lua.c.lua_getfield(L, lua.c.LUA_REGISTRYINDEX, "SCRIPT_CONTEXT");
    const context_ptr = lua.c.lua_touserdata(L, -1);
    lua.c.lua_pop(L, 1);

    if (context_ptr == null) return null;
    return @ptrCast(@alignCast(context_ptr));
}

/// Store ScriptContext in Lua registry for access by bridge functions
pub fn setScriptContext(L: ?*lua.c.lua_State, context: *ScriptContext) void {
    lua.c.lua_pushlightuserdata(L, context);
    lua.c.lua_setfield(L, lua.c.LUA_REGISTRYINDEX, "SCRIPT_CONTEXT");
}
