// ABOUTME: JSON Schema validation implementation for structured data
// ABOUTME: Validates JSON values against schema definitions with type checking

const std = @import("std");

pub const Schema = struct {
    root: SchemaNode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, root: SchemaNode) Schema {
        return Schema{
            .root = root,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const Schema) void {
        var mut_root = self.root;
        mut_root.deinit(self.allocator);
    }

    pub fn validate(self: *const Schema, value: std.json.Value) !ValidationResult {
        return self.root.validate(value, self.allocator);
    }
};

pub const SchemaNode = union(enum) {
    object: ObjectSchema,
    array: ArraySchema,
    string: StringSchema,
    number: NumberSchema,
    boolean: BooleanSchema,
    null: NullSchema,
    any_of: []const SchemaNode,
    all_of: []const SchemaNode,
    one_of: []const SchemaNode,

    pub fn deinit(self: *SchemaNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .object => |*schema| {
                schema.deinit(allocator);
            },
            .any_of, .all_of, .one_of => |schemas| {
                for (schemas) |*schema| {
                    var mut_schema = schema;
                    mut_schema.deinit(allocator);
                }
                allocator.free(schemas);
            },
            else => {},
        }
    }

    pub fn validate(self: *const SchemaNode, value: std.json.Value, allocator: std.mem.Allocator) !ValidationResult {
        switch (self.*) {
            .object => |schema| return schema.validate(value),
            .array => |schema| return schema.validate(value),
            .string => |schema| return schema.validate(value),
            .number => |schema| return schema.validate(value),
            .boolean => |schema| return schema.validate(value),
            .null => |schema| return schema.validate(value),
            .any_of => |schemas| {
                for (schemas) |schema| {
                    if (schema.validate(value, allocator)) |_| {
                        return ValidationResult{ .valid = true };
                    } else |_| {
                        continue;
                    }
                }
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "No schema in anyOf matched" }},
                };
            },
            .all_of => |schemas| {
                for (schemas) |schema| {
                    const result = try schema.validate(value, allocator);
                    if (!result.valid) return result;
                }
                return ValidationResult{ .valid = true };
            },
            .one_of => |schemas| {
                var matches: u32 = 0;
                for (schemas) |schema| {
                    if (schema.validate(value, allocator)) |_| {
                        matches += 1;
                    } else |_| {}
                }
                if (matches == 1) {
                    return ValidationResult{ .valid = true };
                }
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Expected exactly one schema to match in oneOf" }},
                };
            },
        }
    }
};

pub const ObjectSchema = struct {
    properties: std.StringHashMap(SchemaNode),
    required: []const []const u8,
    additional_properties: bool = true,

    pub fn deinit(self: *ObjectSchema, allocator: std.mem.Allocator) void {
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            var schema = entry.value_ptr.*;
            schema.deinit(allocator);
        }
        self.properties.deinit();
        if (self.required.len > 0) {
            allocator.free(self.required);
        }
    }

    pub fn validate(self: *const ObjectSchema, value: std.json.Value) !ValidationResult {
        if (value != .object) {
            return ValidationResult{
                .valid = false,
                .errors = &[_]ValidationError{.{ .message = "Expected object" }},
            };
        }

        // Check required properties
        for (self.required) |prop| {
            if (value.object.get(prop) == null) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Missing required property", .path = prop }},
                };
            }
        }

        // Validate property schemas
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            const prop_name = entry.key_ptr.*;
            const prop_schema = entry.value_ptr.*;

            if (value.object.get(prop_name)) |prop_value| {
                const result = try prop_schema.validate(prop_value, self.properties.allocator);
                if (!result.valid) {
                    return result;
                }
            }
        }

        // Check for additional properties if not allowed
        if (!self.additional_properties) {
            var obj_iter = value.object.iterator();
            while (obj_iter.next()) |entry| {
                if (!self.properties.contains(entry.key_ptr.*)) {
                    return ValidationResult{
                        .valid = false,
                        .errors = &[_]ValidationError{.{ .message = "Additional properties not allowed", .path = entry.key_ptr.* }},
                    };
                }
            }
        }

        return ValidationResult{ .valid = true };
    }
};

pub const ArraySchema = struct {
    items: ?*const SchemaNode = null,
    min_items: ?usize = null,
    max_items: ?usize = null,

    pub fn validate(self: *const ArraySchema, value: std.json.Value) !ValidationResult {
        if (value != .array) {
            return ValidationResult{
                .valid = false,
                .errors = &[_]ValidationError{.{ .message = "Expected array" }},
            };
        }

        if (self.min_items) |min| {
            if (value.array.items.len < min) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Array too short" }},
                };
            }
        }

        if (self.max_items) |max| {
            if (value.array.items.len > max) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Array too long" }},
                };
            }
        }

        // Validate each item if item schema is provided
        if (self.items) |item_schema| {
            for (value.array.items, 0..) |item, index| {
                const result = try item_schema.validate(item, value.array.allocator);
                if (!result.valid) {
                    // Create error with array index in path
                    var path_buf: [256]u8 = undefined;
                    const path = try std.fmt.bufPrint(&path_buf, "[{d}]", .{index});
                    return ValidationResult{
                        .valid = false,
                        .errors = &[_]ValidationError{.{ .message = result.errors[0].message, .path = path }},
                    };
                }
            }
        }

        return ValidationResult{ .valid = true };
    }
};

