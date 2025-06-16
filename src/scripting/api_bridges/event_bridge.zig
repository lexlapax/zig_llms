// ABOUTME: Event API bridge for exposing event system functionality to scripts
// ABOUTME: Enables event subscription, emission, and monitoring from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms event API
const event = @import("../../event.zig");

/// Script event handler wrapper
const ScriptEventHandler = struct {
    id: []const u8,
    event_type: event.EventType,
    callback: *ScriptValue.function,
    context: *ScriptContext,
    priority: event.EventPriority,
    filter: ?ScriptValue,

    pub fn deinit(self: *ScriptEventHandler) void {
        const allocator = self.context.allocator;
        allocator.free(self.id);
        if (self.filter) |*f| {
            f.deinit(allocator);
        }
        allocator.destroy(self);
    }
};

/// Global event handler registry
var event_handlers: ?std.StringHashMap(*ScriptEventHandler) = null;
var handlers_mutex = std.Thread.Mutex{};
var next_handler_id: u32 = 1;

/// Event Bridge implementation
pub const EventBridge = struct {
    pub const bridge = APIBridge{
        .name = "event",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };

    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);

        module.* = ScriptModule{
            .name = "event",
            .functions = &event_functions,
            .constants = &event_constants,
            .description = "Event system subscription and emission API",
            .version = "1.0.0",
        };

        return module;
    }

    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;

        handlers_mutex.lock();
        defer handlers_mutex.unlock();

        if (event_handlers == null) {
            event_handlers = std.StringHashMap(*ScriptEventHandler).init(context.allocator);
        }
    }

    fn deinit() void {
        handlers_mutex.lock();
        defer handlers_mutex.unlock();

        if (event_handlers) |*handlers| {
            var iter = handlers.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            handlers.deinit();
            event_handlers = null;
        }
    }
};

// Event module functions
const event_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "subscribe",
        "Subscribe to an event type with callback",
        2,
        subscribeToEvent,
    ),
    createModuleFunction(
        "subscribeWithFilter",
        "Subscribe to an event with filtering",
        3,
        subscribeToEventWithFilter,
    ),
    createModuleFunction(
        "unsubscribe",
        "Unsubscribe from an event",
        1,
        unsubscribeFromEvent,
    ),
    createModuleFunction(
        "emit",
        "Emit an event with data",
        2,
        emitEvent,
    ),
    createModuleFunction(
        "emitAsync",
        "Emit an event asynchronously",
        3,
        emitEventAsync,
    ),
    createModuleFunction(
        "listSubscriptions",
        "List all active subscriptions",
        0,
        listEventSubscriptions,
    ),
    createModuleFunction(
        "getEventHistory",
        "Get recent event history",
        1,
        getEventHistory,
    ),
    createModuleFunction(
        "clearEventHistory",
        "Clear event history",
        0,
        clearEventHistory,
    ),
    createModuleFunction(
        "pauseHandler",
        "Pause an event handler",
        1,
        pauseEventHandler,
    ),
    createModuleFunction(
        "resumeHandler",
        "Resume a paused event handler",
        1,
        resumeEventHandler,
    ),
    createModuleFunction(
        "getHandlerStats",
        "Get statistics for a handler",
        1,
        getHandlerStats,
    ),
    createModuleFunction(
        "setEventPriority",
        "Set handler execution priority",
        2,
        setEventPriority,
    ),
    createModuleFunction(
        "enableEventLogging",
        "Enable detailed event logging",
        1,
        enableEventLogging,
    ),
    createModuleFunction(
        "disableEventLogging",
        "Disable event logging",
        0,
        disableEventLogging,
    ),
    createModuleFunction(
        "getEventTypes",
        "Get all available event types",
        0,
        getEventTypes,
    ),
};

