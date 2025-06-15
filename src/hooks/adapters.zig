// ABOUTME: Adapters for integrating external hook systems and libraries
// ABOUTME: Provides bridges to connect various hook implementations with the zig_llms hook system

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;
const registry = @import("registry.zig");

// Generic external hook adapter interface
pub const ExternalHookAdapter = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        // Convert external hook to our Hook type
        adaptHook: *const fn (adapter: *ExternalHookAdapter, external_hook: *anyopaque, allocator: std.mem.Allocator) anyerror!*Hook,
        
        // Convert our context to external format
        adaptContext: *const fn (adapter: *ExternalHookAdapter, context: *HookContext, allocator: std.mem.Allocator) anyerror!*anyopaque,
        
        // Convert external result to our HookResult
        adaptResult: *const fn (adapter: *ExternalHookAdapter, external_result: *anyopaque, allocator: std.mem.Allocator) anyerror!HookResult,
        
        // Cleanup
        deinit: ?*const fn (adapter: *ExternalHookAdapter) void = null,
    };
    
    pub fn adaptHook(self: *ExternalHookAdapter, external_hook: *anyopaque, allocator: std.mem.Allocator) !*Hook {
        return self.vtable.adaptHook(self, external_hook, allocator);
    }
    
    pub fn adaptContext(self: *ExternalHookAdapter, context: *HookContext, allocator: std.mem.Allocator) !*anyopaque {
        return self.vtable.adaptContext(self, context, allocator);
    }
    
    pub fn adaptResult(self: *ExternalHookAdapter, external_result: *anyopaque, allocator: std.mem.Allocator) !HookResult {
        return self.vtable.adaptResult(self, external_result, allocator);
    }
    
    pub fn deinit(self: *ExternalHookAdapter) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Function pointer adapter for C-style hooks
pub const FunctionPointerAdapter = struct {
    adapter: ExternalHookAdapter,
    allocator: std.mem.Allocator,
    
    pub const CHookFn = *const fn (context: *anyopaque) callconv(.C) c_int;
    
    pub fn init(allocator: std.mem.Allocator) !*FunctionPointerAdapter {
        const self = try allocator.create(FunctionPointerAdapter);
        self.* = .{
            .adapter = .{
                .vtable = &.{
                    .adaptHook = adaptHook,
                    .adaptContext = adaptContext,
                    .adaptResult = adaptResult,
                    .deinit = deinit,
                },
            },
            .allocator = allocator,
        };
        return self;
    }
    
    fn adaptHook(adapter: *ExternalHookAdapter, external_hook: *anyopaque, allocator: std.mem.Allocator) !*Hook {
        _ = adapter;
        const c_hook = @as(CHookFn, @ptrCast(@alignCast(external_hook)));
        
        const hook = try allocator.create(Hook);
        
        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = struct {
                fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                    const fn_ptr = @as(CHookFn, @ptrFromInt(@as(usize, @intCast(h.config.?.integer))));
                    const c_result = fn_ptr(@ptrCast(ctx));
                    
                    return HookResult{
                        .continue_processing = c_result == 0,
                        .error_info = if (c_result != 0) .{
                            .message = "C hook returned non-zero",
                            .error_type = "CHookError",
                            .recoverable = true,
                        } else null,
                    };
                }
            }.execute,
        };
        
        hook.* = .{
            .id = "c_hook",
            .name = "C Function Hook",
            .description = "Adapted C function pointer",
            .vtable = vtable,
            .supported_points = &[_]HookPoint{.custom},
            .config = .{ .integer = @intFromPtr(c_hook) },
        };
        
        return hook;
    }
    
    fn adaptContext(adapter: *ExternalHookAdapter, context: *HookContext, allocator: std.mem.Allocator) !*anyopaque {
        _ = adapter;
        _ = allocator;
        return @ptrCast(context);
    }
    
    fn adaptResult(adapter: *ExternalHookAdapter, external_result: *anyopaque, allocator: std.mem.Allocator) !HookResult {
        _ = adapter;
        _ = allocator;
        const result = @as(*c_int, @ptrCast(@alignCast(external_result)));
        return HookResult{
            .continue_processing = result.* == 0,
        };
    }
    
    fn deinit(adapter: *ExternalHookAdapter) void {
        const self = @fieldParentPtr(FunctionPointerAdapter, "adapter", adapter);
        self.allocator.destroy(self);
    }
};