pub const StringSchema = struct {
    min_length: ?usize = null,
    max_length: ?usize = null,
    pattern: ?[]const u8 = null,
    format: ?StringFormat = null,

    pub const StringFormat = enum {
        date_time,
        date,
        time,
        email,
        uri,
        uuid,
    };

    pub fn validate(self: *const StringSchema, value: std.json.Value) !ValidationResult {
        if (value != .string) {
            return ValidationResult{
                .valid = false,
                .errors = &[_]ValidationError{.{ .message = "Expected string" }},
            };
        }

        if (self.min_length) |min| {
            if (value.string.len < min) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "String too short" }},
                };
            }
        }

        if (self.max_length) |max| {
            if (value.string.len > max) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "String too long" }},
                };
            }
        }

        // Pattern validation (basic regex-like patterns)
        if (self.pattern) |pattern| {
            if (!matchesPattern(value.string, pattern)) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "String does not match pattern" }},
                };
            }
        }

        // Format validation
        if (self.format) |format| {
            const is_valid = switch (format) {
                .email => isValidEmail(value.string),
                .uri => isValidUri(value.string),
                .uuid => isValidUuid(value.string),
                .date => isValidDate(value.string),
                .date_time => isValidDateTime(value.string),
                .time => isValidTime(value.string),
            };

            if (!is_valid) {
                var msg_buf: [128]u8 = undefined;
                const msg = try std.fmt.bufPrint(&msg_buf, "Invalid {s} format", .{@tagName(format)});
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = msg }},
                };
            }
        }

        return ValidationResult{ .valid = true };
    }
};

pub const NumberSchema = struct {
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    exclusive_minimum: ?f64 = null,
    exclusive_maximum: ?f64 = null,
    multiple_of: ?f64 = null,

    pub fn validate(self: *const NumberSchema, value: std.json.Value) !ValidationResult {
        const num = switch (value) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return ValidationResult{
                .valid = false,
                .errors = &[_]ValidationError{.{ .message = "Expected number" }},
            },
        };

        if (self.minimum) |min| {
            if (num < min) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Number too small" }},
                };
            }
        }

        if (self.maximum) |max| {
            if (num > max) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Number too large" }},
                };
            }
        }

        if (self.exclusive_minimum) |min| {
            if (num <= min) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Number not greater than exclusive minimum" }},
                };
            }
        }

        if (self.exclusive_maximum) |max| {
            if (num >= max) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Number not less than exclusive maximum" }},
                };
            }
        }

        if (self.multiple_of) |multiple| {
            const remainder = @mod(num, multiple);
            if (remainder != 0) {
                return ValidationResult{
                    .valid = false,
                    .errors = &[_]ValidationError{.{ .message = "Number is not a multiple of specified value" }},
                };
            }
        }

        return ValidationResult{ .valid = true };
    }
};

pub const BooleanSchema = struct {
    pub fn validate(self: *const BooleanSchema, value: std.json.Value) !ValidationResult {
        _ = self;
        if (value != .bool) {
            return ValidationResult{
                .valid = false,
                .errors = &[_]ValidationError{.{ .message = "Expected boolean" }},
            };
        }
        return ValidationResult{ .valid = true };
    }
};

pub const NullSchema = struct {
    pub fn validate(self: *const NullSchema, value: std.json.Value) !ValidationResult {
        _ = self;
        if (value != .null) {
            return ValidationResult{
                .valid = false,
                .errors = &[_]ValidationError{.{ .message = "Expected null" }},
            };
        }
        return ValidationResult{ .valid = true };
    }
};

pub const ValidationResult = struct {
    valid: bool,
    errors: []const ValidationError = &[_]ValidationError{},
};

pub const ValidationError = struct {
    message: []const u8,
    path: ?[]const u8 = null,
};

// Helper functions for string validation

fn matchesPattern(str: []const u8, pattern: []const u8) bool {
    // Simple pattern matching (not full regex)
    // Supports * (zero or more chars) and ? (single char)
    var s_idx: usize = 0;
    var p_idx: usize = 0;
    var star_idx: ?usize = null;
    var s_star: usize = 0;

    while (s_idx < str.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == str[s_idx])) {
            s_idx += 1;
            p_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            star_idx = p_idx;
            s_star = s_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            p_idx = star_idx.? + 1;
            s_star += 1;
            s_idx = s_star;
        } else {
            return false;
        }
    }

    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }

    return p_idx == pattern.len;
}

