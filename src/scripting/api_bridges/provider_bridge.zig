// ABOUTME: Provider API bridge for exposing LLM provider functionality to scripts
// ABOUTME: Enables direct provider access, configuration, and management from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms provider API
const provider = @import("../../provider.zig");
const provider_registry = @import("../../providers/registry.zig");

/// Provider configuration wrapper
const ScriptProviderConfig = struct {
    name: []const u8,
    type: []const u8,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    models: []const []const u8 = &[_][]const u8{},
    timeout: u32 = 30000,
    retry_config: ?RetryConfig = null,
    
    const RetryConfig = struct {
        max_retries: u32 = 3,
        initial_delay_ms: u32 = 1000,
        max_delay_ms: u32 = 30000,
        exponential_base: f32 = 2.0,
    };
};

/// Provider Bridge implementation
pub const ProviderBridge = struct {
    pub const bridge = APIBridge{
        .name = "provider",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };
    
    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);
        
        module.* = ScriptModule{
            .name = "provider",
            .functions = &provider_functions,
            .constants = &provider_constants,
            .description = "LLM provider management and direct access API",
            .version = "1.0.0",
        };
        
        return module;
    }
    
    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;
        _ = context;
        // Provider registry is managed by the core system
    }
    
    fn deinit() void {
        // Cleanup if needed
    }
};

// Provider module functions
const provider_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "list",
        "List all available providers",
        0,
        listProviders,
    ),
    createModuleFunction(
        "register",
        "Register a new provider configuration",
        1,
        registerProvider,
    ),
    createModuleFunction(
        "unregister",
        "Unregister a provider",
        1,
        unregisterProvider,
    ),
    createModuleFunction(
        "getCapabilities",
        "Get provider capabilities and features",
        1,
        getProviderCapabilities,
    ),
    createModuleFunction(
        "getModels",
        "Get available models for a provider",
        1,
        getProviderModels,
    ),
    createModuleFunction(
        "complete",
        "Direct completion call to provider",
        2,
        completeWithProvider,
    ),
    createModuleFunction(
        "completeAsync",
        "Async completion call to provider",
        3,
        completeWithProviderAsync,
    ),
    createModuleFunction(
        "stream",
        "Stream completion from provider",
        3,
        streamFromProvider,
    ),
    createModuleFunction(
        "validateApiKey",
        "Validate API key for provider",
        2,
        validateApiKey,
    ),
    createModuleFunction(
        "getUsage",
        "Get usage statistics for provider",
        1,
        getProviderUsage,
    ),
    createModuleFunction(
        "getRateLimits",
        "Get rate limit information",
        1,
        getProviderRateLimits,
    ),
    createModuleFunction(
        "setDefault",
        "Set default provider",
        1,
        setDefaultProvider,
    ),
    createModuleFunction(
        "getDefault",
        "Get default provider",
        0,
        getDefaultProvider,
    ),
    createModuleFunction(
        "testConnection",
        "Test provider connection",
        1,
        testProviderConnection,
    ),
    createModuleFunction(
        "getMetadata",
        "Get provider metadata",
        1,
        getProviderMetadata,
    ),
};

// Provider module constants
const provider_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "TYPE_OPENAI",
        ScriptValue{ .string = "openai" },
        "OpenAI provider type",
    ),
    createModuleConstant(
        "TYPE_ANTHROPIC",
        ScriptValue{ .string = "anthropic" },
        "Anthropic provider type",
    ),
    createModuleConstant(
        "TYPE_OLLAMA",
        ScriptValue{ .string = "ollama" },
        "Ollama provider type",
    ),
    createModuleConstant(
        "TYPE_GEMINI",
        ScriptValue{ .string = "gemini" },
        "Google Gemini provider type",
    ),
    createModuleConstant(
        "TYPE_CUSTOM",
        ScriptValue{ .string = "custom" },
        "Custom provider type",
    ),
    createModuleConstant(
        "MODEL_GPT4",
        ScriptValue{ .string = "gpt-4" },
        "OpenAI GPT-4 model",
    ),
    createModuleConstant(
        "MODEL_GPT35_TURBO",
        ScriptValue{ .string = "gpt-3.5-turbo" },
        "OpenAI GPT-3.5 Turbo model",
    ),
    createModuleConstant(
        "MODEL_CLAUDE_3_OPUS",
        ScriptValue{ .string = "claude-3-opus-20240229" },
        "Anthropic Claude 3 Opus model",
    ),
    createModuleConstant(
        "MODEL_CLAUDE_3_SONNET",
        ScriptValue{ .string = "claude-3-sonnet-20240229" },
        "Anthropic Claude 3 Sonnet model",
    ),
};

