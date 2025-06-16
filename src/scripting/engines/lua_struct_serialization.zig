// ABOUTME: Automatic Zig struct serialization to Lua tables with bidirectional conversion
// ABOUTME: Provides reflection-based struct serialization with field mapping and type validation

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const converter = @import("lua_value_converter.zig");

/// Serialization options for struct conversion
pub const SerializationOptions = struct {
    /// Include fields marked as private (starting with _)
    include_private_fields: bool = false,
    /// Maximum nesting depth for recursive structs
    max_depth: usize = 10,
    /// Field name transformation strategy
    field_name_transform: FieldNameTransform = .none,
    /// Whether to validate field types during deserialization
    validate_types: bool = true,
    /// Custom field mapping
    field_mappings: ?std.StringHashMap([]const u8) = null,
    /// Fields to exclude from serialization
    excluded_fields: ?std.StringHashMap(void) = null,
};

/// Field name transformation strategies
pub const FieldNameTransform = enum {
    /// No transformation
    none,
    /// snake_case to camelCase
    snake_to_camel,
    /// camelCase to snake_case
    camel_to_snake,
    /// Add prefix to all fields
    prefix,
    /// Add suffix to all fields
    suffix,
};

/// Serialization errors
pub const SerializationError = error{
    UnsupportedType,
    MaxDepthExceeded,
    FieldNotFound,
    TypeMismatch,
    CircularReference,
    InvalidStructure,
    LuaNotEnabled,
} || std.mem.Allocator.Error;

/// Struct serialization context for tracking depth and circular references
pub const SerializationContext = struct {
    const PointerMap = std.HashMap(usize, void, std.HashMap.getAutoHashFn(usize), std.HashMap.getAutoEqlFn(usize), std.HashMap.default_max_load_percentage);

    allocator: std.mem.Allocator,
    options: SerializationOptions,
    current_depth: usize = 0,
    visited_pointers: PointerMap,

    pub fn init(allocator: std.mem.Allocator, options: SerializationOptions) SerializationContext {
        return SerializationContext{
            .allocator = allocator,
            .options = options,
            .visited_pointers = PointerMap.init(allocator),
        };
    }

    pub fn deinit(self: *SerializationContext) void {
        self.visited_pointers.deinit();
    }

    pub fn enterStruct(self: *SerializationContext, ptr: *const anyopaque) !void {
        if (self.current_depth >= self.options.max_depth) {
            return SerializationError.MaxDepthExceeded;
        }

        const addr = @intFromPtr(ptr);
        if (self.visited_pointers.contains(addr)) {
            return SerializationError.CircularReference;
        }

        try self.visited_pointers.put(addr, {});
        self.current_depth += 1;
    }

    pub fn exitStruct(self: *SerializationContext, ptr: *const anyopaque) void {
        const addr = @intFromPtr(ptr);
        _ = self.visited_pointers.remove(addr);
        self.current_depth -= 1;
    }
};

