// ABOUTME: Lua userdata system for complex Zig types with type safety and lifecycle management
// ABOUTME: Provides registry, metatables, and automatic cleanup for Zig structures in Lua

const std = @import("std");
const lua = @import("../../bindings/lua/lua.zig");
const LuaWrapper = lua.LuaWrapper;
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptContext = @import("../context.zig").ScriptContext;

/// Userdata type information
pub const UserdataTypeInfo = struct {
    /// Type name for identification
    name: []const u8,

    /// Type size in bytes
    size: usize,

    /// Type alignment requirements
    alignment: usize,

    /// Optional destructor function called when userdata is garbage collected
    destructor: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,

    /// Optional metatable setup function for custom Lua operations
    setup_metatable: ?*const fn (wrapper: *LuaWrapper, type_name: []const u8) anyerror!void = null,

    /// Type version for compatibility checking
    version: u32 = 1,

    /// Whether this type should be cached in the registry
    cacheable: bool = true,
};

/// Userdata registry for managing type information
pub const UserdataRegistry = struct {
    allocator: std.mem.Allocator,
    types: std.StringHashMap(UserdataTypeInfo),

    pub fn init(allocator: std.mem.Allocator) UserdataRegistry {
        return UserdataRegistry{
            .allocator = allocator,
            .types = std.StringHashMap(UserdataTypeInfo).init(allocator),
        };
    }

    pub fn deinit(self: *UserdataRegistry) void {
        // Free all registered type names
        var iterator = self.types.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.types.deinit();
    }

    /// Register a new userdata type
    pub fn registerType(self: *UserdataRegistry, type_info: UserdataTypeInfo) !void {
        const name_copy = try self.allocator.dupe(u8, type_info.name);
        errdefer self.allocator.free(name_copy);

        var info_copy = type_info;
        info_copy.name = name_copy;

        try self.types.put(name_copy, info_copy);
    }

    /// Get type information by name
    pub fn getType(self: *UserdataRegistry, name: []const u8) ?UserdataTypeInfo {
        return self.types.get(name);
    }

    /// Check if a type is registered
    pub fn hasType(self: *UserdataRegistry, name: []const u8) bool {
        return self.types.contains(name);
    }

    /// Get all registered type names
    pub fn getTypeNames(self: *UserdataRegistry, allocator: std.mem.Allocator) ![][]const u8 {
        var names = try std.ArrayList([]const u8).initCapacity(allocator, self.types.count());
        defer names.deinit();

        var iterator = self.types.iterator();
        while (iterator.next()) |entry| {
            names.appendAssumeCapacity(entry.key_ptr.*);
        }

        return names.toOwnedSlice();
    }
};

/// Userdata header stored before actual data for type safety
const UserdataHeader = struct {
    /// Magic number to detect valid userdata
    magic: u32 = 0xDEADBEEF,

    /// Type name length
    type_name_len: u32,

    /// Type version
    version: u32,

    /// Allocator used for this userdata
    allocator: std.mem.Allocator,

    /// Destructor function pointer
    destructor: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    /// Get the type name following the header
    pub fn getTypeName(self: *const UserdataHeader) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self);
        const name_start = ptr + @sizeOf(UserdataHeader);
        return name_start[0..self.type_name_len];
    }

    /// Get pointer to actual user data
    pub fn getData(self: *const UserdataHeader) *anyopaque {
        const ptr: [*]u8 = @ptrCast(self);
        const aligned_header_size = std.mem.alignForward(usize, @sizeOf(UserdataHeader) + self.type_name_len, std.meta.alignment(@This()));
        return @ptrCast(ptr + aligned_header_size);
    }
};

