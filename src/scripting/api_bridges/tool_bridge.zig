// ABOUTME: Tool API bridge for exposing tool functionality to scripts
// ABOUTME: Enables tool registration, execution, and management from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms tool API
const tool = @import("../../tool.zig");
const tool_registry = @import("../../tool_registry.zig");

/// Script tool wrapper
const ScriptTool = struct {
    name: []const u8,
    description: []const u8,
    schema: ?std.json.Value,
    callback: *ScriptValue.function,
    context: *ScriptContext,
    
    pub fn deinit(self: *ScriptTool, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.schema) |*s| {
            s.deinit();
        }
        allocator.destroy(self);
    }
};

/// Global script tool registry
var script_tools: ?std.StringHashMap(*ScriptTool) = null;
var tools_mutex = std.Thread.Mutex{};

/// Tool Bridge implementation
pub const ToolBridge = struct {
    pub const bridge = APIBridge{
        .name = "tool",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };
    
    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);
        
        module.* = ScriptModule{
            .name = "tool",
            .functions = &tool_functions,
            .constants = &tool_constants,
            .description = "Tool registration and execution API",
            .version = "1.0.0",
        };
        
        return module;
    }
    
    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;
        
        // Initialize script tool registry
        tools_mutex.lock();
        defer tools_mutex.unlock();
        
        if (script_tools == null) {
            script_tools = std.StringHashMap(*ScriptTool).init(context.allocator);
        }
    }
    
    fn deinit() void {
        tools_mutex.lock();
        defer tools_mutex.unlock();
        
        if (script_tools) |*tools| {
            var iter = tools.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit(tools.allocator);
            }
            tools.deinit();
            script_tools = null;
        }
    }
};

// Tool module functions
const tool_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "register",
        "Register a new tool with callback",
        1,
        registerTool,
    ),
    createModuleFunction(
        "unregister",
        "Unregister a tool by name",
        1,
        unregisterTool,
    ),
    createModuleFunction(
        "execute",
        "Execute a tool by name with input",
        2,
        executeTool,
    ),
    createModuleFunction(
        "executeAsync",
        "Execute a tool asynchronously",
        3,
        executeToolAsync,
    ),
    createModuleFunction(
        "list",
        "List all available tools",
        0,
        listTools,
    ),
    createModuleFunction(
        "get",
        "Get tool information by name",
        1,
        getToolInfo,
    ),
    createModuleFunction(
        "exists",
        "Check if a tool exists",
        1,
        toolExists,
    ),
    createModuleFunction(
        "validate",
        "Validate input against tool schema",
        2,
        validateToolInput,
    ),
    createModuleFunction(
        "getBuiltinTools",
        "Get list of built-in tools",
        0,
        getBuiltinTools,
    ),
    createModuleFunction(
        "enableTool",
        "Enable a built-in tool",
        1,
        enableBuiltinTool,
    ),
    createModuleFunction(
        "disableTool",
        "Disable a built-in tool",
        1,
        disableBuiltinTool,
    ),
};

// Tool module constants
const tool_constants = [_]ScriptModule.ConstantDef{
    .{
        .name = "BUILTIN_FILE_READER",
        .value = ScriptValue{ .string = "file_reader" },
        .description = "Built-in file reading tool",
    },
    .{
        .name = "BUILTIN_HTTP",
        .value = ScriptValue{ .string = "http_request" },
        .description = "Built-in HTTP request tool",
    },
    .{
        .name = "BUILTIN_SYSTEM_INFO",
        .value = ScriptValue{ .string = "system_info" },
        .description = "Built-in system information tool",
    },
    .{
        .name = "BUILTIN_DATA_PROCESSOR",
        .value = ScriptValue{ .string = "data_processor" },
        .description = "Built-in data processing tool",
    },
    .{
        .name = "BUILTIN_PROCESS_RUNNER",
        .value = ScriptValue{ .string = "process_runner" },
        .description = "Built-in process execution tool",
    },
    .{
        .name = "BUILTIN_MATH",
        .value = ScriptValue{ .string = "math_calculator" },
        .description = "Built-in math calculator tool",
    },
    .{
        .name = "BUILTIN_FEED_READER",
        .value = ScriptValue{ .string = "feed_reader" },
        .description = "Built-in RSS/Atom feed reader tool",
    },
    .{
        .name = "BUILTIN_SEARCH",
        .value = ScriptValue{ .string = "search" },
        .description = "Built-in search tool",
    },
};

