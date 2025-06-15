// ABOUTME: Schema-guided extraction for structured data from LLM outputs
// ABOUTME: Uses JSON schemas to guide parsing and extract specific data structures

const std = @import("std");
const parser = @import("parser.zig");
const registry = @import("registry.zig");
const schema_mod = @import("../schema/validator.zig");
const coercion = @import("../schema/coercion.zig");

pub const ExtractionOptions = struct {
    // Coerce values to match schema types
    enable_coercion: bool = true,
    // Coercion options
    coercion_options: coercion.CoercionOptions = .{},
    // Parse options for underlying parser
    parse_options: parser.ParseOptions = .{},
    // Extract nested objects as separate results
    extract_nested: bool = false,
    // Provide default values for missing required fields
    use_defaults: bool = true,
    // Maximum nesting depth for extraction
    max_depth: u32 = 10,
};

pub const ExtractionResult = struct {
    value: std.json.Value,
    source_format: parser.ParseOptions.Format,
    extracted_fields: []const []const u8,
    coerced_fields: []const []const u8 = &[_][]const u8{},
    defaulted_fields: []const []const u8 = &[_][]const u8{},
    validation_result: ?schema_mod.ValidationResult = null,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ExtractionResult) void {
        if (self.extracted_fields.len > 0) {
            self.allocator.free(self.extracted_fields);
        }
        if (self.coerced_fields.len > 0) {
            self.allocator.free(self.coerced_fields);
        }
        if (self.defaulted_fields.len > 0) {
            self.allocator.free(self.defaulted_fields);
        }
    }
};

