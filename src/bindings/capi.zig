// ABOUTME: C-API for zig_llms framework enabling integration with other languages
// ABOUTME: Provides C-compatible functions for agents, tools, workflows, and memory management

const std = @import("std");
const agent = @import("../agent.zig");
const tool = @import("../tool.zig");
const workflow = @import("../workflow.zig");
const memory = @import("../memory.zig");
const provider = @import("../provider.zig");
const events = @import("../events.zig");
const tool_registry = @import("../tool_registry.zig");
const memory_mgmt = @import("memory.zig");
const error_handling = @import("error_handling.zig");
const BaseAgent = agent.BaseAgent;
const Tool = tool.Tool;
const Workflow = workflow.Workflow;
const MemoryConfig = memory.MemoryConfig;
const EventEmitter = events.emitter.EventEmitter;
const TrackingAllocator = memory_mgmt.TrackingAllocator;
const SessionManager = memory_mgmt.SessionManager;
const MemoryPool = memory_mgmt.MemoryPool;
const MemoryStats = memory_mgmt.MemoryStats;

// C-API version and build info
pub const CAPI_VERSION_MAJOR: c_int = 1;
pub const CAPI_VERSION_MINOR: c_int = 0;
pub const CAPI_VERSION_PATCH: c_int = 0;

// Opaque handle types for C clients
pub const ZigLLMSHandle = opaque {};
pub const ZigLLMSAgent = opaque {};
pub const ZigLLMSTool = opaque {};
pub const ZigLLMSWorkflow = opaque {};
pub const ZigLLMSMemory = opaque {};
pub const ZigLLMSProvider = opaque {};
pub const ZigLLMSEventEmitter = opaque {};

// Error codes for C-API
pub const ZigLLMSError = enum(c_int) {
    SUCCESS = 0,
    NULL_POINTER = -1,
    INVALID_PARAMETER = -2,
    MEMORY_ERROR = -3,
    INITIALIZATION_FAILED = -4,
    AGENT_ERROR = -5,
    TOOL_ERROR = -6,
    WORKFLOW_ERROR = -7,
    PROVIDER_ERROR = -8,
    JSON_ERROR = -9,
    TIMEOUT_ERROR = -10,
    UNKNOWN_ERROR = -99,

    pub fn toInt(self: ZigLLMSError) c_int {
        return @intFromEnum(self);
    }
};

// Configuration structures for C-API
pub const ZigLLMSConfig = extern struct {
    allocator_type: c_int, // 0 = default, 1 = arena, 2 = fixed buffer
    log_level: c_int, // 0 = debug, 1 = info, 2 = warn, 3 = error
    enable_events: bool,
    enable_metrics: bool,
    max_memory_mb: c_int,
};

pub const ZigLLMSAgentConfig = extern struct {
    name: [*c]const u8,
    description: [*c]const u8,
    provider_type: c_int, // 0 = openai, 1 = anthropic, 2 = ollama, 3 = gemini
    model_name: [*c]const u8,
    api_key: [*c]const u8,
    api_url: [*c]const u8,
    max_tokens: c_int,
    temperature: f32,
    enable_memory: bool,
    enable_tools: bool,
};

pub const ZigLLMSResult = extern struct {
    error_code: c_int,
    data: [*c]const u8, // JSON string
    data_length: c_int,
    error_message: [*c]const u8,
};

// Global state management
var global_allocator: std.mem.Allocator = undefined;
var global_initialized: bool = false;
var global_arena: ?std.heap.ArenaAllocator = null;
var global_tracking_allocator: ?TrackingAllocator = null;
var global_session_manager: ?SessionManager = null;
var global_memory_pool: ?MemoryPool = null;

// =============================================================================
// INITIALIZATION AND CLEANUP
// =============================================================================

/// Initialize the zig_llms library
export fn zigllms_init(config: *const ZigLLMSConfig) c_int {
    if (global_initialized) {
        return ZigLLMSError.SUCCESS.toInt();
    }

    // Initialize error handling first
    error_handling.initErrorHandling();

    // Setup base allocator
    const base_allocator = std.heap.c_allocator;

    // Setup allocator based on config
    switch (config.allocator_type) {
        0 => {
            // Default with tracking
            global_tracking_allocator = TrackingAllocator.init(base_allocator, true, // enable leak detection
                10000 // max allocations
            );
            global_allocator = global_tracking_allocator.?.allocator();
        },
        1 => {
            // Arena allocator with tracking
            global_arena = std.heap.ArenaAllocator.init(base_allocator);
            global_tracking_allocator = TrackingAllocator.init(global_arena.?.allocator(), true, 10000);
            global_allocator = global_tracking_allocator.?.allocator();
        },
        2 => {
            // Memory pool for small allocations
            global_memory_pool = MemoryPool.init(base_allocator, 64, // 64-byte blocks
                1000 // 1000 blocks
            ) catch {
                error_handling.reportError(ZigLLMSError.INITIALIZATION_FAILED.toInt(), .memory, .critical, "Failed to initialize memory pool", "zigllms_init");
                return ZigLLMSError.INITIALIZATION_FAILED.toInt();
            };
            global_tracking_allocator = TrackingAllocator.init(base_allocator, true, 10000);
            global_allocator = global_tracking_allocator.?.allocator();
        },
        else => {
            global_tracking_allocator = TrackingAllocator.init(base_allocator, false, // no leak detection for unknown types
                10000);
            global_allocator = global_tracking_allocator.?.allocator();
        },
    }

    // Initialize session manager
    global_session_manager = SessionManager.init(global_allocator, 100, // max 100 sessions
        300000 // 5 minute timeout
    );

    global_initialized = true;
    return ZigLLMSError.SUCCESS.toInt();
}

