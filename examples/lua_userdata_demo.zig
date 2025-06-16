// ABOUTME: Demonstrates Lua userdata system for complex Zig types
// ABOUTME: Shows type-safe userdata creation, access, and lifecycle management

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const ScriptValue = @import("zig_llms").scripting.value_bridge.ScriptValue;
const ScriptContext = @import("zig_llms").scripting.context.ScriptContext;
const UserdataSystem = @import("zig_llms").scripting.engines.lua_userdata_system;
const UserdataRegistry = UserdataSystem.UserdataRegistry;
const LuaUserdataManager = UserdataSystem.LuaUserdataManager;
const UserdataTypeInfo = UserdataSystem.UserdataTypeInfo;

// Example complex types
const Person = struct {
    name: [32]u8,
    age: u32,
    height: f32,
    is_active: bool,

    pub fn init(name: []const u8, age: u32, height: f32) Person {
        var p = Person{
            .name = std.mem.zeroes([32]u8),
            .age = age,
            .height = height,
            .is_active = true,
        };
        @memcpy(p.name[0..@min(name.len, 31)], name[0..@min(name.len, 31)]);
        return p;
    }

    pub fn getName(self: *const Person) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn setAge(self: *Person, new_age: u32) void {
        self.age = new_age;
    }

    pub fn destructor(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;
        const person: *Person = @ptrCast(@alignCast(ptr));
        std.debug.print("  [GC] Cleaning up person: {s}\\n", .{person.getName()});
    }
};

const Vector3 = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn magnitude(self: *const Vector3) f32 {
        return std.math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn normalize(self: *Vector3) void {
        const mag = self.magnitude();
        if (mag > 0) {
            self.x /= mag;
            self.y /= mag;
            self.z /= mag;
        }
    }

    pub fn dot(self: *const Vector3, other: *const Vector3) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }
};

// Metatable setup function for Person
fn setupPersonMetatable(wrapper: *lua.LuaWrapper, type_name: []const u8) !void {
    _ = type_name;

    // Add custom methods to the metatable
    lua.c.lua_pushcfunction(wrapper.state, personGetName);
    lua.c.lua_setfield(wrapper.state, -2, "getName");

    lua.c.lua_pushcfunction(wrapper.state, personSetAge);
    lua.c.lua_setfield(wrapper.state, -2, "setAge");

    lua.c.lua_pushcfunction(wrapper.state, personGetAge);
    lua.c.lua_setfield(wrapper.state, -2, "getAge");
}

// Lua C functions for Person methods
fn personGetName(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    // Get the person userdata
    const userdata_ptr = lua.c.luaL_checkudata(state, 1, "zig_llms.Person");
    if (userdata_ptr == null) {
        lua.c.lua_pushstring(state, "Invalid person userdata");
        return lua.c.lua_error(state);
    }

    // Extract the Person from our userdata format
    const header: *const UserdataSystem.UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
    if (header.magic != 0xDEADBEEF) {
        lua.c.lua_pushstring(state, "Invalid userdata header");
        return lua.c.lua_error(state);
    }

    const person: *const Person = @ptrCast(@alignCast(header.getData()));
    const name = person.getName();

    lua.c.lua_pushlstring(state, name.ptr, name.len);
    return 1;
}

fn personSetAge(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    // Get the person userdata
    const userdata_ptr = lua.c.luaL_checkudata(state, 1, "zig_llms.Person");
    if (userdata_ptr == null) {
        lua.c.lua_pushstring(state, "Invalid person userdata");
        return lua.c.lua_error(state);
    }

    // Get the new age
    const new_age = lua.c.luaL_checkinteger(state, 2);

    // Extract the Person from our userdata format
    const header: *const UserdataSystem.UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
    if (header.magic != 0xDEADBEEF) {
        lua.c.lua_pushstring(state, "Invalid userdata header");
        return lua.c.lua_error(state);
    }

    const person: *Person = @ptrCast(@alignCast(header.getData()));
    person.setAge(@intCast(new_age));

    return 0; // No return values
}