/// Automatic struct serializer
pub const StructSerializer = struct {
    /// Serialize a Zig struct to a Lua table
    pub fn structToLuaTable(
        wrapper: *LuaWrapper,
        comptime T: type,
        value: T,
        options: SerializationOptions,
        allocator: std.mem.Allocator,
    ) SerializationError!void {
        if (!lua.lua_enabled) return SerializationError.LuaNotEnabled;

        var context = SerializationContext.init(allocator, options);
        defer context.deinit();

        try structToLuaTableRecursive(wrapper, T, value, &context);
    }

    /// Deserialize a Lua table to a Zig struct
    pub fn luaTableToStruct(
        wrapper: *LuaWrapper,
        comptime T: type,
        lua_index: c_int,
        options: SerializationOptions,
        allocator: std.mem.Allocator,
    ) SerializationError!T {
        if (!lua.lua_enabled) return SerializationError.LuaNotEnabled;

        var context = SerializationContext.init(allocator, options);
        defer context.deinit();

        return try luaTableToStructRecursive(wrapper, T, lua_index, &context);
    }

    /// Recursive struct to Lua table conversion
    fn structToLuaTableRecursive(
        wrapper: *LuaWrapper,
        comptime T: type,
        value: T,
        context: *SerializationContext,
    ) SerializationError!void {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .Struct => |struct_info| {
                // Track circular references
                try context.enterStruct(&value);
                defer context.exitStruct(&value);

                // Create Lua table
                lua.c.lua_newtable(wrapper.state);

                // Serialize each field
                inline for (struct_info.fields) |field| {
                    const field_name = field.name;

                    // Skip private fields if not included
                    if (!context.options.include_private_fields and field_name[0] == '_') {
                        continue;
                    }

                    // Check if field is excluded
                    if (context.options.excluded_fields) |excluded| {
                        if (excluded.contains(field_name)) continue;
                    }

                    // Get transformed field name
                    const lua_field_name = try transformFieldName(field_name, context.options, context.allocator);
                    defer if (!std.mem.eql(u8, lua_field_name, field_name)) context.allocator.free(lua_field_name);

                    // Get field value
                    const field_value = @field(value, field_name);

                    // Serialize field value
                    try serializeFieldValue(wrapper, field.type, field_value, context);

                    // Set field in table
                    lua.c.lua_setfield(wrapper.state, -2, lua_field_name.ptr);
                }
            },
            else => {
                return SerializationError.UnsupportedType;
            },
        }
    }

    /// Recursive Lua table to struct conversion
    fn luaTableToStructRecursive(
        wrapper: *LuaWrapper,
        comptime T: type,
        lua_index: c_int,
        context: *SerializationContext,
    ) SerializationError!T {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .Struct => |struct_info| {
                var result: T = undefined;

                // Deserialize each field
                inline for (struct_info.fields) |field| {
                    const field_name = field.name;

                    // Skip private fields if not included
                    if (!context.options.include_private_fields and field_name[0] == '_') {
                        // Initialize with default value
                        if (field.default_value) |default| {
                            @field(result, field_name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
                        } else {
                            @field(result, field_name) = std.mem.zeroes(field.type);
                        }
                        continue;
                    }

                    // Get transformed field name
                    const lua_field_name = try transformFieldName(field_name, context.options, context.allocator);
                    defer if (!std.mem.eql(u8, lua_field_name, field_name)) context.allocator.free(lua_field_name);

                    // Get field from Lua table
                    lua.c.lua_getfield(wrapper.state, lua_index, lua_field_name.ptr);

                    if (lua.c.lua_isnil(wrapper.state, -1)) {
                        // Field not found, use default value
                        lua.c.lua_pop(wrapper.state, 1);

                        if (field.default_value) |default| {
                            @field(result, field_name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
                        } else {
                            @field(result, field_name) = std.mem.zeroes(field.type);
                        }
                    } else {
                        // Deserialize field value
                        @field(result, field_name) = try deserializeFieldValue(wrapper, field.type, -1, context);
                        lua.c.lua_pop(wrapper.state, 1);
                    }
                }

                return result;
            },
            else => {
                return SerializationError.UnsupportedType;
            },
        }
    }

    /// Serialize a field value to Lua
    fn serializeFieldValue(
        wrapper: *LuaWrapper,
        comptime FieldType: type,
        value: FieldType,
        context: *SerializationContext,
    ) SerializationError!void {
        const type_info = @typeInfo(FieldType);

        switch (type_info) {
            .Bool => lua.c.lua_pushboolean(wrapper.state, if (value) 1 else 0),
            .Int => |int_info| {
                if (int_info.bits <= 32) {
                    lua.c.lua_pushinteger(wrapper.state, @intCast(value));
                } else {
                    lua.c.lua_pushnumber(wrapper.state, @floatFromInt(value));
                }
            },
            .Float => lua.c.lua_pushnumber(wrapper.state, @floatCast(value)),
            .Enum => |enum_info| {
                if (enum_info.is_exhaustive) {
                    lua.c.lua_pushinteger(wrapper.state, @intFromEnum(value));
                } else {
                    lua.c.lua_pushstring(wrapper.state, @tagName(value));
                }
            },
            .Optional => |opt_info| {
                if (value) |opt_value| {
                    try serializeFieldValue(wrapper, opt_info.child, opt_value, context);
                } else {
                    lua.c.lua_pushnil(wrapper.state);
                }
            },
            .Array => |array_info| {
                lua.c.lua_createtable(wrapper.state, @intCast(array_info.len), 0);

                for (value, 0..) |item, i| {
                    try serializeFieldValue(wrapper, array_info.child, item, context);
                    lua.c.lua_seti(wrapper.state, -2, @intCast(i + 1));
                }
            },
            .Pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .Slice => {
                        if (ptr_info.child == u8) {
                            // String slice
                            lua.c.lua_pushlstring(wrapper.state, value.ptr, value.len);
                        } else {
                            // Array slice
                            lua.c.lua_createtable(wrapper.state, @intCast(value.len), 0);

                            for (value, 0..) |item, i| {
                                try serializeFieldValue(wrapper, ptr_info.child, item, context);
                                lua.c.lua_seti(wrapper.state, -2, @intCast(i + 1));
                            }
                        }
                    },
                    .One => {
                        // Single pointer - dereference and serialize
                        try serializeFieldValue(wrapper, ptr_info.child, value.*, context);
                    },
                    else => return SerializationError.UnsupportedType,
                }
            },
            .Struct => {
                try structToLuaTableRecursive(wrapper, FieldType, value, context);
            },
            .Union => {
                // For tagged unions, create a table with tag and value
                lua.c.lua_newtable(wrapper.state);

                const tag_name = @tagName(value);
                lua.c.lua_pushstring(wrapper.state, tag_name);
                lua.c.lua_setfield(wrapper.state, -2, "tag");

                // Serialize the union value based on the active tag
                switch (value) {
                    inline else => |union_value| {
                        try serializeFieldValue(wrapper, @TypeOf(union_value), union_value, context);
                        lua.c.lua_setfield(wrapper.state, -2, "value");
                    },
                }
            },
            else => {
                return SerializationError.UnsupportedType;
            },
        }
    }

    /// Deserialize a field value from Lua
    fn deserializeFieldValue(
        wrapper: *LuaWrapper,
        comptime FieldType: type,
        lua_index: c_int,
        context: *SerializationContext,
    ) SerializationError!FieldType {
        const type_info = @typeInfo(FieldType);

        switch (type_info) {
            .Bool => {
                if (lua.c.lua_isboolean(wrapper.state, lua_index)) {
                    return lua.c.lua_toboolean(wrapper.state, lua_index) != 0;
                } else {
                    return SerializationError.TypeMismatch;
                }
            },
            .Int => {
                if (lua.c.lua_isnumber(wrapper.state, lua_index)) {
                    const num = lua.c.lua_tonumber(wrapper.state, lua_index);
                    return @intFromFloat(num);
                } else {
                    return SerializationError.TypeMismatch;
                }
            },
            .Float => {
                if (lua.c.lua_isnumber(wrapper.state, lua_index)) {
                    return @floatCast(lua.c.lua_tonumber(wrapper.state, lua_index));
                } else {
                    return SerializationError.TypeMismatch;
                }
            },
            .Enum => |enum_info| {
                if (enum_info.is_exhaustive) {
                    if (lua.c.lua_isnumber(wrapper.state, lua_index)) {
                        const int_val = lua.c.lua_tointeger(wrapper.state, lua_index);
                        return @enumFromInt(int_val);
                    }
                } else {
                    if (lua.c.lua_isstring(wrapper.state, lua_index)) {
                        const str = lua.c.lua_tostring(wrapper.state, lua_index);
                        return std.meta.stringToEnum(FieldType, std.mem.span(str)) orelse return SerializationError.TypeMismatch;
                    }
                }
                return SerializationError.TypeMismatch;
            },
            .Optional => |opt_info| {
                if (lua.c.lua_isnil(wrapper.state, lua_index)) {
                    return null;
                } else {
                    return try deserializeFieldValue(wrapper, opt_info.child, lua_index, context);
                }
            },
            .Array => |array_info| {
                if (!lua.c.lua_istable(wrapper.state, lua_index)) {
                    return SerializationError.TypeMismatch;
                }

                var result: FieldType = undefined;

                for (0..array_info.len) |i| {
                    lua.c.lua_geti(wrapper.state, lua_index, @intCast(i + 1));
                    result[i] = try deserializeFieldValue(wrapper, array_info.child, -1, context);
                    lua.c.lua_pop(wrapper.state, 1);
                }

                return result;
            },
            .Pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .Slice => {
                        if (ptr_info.child == u8) {
                            // String slice
                            if (lua.c.lua_isstring(wrapper.state, lua_index)) {
                                var len: usize = 0;
                                const str_ptr = lua.c.lua_tolstring(wrapper.state, lua_index, &len);
                                if (str_ptr) |ptr| {
                                    return try context.allocator.dupe(u8, ptr[0..len]);
                                } else {
                                    return try context.allocator.dupe(u8, "");
                                }
                            } else {
                                return SerializationError.TypeMismatch;
                            }
                        } else {
                            // Array slice
                            if (!lua.c.lua_istable(wrapper.state, lua_index)) {
                                return SerializationError.TypeMismatch;
                            }

                            const table_len = lua.c.lua_rawlen(wrapper.state, lua_index);
                            var result = try context.allocator.alloc(ptr_info.child, table_len);

                            for (0..table_len) |i| {
                                lua.c.lua_geti(wrapper.state, lua_index, @intCast(i + 1));
                                result[i] = try deserializeFieldValue(wrapper, ptr_info.child, -1, context);
                                lua.c.lua_pop(wrapper.state, 1);
                            }

                            return result;
                        }
                    },
                    .One => {
                        // Single pointer - deserialize and allocate
                        const child_value = try deserializeFieldValue(wrapper, ptr_info.child, lua_index, context);
                        const ptr = try context.allocator.create(ptr_info.child);
                        ptr.* = child_value;
                        return ptr;
                    },
                    else => return SerializationError.UnsupportedType,
                }
            },
            .Struct => {
                if (!lua.c.lua_istable(wrapper.state, lua_index)) {
                    return SerializationError.TypeMismatch;
                }
                return try luaTableToStructRecursive(wrapper, FieldType, lua_index, context);
            },
            .Union => |union_info| {
                if (!lua.c.lua_istable(wrapper.state, lua_index)) {
                    return SerializationError.TypeMismatch;
                }

                // Get the tag
                lua.c.lua_getfield(wrapper.state, lua_index, "tag");
                if (!lua.c.lua_isstring(wrapper.state, -1)) {
                    lua.c.lua_pop(wrapper.state, 1);
                    return SerializationError.TypeMismatch;
                }

                const tag_str = lua.c.lua_tostring(wrapper.state, -1);
                const tag_name = std.mem.span(tag_str);
                lua.c.lua_pop(wrapper.state, 1);

                // Get the value
                lua.c.lua_getfield(wrapper.state, lua_index, "value");
                defer lua.c.lua_pop(wrapper.state, 1);

                // Try to match the tag and deserialize the value
                inline for (union_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, tag_name)) {
                        const field_value = try deserializeFieldValue(wrapper, field.type, -1, context);
                        return @unionInit(FieldType, field.name, field_value);
                    }
                }

                return SerializationError.TypeMismatch;
            },
            else => {
                return SerializationError.UnsupportedType;
            },
        }
    }

    /// Transform field name according to options
    fn transformFieldName(
        field_name: []const u8,
        options: SerializationOptions,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // Check custom field mappings first
        if (options.field_mappings) |mappings| {
            if (mappings.get(field_name)) |mapped_name| {
                return try allocator.dupe(u8, mapped_name);
            }
        }

        switch (options.field_name_transform) {
            .none => return field_name,
            .snake_to_camel => return try snakeToCamel(field_name, allocator),
            .camel_to_snake => return try camelToSnake(field_name, allocator),
            .prefix => {
                // TODO: Implement prefix transformation
                return field_name;
            },
            .suffix => {
                // TODO: Implement suffix transformation
                return field_name;
            },
        }
    }

    /// Convert snake_case to camelCase
    fn snakeToCamel(snake_case: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var result = try allocator.alloc(u8, snake_case.len);
        var result_len: usize = 0;
        var capitalize_next = false;

        for (snake_case) |char| {
            if (char == '_') {
                capitalize_next = true;
            } else {
                if (capitalize_next and result_len > 0) {
                    result[result_len] = std.ascii.toUpper(char);
                    capitalize_next = false;
                } else {
                    result[result_len] = char;
                }
                result_len += 1;
            }
        }

        return allocator.realloc(result, result_len);
    }

    /// Convert camelCase to snake_case
    fn camelToSnake(camel_case: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var result = try allocator.alloc(u8, camel_case.len * 2); // Maximum possible size
        var result_len: usize = 0;

        for (camel_case, 0..) |char, i| {
            if (std.ascii.isUpper(char) and i > 0) {
                result[result_len] = '_';
                result_len += 1;
                result[result_len] = std.ascii.toLower(char);
            } else {
                result[result_len] = std.ascii.toLower(char);
            }
            result_len += 1;
        }

        return allocator.realloc(result, result_len);
    }
};