/// Cleanup and shutdown the library
export fn zigllms_cleanup() void {
    if (!global_initialized) return;

    // Cleanup external tool registry
    deinitExternalToolRegistry();

    // Cleanup session manager
    if (global_session_manager) |*manager| {
        manager.deinit();
        global_session_manager = null;
    }

    // Cleanup memory pool
    if (global_memory_pool) |*pool| {
        pool.deinit(std.heap.c_allocator);
        global_memory_pool = null;
    }

    // Cleanup tracking allocator (will report leaks if any)
    if (global_tracking_allocator) |*tracker| {
        tracker.deinit();
        global_tracking_allocator = null;
    }

    // Cleanup arena
    if (global_arena) |*arena| {
        arena.deinit();
        global_arena = null;
    }

    global_initialized = false;

    // Cleanup error handling last
    error_handling.deinitErrorHandling();
}

/// Get library version information
export fn zigllms_get_version(major: *c_int, minor: *c_int, patch: *c_int) void {
    major.* = CAPI_VERSION_MAJOR;
    minor.* = CAPI_VERSION_MINOR;
    patch.* = CAPI_VERSION_PATCH;
}

// =============================================================================
// AGENT MANAGEMENT
// =============================================================================

/// Create a new agent instance
export fn zigllms_agent_create(config: *const ZigLLMSAgentConfig) ?*ZigLLMSAgent {
    if (!global_initialized) return null;

    const agent_name = std.mem.span(config.name);
    const description = std.mem.span(config.description);

    // Create agent configuration
    var agent_config = agent.AgentConfig{
        .name = agent_name,
        .description = description,
    };

    // Create memory config if enabled
    if (config.enable_memory) {
        agent_config.memory_config = MemoryConfig{};
    }

    // Create agent
    const base_agent = BaseAgent.init(global_allocator, agent_config) catch return null;

    // Cast to opaque handle
    return @ptrCast(base_agent);
}

/// Destroy an agent instance
export fn zigllms_agent_destroy(agent_handle: ?*ZigLLMSAgent) void {
    if (agent_handle == null) return;

    const base_agent: *BaseAgent = @ptrCast(@alignCast(agent_handle));
    base_agent.deinit();
}

/// Execute agent with input and return result
export fn zigllms_agent_run(
    agent_handle: ?*ZigLLMSAgent,
    input_json: [*c]const u8,
    result: *ZigLLMSResult,
) c_int {
    if (agent_handle == null or input_json == null) {
        result.error_code = ZigLLMSError.NULL_POINTER.toInt();
        result.error_message = "Null pointer provided";
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const base_agent: *BaseAgent = @ptrCast(@alignCast(agent_handle));
    const input_str = std.mem.span(input_json);

    // Parse input JSON
    const input_value = std.json.parseFromSlice(std.json.Value, global_allocator, input_str, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to parse input JSON";
        return ZigLLMSError.JSON_ERROR.toInt();
    };
    defer input_value.deinit();

    // Run agent
    const agent_result = base_agent.agent.vtable.run(&base_agent.agent, input_value.value, global_allocator) catch {
        result.error_code = ZigLLMSError.AGENT_ERROR.toInt();
        result.error_message = "Agent execution failed";
        return ZigLLMSError.AGENT_ERROR.toInt();
    };

    // Serialize result to JSON
    const result_json = std.json.stringifyAlloc(global_allocator, agent_result, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to serialize result";
        return ZigLLMSError.JSON_ERROR.toInt();
    };

    result.error_code = ZigLLMSError.SUCCESS.toInt();
    result.data = result_json.ptr;
    result.data_length = @intCast(result_json.len);
    result.error_message = null;

    return ZigLLMSError.SUCCESS.toInt();
}

/// Get agent configuration and status
export fn zigllms_agent_get_info(
    agent_handle: ?*ZigLLMSAgent,
    result: *ZigLLMSResult,
) c_int {
    if (agent_handle == null) {
        result.error_code = ZigLLMSError.NULL_POINTER.toInt();
        result.error_message = "Null agent handle";
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const base_agent: *BaseAgent = @ptrCast(@alignCast(agent_handle));

    // Build info object
    var info_obj = std.json.ObjectMap.init(global_allocator);
    info_obj.put("name", .{ .string = base_agent.config.name }) catch {};
    info_obj.put("description", .{ .string = base_agent.config.description }) catch {};
    info_obj.put("status", .{ .string = "active" }) catch {};

    const info_json = std.json.stringifyAlloc(global_allocator, std.json.Value{ .object = info_obj }, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to serialize agent info";
        return ZigLLMSError.JSON_ERROR.toInt();
    };

    result.error_code = ZigLLMSError.SUCCESS.toInt();
    result.data = info_json.ptr;
    result.data_length = @intCast(info_json.len);
    result.error_message = null;

    return ZigLLMSError.SUCCESS.toInt();
}

// =============================================================================
// TOOL MANAGEMENT
// =============================================================================

/// External tool callback wrapper for C clients
const ExternalToolWrapper = struct {
    name: []const u8,
    description: []const u8,
    schema: std.json.Value,
    callback: *const fn ([*c]const u8) callconv(.C) [*c]const u8,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        description: []const u8,
        schema: std.json.Value,
        callback: *const fn ([*c]const u8) callconv(.C) [*c]const u8,
    ) !*ExternalToolWrapper {
        const wrapper = try allocator.create(ExternalToolWrapper);
        wrapper.* = ExternalToolWrapper{
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .schema = schema,
            .callback = callback,
            .allocator = allocator,
        };
        return wrapper;
    }

    pub fn deinit(self: *ExternalToolWrapper) void {
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.destroy(self);
    }

    pub fn execute(self: *ExternalToolWrapper, input_json: []const u8) ![]const u8 {
        // Call external callback with null-terminated string
        const c_input = try self.allocator.allocSentinel(u8, input_json.len, 0);
        defer self.allocator.free(c_input);
        @memcpy(c_input[0..input_json.len], input_json);

        const result_ptr = self.callback(c_input.ptr);
        if (result_ptr == null) {
            return error.ToolExecutionFailed;
        }

        const result_str = std.mem.span(result_ptr);
        return try self.allocator.dupe(u8, result_str);
    }
};

// Global tool registry for external tools
var external_tools: ?std.StringHashMap(*ExternalToolWrapper) = null;
var external_tools_mutex: std.Thread.Mutex = std.Thread.Mutex{};

/// Initialize external tool registry
fn initExternalToolRegistry() !void {
    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools == null) {
        external_tools = std.StringHashMap(*ExternalToolWrapper).init(global_allocator);
    }
}

