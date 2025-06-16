// ABOUTME: ScriptValue to Lua C API conversion system with bidirectional type mapping
// ABOUTME: Implements lua_push* functions for all ScriptValue types with comprehensive error handling

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptFunction = @import("../interface.zig").ScriptFunction;

/// Conversion errors
pub const ConversionError = error{
    UnsupportedType,
    InvalidValue,
    CircularReference,
    TooManyNestingLevels,
    OutOfMemory,
    StackOverflow,
    InvalidFunctionReference,
    LuaStateError,
    LuaNotEnabled,
} || std.mem.Allocator.Error;

/// Options for value conversion
pub const ConversionOptions = struct {
    /// Maximum nesting depth for tables
    max_depth: usize = 100,
    /// Whether to convert functions to callable references
    convert_functions: bool = true,
    /// Whether to follow metatables
    follow_metatables: bool = true,
    /// Whether to convert userdata
    convert_userdata: bool = true,
};

/// Convert a Lua value to ScriptValue
pub fn luaToScriptValue(
    wrapper: *lua.LuaWrapper,
    index: c_int,
    allocator: std.mem.Allocator,
) !ScriptValue {
    const options = ConversionOptions{};
    return luaToScriptValueWithOptions(wrapper, index, allocator, options, 0);
}

/// Convert a Lua value to ScriptValue with options
pub fn luaToScriptValueWithOptions(
    wrapper: *lua.LuaWrapper,
    index: c_int,
    allocator: std.mem.Allocator,
    options: ConversionOptions,
    depth: usize,
) ConversionError!ScriptValue {
    if (!lua.lua_enabled) return ConversionError.InvalidValue;

    if (depth > options.max_depth) {
        return ConversionError.TooManyNestingLevels;
    }

    const lua_type = wrapper.getType(index);

    switch (lua_type) {
        lua.LUA_TNIL => {
            return ScriptValue.null;
        },
        lua.LUA_TBOOLEAN => {
            return ScriptValue{ .boolean = wrapper.toBoolean(index) };
        },
        lua.LUA_TNUMBER => {
            // Check if it's an integer
            if (wrapper.toInteger(index)) |int_val| {
                const num_val = wrapper.toNumber(index) orelse return ConversionError.InvalidValue;
                if (@as(f64, @floatFromInt(int_val)) == num_val) {
                    return ScriptValue{ .integer = int_val };
                }
            }

            // Otherwise treat as number
            const num_val = wrapper.toNumber(index) orelse return ConversionError.InvalidValue;
            return ScriptValue{ .number = num_val };
        },
        lua.LUA_TSTRING => {
            const str = try wrapper.toString(index);
            const str_copy = try allocator.dupe(u8, str);
            return ScriptValue{ .string = str_copy };
        },
        lua.LUA_TTABLE => {
            return try convertTable(wrapper, index, allocator, options, depth);
        },
        lua.LUA_TFUNCTION => {
            if (!options.convert_functions) {
                return ConversionError.UnsupportedType;
            }
            return try convertFunction(wrapper, index, allocator);
        },
        lua.LUA_TUSERDATA, lua.LUA_TLIGHTUSERDATA => {
            if (!options.convert_userdata) {
                return ConversionError.UnsupportedType;
            }
            return try convertUserdata(wrapper, index, allocator);
        },
        lua.LUA_TTHREAD => {
            // Threads (coroutines) are not directly convertible
            return ConversionError.UnsupportedType;
        },
        else => {
            return ConversionError.UnsupportedType;
        },
    }
}

/// Push ScriptValue to Lua stack using lua_push* functions
pub fn pushScriptValue(wrapper: *lua.LuaWrapper, value: ScriptValue) !void {
    if (!lua.lua_enabled) return ConversionError.LuaNotEnabled;

    switch (value) {
        .nil => lua.c.lua_pushnil(wrapper.state),
        .boolean => |b| lua.c.lua_pushboolean(wrapper.state, if (b) 1 else 0),
        .integer => |i| {
            if (i >= std.math.minInt(lua.c.lua_Integer) and i <= std.math.maxInt(lua.c.lua_Integer)) {
                lua.c.lua_pushinteger(wrapper.state, @intCast(i));
            } else {
                // Convert large integers to number to avoid overflow
                lua.c.lua_pushnumber(wrapper.state, @floatFromInt(i));
            }
        },
        .number => |f| lua.c.lua_pushnumber(wrapper.state, f),
        .string => |s| lua.c.lua_pushlstring(wrapper.state, s.ptr, s.len),
        .array => |arr| try pushArrayValue(wrapper, arr),
        .object => |obj| try pushObjectValue(wrapper, obj),
        .function => |func| try pushFunctionValue(wrapper, func),
        .userdata => |ud| try pushUserdata(wrapper, ud),
    }
}

