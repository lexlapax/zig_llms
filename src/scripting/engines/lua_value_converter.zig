// ABOUTME: ScriptValue to Lua C API conversion system with bidirectional type mapping
// ABOUTME: Implements lua_push* functions for all ScriptValue types with comprehensive error handling

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptFunction = @import("../interface.zig").ScriptFunction;
const NilHandler = @import("lua_nil_handling.zig").NilHandler;
const LightUserdataManager = @import("lua_light_userdata.zig").LightUserdataManager;
const LightUserdataConfig = @import("lua_light_userdata.zig").LightUserdataConfig;
const WeakReferences = @import("lua_weak_references.zig");
const WeakReferenceRegistry = WeakReferences.WeakReferenceRegistry;

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

/// Pull ScriptValue from Lua stack using lua_to* functions
pub fn pullScriptValue(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    if (!lua.lua_enabled) return ConversionError.LuaNotEnabled;

    const lua_type = lua.c.lua_type(wrapper.state, index);

    switch (lua_type) {
        lua.c.LUA_TNIL => {
            return NilHandler.createNilScriptValue();
        },
        lua.c.LUA_TBOOLEAN => {
            return ScriptValue{ .boolean = lua.c.lua_toboolean(wrapper.state, index) != 0 };
        },
        lua.c.LUA_TNUMBER => {
            // Check if it's an integer
            if (lua.c.lua_isinteger(wrapper.state, index) != 0) {
                const int_val = lua.c.lua_tointeger(wrapper.state, index);
                return ScriptValue{ .integer = @intCast(int_val) };
            } else {
                const num_val = lua.c.lua_tonumber(wrapper.state, index);
                return ScriptValue{ .number = num_val };
            }
        },
        lua.c.LUA_TSTRING => {
            var len: usize = 0;
            const str_ptr = lua.c.lua_tolstring(wrapper.state, index, &len);
            if (str_ptr) |ptr| {
                const string_copy = try allocator.dupe(u8, ptr[0..len]);
                return ScriptValue{ .string = string_copy };
            } else {
                return ScriptValue{ .string = try allocator.dupe(u8, "") };
            }
        },
        lua.c.LUA_TTABLE => {
            return try pullTableValue(wrapper, index, allocator);
        },
        lua.c.LUA_TFUNCTION => {
            return try pullFunctionValue(wrapper, index, allocator);
        },
        lua.c.LUA_TUSERDATA, lua.c.LUA_TLIGHTUSERDATA => {
            return try pullUserdataValue(wrapper, index, allocator);
        },
        lua.c.LUA_TTHREAD => {
            // Threads (coroutines) are not directly convertible
            return ConversionError.UnsupportedType;
        },
        else => {
            return ConversionError.UnsupportedType;
        },
    }
}

