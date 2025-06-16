// ABOUTME: Light userdata optimization system for simple pointers and primitive types
// ABOUTME: Provides fast userdata operations without full header overhead for basic types

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const UserdataSystem = @import("lua_userdata_system.zig");

/// Light userdata optimization strategy
pub const LightUserdataStrategy = enum {
    /// Never use light userdata - always use full userdata
    never,
    /// Use light userdata for known safe types
    safe_types_only,
    /// Use light userdata for all pointer types (risky)
    aggressive,
    /// Use heuristics to determine best approach
    heuristic,
};

/// Configuration for light userdata optimization
pub const LightUserdataConfig = struct {
    strategy: LightUserdataStrategy = .safe_types_only,
    max_light_userdata_size: usize = 64, // Max bytes for light userdata consideration
    enable_type_tagging: bool = true, // Add minimal type info to light userdata
    use_pointer_validation: bool = true, // Validate pointers before use
};

/// Types that are safe for light userdata optimization
pub const SafeLightUserdataTypes = std.ComptimeStringMap(bool, .{
    .{ "i8", true },
    .{ "i16", true },
    .{ "i32", true },
    .{ "i64", true },
    .{ "u8", true },
    .{ "u16", true },
    .{ "u32", true },
    .{ "u64", true },
    .{ "f32", true },
    .{ "f64", true },
    .{ "bool", true },
    .{ "usize", true },
    .{ "isize", true },
    .{ "*anyopaque", true },
    .{ "?*anyopaque", true },
});