/// Convert a ScriptValue to Lua (deprecated - use pushScriptValue)
pub fn scriptValueToLua(wrapper: *lua.LuaWrapper, value: ScriptValue) !void {
    return pushScriptValue(wrapper, value);
}

/// Convert a Lua table to either array or object
fn convertTable(
    wrapper: *lua.LuaWrapper,
    index: c_int,
    allocator: std.mem.Allocator,
    options: ConversionOptions,
    depth: usize,
) !ScriptValue {
    // First, check if it's an array-like table
    if (try isArray(wrapper, index)) {
        return try convertArray(wrapper, index, allocator, options, depth);
    } else {
        return try convertObject(wrapper, index, allocator, options, depth);
    }
}

/// Check if a Lua table is array-like
fn isArray(wrapper: *lua.LuaWrapper, index: c_int) !bool {
    if (!lua.lua_enabled) return false;

    // Get table length
    const len = lua.c.lua_rawlen(wrapper.state, index);
    if (len == 0) return false;

    // Check if all keys from 1 to len exist
    var i: usize = 1;
    while (i <= len) : (i += 1) {
        lua.c.lua_rawgeti(wrapper.state, index, @intCast(i));
        const exists = wrapper.getType(-1) != lua.LUA_TNIL;
        wrapper.pop(1);
        if (!exists) return false;
    }

    // Check if there are any non-integer keys
    wrapper.pushNil();
    while (lua.c.lua_next(wrapper.state, index) != 0) {
        // Key is at -2, value at -1
        if (!wrapper.isNumber(-2)) {
            wrapper.pop(2);
            return false;
        }

        const key = wrapper.toNumber(-2) orelse {
            wrapper.pop(2);
            return false;
        };

        // Check if key is a positive integer
        if (key != @floor(key) or key < 1 or key > @as(f64, @floatFromInt(len))) {
            wrapper.pop(2);
            return false;
        }

        wrapper.pop(1); // Remove value, keep key
    }

    return true;
}

/// Convert a Lua array-like table
fn convertArray(
    wrapper: *lua.LuaWrapper,
    index: c_int,
    allocator: std.mem.Allocator,
    options: ConversionOptions,
    depth: usize,
) !ScriptValue {
    const len = lua.c.lua_rawlen(wrapper.state, index);
    var items = try allocator.alloc(ScriptValue, len);
    errdefer {
        for (items[0..len]) |*item| {
            item.deinit(allocator);
        }
        allocator.free(items);
    }

    var i: usize = 1;
    while (i <= len) : (i += 1) {
        lua.c.lua_rawgeti(wrapper.state, index, @intCast(i));
        items[i - 1] = try luaToScriptValueWithOptions(wrapper, -1, allocator, options, depth + 1);
        wrapper.pop(1);
    }

    return ScriptValue{ .array = ScriptValue.Array{
        .items = items,
        .allocator = allocator,
    } };
}

/// Convert a Lua table to object
fn convertObject(
    wrapper: *lua.LuaWrapper,
    index: c_int,
    allocator: std.mem.Allocator,
    options: ConversionOptions,
    depth: usize,
) !ScriptValue {
    var obj = ScriptValue.Object.init(allocator);
    errdefer obj.deinit();

    // Iterate over table
    wrapper.pushNil();
    while (lua.c.lua_next(wrapper.state, if (index < 0) index - 1 else index) != 0) {
        // Key at -2, value at -1
        // Duplicate key for iteration to continue
        wrapper.pushValue(-2);

        // Convert key to string
        const key = wrapper.toString(-1) catch {
            wrapper.pop(3);
            continue;
        };
        wrapper.pop(1); // Remove duplicated key

        // Convert value
        const value = try luaToScriptValueWithOptions(wrapper, -1, allocator, options, depth + 1);
        errdefer value.deinit(allocator);

        try obj.put(key, value);
        wrapper.pop(1); // Remove value, keep original key
    }

    return ScriptValue{ .object = obj };
}

/// Convert a Lua function to a reference
fn convertFunction(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    _ = allocator;

    // Create a reference to the function in the registry
    wrapper.pushValue(index);
    const ref = wrapper.ref(lua.LUA_REGISTRYINDEX);

    // For now, we'll return nil since proper function bridging requires more infrastructure
    _ = ref; // TODO: Store function reference properly

    // TODO: Implement proper function reference storage
    // This would create a ScriptFunction that can be called from Zig
    return ScriptValue.nil;
}

/// Convert Lua userdata
fn convertUserdata(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    _ = allocator;

    if (!lua.lua_enabled) return ConversionError.InvalidValue;

    const ptr = lua.c.lua_touserdata(wrapper.state, index);
    if (ptr == null) {
        return ConversionError.InvalidValue;
    }

    // For now, just create a basic userdata
    // In a real implementation, we'd check for known userdata types
    return ScriptValue{ .userdata = ScriptValue.UserData{
        .ptr = ptr,
        .type_id = "lua_userdata",
        .deinit_fn = null,
    } };
}