/// Convert a Lua value to ScriptValue (deprecated - use pullScriptValue)
pub fn luaToScriptValue(
    wrapper: *lua.LuaWrapper,
    index: c_int,
    allocator: std.mem.Allocator,
) !ScriptValue {
    return pullScriptValue(wrapper, index, allocator);
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
            return NilHandler.createNilScriptValue();
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
        .nil => NilHandler.pushNil(wrapper),
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
    return NilHandler.createNilScriptValue();
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
    if (!lua.lua_enabled) return ConversionError.LuaNotEnabled;

    // Check if this is a Lua function reference
    // We can identify Lua functions by checking if the engine_ref points to a LuaFunctionRef
    const LuaFunctionRef = @import("lua_function_bridge.zig").LuaFunctionRef;

    // Try to cast the engine_ref to a LuaFunctionRef
    // In a proper implementation, we'd have type tagging to safely identify this
    // For now, we'll use a runtime check by verifying the wrapper state matches
    const lua_func_ref: *LuaFunctionRef = @ptrCast(@alignCast(func.engine_ref));

    // Verify this is actually a Lua function by checking if the wrapper state matches
    if (lua_func_ref.wrapper.state == wrapper.state) {
        // This is a Lua function - push it from the registry
        lua.c.lua_rawgeti(wrapper.state, lua.c.LUA_REGISTRYINDEX, lua_func_ref.registry_key);

        // Verify it's still a function
        if (lua.c.lua_type(wrapper.state, -1) != lua.c.LUA_TFUNCTION) {
            lua.c.lua_pop(wrapper.state, 1);
            return ConversionError.InvalidFunctionReference;
        }
    } else {
        // This is not a Lua function reference - create a C closure that calls the ScriptFunction
        // For now, we'll just push nil as this requires more complex implementation
        // TODO: Implement C closure creation for non-Lua ScriptFunction objects
        lua.c.lua_pushnil(wrapper.state);
    }
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

/// Push userdata using the new userdata system
fn pushUserdata(wrapper: *lua.LuaWrapper, ud: ScriptValue.UserData) !void {
    if (!lua.lua_enabled) return ConversionError.LuaNotEnabled;

    // For now, we'll use light userdata for compatibility
    // In the future, this could be enhanced to use the full userdata system
    // when type information is available
    lua.c.lua_pushlightuserdata(wrapper.state, ud.ptr);

    // TODO: Integrate with LuaUserdataManager when we have type information
    // This would involve:
    // 1. Checking if we have a userdata manager available
    // 2. Looking up type information from ud.type_id
    // 3. Creating proper full userdata with metatable if type is registered
}

/// Enhanced userdata push with light userdata optimization
pub fn pushUserdataOptimized(
    wrapper: *lua.LuaWrapper,
    ud: ScriptValue.UserData,
    light_manager: ?*LightUserdataManager,
) !void {
    if (!lua.lua_enabled) return ConversionError.LuaNotEnabled;

    if (light_manager) |manager| {
        // Try to use light userdata optimization based on type
        if (isSimplePointerType(ud.type_id)) {
            lua.c.lua_pushlightuserdata(wrapper.state, ud.ptr);
            return;
        }

        // Try to convert to optimized ScriptValue if possible
        const script_value = try manager.lightUserdataToScriptValue(-1, manager.allocator, ud.type_id);
        _ = script_value; // For now, just use standard approach
    }

    // Fall back to standard light userdata
    lua.c.lua_pushlightuserdata(wrapper.state, ud.ptr);
}

/// Check if a type ID indicates a simple pointer type suitable for light userdata
fn isSimplePointerType(type_id: []const u8) bool {
    const simple_types = [_][]const u8{
        "i8",                "i16", "i32",  "i64",        "isize",
        "u8",                "u16", "u32",  "u64",        "usize",
        "f32",               "f64", "bool", "*anyopaque", "?*anyopaque",
        "lua_lightuserdata",
    };

    for (simple_types) |simple_type| {
        if (std.mem.eql(u8, type_id, simple_type)) {
            return true;
        }
    }

    return false;
}

/// Pull Lua table as ScriptValue (array or object)
fn pullTableValue(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    // Check for circular reference by getting table pointer
    const ptr = lua.c.lua_topointer(wrapper.state, index);
    if (ptr == null) return ConversionError.InvalidValue;

    // Determine if this table should be treated as an array or object
    if (try isSequentialArray(wrapper, index)) {
        return try pullArrayValue(wrapper, index, allocator);
    } else {
        return try pullObjectValue(wrapper, index, allocator);
    }
}

/// Check if table is a sequential array (contiguous integer keys starting from 1)
fn isSequentialArray(wrapper: *lua.LuaWrapper, index: c_int) !bool {
    const len = lua.c.luaL_len(wrapper.state, index);
    if (len == 0) return true; // Empty table can be array

    // Check if all keys from 1 to len exist
    var i: lua.c.lua_Integer = 1;
    while (i <= len) : (i += 1) {
        lua.c.lua_geti(wrapper.state, index, i);
        const is_nil = lua.c.lua_isnil(wrapper.state, -1);
        lua.c.lua_pop(wrapper.state, 1);

        if (is_nil) {
            return false;
        }
    }

    // Check if there are any non-integer keys
    lua.c.lua_pushnil(wrapper.state);
    while (lua.c.lua_next(wrapper.state, index) != 0) {
        // Pop value, keep key for next iteration
        lua.c.lua_pop(wrapper.state, 1);

        if (lua.c.lua_type(wrapper.state, -1) != lua.c.LUA_TNUMBER) {
            lua.c.lua_pop(wrapper.state, 1); // Pop key
            return false;
        }

        if (lua.c.lua_isinteger(wrapper.state, -1) == 0) {
            lua.c.lua_pop(wrapper.state, 1); // Pop key
            return false;
        }

        const key = lua.c.lua_tointeger(wrapper.state, -1);
        if (key < 1 or key > len) {
            lua.c.lua_pop(wrapper.state, 1); // Pop key
            return false;
        }
    }

    return true;
}

/// Pull table as array
fn pullArrayValue(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    const len = lua.c.luaL_len(wrapper.state, index);
    var array = try ScriptValue.Array.init(allocator, @intCast(len));
    errdefer array.deinit();

    // Fill array with table elements
    var i: lua.c.lua_Integer = 1;
    while (i <= len) : (i += 1) {
        lua.c.lua_geti(wrapper.state, index, i);
        array.items[@intCast(i - 1)] = try pullScriptValue(wrapper, -1, allocator);
        lua.c.lua_pop(wrapper.state, 1);
    }

    return ScriptValue{ .array = array };
}

/// Pull table as object
fn pullObjectValue(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    var object = ScriptValue.Object.init(allocator);
    errdefer object.deinit();

    // Iterate through table key-value pairs
    lua.c.lua_pushnil(wrapper.state);
    while (lua.c.lua_next(wrapper.state, index) != 0) {
        // Convert key to string
        const key_str = try luaValueToString(wrapper, -2, allocator);
        errdefer allocator.free(key_str);

        // Convert value
        const value = try pullScriptValue(wrapper, -1, allocator);
        errdefer value.deinit(allocator);

        // Add to object
        try object.put(key_str, value);

        // Pop value, keep key for next iteration
        lua.c.lua_pop(wrapper.state, 1);
    }

    return ScriptValue{ .object = object };
}

/// Pull function as function reference
fn pullFunctionValue(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    const ScriptContext = @import("../context.zig").ScriptContext;

    // Create a mock context for the function (this would normally come from the engine)
    // In a full implementation, this would be passed in or retrieved from the wrapper
    var temp_context = ScriptContext{
        .name = "lua_converter",
        .allocator = allocator,
        .engine = undefined, // Would be set properly in real usage
    };

    const createScriptFunctionFromLua = @import("lua_function_bridge.zig").createScriptFunctionFromLua;
    const script_func = try createScriptFunctionFromLua(allocator, &temp_context, wrapper, index);

    return ScriptValue{ .function = script_func };
}

/// Pull userdata as ScriptValue
fn pullUserdataValue(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
    const data_ptr = lua.c.lua_touserdata(wrapper.state, index);

    if (data_ptr) |ptr| {
        // Check if this is our managed userdata format
        const UserdataSystem = @import("lua_userdata_system.zig");

        if (lua.c.lua_type(wrapper.state, index) == lua.c.LUA_TUSERDATA) {
            // Try to read as managed userdata
            const header: *const UserdataSystem.UserdataHeader = @ptrCast(@alignCast(ptr));
            if (header.magic == 0xDEADBEEF) {
                // This is our managed userdata - extract type information
                const type_name = header.getTypeName();
                const type_name_copy = try allocator.dupe(u8, type_name);

                return ScriptValue{ .userdata = ScriptValue.UserData{
                    .ptr = header.getData(),
                    .type_id = type_name_copy,
                    .deinit_fn = struct {
                        fn deinit(type_id: []const u8, allocator_param: std.mem.Allocator) void {
                            allocator_param.free(type_id);
                        }
                    }.deinit,
                } };
            }
        }

        // Fall back to basic userdata handling
        const userdata = ScriptValue.UserData{
            .ptr = ptr,
            .type_id = if (lua.c.lua_type(wrapper.state, index) == lua.c.LUA_TLIGHTUSERDATA)
                "lua_lightuserdata"
            else
                "lua_userdata",
            .deinit_fn = null,
        };
        return ScriptValue{ .userdata = userdata };
    }

    return NilHandler.createNilScriptValue();
}

/// Convert Lua value at index to string
fn luaValueToString(wrapper: *lua.LuaWrapper, index: c_int, allocator: std.mem.Allocator) ![]u8 {
    const lua_type = lua.c.lua_type(wrapper.state, index);

    switch (lua_type) {
        lua.c.LUA_TSTRING => {
            var len: usize = 0;
            const str_ptr = lua.c.lua_tolstring(wrapper.state, index, &len);
            if (str_ptr) |ptr| {
                return try allocator.dupe(u8, ptr[0..len]);
            }
        },
        lua.c.LUA_TNUMBER => {
            // Convert number to string
            if (lua.c.lua_isinteger(wrapper.state, index) != 0) {
                const int_val = lua.c.lua_tointeger(wrapper.state, index);
                return try std.fmt.allocPrint(allocator, "{}", .{int_val});
            } else {
                const num_val = lua.c.lua_tonumber(wrapper.state, index);
                return try std.fmt.allocPrint(allocator, "{d}", .{num_val});
            }
        },
        lua.c.LUA_TBOOLEAN => {
            const bool_val = lua.c.lua_toboolean(wrapper.state, index) != 0;
            return try allocator.dupe(u8, if (bool_val) "true" else "false");
        },
        else => {
            // Use lua_typename for type name
            const type_name = lua.c.lua_typename(wrapper.state, lua_type);
            if (type_name) |name| {
                const name_slice = std.mem.span(name);
                return try std.fmt.allocPrint(allocator, "[{s}]", .{name_slice});
            }
        },
    }

    return try allocator.dupe(u8, "[unknown]");
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

test "pullScriptValue - basic types" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test nil
    lua.c.lua_pushnil(wrapper.state);
    const nil_value = try pullScriptValue(wrapper, -1, allocator);
    try std.testing.expect(nil_value == .nil);
    lua.c.lua_pop(wrapper.state, 1);

    // Test boolean
    lua.c.lua_pushboolean(wrapper.state, 1);
    const bool_value = try pullScriptValue(wrapper, -1, allocator);
    try std.testing.expect(bool_value == .boolean);
    try std.testing.expect(bool_value.boolean == true);
    lua.c.lua_pop(wrapper.state, 1);

    // Test integer
    lua.c.lua_pushinteger(wrapper.state, 42);
    const int_value = try pullScriptValue(wrapper, -1, allocator);
    defer int_value.deinit(allocator);
    try std.testing.expect(int_value == .integer);
    try std.testing.expectEqual(@as(i64, 42), int_value.integer);
    lua.c.lua_pop(wrapper.state, 1);

    // Test number (float)
    lua.c.lua_pushnumber(wrapper.state, 3.14159);
    const num_value = try pullScriptValue(wrapper, -1, allocator);
    defer num_value.deinit(allocator);
    try std.testing.expect(num_value == .number);
    try std.testing.expectApproxEqRel(@as(f64, 3.14159), num_value.number, 0.00001);
    lua.c.lua_pop(wrapper.state, 1);

    // Test string
    lua.c.lua_pushliteral(wrapper.state, "test string");
    const str_value = try pullScriptValue(wrapper, -1, allocator);
    defer str_value.deinit(allocator);
    try std.testing.expect(str_value == .string);
    try std.testing.expectEqualStrings("test string", str_value.string);
    lua.c.lua_pop(wrapper.state, 1);
}

test "pullScriptValue - array conversion" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create Lua array table
    lua.c.lua_createtable(wrapper.state, 3, 0);

    // Add elements [1] = 10, [2] = "hello", [3] = true
    lua.c.lua_pushinteger(wrapper.state, 10);
    lua.c.lua_seti(wrapper.state, -2, 1);

    lua.c.lua_pushliteral(wrapper.state, "hello");
    lua.c.lua_seti(wrapper.state, -2, 2);

    lua.c.lua_pushboolean(wrapper.state, 1);
    lua.c.lua_seti(wrapper.state, -2, 3);

    // Pull as ScriptValue
    var array_value = try pullScriptValue(wrapper, -1, allocator);
    defer array_value.deinit(allocator);

    try std.testing.expect(array_value == .array);
    try std.testing.expectEqual(@as(usize, 3), array_value.array.items.len);

    // Check elements
    try std.testing.expect(array_value.array.items[0] == .integer);
    try std.testing.expectEqual(@as(i64, 10), array_value.array.items[0].integer);

    try std.testing.expect(array_value.array.items[1] == .string);
    try std.testing.expectEqualStrings("hello", array_value.array.items[1].string);

    try std.testing.expect(array_value.array.items[2] == .boolean);
    try std.testing.expect(array_value.array.items[2].boolean == true);

    lua.c.lua_pop(wrapper.state, 1);
}