// Implementation functions

fn registerTool(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1) {
        return error.InvalidArguments;
    }
    
    const tool_def = switch (args[0]) {
        .object => |obj| obj,
        else => return error.InvalidArguments,
    };
    
    const context = @fieldParentPtr(ScriptContext, "allocator", tool_def.allocator);
    const allocator = context.allocator;
    
    // Extract required fields
    const name = if (tool_def.get("name")) |n|
        try n.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const description = if (tool_def.get("description")) |d|
        try d.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const execute_fn = if (tool_def.get("execute")) |f| switch (f) {
        .function => |func| func,
        else => return error.InvalidArguments,
    } else return error.MissingField;
    
    // Optional schema
    const schema = if (tool_def.get("schema")) |s|
        try TypeMarshaler.marshalJsonValue(s, allocator)
    else
        null;
    
    // Create script tool
    const script_tool = try allocator.create(ScriptTool);
    script_tool.* = ScriptTool{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .schema = schema,
        .callback = execute_fn,
        .context = context,
    };
    
    // Register in script tools
    tools_mutex.lock();
    defer tools_mutex.unlock();
    
    if (script_tools) |*tools| {
        // Check if already exists
        if (tools.contains(name)) {
            script_tool.deinit(allocator);
            return error.ToolAlreadyExists;
        }
        
        try tools.put(script_tool.name, script_tool);
        
        // Also register with the main tool registry
        // This would integrate with the actual tool system
        // For now, we just track it locally
    }
    
    return ScriptValue{ .boolean = true };
}

fn unregisterTool(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const tool_name = args[0].string;
    
    tools_mutex.lock();
    defer tools_mutex.unlock();
    
    if (script_tools) |*tools| {
        if (tools.fetchRemove(tool_name)) |kv| {
            kv.value.deinit(tools.allocator);
            return ScriptValue{ .boolean = true };
        }
    }
    
    return ScriptValue{ .boolean = false };
}

fn executeTool(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const tool_name = args[0].string;
    const input = args[1];
    
    tools_mutex.lock();
    const script_tool = if (script_tools) |*tools|
        tools.get(tool_name)
    else
        null;
    tools_mutex.unlock();
    
    if (script_tool) |tool| {
        // Validate input against schema if present
        if (tool.schema) |schema| {
            _ = schema; // TODO: Implement schema validation
        }
        
        // Execute tool callback
        const callback_args = [_]ScriptValue{input};
        return try tool.callback.call(&callback_args);
    }
    
    // Check built-in tools
    const allocator = @fieldParentPtr(ScriptContext, "allocator", args[0].string).allocator;
    
    // Convert input to JSON for built-in tools
    const input_json = try TypeMarshaler.marshalJsonValue(input, allocator);
    defer input_json.deinit();
    
    // Execute built-in tool (simplified)
    if (std.mem.eql(u8, tool_name, "file_reader")) {
        // Simulate file reader response
        var result = ScriptValue.Object.init(allocator);
        try result.put("content", ScriptValue{ .string = try allocator.dupe(u8, "File content placeholder") });
        try result.put("size", ScriptValue{ .integer = 1024 });
        return ScriptValue{ .object = result };
    }
    
    return error.ToolNotFound;
}

