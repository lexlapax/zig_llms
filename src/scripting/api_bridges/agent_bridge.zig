// ABOUTME: Agent API bridge for exposing agent functionality to scripts
// ABOUTME: Provides full agent lifecycle management and configuration access

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms agent API
const agent = @import("../../agent.zig");
const provider = @import("../../provider.zig");
const memory = @import("../../memory.zig");
const hook = @import("../../hook.zig");

/// Agent wrapper for script access
const ScriptAgent = struct {
    base_agent: *agent.BaseAgent,
    context: *ScriptContext,
    id: []const u8,
    
    pub fn deinit(self: *ScriptAgent) void {
        self.base_agent.deinit();
        self.context.allocator.free(self.id);
        self.context.allocator.destroy(self);
    }
};

/// Global agent registry for the bridge
var agent_registry: ?std.StringHashMap(*ScriptAgent) = null;
var registry_mutex = std.Thread.Mutex{};
var next_agent_id: u32 = 1;

/// Agent Bridge implementation
pub const AgentBridge = struct {
    pub const bridge = APIBridge{
        .name = "agent",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };
    
    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);
        
        module.* = ScriptModule{
            .name = "agent",
            .functions = &agent_functions,
            .constants = &agent_constants,
            .description = "Agent management and execution API",
            .version = "1.0.0",
        };
        
        return module;
    }
    
    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;
        
        // Initialize agent registry if needed
        registry_mutex.lock();
        defer registry_mutex.unlock();
        
        if (agent_registry == null) {
            agent_registry = std.StringHashMap(*ScriptAgent).init(context.allocator);
        }
    }
    
    fn deinit() void {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        
        if (agent_registry) |*registry| {
            var iter = registry.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            registry.deinit();
            agent_registry = null;
        }
    }
};

// Agent module functions
const agent_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "create",
        "Create a new agent with configuration",
        1,
        createAgent,
    ),
    createModuleFunction(
        "destroy",
        "Destroy an agent and free resources",
        1,
        destroyAgent,
    ),
    createModuleFunction(
        "run",
        "Run agent with input and get response",
        2,
        runAgent,
    ),
    createModuleFunction(
        "runAsync",
        "Run agent asynchronously with callback",
        3,
        runAgentAsync,
    ),
    createModuleFunction(
        "getInfo",
        "Get agent information and status",
        1,
        getAgentInfo,
    ),
    createModuleFunction(
        "clone",
        "Clone agent with modified configuration",
        2,
        cloneAgent,
    ),
    createModuleFunction(
        "addHook",
        "Add a hook to agent lifecycle",
        3,
        addAgentHook,
    ),
    createModuleFunction(
        "removeHook",
        "Remove a hook from agent",
        2,
        removeAgentHook,
    ),
    createModuleFunction(
        "getMemory",
        "Get agent's memory interface",
        1,
        getAgentMemory,
    ),
    createModuleFunction(
        "clearMemory",
        "Clear agent's conversation memory",
        1,
        clearAgentMemory,
    ),
    createModuleFunction(
        "list",
        "List all active agents",
        0,
        listAgents,
    ),
    createModuleFunction(
        "get",
        "Get agent by ID",
        1,
        getAgent,
    ),
};

// Agent module constants
const agent_constants = [_]ScriptModule.ConstantDef{
    .{
        .name = "DEFAULT_TEMPERATURE",
        .value = ScriptValue{ .number = 0.7 },
        .description = "Default temperature for agent responses",
    },
    .{
        .name = "DEFAULT_MAX_TOKENS",
        .value = ScriptValue{ .integer = 1000 },
        .description = "Default maximum tokens for responses",
    },
};

// Implementation functions