/// Light userdata manager for optimized operations
pub const LightUserdataManager = struct {
    wrapper: *LuaWrapper,
    config: LightUserdataConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, wrapper: *LuaWrapper, config: LightUserdataConfig) LightUserdataManager {
        return LightUserdataManager{
            .wrapper = wrapper,
            .config = config,
            .allocator = allocator,
        };
    }

    /// Determine if a type should use light userdata
    pub fn shouldUseLightUserdata(self: *LightUserdataManager, comptime T: type, type_name: []const u8) bool {
        switch (self.config.strategy) {
            .never => return false,
            .safe_types_only => {
                return SafeLightUserdataTypes.has(type_name) and @sizeOf(T) <= self.config.max_light_userdata_size;
            },
            .aggressive => {
                return @sizeOf(T) <= self.config.max_light_userdata_size;
            },
            .heuristic => {
                // Use heuristics: simple types, small size, no destructors needed
                const is_simple = switch (@typeInfo(T)) {
                    .Int, .Float, .Bool => true,
                    .Pointer => |ptr_info| ptr_info.size == .One and ptr_info.child == anyopaque,
                    .Optional => |opt_info| @typeInfo(opt_info.child) == .Pointer,
                    else => false,
                };
                return is_simple and @sizeOf(T) <= self.config.max_light_userdata_size;
            },
        }
    }

    /// Push a value as light userdata if appropriate, otherwise use full userdata
    pub fn pushOptimizedUserdata(
        self: *LightUserdataManager,
        comptime T: type,
        value: T,
        type_name: []const u8,
        userdata_manager: ?*UserdataSystem.LuaUserdataManager,
    ) !void {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        if (self.shouldUseLightUserdata(T, type_name)) {
            try self.pushLightUserdata(T, value, type_name);
        } else {
            // Fall back to full userdata system
            if (userdata_manager) |manager| {
                _ = try manager.createUserdata(T, value, type_name);
            } else {
                // Basic light userdata as fallback
                try self.pushLightUserdata(T, value, type_name);
            }
        }
    }

    /// Push a value as light userdata with optional type tagging
    pub fn pushLightUserdata(self: *LightUserdataManager, comptime T: type, value: T, type_name: []const u8) !void {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        if (@sizeOf(T) == 0) {
            // Zero-sized types - just push nil
            lua.c.lua_pushnil(self.wrapper.state);
            return;
        }

        if (@sizeOf(T) <= @sizeOf(*anyopaque)) {
            // Value fits in a pointer - pack it directly
            try self.pushPackedLightUserdata(T, value, type_name);
        } else {
            // Value too large - allocate and use pointer
            try self.pushAllocatedLightUserdata(T, value, type_name);
        }
    }

    /// Pack a small value directly into a light userdata pointer
    fn pushPackedLightUserdata(self: *LightUserdataManager, comptime T: type, value: T, type_name: []const u8) !void {
        _ = type_name; // TODO: Add type tagging if enabled

        // Pack the value into pointer-sized storage
        var packed_value: [@sizeOf(*anyopaque)]u8 = std.mem.zeroes([@sizeOf(*anyopaque)]u8);

        if (@sizeOf(T) <= @sizeOf(*anyopaque)) {
            @memcpy(packed_value[0..@sizeOf(T)], std.mem.asBytes(&value));

            // Convert to pointer for light userdata
            const ptr_value = @as(*anyopaque, @ptrFromInt(@as(usize, @bitCast(packed_value))));
            lua.c.lua_pushlightuserdata(self.wrapper.state, ptr_value);
        } else {
            return error.ValueTooLarge;
        }
    }

    /// Allocate memory for a value and push as light userdata
    fn pushAllocatedLightUserdata(self: *LightUserdataManager, comptime T: type, value: T, type_name: []const u8) !void {
        _ = type_name; // TODO: Add type tagging if enabled

        // Allocate memory for the value
        const allocated_ptr = try self.allocator.create(T);
        allocated_ptr.* = value;

        // Push as light userdata
        lua.c.lua_pushlightuserdata(self.wrapper.state, allocated_ptr);

        // TODO: Track allocation for cleanup - this is a memory leak currently
        // In a real implementation, we'd need a way to track and clean up these allocations
    }

    /// Get a value from light userdata with type checking
    pub fn getLightUserdata(self: *LightUserdataManager, comptime T: type, index: c_int, type_name: []const u8) !?T {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        // Check if it's light userdata
        if (lua.c.lua_type(self.wrapper.state, index) != lua.c.LUA_TLIGHTUSERDATA) {
            return null;
        }

        const ptr = lua.c.lua_touserdata(self.wrapper.state, index);
        if (ptr == null) return null;

        if (self.shouldUseLightUserdata(T, type_name)) {
            if (@sizeOf(T) <= @sizeOf(*anyopaque)) {
                return try self.unpackLightUserdata(T, ptr.?);
            } else {
                return try self.unpackAllocatedLightUserdata(T, ptr.?);
            }
        }

        return null;
    }

    /// Unpack a small value from light userdata pointer
    fn unpackLightUserdata(self: *LightUserdataManager, comptime T: type, ptr: *anyopaque) !T {
        _ = self;

        if (@sizeOf(T) > @sizeOf(*anyopaque)) {
            return error.ValueTooLarge;
        }

        // Convert pointer back to packed bytes
        const ptr_value = @intFromPtr(ptr);
        const packed_bytes: [@sizeOf(*anyopaque)]u8 = @bitCast(@as(usize, ptr_value));

        // Extract the value
        const value_bytes = packed_bytes[0..@sizeOf(T)];
        return @as(*const T, @ptrCast(@alignCast(value_bytes.ptr))).*;
    }

    /// Unpack a value from allocated light userdata
    fn unpackAllocatedLightUserdata(self: *LightUserdataManager, comptime T: type, ptr: *anyopaque) !T {
        _ = self;

        // Cast to the correct type and dereference
        const typed_ptr: *T = @ptrCast(@alignCast(ptr));
        return typed_ptr.*;
    }

    /// Convert light userdata to ScriptValue
    pub fn lightUserdataToScriptValue(
        self: *LightUserdataManager,
        index: c_int,
        allocator: std.mem.Allocator,
        expected_type: ?[]const u8,
    ) !ScriptValue {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        if (lua.c.lua_type(self.wrapper.state, index) != lua.c.LUA_TLIGHTUSERDATA) {
            return ScriptValue.nil;
        }

        const ptr = lua.c.lua_touserdata(self.wrapper.state, index);
        if (ptr == null) return ScriptValue.nil;

        // If we have type information, try to convert appropriately
        if (expected_type) |type_name| {
            // Try common types
            if (std.mem.eql(u8, type_name, "i64")) {
                if (try self.getLightUserdata(i64, index, type_name)) |value| {
                    return ScriptValue{ .integer = value };
                }
            } else if (std.mem.eql(u8, type_name, "f64")) {
                if (try self.getLightUserdata(f64, index, type_name)) |value| {
                    return ScriptValue{ .number = value };
                }
            } else if (std.mem.eql(u8, type_name, "bool")) {
                if (try self.getLightUserdata(bool, index, type_name)) |value| {
                    return ScriptValue{ .boolean = value };
                }
            }
        }

        // Fall back to generic userdata
        const type_id = if (expected_type) |t| try allocator.dupe(u8, t) else "light_userdata";
        return ScriptValue{ .userdata = ScriptValue.UserData{
            .ptr = ptr.?,
            .type_id = type_id,
            .deinit_fn = if (expected_type != null) struct {
                fn deinit(id: []const u8, alloc: std.mem.Allocator) void {
                    alloc.free(id);
                }
            }.deinit else null,
        } };
    }

    /// Get performance metrics for light userdata usage
    pub fn getOptimizationMetrics(self: *LightUserdataManager) OptimizationMetrics {
        _ = self;
        // TODO: Implement metrics collection
        return OptimizationMetrics{
            .light_userdata_count = 0,
            .full_userdata_count = 0,
            .memory_saved_bytes = 0,
            .performance_improvement_percent = 0,
        };
    }
};

