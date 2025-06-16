// ABOUTME: Lua C function wrappers for Schema Bridge API
// ABOUTME: Provides Lua access to JSON schema validation and generation

const std = @import("std");
const lua = @import("../../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../context.zig").ScriptContext;
const LuaValueConverter = @import("../lua_value_converter.zig");
const LuaAPIBridge = @import("../lua_api_bridge.zig");

// Import the actual schema bridge implementation
const SchemaBridge = @import("../../api_bridges/schema_bridge.zig").SchemaBridge;

// Import zig_llms schema API
const schema = @import("../../../schema.zig");

/// Number of functions in this bridge
pub const FUNCTION_COUNT = 8;

/// Schema bridge errors specific to Lua integration
pub const LuaSchemaError = error{
    InvalidSchema,
    SchemaNotFound,
    InvalidDefinition,
    ExecutionFailed,
} || LuaAPIBridge.LuaAPIBridgeError;

/// Register all schema bridge functions with Lua
pub fn register(wrapper: *LuaWrapper, context: *ScriptContext) LuaAPIBridge.LuaAPIBridgeError!void {
    LuaAPIBridge.setScriptContext(wrapper.state, context);
    LuaAPIBridge.presizeStack(wrapper, FUNCTION_COUNT + 5);

    const functions = [_]struct { name: []const u8, func: lua.c.lua_CFunction }{
        .{ .name = "validate", .func = luaSchemaValidate },
        .{ .name = "generate", .func = luaSchemaGenerate },
        .{ .name = "coerce", .func = luaSchemaCoerce },
        .{ .name = "extract", .func = luaSchemaExtract },
        .{ .name = "merge", .func = luaSchemaMerge },
        .{ .name = "create", .func = luaSchemaCreate },
        .{ .name = "compile", .func = luaSchemaCompile },
        .{ .name = "get_info", .func = luaSchemaGetInfo },
    };

    for (functions) |func| {
        lua.c.lua_pushcfunction(wrapper.state, func.func);
        lua.c.lua_setfield(wrapper.state, -2, func.name.ptr);
    }

    addConstants(wrapper.state);
    std.log.debug("Registered {} schema bridge functions", .{functions.len});
}

pub fn cleanup() void {
    std.log.debug("Cleaning up schema bridge resources");
}

fn addConstants(L: ?*lua.c.lua_State) void {
    // Type constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "object");
    lua.c.lua_setfield(L, -2, "OBJECT");
    lua.c.lua_pushstring(L, "array");
    lua.c.lua_setfield(L, -2, "ARRAY");
    lua.c.lua_pushstring(L, "string");
    lua.c.lua_setfield(L, -2, "STRING");
    lua.c.lua_pushstring(L, "number");
    lua.c.lua_setfield(L, -2, "NUMBER");
    lua.c.lua_pushstring(L, "boolean");
    lua.c.lua_setfield(L, -2, "BOOLEAN");
    lua.c.lua_pushstring(L, "null");
    lua.c.lua_setfield(L, -2, "NULL");

    lua.c.lua_setfield(L, -2, "Type");

    // Format constants
    lua.c.lua_newtable(L);

    lua.c.lua_pushstring(L, "email");
    lua.c.lua_setfield(L, -2, "EMAIL");
    lua.c.lua_pushstring(L, "uri");
    lua.c.lua_setfield(L, -2, "URI");
    lua.c.lua_pushstring(L, "date");
    lua.c.lua_setfield(L, -2, "DATE");
    lua.c.lua_pushstring(L, "uuid");
    lua.c.lua_setfield(L, -2, "UUID");

    lua.c.lua_setfield(L, -2, "Format");
}

// Lua C Function Implementations

/// zigllms.schema.validate(data, schema) -> validation_result
export fn luaSchemaValidate(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.validate(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.generate(example_data) -> schema
export fn luaSchemaGenerate(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.generate(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.coerce(data, schema) -> coerced_data
export fn luaSchemaCoerce(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.coerce(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.extract(data, schema) -> extracted_data
export fn luaSchemaExtract(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.extract(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.merge(schema1, schema2) -> merged_schema
export fn luaSchemaMerge(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.merge(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.create(definition) -> schema
export fn luaSchemaCreate(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.create(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.compile(schema_source) -> compiled_schema
export fn luaSchemaCompile(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.compile(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}

/// zigllms.schema.get_info(schema) -> schema_info
export fn luaSchemaGetInfo(L: ?*lua.c.lua_State) c_int {
    const context = LuaAPIBridge.getScriptContext(L) orelse {
        return LuaAPIBridge.handleBridgeError(L, LuaAPIBridge.LuaAPIBridgeError.ScriptContextRequired);
    };

    // Convert arguments from Lua to ScriptValue
    const arg_count = lua.c.lua_gettop(L);
    var args = std.ArrayList(ScriptValue).init(context.allocator);
    defer {
        for (args.items) |*arg| {
            arg.deinit(context.allocator);
        }
        args.deinit();
    }

    for (0..@intCast(arg_count)) |i| {
        const arg_value = LuaValueConverter.pullScriptValue(context.allocator, L, @intCast(i + 1)) catch |err| {
            return LuaAPIBridge.handleBridgeError(L, err);
        };
        try args.append(arg_value);
    }

    // Call the bridge function
    const result = SchemaBridge.getinfo(context, args.items) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };
    defer result.deinit(context.allocator);

    // Convert result back to Lua
    LuaValueConverter.pushScriptValue(context.allocator, L, result) catch |err| {
        return LuaAPIBridge.handleBridgeError(L, err);
    };

    return 1;
}
