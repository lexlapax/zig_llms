// ABOUTME: Demonstrates lua_to* to ScriptValue conversion functionality
// ABOUTME: Shows how to convert all Lua types to ScriptValue using the lua_to* C API functions

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const pullScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pullScriptValue;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== lua_to* to ScriptValue Demo ===\n\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test 1: Basic primitive types
    std.debug.print("1. Basic primitive type conversion:\n", .{});

    // Nil
    lua.c.lua_pushnil(wrapper.state);
    const nil_val = try pullScriptValue(wrapper, -1, allocator);
    std.debug.print("  ✓ Pulled nil - ScriptValue type: {s}\n", .{@tagName(nil_val)});
    lua.c.lua_pop(wrapper.state, 1);

    // Boolean
    lua.c.lua_pushboolean(wrapper.state, 1);
    const bool_val = try pullScriptValue(wrapper, -1, allocator);
    std.debug.print("  ✓ Pulled boolean(true) - value: {}\n", .{bool_val.boolean});
    lua.c.lua_pop(wrapper.state, 1);

    // Integer
    lua.c.lua_pushinteger(wrapper.state, 42);
    var int_val = try pullScriptValue(wrapper, -1, allocator);
    defer int_val.deinit(allocator);
    std.debug.print("  ✓ Pulled integer(42) - value: {}\n", .{int_val.integer});
    lua.c.lua_pop(wrapper.state, 1);

    // Number (float)
    lua.c.lua_pushnumber(wrapper.state, 3.14159);
    var num_val = try pullScriptValue(wrapper, -1, allocator);
    defer num_val.deinit(allocator);
    std.debug.print("  ✓ Pulled number(3.14159) - value: {d}\n", .{num_val.number});
    lua.c.lua_pop(wrapper.state, 1);

    // String
    lua.c.lua_pushliteral(wrapper.state, "Hello from Lua!");
    var str_val = try pullScriptValue(wrapper, -1, allocator);
    defer str_val.deinit(allocator);
    std.debug.print("  ✓ Pulled string - value: \"{s}\"\n", .{str_val.string});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 2: Array conversion
    std.debug.print("\n2. Array conversion:\n", .{});

    // Create Lua array: {10, "test", true, 2.718}
    lua.c.lua_createtable(wrapper.state, 4, 0);

    lua.c.lua_pushinteger(wrapper.state, 10);
    lua.c.lua_seti(wrapper.state, -2, 1);

    lua.c.lua_pushliteral(wrapper.state, "test");
    lua.c.lua_seti(wrapper.state, -2, 2);

    lua.c.lua_pushboolean(wrapper.state, 1);
    lua.c.lua_seti(wrapper.state, -2, 3);

    lua.c.lua_pushnumber(wrapper.state, 2.718);
    lua.c.lua_seti(wrapper.state, -2, 4);

    var array_val = try pullScriptValue(wrapper, -1, allocator);
    defer array_val.deinit(allocator);

    std.debug.print("  ✓ Pulled array with {} elements\n", .{array_val.array.items.len});

    for (array_val.array.items, 0..) |item, i| {
        std.debug.print("  Element [{}]: type = {s}", .{ i + 1, @tagName(item) });

        switch (item) {
            .integer => |val| std.debug.print(", value = {}\n", .{val}),
            .number => |val| std.debug.print(", value = {d}\n", .{val}),
            .string => |val| std.debug.print(", value = \"{s}\"\n", .{val}),
            .boolean => |val| std.debug.print(", value = {}\n", .{val}),
            else => std.debug.print("\n", .{}),
        }
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Test 3: Object conversion
    std.debug.print("\n3. Object conversion:\n", .{});

    // Create Lua object: {name = "TestObject", count = 100, ratio = 0.75, active = false}
    lua.c.lua_createtable(wrapper.state, 0, 4);

    lua.c.lua_pushliteral(wrapper.state, "name");
    lua.c.lua_pushliteral(wrapper.state, "TestObject");
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_pushliteral(wrapper.state, "count");
    lua.c.lua_pushinteger(wrapper.state, 100);
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_pushliteral(wrapper.state, "ratio");
    lua.c.lua_pushnumber(wrapper.state, 0.75);
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_pushliteral(wrapper.state, "active");
    lua.c.lua_pushboolean(wrapper.state, 0);
    lua.c.lua_settable(wrapper.state, -3);

    var obj_val = try pullScriptValue(wrapper, -1, allocator);
    defer obj_val.deinit(allocator);

    std.debug.print("  ✓ Pulled object with {} fields\n", .{obj_val.object.map.count()});

    // Iterate through object fields
    var iterator = obj_val.object.map.iterator();
    while (iterator.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_value = entry.value_ptr.*;

        std.debug.print("  Field '{s}': type = {s}", .{ field_name, @tagName(field_value) });

        switch (field_value) {
            .integer => |val| std.debug.print(", value = {}\n", .{val}),
            .number => |val| std.debug.print(", value = {d}\n", .{val}),
            .string => |val| std.debug.print(", value = \"{s}\"\n", .{val}),
            .boolean => |val| std.debug.print(", value = {}\n", .{val}),
            else => std.debug.print("\n", .{}),
        }
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Test 4: Nested structures
    std.debug.print("\n4. Nested structures:\n", .{});

    // Create nested Lua structure
    // outer = { inner = {1, 2, 3}, metadata = {type = "array", size = 3} }
    lua.c.lua_createtable(wrapper.state, 0, 2);

    // Create inner array {1, 2, 3}
    lua.c.lua_pushliteral(wrapper.state, "inner");
    lua.c.lua_createtable(wrapper.state, 3, 0);
    for (1..4) |i| {
        lua.c.lua_pushinteger(wrapper.state, @intCast(i));
        lua.c.lua_seti(wrapper.state, -2, @intCast(i));
    }
    lua.c.lua_settable(wrapper.state, -3);

    // Create metadata object {type = "array", size = 3}
    lua.c.lua_pushliteral(wrapper.state, "metadata");
    lua.c.lua_createtable(wrapper.state, 0, 2);

    lua.c.lua_pushliteral(wrapper.state, "type");
    lua.c.lua_pushliteral(wrapper.state, "array");
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_pushliteral(wrapper.state, "size");
    lua.c.lua_pushinteger(wrapper.state, 3);
    lua.c.lua_settable(wrapper.state, -3);

    lua.c.lua_settable(wrapper.state, -3);

    var nested_val = try pullScriptValue(wrapper, -1, allocator);
    defer nested_val.deinit(allocator);

    std.debug.print("  ✓ Pulled nested structure\n", .{});

    // Check inner array
    const inner_val = nested_val.object.get("inner").?;
    std.debug.print("  Inner array length: {}\n", .{inner_val.array.items.len});
    for (inner_val.array.items, 0..) |item, i| {
        std.debug.print("    [{}] = {}\n", .{ i + 1, item.integer });
    }

    // Check metadata
    const metadata_val = nested_val.object.get("metadata").?;
    std.debug.print("  Metadata fields: {}\n", .{metadata_val.object.map.count()});
    std.debug.print("    type = \"{s}\"\n", .{metadata_val.object.get("type").?.string});
    std.debug.print("    size = {}\n", .{metadata_val.object.get("size").?.integer});

    lua.c.lua_pop(wrapper.state, 1);

    // Test 5: UserData
    std.debug.print("\n5. UserData conversion:\n", .{});

    const test_data: i32 = 12345;
    lua.c.lua_pushlightuserdata(wrapper.state, @ptrCast(@constCast(&test_data)));

    var ud_val = try pullScriptValue(wrapper, -1, allocator);
    defer ud_val.deinit(allocator);

    std.debug.print("  ✓ Pulled userdata - type: {s}\n", .{ud_val.userdata.type_id});
    std.debug.print("  Pointer valid: {}\n", .{ud_val.userdata.ptr != null});

    // Verify data (careful with pointer casting)
    const data_ptr: *i32 = @ptrCast(@alignCast(ud_val.userdata.ptr));
    std.debug.print("  Original data: {}, Retrieved data: {}\n", .{ test_data, data_ptr.* });

    lua.c.lua_pop(wrapper.state, 1);

    // Test 6: Type detection and edge cases
    std.debug.print("\n6. Type detection and edge cases:\n", .{});

    // Empty table (should be detected as array)
    lua.c.lua_createtable(wrapper.state, 0, 0);
    var empty_table = try pullScriptValue(wrapper, -1, allocator);
    defer empty_table.deinit(allocator);
    std.debug.print("  ✓ Empty table detected as: {s} with {} elements\n", .{ @tagName(empty_table), if (empty_table == .array) empty_table.array.items.len else empty_table.object.map.count() });
    lua.c.lua_pop(wrapper.state, 1);

    // Mixed table (should be detected as object)
    lua.c.lua_createtable(wrapper.state, 0, 0);
    lua.c.lua_pushinteger(wrapper.state, 10);
    lua.c.lua_seti(wrapper.state, -2, 1); // [1] = 10
    lua.c.lua_pushliteral(wrapper.state, "name");
    lua.c.lua_pushliteral(wrapper.state, "value");
    lua.c.lua_settable(wrapper.state, -3); // name = "value"

    var mixed_table = try pullScriptValue(wrapper, -1, allocator);
    defer mixed_table.deinit(allocator);
    std.debug.print("  ✓ Mixed table detected as: {s} with {} fields\n", .{ @tagName(mixed_table), mixed_table.object.map.count() });
    lua.c.lua_pop(wrapper.state, 1);

    // Large integer that might be stored as number in Lua
    const large_int: lua.c.lua_Integer = 9007199254740991; // Max safe integer in JavaScript
    lua.c.lua_pushinteger(wrapper.state, large_int);
    var large_int_val = try pullScriptValue(wrapper.state, -1, allocator);
    defer large_int_val.deinit(allocator);
    std.debug.print("  ✓ Large integer preserved as: {s} with value: {}\n", .{ @tagName(large_int_val), if (large_int_val == .integer) large_int_val.integer else @as(i64, @intFromFloat(large_int_val.number)) });
    lua.c.lua_pop(wrapper.state, 1);

    // Function (should return nil for now)
    _ = lua.c.luaL_loadstring(wrapper.state, "return function() return 42 end");
    _ = lua.c.lua_pcall(wrapper.state, 0, 1, 0);
    var func_val = try pullScriptValue(wrapper.state, -1, allocator);
    defer func_val.deinit(allocator);
    std.debug.print("  ✓ Function converted to: {s} (placeholder)\n", .{@tagName(func_val)});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 7: Round-trip conversion verification
    std.debug.print("\n7. Round-trip conversion verification:\n", .{});

    // Execute Lua code that creates various data types
    const lua_code =
        \\return {
        \\  nil_val = nil,
        \\  bool_val = true,
        \\  int_val = 42,
        \\  num_val = 3.14159,
        \\  str_val = "Hello, World!",
        \\  array_val = {1, 2, 3, "four", true},
        \\  obj_val = {
        \\    name = "test",
        \\    count = 10,
        \\    nested = {a = 1, b = 2}
        \\  }
        \\}
    ;

    _ = lua.c.luaL_loadstring(wrapper.state, lua_code.ptr);
    const result = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result == lua.c.LUA_OK) {
        var lua_data = try pullScriptValue(wrapper.state, -1, allocator);
        defer lua_data.deinit(allocator);

        std.debug.print("  ✓ Successfully pulled complex Lua data structure\n", .{});
        std.debug.print("  Root object fields: {}\n", .{lua_data.object.map.count()});

        // Verify specific fields
        const array_field = lua_data.object.get("array_val").?;
        std.debug.print("  Array field length: {}\n", .{array_field.array.items.len});

        const obj_field = lua_data.object.get("obj_val").?;
        const nested_field = obj_field.object.get("nested").?;
        std.debug.print("  Nested object fields: {}\n", .{nested_field.object.map.count()});

        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Failed to execute Lua code\n", .{});
        lua.c.lua_pop(wrapper.state, 1); // Pop error message
    }

    // Test 8: Stack verification
    std.debug.print("\n8. Stack verification:\n", .{});
    const initial_stack = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Final stack level: {} (should be 0)\n", .{initial_stack});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey functionality demonstrated:\n", .{});
    std.debug.print("- lua_type() for type detection\n", .{});
    std.debug.print("- lua_toboolean() for ScriptValue.boolean\n", .{});
    std.debug.print("- lua_isinteger() + lua_tointeger() for ScriptValue.integer\n", .{});
    std.debug.print("- lua_tonumber() for ScriptValue.number\n", .{});
    std.debug.print("- lua_tolstring() for ScriptValue.string\n", .{});
    std.debug.print("- lua_next() iteration for table conversion\n", .{});
    std.debug.print("- luaL_len() + lua_geti() for array detection and conversion\n", .{});
    std.debug.print("- lua_touserdata() for ScriptValue.userdata\n", .{});
    std.debug.print("- Recursive conversion for nested structures\n", .{});
    std.debug.print("- Automatic array vs object detection\n", .{});
    std.debug.print("- Proper memory management and cleanup\n", .{});
}