// JSON-RPC hook adapter for remote hooks
pub const JsonRpcHookAdapter = struct {
    adapter: ExternalHookAdapter,
    endpoint: []const u8,
    client: HttpClient,
    allocator: std.mem.Allocator,
    
    const HttpClient = struct {
        // Simplified HTTP client interface
        allocator: std.mem.Allocator,
        
        pub fn post(self: *HttpClient, url: []const u8, body: []const u8) ![]u8 {
            _ = self;
            _ = url;
            _ = body;
            // TODO: Implement actual HTTP client
            return self.allocator.dupe(u8, "{}");
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !*JsonRpcHookAdapter {
        const self = try allocator.create(JsonRpcHookAdapter);
        self.* = .{
            .adapter = .{
                .vtable = &.{
                    .adaptHook = adaptHook,
                    .adaptContext = adaptContext,
                    .adaptResult = adaptResult,
                    .deinit = deinit,
                },
            },
            .endpoint = try allocator.dupe(u8, endpoint),
            .client = HttpClient{ .allocator = allocator },
            .allocator = allocator,
        };
        return self;
    }
    
    fn adaptHook(adapter: *ExternalHookAdapter, external_hook: *anyopaque, allocator: std.mem.Allocator) !*Hook {
        const self = @fieldParentPtr(JsonRpcHookAdapter, "adapter", adapter);
        const hook_id = @as(*[]const u8, @ptrCast(@alignCast(external_hook))).*;
        
        const hook = try allocator.create(Hook);
        
        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = struct {
                fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                    const adapter_self = @as(*JsonRpcHookAdapter, @ptrFromInt(@as(usize, @intCast(h.config.?.object.get("adapter").?.integer))));
                    
                    // Build JSON-RPC request
                    var request = std.json.ObjectMap.init(ctx.allocator);
                    defer request.deinit();
                    
                    try request.put("jsonrpc", .{ .string = "2.0" });
                    try request.put("method", .{ .string = "executeHook" });
                    try request.put("id", .{ .integer = 1 });
                    
                    var params = std.json.ObjectMap.init(ctx.allocator);
                    try params.put("hook_id", .{ .string = h.id });
                    try params.put("point", .{ .string = ctx.point.toString() });
                    if (ctx.input_data) |data| {
                        try params.put("input", data);
                    }
                    try request.put("params", .{ .object = params });
                    
                    const request_str = try std.json.stringifyAlloc(ctx.allocator, std.json.Value{ .object = request }, .{});
                    defer ctx.allocator.free(request_str);
                    
                    // Send request
                    const response_str = try adapter_self.client.post(adapter_self.endpoint, request_str);
                    defer ctx.allocator.free(response_str);
                    
                    // Parse response
                    const response = try std.json.parseFromSlice(std.json.Value, ctx.allocator, response_str, .{});
                    defer response.deinit();
                    
                    if (response.value.object.get("error")) |err| {
                        return HookResult{
                            .continue_processing = false,
                            .error_info = .{
                                .message = err.object.get("message").?.string,
                                .error_type = "JsonRpcError",
                                .recoverable = false,
                            },
                        };
                    }
                    
                    const result = response.value.object.get("result").?;
                    return HookResult{
                        .continue_processing = result.object.get("continue").?.bool,
                        .modified_data = result.object.get("data"),
                    };
                }
            }.execute,
        };
        
        var config = std.json.ObjectMap.init(allocator);
        try config.put("adapter", .{ .integer = @intFromPtr(self) });
        
        hook.* = .{
            .id = hook_id,
            .name = try std.fmt.allocPrint(allocator, "JSON-RPC Hook: {s}", .{hook_id}),
            .description = "Remote JSON-RPC hook",
            .vtable = vtable,
            .supported_points = &[_]HookPoint{.custom},
            .config = .{ .object = config },
        };
        
        return hook;
    }
    
    fn adaptContext(adapter: *ExternalHookAdapter, context: *HookContext, allocator: std.mem.Allocator) !*anyopaque {
        _ = adapter;
        const json_str = try std.json.stringifyAlloc(allocator, context.export(allocator), .{});
        return @ptrCast(json_str.ptr);
    }
    
    fn adaptResult(adapter: *ExternalHookAdapter, external_result: *anyopaque, allocator: std.mem.Allocator) !HookResult {
        _ = adapter;
        const json_str = @as([*:0]const u8, @ptrCast(external_result));
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(json_str), .{});
        defer parsed.deinit();
        
        return HookResult{
            .continue_processing = parsed.value.object.get("continue_processing").?.bool,
            .modified_data = parsed.value.object.get("modified_data"),
        };
    }
    
    fn deinit(adapter: *ExternalHookAdapter) void {
        const self = @fieldParentPtr(JsonRpcHookAdapter, "adapter", adapter);
        self.allocator.free(self.endpoint);
        self.allocator.destroy(self);
    }
};