// Event module constants
const event_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "TYPE_AGENT_STARTED",
        ScriptValue{ .string = "agent_started" },
        "Agent execution started event",
    ),
    createModuleConstant(
        "TYPE_AGENT_COMPLETED",
        ScriptValue{ .string = "agent_completed" },
        "Agent execution completed event",
    ),
    createModuleConstant(
        "TYPE_AGENT_ERROR",
        ScriptValue{ .string = "agent_error" },
        "Agent execution error event",
    ),
    createModuleConstant(
        "TYPE_TOOL_CALLED",
        ScriptValue{ .string = "tool_called" },
        "Tool invocation event",
    ),
    createModuleConstant(
        "TYPE_TOOL_RESULT",
        ScriptValue{ .string = "tool_result" },
        "Tool result event",
    ),
    createModuleConstant(
        "TYPE_TOOL_ERROR",
        ScriptValue{ .string = "tool_error" },
        "Tool error event",
    ),
    createModuleConstant(
        "TYPE_WORKFLOW_STARTED",
        ScriptValue{ .string = "workflow_started" },
        "Workflow execution started event",
    ),
    createModuleConstant(
        "TYPE_WORKFLOW_STEP_COMPLETED",
        ScriptValue{ .string = "workflow_step_completed" },
        "Workflow step completed event",
    ),
    createModuleConstant(
        "TYPE_WORKFLOW_COMPLETED",
        ScriptValue{ .string = "workflow_completed" },
        "Workflow execution completed event",
    ),
    createModuleConstant(
        "TYPE_MEMORY_UPDATED",
        ScriptValue{ .string = "memory_updated" },
        "Memory store updated event",
    ),
    createModuleConstant(
        "TYPE_PROVIDER_REQUEST",
        ScriptValue{ .string = "provider_request" },
        "Provider API request event",
    ),
    createModuleConstant(
        "TYPE_PROVIDER_RESPONSE",
        ScriptValue{ .string = "provider_response" },
        "Provider API response event",
    ),
    createModuleConstant(
        "PRIORITY_LOW",
        ScriptValue{ .integer = 0 },
        "Low priority event handler",
    ),
    createModuleConstant(
        "PRIORITY_NORMAL",
        ScriptValue{ .integer = 50 },
        "Normal priority event handler",
    ),
    createModuleConstant(
        "PRIORITY_HIGH",
        ScriptValue{ .integer = 100 },
        "High priority event handler",
    ),
};

// Implementation functions

fn subscribeToEvent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .function) {
        return error.InvalidArguments;
    }

    const event_type_str = args[0].string;
    const callback = args[1].function;
    const context = @fieldParentPtr(ScriptContext, "allocator", args[0].string);
    const allocator = context.allocator;

    // Parse event type
    const event_type = try parseEventType(event_type_str);

    // Generate unique handler ID
    handlers_mutex.lock();
    const handler_id = try std.fmt.allocPrint(allocator, "handler_{}", .{next_handler_id});
    next_handler_id += 1;
    handlers_mutex.unlock();

    // Create handler wrapper
    const handler = try allocator.create(ScriptEventHandler);
    handler.* = ScriptEventHandler{
        .id = handler_id,
        .event_type = event_type,
        .callback = callback,
        .context = context,
        .priority = .normal,
        .filter = null,
    };

    // Register handler
    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        try handlers.put(handler_id, handler);
    }

    // In real implementation, would register with event system

    return ScriptValue{ .string = handler_id };
}

fn subscribeToEventWithFilter(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[0] != .string or args[1] != .function) {
        return error.InvalidArguments;
    }

    const event_type_str = args[0].string;
    const callback = args[1].function;
    const filter = args[2];
    const context = @fieldParentPtr(ScriptContext, "allocator", args[0].string);
    const allocator = context.allocator;

    // Parse event type
    const event_type = try parseEventType(event_type_str);

    // Generate unique handler ID
    handlers_mutex.lock();
    const handler_id = try std.fmt.allocPrint(allocator, "handler_{}", .{next_handler_id});
    next_handler_id += 1;
    handlers_mutex.unlock();

    // Create handler wrapper with filter
    const handler = try allocator.create(ScriptEventHandler);
    handler.* = ScriptEventHandler{
        .id = handler_id,
        .event_type = event_type,
        .callback = callback,
        .context = context,
        .priority = .normal,
        .filter = try filter.clone(allocator),
    };

    // Register handler
    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        try handlers.put(handler_id, handler);
    }

    return ScriptValue{ .string = handler_id };
}

