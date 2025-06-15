// ABOUTME: Hook registry for managing and discovering hooks dynamically
// ABOUTME: Provides centralized hook registration, lookup, and lifecycle management

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookFactory = types.HookFactory;
const HookConfig = types.HookConfig;
const HookMetadata = types.HookMetadata;
const HookPoint = types.HookPoint;
const HookCategory = types.HookCategory;
const HookChain = types.HookChain;

// Hook registry for managing all hooks
pub const HookRegistry = struct {
    // Registered hook factories
    factories: std.StringHashMap(HookFactory),
    
    // Hook metadata
    metadata: std.StringHashMap(HookMetadata),
    
    // Active hook instances
    hooks: std.StringHashMap(*Hook),
    
    // Hook chains by point
    chains: std.AutoHashMap(HookPoint, *HookChain),
    
    // Global hook chain (applies to all points)
    global_chain: *HookChain,
    
    // Mutex for thread safety
    mutex: std.Thread.Mutex = .{},
    
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !HookRegistry {
        var registry = HookRegistry{
            .factories = std.StringHashMap(HookFactory).init(allocator),
            .metadata = std.StringHashMap(HookMetadata).init(allocator),
            .hooks = std.StringHashMap(*Hook).init(allocator),
            .chains = std.AutoHashMap(HookPoint, *HookChain).init(allocator),
            .global_chain = try allocator.create(HookChain),
            .allocator = allocator,
        };
        
        registry.global_chain.* = HookChain.init(allocator);
        
        // Initialize chains for each hook point
        inline for (@typeInfo(HookPoint).Enum.fields) |field| {
            const point = @field(HookPoint, field.name);
            const chain = try allocator.create(HookChain);
            chain.* = HookChain.init(allocator);
            try registry.chains.put(point, chain);
        }
        
        return registry;
    }
    
    pub fn deinit(self: *HookRegistry) void {
        // Clean up hooks
        var hook_iter = self.hooks.iterator();
        while (hook_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.hooks.deinit();
        
        // Clean up chains
        var chain_iter = self.chains.iterator();
        while (chain_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.chains.deinit();
        
        self.global_chain.deinit();
        self.allocator.destroy(self.global_chain);
        
        self.factories.deinit();
        self.metadata.deinit();
    }
    
    // Register a hook factory
    pub fn registerFactory(
        self: *HookRegistry,
        id: []const u8,
        factory: HookFactory,
        metadata: HookMetadata,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.factories.put(id, factory);
        try self.metadata.put(id, metadata);
    }
    
    // Create and register a hook instance
    pub fn createHook(self: *HookRegistry, config: HookConfig) !*Hook {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Find factory
        const factory = self.factories.get(config.hook_type) orelse return error.HookTypeNotFound;
        
        // Create hook
        const hook = try factory(self.allocator, config);
        
        // Initialize hook
        try hook.init(self.allocator);
        
        // Validate hook
        try hook.validate();
        
        // Store hook
        try self.hooks.put(hook.id, hook);
        
        // Add to appropriate chains
        if (config.hook_points.len > 0) {
            for (config.hook_points) |point| {
                if (self.chains.get(point)) |chain| {
                    try chain.addHook(hook);
                }
            }
        } else {
            // Add to global chain if no specific points
            try self.global_chain.addHook(hook);
        }
        
        return hook;
    }
    
    // Remove a hook
    pub fn removeHook(self: *HookRegistry, hook_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.hooks.fetchRemove(hook_id)) |entry| {
            const hook = entry.value;
            
            // Remove from chains
            var chain_iter = self.chains.iterator();
            while (chain_iter.next()) |chain_entry| {
                _ = chain_entry.value_ptr.*.removeHook(hook_id);
            }
            _ = self.global_chain.removeHook(hook_id);
            
            // Cleanup hook
            hook.deinit();
            self.allocator.destroy(hook);
        } else {
            return error.HookNotFound;
        }
    }
    
    // Get hook by ID
    pub fn getHook(self: *HookRegistry, hook_id: []const u8) ?*Hook {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.hooks.get(hook_id);
    }
    
    // Get all hooks for a specific point
    pub fn getHooksForPoint(self: *HookRegistry, point: HookPoint) !HookExecutor {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const point_chain = self.chains.get(point) orelse return error.HookPointNotFound;
        
        return HookExecutor{
            .point_chain = point_chain,
            .global_chain = self.global_chain,
            .allocator = self.allocator,
        };
    }
    
    // List all registered hook types
    pub fn listHookTypes(self: *HookRegistry, allocator: std.mem.Allocator) ![]HookMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var list = std.ArrayList(HookMetadata).init(allocator);
        errdefer list.deinit();
        
        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            try list.append(entry.value_ptr.*);
        }
        
        return try list.toOwnedSlice();
    }
    
    // Find hooks by category
    pub fn findByCategory(
        self: *HookRegistry,
        category: HookCategory,
        allocator: std.mem.Allocator,
    ) ![]HookMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var list = std.ArrayList(HookMetadata).init(allocator);
        errdefer list.deinit();
        
        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.category == category) {
                try list.append(entry.value_ptr.*);
            }
        }
        
        return try list.toOwnedSlice();
    }
    
    // Enable/disable hook
    pub fn setHookEnabled(self: *HookRegistry, hook_id: []const u8, enabled: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.hooks.get(hook_id)) |hook| {
            hook.enabled = enabled;
        } else {
            return error.HookNotFound;
        }
    }
    
    // Update hook configuration
    pub fn updateHookConfig(self: *HookRegistry, hook_id: []const u8, config: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.hooks.get(hook_id)) |hook| {
            hook.config = config;
            try hook.validate();
        } else {
            return error.HookNotFound;
        }
    }
    
    // Get hook statistics
    pub fn getStatistics(self: *HookRegistry, allocator: std.mem.Allocator) !HookStatistics {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var stats = HookStatistics{
            .total_factories = self.factories.count(),
            .total_hooks = self.hooks.count(),
            .hooks_by_point = std.AutoHashMap(HookPoint, usize).init(allocator),
            .hooks_by_category = std.AutoHashMap(HookCategory, usize).init(allocator),
        };
        
        // Count hooks by point
        var chain_iter = self.chains.iterator();
        while (chain_iter.next()) |entry| {
            try stats.hooks_by_point.put(entry.key_ptr.*, entry.value_ptr.*.hooks.items.len);
        }
        
        // Count hooks by category
        var hook_iter = self.hooks.iterator();
        while (hook_iter.next()) |entry| {
            const hook_type = entry.value_ptr.*.vtable.execute; // Use function pointer as type identifier
            _ = hook_type;
            // TODO: Track category in hook instance
        }
        
        return stats;
    }
};