pub const SchemaExtractor = struct {
    allocator: std.mem.Allocator,
    schema: schema_mod.Schema,
    
    pub fn init(allocator: std.mem.Allocator, schema: schema_mod.Schema) SchemaExtractor {
        return .{
            .allocator = allocator,
            .schema = schema,
        };
    }
    
    pub fn extract(
        self: *SchemaExtractor,
        input: []const u8,
        options: ExtractionOptions,
    ) !ExtractionResult {
        // Parse the input
        var parse_opts = options.parse_options;
        parse_opts.validation_schema = self.schema;
        parse_opts.strict = false; // We'll handle validation separately
        
        var parse_result = try registry.parseAny(self.allocator, input, parse_opts);
        defer parse_result.deinit();
        
        if (!parse_result.success and !parse_opts.allow_partial) {
            return error.ParseFailed;
        }
        
        // Extract according to schema
        const extraction = try self.extractFromValue(
            parse_result.value,
            self.schema.root,
            options,
            0,
        );
        
        // Validate the extracted value
        const validation_result = if (options.parse_options.validation_schema != null)
            try self.schema.validate(extraction.value)
        else
            null;
        
        return ExtractionResult{
            .value = extraction.value,
            .source_format = parse_result.format,
            .extracted_fields = extraction.extracted_fields,
            .coerced_fields = extraction.coerced_fields,
            .defaulted_fields = extraction.defaulted_fields,
            .validation_result = validation_result,
            .allocator = self.allocator,
        };
    }
    
    const ExtractedData = struct {
        value: std.json.Value,
        extracted_fields: []const []const u8,
        coerced_fields: []const []const u8,
        defaulted_fields: []const []const u8,
    };
    
    fn extractFromValue(
        self: *SchemaExtractor,
        value: std.json.Value,
        schema_node: schema_mod.SchemaNode,
        options: ExtractionOptions,
        depth: u32,
    ) !ExtractedData {
        if (depth > options.max_depth) {
            return error.MaxDepthExceeded;
        }
        
        var extracted_fields = std.ArrayList([]const u8).init(self.allocator);
        defer extracted_fields.deinit();
        
        var coerced_fields = std.ArrayList([]const u8).init(self.allocator);
        defer coerced_fields.deinit();
        
        var defaulted_fields = std.ArrayList([]const u8).init(self.allocator);
        defer defaulted_fields.deinit();
        
        const result_value = switch (schema_node) {
            .object => |obj_schema| try self.extractObject(
                value,
                obj_schema,
                options,
                &extracted_fields,
                &coerced_fields,
                &defaulted_fields,
                depth,
            ),
            .array => |arr_schema| try self.extractArray(
                value,
                arr_schema,
                options,
                &extracted_fields,
                &coerced_fields,
                &defaulted_fields,
                depth,
            ),
            .any_of => |schemas| try self.extractAnyOf(
                value,
                schemas,
                options,
                &extracted_fields,
                &coerced_fields,
                &defaulted_fields,
                depth,
            ),
            .one_of => |schemas| try self.extractOneOf(
                value,
                schemas,
                options,
                &extracted_fields,
                &coerced_fields,
                &defaulted_fields,
                depth,
            ),
            else => blk: {
                // For primitive types, try coercion if enabled
                if (options.enable_coercion) {
                    const coercion_result = coercion.coerceToSchema(
                        self.allocator,
                        value,
                        schema_node,
                        options.coercion_options,
                    ) catch {
                        break :blk value;
                    };
                    
                    if (coercion_result.coerced) {
                        try coerced_fields.append(try self.allocator.dupe(u8, "value"));
                    }
                    
                    break :blk coercion_result.value;
                } else {
                    break :blk value;
                }
            },
        };
        
        return ExtractedData{
            .value = result_value,
            .extracted_fields = try extracted_fields.toOwnedSlice(),
            .coerced_fields = try coerced_fields.toOwnedSlice(),
            .defaulted_fields = try defaulted_fields.toOwnedSlice(),
        };
    }
    
    fn extractObject(
        self: *SchemaExtractor,
        value: std.json.Value,
        obj_schema: schema_mod.ObjectSchema,
        options: ExtractionOptions,
        extracted_fields: *std.ArrayList([]const u8),
        coerced_fields: *std.ArrayList([]const u8),
        defaulted_fields: *std.ArrayList([]const u8),
        depth: u32,
    ) !std.json.Value {
        const source_obj = switch (value) {
            .object => |obj| obj,
            else => {
                if (options.enable_coercion) {
                    // Try to coerce to object
                    const coercion_result = try coercion.coerceToSchema(
                        self.allocator,
                        value,
                        .{ .object = obj_schema },
                        options.coercion_options,
                    );
                    if (coercion_result.coerced) {
                        try coerced_fields.append(try self.allocator.dupe(u8, "root"));
                    }
                    return coercion_result.value;
                }
                return error.TypeMismatch;
            },
        };
        
        var result = std.json.ObjectMap.init(self.allocator);
        errdefer result.deinit();
        
        // Extract properties defined in schema
        var prop_iter = obj_schema.properties.iterator();
        while (prop_iter.next()) |entry| {
            const prop_name = entry.key_ptr.*;
            const prop_schema = entry.value_ptr.*;
            
            if (source_obj.get(prop_name)) |prop_value| {
                // Property exists, extract it
                const extracted = try self.extractFromValue(
                    prop_value,
                    prop_schema,
                    options,
                    depth + 1,
                );
                
                try result.put(try self.allocator.dupe(u8, prop_name), extracted.value);
                try extracted_fields.append(try self.allocator.dupe(u8, prop_name));
                
                // Track coerced fields
                for (extracted.coerced_fields) |field| {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prop_name, field });
                    try coerced_fields.append(full_path);
                }
                
                // Track defaulted fields
                for (extracted.defaulted_fields) |field| {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prop_name, field });
                    try defaulted_fields.append(full_path);
                }
            } else if (std.mem.indexOfScalar([]const u8, obj_schema.required, prop_name) != null) {
                // Required property missing
                if (options.use_defaults) {
                    // Try to get default value
                    if (getDefaultForSchema(prop_schema)) |default| {
                        try result.put(try self.allocator.dupe(u8, prop_name), default);
                        try defaulted_fields.append(try self.allocator.dupe(u8, prop_name));
                    } else {
                        return error.MissingRequiredField;
                    }
                } else {
                    return error.MissingRequiredField;
                }
            }
            // Optional properties that are missing are simply not included
        }
        
        // Handle additional properties if allowed
        if (obj_schema.additional_properties) {
            var source_iter = source_obj.iterator();
            while (source_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (!obj_schema.properties.contains(key)) {
                    // Additional property - include as-is
                    try result.put(try self.allocator.dupe(u8, key), entry.value_ptr.*);
                }
            }
        }
        
        return std.json.Value{ .object = result };
    }
    
    fn extractArray(
        self: *SchemaExtractor,
        value: std.json.Value,
        arr_schema: schema_mod.ArraySchema,
        options: ExtractionOptions,
        _: *std.ArrayList([]const u8),
        coerced_fields: *std.ArrayList([]const u8),
        defaulted_fields: *std.ArrayList([]const u8),
        depth: u32,
    ) !std.json.Value {
        const source_arr = switch (value) {
            .array => |arr| arr,
            else => {
                if (options.enable_coercion) {
                    // Try to coerce to array
                    const coercion_result = try coercion.coerceToSchema(
                        self.allocator,
                        value,
                        .{ .array = arr_schema },
                        options.coercion_options,
                    );
                    if (coercion_result.coerced) {
                        try coerced_fields.append(try self.allocator.dupe(u8, "root"));
                    }
                    return coercion_result.value;
                }
                return error.TypeMismatch;
            },
        };
        
        var result = std.json.Array.init(self.allocator);
        errdefer result.deinit();
        
        // Extract array items
        if (arr_schema.items) |item_schema| {
            for (source_arr.items, 0..) |item, i| {
                const extracted = try self.extractFromValue(
                    item,
                    item_schema.*,
                    options,
                    depth + 1,
                );
                
                try result.append(extracted.value);
                
                // Track fields with array index
                for (extracted.coerced_fields) |field| {
                    const full_path = try std.fmt.allocPrint(self.allocator, "[{d}].{s}", .{ i, field });
                    try coerced_fields.append(full_path);
                }
                
                for (extracted.defaulted_fields) |field| {
                    const full_path = try std.fmt.allocPrint(self.allocator, "[{d}].{s}", .{ i, field });
                    try defaulted_fields.append(full_path);
                }
            }
        } else {
            // No item schema - include items as-is
            for (source_arr.items) |item| {
                try result.append(item);
            }
        }
        
        return std.json.Value{ .array = result };
    }
    
    fn extractAnyOf(
        self: *SchemaExtractor,
        value: std.json.Value,
        schemas: []const schema_mod.SchemaNode,
        options: ExtractionOptions,
        extracted_fields: *std.ArrayList([]const u8),
        coerced_fields: *std.ArrayList([]const u8),
        defaulted_fields: *std.ArrayList([]const u8),
        depth: u32,
    ) !std.json.Value {
        // Try each schema until one succeeds
        for (schemas) |schema| {
            const extracted = self.extractFromValue(
                value,
                schema,
                options,
                depth + 1,
            ) catch continue;
            
            // Merge field lists
            for (extracted.extracted_fields) |field| {
                try extracted_fields.append(field);
            }
            for (extracted.coerced_fields) |field| {
                try coerced_fields.append(field);
            }
            for (extracted.defaulted_fields) |field| {
                try defaulted_fields.append(field);
            }
            
            return extracted.value;
        }
        
        return error.NoMatchingSchema;
    }
    
    fn extractOneOf(
        self: *SchemaExtractor,
        value: std.json.Value,
        schemas: []const schema_mod.SchemaNode,
        options: ExtractionOptions,
        extracted_fields: *std.ArrayList([]const u8),
        coerced_fields: *std.ArrayList([]const u8),
        defaulted_fields: *std.ArrayList([]const u8),
        depth: u32,
    ) !std.json.Value {
        var matches: u32 = 0;
        var result: ?ExtractedData = null;
        
        // Try each schema and ensure exactly one matches
        for (schemas) |schema| {
            if (self.extractFromValue(value, schema, options, depth + 1)) |extracted| {
                matches += 1;
                if (result != null) {
                    // Multiple matches - fail
                    return error.MultipleMatches;
                }
                result = extracted;
            } else |_| {}
        }
        
        if (result) |extracted| {
            // Merge field lists
            for (extracted.extracted_fields) |field| {
                try extracted_fields.append(field);
            }
            for (extracted.coerced_fields) |field| {
                try coerced_fields.append(field);
            }
            for (extracted.defaulted_fields) |field| {
                try defaulted_fields.append(field);
            }
            
            return extracted.value;
        }
        
        return error.NoMatchingSchema;
    }
    
    fn getDefaultForSchema(schema: schema_mod.SchemaNode) ?std.json.Value {
        return switch (schema) {
            .string => .{ .string = "" },
            .number => .{ .integer = 0 },
            .boolean => .{ .bool = false },
            .null => .{ .null = {} },
            .array => .{ .array = std.json.Array.init(std.heap.page_allocator) },
            .object => .{ .object = std.json.ObjectMap.init(std.heap.page_allocator) },
            else => null,
        };
    }
};