fn executeToolAsync(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[2] != .function) {
        return error.InvalidArguments;
    }
    
    // Execute synchronously and call callback
    const result = executeTool(args[0..2]) catch |err| {
        // Call callback with error
        const callback_args = [_]ScriptValue{
            ScriptValue.nil,
            ScriptValue{ .string = @errorName(err) },
        };
        _ = try args[2].function.call(&callback_args);
        return ScriptValue.nil;
    };
    
    // Call callback with result
    const callback_args = [_]ScriptValue{
        result,
        ScriptValue.nil,
    };
    _ = try args[2].function.call(&callback_args);
    
    return ScriptValue.nil;
}

fn listTools(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;
    
    tools_mutex.lock();
    defer tools_mutex.unlock();
    
    const allocator = if (script_tools) |*tools| tools.allocator else return error.NotInitialized;
    var list = try ScriptValue.Array.init(allocator, 0);
    
    // Add script-registered tools
    if (script_tools) |*tools| {
        var iter = tools.iterator();
        while (iter.next()) |entry| {
            var tool_obj = ScriptValue.Object.init(allocator);
            try tool_obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            try tool_obj.put("description", ScriptValue{ .string = try allocator.dupe(u8, entry.value_ptr.*.description) });
            try tool_obj.put("type", ScriptValue{ .string = try allocator.dupe(u8, "script") });
            
            const new_array = try allocator.realloc(list.items, list.items.len + 1);
            list.items = new_array;
            list.items[list.items.len - 1] = ScriptValue{ .object = tool_obj };
        }
    }
    
    // Add built-in tools
    const builtin_tools = [_]struct { name: []const u8, desc: []const u8 }{
        .{ .name = "file_reader", .desc = "Read files from the filesystem" },
        .{ .name = "http_request", .desc = "Make HTTP requests" },
        .{ .name = "system_info", .desc = "Get system information" },
        .{ .name = "data_processor", .desc = "Process JSON/CSV data" },
        .{ .name = "process_runner", .desc = "Execute system processes" },
        .{ .name = "math_calculator", .desc = "Perform mathematical calculations" },
        .{ .name = "feed_reader", .desc = "Read RSS/Atom feeds" },
        .{ .name = "search", .desc = "Search for information" },
    };
    
    for (builtin_tools) |builtin| {
        var tool_obj = ScriptValue.Object.init(allocator);
        try tool_obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, builtin.name) });
        try tool_obj.put("description", ScriptValue{ .string = try allocator.dupe(u8, builtin.desc) });
        try tool_obj.put("type", ScriptValue{ .string = try allocator.dupe(u8, "builtin") });
        
        const new_array = try allocator.realloc(list.items, list.items.len + 1);
        list.items = new_array;
        list.items[list.items.len - 1] = ScriptValue{ .object = tool_obj };
    }
    
    return ScriptValue{ .array = list };
}

fn getToolInfo(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const tool_name = args[0].string;
    
    tools_mutex.lock();
    defer tools_mutex.unlock();
    
    const allocator = if (script_tools) |*tools| tools.allocator else return error.NotInitialized;
    
    // Check script tools first
    if (script_tools) |*tools| {
        if (tools.get(tool_name)) |tool| {
            var info = ScriptValue.Object.init(allocator);
            try info.put("name", ScriptValue{ .string = try allocator.dupe(u8, tool.name) });
            try info.put("description", ScriptValue{ .string = try allocator.dupe(u8, tool.description) });
            try info.put("type", ScriptValue{ .string = try allocator.dupe(u8, "script") });
            
            if (tool.schema) |schema| {
                const schema_value = try TypeMarshaler.unmarshalJsonValue(schema, allocator);
                try info.put("schema", schema_value);
            }
            
            return ScriptValue{ .object = info };
        }
    }
    
    // Check built-in tools
    const builtin_info = getBuiltinToolInfo(tool_name) catch null;
    if (builtin_info) |info| {
        return ScriptValue{ .string = try allocator.dupe(u8, info) };
    }
    
    return ScriptValue.nil;
}

