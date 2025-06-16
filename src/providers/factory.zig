// ABOUTME: Provider factory for creating LLM provider instances
// ABOUTME: Centralizes provider creation logic with configuration validation

const std = @import("std");
const Provider = @import("../provider.zig").Provider;
const OpenAIProvider = @import("openai.zig").OpenAIProvider;
const AnthropicProvider = @import("anthropic.zig").AnthropicProvider;
const OllamaProvider = @import("ollama.zig").OllamaProvider;

pub const ProviderType = enum {
    openai,
    anthropic,
    ollama,
};

pub const ProviderConfig = union(ProviderType) {
    openai: OpenAIConfig,
    anthropic: AnthropicConfig,
    ollama: OllamaConfig,

    pub const OpenAIConfig = struct {
        api_key: []const u8,
        base_url: ?[]const u8 = null,
        model: []const u8 = "gpt-4",
        organization: ?[]const u8 = null,
    };

    pub const AnthropicConfig = struct {
        api_key: []const u8,
        base_url: ?[]const u8 = null,
        model: []const u8 = "claude-3-opus-20240229",
    };

    pub const OllamaConfig = struct {
        base_url: []const u8 = "http://localhost:11434",
        model: []const u8 = "llama2",
    };
};

pub fn createProvider(allocator: std.mem.Allocator, config: ProviderConfig) !*Provider {
    return switch (config) {
        .openai => |cfg| try OpenAIProvider.create(allocator, cfg),
        .anthropic => |cfg| try AnthropicProvider.create(allocator, cfg),
        .ollama => |cfg| try OllamaProvider.create(allocator, cfg),
    };
}

pub fn createFromJSON(allocator: std.mem.Allocator, json: []const u8) !*Provider {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;
    const provider_type = obj.get("type") orelse return error.MissingProviderType;

    if (std.mem.eql(u8, provider_type.string, "openai")) {
        const config = ProviderConfig{
            .openai = .{
                .api_key = obj.get("api_key").?.string,
                .base_url = if (obj.get("base_url")) |url| url.string else null,
                .model = if (obj.get("model")) |model| model.string else "gpt-4",
                .organization = if (obj.get("organization")) |org| org.string else null,
            },
        };
        return createProvider(allocator, config);
    } else if (std.mem.eql(u8, provider_type.string, "anthropic")) {
        const config = ProviderConfig{
            .anthropic = .{
                .api_key = obj.get("api_key").?.string,
                .base_url = if (obj.get("base_url")) |url| url.string else null,
                .model = if (obj.get("model")) |model| model.string else "claude-3-opus-20240229",
            },
        };
        return createProvider(allocator, config);
    } else if (std.mem.eql(u8, provider_type.string, "ollama")) {
        const config = ProviderConfig{
            .ollama = .{
                .base_url = if (obj.get("base_url")) |url| url.string else "http://localhost:11434",
                .model = if (obj.get("model")) |model| model.string else "llama2",
            },
        };
        return createProvider(allocator, config);
    }

    return error.UnknownProviderType;
}
