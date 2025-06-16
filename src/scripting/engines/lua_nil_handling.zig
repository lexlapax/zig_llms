// ABOUTME: Comprehensive nil/null handling for Lua integration
// ABOUTME: Ensures consistent nil semantics between Lua, Zig, and ScriptValue

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;

/// Nil handling utilities for Lua integration
pub const NilHandler = struct {
    /// Check if a Lua value is nil
    pub fn isNil(wrapper: *LuaWrapper, index: c_int) bool {
        if (!lua.lua_enabled) return false;
        return lua.c.lua_type(wrapper.state, index) == lua.c.LUA_TNIL;
    }

    /// Push nil to Lua stack
    pub fn pushNil(wrapper: *LuaWrapper) void {
        if (!lua.lua_enabled) return;
        lua.c.lua_pushnil(wrapper.state);
    }

    /// Create a nil ScriptValue
    pub fn createNilScriptValue() ScriptValue {
        return ScriptValue.nil;
    }

    /// Check if a ScriptValue is nil
    pub fn isScriptValueNil(value: ScriptValue) bool {
        return value == .nil;
    }

    /// Convert various "empty" values to appropriate nil representation
    pub fn normalizeToNil(value: anytype) ?ScriptValue {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .Optional => {
                if (value == null) {
                    return ScriptValue.nil;
                }
                return null; // Not nil, let caller handle the actual value
            },
            .Pointer => |ptr_info| {
                if (ptr_info.size == .One) {
                    // Single pointer - check if null
                    if (@intFromPtr(value) == 0) {
                        return ScriptValue.nil;
                    }
                } else if (ptr_info.size == .Slice) {
                    // Slice - check if empty or null pointer
                    if (value.len == 0) {
                        return ScriptValue.nil;
                    }
                }
                return null;
            },
            .Array => |arr_info| {
                if (arr_info.len == 0) {
                    return ScriptValue.nil;
                }
                return null;
            },
            else => return null,
        }
    }

    /// Handle conversion of null/nil values from different sources
    pub fn convertNilValue(source: NilSource) ScriptValue {
        return switch (source) {
            .lua_nil => ScriptValue.nil,
            .zig_null => ScriptValue.nil,
            .empty_string => ScriptValue.nil,
            .zero_pointer => ScriptValue.nil,
            .undefined_value => ScriptValue.nil,
        };
    }

    /// Determine if a value should be treated as nil/null in specific contexts
    pub fn shouldTreatAsNil(value: ScriptValue, context: NilContext) bool {
        switch (context) {
            .strict => {
                // Only actual nil values
                return value == .nil;
            },
            .lenient => {
                // Nil, empty strings, empty arrays, empty objects
                return switch (value) {
                    .nil => true,
                    .string => |s| s.len == 0,
                    .array => |arr| arr.items.len == 0,
                    .object => |obj| obj.map.count() == 0,
                    else => false,
                };
            },
            .javascript_like => {
                // Nil, empty strings, zero numbers, false booleans
                return switch (value) {
                    .nil => true,
                    .boolean => |b| !b,
                    .integer => |i| i == 0,
                    .number => |n| n == 0.0,
                    .string => |s| s.len == 0,
                    .array => |arr| arr.items.len == 0,
                    .object => |obj| obj.map.count() == 0,
                    else => false,
                };
            },
        }
    }

    /// Convert Lua nil to ScriptValue with proper handling
    pub fn luaNilToScriptValue(wrapper: *LuaWrapper, index: c_int) !ScriptValue {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        if (lua.c.lua_type(wrapper.state, index) != lua.c.LUA_TNIL) {
            return error.NotNil;
        }

        return ScriptValue.nil;
    }

    /// Push ScriptValue nil to Lua stack
    pub fn scriptValueNilToLua(wrapper: *LuaWrapper, value: ScriptValue) !void {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        if (value != .nil) {
            return error.NotNil;
        }

        lua.c.lua_pushnil(wrapper.state);
    }

    /// Handle optional values correctly
    pub fn handleOptional(comptime T: type, optional_value: ?T) ScriptValue {
        if (optional_value) |value| {
            // Convert the actual value
            return switch (@TypeOf(value)) {
                bool => ScriptValue{ .boolean = value },
                i8, i16, i32, i64, isize => ScriptValue{ .integer = @intCast(value) },
                u8, u16, u32, u64, usize => ScriptValue{ .integer = @intCast(value) },
                f32, f64 => ScriptValue{ .number = @floatCast(value) },
                else => ScriptValue.nil, // Fallback for complex types
            };
        } else {
            return ScriptValue.nil;
        }
    }

    /// Validate nil handling consistency
    pub fn validateNilConsistency(wrapper: *LuaWrapper) !NilValidationResult {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        var result = NilValidationResult{
            .lua_nil_pushable = false,
            .lua_nil_detectable = false,
            .script_value_nil_convertible = false,
            .round_trip_consistent = false,
        };

        // Test 1: Can we push nil?
        lua.c.lua_pushnil(wrapper.state);
        result.lua_nil_pushable = lua.c.lua_gettop(wrapper.state) > 0;

        // Test 2: Can we detect nil?
        if (result.lua_nil_pushable) {
            result.lua_nil_detectable = lua.c.lua_type(wrapper.state, -1) == lua.c.LUA_TNIL;
        }

        // Test 3: Can we convert to ScriptValue?
        if (result.lua_nil_detectable) {
            const script_nil = try luaNilToScriptValue(wrapper, -1);
            result.script_value_nil_convertible = script_nil == .nil;
        }

        // Test 4: Round-trip consistency
        if (result.script_value_nil_convertible) {
            lua.c.lua_pop(wrapper.state, 1); // Remove first nil
            try scriptValueNilToLua(wrapper, ScriptValue.nil);
            const is_still_nil = lua.c.lua_type(wrapper.state, -1) == lua.c.LUA_TNIL;
            result.round_trip_consistent = is_still_nil;
            lua.c.lua_pop(wrapper.state, 1); // Clean up
        } else if (result.lua_nil_pushable) {
            lua.c.lua_pop(wrapper.state, 1); // Clean up
        }

        return result;
    }
};

