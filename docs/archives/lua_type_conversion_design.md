# Lua Type Conversion System Design

## Overview

This document designs the ScriptValue ↔ Lua type conversion system for the zig_llms Lua scripting engine. The system bridges between our universal ScriptValue type system and Lua's native type system via the Lua C API.

## Lua Type System Mapping

### Lua Basic Types → ScriptValue

| Lua Type | Lua API Check | ScriptValue Variant | Notes |
|----------|---------------|-------------------|-------|
| `nil` | `lua_isnil()` | `ScriptValue.nil` | Direct mapping |
| `boolean` | `lua_isboolean()` | `ScriptValue.boolean` | Direct mapping |
| `number` | `lua_isnumber()` | `ScriptValue.integer` or `ScriptValue.number` | Lua 5.4 distinguishes integers vs floats |
| `string` | `lua_isstring()` | `ScriptValue.string` | UTF-8 safe, needs length handling |
| `table` | `lua_istable()` | `ScriptValue.array` or `ScriptValue.object` | Determined by array-like structure |
| `function` | `lua_isfunction()` | `ScriptValue.function` | Lua function reference |
| `userdata` | `lua_isuserdata()` | `ScriptValue.userdata` | Full/light userdata |
| `thread` | `lua_isthread()` | `ScriptValue.userdata` | Coroutine as special userdata |

### ScriptValue → Lua Stack Operations

| ScriptValue Variant | Lua Push Function | Special Handling |
|-------------------|------------------|------------------|
| `ScriptValue.nil` | `lua_pushnil()` | Direct |
| `ScriptValue.boolean` | `lua_pushboolean()` | Direct |
| `ScriptValue.integer` | `lua_pushinteger()` | Direct |
| `ScriptValue.number` | `lua_pushnumber()` | Direct |
| `ScriptValue.string` | `lua_pushlstring()` | Length-safe |
| `ScriptValue.array` | Table construction | Recursive conversion |
| `ScriptValue.object` | Table construction | Key-value mapping |
| `ScriptValue.function` | Function reference | Registry lookup |
| `ScriptValue.userdata` | `lua_pushlightuserdata()` | Type-checked casting |

## Conversion Architecture

### Core Conversion Interface

```zig
const LuaConverter = struct {
    const Self = @This();
    
    // Core conversion functions
    pub fn scriptValueToLua(state: *LuaState, value: ScriptValue) !void;
    pub fn luaToScriptValue(state: *LuaState, index: i32, allocator: std.mem.Allocator) !ScriptValue;
    
    // Specialized conversions
    pub fn pushScriptArray(state: *LuaState, array: ScriptValue.Array) !void;
    pub fn pushScriptObject(state: *LuaState, object: ScriptValue.Object) !void;
    pub fn pullLuaTable(state: *LuaState, index: i32, allocator: std.mem.Allocator) !ScriptValue;
    
    // Function handling
    pub fn registerScriptFunction(state: *LuaState, function: *ScriptFunction) !LuaFunctionRef;
    pub fn callLuaFunction(state: *LuaState, func_ref: LuaFunctionRef, args: []const ScriptValue, allocator: std.mem.Allocator) ![]ScriptValue;
    
    // Userdata management
    pub fn pushUserData(state: *LuaState, userdata: ScriptValue.UserData) !void;
    pub fn pullUserData(state: *LuaState, index: i32) !ScriptValue.UserData;
};
```

### Stack Management Strategy

```zig
const LuaStackGuard = struct {
    state: *LuaState,
    initial_top: i32,
    
    pub fn init(state: *LuaState) LuaStackGuard {
        return LuaStackGuard{
            .state = state,
            .initial_top = c.lua_gettop(state.state),
        };
    }
    
    pub fn deinit(self: *LuaStackGuard) void {
        c.lua_settop(self.state.state, self.initial_top);
    }
    
    pub fn check(self: LuaStackGuard, expected_change: i32) bool {
        const current_top = c.lua_gettop(self.state.state);
        return current_top == self.initial_top + expected_change;
    }
};
```

## Detailed Conversion Logic

### 1. ScriptValue → Lua Stack

