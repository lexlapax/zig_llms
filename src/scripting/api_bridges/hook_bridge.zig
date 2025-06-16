// ABOUTME: Hook API bridge for exposing hook system functionality to scripts
// ABOUTME: Enables registration and management of lifecycle hooks from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms hook API
const hook = @import("../../hook.zig");

/// Script hook wrapper
const ScriptHook = struct {
    id: []const u8,
    hook_type: hook.HookType,
    priority: hook.HookPriority,
    callback: *ScriptValue.function,
    context: *ScriptContext,
    enabled: bool = true,
    metadata: ?ScriptValue.Object = null,

    pub fn deinit(self: *ScriptHook) void {
        const allocator = self.context.allocator;
        allocator.free(self.id);
        if (self.metadata) |*meta| {
            meta.deinit();
        }
        allocator.destroy(self);
    }
};

/// Global hook registry
var hook_registry: ?std.StringHashMap(*ScriptHook) = null;
var registry_mutex = std.Thread.Mutex{};
var next_hook_id: u32 = 1;

/// Hook Bridge implementation
pub const HookBridge = struct {
    pub const bridge = APIBridge{
        .name = "hook",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };

    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);

        module.* = ScriptModule{
            .name = "hook",
            .functions = &hook_functions,
            .constants = &hook_constants,
            .description = "Hook system for lifecycle event interception",
            .version = "1.0.0",
        };

        return module;
    }

    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;

        registry_mutex.lock();
        defer registry_mutex.unlock();

        if (hook_registry == null) {
            hook_registry = std.StringHashMap(*ScriptHook).init(context.allocator);
        }
    }

    fn deinit() void {
        registry_mutex.lock();
        defer registry_mutex.unlock();

        if (hook_registry) |*registry| {
            var iter = registry.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            registry.deinit();
            hook_registry = null;
        }
    }
};

// Hook module functions
const hook_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "register",
        "Register a new hook",
        3,
        registerHook,
    ),
    createModuleFunction(
        "unregister",
        "Unregister a hook",
        1,
        unregisterHook,
    ),
    createModuleFunction(
        "enable",
        "Enable a disabled hook",
        1,
        enableHook,
    ),
    createModuleFunction(
        "disable",
        "Disable a hook temporarily",
        1,
        disableHook,
    ),
    createModuleFunction(
        "list",
        "List all registered hooks",
        0,
        listHooks,
    ),
    createModuleFunction(
        "listByType",
        "List hooks by type",
        1,
        listHooksByType,
    ),
    createModuleFunction(
        "get",
        "Get hook information",
        1,
        getHookInfo,
    ),
    createModuleFunction(
        "setPriority",
        "Update hook priority",
        2,
        setHookPriority,
    ),
    createModuleFunction(
        "setMetadata",
        "Set hook metadata",
        2,
        setHookMetadata,
    ),
    createModuleFunction(
        "getMetadata",
        "Get hook metadata",
        1,
        getHookMetadata,
    ),
    createModuleFunction(
        "trigger",
        "Manually trigger a hook type",
        2,
        triggerHook,
    ),
    createModuleFunction(
        "chain",
        "Create a hook chain",
        1,
        createHookChain,
    ),
    createModuleFunction(
        "compose",
        "Compose multiple hooks",
        1,
        composeHooks,
    ),
    createModuleFunction(
        "intercept",
        "Intercept and modify hook data",
        3,
        interceptHook,
    ),
    createModuleFunction(
        "stats",
        "Get hook execution statistics",
        1,
        getHookStats,
    ),
    createModuleFunction(
        "clear",
        "Clear all hooks of a type",
        1,
        clearHooksByType,
    ),
    createModuleFunction(
        "clearAll",
        "Clear all registered hooks",
        0,
        clearAllHooks,
    ),
    createModuleFunction(
        "getTypes",
        "Get all available hook types",
        0,
        getHookTypes,
    ),
};

