// ABOUTME: C bindings for Lua 5.4 integration with zig_llms
// ABOUTME: Provides Zig-friendly wrappers around Lua C API

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// Only compile Lua support if enabled
pub const lua_enabled = build_options.enable_lua;

// Lua C API imports
pub const c = if (lua_enabled) @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
}) else struct {
    // Stub types when Lua is disabled
    pub const lua_State = opaque {};
    pub const lua_Number = f64;
    pub const lua_Integer = i64;
    pub const lua_CFunction = *const fn (?*lua_State) callconv(.C) c_int;
};

// Lua constants
pub const LUA_OK = 0;
pub const LUA_YIELD = 1;
pub const LUA_ERRRUN = 2;
pub const LUA_ERRSYNTAX = 3;
pub const LUA_ERRMEM = 4;
pub const LUA_ERRERR = 5;

// Lua types
pub const LUA_TNONE = -1;
pub const LUA_TNIL = 0;
pub const LUA_TBOOLEAN = 1;
pub const LUA_TLIGHTUSERDATA = 2;
pub const LUA_TNUMBER = 3;
pub const LUA_TSTRING = 4;
pub const LUA_TTABLE = 5;
pub const LUA_TFUNCTION = 6;
pub const LUA_TUSERDATA = 7;
pub const LUA_TTHREAD = 8;

// Type aliases for cleaner Zig code
pub const LuaState = if (lua_enabled) *c.lua_State else *c.lua_State;
pub const LuaNumber = c.lua_Number;
pub const LuaInteger = c.lua_Integer;
pub const LuaCFunction = c.lua_CFunction;

// Error type for Lua operations
pub const LuaError = error{
    RuntimeError,
    SyntaxError,
    MemoryError,
    ErrorHandlingError,
    TypeError,
    UnknownError,
};

// Convert Lua error codes to Zig errors
pub fn luaErrorFromCode(code: c_int) LuaError {
    return switch (code) {
        LUA_OK => unreachable,
        LUA_ERRRUN => LuaError.RuntimeError,
        LUA_ERRSYNTAX => LuaError.SyntaxError,
        LUA_ERRMEM => LuaError.MemoryError,
        LUA_ERRERR => LuaError.ErrorHandlingError,
        else => LuaError.UnknownError,
    };
}