// Plugin system adapter for dynamic library hooks
pub const PluginHookAdapter = struct {
    adapter: ExternalHookAdapter,
    plugin_path: []const u8,
    handle: ?*anyopaque = null,
    allocator: std.mem.Allocator,
    
    pub const PluginInterface = struct {
        version: u32,
        name: [*:0]const u8,
        description: [*:0]const u8,
        supported_points: [*]const u32,
        supported_points_count: usize,
        
        // Hook functions
        initialize: ?*const fn () callconv(.C) void,
        execute: *const fn (context: *anyopaque) callconv(.C) c_int,
        cleanup: ?*const fn () callconv(.C) void,
    };
    
    pub fn init(allocator: std.mem.Allocator, plugin_path: []const u8) !*PluginHookAdapter {
        const self = try allocator.create(PluginHookAdapter);
        self.* = .{
            .adapter = .{
                .vtable = &.{
                    .adaptHook = adaptHook,
                    .adaptContext = adaptContext,
                    .adaptResult = adaptResult,
                    .deinit = deinit,
                },
            },
            .plugin_path = try allocator.dupe(u8, plugin_path),
            .allocator = allocator,
        };
        
        // TODO: Load dynamic library
        // self.handle = try std.DynLib.open(plugin_path);
        
        return self;
    }
    
    fn adaptHook(adapter: *ExternalHookAdapter, external_hook: *anyopaque, allocator: std.mem.Allocator) !*Hook {
        const self = @fieldParentPtr(PluginHookAdapter, "adapter", adapter);
        const plugin = @as(*PluginInterface, @ptrCast(@alignCast(external_hook)));
        
        const hook = try allocator.create(Hook);
        
        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = struct {
                fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                    const plugin_ptr = @as(*PluginInterface, @ptrFromInt(@as(usize, @intCast(h.config.?.integer))));
                    const result = plugin_ptr.execute(@ptrCast(ctx));
                    
                    return HookResult{
                        .continue_processing = result == 0,
                    };
                }
            }.execute,
            .init = if (plugin.initialize) |init_fn| struct {
                fn init(h: *Hook, alloc: std.mem.Allocator) !void {
                    _ = h;
                    _ = alloc;
                    const plugin_ptr = @as(*PluginInterface, @ptrFromInt(@as(usize, @intCast(h.config.?.integer))));
                    if (plugin_ptr.initialize) |initialize| {
                        initialize();
                    }
                }
            }.init else null,
            .deinit = if (plugin.cleanup) |cleanup_fn| struct {
                fn deinit(h: *Hook) void {
                    const plugin_ptr = @as(*PluginInterface, @ptrFromInt(@as(usize, @intCast(h.config.?.integer))));
                    if (plugin_ptr.cleanup) |cleanup| {
                        cleanup();
                    }
                }
            }.deinit else null,
        };
        
        // Convert supported points
        var points = std.ArrayList(HookPoint).init(allocator);
        defer points.deinit();
        
        var i: usize = 0;
        while (i < plugin.supported_points_count) : (i += 1) {
            const point_value = plugin.supported_points[i];
            if (point_value < @typeInfo(HookPoint).Enum.fields.len) {
                try points.append(@enumFromInt(point_value));
            }
        }
        
        hook.* = .{
            .id = std.mem.span(plugin.name),
            .name = std.mem.span(plugin.name),
            .description = std.mem.span(plugin.description),
            .vtable = vtable,
            .supported_points = try points.toOwnedSlice(),
            .config = .{ .integer = @intFromPtr(plugin) },
        };
        
        return hook;
    }
    
    fn adaptContext(adapter: *ExternalHookAdapter, context: *HookContext, allocator: std.mem.Allocator) !*anyopaque {
        _ = adapter;
        _ = allocator;
        return @ptrCast(context);
    }
    
    fn adaptResult(adapter: *ExternalHookAdapter, external_result: *anyopaque, allocator: std.mem.Allocator) !HookResult {
        _ = adapter;
        _ = allocator;
        const result = @as(*c_int, @ptrCast(@alignCast(external_result)));
        return HookResult{
            .continue_processing = result.* == 0,
        };
    }
    
    fn deinit(adapter: *ExternalHookAdapter) void {
        const self = @fieldParentPtr(PluginHookAdapter, "adapter", adapter);
        
        // TODO: Unload dynamic library
        // if (self.handle) |handle| {
        //     handle.close();
        // }
        
        self.allocator.free(self.plugin_path);
        self.allocator.destroy(self);
    }
};

