// ABOUTME: Demonstrates ScriptValue to lua_push* conversion functionality
// ABOUTME: Shows how to convert all ScriptValue types to Lua using the lua_push* C API functions

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const pushScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pushScriptValue;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== ScriptValue to lua_push* Demo ===\n\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test 1: Basic primitive types
    std.debug.print("1. Basic primitive types:\n", .{});

    // Nil
    try pushScriptValue(wrapper, ScriptValue.nil);
    std.debug.print("  ✓ Pushed nil - stack top is: {s}\n", .{if (lua.c.lua_isnil(wrapper.state, -1)) "nil" else "not nil"});
    lua.c.lua_pop(wrapper.state, 1);

    // Boolean
    try pushScriptValue(wrapper, ScriptValue{ .boolean = true });
    std.debug.print("  ✓ Pushed boolean(true) - value: {}\n", .{lua.c.lua_toboolean(wrapper.state, -1) != 0});
    lua.c.lua_pop(wrapper.state, 1);

    // Integer
    try pushScriptValue(wrapper, ScriptValue{ .integer = 42 });
    std.debug.print("  ✓ Pushed integer(42) - value: {}\n", .{lua.c.lua_tointeger(wrapper.state, -1)});
    lua.c.lua_pop(wrapper.state, 1);

    // Number (float)
    try pushScriptValue(wrapper, ScriptValue{ .number = 3.14159 });
    std.debug.print("  ✓ Pushed number(3.14159) - value: {d}\n", .{lua.c.lua_tonumber(wrapper.state, -1)});
    lua.c.lua_pop(wrapper.state, 1);

    // String
    const test_string = "Hello from Zig!";
    try pushScriptValue(wrapper, ScriptValue{ .string = test_string });
    var len: usize = 0;
    const lua_str = lua.c.lua_tolstring(wrapper.state, -1, &len);
    std.debug.print("  ✓ Pushed string - value: \"{s}\"\n", .{lua_str.?[0..len]});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 2: Array conversion
    std.debug.print("\n2. Array conversion:\n", .{});

    var array = try ScriptValue.Array.init(allocator, 4);
    defer array.deinit();

    array.items[0] = ScriptValue{ .integer = 10 };
    array.items[1] = ScriptValue{ .string = "hello" };
    array.items[2] = ScriptValue{ .boolean = true };
    array.items[3] = ScriptValue{ .number = 2.718 };

    try pushScriptValue(wrapper, ScriptValue{ .array = array });

    std.debug.print("  ✓ Pushed array with 4 elements\n", .{});
    std.debug.print("  Array length: {}\n", .{lua.c.luaL_len(wrapper.state, -1)});

    // Check each element
    for (1..5) |i| {
        lua.c.lua_geti(wrapper.state, -1, @intCast(i));
        const lua_type = lua.c.lua_type(wrapper.state, -1);
        const type_name = lua.c.lua_typename(wrapper.state, lua_type);
        std.debug.print("  Element [{}]: type = {s}", .{ i, std.mem.span(type_name.?) });

        switch (lua_type) {
            lua.c.LUA_TNUMBER => {
                if (lua.c.lua_isinteger(wrapper.state, -1) != 0) {
                    std.debug.print(", value = {}\n", .{lua.c.lua_tointeger(wrapper.state, -1)});
                } else {
                    std.debug.print(", value = {d}\n", .{lua.c.lua_tonumber(wrapper.state, -1)});
                }
            },
            lua.c.LUA_TSTRING => {
                var str_len: usize = 0;
                const str = lua.c.lua_tolstring(wrapper.state, -1, &str_len);
                std.debug.print(", value = \"{s}\"\n", .{str.?[0..str_len]});
            },
            lua.c.LUA_TBOOLEAN => {
                std.debug.print(", value = {}\n", .{lua.c.lua_toboolean(wrapper.state, -1) != 0});
            },
            else => {
                std.debug.print("\n", .{});
            },
        }
        lua.c.lua_pop(wrapper.state, 1);
    }
    lua.c.lua_pop(wrapper.state, 1); // Pop the array

    // Test 3: Object conversion
    std.debug.print("\n3. Object conversion:\n", .{});

    var obj = ScriptValue.Object.init(allocator);
    defer obj.deinit();

    try obj.put("name", ScriptValue{ .string = "TestObject" });
    try obj.put("count", ScriptValue{ .integer = 100 });
    try obj.put("ratio", ScriptValue{ .number = 0.75 });
    try obj.put("active", ScriptValue{ .boolean = true });

    try pushScriptValue(wrapper, ScriptValue{ .object = obj });

    std.debug.print("  ✓ Pushed object with {} fields\n", .{obj.map.count()});

    // Check each field
    const fields = [_][]const u8{ "name", "count", "ratio", "active" };
    for (fields) |field| {
        lua.c.lua_getfield(wrapper.state, -1, field.ptr);
        const lua_type = lua.c.lua_type(wrapper.state, -1);
        const type_name = lua.c.lua_typename(wrapper.state, lua_type);
        std.debug.print("  Field '{s}': type = {s}", .{ field, std.mem.span(type_name.?) });

        switch (lua_type) {
            lua.c.LUA_TNUMBER => {
                if (lua.c.lua_isinteger(wrapper.state, -1) != 0) {
                    std.debug.print(", value = {}\n", .{lua.c.lua_tointeger(wrapper.state, -1)});
                } else {
                    std.debug.print(", value = {d}\n", .{lua.c.lua_tonumber(wrapper.state, -1)});
                }
            },
            lua.c.LUA_TSTRING => {
                var str_len: usize = 0;
                const str = lua.c.lua_tolstring(wrapper.state, -1, &str_len);
                std.debug.print(", value = \"{s}\"\n", .{str.?[0..str_len]});
            },
            lua.c.LUA_TBOOLEAN => {
                std.debug.print(", value = {}\n", .{lua.c.lua_toboolean(wrapper.state, -1) != 0});
            },
            else => {
                std.debug.print("\n", .{});
            },
        }
        lua.c.lua_pop(wrapper.state, 1);
    }
    lua.c.lua_pop(wrapper.state, 1); // Pop the object

    // Test 4: Nested structures
    std.debug.print("\n4. Nested structures:\n", .{});

    var nested_array = try ScriptValue.Array.init(allocator, 2);
    defer nested_array.deinit();
    nested_array.items[0] = ScriptValue{ .integer = 1 };
    nested_array.items[1] = ScriptValue{ .integer = 2 };

    var nested_obj = ScriptValue.Object.init(allocator);
    defer nested_obj.deinit();
    try nested_obj.put("numbers", ScriptValue{ .array = nested_array });
    try nested_obj.put("description", ScriptValue{ .string = "nested structure" });

    try pushScriptValue(wrapper, ScriptValue{ .object = nested_obj });

    std.debug.print("  ✓ Pushed nested object\n", .{});

    // Check nested array
    lua.c.lua_getfield(wrapper.state, -1, "numbers");
    std.debug.print("  Nested array length: {}\n", .{lua.c.luaL_len(wrapper.state, -1)});
    lua.c.lua_pop(wrapper.state, 1);

    // Check description
    lua.c.lua_getfield(wrapper.state, -1, "description");
    var desc_len: usize = 0;
    const desc_str = lua.c.lua_tolstring(wrapper.state, -1, &desc_len);
    std.debug.print("  Description: \"{s}\"\n", .{desc_str.?[0..desc_len]});
    lua.c.lua_pop(wrapper.state, 2); // Pop string and object

    // Test 5: UserData
    std.debug.print("\n5. UserData:\n", .{});

    const test_data: i32 = 12345;
    const userdata = ScriptValue.UserData{
        .ptr = @ptrCast(@constCast(&test_data)),
        .type_id = "test_i32",
        .deinit_fn = null,
    };

    try pushScriptValue(wrapper, ScriptValue{ .userdata = userdata });
    std.debug.print("  ✓ Pushed userdata - type: {s}\n", .{if (lua.c.lua_type(wrapper.state, -1) == lua.c.LUA_TLIGHTUSERDATA) "lightuserdata" else "other"});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 6: Type conversion edge cases
    std.debug.print("\n6. Type conversion edge cases:\n", .{});

    // Large integer that exceeds Lua integer range
    const large_int: i64 = std.math.maxInt(i64);
    try pushScriptValue(wrapper, ScriptValue{ .integer = large_int });
    std.debug.print("  ✓ Large integer converted to: {s} with value: {d}\n", .{ if (lua.c.lua_isinteger(wrapper.state, -1) != 0) "integer" else "number", lua.c.lua_tonumber(wrapper.state, -1) });
    lua.c.lua_pop(wrapper.state, 1);

    // Empty string
    try pushScriptValue(wrapper, ScriptValue{ .string = "" });
    var empty_len: usize = 0;
    const empty_str = lua.c.lua_tolstring(wrapper.state, -1, &empty_len);
    std.debug.print("  ✓ Empty string - length: {}, content: \"{s}\"\n", .{ empty_len, empty_str.?[0..empty_len] });
    lua.c.lua_pop(wrapper.state, 1);

    // Empty array
    var empty_array = try ScriptValue.Array.init(allocator, 0);
    defer empty_array.deinit();
    try pushScriptValue(wrapper, ScriptValue{ .array = empty_array });
    std.debug.print("  ✓ Empty array - length: {}\n", .{lua.c.luaL_len(wrapper.state, -1)});
    lua.c.lua_pop(wrapper.state, 1);

    // Empty object
    var empty_obj = ScriptValue.Object.init(allocator);
    defer empty_obj.deinit();
    try pushScriptValue(wrapper, ScriptValue{ .object = empty_obj });
    std.debug.print("  ✓ Empty object - field count: {}\n", .{empty_obj.map.count()});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 7: Stack verification
    std.debug.print("\n7. Stack verification:\n", .{});
    const initial_stack_top = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Initial stack top: {}\n", .{initial_stack_top});

    // Push multiple values
    try pushScriptValue(wrapper, ScriptValue{ .integer = 1 });
    try pushScriptValue(wrapper, ScriptValue{ .string = "test" });
    try pushScriptValue(wrapper, ScriptValue{ .boolean = false });

    const final_stack_top = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  After pushing 3 values: {}\n", .{final_stack_top});
    std.debug.print("  Stack growth: {}\n", .{final_stack_top - initial_stack_top});

    // Clean up stack
    lua.c.lua_settop(wrapper.state, initial_stack_top);
    std.debug.print("  Stack restored to: {}\n", .{lua.c.lua_gettop(wrapper.state)});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey functionality demonstrated:\n", .{});
    std.debug.print("- lua_pushnil() for ScriptValue.nil\n", .{});
    std.debug.print("- lua_pushboolean() for ScriptValue.boolean\n", .{});
    std.debug.print("- lua_pushinteger() for ScriptValue.integer (with overflow handling)\n", .{});
    std.debug.print("- lua_pushnumber() for ScriptValue.number\n", .{});
    std.debug.print("- lua_pushlstring() for ScriptValue.string\n", .{});
    std.debug.print("- lua_createtable() + lua_seti() for ScriptValue.array\n", .{});
    std.debug.print("- lua_createtable() + lua_settable() for ScriptValue.object\n", .{});
    std.debug.print("- lua_pushlightuserdata() for ScriptValue.userdata\n", .{});
    std.debug.print("- Recursive conversion for nested structures\n", .{});
    std.debug.print("- Proper stack management and cleanup\n", .{});
}
