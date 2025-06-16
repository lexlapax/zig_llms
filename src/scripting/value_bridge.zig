// ABOUTME: Universal value type system for script<->zig type conversion
// ABOUTME: Handles marshaling between script values and native Zig types

const std = @import("std");

/// Universal value type for script<->zig conversion
pub const ScriptValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    array: Array,
    object: Object,
    function: *ScriptFunction,
    userdata: UserData,

    pub const Array = struct {
        items: []ScriptValue,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Array {
            return Array{
                .items = try allocator.alloc(ScriptValue, capacity),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Array) void {
            for (self.items) |*item| {
                item.deinit(self.allocator);
            }
            self.allocator.free(self.items);
        }

        pub fn clone(self: Array, allocator: std.mem.Allocator) !Array {
            var new_array = try Array.init(allocator, self.items.len);
            for (self.items, 0..) |item, i| {
                new_array.items[i] = try item.clone(allocator);
            }
            return new_array;
        }
    };

    pub const Object = struct {
        map: std.StringHashMap(ScriptValue),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Object {
            return Object{
                .map = std.StringHashMap(ScriptValue).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Object) void {
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            self.map.deinit();
        }

        pub fn put(self: *Object, key: []const u8, value: ScriptValue) !void {
            const owned_key = try self.allocator.dupe(u8, key);
            try self.map.put(owned_key, value);
        }

        pub fn get(self: *const Object, key: []const u8) ?ScriptValue {
            return self.map.get(key);
        }

        pub fn clone(self: Object, allocator: std.mem.Allocator) !Object {
            var new_obj = Object.init(allocator);
            var iter = self.map.iterator();
            while (iter.next()) |entry| {
                const cloned_value = try entry.value_ptr.*.clone(allocator);
                try new_obj.put(entry.key_ptr.*, cloned_value);
            }
            return new_obj;
        }
    };

    pub const UserData = struct {
        ptr: *anyopaque,
        type_id: []const u8,
        deinit_fn: ?*const fn (ptr: *anyopaque) void = null,

        pub fn deinit(self: *UserData) void {
            if (self.deinit_fn) |deinit_fn| {
                deinit_fn(self.ptr);
            }
        }
    };

    /// Convert from a Zig value to ScriptValue
    pub fn fromZig(comptime T: type, value: T, allocator: std.mem.Allocator) !ScriptValue {
        const type_info = @typeInfo(T);

        return switch (type_info) {
            .Void, .Null => ScriptValue.nil,
            .Bool => ScriptValue{ .boolean = value },
            .Int => ScriptValue{ .integer = @intCast(value) },
            .Float => ScriptValue{ .number = @floatCast(value) },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    if (ptr.child == u8) {
                        // String
                        return ScriptValue{ .string = try allocator.dupe(u8, value) };
                    } else {
                        // Array of other types
                        var array = try Array.init(allocator, value.len);
                        for (value, 0..) |item, i| {
                            array.items[i] = try fromZig(ptr.child, item, allocator);
                        }
                        return ScriptValue{ .array = array };
                    }
                },
                .One => {
                    // Single pointer - treat as userdata
                    return ScriptValue{
                        .userdata = UserData{
                            .ptr = @ptrCast(@constCast(value)),
                            .type_id = @typeName(T),
                        },
                    };
                },
                else => return error.UnsupportedType,
            },
            .Array => |arr| {
                var array = try Array.init(allocator, arr.len);
                for (value, 0..) |item, i| {
                    array.items[i] = try fromZig(arr.child, item, allocator);
                }
                return ScriptValue{ .array = array };
            },
            .Struct => |str| {
                var obj = Object.init(allocator);
                inline for (str.fields) |field| {
                    const field_value = @field(value, field.name);
                    const script_value = try fromZig(field.type, field_value, allocator);
                    try obj.put(field.name, script_value);
                }
                return ScriptValue{ .object = obj };
            },
            .Optional => |opt| {
                if (value) |val| {
                    return fromZig(opt.child, val, allocator);
                } else {
                    return ScriptValue.nil;
                }
            },
            .Enum => {
                return ScriptValue{ .string = try allocator.dupe(u8, @tagName(value)) };
            },
            .Union => |un| {
                if (un.tag_type != null) {
                    // Tagged union
                    inline for (un.fields) |field| {
                        if (value == @field(T, field.name)) {
                            return fromZig(field.type, @field(value, field.name), allocator);
                        }
                    }
                }
                return error.UnsupportedType;
            },
            else => return error.UnsupportedType,
        };
    }

    /// Convert from ScriptValue to a Zig value
    pub fn toZig(self: ScriptValue, comptime T: type, allocator: std.mem.Allocator) !T {
        const type_info = @typeInfo(T);

        switch (type_info) {
            .Void => {
                if (self != .nil) return error.TypeMismatch;
                return;
            },
            .Bool => {
                return switch (self) {
                    .boolean => |b| b,
                    .nil => false,
                    .integer => |i| i != 0,
                    .number => |n| n != 0.0,
                    else => error.TypeMismatch,
                };
            },
            .Int => {
                return switch (self) {
                    .integer => |i| @intCast(i),
                    .number => |n| @intFromFloat(n),
                    .boolean => |b| if (b) @as(T, 1) else 0,
                    else => error.TypeMismatch,
                };
            },
            .Float => {
                return switch (self) {
                    .number => |n| @floatCast(n),
                    .integer => |i| @floatFromInt(i),
                    else => error.TypeMismatch,
                };
            },
            .Pointer => |ptr| switch (ptr.size) {
                .Slice => {
                    if (ptr.child == u8) {
                        // String
                        return switch (self) {
                            .string => |s| try allocator.dupe(u8, s),
                            else => error.TypeMismatch,
                        };
                    } else {
                        // Array slice
                        return switch (self) {
                            .array => |arr| blk: {
                                var result = try allocator.alloc(ptr.child, arr.items.len);
                                for (arr.items, 0..) |item, i| {
                                    result[i] = try item.toZig(ptr.child, allocator);
                                }
                                break :blk result;
                            },
                            else => error.TypeMismatch,
                        };
                    }
                },
                .One => {
                    return switch (self) {
                        .userdata => |ud| {
                            if (!std.mem.eql(u8, ud.type_id, @typeName(T))) {
                                return error.TypeMismatch;
                            }
                            return @ptrCast(@alignCast(ud.ptr));
                        },
                        else => error.TypeMismatch,
                    };
                },
                else => return error.UnsupportedType,
            },
            .Optional => |opt| {
                if (self == .nil) {
                    return null;
                } else {
                    return try self.toZig(opt.child, allocator);
                }
            },
            .Struct => |str| {
                switch (self) {
                    .object => |obj| {
                        var result: T = undefined;
                        inline for (str.fields) |field| {
                            if (obj.get(field.name)) |field_value| {
                                @field(result, field.name) = try field_value.toZig(field.type, allocator);
                            } else if (field.default_value) |default| {
                                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
                            } else {
                                return error.MissingField;
                            }
                        }
                        return result;
                    },
                    else => return error.TypeMismatch,
                }
            },
            else => return error.UnsupportedType,
        }
    }

    /// Deep clone a ScriptValue
    pub fn clone(self: ScriptValue, allocator: std.mem.Allocator) !ScriptValue {
        return switch (self) {
            .nil => ScriptValue.nil,
            .boolean => |b| ScriptValue{ .boolean = b },
            .integer => |i| ScriptValue{ .integer = i },
            .number => |n| ScriptValue{ .number = n },
            .string => |s| ScriptValue{ .string = try allocator.dupe(u8, s) },
            .array => |arr| ScriptValue{ .array = try arr.clone(allocator) },
            .object => |obj| ScriptValue{ .object = try obj.clone(allocator) },
            .function => |f| ScriptValue{ .function = f }, // Functions are not cloned
            .userdata => |ud| ScriptValue{ .userdata = ud }, // Userdata is not cloned
        };
    }

    /// Release resources associated with a ScriptValue
    pub fn deinit(self: *ScriptValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .nil, .boolean, .integer, .number => {},
            .string => |s| allocator.free(s),
            .array => |*arr| arr.deinit(),
            .object => |*obj| obj.deinit(),
            .function => {}, // Functions are managed by the engine
            .userdata => |*ud| ud.deinit(),
        }
    }

    /// Check if two ScriptValues are equal
    pub fn eql(self: ScriptValue, other: ScriptValue) bool {
        if (@intFromEnum(self) != @intFromEnum(other)) return false;

        return switch (self) {
            .nil => true,
            .boolean => |b| b == other.boolean,
            .integer => |i| i == other.integer,
            .number => |n| n == other.number,
            .string => |s| std.mem.eql(u8, s, other.string),
            .array => |arr| blk: {
                if (arr.items.len != other.array.items.len) break :blk false;
                for (arr.items, other.array.items) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
            .object => false, // Object equality is complex, skip for now
            .function => |f| f == other.function,
            .userdata => |ud| ud.ptr == other.userdata.ptr,
        };
    }

    /// Get string representation for debugging
    pub fn toString(self: ScriptValue, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .nil => try allocator.dupe(u8, "nil"),
            .boolean => |b| try std.fmt.allocPrint(allocator, "{}", .{b}),
            .integer => |i| try std.fmt.allocPrint(allocator, "{}", .{i}),
            .number => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .string => |s| try std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
            .array => |arr| blk: {
                var list = std.ArrayList(u8).init(allocator);
                try list.append('[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try list.appendSlice(", ");
                    const item_str = try item.toString(allocator);
                    defer allocator.free(item_str);
                    try list.appendSlice(item_str);
                }
                try list.append(']');
                break :blk try list.toOwnedSlice();
            },
            .object => try allocator.dupe(u8, "[object]"),
            .function => try allocator.dupe(u8, "[function]"),
            .userdata => |ud| try std.fmt.allocPrint(allocator, "[userdata: {s}]", .{ud.type_id}),
        };
    }
};