// Event emitter adapter for pub/sub style hooks
pub const EventEmitterAdapter = struct {
    adapter: ExternalHookAdapter,
    event_handlers: std.StringHashMap(std.ArrayList(EventHandler)),
    allocator: std.mem.Allocator,
    
    pub const EventHandler = struct {
        callback: *const fn (event_data: std.json.Value) void,
        filter: ?*const fn (event_data: std.json.Value) bool = null,
    };
    
    pub fn init(allocator: std.mem.Allocator) !*EventEmitterAdapter {
        const self = try allocator.create(EventEmitterAdapter);
        self.* = .{
            .adapter = .{
                .vtable = &.{
                    .adaptHook = adaptHook,
                    .adaptContext = adaptContext,
                    .adaptResult = adaptResult,
                    .deinit = deinit,
                },
            },
            .event_handlers = std.StringHashMap(std.ArrayList(EventHandler)).init(allocator),
            .allocator = allocator,
        };
        return self;
    }
    
    pub fn on(self: *EventEmitterAdapter, event_type: []const u8, handler: EventHandler) !void {
        const result = try self.event_handlers.getOrPut(event_type);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(EventHandler).init(self.allocator);
        }
        try result.value_ptr.append(handler);
    }
    
    pub fn emit(self: *EventEmitterAdapter, event_type: []const u8, data: std.json.Value) void {
        if (self.event_handlers.get(event_type)) |handlers| {
            for (handlers.items) |handler| {
                if (handler.filter) |filter| {
                    if (!filter(data)) continue;
                }
                handler.callback(data);
            }
        }
    }
    
    fn adaptHook(adapter: *ExternalHookAdapter, external_hook: *anyopaque, allocator: std.mem.Allocator) !*Hook {
        const self = @fieldParentPtr(EventEmitterAdapter, "adapter", adapter);
        const event_type = @as(*[]const u8, @ptrCast(@alignCast(external_hook))).*;
        
        const hook = try allocator.create(Hook);
        
        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = struct {
                fn execute(h: *Hook, ctx: *HookContext) !HookResult {
                    const adapter_self = @as(*EventEmitterAdapter, @ptrFromInt(@as(usize, @intCast(h.config.?.object.get("adapter").?.integer))));
                    const evt_type = h.config.?.object.get("event_type").?.string;
                    
                    var event_data = std.json.ObjectMap.init(ctx.allocator);
                    defer event_data.deinit();
                    
                    try event_data.put("hook_point", .{ .string = ctx.point.toString() });
                    if (ctx.input_data) |data| {
                        try event_data.put("input", data);
                    }
                    try event_data.put("timestamp", .{ .integer = std.time.milliTimestamp() });
                    
                    adapter_self.emit(evt_type, .{ .object = event_data });
                    
                    return HookResult{ .continue_processing = true };
                }
            }.execute,
        };
        
        var config = std.json.ObjectMap.init(allocator);
        try config.put("adapter", .{ .integer = @intFromPtr(self) });
        try config.put("event_type", .{ .string = event_type });
        
        hook.* = .{
            .id = event_type,
            .name = try std.fmt.allocPrint(allocator, "Event: {s}", .{event_type}),
            .description = "Event emitter hook",
            .vtable = vtable,
            .supported_points = &[_]HookPoint{.custom},
            .config = .{ .object = config },
        };
        
        return hook;
    }
    
    fn adaptContext(adapter: *ExternalHookAdapter, context: *HookContext, allocator: std.mem.Allocator) !*anyopaque {
        _ = adapter;
        _ = context;
        _ = allocator;
        return @as(*anyopaque, undefined);
    }
    
    fn adaptResult(adapter: *ExternalHookAdapter, external_result: *anyopaque, allocator: std.mem.Allocator) !HookResult {
        _ = adapter;
        _ = external_result;
        _ = allocator;
        return HookResult{ .continue_processing = true };
    }
    
    fn deinit(adapter: *ExternalHookAdapter) void {
        const self = @fieldParentPtr(EventEmitterAdapter, "adapter", adapter);
        
        var iter = self.event_handlers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.event_handlers.deinit();
        
        self.allocator.destroy(self);
    }
};