/// Push ScriptValue array as Lua table with sequential integer keys
fn pushArrayValue(wrapper: *lua.LuaWrapper, array: ScriptValue.Array) !void {
    // Create table with array size hint (narr, nrec)
    lua.c.lua_createtable(wrapper.state, @intCast(array.items.len), 0);

    // Push array elements with 1-based indexing (Lua convention)
    for (array.items, 1..) |item, i| {
        try pushScriptValue(wrapper, item);
        lua.c.lua_seti(wrapper.state, -2, @intCast(i));
    }
}

/// Push ScriptValue object as Lua table with string keys
fn pushObjectValue(wrapper: *lua.LuaWrapper, obj: ScriptValue.Object) !void {
    // Create table with hash size hint
    lua.c.lua_createtable(wrapper.state, 0, @intCast(obj.map.count()));

    var iterator = obj.map.iterator();
    while (iterator.next()) |entry| {
        // Push key
        lua.c.lua_pushlstring(wrapper.state, entry.key_ptr.*.ptr, entry.key_ptr.*.len);

        // Push value
        try pushScriptValue(wrapper, entry.value_ptr.*);

        // Set table[key] = value
        lua.c.lua_settable(wrapper.state, -3);
    }
}

/// Push ScriptValue function as Lua function
fn pushFunctionValue(wrapper: *lua.LuaWrapper, func: *ScriptFunction) !void {
    // For now, we'll push a light userdata representing the function pointer
    // In a complete implementation, this would create a proper C closure
    // that can be called from Lua and bridges to the ScriptFunction
    _ = func;

    // Placeholder implementation - push nil for now
    lua.c.lua_pushnil(wrapper.state);

    // TODO: Implement proper function bridging in task 22.5
    // This would involve:
    // 1. Creating a C function that can be called from Lua
    // 2. Storing the ScriptFunction reference in an upvalue or registry
    // 3. Converting Lua arguments to ScriptValues
    // 4. Calling the ScriptFunction with the converted arguments
    // 5. Converting the result back to Lua values
}

/// Push a ScriptValue array to Lua (deprecated)
fn pushArray(wrapper: *lua.LuaWrapper, array: ScriptValue.Array) !void {
    return pushArrayValue(wrapper, array);
}

/// Push a ScriptValue object to Lua (deprecated)
fn pushObject(wrapper: *lua.LuaWrapper, obj: ScriptValue.Object) !void {
    return pushObjectValue(wrapper, obj);
}

/// Push a function reference (deprecated)
fn pushFunction(wrapper: *lua.LuaWrapper, func: *ScriptFunction) !void {
    _ = func;
    // For compatibility, just push nil
    lua.c.lua_pushnil(wrapper.state);
}

/// Push userdata (deprecated)
fn pushUserdata(wrapper: *lua.LuaWrapper, ud: ScriptValue.UserData) !void {
    lua.c.lua_pushlightuserdata(wrapper.state, ud.ptr);
}

// Tests
test "Lua value conversion - primitives" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test nil
    wrapper.pushNil();
    var nil_val = try luaToScriptValue(wrapper, -1, allocator);
    defer nil_val.deinit(allocator);
    try std.testing.expectEqual(ScriptValue.nil, nil_val);
    wrapper.pop(1);

    // Test boolean
    wrapper.pushBoolean(true);
    var bool_val = try luaToScriptValue(wrapper, -1, allocator);
    defer bool_val.deinit(allocator);
    try std.testing.expectEqual(ScriptValue{ .boolean = true }, bool_val);
    wrapper.pop(1);

    // Test integer
    wrapper.pushInteger(42);
    var int_val = try luaToScriptValue(wrapper, -1, allocator);
    defer int_val.deinit(allocator);
    try std.testing.expectEqual(ScriptValue{ .integer = 42 }, int_val);
    wrapper.pop(1);

    // Test number
    wrapper.pushNumber(3.14);
    var num_val = try luaToScriptValue(wrapper, -1, allocator);
    defer num_val.deinit(allocator);
    try std.testing.expectEqual(ScriptValue{ .number = 3.14 }, num_val);
    wrapper.pop(1);

    // Test string
    try wrapper.pushString("hello");
    var str_val = try luaToScriptValue(wrapper, -1, allocator);
    defer str_val.deinit(allocator);
    try std.testing.expectEqualStrings("hello", str_val.string);
    wrapper.pop(1);
}

