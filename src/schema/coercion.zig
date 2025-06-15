// ABOUTME: Type coercion utilities for converting values to match schema types
// ABOUTME: Provides safe conversion between compatible JSON types with validation

const std = @import("std");
const validator = @import("validator.zig");

pub const CoercionOptions = struct {
    // String to number conversion
    string_to_number: bool = true,
    // Number to string conversion  
    number_to_string: bool = true,
    // String to boolean conversion ("true"/"false", "1"/"0", "yes"/"no")
    string_to_boolean: bool = true,
    // Number to boolean conversion (0 = false, non-zero = true)
    number_to_boolean: bool = true,
    // Null to default values
    null_to_defaults: bool = true,
    // Trim whitespace from strings
    trim_strings: bool = true,
    // Convert string case
    string_case: ?StringCase = null,
    
    pub const StringCase = enum {
        lower,
        upper,
        title,
    };
};

pub const CoercionResult = struct {
    value: std.json.Value,
    coerced: bool,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *CoercionResult) void {
        if (self.coerced) {
            // Clean up allocated memory for coerced values
            switch (self.value) {
                .string => |s| self.allocator.free(s),
                .object => |*obj| {
                    var iter = obj.iterator();
                    while (iter.next()) |entry| {
                        self.allocator.free(entry.key_ptr.*);
                    }
                    obj.deinit();
                },
                .array => |*arr| arr.deinit(),
                else => {},
            }
        }
    }
};