// Hook executor for running hooks at a specific point
pub const HookExecutor = struct {
    point_chain: *HookChain,
    global_chain: *HookChain,
    allocator: std.mem.Allocator,
    
    pub fn execute(self: *HookExecutor, context: *types.HookContext) !types.HookResult {
        // Execute global hooks first
        var result = try self.global_chain.execute(context);
        if (!result.shouldContinue()) {
            return result;
        }
        
        // Then execute point-specific hooks
        const point_result = try self.point_chain.execute(context);
        
        // Merge results
        if (point_result.modified_data) |data| {
            result.modified_data = data;
        }
        if (point_result.metrics) |metrics| {
            result.metrics = metrics;
        }
        if (point_result.error_info) |error_info| {
            result.error_info = error_info;
            result.continue_processing = point_result.continue_processing;
        }
        
        return result;
    }
};

// Hook statistics
pub const HookStatistics = struct {
    total_factories: usize,
    total_hooks: usize,
    hooks_by_point: std.AutoHashMap(HookPoint, usize),
    hooks_by_category: std.AutoHashMap(HookCategory, usize),
    
    pub fn deinit(self: *HookStatistics) void {
        self.hooks_by_point.deinit();
        self.hooks_by_category.deinit();
    }
};

// Global registry instance
var global_registry: ?*HookRegistry = null;
var global_mutex: std.Thread.Mutex = .{};

// Get or create global registry
pub fn getGlobalRegistry(allocator: std.mem.Allocator) !*HookRegistry {
    global_mutex.lock();
    defer global_mutex.unlock();
    
    if (global_registry) |registry| {
        return registry;
    }
    
    global_registry = try allocator.create(HookRegistry);
    global_registry.?.* = try HookRegistry.init(allocator);
    return global_registry.?;
}