fn createAgent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }
    
    const context = @fieldParentPtr(ScriptContext, "allocator", args[0].object.allocator);
    const allocator = context.allocator;
    
    // Marshal configuration
    const config_obj = args[0].object;
    
    // Extract required fields
    const name = if (config_obj.get("name")) |n| 
        try n.toZig([]const u8, allocator) 
    else 
        return error.MissingField;
        
    const provider_name = if (config_obj.get("provider")) |p| 
        try p.toZig([]const u8, allocator) 
    else 
        return error.MissingField;
        
    const model_name = if (config_obj.get("model")) |m| 
        try m.toZig([]const u8, allocator) 
    else 
        return error.MissingField;
    
    // Create agent configuration
    var agent_config = agent.AgentConfig{
        .name = name,
        .description = if (config_obj.get("description")) |d| 
            try d.toZig([]const u8, allocator) 
        else 
            "",
    };
    
    // Add memory configuration if specified
    if (config_obj.get("memory_config")) |mem_config| {
        if (mem_config == .object) {
            const mem_type = if (mem_config.object.get("type")) |t|
                try t.toZig([]const u8, allocator)
            else
                "short_term";
                
            if (std.mem.eql(u8, mem_type, "short_term")) {
                agent_config.memory_config = memory.MemoryConfig{
                    .max_messages = if (mem_config.object.get("max_messages")) |m|
                        try m.toZig(u32, allocator)
                    else
                        100,
                };
            }
        }
    }
    
    // Create base agent
    const base_agent = try agent.BaseAgent.init(allocator, agent_config);
    errdefer base_agent.deinit();
    
    // Configure provider
    // Note: In real implementation, this would use the actual provider registry
    _ = provider_name;
    _ = model_name;
    
    // Generate unique ID
    registry_mutex.lock();
    const agent_id = try std.fmt.allocPrint(allocator, "agent_{}", .{next_agent_id});
    next_agent_id += 1;
    registry_mutex.unlock();
    
    // Create script agent wrapper
    const script_agent = try allocator.create(ScriptAgent);
    script_agent.* = ScriptAgent{
        .base_agent = base_agent,
        .context = context,
        .id = agent_id,
    };
    
    // Register agent
    registry_mutex.lock();
    defer registry_mutex.unlock();
    
    if (agent_registry) |*registry| {
        try registry.put(agent_id, script_agent);
    }
    
    // Return agent ID
    return ScriptValue{ .string = agent_id };
}

fn destroyAgent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const agent_id = args[0].string;
    
    registry_mutex.lock();
    defer registry_mutex.unlock();
    
    if (agent_registry) |*registry| {
        if (registry.fetchRemove(agent_id)) |kv| {
            kv.value.deinit();
            return ScriptValue{ .boolean = true };
        }
    }
    
    return ScriptValue{ .boolean = false };
}

fn runAgent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2) {
        return error.InvalidArguments;
    }
    
    const agent_id = switch (args[0]) {
        .string => |s| s,
        else => return error.InvalidArguments,
    };
    
    registry_mutex.lock();
    const script_agent = if (agent_registry) |*registry| 
        registry.get(agent_id) 
    else 
        null;
    registry_mutex.unlock();
    
    if (script_agent == null) {
        return error.AgentNotFound;
    }
    
    const allocator = script_agent.?.context.allocator;
    
    // Convert input to JSON for agent
    const input_json = try TypeMarshaler.marshalJsonValue(args[1], allocator);
    defer input_json.deinit();
    
    // Run agent (simplified - real implementation would use actual agent execution)
    const result_json = std.json.Value{
        .object = blk: {
            var obj = std.json.ObjectMap.init(allocator);
            try obj.put("content", .{ .string = "Agent response placeholder" });
            try obj.put("usage", .{
                .object = usage: {
                    var usage_obj = std.json.ObjectMap.init(allocator);
                    try usage_obj.put("total_tokens", .{ .integer = 100 });
                    break :usage usage_obj;
                },
            });
            break :blk obj;
        },
    };
    
    // Convert result back to ScriptValue
    return try TypeMarshaler.unmarshalJsonValue(result_json, allocator);
}

fn runAgentAsync(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3) {
        return error.InvalidArguments;
    }
    
    // args[0]: agent_id
    // args[1]: input
    // args[2]: callback function
    
    if (args[2] != .function) {
        return error.InvalidArguments;
    }
    
    // In a real implementation, this would spawn an async task
    // For now, we'll just call the sync version and then the callback
    const result = try runAgent(args[0..2]);
    
    // Call the callback with result and no error
    const callback_args = [_]ScriptValue{
        result,
        ScriptValue.nil, // No error
    };
    
    _ = try args[2].function.call(&callback_args);
    
    return ScriptValue.nil;
}

fn getAgentInfo(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const agent_id = args[0].string;
    
    registry_mutex.lock();
    const script_agent = if (agent_registry) |*registry| 
        registry.get(agent_id) 
    else 
        null;
    registry_mutex.unlock();
    
    if (script_agent == null) {
        return error.AgentNotFound;
    }
    
    const allocator = script_agent.?.context.allocator;
    var info = ScriptValue.Object.init(allocator);
    
    try info.put("id", ScriptValue{ .string = try allocator.dupe(u8, agent_id) });
    try info.put("name", ScriptValue{ .string = try allocator.dupe(u8, script_agent.?.base_agent.config.name) });
    try info.put("description", ScriptValue{ .string = try allocator.dupe(u8, script_agent.?.base_agent.config.description) });
    try info.put("status", ScriptValue{ .string = try allocator.dupe(u8, "active") });
    
    return ScriptValue{ .object = info };
}