fn unsubscribeFromEvent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const handler_id = args[0].string;

    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        if (handlers.fetchRemove(handler_id)) |kv| {
            kv.value.deinit();
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn emitEvent(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const event_type_str = args[0].string;
    const event_data = args[1];
    const allocator = @fieldParentPtr(ScriptContext, "allocator", event_type_str).allocator;

    // Parse event type
    const event_type = try parseEventType(event_type_str);

    // Convert data to JSON for event system
    const data_json = try TypeMarshaler.marshalJsonValue(event_data, allocator);
    defer data_json.deinit();

    // Emit event (simplified - in real implementation would use event system)
    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        var iter = handlers.iterator();
        while (iter.next()) |entry| {
            const handler = entry.value_ptr.*;
            if (handler.event_type == event_type) {
                // Check filter if present
                if (handler.filter) |filter| {
                    if (!try matchesFilter(event_data, filter, allocator)) {
                        continue;
                    }
                }

                // Call handler callback
                const callback_args = [_]ScriptValue{
                    ScriptValue{ .string = event_type_str },
                    event_data,
                };
                _ = try handler.callback.call(&callback_args);
            }
        }
    }

    return ScriptValue{ .boolean = true };
}

fn emitEventAsync(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[2] != .function) {
        return error.InvalidArguments;
    }

    // Execute synchronously and call callback
    const result = emitEvent(args[0..2]) catch |err| {
        const callback_args = [_]ScriptValue{
            ScriptValue.nil,
            ScriptValue{ .string = @errorName(err) },
        };
        _ = try args[2].function.call(&callback_args);
        return ScriptValue.nil;
    };

    const callback_args = [_]ScriptValue{
        result,
        ScriptValue.nil,
    };
    _ = try args[2].function.call(&callback_args);

    return ScriptValue.nil;
}

fn listEventSubscriptions(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        const allocator = handlers.allocator;
        var list = try ScriptValue.Array.init(allocator, handlers.count());

        var iter = handlers.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            var sub_obj = ScriptValue.Object.init(allocator);
            try sub_obj.put("id", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            try sub_obj.put("event_type", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.event_type)) });
            try sub_obj.put("priority", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.priority)) });
            try sub_obj.put("has_filter", ScriptValue{ .boolean = entry.value_ptr.*.filter != null });
            list.items[i] = ScriptValue{ .object = sub_obj };
        }

        return ScriptValue{ .array = list };
    }

    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn getEventHistory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .integer) {
        return error.InvalidArguments;
    }

    const limit = @as(usize, @intCast(args[0].integer));
    const allocator = std.heap.page_allocator; // Temporary allocator

    // Simulate event history
    var history = try ScriptValue.Array.init(allocator, @min(limit, 5));

    const mock_events = [_]struct {
        type: []const u8,
        timestamp: i64,
        source: []const u8,
    }{
        .{ .type = "agent_started", .timestamp = 1700000000, .source = "agent_1" },
        .{ .type = "tool_called", .timestamp = 1700000001, .source = "agent_1" },
        .{ .type = "tool_result", .timestamp = 1700000002, .source = "file_reader" },
        .{ .type = "agent_completed", .timestamp = 1700000003, .source = "agent_1" },
        .{ .type = "workflow_started", .timestamp = 1700000004, .source = "workflow_1" },
    };

    for (mock_events[0..@min(limit, mock_events.len)], 0..) |evt, i| {
        var event_obj = ScriptValue.Object.init(allocator);
        try event_obj.put("type", ScriptValue{ .string = try allocator.dupe(u8, evt.type) });
        try event_obj.put("timestamp", ScriptValue{ .integer = evt.timestamp });
        try event_obj.put("source", ScriptValue{ .string = try allocator.dupe(u8, evt.source) });
        history.items[i] = ScriptValue{ .object = event_obj };
    }

    return ScriptValue{ .array = history };
}

fn clearEventHistory(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    // In real implementation, would clear event history
    return ScriptValue{ .boolean = true };
}