// Import after ScriptValue is defined
const ScriptFunction = @import("interface.zig").ScriptFunction;

// Tests
test "ScriptValue from/to Zig conversions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test basic types
    {
        const val = try ScriptValue.fromZig(bool, true, allocator);
        defer val.deinit(allocator);
        try testing.expect(val.boolean == true);

        const back = try val.toZig(bool, allocator);
        try testing.expect(back == true);
    }

    {
        const val = try ScriptValue.fromZig(i32, 42, allocator);
        defer val.deinit(allocator);
        try testing.expect(val.integer == 42);

        const back = try val.toZig(i32, allocator);
        try testing.expect(back == 42);
    }

    {
        const val = try ScriptValue.fromZig(f64, 3.14, allocator);
        defer val.deinit(allocator);
        try testing.expect(val.number == 3.14);

        const back = try val.toZig(f64, allocator);
        try testing.expect(back == 3.14);
    }

    // Test string
    {
        const str = "hello world";
        const val = try ScriptValue.fromZig([]const u8, str, allocator);
        defer val.deinit(allocator);
        try testing.expectEqualStrings(val.string, str);

        const back = try val.toZig([]const u8, allocator);
        defer allocator.free(back);
        try testing.expectEqualStrings(back, str);
    }

    // Test optional
    {
        const opt: ?i32 = 42;
        const val = try ScriptValue.fromZig(?i32, opt, allocator);
        defer val.deinit(allocator);
        try testing.expect(val.integer == 42);

        const none: ?i32 = null;
        const nil_val = try ScriptValue.fromZig(?i32, none, allocator);
        defer nil_val.deinit(allocator);
        try testing.expect(nil_val == .nil);
    }

    // Test struct
    {
        const TestStruct = struct {
            name: []const u8,
            value: i32,
            enabled: bool,
        };

        const test_struct = TestStruct{
            .name = "test",
            .value = 42,
            .enabled = true,
        };

        const val = try ScriptValue.fromZig(TestStruct, test_struct, allocator);
        defer val.deinit(allocator);

        try testing.expect(val == .object);
        try testing.expectEqualStrings(val.object.get("name").?.string, "test");
        try testing.expect(val.object.get("value").?.integer == 42);
        try testing.expect(val.object.get("enabled").?.boolean == true);
    }
}