// Implementation functions

fn listProviders(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;
    
    const context = @fieldParentPtr(ScriptContext, "allocator", args.ptr);
    const allocator = context.allocator;
    
    // Get available providers (simplified for now)
    const providers = [_]struct {
        name: []const u8,
        type: []const u8,
        status: []const u8,
    }{
        .{ .name = "openai", .type = "openai", .status = "available" },
        .{ .name = "anthropic", .type = "anthropic", .status = "available" },
        .{ .name = "ollama", .type = "ollama", .status = "available" },
        .{ .name = "gemini", .type = "gemini", .status = "available" },
    };
    
    var list = try ScriptValue.Array.init(allocator, providers.len);
    
    for (providers, 0..) |p, i| {
        var provider_obj = ScriptValue.Object.init(allocator);
        try provider_obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, p.name) });
        try provider_obj.put("type", ScriptValue{ .string = try allocator.dupe(u8, p.type) });
        try provider_obj.put("status", ScriptValue{ .string = try allocator.dupe(u8, p.status) });
        list.items[i] = ScriptValue{ .object = provider_obj };
    }
    
    return ScriptValue{ .array = list };
}

fn registerProvider(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }
    
    const config_obj = args[0].object;
    const allocator = config_obj.allocator;
    
    // Extract provider configuration
    const name = if (config_obj.get("name")) |n|
        try n.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const provider_type = if (config_obj.get("type")) |t|
        try t.toZig([]const u8, allocator)
    else
        return error.MissingField;
    
    // In real implementation, this would register with the provider registry
    _ = name;
    _ = provider_type;
    
    return ScriptValue{ .boolean = true };
}

fn unregisterProvider(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    _ = provider_name;
    
    // In real implementation, this would unregister from the provider registry
    return ScriptValue{ .boolean = true };
}

fn getProviderCapabilities(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", provider_name).allocator;
    
    var capabilities = ScriptValue.Object.init(allocator);
    
    // Return capabilities based on provider type
    if (std.mem.eql(u8, provider_name, "openai")) {
        try capabilities.put("streaming", ScriptValue{ .boolean = true });
        try capabilities.put("functions", ScriptValue{ .boolean = true });
        try capabilities.put("vision", ScriptValue{ .boolean = true });
        try capabilities.put("max_context_tokens", ScriptValue{ .integer = 128000 });
        try capabilities.put("max_output_tokens", ScriptValue{ .integer = 4096 });
        
        var supported_models = try ScriptValue.Array.init(allocator, 4);
        supported_models.items[0] = ScriptValue{ .string = try allocator.dupe(u8, "gpt-4") };
        supported_models.items[1] = ScriptValue{ .string = try allocator.dupe(u8, "gpt-4-turbo") };
        supported_models.items[2] = ScriptValue{ .string = try allocator.dupe(u8, "gpt-3.5-turbo") };
        supported_models.items[3] = ScriptValue{ .string = try allocator.dupe(u8, "gpt-4-vision-preview") };
        try capabilities.put("models", ScriptValue{ .array = supported_models });
    } else if (std.mem.eql(u8, provider_name, "anthropic")) {
        try capabilities.put("streaming", ScriptValue{ .boolean = true });
        try capabilities.put("functions", ScriptValue{ .boolean = false });
        try capabilities.put("vision", ScriptValue{ .boolean = true });
        try capabilities.put("max_context_tokens", ScriptValue{ .integer = 200000 });
        try capabilities.put("max_output_tokens", ScriptValue{ .integer = 4096 });
        
        var supported_models = try ScriptValue.Array.init(allocator, 2);
        supported_models.items[0] = ScriptValue{ .string = try allocator.dupe(u8, "claude-3-opus-20240229") };
        supported_models.items[1] = ScriptValue{ .string = try allocator.dupe(u8, "claude-3-sonnet-20240229") };
        try capabilities.put("models", ScriptValue{ .array = supported_models });
    }
    
    return ScriptValue{ .object = capabilities };
}