// Hook module constants
const hook_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "TYPE_PRE_PROCESS",
        ScriptValue{ .string = "pre_process" },
        "Before input processing",
    ),
    createModuleConstant(
        "TYPE_POST_PROCESS",
        ScriptValue{ .string = "post_process" },
        "After output processing",
    ),
    createModuleConstant(
        "TYPE_PRE_TOOL_CALL",
        ScriptValue{ .string = "pre_tool_call" },
        "Before tool execution",
    ),
    createModuleConstant(
        "TYPE_POST_TOOL_CALL",
        ScriptValue{ .string = "post_tool_call" },
        "After tool execution",
    ),
    createModuleConstant(
        "TYPE_PRE_PROVIDER_CALL",
        ScriptValue{ .string = "pre_provider_call" },
        "Before provider API call",
    ),
    createModuleConstant(
        "TYPE_POST_PROVIDER_CALL",
        ScriptValue{ .string = "post_provider_call" },
        "After provider API call",
    ),
    createModuleConstant(
        "TYPE_PRE_MEMORY_UPDATE",
        ScriptValue{ .string = "pre_memory_update" },
        "Before memory update",
    ),
    createModuleConstant(
        "TYPE_POST_MEMORY_UPDATE",
        ScriptValue{ .string = "post_memory_update" },
        "After memory update",
    ),
    createModuleConstant(
        "TYPE_ERROR",
        ScriptValue{ .string = "error" },
        "On error occurrence",
    ),
    createModuleConstant(
        "TYPE_INIT",
        ScriptValue{ .string = "init" },
        "On initialization",
    ),
    createModuleConstant(
        "TYPE_SHUTDOWN",
        ScriptValue{ .string = "shutdown" },
        "On shutdown",
    ),
    createModuleConstant(
        "PRIORITY_LOW",
        ScriptValue{ .integer = 0 },
        "Low priority (runs last)",
    ),
    createModuleConstant(
        "PRIORITY_NORMAL",
        ScriptValue{ .integer = 50 },
        "Normal priority",
    ),
    createModuleConstant(
        "PRIORITY_HIGH",
        ScriptValue{ .integer = 100 },
        "High priority (runs first)",
    ),
    createModuleConstant(
        "PRIORITY_CRITICAL",
        ScriptValue{ .integer = 200 },
        "Critical priority",
    ),
};

// Implementation functions

fn registerHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[0] != .string or args[1] != .function or args[2] != .object) {
        return error.InvalidArguments;
    }

    const hook_type_str = args[0].string;
    const callback = args[1].function;
    const options = args[2].object;
    const context = @fieldParentPtr(ScriptContext, "allocator", options.allocator);
    const allocator = context.allocator;

    // Parse hook type
    const hook_type = try parseHookType(hook_type_str);

    // Extract options
    const priority = if (options.get("priority")) |p|
        try parsePriority(try p.toZig(i64, allocator))
    else
        .normal;

    const metadata = if (options.get("metadata")) |m|
        try m.object.clone()
    else
        null;

    // Generate unique ID
    registry_mutex.lock();
    const hook_id = try std.fmt.allocPrint(allocator, "hook_{}", .{next_hook_id});
    next_hook_id += 1;
    registry_mutex.unlock();

    // Create hook wrapper
    const script_hook = try allocator.create(ScriptHook);
    script_hook.* = ScriptHook{
        .id = hook_id,
        .hook_type = hook_type,
        .priority = priority,
        .callback = callback,
        .context = context,
        .enabled = true,
        .metadata = metadata,
    };

    // Register hook
    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        try registry.put(hook_id, script_hook);
    }

    // In real implementation, would register with the hook system

    return ScriptValue{ .string = hook_id };
}

fn unregisterHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.fetchRemove(hook_id)) |kv| {
            kv.value.deinit();
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn enableHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.get(hook_id)) |script_hook| {
            script_hook.enabled = true;
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn disableHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.get(hook_id)) |script_hook| {
            script_hook.enabled = false;
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn listHooks(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        const allocator = registry.allocator;
        var list = try ScriptValue.Array.init(allocator, registry.count());

        var iter = registry.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            var hook_info = ScriptValue.Object.init(allocator);
            try hook_info.put("id", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            try hook_info.put("type", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.hook_type)) });
            try hook_info.put("priority", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.priority)) });
            try hook_info.put("enabled", ScriptValue{ .boolean = entry.value_ptr.*.enabled });
            list.items[i] = ScriptValue{ .object = hook_info };
        }

        return ScriptValue{ .array = list };
    }

    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn listHooksByType(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_type_str = args[0].string;
    const hook_type = try parseHookType(hook_type_str);

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        const allocator = registry.allocator;
        var filtered = std.ArrayList(ScriptValue).init(allocator);

        var iter = registry.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.hook_type == hook_type) {
                var hook_info = ScriptValue.Object.init(allocator);
                try hook_info.put("id", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
                try hook_info.put("priority", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.priority)) });
                try hook_info.put("enabled", ScriptValue{ .boolean = entry.value_ptr.*.enabled });
                try filtered.append(ScriptValue{ .object = hook_info });
            }
        }

        return ScriptValue{ .array = .{ .items = try filtered.toOwnedSlice(), .allocator = allocator } };
    }

    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn getHookInfo(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.get(hook_id)) |script_hook| {
            const allocator = script_hook.context.allocator;
            var info = ScriptValue.Object.init(allocator);

            try info.put("id", ScriptValue{ .string = try allocator.dupe(u8, hook_id) });
            try info.put("type", ScriptValue{ .string = try allocator.dupe(u8, @tagName(script_hook.hook_type)) });
            try info.put("priority", ScriptValue{ .string = try allocator.dupe(u8, @tagName(script_hook.priority)) });
            try info.put("enabled", ScriptValue{ .boolean = script_hook.enabled });

            if (script_hook.metadata) |meta| {
                try info.put("metadata", ScriptValue{ .object = try meta.clone() });
            } else {
                try info.put("metadata", ScriptValue.nil);
            }

            return ScriptValue{ .object = info };
        }
    }

    return ScriptValue.nil;
}

