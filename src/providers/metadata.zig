// ABOUTME: Provider metadata types for discovery and capability checking
// ABOUTME: Defines capabilities, models, and constraints for LLM providers

const std = @import("std");
const Schema = @import("../schema/validator.zig").Schema;

pub const Capability = enum {
    streaming,
    function_calling,
    vision,
    embeddings,
    fine_tuning,
    logprobs,
};

pub const ModelInfo = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    max_tokens: u32,
    supports_functions: bool,
    supports_vision: bool,
    supports_streaming: bool,
    context_window: u32,
    input_cost_per_1k: ?f64 = null,
    output_cost_per_1k: ?f64 = null,
};

pub const Constraints = struct {
    max_requests_per_minute: ?u32 = null,
    max_tokens_per_minute: ?u32 = null,
    max_concurrent_requests: ?u32 = null,
    requires_api_key: bool = true,
};

pub const ProviderMetadata = struct {
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    version: []const u8,
    capabilities: []const Capability,
    models: []const ModelInfo,
    constraints: Constraints,
    config_schema: ?*const Schema = null,
    
    pub fn hasCapability(self: *const ProviderMetadata, capability: Capability) bool {
        for (self.capabilities) |cap| {
            if (cap == capability) return true;
        }
        return false;
    }
    
    pub fn getModel(self: *const ProviderMetadata, model_id: []const u8) ?ModelInfo {
        for (self.models) |model| {
            if (std.mem.eql(u8, model.id, model_id)) {
                return model;
            }
        }
        return null;
    }
    
    pub fn supportsStreaming(self: *const ProviderMetadata) bool {
        return self.hasCapability(.streaming);
    }
    
    pub fn supportsFunctions(self: *const ProviderMetadata) bool {
        return self.hasCapability(.function_calling);
    }
    
    pub fn supportsVision(self: *const ProviderMetadata) bool {
        return self.hasCapability(.vision);
    }
};

// Pre-defined metadata for common providers
pub const OPENAI_METADATA = ProviderMetadata{
    .name = "openai",
    .display_name = "OpenAI",
    .description = "OpenAI's GPT models including GPT-4 and GPT-3.5",
    .version = "1.0.0",
    .capabilities = &[_]Capability{
        .streaming,
        .function_calling,
        .vision,
        .embeddings,
    },
    .models = &[_]ModelInfo{
        .{
            .id = "gpt-4",
            .name = "GPT-4",
            .description = "Most capable GPT-4 model",
            .max_tokens = 8192,
            .supports_functions = true,
            .supports_vision = false,
            .supports_streaming = true,
            .context_window = 8192,
            .input_cost_per_1k = 0.03,
            .output_cost_per_1k = 0.06,
        },
        .{
            .id = "gpt-4-vision-preview",
            .name = "GPT-4 Vision",
            .description = "GPT-4 with vision capabilities",
            .max_tokens = 4096,
            .supports_functions = true,
            .supports_vision = true,
            .supports_streaming = true,
            .context_window = 128000,
            .input_cost_per_1k = 0.01,
            .output_cost_per_1k = 0.03,
        },
        .{
            .id = "gpt-3.5-turbo",
            .name = "GPT-3.5 Turbo",
            .description = "Fast and efficient model",
            .max_tokens = 4096,
            .supports_functions = true,
            .supports_vision = false,
            .supports_streaming = true,
            .context_window = 16385,
            .input_cost_per_1k = 0.0005,
            .output_cost_per_1k = 0.0015,
        },
    },
    .constraints = .{
        .max_requests_per_minute = 10000,
        .max_tokens_per_minute = 150000,
        .requires_api_key = true,
    },
};

pub const ANTHROPIC_METADATA = ProviderMetadata{
    .name = "anthropic",
    .display_name = "Anthropic",
    .description = "Anthropic's Claude models",
    .version = "1.0.0",
    .capabilities = &[_]Capability{
        .streaming,
        .vision,
    },
    .models = &[_]ModelInfo{
        .{
            .id = "claude-3-opus-20240229",
            .name = "Claude 3 Opus",
            .description = "Most capable Claude model",
            .max_tokens = 4096,
            .supports_functions = false,
            .supports_vision = true,
            .supports_streaming = true,
            .context_window = 200000,
            .input_cost_per_1k = 0.015,
            .output_cost_per_1k = 0.075,
        },
        .{
            .id = "claude-3-sonnet-20240229",
            .name = "Claude 3 Sonnet",
            .description = "Balanced performance and cost",
            .max_tokens = 4096,
            .supports_functions = false,
            .supports_vision = true,
            .supports_streaming = true,
            .context_window = 200000,
            .input_cost_per_1k = 0.003,
            .output_cost_per_1k = 0.015,
        },
    },
    .constraints = .{
        .max_requests_per_minute = 1000,
        .requires_api_key = true,
    },
};

pub const OLLAMA_METADATA = ProviderMetadata{
    .name = "ollama",
    .display_name = "Ollama",
    .description = "Local LLM inference with Ollama",
    .version = "1.0.0",
    .capabilities = &[_]Capability{
        .streaming,
    },
    .models = &[_]ModelInfo{
        .{
            .id = "llama2",
            .name = "Llama 2",
            .description = "Meta's Llama 2 model",
            .max_tokens = 4096,
            .supports_functions = false,
            .supports_vision = false,
            .supports_streaming = true,
            .context_window = 4096,
        },
        .{
            .id = "mistral",
            .name = "Mistral",
            .description = "Mistral AI's model",
            .max_tokens = 8192,
            .supports_functions = false,
            .supports_vision = false,
            .supports_streaming = true,
            .context_window = 8192,
        },
    },
    .constraints = .{
        .requires_api_key = false,
    },
};