test "ScriptValue array operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var array = try ScriptValue.Array.init(allocator, 3);
    defer array.deinit();

    array.items[0] = ScriptValue{ .integer = 1 };
    array.items[1] = ScriptValue{ .string = try allocator.dupe(u8, "hello") };
    array.items[2] = ScriptValue{ .boolean = true };

    const val = ScriptValue{ .array = array };
    _ = val;

    // Note: array is moved into val, so we shouldn't deinit it separately
}

test "ScriptValue object operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var obj = ScriptValue.Object.init(allocator);
    defer obj.deinit();

    try obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, "test") });
    try obj.put("value", ScriptValue{ .integer = 42 });
    try obj.put("enabled", ScriptValue{ .boolean = true });

    try testing.expectEqualStrings(obj.get("name").?.string, "test");
    try testing.expect(obj.get("value").?.integer == 42);
    try testing.expect(obj.get("enabled").?.boolean == true);
    try testing.expect(obj.get("missing") == null);
}

test "ScriptValue equality" {
    const testing = std.testing;

    try testing.expect(ScriptValue.nil.eql(ScriptValue.nil));
    try testing.expect((ScriptValue{ .boolean = true }).eql(ScriptValue{ .boolean = true }));
    try testing.expect(!(ScriptValue{ .boolean = true }).eql(ScriptValue{ .boolean = false }));
    try testing.expect((ScriptValue{ .integer = 42 }).eql(ScriptValue{ .integer = 42 }));
    try testing.expect((ScriptValue{ .float = 3.14 }).eql(ScriptValue{ .float = 3.14 }));
    try testing.expect((ScriptValue{ .string = "hello" }).eql(ScriptValue{ .string = "hello" }));
}