fn isValidEmail(email: []const u8) bool {
    // Basic email validation
    var at_count: u32 = 0;
    var at_pos: ?usize = null;

    for (email, 0..) |char, i| {
        if (char == '@') {
            at_count += 1;
            at_pos = i;
        }
    }

    if (at_count != 1) return false;
    if (at_pos == null or at_pos.? == 0 or at_pos.? == email.len - 1) return false;

    // Check for dot after @
    const domain = email[at_pos.? + 1 ..];
    return std.mem.indexOf(u8, domain, ".") != null;
}

fn isValidUri(uri: []const u8) bool {
    // Basic URI validation - check for scheme://
    return std.mem.indexOf(u8, uri, "://") != null;
}

fn isValidUuid(uuid: []const u8) bool {
    // UUID v4 format: 8-4-4-4-12 hexadecimal digits
    if (uuid.len != 36) return false;

    const expected_dashes = [_]usize{ 8, 13, 18, 23 };
    for (expected_dashes) |pos| {
        if (uuid[pos] != '-') return false;
    }

    for (uuid, 0..) |char, i| {
        if (std.mem.indexOfScalar(usize, &expected_dashes, i) != null) continue;
        if (!std.ascii.isHex(char)) return false;
    }

    return true;
}

fn isValidDate(date: []const u8) bool {
    // ISO 8601 date format: YYYY-MM-DD
    if (date.len != 10) return false;
    if (date[4] != '-' or date[7] != '-') return false;

    const year = std.fmt.parseInt(u32, date[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u32, date[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u32, date[8..10], 10) catch return false;

    return year >= 1 and year <= 9999 and month >= 1 and month <= 12 and day >= 1 and day <= 31;
}

fn isValidDateTime(datetime: []const u8) bool {
    // ISO 8601 datetime format: YYYY-MM-DDTHH:MM:SS[.sss][Z|+/-HH:MM]
    if (datetime.len < 19) return false;
    if (datetime[10] != 'T') return false;

    return isValidDate(datetime[0..10]) and isValidTime(datetime[11..]);
}

fn isValidTime(time: []const u8) bool {
    // Time format: HH:MM:SS[.sss]
    if (time.len < 8) return false;
    if (time[2] != ':' or time[5] != ':') return false;

    const hour = std.fmt.parseInt(u32, time[0..2], 10) catch return false;
    const minute = std.fmt.parseInt(u32, time[3..5], 10) catch return false;
    const second = std.fmt.parseInt(u32, time[6..8], 10) catch return false;

    return hour <= 23 and minute <= 59 and second <= 59;
}

// Tests
test "basic type validation" {
    const allocator = std.testing.allocator;

    // String validation
    var string_schema = Schema.init(allocator, .{ .string = StringSchema{} });
    defer string_schema.deinit();

    const valid_string = std.json.Value{ .string = "hello" };
    const invalid_string = std.json.Value{ .integer = 42 };

    try std.testing.expect((try string_schema.validate(valid_string)).valid);
    try std.testing.expect(!(try string_schema.validate(invalid_string)).valid);

    // Number validation
    var number_schema = Schema.init(allocator, .{ .number = NumberSchema{
        .minimum = 0,
        .maximum = 100,
    } });
    defer number_schema.deinit();

    const valid_number = std.json.Value{ .integer = 50 };
    const invalid_number = std.json.Value{ .integer = 150 };

    try std.testing.expect((try number_schema.validate(valid_number)).valid);
    try std.testing.expect(!(try number_schema.validate(invalid_number)).valid);
}

test "string format validation" {
    const allocator = std.testing.allocator;

    // Email validation
    var email_schema = Schema.init(allocator, .{ .string = StringSchema{ .format = .email } });
    defer email_schema.deinit();

    const valid_email = std.json.Value{ .string = "user@example.com" };
    const invalid_email = std.json.Value{ .string = "not-an-email" };

    try std.testing.expect((try email_schema.validate(valid_email)).valid);
    try std.testing.expect(!(try email_schema.validate(invalid_email)).valid);

    // UUID validation
    var uuid_schema = Schema.init(allocator, .{ .string = StringSchema{ .format = .uuid } });
    defer uuid_schema.deinit();

    const valid_uuid = std.json.Value{ .string = "550e8400-e29b-41d4-a716-446655440000" };
    const invalid_uuid = std.json.Value{ .string = "not-a-uuid" };

    try std.testing.expect((try uuid_schema.validate(valid_uuid)).valid);
    try std.testing.expect(!(try uuid_schema.validate(invalid_uuid)).valid);
}

test "pattern matching" {
    try std.testing.expect(matchesPattern("hello", "hello"));
    try std.testing.expect(matchesPattern("hello", "h*o"));
    try std.testing.expect(matchesPattern("hello", "h?llo"));
    try std.testing.expect(matchesPattern("hello world", "*world"));
    try std.testing.expect(matchesPattern("hello world", "hello*"));
    try std.testing.expect(!matchesPattern("hello", "goodbye"));
    try std.testing.expect(!matchesPattern("hello", "h?o"));
}