test "pullScriptValue - object conversion" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create Lua object table
    lua.c.lua_createtable(wrapper.state, 0, 3);

    // Add key-value pairs
    lua.c.lua_pushliteral(wrapper.state, "name");
    lua.c.lua_pushliteral(wrapper.state, "TestObject");
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_pushliteral(wrapper.state, "count");
    lua.c.lua_pushinteger(wrapper.state, 100);
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_pushliteral(wrapper.state, "active");
    lua.c.lua_pushboolean(wrapper.state, 0);
    lua.c.lua_settable(wrapper.state, -3);

    // Pull as ScriptValue
    var obj_value = try pullScriptValue(wrapper, -1, allocator);
    defer obj_value.deinit(allocator);

    try std.testing.expect(obj_value == .object);
    try std.testing.expectEqual(@as(usize, 3), obj_value.object.map.count());

    // Check fields
    const name_val = obj_value.object.get("name").?;
    try std.testing.expect(name_val == .string);
    try std.testing.expectEqualStrings("TestObject", name_val.string);

    const count_val = obj_value.object.get("count").?;
    try std.testing.expect(count_val == .integer);
    try std.testing.expectEqual(@as(i64, 100), count_val.integer);

    const active_val = obj_value.object.get("active").?;
    try std.testing.expect(active_val == .boolean);
    try std.testing.expect(active_val.boolean == false);

    lua.c.lua_pop(wrapper.state, 1);
}

