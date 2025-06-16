// ABOUTME: Demonstrates comprehensive nil/null handling in Lua integration
// ABOUTME: Shows consistent nil semantics across contexts and conversion scenarios

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const NilHandler = @import("zig_llms").scripting.engines.lua_nil_handling.NilHandler;
const NilContext = @import("zig_llms").scripting.engines.lua_nil_handling.NilContext;
const pullScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pullScriptValue;
const pushScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pushScriptValue;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Denable-lua=true\\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Nil/Null Handling Demo ===\\n\\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Test 1: Basic nil operations
    std.debug.print("1. Basic nil operations:\\n", .{});

    // Create nil ScriptValue
    const nil_script_value = NilHandler.createNilScriptValue();
    std.debug.print("  ✓ Created nil ScriptValue: {s}\\n", .{@tagName(nil_script_value)});

    // Check if it's nil
    const is_nil = NilHandler.isScriptValueNil(nil_script_value);
    std.debug.print("  ✓ Is ScriptValue nil: {}\\n", .{is_nil});

    // Push nil to Lua
    NilHandler.pushNil(wrapper);
    std.debug.print("  ✓ Pushed nil to Lua stack\\n", .{});

    // Check if Lua value is nil
    const lua_is_nil = NilHandler.isNil(wrapper, -1);
    std.debug.print("  ✓ Lua stack top is nil: {}\\n", .{lua_is_nil});

    lua.c.lua_pop(wrapper.state, 1);

    // Test 2: Nil validation
    std.debug.print("\\n2. Nil handling validation:\\n", .{});

    const validation = try NilHandler.validateNilConsistency(wrapper);

    std.debug.print("  Lua nil pushable: {}\\n", .{validation.lua_nil_pushable});
    std.debug.print("  Lua nil detectable: {}\\n", .{validation.lua_nil_detectable});
    std.debug.print("  ScriptValue nil convertible: {}\\n", .{validation.script_value_nil_convertible});
    std.debug.print("  Round-trip consistent: {}\\n", .{validation.round_trip_consistent});
    std.debug.print("  ✓ Overall nil handling working: {}\\n", .{validation.isFullyWorking()});

    if (!validation.isFullyWorking()) {
        const issues = try validation.getIssues(allocator);
        defer allocator.free(issues);

        std.debug.print("  Issues found:\\n", .{});
        for (issues) |issue| {
            std.debug.print("    - {s}\\n", .{issue});
        }
    }

    // Test 3: Optional value handling
    std.debug.print("\\n3. Optional value handling:\\n", .{});

    const optional_null: ?i32 = null;
    const nil_from_null = NilHandler.handleOptional(i32, optional_null);
    std.debug.print("  ✓ null optional converted to: {s}\\n", .{@tagName(nil_from_null)});

    const optional_with_value: ?i32 = 42;
    const value_from_optional = NilHandler.handleOptional(i32, optional_with_value);
    std.debug.print("  ✓ optional with value converted to: {s} = {}\\n", .{ @tagName(value_from_optional), value_from_optional.integer });

    const optional_string: ?[]const u8 = null;
    const nil_string = NilHandler.handleOptional([]const u8, optional_string);
    std.debug.print("  ✓ null string optional converted to: {s}\\n", .{@tagName(nil_string)});

    // Test 4: Context-sensitive nil detection
    std.debug.print("\\n4. Context-sensitive nil detection:\\n", .{});

    const test_values = [_]ScriptValue{
        ScriptValue.nil,
        ScriptValue{ .boolean = false },
        ScriptValue{ .integer = 0 },
        ScriptValue{ .number = 0.0 },
        ScriptValue{ .string = "" },
        ScriptValue{ .string = "hello" },
        ScriptValue{ .integer = 42 },
        ScriptValue{ .boolean = true },
    };

    const contexts = [_]struct { name: []const u8, context: NilContext }{
        .{ .name = "strict", .context = .strict },
        .{ .name = "lenient", .context = .lenient },
        .{ .name = "javascript_like", .context = .javascript_like },
    };

    for (contexts) |ctx| {
        std.debug.print("  {s} context:\\n", .{ctx.name});
        for (test_values) |value| {
            const should_be_nil = NilHandler.shouldTreatAsNil(value, ctx.context);
            const value_desc = switch (value) {
                .nil => "nil",
                .boolean => |b| if (b) "true" else "false",
                .integer => |i| if (i == 0) "0 (int)" else "42 (int)",
                .number => |n| if (n == 0.0) "0.0 (float)" else "3.14 (float)",
                .string => |s| if (s.len == 0) "\\\"\\\" (empty)" else "\\\"hello\\\"",
                else => "other",
            };
            std.debug.print("    {s:15} -> nil: {}\\n", .{ value_desc, should_be_nil });
        }
        std.debug.print("\\n", .{});
    }

    // Test 5: Lua to ScriptValue nil conversion
    std.debug.print("5. Lua ↔ ScriptValue nil conversion:\\n", .{});

    // Push various Lua values and convert them
    const lua_test_cases = [_]struct { desc: []const u8, lua_code: []const u8 }{
        .{ .desc = "nil literal", .lua_code = "return nil" },
        .{ .desc = "undefined global", .lua_code = "return undefined_global_var" },
        .{ .desc = "function returning nil", .lua_code = "return function() end()" },
    };

    for (lua_test_cases) |test_case| {
        _ = lua.c.luaL_loadstring(wrapper.state, test_case.lua_code.ptr);
        const result = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

        if (result == lua.c.LUA_OK) {
            var converted_value = try pullScriptValue(wrapper, -1, allocator);
            defer converted_value.deinit(allocator);

            std.debug.print("  {s}: {s}\\n", .{ test_case.desc, @tagName(converted_value) });
            lua.c.lua_pop(wrapper.state, 1);
        } else {
            std.debug.print("  {s}: execution failed\\n", .{test_case.desc});
            lua.c.lua_pop(wrapper.state, 1);
        }
    }

    // Test 6: ScriptValue to Lua nil conversion
    std.debug.print("\\n6. ScriptValue → Lua nil conversion:\\n", .{});

    const script_values_to_test = [_]ScriptValue{
        ScriptValue.nil,
        ScriptValue{ .boolean = false },
        ScriptValue{ .integer = 0 },
        ScriptValue{ .string = "" },
    };

    for (script_values_to_test) |value| {
        try pushScriptValue(wrapper, value);
        const lua_type = lua.c.lua_type(wrapper.state, -1);
        const type_name = lua.c.lua_typename(wrapper.state, lua_type);

        std.debug.print("  {s} → Lua {s}\\n", .{ @tagName(value), std.mem.span(type_name.?) });
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 7: Round-trip nil conversion
    std.debug.print("\\n7. Round-trip nil conversion:\\n", .{});

    // ScriptValue.nil → Lua → ScriptValue
    try pushScriptValue(wrapper, ScriptValue.nil);
    var round_trip_value = try pullScriptValue(wrapper, -1, allocator);
    defer round_trip_value.deinit(allocator);

    const round_trip_success = round_trip_value == .nil;
    std.debug.print("  ScriptValue.nil → Lua → ScriptValue: {}\\n", .{round_trip_success});
    lua.c.lua_pop(wrapper.state, 1);

    // Test 8: Nil in complex structures
    std.debug.print("\\n8. Nil in complex structures:\\n", .{});

    // Create Lua table with nil values
    const complex_lua_code =
        \\\\return {
        \\\\  explicit_nil = nil,
        \\\\  array_with_holes = {1, nil, 3, nil, 5},
        \\\\  object_with_nil = {
        \\\\    name = "test",
        \\\\    value = nil,
        \\\\    count = 0
        \\\\  }
        \\\\}
    ;

    _ = lua.c.luaL_loadstring(wrapper.state, complex_lua_code.ptr);
    const complex_result = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (complex_result == lua.c.LUA_OK) {
        var complex_value = try pullScriptValue(wrapper, -1, allocator);
        defer complex_value.deinit(allocator);

        std.debug.print("  ✓ Successfully converted complex structure with nils\\n", .{});
        std.debug.print("  Root type: {s}\\n", .{@tagName(complex_value)});

        if (complex_value == .object) {
            const explicit_nil = complex_value.object.get("explicit_nil");
            std.debug.print("  explicit_nil field: {s}\\n", .{if (explicit_nil) |val| @tagName(val) else "missing"});

            const array_field = complex_value.object.get("array_with_holes");
            if (array_field) |arr_val| {
                if (arr_val == .array) {
                    std.debug.print("  array_with_holes length: {}\\n", .{arr_val.array.items.len});
                    for (arr_val.array.items, 0..) |item, i| {
                        std.debug.print("    [{}]: {s}\\n", .{ i + 1, @tagName(item) });
                    }
                }
            }
        }

        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Failed to execute complex Lua code\\n", .{});
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 9: Nil error handling
    std.debug.print("\\n9. Nil error handling:\\n", .{});

    // Test error when trying to convert non-nil to nil
    lua.c.lua_pushinteger(wrapper.state, 42);
    const nil_conversion_result = NilHandler.luaNilToScriptValue(wrapper, -1);

    if (nil_conversion_result) |_| {
        std.debug.print("  ✗ Should have failed to convert integer to nil\\n", .{});
    } else |err| {
        std.debug.print("  ✓ Correctly failed to convert non-nil value: {}\\n", .{err});
    }
    lua.c.lua_pop(wrapper.state, 1);

    // Test error when trying to push non-nil as nil
    const non_nil_value = ScriptValue{ .integer = 42 };
    const push_result = NilHandler.scriptValueNilToLua(wrapper, non_nil_value);

    if (push_result) {
        std.debug.print("  ✗ Should have failed to push non-nil as nil\\n", .{});
    } else |err| {
        std.debug.print("  ✓ Correctly failed to push non-nil value: {}\\n", .{err});
    }

    // Test 10: Memory and stack verification
    std.debug.print("\\n10. Memory and stack verification:\\n", .{});

    const final_stack = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Final stack level: {} (should be 0)\\n", .{final_stack});

    // Force garbage collection
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    const lua_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
    std.debug.print("  Lua memory usage: {} KB\\n", .{lua_memory});

    std.debug.print("\\n=== Demo Complete ===\\n", .{});
    std.debug.print("\\nKey nil/null handling features demonstrated:\\n", .{});
    std.debug.print("- Consistent nil semantics across Lua and ScriptValue\\n", .{});
    std.debug.print("- Context-sensitive nil detection (strict, lenient, JavaScript-like)\\n", .{});
    std.debug.print("- Proper optional value handling with automatic nil conversion\\n", .{});
    std.debug.print("- Round-trip nil conversion consistency validation\\n", .{});
    std.debug.print("- Nil handling in complex nested structures\\n", .{});
    std.debug.print("- Error handling for invalid nil conversions\\n", .{});
    std.debug.print("- Comprehensive nil validation and issue reporting\\n", .{});
    std.debug.print("- Memory-safe nil operations with proper cleanup\\n", .{});
}