// Adapter manager for centralized adapter registration
pub const AdapterManager = struct {
    adapters: std.StringHashMap(*ExternalHookAdapter),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) AdapterManager {
        return .{
            .adapters = std.StringHashMap(*ExternalHookAdapter).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *AdapterManager) void {
        var iter = self.adapters.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.adapters.deinit();
    }
    
    pub fn registerAdapter(self: *AdapterManager, name: []const u8, adapter: *ExternalHookAdapter) !void {
        try self.adapters.put(name, adapter);
    }
    
    pub fn getAdapter(self: *AdapterManager, name: []const u8) ?*ExternalHookAdapter {
        return self.adapters.get(name);
    }
    
    pub fn importHook(
        self: *AdapterManager,
        adapter_name: []const u8,
        external_hook: *anyopaque,
        hook_registry: *registry.HookRegistry,
    ) !void {
        const adapter = self.getAdapter(adapter_name) orelse return error.AdapterNotFound;
        const hook = try adapter.adaptHook(adapter, external_hook, self.allocator);
        
        // Register with hook registry
        try hook_registry.hooks.put(hook.id, hook);
        
        // Add to appropriate chains
        for (hook.supported_points) |point| {
            if (hook_registry.chains.get(point)) |chain| {
                try chain.addHook(hook);
            }
        }
    }
};

// Tests
test "function pointer adapter" {
    const allocator = std.testing.allocator;
    
    const adapter = try FunctionPointerAdapter.init(allocator);
    defer adapter.adapter.deinit();
    
    // C-style hook function
    const c_hook = struct {
        fn hook(context: *anyopaque) callconv(.C) c_int {
            _ = context;
            return 0; // Success
        }
    }.hook;
    
    const hook = try adapter.adapter.adaptHook(&adapter.adapter, @as(*anyopaque, @ptrCast(@constCast(&c_hook))), allocator);
    defer {
        allocator.destroy(hook.vtable);
        allocator.destroy(hook);
    }
    
    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    const result = try hook.execute(&context);
    try std.testing.expect(result.continue_processing);
}

test "event emitter adapter" {
    const allocator = std.testing.allocator;
    
    const adapter = try EventEmitterAdapter.init(allocator);
    defer adapter.adapter.deinit();
    
    var event_fired = false;
    
    // Register event handler
    try adapter.on("test_event", .{
        .callback = struct {
            fn handle(data: std.json.Value) void {
                _ = data;
                event_fired = true;
            }
        }.handle,
    });
    
    // Create hook for event
    var event_type = "test_event";
    const hook = try adapter.adapter.adaptHook(&adapter.adapter, @ptrCast(&event_type), allocator);
    defer {
        hook.config.?.object.deinit();
        allocator.free(hook.name);
        allocator.destroy(hook.vtable);
        allocator.destroy(hook);
    }
    
    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    _ = try hook.execute(&context);
    try std.testing.expect(event_fired);
}