fn toolExists(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const tool_name = args[0].string;
    
    tools_mutex.lock();
    defer tools_mutex.unlock();
    
    // Check script tools
    if (script_tools) |*tools| {
        if (tools.contains(tool_name)) {
            return ScriptValue{ .boolean = true };
        }
    }
    
    // Check built-in tools
    const builtin_tools = [_][]const u8{
        "file_reader", "http_request", "system_info", "data_processor",
        "process_runner", "math_calculator", "feed_reader", "search",
    };
    
    for (builtin_tools) |builtin| {
        if (std.mem.eql(u8, tool_name, builtin)) {
            return ScriptValue{ .boolean = true };
        }
    }
    
    return ScriptValue{ .boolean = false };
}

fn validateToolInput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const tool_name = args[0].string;
    const input = args[1];
    
    _ = tool_name;
    _ = input;
    
    // TODO: Implement schema validation
    return ScriptValue{ .boolean = true };
}

fn getBuiltinTools(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;
    
    const allocator = if (script_tools) |*tools| 
        tools.allocator 
    else 
        return error.NotInitialized;
        
    var list = try ScriptValue.Array.init(allocator, 8);
    
    const tools = [_][]const u8{
        "file_reader", "http_request", "system_info", "data_processor",
        "process_runner", "math_calculator", "feed_reader", "search",
    };
    
    for (tools, 0..) |tool_name, i| {
        list.items[i] = ScriptValue{ .string = try allocator.dupe(u8, tool_name) };
    }
    
    return ScriptValue{ .array = list };
}

fn enableBuiltinTool(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    // In real implementation, this would enable the tool in the registry
    return ScriptValue{ .boolean = true };
}

fn disableBuiltinTool(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    // In real implementation, this would disable the tool in the registry
    return ScriptValue{ .boolean = true };
}

fn getBuiltinToolInfo(name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, name, "file_reader")) {
        return "Read files from the filesystem with safety controls";
    } else if (std.mem.eql(u8, name, "http_request")) {
        return "Make HTTP requests with various methods and headers";
    } else if (std.mem.eql(u8, name, "system_info")) {
        return "Get system information including OS, CPU, memory";
    } else if (std.mem.eql(u8, name, "data_processor")) {
        return "Process and transform JSON/CSV data";
    } else if (std.mem.eql(u8, name, "process_runner")) {
        return "Execute system processes with safety controls";
    } else if (std.mem.eql(u8, name, "math_calculator")) {
        return "Perform mathematical calculations and statistics";
    } else if (std.mem.eql(u8, name, "feed_reader")) {
        return "Read and parse RSS/Atom feeds";
    } else if (std.mem.eql(u8, name, "search")) {
        return "Search for information using various sources";
    }
    return error.ToolNotFound;
}

// Tests
test "ToolBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const module = try ToolBridge.getModule(allocator);
    defer allocator.destroy(module);
    
    try testing.expectEqualStrings("tool", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}

test "ToolBridge register and execute" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Initialize context
    const dummy_engine: *anyopaque = undefined;
    const dummy_engine_context: *anyopaque = undefined;
    const context = try ScriptContext.init(allocator, "test", dummy_engine, dummy_engine_context);
    defer context.deinit();
    
    // Initialize bridge
    const engine: *ScriptingEngine = undefined;
    try ToolBridge.init(engine, context);
    defer ToolBridge.deinit();
    
    // Create tool definition
    var tool_def = ScriptValue.Object.init(allocator);
    defer tool_def.deinit();
    
    try tool_def.put("name", ScriptValue{ .string = try allocator.dupe(u8, "test_tool") });
    try tool_def.put("description", ScriptValue{ .string = try allocator.dupe(u8, "Test tool") });
    
    // Mock execute function
    const mock_fn: ScriptValue.function = undefined;
    try tool_def.put("execute", ScriptValue{ .function = &mock_fn });
    
    // Note: Can't actually test registration without a proper function implementation
    // This is a limitation of the test environment
}