// Cleanup global registry
pub fn deinitGlobalRegistry() void {
    global_mutex.lock();
    defer global_mutex.unlock();
    
    if (global_registry) |registry| {
        registry.deinit();
        // Note: We don't destroy the registry here as we don't know which allocator was used
        global_registry = null;
    }
}

// Built-in hook factories
pub const builtin_factories = struct {
    // No-op hook factory for testing
    pub fn createNoOpHook(allocator: std.mem.Allocator, config: HookConfig) !*Hook {
        const hook = try allocator.create(Hook);
        hook.* = .{
            .id = config.id,
            .name = "No-Op Hook",
            .description = "A hook that does nothing",
            .vtable = &.{
                .execute = noOpExecute,
            },
            .priority = config.priority,
            .supported_points = config.hook_points,
            .enabled = config.enabled,
            .config = config.config,
        };
        return hook;
    }
    
    fn noOpExecute(hook: *Hook, context: *types.HookContext) !types.HookResult {
        _ = hook;
        _ = context;
        return types.HookResult{ .continue_processing = true };
    }
    
    // Debug hook factory
    pub fn createDebugHook(allocator: std.mem.Allocator, config: HookConfig) !*Hook {
        const hook = try allocator.create(Hook);
        hook.* = .{
            .id = config.id,
            .name = "Debug Hook",
            .description = "Logs hook execution details",
            .vtable = &.{
                .execute = debugExecute,
            },
            .priority = config.priority,
            .supported_points = config.hook_points,
            .enabled = config.enabled,
            .config = config.config,
        };
        return hook;
    }
    
    fn debugExecute(hook: *Hook, context: *types.HookContext) !types.HookResult {
        std.log.debug("Hook '{s}' executed at point '{s}'", .{ hook.id, context.point.toString() });
        std.log.debug("  Hook {d}/{d} in chain", .{ context.hook_index + 1, context.total_hooks });
        std.log.debug("  Elapsed: {d}ms", .{context.getElapsedMs()});
        
        return types.HookResult{ .continue_processing = true };
    }
};

// Tests
test "hook registry" {
    const allocator = std.testing.allocator;
    
    var registry = try HookRegistry.init(allocator);
    defer registry.deinit();
    
    // Register factory
    try registry.registerFactory(
        "noop",
        builtin_factories.createNoOpHook,
        .{
            .id = "noop",
            .name = "No-Op Hook",
            .description = "A hook that does nothing",
            .category = .custom,
            .version = "1.0.0",
            .supported_points = &[_]HookPoint{.agent_before_run},
        },
    );
    
    // Create hook
    const hook = try registry.createHook(.{
        .id = "test_noop",
        .hook_type = "noop",
        .hook_points = &[_]HookPoint{.agent_before_run},
    });
    
    try std.testing.expectEqualStrings("test_noop", hook.id);
    
    // Get hook
    const retrieved = registry.getHook("test_noop");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(hook, retrieved.?);
    
    // Remove hook
    try registry.removeHook("test_noop");
    try std.testing.expect(registry.getHook("test_noop") == null);
}

test "hook executor" {
    const allocator = std.testing.allocator;
    
    var registry = try HookRegistry.init(allocator);
    defer registry.deinit();
    
    // Register debug factory
    try registry.registerFactory(
        "debug",
        builtin_factories.createDebugHook,
        .{
            .id = "debug",
            .name = "Debug Hook",
            .description = "Logs hook execution",
            .category = .logging,
            .version = "1.0.0",
            .supported_points = &[_]HookPoint{.agent_before_run},
        },
    );
    
    // Create hooks
    _ = try registry.createHook(.{
        .id = "debug1",
        .hook_type = "debug",
        .priority = .high,
        .hook_points = &[_]HookPoint{.agent_before_run},
    });
    
    _ = try registry.createHook(.{
        .id = "debug2",
        .hook_type = "debug",
        .priority = .low,
        .hook_points = &[_]HookPoint{.agent_before_run},
    });
    
    // Get executor
    var executor = try registry.getHooksForPoint(.agent_before_run);
    
    // Create context
    var run_context = try @import("../context.zig").RunContext.init(allocator, .{});
    defer run_context.deinit();
    
    var context = types.HookContext.init(allocator, .agent_before_run, &run_context);
    defer context.deinit();
    
    // Execute hooks
    const result = try executor.execute(&context);
    try std.testing.expect(result.continue_processing);
}