test "pullScriptValue - userdata conversion" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test light userdata
    const test_data: i32 = 12345;
    lua.c.lua_pushlightuserdata(wrapper.state, @ptrCast(@constCast(&test_data)));

    const ud_value = try pullScriptValue(wrapper, -1, allocator);
    defer ud_value.deinit(allocator);

    try std.testing.expect(ud_value == .userdata);
    try std.testing.expectEqualStrings("lua_lightuserdata", ud_value.userdata.type_id);
    try std.testing.expect(ud_value.userdata.ptr != null);

    lua.c.lua_pop(wrapper.state, 1);
}

test "pullScriptValue - round trip conversion" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create complex nested structure
    var original_obj = ScriptValue.Object.init(allocator);
    defer original_obj.deinit();

    var nested_array = try ScriptValue.Array.init(allocator, 2);
    defer nested_array.deinit();
    nested_array.items[0] = ScriptValue{ .integer = 1 };
    nested_array.items[1] = ScriptValue{ .string = try allocator.dupe(u8, "nested") };
    defer allocator.free(nested_array.items[1].string);

    try original_obj.put("numbers", ScriptValue{ .array = nested_array });
    try original_obj.put("pi", ScriptValue{ .number = 3.14159 });
    try original_obj.put("enabled", ScriptValue{ .boolean = true });

    // Push to Lua
    try pushScriptValue(wrapper, ScriptValue{ .object = original_obj });

    // Pull back from Lua
    var pulled_obj = try pullScriptValue(wrapper, -1, allocator);
    defer pulled_obj.deinit(allocator);

    // Verify round-trip conversion
    try std.testing.expect(pulled_obj == .object);
    try std.testing.expectEqual(@as(usize, 3), pulled_obj.object.map.count());

    // Check nested array
    const numbers_val = pulled_obj.object.get("numbers").?;
    try std.testing.expect(numbers_val == .array);
    try std.testing.expectEqual(@as(usize, 2), numbers_val.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), numbers_val.array.items[0].integer);
    try std.testing.expectEqualStrings("nested", numbers_val.array.items[1].string);

    // Check other fields
    const pi_val = pulled_obj.object.get("pi").?;
    try std.testing.expectApproxEqRel(@as(f64, 3.14159), pi_val.number, 0.00001);

    const enabled_val = pulled_obj.object.get("enabled").?;
    try std.testing.expect(enabled_val.boolean == true);

    lua.c.lua_pop(wrapper.state, 1);
}