pub fn coerceToSchema(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    schema_node: validator.SchemaNode,
    options: CoercionOptions,
) !CoercionResult {
    switch (schema_node) {
        .string => return coerceToString(allocator, value, options),
        .number => return coerceToNumber(allocator, value, options),
        .boolean => return coerceToBoolean(allocator, value, options),
        .null => return coerceToNull(allocator, value, options),
        .array => |array_schema| return coerceToArray(allocator, value, array_schema, options),
        .object => |object_schema| return coerceToObject(allocator, value, object_schema, options),
        .any_of => |schemas| {
            // Try each schema in order until one succeeds
            for (schemas) |schema| {
                if (coerceToSchema(allocator, value, schema, options)) |result| {
                    return result;
                } else |_| {
                    continue;
                }
            }
            return error.NoMatchingSchema;
        },
        .all_of => {
            // For all_of, we can't really coerce - the value must satisfy all schemas
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        .one_of => |schemas| {
            // Try to find exactly one schema that matches
            var matches: u32 = 0;
            var result: ?CoercionResult = null;
            
            for (schemas) |schema| {
                if (coerceToSchema(allocator, value, schema, options)) |coerced| {
                    matches += 1;
                    if (result) |*r| r.deinit();
                    result = coerced;
                } else |_| {}
            }
            
            if (matches == 1 and result != null) {
                return result.?;
            }
            
            if (result) |*r| r.deinit();
            return error.NotExactlyOneMatch;
        },
    }
}

fn coerceToString(allocator: std.mem.Allocator, value: std.json.Value, options: CoercionOptions) !CoercionResult {
    switch (value) {
        .string => |s| {
            if (options.trim_strings or options.string_case != null) {
                var processed = s;
                
                // Trim whitespace
                if (options.trim_strings) {
                    processed = std.mem.trim(u8, processed, " \t\r\n");
                }
                
                // Convert case
                const final_string = if (options.string_case) |case| blk: {
                    const result = try allocator.alloc(u8, processed.len);
                    switch (case) {
                        .lower => {
                            for (processed, 0..) |c, i| {
                                result[i] = std.ascii.toLower(c);
                            }
                        },
                        .upper => {
                            for (processed, 0..) |c, i| {
                                result[i] = std.ascii.toUpper(c);
                            }
                        },
                        .title => {
                            var word_start = true;
                            for (processed, 0..) |c, i| {
                                if (std.ascii.isWhitespace(c)) {
                                    result[i] = c;
                                    word_start = true;
                                } else if (word_start) {
                                    result[i] = std.ascii.toUpper(c);
                                    word_start = false;
                                } else {
                                    result[i] = std.ascii.toLower(c);
                                }
                            }
                        },
                    }
                    break :blk result;
                } else if (options.trim_strings and processed.len != s.len) blk: {
                    break :blk try allocator.dupe(u8, processed);
                } else blk: {
                    break :blk s;
                };
                
                return CoercionResult{
                    .value = .{ .string = final_string },
                    .coerced = final_string.ptr != s.ptr,
                    .allocator = allocator,
                };
            }
            
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        .integer => |i| {
            if (options.number_to_string) {
                const str = try std.fmt.allocPrint(allocator, "{d}", .{i});
                return CoercionResult{
                    .value = .{ .string = str },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        .float => |f| {
            if (options.number_to_string) {
                const str = try std.fmt.allocPrint(allocator, "{d}", .{f});
                return CoercionResult{
                    .value = .{ .string = str },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        .bool => |b| {
            if (options.number_to_string) {
                const str = try allocator.dupe(u8, if (b) "true" else "false");
                return CoercionResult{
                    .value = .{ .string = str },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        .null => {
            if (options.null_to_defaults) {
                const str = try allocator.dupe(u8, "");
                return CoercionResult{
                    .value = .{ .string = str },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        else => return error.CannotCoerce,
    }
}

fn coerceToNumber(allocator: std.mem.Allocator, value: std.json.Value, options: CoercionOptions) !CoercionResult {
    switch (value) {
        .integer, .float => {
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        .string => |s| {
            if (options.string_to_number) {
                const trimmed = std.mem.trim(u8, s, " \t\r\n");
                
                // Try parsing as integer first
                if (std.fmt.parseInt(i64, trimmed, 10)) |i| {
                    return CoercionResult{
                        .value = .{ .integer = i },
                        .coerced = true,
                        .allocator = allocator,
                    };
                } else |_| {}
                
                // Try parsing as float
                if (std.fmt.parseFloat(f64, trimmed)) |f| {
                    return CoercionResult{
                        .value = .{ .float = f },
                        .coerced = true,
                        .allocator = allocator,
                    };
                } else |_| {}
            }
            return error.CannotCoerce;
        },
        .bool => |b| {
            if (options.number_to_boolean) {
                return CoercionResult{
                    .value = .{ .integer = if (b) 1 else 0 },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        .null => {
            if (options.null_to_defaults) {
                return CoercionResult{
                    .value = .{ .integer = 0 },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        else => return error.CannotCoerce,
    }
}

fn coerceToBoolean(allocator: std.mem.Allocator, value: std.json.Value, options: CoercionOptions) !CoercionResult {
    switch (value) {
        .bool => {
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        .string => |s| {
            if (options.string_to_boolean) {
                const lower = std.ascii.lowerString(s, try allocator.alloc(u8, s.len));
                defer allocator.free(lower);
                
                const is_true = std.mem.eql(u8, lower, "true") or
                    std.mem.eql(u8, lower, "yes") or
                    std.mem.eql(u8, lower, "1") or
                    std.mem.eql(u8, lower, "on");
                    
                const is_false = std.mem.eql(u8, lower, "false") or
                    std.mem.eql(u8, lower, "no") or
                    std.mem.eql(u8, lower, "0") or
                    std.mem.eql(u8, lower, "off");
                
                if (is_true) {
                    return CoercionResult{
                        .value = .{ .bool = true },
                        .coerced = true,
                        .allocator = allocator,
                    };
                } else if (is_false) {
                    return CoercionResult{
                        .value = .{ .bool = false },
                        .coerced = true,
                        .allocator = allocator,
                    };
                }
            }
            return error.CannotCoerce;
        },
        .integer => |i| {
            if (options.number_to_boolean) {
                return CoercionResult{
                    .value = .{ .bool = i != 0 },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        .float => |f| {
            if (options.number_to_boolean) {
                return CoercionResult{
                    .value = .{ .bool = f != 0.0 },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        .null => {
            if (options.null_to_defaults) {
                return CoercionResult{
                    .value = .{ .bool = false },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            return error.CannotCoerce;
        },
        else => return error.CannotCoerce,
    }
}

fn coerceToNull(allocator: std.mem.Allocator, value: std.json.Value, options: CoercionOptions) !CoercionResult {
    _ = options;
    
    switch (value) {
        .null => {
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        else => return error.CannotCoerce,
    }
}

fn coerceToArray(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    array_schema: validator.ArraySchema,
    options: CoercionOptions,
) !CoercionResult {
    switch (value) {
        .array => |arr| {
            if (array_schema.items) |item_schema| {
                var coerced_items = std.ArrayList(std.json.Value).init(allocator);
                errdefer coerced_items.deinit();
                
                var any_coerced = false;
                
                for (arr.items) |item| {
                    const result = try coerceToSchema(allocator, item, item_schema.*, options);
                    try coerced_items.append(result.value);
                    if (result.coerced) {
                        any_coerced = true;
                    }
                }
                
                if (any_coerced) {
                    return CoercionResult{
                        .value = .{ .array = coerced_items },
                        .coerced = true,
                        .allocator = allocator,
                    };
                }
            }
            
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        else => return error.CannotCoerce,
    }
}

fn coerceToObject(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    object_schema: validator.ObjectSchema,
    options: CoercionOptions,
) !CoercionResult {
    switch (value) {
        .object => |obj| {
            var coerced_obj = std.json.ObjectMap.init(allocator);
            errdefer coerced_obj.deinit();
            
            var any_coerced = false;
            
            // Process existing properties
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                
                // Check if property has a schema
                if (object_schema.properties.get(key)) |prop_schema| {
                    const result = try coerceToSchema(allocator, val, prop_schema, options);
                    try coerced_obj.put(try allocator.dupe(u8, key), result.value);
                    if (result.coerced) {
                        any_coerced = true;
                    }
                } else if (object_schema.additional_properties) {
                    // Keep additional properties as-is
                    try coerced_obj.put(try allocator.dupe(u8, key), val);
                }
                // Else: drop additional properties if not allowed
            }
            
            // Add defaults for missing required properties
            if (options.null_to_defaults) {
                for (object_schema.required) |req_prop| {
                    if (!coerced_obj.contains(req_prop)) {
                        if (object_schema.properties.get(req_prop)) |prop_schema| {
                            if (getDefaultForSchema(prop_schema)) |default| {
                                try coerced_obj.put(try allocator.dupe(u8, req_prop), default);
                                any_coerced = true;
                            }
                        }
                    }
                }
            }
            
            if (any_coerced) {
                return CoercionResult{
                    .value = .{ .object = coerced_obj },
                    .coerced = true,
                    .allocator = allocator,
                };
            }
            
            return CoercionResult{
                .value = value,
                .coerced = false,
                .allocator = allocator,
            };
        },
        else => return error.CannotCoerce,
    }
}

fn getDefaultForSchema(schema_node: validator.SchemaNode) ?std.json.Value {
    return switch (schema_node) {
        .string => .{ .string = "" },
        .number => .{ .integer = 0 },
        .boolean => .{ .bool = false },
        .array => .{ .array = std.json.Array.init(std.heap.page_allocator) },
        .object => .{ .object = std.json.ObjectMap.init(std.heap.page_allocator) },
        .null => .{ .null = {} },
        else => null,
    };
}

// Tests
test "coerce string to number" {
    const allocator = std.testing.allocator;
    const options = CoercionOptions{};
    
    const string_value = std.json.Value{ .string = "42" };
    const number_schema = validator.SchemaNode{ .number = validator.NumberSchema{} };
    
    var result = try coerceToSchema(allocator, string_value, number_schema, options);
    defer result.deinit();
    
    try std.testing.expect(result.coerced);
    try std.testing.expectEqual(std.json.Value{ .integer = 42 }, result.value);
}

test "coerce with string trimming" {
    const allocator = std.testing.allocator;
    const options = CoercionOptions{ .trim_strings = true };
    
    const string_value = std.json.Value{ .string = "  hello  " };
    const string_schema = validator.SchemaNode{ .string = validator.StringSchema{} };
    
    var result = try coerceToSchema(allocator, string_value, string_schema, options);
    defer result.deinit();
    
    try std.testing.expect(result.coerced);
    try std.testing.expectEqualStrings("hello", result.value.string);
}

test "coerce string to boolean" {
    const allocator = std.testing.allocator;
    const options = CoercionOptions{};
    
    const true_values = [_][]const u8{ "true", "yes", "1", "on" };
    const false_values = [_][]const u8{ "false", "no", "0", "off" };
    
    const bool_schema = validator.SchemaNode{ .boolean = validator.BooleanSchema{} };
    
    for (true_values) |val| {
        const string_value = std.json.Value{ .string = val };
        var result = try coerceToSchema(allocator, string_value, bool_schema, options);
        defer result.deinit();
        
        try std.testing.expect(result.coerced);
        try std.testing.expect(result.value.bool);
    }
    
    for (false_values) |val| {
        const string_value = std.json.Value{ .string = val };
        var result = try coerceToSchema(allocator, string_value, bool_schema, options);
        defer result.deinit();
        
        try std.testing.expect(result.coerced);
        try std.testing.expect(!result.value.bool);
    }
}