/// Utility functions for struct serialization
pub const StructSerializationUtils = struct {
    /// Create a ScriptValue.Object from a Zig struct
    pub fn structToScriptObject(
        comptime T: type,
        value: T,
        options: SerializationOptions,
        allocator: std.mem.Allocator,
    ) !ScriptValue {
        const wrapper = try lua.LuaWrapper.init(allocator);
        defer wrapper.deinit();

        try StructSerializer.structToLuaTable(wrapper, T, value, options, allocator);
        return try converter.pullScriptValue(wrapper, -1, allocator);
    }

    /// Create a Zig struct from a ScriptValue.Object
    pub fn scriptObjectToStruct(
        comptime T: type,
        script_value: ScriptValue,
        options: SerializationOptions,
        allocator: std.mem.Allocator,
    ) !T {
        if (script_value != .object) {
            return SerializationError.TypeMismatch;
        }

        const wrapper = try lua.LuaWrapper.init(allocator);
        defer wrapper.deinit();

        try converter.pushScriptValue(wrapper, script_value);
        return try StructSerializer.luaTableToStruct(wrapper, T, -1, options, allocator);
    }

    /// Get field information for a struct type
    pub fn getStructFieldInfo(comptime T: type, allocator: std.mem.Allocator) ![]FieldInfo {
        const type_info = @typeInfo(T);

        if (type_info != .Struct) {
            return SerializationError.UnsupportedType;
        }

        const struct_info = type_info.Struct;
        var field_infos = try allocator.alloc(FieldInfo, struct_info.fields.len);

        for (struct_info.fields, 0..) |field, i| {
            field_infos[i] = FieldInfo{
                .name = try allocator.dupe(u8, field.name),
                .type_name = try allocator.dupe(u8, @typeName(field.type)),
                .is_optional = @typeInfo(field.type) == .Optional,
                .has_default = field.default_value != null,
                .size = @sizeOf(field.type),
                .alignment = @alignOf(field.type),
            };
        }

        return field_infos;
    }

    /// Validate that a Lua table structure matches a Zig struct
    pub fn validateTableStructure(
        wrapper: *LuaWrapper,
        comptime T: type,
        lua_index: c_int,
        options: SerializationOptions,
        allocator: std.mem.Allocator,
    ) !ValidationResult {
        if (!lua.c.lua_istable(wrapper.state, lua_index)) {
            return ValidationResult{
                .is_valid = false,
                .errors = try allocator.alloc([]const u8, 1),
            };
        }

        var errors = std.ArrayList([]const u8).init(allocator);
        defer errors.deinit();

        const type_info = @typeInfo(T);
        if (type_info != .Struct) {
            try errors.append(try allocator.dupe(u8, "Type is not a struct"));
            return ValidationResult{
                .is_valid = false,
                .errors = try errors.toOwnedSlice(),
            };
        }

        const struct_info = type_info.Struct;

        // Check each required field
        inline for (struct_info.fields) |field| {
            if (!options.include_private_fields and field.name[0] == '_') {
                continue;
            }

            const lua_field_name = try StructSerializer.transformFieldName(field.name, options, allocator);
            defer if (!std.mem.eql(u8, lua_field_name, field.name)) allocator.free(lua_field_name);

            lua.c.lua_getfield(wrapper.state, lua_index, lua_field_name.ptr);
            const field_exists = !lua.c.lua_isnil(wrapper.state, -1);
            lua.c.lua_pop(wrapper.state, 1);

            if (!field_exists and field.default_value == null and @typeInfo(field.type) != .Optional) {
                const error_msg = try std.fmt.allocPrint(allocator, "Required field '{}' is missing", .{field.name});
                try errors.append(error_msg);
            }
        }

        return ValidationResult{
            .is_valid = errors.items.len == 0,
            .errors = try errors.toOwnedSlice(),
        };
    }
};