/// Userdata manager for a specific Lua state
pub const LuaUserdataManager = struct {
    wrapper: *LuaWrapper,
    registry: *UserdataRegistry,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, wrapper: *LuaWrapper, registry: *UserdataRegistry) LuaUserdataManager {
        return LuaUserdataManager{
            .wrapper = wrapper,
            .registry = registry,
            .allocator = allocator,
        };
    }

    /// Create userdata for a specific type
    pub fn createUserdata(self: *LuaUserdataManager, comptime T: type, value: T, type_name: []const u8) !*T {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        const type_info = self.registry.getType(type_name) orelse return error.UnknownType;

        // Verify type size matches
        if (@sizeOf(T) != type_info.size) {
            return error.TypeSizeMismatch;
        }

        // Calculate total size needed: header + type_name + aligned data
        const header_size = @sizeOf(UserdataHeader);
        const aligned_header_size = std.mem.alignForward(usize, header_size + type_name.len, @alignOf(T));
        const total_size = aligned_header_size + @sizeOf(T);

        // Create userdata in Lua
        const userdata_ptr = lua.c.lua_newuserdatauv(self.wrapper.state, total_size, 0);

        // Initialize header
        const header: *UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
        header.* = UserdataHeader{
            .magic = 0xDEADBEEF,
            .type_name_len = @intCast(type_name.len),
            .version = type_info.version,
            .allocator = self.allocator,
            .destructor = type_info.destructor,
        };

        // Copy type name
        const name_ptr: [*]u8 = @ptrCast(header);
        const name_dest = name_ptr + @sizeOf(UserdataHeader);
        @memcpy(name_dest[0..type_name.len], type_name);

        // Get data pointer and copy value
        const data_ptr: *T = @ptrCast(@alignCast(header.getData()));
        data_ptr.* = value;

        // Set up metatable if one exists for this type
        if (self.getMetatableName(type_name)) |metatable_name| {
            if (lua.c.luaL_getmetatable(self.wrapper.state, metatable_name.ptr) != lua.c.LUA_TNIL) {
                lua.c.lua_setmetatable(self.wrapper.state, -2);
            } else {
                // Create metatable if it doesn't exist
                try self.createMetatable(type_name, type_info);
                lua.c.lua_setmetatable(self.wrapper.state, -2);
            }
        }

        return data_ptr;
    }

    /// Get typed pointer from userdata, with type checking
    pub fn getUserdata(self: *LuaUserdataManager, comptime T: type, index: c_int, type_name: []const u8) !?*T {
        if (!lua.lua_enabled) return error.LuaNotEnabled;

        // Check if it's userdata
        if (lua.c.lua_type(self.wrapper.state, index) != lua.c.LUA_TUSERDATA) {
            return null;
        }

        const userdata_ptr = lua.c.lua_touserdata(self.wrapper.state, index);
        if (userdata_ptr == null) return null;

        // Verify header
        const header: *const UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
        if (header.magic != 0xDEADBEEF) {
            return error.InvalidUserdata;
        }

        // Check type name
        const stored_type_name = header.getTypeName();
        if (!std.mem.eql(u8, stored_type_name, type_name)) {
            return error.TypeMismatch;
        }

        // Check type size
        if (@sizeOf(T) != self.registry.getType(type_name).?.size) {
            return error.TypeSizeMismatch;
        }

        return @ptrCast(@alignCast(header.getData()));
    }

    /// Push a Zig value as userdata
    pub fn pushUserdata(self: *LuaUserdataManager, comptime T: type, value: T, type_name: []const u8) !void {
        _ = try self.createUserdata(T, value, type_name);
    }

    /// Convert userdata to ScriptValue
    pub fn userdataToScriptValue(self: *LuaUserdataManager, index: c_int, allocator: std.mem.Allocator) !ScriptValue {
        _ = allocator;

        if (!lua.lua_enabled) return error.LuaNotEnabled;

        const userdata_ptr = lua.c.lua_touserdata(self.wrapper.state, index);
        if (userdata_ptr == null) {
            return ScriptValue.nil;
        }

        // Try to read header to get type information
        const header: *const UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
        if (header.magic != 0xDEADBEEF) {
            // Not our userdata format, treat as opaque
            return ScriptValue{ .userdata = ScriptValue.UserData{
                .ptr = userdata_ptr,
                .type_id = "unknown_userdata",
                .deinit_fn = null,
            } };
        }

        const type_name = header.getTypeName();
        return ScriptValue{
            .userdata = ScriptValue.UserData{
                .ptr = header.getData(),
                .type_id = type_name,
                .deinit_fn = null, // Lua will handle cleanup via GC
            },
        };
    }

    /// Create a metatable for a userdata type
    fn createMetatable(self: *LuaUserdataManager, type_name: []const u8, type_info: UserdataTypeInfo) !void {
        const metatable_name = try self.getMetatableName(type_name);
        defer self.allocator.free(metatable_name);

        // Create new metatable
        _ = lua.c.luaL_newmetatable(self.wrapper.state, metatable_name.ptr);

        // Set __gc metamethod for cleanup
        lua.c.lua_pushcfunction(self.wrapper.state, userdataGC);
        lua.c.lua_setfield(self.wrapper.state, -2, "__gc");

        // Set __tostring metamethod for debugging
        lua.c.lua_pushcfunction(self.wrapper.state, userdataToString);
        lua.c.lua_setfield(self.wrapper.state, -2, "__tostring");

        // Set __index to itself for method access (if needed)
        lua.c.lua_pushvalue(self.wrapper.state, -1);
        lua.c.lua_setfield(self.wrapper.state, -2, "__index");

        // Call custom metatable setup if provided
        if (type_info.setup_metatable) |setup_fn| {
            try setup_fn(self.wrapper, type_name);
        }
    }

    /// Get metatable name for a type
    fn getMetatableName(self: *LuaUserdataManager, type_name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "zig_llms.{s}", .{type_name});
    }
};

/// Garbage collection metamethod for userdata
fn userdataGC(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    const userdata_ptr = lua.c.lua_touserdata(state, 1);
    if (userdata_ptr == null) return 0;

    // Check if it's our userdata format
    const header: *const UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
    if (header.magic != 0xDEADBEEF) return 0;

    // Call destructor if provided
    if (header.destructor) |destructor_fn| {
        destructor_fn(header.getData(), header.allocator);
    }

    return 0;
}