test "Lua value conversion - tables" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test array
    wrapper.createTable(3, 0);
    wrapper.pushInteger(10);
    lua.c.lua_rawseti(wrapper.state, -2, 1);
    wrapper.pushInteger(20);
    lua.c.lua_rawseti(wrapper.state, -2, 2);
    wrapper.pushInteger(30);
    lua.c.lua_rawseti(wrapper.state, -2, 3);

    var array_val = try luaToScriptValue(wrapper, -1, allocator);
    defer array_val.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), array_val.array.items.len);
    try std.testing.expectEqual(ScriptValue{ .integer = 10 }, array_val.array.items[0]);
    try std.testing.expectEqual(ScriptValue{ .integer = 20 }, array_val.array.items[1]);
    try std.testing.expectEqual(ScriptValue{ .integer = 30 }, array_val.array.items[2]);
    wrapper.pop(1);

    // Test object
    wrapper.createTable(0, 2);
    try wrapper.pushString("name");
    try wrapper.pushString("test");
    wrapper.setTable(-3);
    try wrapper.pushString("value");
    wrapper.pushInteger(42);
    wrapper.setTable(-3);

    var obj_val = try luaToScriptValue(wrapper, -1, allocator);
    defer obj_val.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), obj_val.object.map.count());
    try std.testing.expectEqualStrings("test", obj_val.object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj_val.object.get("value").?.integer);
    wrapper.pop(1);
}

test "pushScriptValue - basic types" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test nil
    try pushScriptValue(wrapper, ScriptValue.nil);
    try std.testing.expect(lua.c.lua_isnil(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 1);

    // Test boolean
    try pushScriptValue(wrapper, ScriptValue{ .boolean = true });
    try std.testing.expect(lua.c.lua_isboolean(wrapper.state, -1));
    try std.testing.expect(lua.c.lua_toboolean(wrapper.state, -1) != 0);
    lua.c.lua_pop(wrapper.state, 1);

    // Test integer
    try pushScriptValue(wrapper, ScriptValue{ .integer = 42 });
    try std.testing.expect(lua.c.lua_isnumber(wrapper.state, -1));
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 42), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 1);

    // Test number (float)
    try pushScriptValue(wrapper, ScriptValue{ .number = 3.14 });
    try std.testing.expect(lua.c.lua_isnumber(wrapper.state, -1));
    try std.testing.expectApproxEqRel(@as(f64, 3.14), lua.c.lua_tonumber(wrapper.state, -1), 0.001);
    lua.c.lua_pop(wrapper.state, 1);

    // Test string
    const test_string = "Hello, World!";
    try pushScriptValue(wrapper, ScriptValue{ .string = test_string });
    try std.testing.expect(lua.c.lua_isstring(wrapper.state, -1));
    var len: usize = 0;
    const lua_str = lua.c.lua_tolstring(wrapper.state, -1, &len);
    try std.testing.expectEqualStrings(test_string, lua_str.?[0..len]);
    lua.c.lua_pop(wrapper.state, 1);
}

test "pushScriptValue - array conversion" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create test array
    var array = try ScriptValue.Array.init(allocator, 3);
    defer array.deinit();

    array.items[0] = ScriptValue{ .integer = 10 };
    array.items[1] = ScriptValue{ .integer = 20 };
    array.items[2] = ScriptValue{ .integer = 30 };

    // Push array
    try pushScriptValue(wrapper, ScriptValue{ .array = array });

    // Verify it's a table
    try std.testing.expect(lua.c.lua_istable(wrapper.state, -1));

    // Check array length
    const len = lua.c.luaL_len(wrapper.state, -1);
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 3), len);

    // Check array elements (Lua uses 1-based indexing)
    lua.c.lua_geti(wrapper.state, -1, 1);
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 10), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 1);

    lua.c.lua_geti(wrapper.state, -1, 2);
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 20), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 1);

    lua.c.lua_geti(wrapper.state, -1, 3);
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 30), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 2); // Pop value and table
}

test "pushScriptValue - object conversion" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create test object
    var obj = ScriptValue.Object.init(allocator);
    defer obj.deinit();

    try obj.put("name", ScriptValue{ .string = "test" });
    try obj.put("value", ScriptValue{ .integer = 42 });

    // Push object
    try pushScriptValue(wrapper, ScriptValue{ .object = obj });

    // Verify it's a table
    try std.testing.expect(lua.c.lua_istable(wrapper.state, -1));

    // Check object fields
    lua.c.lua_getfield(wrapper.state, -1, "name");
    var len: usize = 0;
    const name_str = lua.c.lua_tolstring(wrapper.state, -1, &len);
    try std.testing.expectEqualStrings("test", name_str.?[0..len]);
    lua.c.lua_pop(wrapper.state, 1);

    lua.c.lua_getfield(wrapper.state, -1, "value");
    try std.testing.expectEqual(@as(lua.c.lua_Integer, 42), lua.c.lua_tointeger(wrapper.state, -1));
    lua.c.lua_pop(wrapper.state, 2); // Pop value and table
}