// Zig-friendly wrappers for common Lua operations
pub const LuaWrapper = struct {
    state: LuaState,
    allocator: std.mem.Allocator,
    owns_state: bool,

    pub fn init(allocator: std.mem.Allocator) !*LuaWrapper {
        if (!lua_enabled) {
            return error.LuaNotEnabled;
        }
        
        const self = try allocator.create(LuaWrapper);
        errdefer allocator.destroy(self);

        const state = c.luaL_newstate() orelse return error.OutOfMemory;
        errdefer c.lua_close(state);

        self.* = LuaWrapper{
            .state = state,
            .allocator = allocator,
            .owns_state = true,
        };

        // Open standard libraries
        c.luaL_openlibs(state);

        return self;
    }

    pub fn initWithState(allocator: std.mem.Allocator, state: LuaState) !*LuaWrapper {
        if (!lua_enabled) {
            return error.LuaNotEnabled;
        }
        
        const self = try allocator.create(LuaWrapper);
        self.* = LuaWrapper{
            .state = state,
            .allocator = allocator,
            .owns_state = false,
        };
        return self;
    }

    pub fn deinit(self: *LuaWrapper) void {
        if (self.owns_state and lua_enabled) {
            c.lua_close(self.state);
        }
        self.allocator.destroy(self);
    }

    // Execute Lua code
    pub fn doString(self: *LuaWrapper, code: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        
        const code_z = try self.allocator.dupeZ(u8, code);
        defer self.allocator.free(code_z);

        const result = c.luaL_dostring(self.state, code_z);
        if (result != LUA_OK) {
            const err_msg = self.toString(-1) catch "Unknown error";
            std.log.err("Lua error: {s}", .{err_msg});
            self.pop(1);
            return luaErrorFromCode(result);
        }
    }

    // Load Lua file
    pub fn doFile(self: *LuaWrapper, filename: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        
        const filename_z = try self.allocator.dupeZ(u8, filename);
        defer self.allocator.free(filename_z);

        const result = c.luaL_dofile(self.state, filename_z);
        if (result != LUA_OK) {
            const err_msg = self.toString(-1) catch "Unknown error";
            std.log.err("Lua error in file {s}: {s}", .{ filename, err_msg });
            self.pop(1);
            return luaErrorFromCode(result);
        }
    }

    // Stack manipulation
    pub fn getTop(self: *LuaWrapper) c_int {
        if (!lua_enabled) return 0;
        return c.lua_gettop(self.state);
    }

    pub fn setTop(self: *LuaWrapper, index: c_int) void {
        if (!lua_enabled) return;
        c.lua_settop(self.state, index);
    }

    pub fn pop(self: *LuaWrapper, n: c_int) void {
        if (!lua_enabled) return;
        c.lua_pop(self.state, n);
    }

    // Type checking
    pub fn getType(self: *LuaWrapper, index: c_int) c_int {
        if (!lua_enabled) return LUA_TNONE;
        return c.lua_type(self.state, index);
    }

    pub fn isNil(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return true;
        return c.lua_isnil(self.state, index);
    }

    pub fn isBoolean(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return false;
        return c.lua_isboolean(self.state, index);
    }

    pub fn isNumber(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return false;
        return c.lua_isnumber(self.state, index) != 0;
    }

    pub fn isString(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return false;
        return c.lua_isstring(self.state, index) != 0;
    }

    pub fn isTable(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return false;
        return c.lua_istable(self.state, index);
    }

    pub fn isFunction(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return false;
        return c.lua_isfunction(self.state, index);
    }

    // Push values
    pub fn pushNil(self: *LuaWrapper) void {
        if (!lua_enabled) return;
        c.lua_pushnil(self.state);
    }

    pub fn pushBoolean(self: *LuaWrapper, value: bool) void {
        if (!lua_enabled) return;
        c.lua_pushboolean(self.state, @intFromBool(value));
    }

    pub fn pushNumber(self: *LuaWrapper, value: LuaNumber) void {
        if (!lua_enabled) return;
        c.lua_pushnumber(self.state, value);
    }

    pub fn pushInteger(self: *LuaWrapper, value: LuaInteger) void {
        if (!lua_enabled) return;
        c.lua_pushinteger(self.state, value);
    }

    pub fn pushString(self: *LuaWrapper, value: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        const value_z = try self.allocator.dupeZ(u8, value);
        defer self.allocator.free(value_z);
        _ = c.lua_pushstring(self.state, value_z);
    }

    pub fn pushCFunction(self: *LuaWrapper, func: LuaCFunction) void {
        if (!lua_enabled) return;
        c.lua_pushcfunction(self.state, func);
    }

    // Get values
    pub fn toBoolean(self: *LuaWrapper, index: c_int) bool {
        if (!lua_enabled) return false;
        return c.lua_toboolean(self.state, index) != 0;
    }

    pub fn toNumber(self: *LuaWrapper, index: c_int) ?LuaNumber {
        if (!lua_enabled) return null;
        var isnum: c_int = 0;
        const result = c.lua_tonumberx(self.state, index, &isnum);
        return if (isnum != 0) result else null;
    }

    pub fn toInteger(self: *LuaWrapper, index: c_int) ?LuaInteger {
        if (!lua_enabled) return null;
        var isnum: c_int = 0;
        const result = c.lua_tointegerx(self.state, index, &isnum);
        return if (isnum != 0) result else null;
    }

    pub fn toString(self: *LuaWrapper, index: c_int) ![]const u8 {
        if (!lua_enabled) return error.LuaNotEnabled;
        var len: usize = 0;
        const str = c.lua_tolstring(self.state, index, &len);
        if (str == null) {
            return error.TypeError;
        }
        return str[0..len];
    }

    // Table operations
    pub fn createTable(self: *LuaWrapper, narr: c_int, nrec: c_int) void {
        if (!lua_enabled) return;
        c.lua_createtable(self.state, narr, nrec);
    }

    pub fn getTable(self: *LuaWrapper, index: c_int) void {
        if (!lua_enabled) return;
        c.lua_gettable(self.state, index);
    }

    pub fn setTable(self: *LuaWrapper, index: c_int) void {
        if (!lua_enabled) return;
        c.lua_settable(self.state, index);
    }

    pub fn getField(self: *LuaWrapper, index: c_int, key: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        c.lua_getfield(self.state, index, key_z);
    }

    pub fn setField(self: *LuaWrapper, index: c_int, key: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        const key_z = try self.allocator.dupeZ(u8, key);
        defer self.allocator.free(key_z);
        c.lua_setfield(self.state, index, key_z);
    }

    // Global operations
    pub fn getGlobal(self: *LuaWrapper, name: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        c.lua_getglobal(self.state, name_z);
    }

    pub fn setGlobal(self: *LuaWrapper, name: []const u8) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        const name_z = try self.allocator.dupeZ(u8, name);
        defer self.allocator.free(name_z);
        c.lua_setglobal(self.state, name_z);
    }

    // Function calls
    pub fn call(self: *LuaWrapper, nargs: c_int, nresults: c_int) !void {
        if (!lua_enabled) return error.LuaNotEnabled;
        const result = c.lua_pcall(self.state, nargs, nresults, 0);
        if (result != LUA_OK) {
            const err_msg = self.toString(-1) catch "Unknown error";
            std.log.err("Lua call error: {s}", .{err_msg});
            self.pop(1);
            return luaErrorFromCode(result);
        }
    }

    // Registry operations
    pub fn ref(self: *LuaWrapper, table: c_int) c_int {
        if (!lua_enabled) return 0;
        return c.luaL_ref(self.state, table);
    }

    pub fn unref(self: *LuaWrapper, table: c_int, reference: c_int) void {
        if (!lua_enabled) return;
        c.luaL_unref(self.state, table, reference);
    }
};

// Test support
test "lua wrapper basic operations" {
    if (!lua_enabled) return;
    
    const allocator = std.testing.allocator;
    const lua = try LuaWrapper.init(allocator);
    defer lua.deinit();

    // Test basic operations
    try lua.doString("x = 42");
    try lua.getGlobal("x");
    const value = lua.toNumber(-1);
    try std.testing.expect(value != null);
    try std.testing.expectEqual(@as(f64, 42), value.?);
    lua.pop(1);
}