/// __tostring metamethod for userdata debugging
fn userdataToString(L: ?*lua.c.lua_State) callconv(.C) c_int {
    const state = L.?;

    const userdata_ptr = lua.c.lua_touserdata(state, 1);
    if (userdata_ptr == null) {
        lua.c.lua_pushstring(state, "[invalid userdata]");
        return 1;
    }

    // Check if it's our userdata format
    const header: *const UserdataHeader = @ptrCast(@alignCast(userdata_ptr));
    if (header.magic != 0xDEADBEEF) {
        lua.c.lua_pushstring(state, "[unknown userdata]");
        return 1;
    }

    const type_name = header.getTypeName();
    const data_ptr = header.getData();

    // Create string representation
    const result_str = std.fmt.allocPrint(header.allocator, "[{s} userdata: 0x{x}]", .{ type_name, @intFromPtr(data_ptr) }) catch {
        lua.c.lua_pushstring(state, "[userdata: allocation failed]");
        return 1;
    };
    defer header.allocator.free(result_str);

    lua.c.lua_pushlstring(state, result_str.ptr, result_str.len);
    return 1;
}

/// Helper function to register common zig_llms types
pub fn registerCommonTypes(registry: *UserdataRegistry) !void {
    // Register ScriptContext
    try registry.registerType(UserdataTypeInfo{
        .name = "ScriptContext",
        .size = @sizeOf(ScriptContext),
        .alignment = @alignOf(ScriptContext),
        .destructor = null, // Context cleanup is handled externally
        .cacheable = true,
    });

    // Register basic types that might be used
    try registry.registerType(UserdataTypeInfo{
        .name = "i64",
        .size = @sizeOf(i64),
        .alignment = @alignOf(i64),
        .destructor = null,
        .cacheable = true,
    });

    try registry.registerType(UserdataTypeInfo{
        .name = "f64",
        .size = @sizeOf(f64),
        .alignment = @alignOf(f64),
        .destructor = null,
        .cacheable = true,
    });

    try registry.registerType(UserdataTypeInfo{
        .name = "bool",
        .size = @sizeOf(bool),
        .alignment = @alignOf(bool),
        .destructor = null,
        .cacheable = true,
    });
}

// Tests
test "UserdataRegistry basic operations" {
    const allocator = std.testing.allocator;

    var registry = UserdataRegistry.init(allocator);
    defer registry.deinit();

    // Test registration
    const test_type = UserdataTypeInfo{
        .name = "TestStruct",
        .size = @sizeOf(struct { value: i32 }),
        .alignment = @alignOf(struct { value: i32 }),
    };

    try registry.registerType(test_type);

    // Test retrieval
    const retrieved = registry.getType("TestStruct");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("TestStruct", retrieved.?.name);
    try std.testing.expectEqual(@sizeOf(struct { value: i32 }), retrieved.?.size);

    // Test has type
    try std.testing.expect(registry.hasType("TestStruct"));
    try std.testing.expect(!registry.hasType("NonExistent"));
}

test "LuaUserdataManager userdata creation" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    // Setup
    var registry = UserdataRegistry.init(allocator);
    defer registry.deinit();

    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var manager = LuaUserdataManager.init(allocator, wrapper, &registry);

    // Register a test type
    const TestStruct = struct { value: i32, name: [16]u8 };
    try registry.registerType(UserdataTypeInfo{
        .name = "TestStruct",
        .size = @sizeOf(TestStruct),
        .alignment = @alignOf(TestStruct),
    });

    // Create userdata
    const test_value = TestStruct{ .value = 42, .name = "test_name\x00\x00\x00\x00\x00\x00".* };
    const userdata_ptr = try manager.createUserdata(TestStruct, test_value, "TestStruct");

    // Verify userdata
    try std.testing.expectEqual(@as(i32, 42), userdata_ptr.value);

    // Test retrieval
    const retrieved_ptr = try manager.getUserdata(TestStruct, -1, "TestStruct");
    try std.testing.expect(retrieved_ptr != null);
    try std.testing.expectEqual(@as(i32, 42), retrieved_ptr.?.value);

    lua.c.lua_pop(wrapper.state, 1);
}

test "Userdata type safety" {
    if (!lua.lua_enabled) return;

    const allocator = std.testing.allocator;

    var registry = UserdataRegistry.init(allocator);
    defer registry.deinit();

    const wrapper = try LuaWrapper.init(allocator);
    defer wrapper.deinit();

    var manager = LuaUserdataManager.init(allocator, wrapper, &registry);

    // Register types
    try registry.registerType(UserdataTypeInfo{
        .name = "i32",
        .size = @sizeOf(i32),
        .alignment = @alignOf(i32),
    });

    try registry.registerType(UserdataTypeInfo{
        .name = "f64",
        .size = @sizeOf(f64),
        .alignment = @alignOf(f64),
    });

    // Create i32 userdata
    _ = try manager.createUserdata(i32, 42, "i32");

    // Try to access as wrong type - should return null or error
    const wrong_type_ptr = try manager.getUserdata(f64, -1, "f64");
    try std.testing.expect(wrong_type_ptr == null);

    lua.c.lua_pop(wrapper.state, 1);
}