/// Source of nil/null values
pub const NilSource = enum {
    lua_nil,
    zig_null,
    empty_string,
    zero_pointer,
    undefined_value,
};

/// Context for nil interpretation
pub const NilContext = enum {
    /// Only actual nil values are considered nil
    strict,
    /// Empty containers and strings are also considered nil
    lenient,
    /// JavaScript-like falsy value semantics
    javascript_like,
};

/// Result of nil handling validation
pub const NilValidationResult = struct {
    lua_nil_pushable: bool,
    lua_nil_detectable: bool,
    script_value_nil_convertible: bool,
    round_trip_consistent: bool,

    pub fn isFullyWorking(self: NilValidationResult) bool {
        return self.lua_nil_pushable and
            self.lua_nil_detectable and
            self.script_value_nil_convertible and
            self.round_trip_consistent;
    }

    pub fn getIssues(self: NilValidationResult, allocator: std.mem.Allocator) ![]const []const u8 {
        var issues = std.ArrayList([]const u8).init(allocator);

        if (!self.lua_nil_pushable) {
            try issues.append("Cannot push nil to Lua stack");
        }
        if (!self.lua_nil_detectable) {
            try issues.append("Cannot detect nil values from Lua");
        }
        if (!self.script_value_nil_convertible) {
            try issues.append("Cannot convert Lua nil to ScriptValue.nil");
        }
        if (!self.round_trip_consistent) {
            try issues.append("Round-trip conversion is not consistent");
        }

        return issues.toOwnedSlice();
    }
};

/// Common nil-related errors
pub const NilError = error{
    NotNil,
    InvalidNilConversion,
    NilValidationFailed,
    LuaNotEnabled,
};

// Tests
test "NilHandler basic operations" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test nil detection
    NilHandler.pushNil(wrapper);
    try std.testing.expect(NilHandler.isNil(wrapper, -1));
    lua.c.lua_pop(wrapper.state, 1);

    // Test ScriptValue nil
    const nil_value = NilHandler.createNilScriptValue();
    try std.testing.expect(NilHandler.isScriptValueNil(nil_value));

    // Test conversion
    NilHandler.pushNil(wrapper);
    const converted = try NilHandler.luaNilToScriptValue(wrapper, -1);
    try std.testing.expect(converted == .nil);
    lua.c.lua_pop(wrapper.state, 1);
}

test "NilHandler optional handling" {
    const optional_int: ?i32 = null;
    const nil_result = NilHandler.handleOptional(i32, optional_int);
    try std.testing.expect(nil_result == .nil);

    const optional_with_value: ?i32 = 42;
    const value_result = NilHandler.handleOptional(i32, optional_with_value);
    try std.testing.expect(value_result == .integer);
    try std.testing.expectEqual(@as(i64, 42), value_result.integer);
}

test "NilHandler context-sensitive nil detection" {
    const nil_value = ScriptValue.nil;
    const empty_string = ScriptValue{ .string = "" };
    const zero_int = ScriptValue{ .integer = 0 };
    const false_bool = ScriptValue{ .boolean = false };

    // Strict context
    try std.testing.expect(NilHandler.shouldTreatAsNil(nil_value, .strict));
    try std.testing.expect(!NilHandler.shouldTreatAsNil(empty_string, .strict));
    try std.testing.expect(!NilHandler.shouldTreatAsNil(zero_int, .strict));

    // Lenient context
    try std.testing.expect(NilHandler.shouldTreatAsNil(nil_value, .lenient));
    try std.testing.expect(NilHandler.shouldTreatAsNil(empty_string, .lenient));
    try std.testing.expect(!NilHandler.shouldTreatAsNil(zero_int, .lenient));

    // JavaScript-like context
    try std.testing.expect(NilHandler.shouldTreatAsNil(nil_value, .javascript_like));
    try std.testing.expect(NilHandler.shouldTreatAsNil(empty_string, .javascript_like));
    try std.testing.expect(NilHandler.shouldTreatAsNil(zero_int, .javascript_like));
    try std.testing.expect(NilHandler.shouldTreatAsNil(false_bool, .javascript_like));
}

test "Nil validation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    const validation = try NilHandler.validateNilConsistency(wrapper);
    try std.testing.expect(validation.isFullyWorking());

    if (!validation.isFullyWorking()) {
        const issues = try validation.getIssues(allocator);
        defer allocator.free(issues);

        for (issues) |issue| {
            std.debug.print("Nil handling issue: {s}\\n", .{issue});
        }
    }
}