fn getProviderModels(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", provider_name).allocator;
    
    var models = std.ArrayList(ScriptValue).init(allocator);
    
    if (std.mem.eql(u8, provider_name, "openai")) {
        const openai_models = [_]struct {
            id: []const u8,
            name: []const u8,
            context: i64,
        }{
            .{ .id = "gpt-4", .name = "GPT-4", .context = 8192 },
            .{ .id = "gpt-4-turbo", .name = "GPT-4 Turbo", .context = 128000 },
            .{ .id = "gpt-3.5-turbo", .name = "GPT-3.5 Turbo", .context = 16384 },
            .{ .id = "gpt-4-vision-preview", .name = "GPT-4 Vision", .context = 128000 },
        };
        
        for (openai_models) |model| {
            var model_obj = ScriptValue.Object.init(allocator);
            try model_obj.put("id", ScriptValue{ .string = try allocator.dupe(u8, model.id) });
            try model_obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, model.name) });
            try model_obj.put("context_length", ScriptValue{ .integer = model.context });
            try models.append(ScriptValue{ .object = model_obj });
        }
    }
    
    return ScriptValue{ .array = .{ .items = try models.toOwnedSlice(), .allocator = allocator } };
}

fn completeWithProvider(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const request_obj = args[1].object;
    const allocator = request_obj.allocator;
    
    // Extract request parameters
    const model = if (request_obj.get("model")) |m|
        try m.toZig([]const u8, allocator)
    else
        return error.MissingField;
        
    const messages = request_obj.get("messages") orelse return error.MissingField;
    
    // Simulate provider completion
    _ = provider_name;
    _ = model;
    _ = messages;
    
    var response = ScriptValue.Object.init(allocator);
    try response.put("content", ScriptValue{ .string = try allocator.dupe(u8, "This is a simulated response from the provider.") });
    try response.put("model", ScriptValue{ .string = try allocator.dupe(u8, model) });
    
    var usage = ScriptValue.Object.init(allocator);
    try usage.put("prompt_tokens", ScriptValue{ .integer = 100 });
    try usage.put("completion_tokens", ScriptValue{ .integer = 50 });
    try usage.put("total_tokens", ScriptValue{ .integer = 150 });
    try response.put("usage", ScriptValue{ .object = usage });
    
    return ScriptValue{ .object = response };
}

fn completeWithProviderAsync(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[2] != .function) {
        return error.InvalidArguments;
    }
    
    // Execute synchronously and call callback
    const result = completeWithProvider(args[0..2]) catch |err| {
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

fn streamFromProvider(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[0] != .string or args[1] != .object or args[2] != .function) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const request_obj = args[1].object;
    const stream_callback = args[2].function;
    const allocator = request_obj.allocator;
    
    _ = provider_name;
    
    // Simulate streaming response
    const chunks = [_][]const u8{
        "This ",
        "is a ",
        "simulated ",
        "streaming ",
        "response.",
    };
    
    for (chunks) |chunk| {
        var chunk_obj = ScriptValue.Object.init(allocator);
        try chunk_obj.put("content", ScriptValue{ .string = try allocator.dupe(u8, chunk) });
        try chunk_obj.put("done", ScriptValue{ .boolean = false });
        
        const callback_args = [_]ScriptValue{ScriptValue{ .object = chunk_obj }};
        _ = try stream_callback.call(&callback_args);
    }
    
    // Send final chunk
    var final_obj = ScriptValue.Object.init(allocator);
    try final_obj.put("content", ScriptValue{ .string = try allocator.dupe(u8, "") });
    try final_obj.put("done", ScriptValue{ .boolean = true });
    
    const final_args = [_]ScriptValue{ScriptValue{ .object = final_obj }};
    _ = try stream_callback.call(&final_args);
    
    return ScriptValue{ .boolean = true };
}

