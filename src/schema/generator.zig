// ABOUTME: JSON Schema generation from Zig type definitions
// ABOUTME: Provides compile-time schema generation for type-safe validation

const std = @import("std");
const validator = @import("validator.zig");

pub const GeneratorOptions = struct {
    // Include descriptions from doc comments
    include_descriptions: bool = true,
    // Mark all fields as required by default
    all_required: bool = true,
    // Allow additional properties in objects
    additional_properties: bool = false,
    // Generate validation constraints from type info
    infer_constraints: bool = true,
    // Add format hints for common types
    add_format_hints: bool = true,
};

pub fn generateSchema(comptime T: type, allocator: std.mem.Allocator, options: GeneratorOptions) !validator.Schema {
    const schema_node = try generateSchemaNode(T, allocator, options);
    return validator.Schema.init(allocator, schema_node);
}

pub fn generateSchemaNode(comptime T: type, allocator: std.mem.Allocator, options: GeneratorOptions) !validator.SchemaNode {
    const type_info = @typeInfo(T);
    
    switch (type_info) {
        .Bool => {
            return validator.SchemaNode{ .boolean = validator.BooleanSchema{} };
        },
        .Int => |int_info| {
            var schema = validator.NumberSchema{};
            
            if (options.infer_constraints) {
                // Set min/max based on integer type
                const int_type = @Type(.{ .Int = int_info });
                if (int_info.signedness == .unsigned) {
                    schema.minimum = 0;
                    schema.maximum = @as(f64, @floatFromInt(std.math.maxInt(int_type)));
                } else {
                    schema.minimum = @as(f64, @floatFromInt(std.math.minInt(int_type)));
                    schema.maximum = @as(f64, @floatFromInt(std.math.maxInt(int_type)));
                }
            }
            
            return validator.SchemaNode{ .number = schema };
        },
        .Float => {
            return validator.SchemaNode{ .number = validator.NumberSchema{} };
        },
        .Optional => |opt_info| {
            // For optionals, create anyOf with null and the actual type
            var schemas = try allocator.alloc(validator.SchemaNode, 2);
            schemas[0] = validator.SchemaNode{ .null = validator.NullSchema{} };
            schemas[1] = try generateSchemaNode(opt_info.child, allocator, options);
            
            return validator.SchemaNode{ .any_of = schemas };
        },
        .Array => |array_info| {
            var schema = validator.ArraySchema{};
            
            if (array_info.len > 0) {
                schema.min_items = array_info.len;
                schema.max_items = array_info.len;
            }
            
            if (array_info.child != u8) { // Not a string
                const item_schema = try allocator.create(validator.SchemaNode);
                item_schema.* = try generateSchemaNode(array_info.child, allocator, options);
                schema.items = item_schema;
            }
            
            return validator.SchemaNode{ .array = schema };
        },
        .Pointer => |ptr_info| {
            switch (ptr_info.size) {
                .Slice => {
                    if (ptr_info.child == u8) {
                        // []u8 or []const u8 -> string
                        const schema = validator.StringSchema{};
                        
                        if (options.add_format_hints) {
                            // Try to infer format from field name in parent struct
                            // This would need more context, so leaving basic for now
                        }
                        
                        return validator.SchemaNode{ .string = schema };
                    } else {
                        // Other slices -> array
                        var schema = validator.ArraySchema{};
                        const item_schema = try allocator.create(validator.SchemaNode);
                        item_schema.* = try generateSchemaNode(ptr_info.child, allocator, options);
                        schema.items = item_schema;
                        
                        return validator.SchemaNode{ .array = schema };
                    }
                },
                .One => {
                    // Single pointer - follow through to child type
                    return generateSchemaNode(ptr_info.child, allocator, options);
                },
                else => return error.UnsupportedType,
            }
        },
        .Struct => |struct_info| {
            var schema = validator.ObjectSchema{
                .properties = std.StringHashMap(validator.SchemaNode).init(allocator),
                .required = &[_][]const u8{},
                .additional_properties = options.additional_properties,
            };
            
            // Collect required fields
            var required_fields = std.ArrayList([]const u8).init(allocator);
            defer required_fields.deinit();
            
            // Process each field
            inline for (struct_info.fields) |field| {
                const field_schema = try generateSchemaNode(field.type, allocator, options);
                try schema.properties.put(field.name, field_schema);
                
                // Check if field is required (not optional)
                const field_type_info = @typeInfo(field.type);
                const is_optional = field_type_info == .Optional;
                
                if (options.all_required and !is_optional) {
                    try required_fields.append(field.name);
                }
            }
            
            schema.required = try required_fields.toOwnedSlice();
            
            return validator.SchemaNode{ .object = schema };
        },
        .Enum => |enum_info| {
            // Enums -> string with enumerated values
            _ = enum_info;
            const schema = validator.StringSchema{};
            
            // TODO: Add enum values as pattern or enum constraint
            // This would require extending the validator to support enum constraints
            
            return validator.SchemaNode{ .string = schema };
        },
        .Union => |union_info| {
            // Unions -> oneOf
            var schemas = try allocator.alloc(validator.SchemaNode, union_info.fields.len);
            
            inline for (union_info.fields, 0..) |field, i| {
                schemas[i] = try generateSchemaNode(field.type, allocator, options);
            }
            
            return validator.SchemaNode{ .one_of = schemas };
        },
        .Void => {
            return validator.SchemaNode{ .null = validator.NullSchema{} };
        },
        else => return error.UnsupportedType,
    }
}

