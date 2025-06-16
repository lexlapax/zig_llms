// ABOUTME: Demonstrates Lua function reference and callback functionality
// ABOUTME: Shows bidirectional function calls between Lua and Zig

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const ScriptContext = @import("zig_llms").scripting.context.ScriptContext;
const LuaFunctionBridge = @import("zig_llms").scripting.engines.lua_function_bridge.LuaFunctionBridge;
const pullScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pullScriptValue;
const pushScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pushScriptValue;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Function Bridge Demo ===\n\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create a script context
    var context = ScriptContext{
        .name = "demo_context",
        .allocator = allocator,
        .engine = undefined, // Would be properly set in real usage
    };

    // Initialize function bridge
    var bridge = LuaFunctionBridge.init(allocator, &context, wrapper);
    defer bridge.deinit();

    // Test 1: Register Zig functions to be called from Lua
    std.debug.print("1. Registering Zig functions for Lua:\n", .{});

    // Simple arithmetic function
    const addFunction = struct {
        fn call(ctx: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue {
            _ = ctx;
            if (args.len != 2) return ScriptValue.nil;

            if (args[0] == .integer and args[1] == .integer) {
                return ScriptValue{ .integer = args[0].integer + args[1].integer };
            } else if (args[0] == .number and args[1] == .number) {
                return ScriptValue{ .number = args[0].number + args[1].number };
            } else if (args[0] == .integer and args[1] == .number) {
                return ScriptValue{ .number = @as(f64, @floatFromInt(args[0].integer)) + args[1].number };
            } else if (args[0] == .number and args[1] == .integer) {
                return ScriptValue{ .number = args[0].number + @as(f64, @floatFromInt(args[1].integer)) };
            }

            return ScriptValue.nil;
        }
    }.call;

    try bridge.registerZigFunction("add", addFunction, 2);
    std.debug.print("  ✓ Registered 'add' function\n", .{});

    // String manipulation function
    const concatFunction = struct {
        fn call(ctx: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue {
            if (args.len == 0) return ScriptValue{ .string = try ctx.allocator.dupe(u8, "") };

            var result = std.ArrayList(u8).init(ctx.allocator);
            defer result.deinit();

            for (args) |arg| {
                switch (arg) {
                    .string => |s| try result.appendSlice(s),
                    .integer => |i| {
                        const str = try std.fmt.allocPrint(ctx.allocator, "{}", .{i});
                        defer ctx.allocator.free(str);
                        try result.appendSlice(str);
                    },
                    .number => |n| {
                        const str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{n});
                        defer ctx.allocator.free(str);
                        try result.appendSlice(str);
                    },
                    .boolean => |b| try result.appendSlice(if (b) "true" else "false"),
                    else => try result.appendSlice("[object]"),
                }
            }

            return ScriptValue{ .string = try result.toOwnedSlice() };
        }
    }.call;

    try bridge.registerZigFunction("concat", concatFunction, null); // Variadic
    std.debug.print("  ✓ Registered 'concat' function (variadic)\n", .{});

    // Test 2: Call Zig functions from Lua
    std.debug.print("\n2. Calling Zig functions from Lua:\n", .{});

    // Test arithmetic
    const lua_code1 = "return add(15, 27)";
    _ = lua.c.luaL_loadstring(wrapper.state, lua_code1.ptr);
    var result1 = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result1 == lua.c.LUA_OK) {
        const lua_result = lua.c.lua_tointeger(wrapper.state, -1);
        std.debug.print("  add(15, 27) = {}\n", .{lua_result});
        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Failed to call add function\n", .{});
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test string concatenation
    const lua_code2 = "return concat('Hello, ', 'World!', ' The answer is ', 42)";
    _ = lua.c.luaL_loadstring(wrapper.state, lua_code2.ptr);
    result1 = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result1 == lua.c.LUA_OK) {
        var len: usize = 0;
        const lua_str = lua.c.lua_tolstring(wrapper.state, -1, &len);
        std.debug.print("  concat result: \"{s}\"\n", .{lua_str.?[0..len]});
        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Failed to call concat function\n", .{});
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 3: Create Lua function references
    std.debug.print("\n3. Creating Lua function references:\n", .{});

    // Define a Lua function
    const lua_function_def =
        \\function multiply(x, y)
        \\    return x * y
        \\end
        \\return multiply
    ;

    _ = lua.c.luaL_loadstring(wrapper.state, lua_function_def.ptr);
    result1 = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result1 == lua.c.LUA_OK) {
        // Create ScriptFunction from Lua function
        var script_func = try bridge.createScriptFunction(-1);
        defer bridge.releaseScriptFunction(script_func);

        std.debug.print("  ✓ Created ScriptFunction from Lua function\n", .{});

        // Test calling the Lua function from Zig
        const args = [_]ScriptValue{
            ScriptValue{ .integer = 6 },
            ScriptValue{ .integer = 9 },
        };

        var call_result = try script_func.call(&args);
        defer call_result.deinit(allocator);

        std.debug.print("  multiply(6, 9) = {}\n", .{call_result.integer});

        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Failed to create Lua function\n", .{});
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 4: Complex function interaction
    std.debug.print("\n4. Complex function interactions:\n", .{});

    // Create a Lua function that calls back to Zig functions
    const complex_lua_code =
        \\function complex_operation(a, b, c)
        \\    local sum = add(a, b)
        \\    local product = sum * c
        \\    local message = concat("Result: ", product, " (from ", a, " + ", b, " = ", sum, " * ", c, ")")
        \\    return product, message
        \\end
        \\return complex_operation
    ;

    _ = lua.c.luaL_loadstring(wrapper.state, complex_lua_code.ptr);
    result1 = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result1 == lua.c.LUA_OK) {
        var complex_func = try bridge.createScriptFunction(-1);
        defer bridge.releaseScriptFunction(complex_func);

        std.debug.print("  ✓ Created complex Lua function\n", .{});

        // Call with multiple arguments
        const complex_args = [_]ScriptValue{
            ScriptValue{ .integer = 5 },
            ScriptValue{ .integer = 3 },
            ScriptValue{ .integer = 4 },
        };

        var complex_result = try complex_func.call(&complex_args);
        defer complex_result.deinit(allocator);

        std.debug.print("  complex_operation(5, 3, 4) returned: {s}\n", .{@tagName(complex_result)});

        // In a real implementation, we'd handle multiple return values
        // For now, we get the first return value
        if (complex_result == .integer) {
            std.debug.print("  Result value: {}\n", .{complex_result.integer});
        }

        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Failed to create complex function\n", .{});
        const error_msg = lua.c.lua_tostring(wrapper.state, -1);
        if (error_msg) |msg| {
            std.debug.print("  Error: {s}\n", .{std.mem.span(msg)});
        }
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 5: Error handling
    std.debug.print("\n5. Error handling:\n", .{});

    // Define a function that can cause errors
    const errorFunction = struct {
        fn call(ctx: *ScriptContext, args: []const ScriptValue) anyerror!ScriptValue {
            _ = ctx;
            if (args.len == 0) return error.InvalidArguments;

            if (args[0] == .integer and args[0].integer == 0) {
                return error.DivisionByZero;
            }

            if (args[0] == .integer) {
                return ScriptValue{ .integer = 100 / args[0].integer };
            }

            return ScriptValue.nil;
        }
    }.call;

    try bridge.registerZigFunction("divide100", errorFunction, 1);
    std.debug.print("  ✓ Registered error-prone function\n", .{});

    // Test normal operation
    const normal_test = "return divide100(5)";
    _ = lua.c.luaL_loadstring(wrapper.state, normal_test.ptr);
    result1 = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result1 == lua.c.LUA_OK) {
        const normal_result = lua.c.lua_tointeger(wrapper.state, -1);
        std.debug.print("  divide100(5) = {}\n", .{normal_result});
        lua.c.lua_pop(wrapper.state, 1);
    } else {
        std.debug.print("  ✗ Normal operation failed\n", .{});
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test error condition
    const error_test = "return divide100(0)";
    _ = lua.c.luaL_loadstring(wrapper.state, error_test.ptr);
    result1 = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (result1 == lua.c.LUA_OK) {
        std.debug.print("  ✗ Error test should have failed\n", .{});
        lua.c.lua_pop(wrapper.state, 1);
    } else {
        const error_msg = lua.c.lua_tostring(wrapper.state, -1);
        if (error_msg) |msg| {
            std.debug.print("  ✓ Error correctly caught: {s}\n", .{std.mem.span(msg)});
        }
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 6: Function type detection
    std.debug.print("\n6. Function type detection:\n", .{});

    // Create a C function
    const lua_c_function = "return type";
    _ = lua.c.luaL_loadstring(wrapper.state, lua_c_function.ptr);
    _ = lua.c.lua_pcall(wrapper.state, 0, 1, 0);

    if (lua.c.lua_type(wrapper.state, -1) == lua.c.LUA_TFUNCTION) {
        var c_func = try bridge.createScriptFunction(-1);
        defer bridge.releaseScriptFunction(c_func);

        // Get function info (this would work with a real LuaFunctionRef)
        std.debug.print("  ✓ Created function reference for C function\n", .{});

        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 7: Memory management verification
    std.debug.print("\n7. Memory management verification:\n", .{});

    const initial_stack = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Final stack level: {} (should be 0)\n", .{initial_stack});

    // Force garbage collection
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);
    const lua_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
    std.debug.print("  Lua memory usage: {} KB\n", .{lua_memory});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey functionality demonstrated:\n", .{});
    std.debug.print("- Registering Zig functions to be callable from Lua\n", .{});
    std.debug.print("- Creating function references from Lua functions\n", .{});
    std.debug.print("- Bidirectional function calls with argument conversion\n", .{});
    std.debug.print("- Error handling in cross-language function calls\n", .{});
    std.debug.print("- Complex function interactions and composition\n", .{});
    std.debug.print("- Memory management and resource cleanup\n", .{});
    std.debug.print("- Function type detection and introspection\n", .{});
}
