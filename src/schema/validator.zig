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
    
    pub fn deinit(self: *Schema) void {
        // TODO: Cleanup schema nodes
        _ = self;
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
        
        // TODO: Validate property schemas
        
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
        
        // TODO: Pattern and format validation
        
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