fn validateApiKey(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const api_key = args[1].string;
    
    // Simple validation (in real implementation, would make test API call)
    _ = provider_name;
    const is_valid = api_key.len > 10;
    
    return ScriptValue{ .boolean = is_valid };
}

fn getProviderUsage(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", provider_name).allocator;
    
    var usage = ScriptValue.Object.init(allocator);
    try usage.put("requests_today", ScriptValue{ .integer = 150 });
    try usage.put("tokens_today", ScriptValue{ .integer = 50000 });
    try usage.put("requests_this_month", ScriptValue{ .integer = 3500 });
    try usage.put("tokens_this_month", ScriptValue{ .integer = 1500000 });
    try usage.put("cost_this_month", ScriptValue{ .number = 45.67 });
    
    return ScriptValue{ .object = usage };
}

fn getProviderRateLimits(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", provider_name).allocator;
    
    var limits = ScriptValue.Object.init(allocator);
    
    if (std.mem.eql(u8, provider_name, "openai")) {
        try limits.put("requests_per_minute", ScriptValue{ .integer = 500 });
        try limits.put("tokens_per_minute", ScriptValue{ .integer = 90000 });
        try limits.put("requests_per_day", ScriptValue{ .integer = 10000 });
    } else if (std.mem.eql(u8, provider_name, "anthropic")) {
        try limits.put("requests_per_minute", ScriptValue{ .integer = 50 });
        try limits.put("tokens_per_minute", ScriptValue{ .integer = 100000 });
        try limits.put("requests_per_day", ScriptValue{ .integer = 1000 });
    }
    
    return ScriptValue{ .object = limits };
}

fn setDefaultProvider(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    _ = provider_name;
    
    // In real implementation, this would set the default provider
    return ScriptValue{ .boolean = true };
}

fn getDefaultProvider(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;
    
    const allocator = std.heap.page_allocator; // Temporary allocator
    return ScriptValue{ .string = try allocator.dupe(u8, "openai") };
}

fn testProviderConnection(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", provider_name).allocator;
    
    // Simulate connection test
    var result = ScriptValue.Object.init(allocator);
    try result.put("connected", ScriptValue{ .boolean = true });
    try result.put("latency_ms", ScriptValue{ .integer = 150 });
    try result.put("status", ScriptValue{ .string = try allocator.dupe(u8, "healthy") });
    
    return ScriptValue{ .object = result };
}

fn getProviderMetadata(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const provider_name = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", provider_name).allocator;
    
    var metadata = ScriptValue.Object.init(allocator);
    
    if (std.mem.eql(u8, provider_name, "openai")) {
        try metadata.put("name", ScriptValue{ .string = try allocator.dupe(u8, "OpenAI") });
        try metadata.put("website", ScriptValue{ .string = try allocator.dupe(u8, "https://openai.com") });
        try metadata.put("documentation", ScriptValue{ .string = try allocator.dupe(u8, "https://platform.openai.com/docs") });
        try metadata.put("pricing_url", ScriptValue{ .string = try allocator.dupe(u8, "https://openai.com/pricing") });
        
        var features = try ScriptValue.Array.init(allocator, 3);
        features.items[0] = ScriptValue{ .string = try allocator.dupe(u8, "chat_completions") };
        features.items[1] = ScriptValue{ .string = try allocator.dupe(u8, "function_calling") };
        features.items[2] = ScriptValue{ .string = try allocator.dupe(u8, "vision") };
        try metadata.put("features", ScriptValue{ .array = features });
    }
    
    return ScriptValue{ .object = metadata };
}

// Tests
test "ProviderBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const module = try ProviderBridge.getModule(allocator);
    defer allocator.destroy(module);
    
    try testing.expectEqualStrings("provider", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}