fn pauseEventHandler(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const handler_id = args[0].string;

    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        if (handlers.get(handler_id)) |_| {
            // In real implementation, would pause the handler
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn resumeEventHandler(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const handler_id = args[0].string;

    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        if (handlers.get(handler_id)) |_| {
            // In real implementation, would resume the handler
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn getHandlerStats(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const handler_id = args[0].string;

    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        if (handlers.get(handler_id)) |handler| {
            const allocator = handler.context.allocator;
            var stats = ScriptValue.Object.init(allocator);

            try stats.put("id", ScriptValue{ .string = try allocator.dupe(u8, handler_id) });
            try stats.put("event_type", ScriptValue{ .string = try allocator.dupe(u8, @tagName(handler.event_type)) });
            try stats.put("calls_count", ScriptValue{ .integer = 42 }); // Mock data
            try stats.put("errors_count", ScriptValue{ .integer = 0 });
            try stats.put("avg_duration_ms", ScriptValue{ .number = 15.5 });
            try stats.put("last_called", ScriptValue{ .integer = 1700000000 });

            return ScriptValue{ .object = stats };
        }
    }

    return ScriptValue.nil;
}

fn setEventPriority(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .integer) {
        return error.InvalidArguments;
    }

    const handler_id = args[0].string;
    const priority = args[1].integer;

    handlers_mutex.lock();
    defer handlers_mutex.unlock();

    if (event_handlers) |*handlers| {
        if (handlers.get(handler_id)) |handler| {
            handler.priority = switch (priority) {
                0...33 => .low,
                34...66 => .normal,
                else => .high,
            };
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn enableEventLogging(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    // In real implementation, would enable logging for event type
    return ScriptValue{ .boolean = true };
}

fn disableEventLogging(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    // In real implementation, would disable all event logging
    return ScriptValue{ .boolean = true };
}

fn getEventTypes(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    const allocator = std.heap.page_allocator; // Temporary allocator

    const event_types = std.meta.fields(event.EventType);
    var list = try ScriptValue.Array.init(allocator, event_types.len);

    for (event_types, 0..) |field, i| {
        list.items[i] = ScriptValue{ .string = try allocator.dupe(u8, field.name) };
    }

    return ScriptValue{ .array = list };
}

// Helper functions

fn parseEventType(type_str: []const u8) !event.EventType {
    if (std.mem.eql(u8, type_str, "agent_started")) {
        return .agent_started;
    } else if (std.mem.eql(u8, type_str, "agent_completed")) {
        return .agent_completed;
    } else if (std.mem.eql(u8, type_str, "agent_error")) {
        return .agent_error;
    } else if (std.mem.eql(u8, type_str, "tool_called")) {
        return .tool_called;
    } else if (std.mem.eql(u8, type_str, "tool_result")) {
        return .tool_result;
    } else if (std.mem.eql(u8, type_str, "tool_error")) {
        return .tool_error;
    } else if (std.mem.eql(u8, type_str, "workflow_started")) {
        return .workflow_started;
    } else if (std.mem.eql(u8, type_str, "workflow_step_completed")) {
        return .workflow_step_completed;
    } else if (std.mem.eql(u8, type_str, "workflow_completed")) {
        return .workflow_completed;
    } else if (std.mem.eql(u8, type_str, "memory_updated")) {
        return .memory_updated;
    } else if (std.mem.eql(u8, type_str, "provider_request")) {
        return .provider_request;
    } else if (std.mem.eql(u8, type_str, "provider_response")) {
        return .provider_response;
    }

    return error.InvalidEventType;
}

fn matchesFilter(event_data: ScriptValue, filter: ScriptValue, allocator: std.mem.Allocator) !bool {
    _ = allocator;

    // Simple filter matching logic
    switch (filter) {
        .object => |filter_obj| {
            if (event_data != .object) return false;

            var iter = filter_obj.map.iterator();
            while (iter.next()) |entry| {
                if (event_data.object.get(entry.key_ptr.*)) |data_value| {
                    if (!try valuesMatch(data_value, entry.value_ptr.*)) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
        else => return true,
    }
}

fn valuesMatch(a: ScriptValue, b: ScriptValue) !bool {
    if (@as(std.meta.Tag(ScriptValue), a) != @as(std.meta.Tag(ScriptValue), b)) {
        return false;
    }

    switch (a) {
        .nil => return true,
        .boolean => |val| return val == b.boolean,
        .integer => |val| return val == b.integer,
        .number => |val| return val == b.number,
        .string => |val| return std.mem.eql(u8, val, b.string),
        else => return true, // Simplified for other types
    }
}

// Tests
test "EventBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const module = try EventBridge.getModule(allocator);
    defer allocator.destroy(module);

    try testing.expectEqualStrings("event", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}