/// Cleanup external tool registry
fn deinitExternalToolRegistry() void {
    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools) |*registry| {
        var iterator = registry.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        registry.deinit();
        external_tools = null;
    }
}

/// Register a tool from external definition
export fn zigllms_tool_register(
    name: [*c]const u8,
    description: [*c]const u8,
    schema_json: [*c]const u8,
    callback_ptr: ?*const fn ([*c]const u8) callconv(.C) [*c]const u8,
) c_int {
    if (!global_initialized) {
        error_handling.reportError(ZigLLMSError.INITIALIZATION_FAILED.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.@"error", "Library not initialized", "zigllms_tool_register");
        return ZigLLMSError.INITIALIZATION_FAILED.toInt();
    }

    if (name == null or description == null or callback_ptr == null) {
        error_handling.reportError(ZigLLMSError.NULL_POINTER.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.@"error", "Null pointer provided to tool registration", "zigllms_tool_register");
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    // Initialize registry if needed
    initExternalToolRegistry() catch {
        error_handling.reportError(ZigLLMSError.MEMORY_ERROR.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.@"error", "Failed to initialize external tool registry", "zigllms_tool_register");
        return ZigLLMSError.MEMORY_ERROR.toInt();
    };

    const tool_name = std.mem.span(name);
    const tool_description = std.mem.span(description);

    // Parse schema if provided
    var schema_value: std.json.Value = .null;
    if (schema_json != null) {
        const schema_str = std.mem.span(schema_json);
        if (schema_str.len > 0) {
            const parsed_schema = std.json.parseFromSlice(std.json.Value, global_allocator, schema_str, .{}) catch {
                error_handling.reportError(ZigLLMSError.JSON_ERROR.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.@"error", "Failed to parse tool schema JSON", "zigllms_tool_register");
                return ZigLLMSError.JSON_ERROR.toInt();
            };
            schema_value = parsed_schema.value;
        }
    }

    // Create external tool wrapper
    const wrapper = ExternalToolWrapper.init(global_allocator, tool_name, tool_description, schema_value, callback_ptr.?) catch {
        error_handling.reportError(ZigLLMSError.MEMORY_ERROR.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.@"error", "Failed to create external tool wrapper", "zigllms_tool_register");
        return ZigLLMSError.MEMORY_ERROR.toInt();
    };

    // Register in external tools registry
    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools) |*registry| {
        // Check if tool already exists
        if (registry.contains(tool_name)) {
            wrapper.deinit();
            error_handling.reportError(ZigLLMSError.INVALID_PARAMETER.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.warning, "Tool with this name already registered", "zigllms_tool_register");
            return ZigLLMSError.INVALID_PARAMETER.toInt();
        }

        // Add to registry
        registry.put(tool_name, wrapper) catch {
            wrapper.deinit();
            error_handling.reportError(ZigLLMSError.MEMORY_ERROR.toInt(), error_handling.ErrorContext.tool, error_handling.Severity.@"error", "Failed to register external tool", "zigllms_tool_register");
            return ZigLLMSError.MEMORY_ERROR.toInt();
        };

        return ZigLLMSError.SUCCESS.toInt();
    }

    wrapper.deinit();
    return ZigLLMSError.INITIALIZATION_FAILED.toInt();
}