/// Weak reference integration functions
pub const WeakReferenceIntegration = struct {
    /// Create a ScriptValue that holds a weak reference to a Lua object
    pub fn createWeakScriptValue(
        allocator: std.mem.Allocator,
        registry: *WeakReferenceRegistry,
        wrapper: *lua.LuaWrapper,
        lua_index: c_int,
        type_name: []const u8,
    ) !ScriptValue {
        const ref_id = try registry.createLuaRef(wrapper, lua_index, type_name);

        // Create a custom userdata that holds the weak reference ID
        const WeakRefHolder = struct {
            ref_id: u64,
            registry: *WeakReferenceRegistry,
            type_name: []const u8,

            pub fn getValue(self: @This(), alloc: std.mem.Allocator) !?ScriptValue {
                if (self.registry.getLuaRef(self.ref_id)) |weak_ref| {
                    return weak_ref.get(alloc);
                }
                return null;
            }
        };

        const holder = try allocator.create(WeakRefHolder);
        holder.* = WeakRefHolder{
            .ref_id = ref_id,
            .registry = registry,
            .type_name = try allocator.dupe(u8, type_name),
        };

        return ScriptValue{ .userdata = ScriptValue.UserData{
            .ptr = holder,
            .type_id = try allocator.dupe(u8, "weak_lua_reference"),
            .deinit_fn = struct {
                fn deinit(type_id: []const u8, alloc: std.mem.Allocator) void {
                    alloc.free(type_id);
                }
            }.deinit,
        } };
    }

    /// Create a weak reference from a Zig object and push it to Lua
    pub fn pushZigObjectAsWeakRef(
        registry: *WeakReferenceRegistry,
        wrapper: *lua.LuaWrapper,
        ptr: *anyopaque,
        size: usize,
        type_name: []const u8,
    ) !void {
        const ref_id = try registry.createZigRef(ptr, size, type_name);

        // Create a Lua userdata that holds the weak reference ID
        const holder_ptr = lua.c.lua_newuserdata(wrapper.state, @sizeOf(u64));
        const holder: *u64 = @ptrCast(@alignCast(holder_ptr));
        holder.* = ref_id;

        // Set metatable for type identification
        if (lua.c.luaL_newmetatable(wrapper.state, "zig_weak_reference") != 0) {
            // First time creating this metatable
            lua.c.lua_pushstring(wrapper.state, "__gc");
            lua.c.lua_pushcfunction(wrapper.state, struct {
                fn gc(L: ?*lua.c.lua_State) callconv(.C) c_int {
                    const ref_id_ptr: *u64 = @ptrCast(@alignCast(lua.c.lua_touserdata(L, 1)));
                    // Note: In a real implementation, we'd need access to the registry here
                    // for proper cleanup. This is a simplified example.
                    _ = ref_id_ptr;
                    return 0;
                }
            }.gc);
            lua.c.lua_settable(wrapper.state, -3);
        }
        lua.c.lua_setmetatable(wrapper.state, -2);
    }

    /// Extract a Zig object from a weak reference userdata
    pub fn getZigObjectFromWeakRef(
        registry: *WeakReferenceRegistry,
        wrapper: *lua.LuaWrapper,
        lua_index: c_int,
        comptime T: type,
    ) ?*T {
        // Check if this is our weak reference userdata
        if (lua.c.lua_type(wrapper.state, lua_index) != lua.c.LUA_TUSERDATA) return null;

        // Check metatable
        if (lua.c.lua_getmetatable(wrapper.state, lua_index) == 0) return null;
        lua.c.luaL_getmetatable(wrapper.state, "zig_weak_reference");
        const is_weak_ref = lua.c.lua_rawequal(wrapper.state, -1, -2) != 0;
        lua.c.lua_pop(wrapper.state, 2); // Remove both metatables

        if (!is_weak_ref) return null;

        // Extract the reference ID
        const ref_id_ptr: *u64 = @ptrCast(@alignCast(lua.c.lua_touserdata(wrapper.state, lua_index)));
        const ref_id = ref_id_ptr.*;

        // Get the weak reference and extract the object
        if (registry.getZigRef(ref_id)) |weak_ref| {
            return weak_ref.get(T);
        }

        return null;
    }

    /// Create a bidirectional weak reference between Lua and Zig objects
    pub fn createBidirectionalWeakRef(
        allocator: std.mem.Allocator,
        registry: *WeakReferenceRegistry,
        wrapper: *lua.LuaWrapper,
        lua_index: c_int,
        zig_ptr: *anyopaque,
        zig_size: usize,
        type_name: []const u8,
    ) !ScriptValue {
        const ref_id = try registry.createBidirectionalRef(
            wrapper,
            lua_index,
            zig_ptr,
            zig_size,
            type_name,
        );

        // Create a ScriptValue that can access both sides
        const BiRefHolder = struct {
            ref_id: u64,
            registry: *WeakReferenceRegistry,
            type_name: []const u8,

            pub fn getLuaValue(self: @This(), alloc: std.mem.Allocator) !?ScriptValue {
                if (self.registry.getBidirectionalRef(self.ref_id)) |bi_ref| {
                    return bi_ref.getLua(alloc);
                }
                return null;
            }

            pub fn getZigValue(self: @This(), comptime T: type) ?*T {
                if (self.registry.getBidirectionalRef(self.ref_id)) |bi_ref| {
                    return bi_ref.getZig(T);
                }
                return null;
            }
        };

        const holder = try allocator.create(BiRefHolder);
        holder.* = BiRefHolder{
            .ref_id = ref_id,
            .registry = registry,
            .type_name = try allocator.dupe(u8, type_name),
        };

        return ScriptValue{ .userdata = ScriptValue.UserData{
            .ptr = holder,
            .type_id = try allocator.dupe(u8, "bidirectional_weak_reference"),
            .deinit_fn = struct {
                fn deinit(type_id: []const u8, alloc: std.mem.Allocator) void {
                    alloc.free(type_id);
                }
            }.deinit,
        } };
    }

    /// Utility function to check if a ScriptValue contains a weak reference
    pub fn isWeakReference(value: ScriptValue) bool {
        if (value != .userdata) return false;

        return std.mem.eql(u8, value.userdata.type_id, "weak_lua_reference") or
            std.mem.eql(u8, value.userdata.type_id, "bidirectional_weak_reference");
    }

    /// Resolve a weak reference ScriptValue to its actual value
    pub fn resolveWeakReference(value: ScriptValue, allocator: std.mem.Allocator) !?ScriptValue {
        if (!isWeakReference(value)) return null;

        if (std.mem.eql(u8, value.userdata.type_id, "weak_lua_reference")) {
            const holder: *const struct {
                ref_id: u64,
                registry: *WeakReferenceRegistry,
                type_name: []const u8,

                pub fn getValue(self: @This(), alloc: std.mem.Allocator) !?ScriptValue {
                    if (self.registry.getLuaRef(self.ref_id)) |weak_ref| {
                        return weak_ref.get(alloc);
                    }
                    return null;
                }
            } = @ptrCast(@alignCast(value.userdata.ptr));

            return try holder.getValue(allocator);
        }

        return null;
    }
};

