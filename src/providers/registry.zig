// ABOUTME: Dynamic provider registry for runtime provider registration
// ABOUTME: Enables discovery and management of available LLM providers

const std = @import("std");
const Provider = @import("../provider.zig").Provider;
const ProviderMetadata = @import("metadata.zig").ProviderMetadata;

pub const ProviderRegistry = struct {
    providers: std.StringHashMap(*Provider),
    metadata: std.StringHashMap(ProviderMetadata),
    factories: std.StringHashMap(ProviderFactory),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub const ProviderFactory = *const fn (allocator: std.mem.Allocator, config: std.json.Value) anyerror!*Provider;

    pub fn init(allocator: std.mem.Allocator) ProviderRegistry {
        return ProviderRegistry{
            .providers = std.StringHashMap(*Provider).init(allocator),
            .metadata = std.StringHashMap(ProviderMetadata).init(allocator),
            .factories = std.StringHashMap(ProviderFactory).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up provider instances
        var iter = self.providers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.vtable.close(entry.value_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }

        self.providers.deinit();
        self.metadata.deinit();
        self.factories.deinit();
    }

    pub fn register(self: *ProviderRegistry, name: []const u8, provider: *Provider, metadata: ProviderMetadata) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.providers.put(name, provider);
        try self.metadata.put(name, metadata);
    }

    pub fn registerFactory(self: *ProviderRegistry, name: []const u8, factory: ProviderFactory, metadata: ProviderMetadata) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.factories.put(name, factory);
        try self.metadata.put(name, metadata);
    }

    pub fn getProvider(self: *ProviderRegistry, name: []const u8) ?*Provider {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.providers.get(name);
    }

    pub fn createProvider(self: *ProviderRegistry, name: []const u8, config: std.json.Value) !*Provider {
        self.mutex.lock();
        defer self.mutex.unlock();

        const factory = self.factories.get(name) orelse return error.ProviderNotFound;
        const provider = try factory(self.allocator, config);

        try self.providers.put(name, provider);
        return provider;
    }

    pub fn discover(self: *ProviderRegistry) []const ProviderMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(ProviderMetadata).init(self.allocator);
        defer result.deinit();

        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            result.append(entry.value_ptr.*) catch continue;
        }

        return result.toOwnedSlice() catch &[_]ProviderMetadata{};
    }

    pub fn getMetadata(self: *ProviderRegistry, name: []const u8) ?ProviderMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.metadata.get(name);
    }
};

test "provider registry" {
    const allocator = std.testing.allocator;

    var registry = ProviderRegistry.init(allocator);
    defer registry.deinit();

    const providers = registry.discover();
    defer allocator.free(providers);
    try std.testing.expectEqual(@as(usize, 0), providers.len);
}