/// Metrics for light userdata optimization
pub const OptimizationMetrics = struct {
    light_userdata_count: usize,
    full_userdata_count: usize,
    memory_saved_bytes: usize,
    performance_improvement_percent: f64,

    pub fn getTotalUserdata(self: OptimizationMetrics) usize {
        return self.light_userdata_count + self.full_userdata_count;
    }

    pub fn getLightUserdataRatio(self: OptimizationMetrics) f64 {
        const total = self.getTotalUserdata();
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.light_userdata_count)) / @as(f64, @floatFromInt(total));
    }
};

/// Utility functions for determining optimization eligibility
pub const OptimizationUtils = struct {
    /// Check if a type is suitable for light userdata based on characteristics
    pub fn isLightUserdataSuitable(comptime T: type) bool {
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .Int, .Float, .Bool => @sizeOf(T) <= @sizeOf(*anyopaque),
            .Pointer => |ptr_info| {
                // Only simple pointers to opaque types
                return ptr_info.size == .One and ptr_info.child == anyopaque;
            },
            .Optional => |opt_info| {
                return @typeInfo(opt_info.child) == .Pointer and @sizeOf(T) <= @sizeOf(*anyopaque);
            },
            .Enum => |enum_info| {
                return @sizeOf(enum_info.tag_type) <= @sizeOf(*anyopaque);
            },
            else => false,
        };
    }

    /// Estimate memory savings from using light userdata
    pub fn estimateMemorySavings(comptime T: type) usize {
        if (!isLightUserdataSuitable(T)) return 0;

        const full_userdata_size = @sizeOf(UserdataSystem.UserdataHeader) + @sizeOf(T);
        const light_userdata_size = @sizeOf(*anyopaque);

        return if (full_userdata_size > light_userdata_size)
            full_userdata_size - light_userdata_size
        else
            0;
    }

    /// Get type category for optimization decisions
    pub fn getTypeCategory(comptime T: type) TypeCategory {
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .Int => if (@sizeOf(T) <= 4) .small_integer else .large_integer,
            .Float => if (@sizeOf(T) <= 4) .small_float else .large_float,
            .Bool => .boolean,
            .Pointer => .pointer,
            .Optional => .optional,
            .Enum => .enumeration,
            .Struct => if (@sizeOf(T) <= 8) .small_struct else .large_struct,
            .Array => .array,
            else => .other,
        };
    }
};

