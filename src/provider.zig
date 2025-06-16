// ABOUTME: Provider interface defining the contract for all LLM providers
// ABOUTME: Uses vtable pattern for runtime polymorphism and extensibility

const std = @import("std");
const types = @import("types.zig");

pub const Provider = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        generate: *const fn (self: *Provider, messages: []const types.Message, options: types.GenerateOptions) anyerror!types.Response,
        generateStream: *const fn (self: *Provider, messages: []const types.Message, options: types.GenerateOptions) anyerror!types.StreamResponse,
        getMetadata: *const fn (self: *Provider) ProviderMetadata,
        close: *const fn (self: *Provider) void,
    };

    pub fn generate(self: *Provider, messages: []const types.Message, options: types.GenerateOptions) !types.Response {
        return self.vtable.generate(self, messages, options);
    }

    pub fn generateStream(self: *Provider, messages: []const types.Message, options: types.GenerateOptions) !types.StreamResponse {
        return self.vtable.generateStream(self, messages, options);
    }

    pub fn getMetadata(self: *Provider) ProviderMetadata {
        return self.vtable.getMetadata(self);
    }

    pub fn close(self: *Provider) void {
        self.vtable.close(self);
    }
};

// Re-export metadata types for convenience
pub const ProviderMetadata = @import("providers/metadata.zig").ProviderMetadata;
pub const Capability = @import("providers/metadata.zig").Capability;
pub const ModelInfo = @import("providers/metadata.zig").ModelInfo;