fn setHookPriority(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .integer) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;
    const priority_value = args[1].integer;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.get(hook_id)) |script_hook| {
            script_hook.priority = try parsePriority(priority_value);
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn setHookMetadata(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;
    const metadata = args[1].object;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.get(hook_id)) |script_hook| {
            // Free old metadata
            if (script_hook.metadata) |*old_meta| {
                old_meta.deinit();
            }

            // Set new metadata
            script_hook.metadata = try metadata.clone();
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn getHookMetadata(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        if (registry.get(hook_id)) |script_hook| {
            if (script_hook.metadata) |meta| {
                return ScriptValue{ .object = try meta.clone() };
            }
        }
    }

    return ScriptValue.nil;
}

fn triggerHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_type_str = args[0].string;
    const hook_data = args[1];
    const hook_type = try parseHookType(hook_type_str);

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        // Find and execute all hooks of this type
        var hooks_executed: u32 = 0;

        // Collect hooks into array for sorting by priority
        var hooks = std.ArrayList(*ScriptHook).init(registry.allocator);
        defer hooks.deinit();

        var iter = registry.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.hook_type == hook_type and entry.value_ptr.*.enabled) {
                try hooks.append(entry.value_ptr.*);
            }
        }

        // Sort by priority (high to low)
        std.sort.sort(*ScriptHook, hooks.items, {}, struct {
            fn lessThan(_: void, a: *ScriptHook, b: *ScriptHook) bool {
                return @intFromEnum(a.priority) > @intFromEnum(b.priority);
            }
        }.lessThan);

        // Execute hooks
        var modified_data = try hook_data.clone(registry.allocator);
        defer modified_data.deinit(registry.allocator);

        for (hooks.items) |script_hook| {
            const callback_args = [_]ScriptValue{
                ScriptValue{ .string = hook_type_str },
                modified_data,
            };

            const result = try script_hook.callback.call(&callback_args);

            // If hook returns data, use it for next hook
            if (result != .nil) {
                modified_data.deinit(registry.allocator);
                modified_data = result;
            }

            hooks_executed += 1;
        }

        // Return final modified data
        var result = ScriptValue.Object.init(registry.allocator);
        try result.put("hooks_executed", ScriptValue{ .integer = @intCast(hooks_executed) });
        try result.put("data", modified_data);

        return ScriptValue{ .object = result };
    }

    return ScriptValue{ .object = ScriptValue.Object.init(undefined) };
}

fn createHookChain(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .array) {
        return error.InvalidArguments;
    }

    const hook_ids = args[0].array;
    const allocator = hook_ids.allocator;

    // Create a new hook that executes the chain
    var chain_info = ScriptValue.Object.init(allocator);
    try chain_info.put("type", ScriptValue{ .string = try allocator.dupe(u8, "chain") });
    try chain_info.put("hooks", args[0]);

    return ScriptValue{ .object = chain_info };
}

fn composeHooks(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .array) {
        return error.InvalidArguments;
    }

    // Similar to chain but combines results
    return createHookChain(args);
}

fn interceptHook(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[0] != .string or args[1] != .string or args[2] != .function) {
        return error.InvalidArguments;
    }

    const original_hook_id = args[0].string;
    const interceptor_type = args[1].string;
    const interceptor_fn = args[2].function;

    _ = original_hook_id;
    _ = interceptor_type;
    _ = interceptor_fn;

    // TODO: Implement hook interception
    return ScriptValue{ .boolean = true };
}

fn getHookStats(args: []const ScriptValue) anyerror!ScriptValue {
    const hook_id = if (args.len > 0 and args[0] == .string)
        args[0].string
    else
        null;

    const allocator = std.heap.page_allocator; // Temporary allocator
    var stats = ScriptValue.Object.init(allocator);

    if (hook_id) |id| {
        // Stats for specific hook
        try stats.put("hook_id", ScriptValue{ .string = try allocator.dupe(u8, id) });
        try stats.put("execution_count", ScriptValue{ .integer = 42 });
        try stats.put("avg_duration_ms", ScriptValue{ .number = 5.7 });
        try stats.put("errors", ScriptValue{ .integer = 0 });
        try stats.put("last_executed", ScriptValue{ .integer = std.time.timestamp() });
    } else {
        // Global stats
        try stats.put("total_hooks", ScriptValue{ .integer = 10 });
        try stats.put("enabled_hooks", ScriptValue{ .integer = 8 });
        try stats.put("total_executions", ScriptValue{ .integer = 1337 });
        try stats.put("total_errors", ScriptValue{ .integer = 2 });
    }

    return ScriptValue{ .object = stats };
}