/// Type categories for optimization
pub const TypeCategory = enum {
    small_integer,
    large_integer,
    small_float,
    large_float,
    boolean,
    pointer,
    optional,
    enumeration,
    small_struct,
    large_struct,
    array,
    other,

    pub fn isLightUserdataCandidate(self: TypeCategory) bool {
        return switch (self) {
            .small_integer, .small_float, .boolean, .pointer, .enumeration => true,
            .optional, .small_struct => true,
            else => false,
        };
    }
};

// Tests
test "Light userdata suitability detection" {
    try std.testing.expect(OptimizationUtils.isLightUserdataSuitable(i32));
    try std.testing.expect(OptimizationUtils.isLightUserdataSuitable(f32));
    try std.testing.expect(OptimizationUtils.isLightUserdataSuitable(bool));
    try std.testing.expect(OptimizationUtils.isLightUserdataSuitable(*anyopaque));

    // Large structs should not be suitable
    const LargeStruct = struct { data: [1024]u8 };
    try std.testing.expect(!OptimizationUtils.isLightUserdataSuitable(LargeStruct));
}

test "Memory savings estimation" {
    const i32_savings = OptimizationUtils.estimateMemorySavings(i32);
    try std.testing.expect(i32_savings > 0);

    const bool_savings = OptimizationUtils.estimateMemorySavings(bool);
    try std.testing.expect(bool_savings > 0);

    const LargeStruct = struct { data: [1024]u8 };
    const large_savings = OptimizationUtils.estimateMemorySavings(LargeStruct);
    try std.testing.expectEqual(@as(usize, 0), large_savings);
}

test "Type categorization" {
    try std.testing.expectEqual(TypeCategory.small_integer, OptimizationUtils.getTypeCategory(i32));
    try std.testing.expectEqual(TypeCategory.large_integer, OptimizationUtils.getTypeCategory(i64));
    try std.testing.expectEqual(TypeCategory.small_float, OptimizationUtils.getTypeCategory(f32));
    try std.testing.expectEqual(TypeCategory.boolean, OptimizationUtils.getTypeCategory(bool));
    try std.testing.expectEqual(TypeCategory.pointer, OptimizationUtils.getTypeCategory(*anyopaque));
}

test "Light userdata manager basic operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    const config = LightUserdataConfig{
        .strategy = .safe_types_only,
        .max_light_userdata_size = 64,
    };

    var manager = LightUserdataManager.init(allocator, wrapper, config);

    // Test suitability decisions
    try std.testing.expect(manager.shouldUseLightUserdata(i32, "i32"));
    try std.testing.expect(manager.shouldUseLightUserdata(bool, "bool"));
    try std.testing.expect(!manager.shouldUseLightUserdata([1024]u8, "large_array"));
}

test "Light userdata packed value operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    const config = LightUserdataConfig{ .strategy = .safe_types_only };
    var manager = LightUserdataManager.init(allocator, wrapper, config);

    // Test i32 packing
    try manager.pushLightUserdata(i32, 42, "i32");
    const retrieved_i32 = try manager.getLightUserdata(i32, -1, "i32");

    if (retrieved_i32) |value| {
        try std.testing.expectEqual(@as(i32, 42), value);
    } else {
        try std.testing.expect(false); // Should have retrieved value
    }

    lua.c.lua_pop(wrapper.state, 1);

    // Test bool packing
    try manager.pushLightUserdata(bool, true, "bool");
    const retrieved_bool = try manager.getLightUserdata(bool, -1, "bool");

    if (retrieved_bool) |value| {
        try std.testing.expect(value);
    } else {
        try std.testing.expect(false); // Should have retrieved value
    }

    lua.c.lua_pop(wrapper.state, 1);
}