/// Field information for reflection
pub const FieldInfo = struct {
    name: []const u8,
    type_name: []const u8,
    is_optional: bool,
    has_default: bool,
    size: usize,
    alignment: usize,

    pub fn deinit(self: FieldInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type_name);
    }
};

/// Validation result for struct compatibility
pub const ValidationResult = struct {
    is_valid: bool,
    errors: [][]const u8,

    pub fn deinit(self: ValidationResult, allocator: std.mem.Allocator) void {
        for (self.errors) |error_msg| {
            allocator.free(error_msg);
        }
        allocator.free(self.errors);
    }
};

// Tests
test "StructSerializer - basic struct serialization" {
    if (!lua.lua_enabled) return;

    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
        score: f64,
    };

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    const test_value = TestStruct{
        .id = 42,
        .name = "test",
        .active = true,
        .score = 98.5,
    };

    const options = SerializationOptions{};

    // Serialize to Lua table
    try StructSerializer.structToLuaTable(wrapper, TestStruct, test_value, options, allocator);

    // Verify the table was created
    try std.testing.expect(lua.c.lua_istable(wrapper.state, -1));

    // Check field values
    lua.c.lua_getfield(wrapper.state, -1, "id");
    try std.testing.expectEqual(@as(c_int, 42), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 1);

    lua.c.lua_getfield(wrapper.state, -1, "active");
    try std.testing.expect(lua.c.lua_toboolean(wrapper.state, -1) != 0);
    lua.c.lua_pop(wrapper.state, 1);

    lua.c.lua_pop(wrapper.state, 1); // Remove table
}