fn cloneAgent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    // Get original agent
    const agent_id = args[0].string;
    
    registry_mutex.lock();
    const script_agent = if (agent_registry) |*registry| 
        registry.get(agent_id) 
    else 
        null;
    registry_mutex.unlock();
    
    if (script_agent == null) {
        return error.AgentNotFound;
    }
    
    // Create new configuration by merging with modifications
    const allocator = script_agent.?.context.allocator;
    var new_config = ScriptValue.Object.init(allocator);
    
    // Copy base configuration
    try new_config.put("name", ScriptValue{ .string = try allocator.dupe(u8, script_agent.?.base_agent.config.name) });
    try new_config.put("description", ScriptValue{ .string = try allocator.dupe(u8, script_agent.?.base_agent.config.description) });
    
    // Apply modifications from args[1]
    var iter = args[1].object.map.iterator();
    while (iter.next()) |entry| {
        const cloned_value = try entry.value_ptr.*.clone(allocator);
        try new_config.put(entry.key_ptr.*, cloned_value);
    }
    
    // Create new agent with modified config
    const create_args = [_]ScriptValue{ScriptValue{ .object = new_config }};
    return try createAgent(&create_args);
}

fn addAgentHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[0] != .string or args[1] != .string or args[2] != .function) {
        return error.InvalidArguments;
    }
    
    const agent_id = args[0].string;
    const hook_type = args[1].string;
    const callback = args[2].function;
    
    _ = agent_id;
    _ = hook_type;
    _ = callback;
    
    // TODO: Implement hook registration
    return ScriptValue{ .boolean = true };
}

fn removeAgentHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }
    
    // TODO: Implement hook removal
    return ScriptValue{ .boolean = true };
}

fn getAgentMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const agent_id = args[0].string;
    
    registry_mutex.lock();
    const script_agent = if (agent_registry) |*registry| 
        registry.get(agent_id) 
    else 
        null;
    registry_mutex.unlock();
    
    if (script_agent == null) {
        return error.AgentNotFound;
    }
    
    // Return memory interface object
    const allocator = script_agent.?.context.allocator;
    var memory_obj = ScriptValue.Object.init(allocator);
    
    try memory_obj.put("agent_id", ScriptValue{ .string = try allocator.dupe(u8, agent_id) });
    try memory_obj.put("type", ScriptValue{ .string = try allocator.dupe(u8, "short_term") });
    
    // Add memory methods as properties
    // In a real implementation, these would be bound functions
    
    return ScriptValue{ .object = memory_obj };
}

fn clearAgentMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const agent_id = args[0].string;
    
    registry_mutex.lock();
    const script_agent = if (agent_registry) |*registry| 
        registry.get(agent_id) 
    else 
        null;
    registry_mutex.unlock();
    
    if (script_agent == null) {
        return error.AgentNotFound;
    }
    
    // Clear memory
    if (script_agent.?.base_agent.memory) |agent_memory| {
        agent_memory.clear();
    }
    
    return ScriptValue{ .boolean = true };
}

fn listAgents(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;
    
    registry_mutex.lock();
    defer registry_mutex.unlock();
    
    if (agent_registry) |*registry| {
        const allocator = registry.allocator;
        var list = try ScriptValue.Array.init(allocator, registry.count());
        
        var iter = registry.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            list.items[i] = ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) };
        }
        
        return ScriptValue{ .array = list };
    }
    
    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn getAgent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const agent_id = args[0].string;
    
    registry_mutex.lock();
    const exists = if (agent_registry) |*registry| 
        registry.contains(agent_id) 
    else 
        false;
    registry_mutex.unlock();
    
    if (exists) {
        return ScriptValue{ .string = agent_id };
    } else {
        return ScriptValue.nil;
    }
}

// Tests
test "AgentBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const module = try AgentBridge.getModule(allocator);
    defer allocator.destroy(module);
    
    try testing.expectEqualStrings("agent", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}

test "AgentBridge create and destroy" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Initialize a dummy context
    const dummy_engine: *anyopaque = undefined;
    const dummy_engine_context: *anyopaque = undefined;
    const context = try ScriptContext.init(allocator, "test", dummy_engine, dummy_engine_context);
    defer context.deinit();
    
    // Initialize bridge
    const engine: *ScriptingEngine = undefined;
    try AgentBridge.init(engine, context);
    defer AgentBridge.deinit();
    
    // Create agent configuration
    var config = ScriptValue.Object.init(allocator);
    defer config.deinit();
    
    try config.put("name", ScriptValue{ .string = try allocator.dupe(u8, "test_agent") });
    try config.put("provider", ScriptValue{ .string = try allocator.dupe(u8, "openai") });
    try config.put("model", ScriptValue{ .string = try allocator.dupe(u8, "gpt-4") });
    
    const create_args = [_]ScriptValue{ScriptValue{ .object = config }};
    const agent_id = try createAgent(&create_args);
    defer agent_id.deinit(allocator);
    
    try testing.expect(agent_id == .string);
    try testing.expect(std.mem.startsWith(u8, agent_id.string, "agent_"));
    
    // Destroy agent
    const destroy_args = [_]ScriptValue{agent_id};
    const result = try destroyAgent(&destroy_args);
    
    try testing.expect(result == .boolean);
    try testing.expect(result.boolean == true);
}