```zig
pub fn scriptValueToLua(state: *LuaState, value: ScriptValue) !void {
    switch (value) {
        .nil => c.lua_pushnil(state.state),
        .boolean => |b| c.lua_pushboolean(state.state, if (b) 1 else 0),
        .integer => |i| c.lua_pushinteger(state.state, i),
        .number => |n| c.lua_pushnumber(state.state, n),
        .string => |s| c.lua_pushlstring(state.state, s.ptr, s.len),
        .array => |arr| try pushScriptArray(state, arr),
        .object => |obj| try pushScriptObject(state, obj),
        .function => |func| try pushScriptFunction(state, func),
        .userdata => |ud| try pushUserData(state, ud),
    }
}

fn pushScriptArray(state: *LuaState, array: ScriptValue.Array) !void {
    c.lua_createtable(state.state, @intCast(array.items.len), 0);
    
    for (array.items, 1..) |item, i| {
        try scriptValueToLua(state, item);
        c.lua_rawseti(state.state, -2, @intCast(i));
    }
}

fn pushScriptObject(state: *LuaState, object: ScriptValue.Object) !void {
    c.lua_createtable(state.state, 0, @intCast(object.map.count()));
    
    var iter = object.map.iterator();
    while (iter.next()) |entry| {
        // Push key
        c.lua_pushlstring(state.state, entry.key_ptr.*.ptr, entry.key_ptr.*.len);
        // Push value
        try scriptValueToLua(state, entry.value_ptr.*);
        // Set table[key] = value
        c.lua_rawset(state.state, -3);
    }
}
```

### 2. Lua Stack → ScriptValue

```zig
pub fn luaToScriptValue(state: *LuaState, index: i32, allocator: std.mem.Allocator) !ScriptValue {
    const lua_type = c.lua_type(state.state, index);
    
    return switch (lua_type) {
        c.LUA_TNIL => ScriptValue.nil,
        c.LUA_TBOOLEAN => ScriptValue{ .boolean = c.lua_toboolean(state.state, index) != 0 },
        c.LUA_TNUMBER => blk: {
            if (c.lua_isinteger(state.state, index) != 0) {
                break :blk ScriptValue{ .integer = c.lua_tointeger(state.state, index) };
            } else {
                break :blk ScriptValue{ .number = c.lua_tonumber(state.state, index) };
            }
        },
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const str_ptr = c.lua_tolstring(state.state, index, &len);
            const str = try allocator.dupe(u8, str_ptr[0..len]);
            break :blk ScriptValue{ .string = str };
        },
        c.LUA_TTABLE => try pullLuaTable(state, index, allocator),
        c.LUA_TFUNCTION => try pullLuaFunction(state, index),
        c.LUA_TUSERDATA => try pullUserData(state, index),
        c.LUA_TLIGHTUSERDATA => try pullLightUserData(state, index),
        c.LUA_TTHREAD => try pullLuaThread(state, index),
        else => error.UnsupportedLuaType,
    };
}
```

### 3. Table Conversion Strategy