test "StructSerializer - struct deserialization" {
    if (!lua.lua_enabled) return;

    const TestStruct = struct {
        id: u32,
        name: []const u8,
        active: bool,
        score: f64,
    };

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create Lua table
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushinteger(wrapper.state, 123);
    lua.c.lua_setfield(wrapper.state, -2, "id");
    lua.c.lua_pushliteral(wrapper.state, "deserialized");
    lua.c.lua_setfield(wrapper.state, -2, "name");
    lua.c.lua_pushboolean(wrapper.state, 0);
    lua.c.lua_setfield(wrapper.state, -2, "active");
    lua.c.lua_pushnumber(wrapper.state, 75.25);
    lua.c.lua_setfield(wrapper.state, -2, "score");

    const options = SerializationOptions{};

    // Deserialize from Lua table
    const result = try StructSerializer.luaTableToStruct(wrapper, TestStruct, -1, options, allocator);
    defer allocator.free(result.name);

    // Verify values
    try std.testing.expectEqual(@as(u32, 123), result.id);
    try std.testing.expectEqualStrings("deserialized", result.name);
    try std.testing.expect(!result.active);
    try std.testing.expectApproxEqRel(@as(f64, 75.25), result.score, 0.001);

    lua.c.lua_pop(wrapper.state, 1); // Remove table
}