fn personGetAge(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    // Get the person userdata
    const userdata_ptr = lua.c.luaL_checkudata(state, 1, "zig_llms.Person");
    if (userdata_ptr == null) {
        lua.c.lua_pushstring(state, "Invalid person userdata");
        return lua.c.lua_error(state);
    }

    // Extract the Person from our userdata format
    const header: *const UserdataSystem.UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
    if (header.magic != 0xDEADBEEF) {
        lua.c.lua_pushstring(state, "Invalid userdata header");
        return lua.c.lua_error(state);
    }

    const person: *const Person = @ptrCast(@alignCast(header.getData()));

    lua.c.lua_pushinteger(state, @intCast(person.age));
    return 1;
}

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Denable-lua=true\\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Userdata System Demo ===\\n\\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    // Create userdata registry
    var registry = UserdataRegistry.init(allocator);
    defer registry.deinit();

    // Create userdata manager
    var manager = LuaUserdataManager.init(allocator, wrapper, &registry);

    // Test 1: Register types
    std.debug.print("1. Registering userdata types:\\n", .{});

    try registry.registerType(UserdataTypeInfo{
        .name = "Person",
        .size = @sizeOf(Person),
        .alignment = @alignOf(Person),
        .destructor = Person.destructor,
        .setup_metatable = setupPersonMetatable,
        .version = 1,
        .cacheable = true,
    });
    std.debug.print("  ✓ Registered Person type\\n", .{});

    try registry.registerType(UserdataTypeInfo{
        .name = "Vector3",
        .size = @sizeOf(Vector3),
        .alignment = @alignOf(Vector3),
        .destructor = null, // No special cleanup needed
        .setup_metatable = null, // No custom methods for now
        .version = 1,
        .cacheable = true,
    });
    std.debug.print("  ✓ Registered Vector3 type\\n", .{});

    // Register common types
    try UserdataSystem.registerCommonTypes(&registry);
    std.debug.print("  ✓ Registered common types\\n", .{});

    // Test 2: Create userdata instances
    std.debug.print("\\n2. Creating userdata instances:\\n", .{});

    // Create a Person
    const person1 = Person.init("Alice Johnson", 28, 165.5);
    const person_ptr = try manager.createUserdata(Person, person1, "Person");
    std.debug.print("  ✓ Created Person userdata: {s}, age {}, height {d}cm\\n", .{ person_ptr.getName(), person_ptr.age, person_ptr.height });

    // Create a Vector3
    const vector1 = Vector3{ .x = 1.0, .y = 2.0, .z = 3.0 };
    const vector_ptr = try manager.createUserdata(Vector3, vector1, "Vector3");
    std.debug.print("  ✓ Created Vector3 userdata: ({d}, {d}, {d})\\n", .{ vector_ptr.x, vector_ptr.y, vector_ptr.z });

    // Test 3: Type-safe access
    std.debug.print("\\n3. Type-safe userdata access:\\n", .{});

    // Access Person (should work)
    const retrieved_person = try manager.getUserdata(Person, -2, "Person");
    if (retrieved_person) |p| {
        std.debug.print("  ✓ Retrieved Person: {s}, age {}\\n", .{ p.getName(), p.age });

        // Modify the person
        p.setAge(29);
        std.debug.print("  ✓ Updated Person age to {}\\n", .{p.age});
    } else {
        std.debug.print("  ✗ Failed to retrieve Person\\n", .{});
    }

    // Try to access Person as Vector3 (should fail)
    const wrong_type = try manager.getUserdata(Vector3, -2, "Vector3");
    if (wrong_type) |_| {
        std.debug.print("  ✗ Type safety failed - should not be able to access Person as Vector3\\n", .{});
    } else {
        std.debug.print("  ✓ Type safety working - correctly rejected wrong type access\\n", .{});
    }

    // Test 4: Method calls via metatable
    std.debug.print("\\n4. Method calls via Lua metatable:\\n", .{});

    // Call Person methods from Lua
    const lua_code1 =
        \\\\-- Get person from stack position -2
        \\\\local person = ...
        \\\\print("Person name from Lua:", person:getName())
        \\\\print("Person age from Lua:", person:getAge())
        \\\\person:setAge(30)
        \\\\print("Person age after update:", person:getAge())
        \\\\return person:getName(), person:getAge()
    ;

    // Push the person userdata as argument
    lua.c.lua_pushvalue(wrapper.state, -2);

    _ = lua.c.luaL_loadstring(wrapper.state, lua_code1.ptr);
    lua.c.lua_insert(wrapper.state, -2); // Move function before person argument

    const result1 = lua.c.lua_pcall(wrapper.state, 1, 2, 0);
    if (result1 == lua.c.LUA_OK) {
        // Get return values
        var len: usize = 0;
        const name_from_lua = lua.c.lua_tolstring(wrapper.state, -2, &len);
        const age_from_lua = lua.c.lua_tointeger(wrapper.state, -1);

        std.debug.print("  ✓ Lua returned: name = \\\"{s}\\\", age = {}\\n", .{ name_from_lua.?[0..len], age_from_lua });

        lua.c.lua_pop(wrapper.state, 2); // Pop return values
    } else {
        const error_msg = lua.c.lua_tostring(wrapper.state, -1);
        std.debug.print("  ✗ Lua execution failed: {s}\\n", .{std.mem.span(error_msg.?)});
        lua.c.lua_pop(wrapper.state, 1);
    }

    // Test 5: Userdata conversion to ScriptValue
    std.debug.print("\\n5. Userdata to ScriptValue conversion:\\n", .{});

    const pullScriptValue = @import("zig_llms").scripting.engines.lua_value_converter.pullScriptValue;

    // Convert Person userdata to ScriptValue
    var person_script_value = try pullScriptValue(wrapper, -2, allocator);
    defer person_script_value.deinit(allocator);

    std.debug.print("  ✓ Converted Person to ScriptValue\\n", .{});
    std.debug.print("  Type: {s}\\n", .{@tagName(person_script_value)});
    if (person_script_value == .userdata) {
        std.debug.print("  Type ID: {s}\\n", .{person_script_value.userdata.type_id});
        std.debug.print("  Pointer: 0x{x}\\n", .{@intFromPtr(person_script_value.userdata.ptr)});
    }

    // Convert Vector3 userdata to ScriptValue
    var vector_script_value = try pullScriptValue(wrapper, -1, allocator);
    defer vector_script_value.deinit(allocator);

    std.debug.print("  ✓ Converted Vector3 to ScriptValue\\n", .{});
    std.debug.print("  Type: {s}\\n", .{@tagName(vector_script_value)});
    if (vector_script_value == .userdata) {
        std.debug.print("  Type ID: {s}\\n", .{vector_script_value.userdata.type_id});
        std.debug.print("  Pointer: 0x{x}\\n", .{@intFromPtr(vector_script_value.userdata.ptr)});
    }

    // Test 6: Registry information
    std.debug.print("\\n6. Registry information:\\n", .{});

    const type_names = try registry.getTypeNames(allocator);
    defer allocator.free(type_names);

    std.debug.print("  Registered types: {}\\n", .{type_names.len});
    for (type_names) |name| {
        const type_info = registry.getType(name).?;
        std.debug.print("    - {s}: size={}, align={}, version={}\\n", .{
            name,
            type_info.size,
            type_info.alignment,
            type_info.version,
        });
    }

    // Test 7: Memory management and garbage collection
    std.debug.print("\\n7. Memory management and garbage collection:\\n", .{});

    // Create additional userdata that will be garbage collected
    const person2 = Person.init("Bob Smith", 35, 180.0);
    _ = try manager.createUserdata(Person, person2, "Person");
    std.debug.print("  ✓ Created additional Person for GC test\\n", .{});

    // Force garbage collection
    std.debug.print("  Running Lua garbage collection...\\n", .{});
    _ = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOLLECT, 0);

    // Check memory usage
    const lua_memory = lua.c.lua_gc(wrapper.state, lua.c.LUA_GCCOUNT, 0);
    std.debug.print("  Lua memory usage: {} KB\\n", .{lua_memory});

    // Test 8: Stack verification
    std.debug.print("\\n8. Stack verification:\\n", .{});
    const final_stack = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Final stack level: {} (should be 2 for Person and Vector3)\\n", .{final_stack});

    // Clean up stack
    lua.c.lua_pop(wrapper.state, final_stack);
    const clean_stack = lua.c.lua_gettop(wrapper.state);
    std.debug.print("  Cleaned stack level: {}\\n", .{clean_stack});

    std.debug.print("\\n=== Demo Complete ===\\n", .{});
    std.debug.print("\\nKey functionality demonstrated:\\n", .{});
    std.debug.print("- Type-safe userdata creation with headers and magic numbers\\n", .{});
    std.debug.print("- Userdata registry with type information and versioning\\n", .{});
    std.debug.print("- Custom metatable setup for method access from Lua\\n", .{});
    std.debug.print("- Type safety enforcement preventing wrong type access\\n", .{});
    std.debug.print("- Automatic garbage collection with custom destructors\\n", .{});
    std.debug.print("- Bidirectional conversion between userdata and ScriptValue\\n", .{});
    std.debug.print("- Method invocation from Lua via metatables\\n", .{});
    std.debug.print("- Memory management and proper cleanup\\n", .{});
}