// Helper to generate schema for common patterns
pub fn generateSchemaForApiResponse(comptime T: type, allocator: std.mem.Allocator) !validator.Schema {
    const ResponseWrapper = struct {
        success: bool,
        data: ?T,
        @"error": ?[]const u8,
    };
    
    return generateSchema(ResponseWrapper, allocator, .{
        .all_required = false,
        .additional_properties = true,
    });
}

pub fn generateSchemaForList(comptime T: type, allocator: std.mem.Allocator) !validator.Schema {
    const ListWrapper = struct {
        items: []T,
        total: usize,
        page: ?usize,
        per_page: ?usize,
    };
    
    return generateSchema(ListWrapper, allocator, .{
        .all_required = false,
    });
}

// Compile-time schema generation with validation
pub fn SchemaValidated(comptime T: type) type {
    return struct {
        value: T,
        
        const Self = @This();
        
        pub fn init(value: T) Self {
            return .{ .value = value };
        }
        
        pub fn validate(self: *const Self, allocator: std.mem.Allocator) !bool {
            const schema = try generateSchema(T, allocator, .{});
            defer schema.deinit();
            
            // Convert value to JSON for validation
            const json_string = try std.json.stringifyAlloc(allocator, self.value, .{});
            defer allocator.free(json_string);
            
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_string, .{});
            defer parsed.deinit();
            
            const result = try schema.validate(parsed.value);
            return result.valid;
        }
    };
}

// Tests
test "generate schema for basic types" {
    const allocator = std.testing.allocator;
    
    // Boolean
    var bool_schema = try generateSchema(bool, allocator, .{});
    defer bool_schema.deinit();
    try std.testing.expect(bool_schema.root == .boolean);
    
    // Integer
    var int_schema = try generateSchema(u32, allocator, .{});
    defer int_schema.deinit();
    try std.testing.expect(int_schema.root == .number);
    
    // String ([]const u8)
    var string_schema = try generateSchema([]const u8, allocator, .{});
    defer string_schema.deinit();
    try std.testing.expect(string_schema.root == .string);
}

test "generate schema for struct" {
    const allocator = std.testing.allocator;
    
    const User = struct {
        id: u64,
        name: []const u8,
        email: []const u8,
        age: ?u8,
        active: bool,
    };
    
    var schema = try generateSchema(User, allocator, .{});
    defer schema.deinit();
    
    try std.testing.expect(schema.root == .object);
    const obj_schema = schema.root.object;
    
    // Check properties exist
    try std.testing.expect(obj_schema.properties.contains("id"));
    try std.testing.expect(obj_schema.properties.contains("name"));
    try std.testing.expect(obj_schema.properties.contains("email"));
    try std.testing.expect(obj_schema.properties.contains("age"));
    try std.testing.expect(obj_schema.properties.contains("active"));
    
    // Check required fields (age is optional, so should have 4 required)
    try std.testing.expectEqual(@as(usize, 4), obj_schema.required.len);
}

test "generate schema for optional types" {
    const allocator = std.testing.allocator;
    
    var schema = try generateSchema(?u32, allocator, .{});
    defer schema.deinit();
    
    try std.testing.expect(schema.root == .any_of);
    try std.testing.expectEqual(@as(usize, 2), schema.root.any_of.len);
    try std.testing.expect(schema.root.any_of[0] == .null);
    try std.testing.expect(schema.root.any_of[1] == .number);
}

test "schema validated wrapper" {
    const allocator = std.testing.allocator;
    
    const Config = struct {
        host: []const u8,
        port: u16,
        secure: bool,
    };
    
    const ValidatedConfig = SchemaValidated(Config);
    
    const config = ValidatedConfig.init(.{
        .host = "localhost",
        .port = 8080,
        .secure = true,
    });
    
    try std.testing.expect(try config.validate(allocator));
}