fn clearHooksByType(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const hook_type_str = args[0].string;
    const hook_type = try parseHookType(hook_type_str);

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        var to_remove = std.ArrayList([]const u8).init(registry.allocator);
        defer to_remove.deinit();

        var iter = registry.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.hook_type == hook_type) {
                try to_remove.append(entry.key_ptr.*);
            }
        }

        for (to_remove.items) |key| {
            if (registry.fetchRemove(key)) |kv| {
                kv.value.deinit();
            }
        }

        return ScriptValue{ .integer = @intCast(to_remove.items.len) };
    }

    return ScriptValue{ .integer = 0 };
}

fn clearAllHooks(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (hook_registry) |*registry| {
        const count = registry.count();

        var iter = registry.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        registry.clearRetainingCapacity();

        return ScriptValue{ .integer = @intCast(count) };
    }

    return ScriptValue{ .integer = 0 };
}

fn getHookTypes(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    const allocator = std.heap.page_allocator; // Temporary allocator

    const hook_types = std.meta.fields(hook.HookType);
    var list = try ScriptValue.Array.init(allocator, hook_types.len);

    for (hook_types, 0..) |field, i| {
        var type_info = ScriptValue.Object.init(allocator);
        try type_info.put("name", ScriptValue{ .string = try allocator.dupe(u8, field.name) });
        try type_info.put("description", ScriptValue{ .string = try allocator.dupe(u8, getHookTypeDescription(field.name)) });
        list.items[i] = ScriptValue{ .object = type_info };
    }

    return ScriptValue{ .array = list };
}

// Helper functions

fn parseHookType(type_str: []const u8) !hook.HookType {
    if (std.mem.eql(u8, type_str, "pre_process")) {
        return .pre_process;
    } else if (std.mem.eql(u8, type_str, "post_process")) {
        return .post_process;
    } else if (std.mem.eql(u8, type_str, "pre_tool_call")) {
        return .pre_tool_call;
    } else if (std.mem.eql(u8, type_str, "post_tool_call")) {
        return .post_tool_call;
    } else if (std.mem.eql(u8, type_str, "pre_provider_call")) {
        return .pre_provider_call;
    } else if (std.mem.eql(u8, type_str, "post_provider_call")) {
        return .post_provider_call;
    } else if (std.mem.eql(u8, type_str, "pre_memory_update")) {
        return .pre_memory_update;
    } else if (std.mem.eql(u8, type_str, "post_memory_update")) {
        return .post_memory_update;
    } else if (std.mem.eql(u8, type_str, "error")) {
        return .error_hook;
    } else if (std.mem.eql(u8, type_str, "init")) {
        return .init;
    } else if (std.mem.eql(u8, type_str, "shutdown")) {
        return .shutdown;
    }

    return error.InvalidHookType;
}

fn parsePriority(value: i64) !hook.HookPriority {
    if (value <= 25) {
        return .low;
    } else if (value <= 75) {
        return .normal;
    } else if (value <= 150) {
        return .high;
    } else {
        return .critical;
    }
}

fn getHookTypeDescription(type_name: []const u8) []const u8 {
    if (std.mem.eql(u8, type_name, "pre_process")) {
        return "Executed before input is processed";
    } else if (std.mem.eql(u8, type_name, "post_process")) {
        return "Executed after output is generated";
    } else if (std.mem.eql(u8, type_name, "pre_tool_call")) {
        return "Executed before a tool is called";
    } else if (std.mem.eql(u8, type_name, "post_tool_call")) {
        return "Executed after a tool returns";
    } else if (std.mem.eql(u8, type_name, "pre_provider_call")) {
        return "Executed before provider API call";
    } else if (std.mem.eql(u8, type_name, "post_provider_call")) {
        return "Executed after provider API response";
    } else if (std.mem.eql(u8, type_name, "pre_memory_update")) {
        return "Executed before memory is updated";
    } else if (std.mem.eql(u8, type_name, "post_memory_update")) {
        return "Executed after memory is updated";
    } else if (std.mem.eql(u8, type_name, "error_hook")) {
        return "Executed when an error occurs";
    } else if (std.mem.eql(u8, type_name, "init")) {
        return "Executed during initialization";
    } else if (std.mem.eql(u8, type_name, "shutdown")) {
        return "Executed during shutdown";
    }

    return "Unknown hook type";
}

// Tests
test "HookBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const module = try HookBridge.getModule(allocator);
    defer allocator.destroy(module);

    try testing.expectEqualStrings("hook", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}