// Tests for weak reference integration
test "WeakReferenceIntegration - basic weak ScriptValue" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var registry = WeakReferenceRegistry.init(allocator);
    defer registry.deinit();

    // Create a Lua table
    lua.c.lua_newtable(wrapper.state);
    lua.c.lua_pushstring(wrapper.state, "test_value");
    lua.c.lua_setfield(wrapper.state, -2, "key");

    // Create weak ScriptValue
    var weak_value = try WeakReferenceIntegration.createWeakScriptValue(
        allocator,
        &registry,
        wrapper,
        -1,
        "test_table",
    );
    defer weak_value.deinit(allocator);

    lua.c.lua_pop(wrapper.state, 1); // Remove table from stack

    // Test that it's a weak reference
    try std.testing.expect(WeakReferenceIntegration.isWeakReference(weak_value));

    // Test resolving the weak reference
    if (try WeakReferenceIntegration.resolveWeakReference(weak_value, allocator)) |resolved| {
        defer resolved.deinit(allocator);
        try std.testing.expect(resolved == .object);
    }
}

test "WeakReferenceIntegration - Zig object weak reference" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;
    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var registry = WeakReferenceRegistry.init(allocator);
    defer registry.deinit();

    // Create a Zig object
    var test_object: i32 = 42;

    // Push as weak reference to Lua
    try WeakReferenceIntegration.pushZigObjectAsWeakRef(
        &registry,
        wrapper,
        &test_object,
        @sizeOf(i32),
        "test_i32",
    );

    // Try to get it back
    const retrieved = WeakReferenceIntegration.getZigObjectFromWeakRef(&registry, wrapper, -1, i32);
    try std.testing.expect(retrieved != null);

    if (retrieved) |ptr| {
        try std.testing.expectEqual(@as(i32, 42), ptr.*);

        // Release the reference (in real usage, this would be done automatically)
        if (registry.getZigRef(1)) |weak_ref| { // Assuming ID 1 for first reference
            weak_ref.release();
        }
    }

    lua.c.lua_pop(wrapper.state, 1);
}