test "StructSerializer - nested struct serialization" {
    if (!lua.lua_enabled) return;

    const InnerStruct = struct {
        value: i32,
        flag: bool,
    };

    const OuterStruct = struct {
        id: u64,
        inner: InnerStruct,
        optional_data: ?f32,
    };

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    const test_value = OuterStruct{
        .id = 999,
        .inner = InnerStruct{
            .value = -42,
            .flag = false,
        },
        .optional_data = 3.14,
    };

    const options = SerializationOptions{};

    // Serialize to Lua table
    try StructSerializer.structToLuaTable(wrapper, OuterStruct, test_value, options, allocator);

    // Verify nested structure
    try std.testing.expect(lua.c.lua_istable(wrapper.state, -1));

    lua.c.lua_getfield(wrapper.state, -1, "inner");
    try std.testing.expect(lua.c.lua_istable(wrapper.state, -1));

    lua.c.lua_getfield(wrapper.state, -1, "value");
    try std.testing.expectEqual(@as(c_int, -42), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 2); // value and inner table

    lua.c.lua_pop(wrapper.state, 1); // Remove outer table
}

test "StructSerializationUtils - field info extraction" {
    const TestStruct = struct {
        id: u32,
        name: []const u8,
        optional_field: ?i32,
        nested: struct {
            x: f32,
            y: f32,
        },
    };

    const allocator = std.testing.allocator;
    const field_infos = try StructSerializationUtils.getStructFieldInfo(TestStruct, allocator);
    defer {
        for (field_infos) |info| {
            info.deinit(allocator);
        }
        allocator.free(field_infos);
    }

    try std.testing.expectEqual(@as(usize, 4), field_infos.len);
    try std.testing.expectEqualStrings("id", field_infos[0].name);
    try std.testing.expectEqualStrings("name", field_infos[1].name);
    try std.testing.expect(field_infos[2].is_optional);
    try std.testing.expectEqualStrings("optional_field", field_infos[2].name);
}

test "StructSerializer - field name transformation" {
    const allocator = std.testing.allocator;

    // Test snake_case to camelCase
    const camel_result = try StructSerializer.snakeToCamel("snake_case_field", allocator);
    defer allocator.free(camel_result);
    try std.testing.expectEqualStrings("snakeCaseField", camel_result);

    // Test camelCase to snake_case
    const snake_result = try StructSerializer.camelToSnake("camelCaseField", allocator);
    defer allocator.free(snake_result);
    try std.testing.expectEqualStrings("camel_case_field", snake_result);
}