// Convenience functions
pub fn extractWithSchema(
    allocator: std.mem.Allocator,
    input: []const u8,
    schema: schema_mod.Schema,
) !ExtractionResult {
    var extractor = SchemaExtractor.init(allocator, schema);
    return extractor.extract(input, .{});
}

pub fn extractFromType(
    allocator: std.mem.Allocator,
    comptime T: type,
    input: []const u8,
) !T {
    const generator = @import("../schema/generator.zig");
    var schema = try generator.generateSchema(T, allocator, .{});
    defer schema.deinit();
    
    var extractor = SchemaExtractor.init(allocator, schema);
    var result = try extractor.extract(input, .{});
    defer result.deinit();
    
    // Convert JSON to Zig type
    const json_string = try std.json.stringifyAlloc(allocator, result.value, .{});
    defer allocator.free(json_string);
    
    const parsed = try std.json.parseFromSlice(T, allocator, json_string, .{});
    return parsed.value;
}

// Tests
test "schema-guided extraction" {
    const allocator = std.testing.allocator;
    
    // Define schema for user data
    var user_props = std.StringHashMap(schema_mod.SchemaNode).init(allocator);
    defer user_props.deinit();
    
    try user_props.put("name", .{ .string = schema_mod.StringSchema{} });
    try user_props.put("age", .{ .number = schema_mod.NumberSchema{ .minimum = 0, .maximum = 150 } });
    try user_props.put("email", .{ .string = schema_mod.StringSchema{ .format = .email } });
    
    var user_schema = schema_mod.Schema.init(allocator, .{
        .object = schema_mod.ObjectSchema{
            .properties = user_props,
            .required = &[_][]const u8{ "name", "email" },
            .additional_properties = false,
        },
    });
    defer user_schema.deinit();
    
    // Test extraction from messy input
    const input = 
        \\The user details are as follows:
        \\```json
        \\{
        \\  "name": "John Doe",
        \\  "age": "30",
        \\  "email": "john@example.com",
        \\  "extra": "ignored"
        \\}
        \\```
    ;
    
    var result = try extractWithSchema(allocator, input, user_schema);
    defer result.deinit();
    
    try std.testing.expect(result.value.object.contains("name"));
    try std.testing.expect(result.value.object.contains("age"));
    try std.testing.expect(result.value.object.contains("email"));
    try std.testing.expect(!result.value.object.contains("extra")); // Additional property filtered out
    
    // Age was coerced from string to number
    try std.testing.expectEqual(@as(usize, 1), result.coerced_fields.len);
}

test "extract from type" {
    const allocator = std.testing.allocator;
    
    const Config = struct {
        host: []const u8,
        port: u16,
        secure: bool = false,
    };
    
    const input = 
        \\Configuration:
        \\host: localhost
        \\port: 8080
        \\secure: yes
    ;
    
    const config = try extractFromType(allocator, Config, input);
    defer allocator.free(config.host);
    
    try std.testing.expectEqualStrings("localhost", config.host);
    try std.testing.expectEqual(@as(u16, 8080), config.port);
    try std.testing.expect(config.secure);
}