```zig
fn pullLuaTable(state: *LuaState, index: i32, allocator: std.mem.Allocator) !ScriptValue {
    // First pass: determine if this is an array-like table
    const is_array = isArrayLikeTable(state, index);
    
    if (is_array) {
        return try pullLuaArray(state, index, allocator);
    } else {
        return try pullLuaObject(state, index, allocator);
    }
}

fn isArrayLikeTable(state: *LuaState, index: i32) bool {
    const len = c.lua_rawlen(state.state, index);
    if (len == 0) return false;
    
    // Check if all keys from 1 to len exist
    for (1..len + 1) |i| {
        c.lua_rawgeti(state.state, index, @intCast(i));
        const is_nil = c.lua_isnil(state.state, -1);
        c.lua_pop(state.state, 1);
        if (is_nil) return false;
    }
    
    // Check if there are any non-integer keys
    c.lua_pushnil(state.state);
    while (c.lua_next(state.state, index) != 0) {
        defer c.lua_pop(state.state, 1); // pop value
        
        if (c.lua_isinteger(state.state, -2) == 0) {
            c.lua_pop(state.state, 1); // pop key
            return false;
        }
        
        const key = c.lua_tointeger(state.state, -2);
        if (key < 1 or key > len) {
            c.lua_pop(state.state, 1); // pop key
            return false;
        }
    }
    
    return true;
}

fn pullLuaArray(state: *LuaState, index: i32, allocator: std.mem.Allocator) !ScriptValue {
    const len = c.lua_rawlen(state.state, index);
    var array = try ScriptValue.Array.init(allocator, len);
    
    for (1..len + 1) |i| {
        c.lua_rawgeti(state.state, index, @intCast(i));
        array.items[i - 1] = try luaToScriptValue(state, -1, allocator);
        c.lua_pop(state.state, 1);
    }
    
    return ScriptValue{ .array = array };
}

fn pullLuaObject(state: *LuaState, index: i32, allocator: std.mem.Allocator) !ScriptValue {
    var object = ScriptValue.Object.init(allocator);
    
    c.lua_pushnil(state.state);
    while (c.lua_next(state.state, index) != 0) {
        defer c.lua_pop(state.state, 1); // pop value
        
        // Convert key to string
        const key = try luaKeyToString(state, -2, allocator);
        defer allocator.free(key);
        
        // Convert value
        const value = try luaToScriptValue(state, -1, allocator);
        
        try object.put(key, value);
    }
    
    return ScriptValue{ .object = object };
}

fn luaKeyToString(state: *LuaState, index: i32, allocator: std.mem.Allocator) ![]u8 {
    const lua_type = c.lua_type(state.state, index);
    return switch (lua_type) {
        c.LUA_TSTRING => blk: {
            var len: usize = 0;
            const str_ptr = c.lua_tolstring(state.state, index, &len);
            break :blk try allocator.dupe(u8, str_ptr[0..len]);
        },
        c.LUA_TNUMBER => blk: {
            if (c.lua_isinteger(state.state, index) != 0) {
                const num = c.lua_tointeger(state.state, index);
                break :blk try std.fmt.allocPrint(allocator, "{}", .{num});
            } else {
                const num = c.lua_tonumber(state.state, index);
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{num});
            }
        },
        else => error.InvalidKeyType,
    };
}
```

## Function Reference Management

### Lua Function → ScriptFunction Bridge

```zig
const LuaFunctionRef = struct {
    registry_ref: i32,
    state: *LuaState,
    
    pub fn deinit(self: *LuaFunctionRef) void {
        c.luaL_unref(self.state.state, c.LUA_REGISTRYINDEX, self.registry_ref);
    }
};

const LuaScriptFunction = struct {
    ref: LuaFunctionRef,
    allocator: std.mem.Allocator,
    
    pub fn call(self: *LuaScriptFunction, args: []const ScriptValue) ![]ScriptValue {
        const guard = LuaStackGuard.init(self.ref.state);
        defer guard.deinit();
        
        // Push function onto stack
        c.lua_rawgeti(self.ref.state.state, c.LUA_REGISTRYINDEX, self.ref.registry_ref);
        
        // Push arguments
        for (args) |arg| {
            try scriptValueToLua(self.ref.state, arg);
        }
        
        // Call function
        const result = c.lua_pcall(self.ref.state.state, @intCast(args.len), c.LUA_MULTRET, 0);
        if (result != c.LUA_OK) {
            const error_msg = c.lua_tostring(self.ref.state.state, -1);
            c.lua_pop(self.ref.state.state, 1);
            return error.LuaFunctionCallFailed;
        }
        
        // Collect results
        const num_results = c.lua_gettop(self.ref.state.state) - guard.initial_top;
        var results = try self.allocator.alloc(ScriptValue, @intCast(num_results));
        
        for (0..@intCast(num_results)) |i| {
            const stack_index = guard.initial_top + 1 + @as(i32, @intCast(i));
            results[i] = try luaToScriptValue(self.ref.state, stack_index, self.allocator);
        }
        
        return results;
    }
};

fn pullLuaFunction(state: *LuaState, index: i32) !ScriptValue {
    // Create reference in registry
    c.lua_pushvalue(state.state, index);
    const registry_ref = c.luaL_ref(state.state, c.LUA_REGISTRYINDEX);
    
    const lua_func = try state.allocator.create(LuaScriptFunction);
    lua_func.* = LuaScriptFunction{
        .ref = LuaFunctionRef{
            .registry_ref = registry_ref,
            .state = state,
        },
        .allocator = state.allocator,
    };
    
    return ScriptValue{
        .function = @ptrCast(lua_func),
    };
}
```