/// Execute a registered tool by name
export fn zigllms_tool_execute(
    tool_name: [*c]const u8,
    input_json: [*c]const u8,
    result: *ZigLLMSResult,
) c_int {
    if (!global_initialized) {
        result.error_code = ZigLLMSError.INITIALIZATION_FAILED.toInt();
        result.error_message = "Library not initialized";
        return ZigLLMSError.INITIALIZATION_FAILED.toInt();
    }

    if (tool_name == null or input_json == null) {
        result.error_code = ZigLLMSError.NULL_POINTER.toInt();
        result.error_message = "Null pointer provided";
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const name_str = std.mem.span(tool_name);
    const input_str = std.mem.span(input_json);

    // Validate input JSON
    const input_validation = std.json.parseFromSlice(std.json.Value, global_allocator, input_str, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Invalid input JSON";
        return ZigLLMSError.JSON_ERROR.toInt();
    };
    input_validation.deinit();

    // Find tool in external registry
    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools) |*registry| {
        if (registry.get(name_str)) |wrapper| {
            // Execute external tool
            const tool_result = wrapper.execute(input_str) catch |err| switch (err) {
                error.ToolExecutionFailed => {
                    result.error_code = ZigLLMSError.TOOL_ERROR.toInt();
                    result.error_message = "External tool execution failed";
                    return ZigLLMSError.TOOL_ERROR.toInt();
                },
                error.OutOfMemory => {
                    result.error_code = ZigLLMSError.MEMORY_ERROR.toInt();
                    result.error_message = "Out of memory during tool execution";
                    return ZigLLMSError.MEMORY_ERROR.toInt();
                },
                else => {
                    result.error_code = ZigLLMSError.UNKNOWN_ERROR.toInt();
                    result.error_message = "Unknown error during tool execution";
                    return ZigLLMSError.UNKNOWN_ERROR.toInt();
                },
            };

            // Validate result JSON
            const result_validation = std.json.parseFromSlice(std.json.Value, global_allocator, tool_result, .{}) catch {
                global_allocator.free(tool_result);
                result.error_code = ZigLLMSError.JSON_ERROR.toInt();
                result.error_message = "Tool returned invalid JSON";
                return ZigLLMSError.JSON_ERROR.toInt();
            };
            result_validation.deinit();

            result.error_code = ZigLLMSError.SUCCESS.toInt();
            result.data = tool_result.ptr;
            result.data_length = @intCast(tool_result.len);
            result.error_message = null;

            return ZigLLMSError.SUCCESS.toInt();
        }
    }

    // Tool not found
    result.error_code = ZigLLMSError.TOOL_ERROR.toInt();
    result.error_message = "Tool not found";
    return ZigLLMSError.TOOL_ERROR.toInt();
}

/// List all registered tools
export fn zigllms_tool_list(result: *ZigLLMSResult) c_int {
    if (!global_initialized) {
        result.error_code = ZigLLMSError.INITIALIZATION_FAILED.toInt();
        result.error_message = "Library not initialized";
        return ZigLLMSError.INITIALIZATION_FAILED.toInt();
    }

    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    var tools_array = std.ArrayList(std.json.Value).init(global_allocator);
    defer tools_array.deinit();

    if (external_tools) |*registry| {
        var iterator = registry.iterator();
        while (iterator.next()) |entry| {
            const wrapper = entry.value_ptr.*;

            var tool_obj = std.json.ObjectMap.init(global_allocator);
            tool_obj.put("name", .{ .string = wrapper.name }) catch continue;
            tool_obj.put("description", .{ .string = wrapper.description }) catch continue;
            tool_obj.put("type", .{ .string = "external" }) catch continue;

            // Add schema if available
            if (wrapper.schema != .null) {
                tool_obj.put("schema", wrapper.schema) catch continue;
            }

            tools_array.append(.{ .object = tool_obj }) catch continue;
        }
    }

    // Serialize to JSON
    const tools_json = std.json.stringifyAlloc(global_allocator, std.json.Value{ .array = std.json.Array.fromOwnedSlice(global_allocator, tools_array.toOwnedSlice() catch &[_]std.json.Value{}) }, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to serialize tools list";
        return ZigLLMSError.JSON_ERROR.toInt();
    };

    result.error_code = ZigLLMSError.SUCCESS.toInt();
    result.data = tools_json.ptr;
    result.data_length = @intCast(tools_json.len);
    result.error_message = null;

    return ZigLLMSError.SUCCESS.toInt();
}

/// Unregister a tool by name
export fn zigllms_tool_unregister(tool_name: [*c]const u8) c_int {
    if (!global_initialized) {
        return ZigLLMSError.INITIALIZATION_FAILED.toInt();
    }

    if (tool_name == null) {
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const name_str = std.mem.span(tool_name);

    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools) |*registry| {
        if (registry.fetchRemove(name_str)) |entry| {
            entry.value.deinit();
            return ZigLLMSError.SUCCESS.toInt();
        }
    }

    return ZigLLMSError.TOOL_ERROR.toInt();
}

/// Get tool information by name
export fn zigllms_tool_get_info(
    tool_name: [*c]const u8,
    result: *ZigLLMSResult,
) c_int {
    if (!global_initialized) {
        result.error_code = ZigLLMSError.INITIALIZATION_FAILED.toInt();
        result.error_message = "Library not initialized";
        return ZigLLMSError.INITIALIZATION_FAILED.toInt();
    }

    if (tool_name == null) {
        result.error_code = ZigLLMSError.NULL_POINTER.toInt();
        result.error_message = "Null tool name";
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const name_str = std.mem.span(tool_name);

    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools) |*registry| {
        if (registry.get(name_str)) |wrapper| {
            var tool_obj = std.json.ObjectMap.init(global_allocator);
            tool_obj.put("name", .{ .string = wrapper.name }) catch {
                result.error_code = ZigLLMSError.MEMORY_ERROR.toInt();
                result.error_message = "Failed to build tool info";
                return ZigLLMSError.MEMORY_ERROR.toInt();
            };
            tool_obj.put("description", .{ .string = wrapper.description }) catch {
                result.error_code = ZigLLMSError.MEMORY_ERROR.toInt();
                result.error_message = "Failed to build tool info";
                return ZigLLMSError.MEMORY_ERROR.toInt();
            };
            tool_obj.put("type", .{ .string = "external" }) catch {
                result.error_code = ZigLLMSError.MEMORY_ERROR.toInt();
                result.error_message = "Failed to build tool info";
                return ZigLLMSError.MEMORY_ERROR.toInt();
            };

            if (wrapper.schema != .null) {
                tool_obj.put("schema", wrapper.schema) catch {
                    result.error_code = ZigLLMSError.MEMORY_ERROR.toInt();
                    result.error_message = "Failed to build tool info";
                    return ZigLLMSError.MEMORY_ERROR.toInt();
                };
            }

            const info_json = std.json.stringifyAlloc(global_allocator, std.json.Value{ .object = tool_obj }, .{}) catch {
                result.error_code = ZigLLMSError.JSON_ERROR.toInt();
                result.error_message = "Failed to serialize tool info";
                return ZigLLMSError.JSON_ERROR.toInt();
            };

            result.error_code = ZigLLMSError.SUCCESS.toInt();
            result.data = info_json.ptr;
            result.data_length = @intCast(info_json.len);
            result.error_message = null;

            return ZigLLMSError.SUCCESS.toInt();
        }
    }

    result.error_code = ZigLLMSError.TOOL_ERROR.toInt();
    result.error_message = "Tool not found";
    return ZigLLMSError.TOOL_ERROR.toInt();
}

/// Check if a tool is registered
export fn zigllms_tool_exists(tool_name: [*c]const u8) c_int {
    if (!global_initialized or tool_name == null) {
        return 0; // false
    }

    const name_str = std.mem.span(tool_name);

    external_tools_mutex.lock();
    defer external_tools_mutex.unlock();

    if (external_tools) |*registry| {
        return if (registry.contains(name_str)) 1 else 0;
    }

    return 0; // false
}

// =============================================================================
// WORKFLOW MANAGEMENT
// =============================================================================

/// Create a new workflow
export fn zigllms_workflow_create(name: [*c]const u8) ?*ZigLLMSWorkflow {
    if (!global_initialized or name == null) return null;

    const workflow_name = std.mem.span(name);
    const workflow_instance = Workflow.init(global_allocator, workflow_name) catch return null;

    return @ptrCast(workflow_instance);
}

/// Destroy a workflow
export fn zigllms_workflow_destroy(workflow_handle: ?*ZigLLMSWorkflow) void {
    if (workflow_handle == null) return;

    const workflow_instance: *Workflow = @ptrCast(@alignCast(workflow_handle));
    workflow_instance.deinit();
}

/// Execute a workflow
export fn zigllms_workflow_execute(
    workflow_handle: ?*ZigLLMSWorkflow,
    input_json: [*c]const u8,
    result: *ZigLLMSResult,
) c_int {
    if (workflow_handle == null or input_json == null) {
        result.error_code = ZigLLMSError.NULL_POINTER.toInt();
        result.error_message = "Null pointer provided";
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const workflow_instance: *Workflow = @ptrCast(@alignCast(workflow_handle));
    const input_str = std.mem.span(input_json);

    // Parse input JSON
    const input_value = std.json.parseFromSlice(std.json.Value, global_allocator, input_str, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to parse input JSON";
        return ZigLLMSError.JSON_ERROR.toInt();
    };
    defer input_value.deinit();

    // Execute workflow
    const workflow_result = workflow_instance.vtable.execute(workflow_instance, input_value.value, global_allocator) catch {
        result.error_code = ZigLLMSError.WORKFLOW_ERROR.toInt();
        result.error_message = "Workflow execution failed";
        return ZigLLMSError.WORKFLOW_ERROR.toInt();
    };

    // Serialize result
    const result_json = std.json.stringifyAlloc(global_allocator, workflow_result, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to serialize result";
        return ZigLLMSError.JSON_ERROR.toInt();
    };

    result.error_code = ZigLLMSError.SUCCESS.toInt();
    result.data = result_json.ptr;
    result.data_length = @intCast(result_json.len);
    result.error_message = null;

    return ZigLLMSError.SUCCESS.toInt();
}

// =============================================================================
// MEMORY MANAGEMENT
// =============================================================================

/// Free a result returned by the API
export fn zigllms_result_free(result: *ZigLLMSResult) void {
    if (result.data != null and result.data_length > 0) {
        const data_slice = result.data[0..@intCast(result.data_length)];
        global_allocator.free(data_slice);
        result.data = null;
        result.data_length = 0;
    }
}

/// Create a session for isolated memory management
export fn zigllms_session_create(session_id: [*c]const u8) c_int {
    if (!global_initialized or session_id == null) {
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    if (global_session_manager) |*manager| {
        const id_str = std.mem.span(session_id);
        manager.createSession(id_str) catch |err| switch (err) {
            error.TooManySessions => return ZigLLMSError.MEMORY_ERROR.toInt(),
            error.SessionAlreadyExists => return ZigLLMSError.INVALID_PARAMETER.toInt(),
            else => return ZigLLMSError.UNKNOWN_ERROR.toInt(),
        };
        return ZigLLMSError.SUCCESS.toInt();
    }

    return ZigLLMSError.INITIALIZATION_FAILED.toInt();
}

/// Destroy a session and free all its memory
export fn zigllms_session_destroy(session_id: [*c]const u8) c_int {
    if (!global_initialized or session_id == null) {
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    if (global_session_manager) |*manager| {
        const id_str = std.mem.span(session_id);
        if (manager.destroySession(id_str)) {
            return ZigLLMSError.SUCCESS.toInt();
        } else {
            return ZigLLMSError.INVALID_PARAMETER.toInt();
        }
    }

    return ZigLLMSError.INITIALIZATION_FAILED.toInt();
}

/// Reset a session's arena allocator
export fn zigllms_session_reset(session_id: [*c]const u8) c_int {
    if (!global_initialized or session_id == null) {
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    if (global_session_manager) |*manager| {
        const id_str = std.mem.span(session_id);
        if (manager.getSession(id_str)) |session| {
            session.reset();
            return ZigLLMSError.SUCCESS.toInt();
        } else {
            return ZigLLMSError.INVALID_PARAMETER.toInt();
        }
    }

    return ZigLLMSError.INITIALIZATION_FAILED.toInt();
}

/// Get memory usage statistics
export fn zigllms_memory_stats(result: *ZigLLMSResult) c_int {
    // Create memory stats object
    var stats_obj = std.json.ObjectMap.init(global_allocator);
    stats_obj.put("initialized", .{ .bool = global_initialized }) catch {};

    // Add tracking allocator stats if available
    if (global_tracking_allocator) |*tracker| {
        const memory_stats = tracker.getStats();
        stats_obj.put("total_allocated", .{ .integer = @as(i64, @intCast(memory_stats.total_allocated)) }) catch {};
        stats_obj.put("total_freed", .{ .integer = @as(i64, @intCast(memory_stats.total_freed)) }) catch {};
        stats_obj.put("current_allocated", .{ .integer = @as(i64, @intCast(memory_stats.current_allocated)) }) catch {};
        stats_obj.put("peak_allocated", .{ .integer = @as(i64, @intCast(memory_stats.peak_allocated)) }) catch {};
        stats_obj.put("allocation_count", .{ .integer = @as(i64, @intCast(memory_stats.allocation_count)) }) catch {};
        stats_obj.put("free_count", .{ .integer = @as(i64, @intCast(memory_stats.free_count)) }) catch {};
        stats_obj.put("leak_count", .{ .integer = @as(i64, @intCast(memory_stats.leak_count)) }) catch {};
        stats_obj.put("active_allocations", .{ .integer = @as(i64, @intCast(tracker.getAllocationCount())) }) catch {};
    }

    // Add session manager stats if available
    if (global_session_manager) |*manager| {
        stats_obj.put("active_sessions", .{ .integer = @as(i64, @intCast(manager.getSessionCount())) }) catch {};
    }

    // Add memory pool stats if available
    if (global_memory_pool) |*pool| {
        const usage = pool.getUsage();
        stats_obj.put("pool_allocated_blocks", .{ .integer = @as(i64, @intCast(usage.allocated)) }) catch {};
        stats_obj.put("pool_total_blocks", .{ .integer = @as(i64, @intCast(usage.total)) }) catch {};
    }

    const stats_json = std.json.stringifyAlloc(global_allocator, std.json.Value{ .object = stats_obj }, .{}) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to serialize memory stats";
        return ZigLLMSError.JSON_ERROR.toInt();
    };

    result.error_code = ZigLLMSError.SUCCESS.toInt();
    result.data = stats_json.ptr;
    result.data_length = @intCast(stats_json.len);
    result.error_message = null;

    return ZigLLMSError.SUCCESS.toInt();
}

// =============================================================================
// EVENT SYSTEM
// =============================================================================

/// Create an event emitter
export fn zigllms_events_create() ?*ZigLLMSEventEmitter {
    if (!global_initialized) return null;

    const c_emitter = CEventEmitter.init(global_allocator) catch return null;
    return @ptrCast(c_emitter);
}

/// Destroy an event emitter
export fn zigllms_events_destroy(emitter_handle: ?*ZigLLMSEventEmitter) void {
    if (emitter_handle == null) return;

    const emitter: *EventEmitter = @ptrCast(@alignCast(emitter_handle));
    emitter.deinit();
}

/// Event subscription wrapper for C clients
const EventSubscription = struct {
    event_type: []const u8,
    callback: *const fn ([*c]const u8) callconv(.C) void,
    subscription_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        event_type: []const u8,
        callback: *const fn ([*c]const u8) callconv(.C) void,
        subscription_id: u32,
    ) !*EventSubscription {
        const subscription = try allocator.create(EventSubscription);
        subscription.* = EventSubscription{
            .event_type = try allocator.dupe(u8, event_type),
            .callback = callback,
            .subscription_id = subscription_id,
            .allocator = allocator,
        };
        return subscription;
    }

    pub fn deinit(self: *EventSubscription) void {
        self.allocator.free(self.event_type);
        self.allocator.destroy(self);
    }

    pub fn notify(self: *EventSubscription, event_data: []const u8) void {
        // Convert to null-terminated string for C callback
        const c_data = self.allocator.allocSentinel(u8, event_data.len, 0) catch return;
        defer self.allocator.free(c_data);
        @memcpy(c_data[0..event_data.len], event_data);

        self.callback(c_data.ptr);
    }
};

/// Enhanced event emitter wrapper for C-API
const CEventEmitter = struct {
    emitter: *EventEmitter,
    subscriptions: std.ArrayList(*EventSubscription),
    subscription_counter: u32,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*CEventEmitter {
        const emitter = try EventEmitter.init(allocator);
        const c_emitter = try allocator.create(CEventEmitter);
        c_emitter.* = CEventEmitter{
            .emitter = emitter,
            .subscriptions = std.ArrayList(*EventSubscription).init(allocator),
            .subscription_counter = 1,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
        return c_emitter;
    }

    pub fn deinit(self: *CEventEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all subscriptions
        for (self.subscriptions.items) |subscription| {
            subscription.deinit();
        }
        self.subscriptions.deinit();

        self.emitter.deinit();
        self.allocator.destroy(self);
    }

    pub fn subscribe(
        self: *CEventEmitter,
        event_type: []const u8,
        callback: *const fn ([*c]const u8) callconv(.C) void,
    ) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const subscription_id = self.subscription_counter;
        self.subscription_counter += 1;

        const subscription = try EventSubscription.init(self.allocator, event_type, callback, subscription_id);

        try self.subscriptions.append(subscription);

        return subscription_id;
    }

    pub fn unsubscribe(self: *CEventEmitter, subscription_id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.subscriptions.items, 0..) |subscription, i| {
            if (subscription.subscription_id == subscription_id) {
                subscription.deinit();
                _ = self.subscriptions.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn emit(self: *CEventEmitter, event_type: []const u8, event_data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Emit to internal event system
        try self.emitter.emit(event_type, event_data);

        // Notify C subscribers
        for (self.subscriptions.items) |subscription| {
            if (std.mem.eql(u8, subscription.event_type, event_type)) {
                subscription.notify(event_data);
            }
        }
    }

    pub fn getSubscriptionCount(self: *CEventEmitter) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.subscriptions.items.len;
    }
};

/// Subscribe to events with callback
export fn zigllms_events_subscribe(
    emitter_handle: ?*ZigLLMSEventEmitter,
    event_type: [*c]const u8,
    callback_ptr: ?*const fn ([*c]const u8) callconv(.C) void,
) c_int {
    if (!global_initialized) {
        error_handling.reportError(ZigLLMSError.INITIALIZATION_FAILED.toInt(), error_handling.ErrorContext.general, error_handling.Severity.@"error", "Library not initialized", "zigllms_events_subscribe");
        return ZigLLMSError.INITIALIZATION_FAILED.toInt();
    }

    if (emitter_handle == null or event_type == null or callback_ptr == null) {
        error_handling.reportError(ZigLLMSError.NULL_POINTER.toInt(), error_handling.ErrorContext.general, error_handling.Severity.@"error", "Null pointer provided to event subscription", "zigllms_events_subscribe");
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    const c_emitter: *CEventEmitter = @ptrCast(@alignCast(emitter_handle));
    const event_type_str = std.mem.span(event_type);

    const subscription_id = c_emitter.subscribe(event_type_str, callback_ptr.?) catch {
        error_handling.reportError(ZigLLMSError.MEMORY_ERROR.toInt(), error_handling.ErrorContext.general, error_handling.Severity.@"error", "Failed to create event subscription", "zigllms_events_subscribe");
        return ZigLLMSError.MEMORY_ERROR.toInt();
    };

    return @intCast(subscription_id);
}

/// Emit an event
export fn zigllms_events_emit(
    emitter_handle: ?*ZigLLMSEventEmitter,
    event_type: [*c]const u8,
    data_json: [*c]const u8,
) c_int {
    if (emitter_handle == null or event_type == null) {
        return ZigLLMSError.NULL_POINTER.toInt();
    }

    _ = data_json; // TODO: Use this parameter when implementing event emission
    // Event emission would be implemented here
    return ZigLLMSError.SUCCESS.toInt();
}

// =============================================================================
// UTILITY FUNCTIONS
// =============================================================================

/// Validate JSON string
export fn zigllms_json_validate(json_str: [*c]const u8) c_int {
    if (json_str == null) return ZigLLMSError.NULL_POINTER.toInt();

    const json_string = std.mem.span(json_str);

    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, json_string, .{}) catch {
        return ZigLLMSError.JSON_ERROR.toInt();
    };
    defer parsed.deinit();

    return ZigLLMSError.SUCCESS.toInt();
}

/// Convert error code to string
export fn zigllms_error_string(error_code: c_int) [*c]const u8 {
    return switch (error_code) {
        0 => "SUCCESS",
        -1 => "NULL_POINTER",
        -2 => "INVALID_PARAMETER",
        -3 => "MEMORY_ERROR",
        -4 => "INITIALIZATION_FAILED",
        -5 => "AGENT_ERROR",
        -6 => "TOOL_ERROR",
        -7 => "WORKFLOW_ERROR",
        -8 => "PROVIDER_ERROR",
        -9 => "JSON_ERROR",
        -10 => "TIMEOUT_ERROR",
        else => "UNKNOWN_ERROR",
    };
}

/// Set error callback for C clients
export fn zigllms_set_error_callback(callback: ?*const fn (error_code: c_int, category: c_int, severity: c_int, message: [*c]const u8, context: [*c]const u8) callconv(.C) void) void {
    if (callback) |cb| {
        const wrapper_callback = struct {
            fn errorCallback(error_info: *const error_handling.ErrorInfo) callconv(.C) void {
                const message_str = std.mem.sliceTo(&error_info.message, 0);
                const context_str = std.mem.sliceTo(&error_info.context, 0);

                cb(error_info.code, @intFromEnum(error_info.category), @intFromEnum(error_info.severity), message_str.ptr, context_str.ptr);
            }
        }.errorCallback;

        error_handling.setErrorCallback(wrapper_callback);
    }
}

/// Get last error information
export fn zigllms_get_last_error(result: *ZigLLMSResult) c_int {
    if (error_handling.getLastError()) |_| {
        // Format error as JSON
        const error_json = error_handling.formatErrorStackAsJson(global_allocator) catch {
            result.error_code = ZigLLMSError.JSON_ERROR.toInt();
            result.error_message = "Failed to format error information";
            return ZigLLMSError.JSON_ERROR.toInt();
        };

        result.error_code = ZigLLMSError.SUCCESS.toInt();
        result.data = error_json.ptr;
        result.data_length = @intCast(error_json.len);
        result.error_message = null;

        return ZigLLMSError.SUCCESS.toInt();
    } else {
        result.error_code = ZigLLMSError.SUCCESS.toInt();
        result.data = "null";
        result.data_length = 4;
        result.error_message = null;

        return ZigLLMSError.SUCCESS.toInt();
    }
}

/// Get error count
export fn zigllms_get_error_count() c_int {
    return @intCast(error_handling.getErrorCount());
}

/// Clear all errors
export fn zigllms_clear_errors() void {
    error_handling.clearErrors();
}

/// Get all errors as JSON array
export fn zigllms_get_error_stack(result: *ZigLLMSResult) c_int {
    const error_stack_json = error_handling.formatErrorStackAsJson(global_allocator) catch {
        result.error_code = ZigLLMSError.JSON_ERROR.toInt();
        result.error_message = "Failed to format error stack";
        return ZigLLMSError.JSON_ERROR.toInt();
    };

    result.error_code = ZigLLMSError.SUCCESS.toInt();
    result.data = error_stack_json.ptr;
    result.data_length = @intCast(error_stack_json.len);
    result.error_message = null;

    return ZigLLMSError.SUCCESS.toInt();
}

/// Get last error message (thread-local for backwards compatibility)
threadlocal var last_error: [256]u8 = [_]u8{0} ** 256;

export fn zigllms_get_last_error_message() [*c]const u8 {
    if (error_handling.getLastError()) |error_info| {
        const message_str = std.mem.sliceTo(&error_info.message, 0);
        const len = @min(message_str.len, last_error.len - 1);
        @memcpy(last_error[0..len], message_str[0..len]);
        last_error[len] = 0;
        return &last_error;
    }
    return "No error";
}

// Helper function to set last error (internal use)
fn setLastError(message: []const u8) void {
    const len = @min(message.len, last_error.len - 1);
    @memcpy(last_error[0..len], message[0..len]);
    last_error[len] = 0;
}

// =============================================================================
// TESTS
// =============================================================================

test "capi initialization" {
    const config = ZigLLMSConfig{
        .allocator_type = 0,
        .log_level = 1,
        .enable_events = true,
        .enable_metrics = false,
        .max_memory_mb = 100,
    };

    const result = zigllms_init(&config);
    try std.testing.expectEqual(@as(c_int, 0), result);

    defer zigllms_cleanup();

    var major: c_int = 0;
    var minor: c_int = 0;
    var patch: c_int = 0;
    zigllms_get_version(&major, &minor, &patch);

    try std.testing.expectEqual(@as(c_int, 1), major);
    try std.testing.expectEqual(@as(c_int, 0), minor);
    try std.testing.expectEqual(@as(c_int, 0), patch);
}

test "capi json validation" {
    const config = ZigLLMSConfig{
        .allocator_type = 0,
        .log_level = 1,
        .enable_events = false,
        .enable_metrics = false,
        .max_memory_mb = 100,
    };

    _ = zigllms_init(&config);
    defer zigllms_cleanup();

    // Valid JSON
    const valid_json = "{\"test\": true}";
    const valid_result = zigllms_json_validate(valid_json.ptr);
    try std.testing.expectEqual(@as(c_int, 0), valid_result);

    // Invalid JSON
    const invalid_json = "{invalid json}";
    const invalid_result = zigllms_json_validate(invalid_json.ptr);
    try std.testing.expectEqual(ZigLLMSError.JSON_ERROR.toInt(), invalid_result);
}

test "capi error handling" {
    const error_msg = zigllms_error_string(ZigLLMSError.AGENT_ERROR.toInt());
    const expected = "AGENT_ERROR";

    const actual = std.mem.span(error_msg);
    try std.testing.expectEqualStrings(expected, actual);
}

test "external tool registration" {
    const config = ZigLLMSConfig{
        .allocator_type = 0,
        .log_level = 1,
        .enable_events = false,
        .enable_metrics = false,
        .max_memory_mb = 100,
    };

    _ = zigllms_init(&config);
    defer zigllms_cleanup();

    // Test callback function
    const TestCallback = struct {
        fn callback(input: [*c]const u8) callconv(.C) [*c]const u8 {
            _ = input;
            return "{\"result\": \"test_output\"}";
        }
    };

    // Register a tool
    const tool_name = "test_tool";
    const tool_desc = "A test tool";
    const tool_schema = "{\"type\": \"object\"}";

    const reg_result = zigllms_tool_register(tool_name.ptr, tool_desc.ptr, tool_schema.ptr, TestCallback.callback);
    try std.testing.expectEqual(@as(c_int, 0), reg_result);

    // Check if tool exists
    const exists = zigllms_tool_exists(tool_name.ptr);
    try std.testing.expectEqual(@as(c_int, 1), exists);

    // Execute the tool
    var result: ZigLLMSResult = undefined;
    const exec_result = zigllms_tool_execute(tool_name.ptr, "{\"input\": \"test\"}", &result);
    try std.testing.expectEqual(@as(c_int, 0), exec_result);
    try std.testing.expectEqual(@as(c_int, 0), result.error_code);

    // Clean up result
    zigllms_result_free(&result);

    // Unregister the tool
    const unreg_result = zigllms_tool_unregister(tool_name.ptr);
    try std.testing.expectEqual(@as(c_int, 0), unreg_result);

    // Check that tool no longer exists
    const exists_after = zigllms_tool_exists(tool_name.ptr);
    try std.testing.expectEqual(@as(c_int, 0), exists_after);
}