## Userdata Integration

### Zig → Lua Userdata

```zig
const LuaUserDataInfo = struct {
    type_name: []const u8,
    metatable_name: []const u8,
    destructor: ?*const fn (ptr: *anyopaque) void = null,
};

fn pushUserData(state: *LuaState, userdata: ScriptValue.UserData) !void {
    // For simple pointers, use light userdata
    if (userdata.deinit_fn == null) {
        c.lua_pushlightuserdata(state.state, userdata.ptr);
        return;
    }
    
    // For complex data, create full userdata
    const ud_ptr = c.lua_newuserdata(state.state, @sizeOf(*anyopaque));
    @as(**anyopaque, @ptrCast(@alignCast(ud_ptr))).* = userdata.ptr;
    
    // Set metatable for type checking
    if (c.luaL_getmetatable(state.state, userdata.type_id.ptr) == c.LUA_TNIL) {
        c.lua_pop(state.state, 1); // pop nil
        // Create new metatable
        c.luaL_newmetatable(state.state, userdata.type_id.ptr);
        
        // Set __gc metamethod if destructor exists
        if (userdata.deinit_fn) |deinit_fn| {
            c.lua_pushcfunction(state.state, luaUserDataGC);
            c.lua_setfield(state.state, -2, "__gc");
        }
    }
    c.lua_setmetatable(state.state, -2);
}

fn luaUserDataGC(L: ?*c.lua_State) callconv(.C) i32 {
    const ptr_ptr = @as(**anyopaque, @ptrCast(@alignCast(c.lua_touserdata(L, 1))));
    const ptr = ptr_ptr.*;
    
    // Look up destructor (this would need a registry)
    // For now, we'll need to store the destructor with the userdata
    
    return 0;
}

fn pullUserData(state: *LuaState, index: i32) !ScriptValue.UserData {
    const ptr = c.lua_touserdata(state.state, index);
    
    // Determine if this is light userdata or full userdata
    if (c.lua_getmetatable(state.state, index) == 0) {
        // Light userdata - no metatable
        return ScriptValue.UserData{
            .ptr = ptr,
            .type_id = "unknown",
            .deinit_fn = null,
        };
    } else {
        // Full userdata - has metatable
        c.lua_pop(state.state, 1); // pop metatable
        
        const actual_ptr = @as(**anyopaque, @ptrCast(@alignCast(ptr))).*;
        return ScriptValue.UserData{
            .ptr = actual_ptr,
            .type_id = "lua_userdata", // Would need registry lookup for actual type
            .deinit_fn = null, // Managed by Lua GC
        };
    }
}
```

## Error Handling Strategy

### Conversion Errors

```zig
const LuaConversionError = error{
    UnsupportedLuaType,
    UnsupportedScriptValueType,
    InvalidKeyType,
    StackOverflow,
    StackUnderflow,
    LuaFunctionCallFailed,
    TypeMismatch,
    MemoryAllocationFailed,
};

fn handleConversionError(state: *LuaState, err: LuaConversionError) void {
    const error_msg = switch (err) {
        error.UnsupportedLuaType => "Unsupported Lua type in conversion",
        error.UnsupportedScriptValueType => "Unsupported ScriptValue type in conversion",
        error.InvalidKeyType => "Invalid key type for table conversion",
        error.StackOverflow => "Lua stack overflow during conversion",
        error.StackUnderflow => "Lua stack underflow during conversion",
        error.LuaFunctionCallFailed => "Lua function call failed",
        error.TypeMismatch => "Type mismatch in conversion",
        error.MemoryAllocationFailed => "Memory allocation failed during conversion",
    };
    
    c.lua_pushstring(state.state, error_msg.ptr);
    _ = c.lua_error(state.state); // Never returns
}
```

## Performance Optimizations

### 1. Stack Pre-sizing

```zig
fn ensureStackSpace(state: *LuaState, needed: i32) !void {
    if (c.lua_checkstack(state.state, needed) == 0) {
        return error.StackOverflow;
    }
}
```

### 2. Type Caching

```zig
const TypeCache = struct {
    string_to_scriptvalue: std.StringHashMap(ScriptValue),
    metatable_refs: std.StringHashMap(i32),
    
    pub fn init(allocator: std.mem.Allocator) TypeCache {
        return TypeCache{
            .string_to_scriptvalue = std.StringHashMap(ScriptValue).init(allocator),
            .metatable_refs = std.StringHashMap(i32).init(allocator),
        };
    }
    
    pub fn deinit(self: *TypeCache) void {
        self.string_to_scriptvalue.deinit();
        self.metatable_refs.deinit();
    }
};
```

### 3. Bulk Conversion

```zig
fn convertMultipleValues(state: *LuaState, start_index: i32, count: i32, allocator: std.mem.Allocator) ![]ScriptValue {
    var results = try allocator.alloc(ScriptValue, @intCast(count));
    errdefer allocator.free(results);
    
    for (0..@intCast(count)) |i| {
        const index = start_index + @as(i32, @intCast(i));
        results[i] = try luaToScriptValue(state, index, allocator);
    }
    
    return results;
}
```

## Integration with zig_llms Architecture

### 1. Engine Implementation Hook

```zig
const LuaEngine = struct {
    // ... other fields
    converter: LuaConverter,
    type_cache: TypeCache,
    
    pub fn executeScript(self: *LuaEngine, script: []const u8, context: *ScriptContext) !ScriptValue {
        // Load and execute script
        const result = try self.loadAndCallScript(script);
        
        // Convert result back to ScriptValue
        const guard = LuaStackGuard.init(&self.state);
        defer guard.deinit();
        
        return try self.converter.luaToScriptValue(&self.state, -1, context.allocator);
    }
    
    pub fn callFunction(self: *LuaEngine, name: []const u8, args: []const ScriptValue, context: *ScriptContext) !ScriptValue {
        const guard = LuaStackGuard.init(&self.state);
        defer guard.deinit();
        
        // Get function
        c.lua_getglobal(self.state.state, name.ptr);
        if (c.lua_isfunction(self.state.state, -1) == 0) {
            return error.FunctionNotFound;
        }
        
        // Push arguments
        for (args) |arg| {
            try self.converter.scriptValueToLua(&self.state, arg);
        }
        
        // Call function
        const result = c.lua_pcall(self.state.state, @intCast(args.len), 1, 0);
        if (result != c.LUA_OK) {
            return error.FunctionCallFailed;
        }
        
        return try self.converter.luaToScriptValue(&self.state, -1, context.allocator);
    }
};
```

### 2. API Bridge Integration

The conversion system integrates with all existing API bridges:

```zig
// In agent_bridge.zig
pub fn luaCreateAgent(L: ?*c.lua_State) callconv(.C) i32 {
    const state = getLuaState(L);
    
    // Convert Lua table to AgentConfig
    const config_value = luaToScriptValue(state, 1, state.allocator) catch {
        return luaError(L, "Failed to convert agent config");
    };
    defer config_value.deinit(state.allocator);
    
    const config = config_value.toZig(AgentConfig, state.allocator) catch {
        return luaError(L, "Invalid agent config");
    };
    
    // Create agent...
    const agent = createAgent(config) catch {
        return luaError(L, "Failed to create agent");
    };
    
    // Convert agent back to Lua userdata
    const agent_value = ScriptValue.fromZig(*Agent, agent, state.allocator) catch {
        return luaError(L, "Failed to convert agent");
    };
    
    scriptValueToLua(state, agent_value) catch {
        return luaError(L, "Failed to push agent to Lua");
    };
    
    return 1; // Number of return values
}
```

## Conclusion

This design provides a comprehensive, efficient, and safe type conversion system between ScriptValue and Lua types. Key features:

1. **Bidirectional Conversion**: Full support for converting in both directions
2. **Type Safety**: Proper type checking and error handling
3. **Memory Safety**: Careful memory management with RAII patterns
4. **Performance**: Stack guards, type caching, and bulk operations
5. **Integration**: Seamless integration with the existing zig_llms architecture
6. **Lua Idioms**: Respects Lua conventions for tables, functions, and userdata

The system maintains the universal nature of ScriptValue while providing efficient, native Lua integration for optimal performance and user experience.