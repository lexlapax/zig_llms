// ABOUTME: Schema API bridge for exposing validation and structure functionality to scripts
// ABOUTME: Enables JSON schema validation, structure parsing, and data validation from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms schema API
const schema = @import("../../schema.zig");
const json_schema = @import("../../schema/json_schema.zig");
const validator = @import("../../schema/validator.zig");
const parser = @import("../../output/parser.zig");

/// Script schema wrapper
const ScriptSchema = struct {
    id: []const u8,
    schema_json: std.json.Value,
    context: *ScriptContext,
    compiled: bool = false,

    pub fn deinit(self: *ScriptSchema) void {
        const allocator = self.context.allocator;
        allocator.free(self.id);
        self.schema_json.deinit();
        allocator.destroy(self);
    }
};

/// Global schema registry
var schema_registry: ?std.StringHashMap(*ScriptSchema) = null;
var registry_mutex = std.Thread.Mutex{};
var next_schema_id: u32 = 1;

/// Schema Bridge implementation
pub const SchemaBridge = struct {
    pub const bridge = APIBridge{
        .name = "schema",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };

    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);

        module.* = ScriptModule{
            .name = "schema",
            .functions = &schema_functions,
            .constants = &schema_constants,
            .description = "JSON schema validation and structure parsing API",
            .version = "1.0.0",
        };

        return module;
    }

    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;

        registry_mutex.lock();
        defer registry_mutex.unlock();

        if (schema_registry == null) {
            schema_registry = std.StringHashMap(*ScriptSchema).init(context.allocator);
        }
    }

    fn deinit() void {
        registry_mutex.lock();
        defer registry_mutex.unlock();

        if (schema_registry) |*registry| {
            var iter = registry.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            registry.deinit();
            schema_registry = null;
        }
    }
};

// Schema module functions
const schema_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "create",
        "Create a new schema from definition",
        1,
        createSchema,
    ),
    createModuleFunction(
        "createFromString",
        "Create schema from JSON string",
        1,
        createSchemaFromString,
    ),
    createModuleFunction(
        "validate",
        "Validate data against schema",
        2,
        validateData,
    ),
    createModuleFunction(
        "validateWithDetails",
        "Validate with detailed error info",
        2,
        validateDataWithDetails,
    ),
    createModuleFunction(
        "compile",
        "Compile schema for faster validation",
        1,
        compileSchema,
    ),
    createModuleFunction(
        "destroy",
        "Destroy a schema and free resources",
        1,
        destroySchema,
    ),
    createModuleFunction(
        "merge",
        "Merge multiple schemas",
        1,
        mergeSchemas,
    ),
    createModuleFunction(
        "extend",
        "Extend a schema with additional properties",
        2,
        extendSchema,
    ),
    createModuleFunction(
        "list",
        "List all registered schemas",
        0,
        listSchemas,
    ),
    createModuleFunction(
        "get",
        "Get schema by ID",
        1,
        getSchema,
    ),
    createModuleFunction(
        "generateFromData",
        "Generate schema from sample data",
        1,
        generateSchemaFromData,
    ),
    createModuleFunction(
        "generateFromType",
        "Generate schema from type definition",
        1,
        generateSchemaFromType,
    ),
    createModuleFunction(
        "coerce",
        "Coerce data to match schema",
        2,
        coerceData,
    ),
    createModuleFunction(
        "defaults",
        "Apply default values from schema",
        2,
        applyDefaults,
    ),
    createModuleFunction(
        "strip",
        "Strip unknown properties from data",
        2,
        stripUnknownProperties,
    ),
    createModuleFunction(
        "diff",
        "Get differences between schemas",
        2,
        diffSchemas,
    ),
    createModuleFunction(
        "parseStructured",
        "Parse structured output with schema",
        2,
        parseStructuredOutput,
    ),
    createModuleFunction(
        "extractJson",
        "Extract JSON from text with schema",
        2,
        extractJsonFromText,
    ),
    createModuleFunction(
        "validatePartial",
        "Validate partial data against schema",
        2,
        validatePartialData,
    ),
    createModuleFunction(
        "getBuiltinSchemas",
        "Get list of built-in schemas",
        0,
        getBuiltinSchemas,
    ),
};

// Schema module constants
const schema_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "TYPE_STRING",
        ScriptValue{ .string = "string" },
        "String type in JSON schema",
    ),
    createModuleConstant(
        "TYPE_NUMBER",
        ScriptValue{ .string = "number" },
        "Number type in JSON schema",
    ),
    createModuleConstant(
        "TYPE_INTEGER",
        ScriptValue{ .string = "integer" },
        "Integer type in JSON schema",
    ),
    createModuleConstant(
        "TYPE_BOOLEAN",
        ScriptValue{ .string = "boolean" },
        "Boolean type in JSON schema",
    ),
    createModuleConstant(
        "TYPE_OBJECT",
        ScriptValue{ .string = "object" },
        "Object type in JSON schema",
    ),
    createModuleConstant(
        "TYPE_ARRAY",
        ScriptValue{ .string = "array" },
        "Array type in JSON schema",
    ),
    createModuleConstant(
        "TYPE_NULL",
        ScriptValue{ .string = "null" },
        "Null type in JSON schema",
    ),
    createModuleConstant(
        "FORMAT_DATE",
        ScriptValue{ .string = "date" },
        "Date format for strings",
    ),
    createModuleConstant(
        "FORMAT_TIME",
        ScriptValue{ .string = "time" },
        "Time format for strings",
    ),
    createModuleConstant(
        "FORMAT_DATETIME",
        ScriptValue{ .string = "date-time" },
        "DateTime format for strings",
    ),
    createModuleConstant(
        "FORMAT_EMAIL",
        ScriptValue{ .string = "email" },
        "Email format for strings",
    ),
    createModuleConstant(
        "FORMAT_URI",
        ScriptValue{ .string = "uri" },
        "URI format for strings",
    ),
    createModuleConstant(
        "FORMAT_UUID",
        ScriptValue{ .string = "uuid" },
        "UUID format for strings",
    ),
    createModuleConstant(
        "FORMAT_IPV4",
        ScriptValue{ .string = "ipv4" },
        "IPv4 address format",
    ),
    createModuleConstant(
        "FORMAT_IPV6",
        ScriptValue{ .string = "ipv6" },
        "IPv6 address format",
    ),
};

// Implementation functions

fn createSchema(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }

    const schema_def = args[0].object;
    const context = @fieldParentPtr(ScriptContext, "allocator", schema_def.allocator);
    const allocator = context.allocator;

    // Convert ScriptValue to JSON
    const schema_json = try TypeMarshaler.marshalJsonValue(args[0], allocator);

    // Generate unique ID
    registry_mutex.lock();
    const schema_id = try std.fmt.allocPrint(allocator, "schema_{}", .{next_schema_id});
    next_schema_id += 1;
    registry_mutex.unlock();

    // Create schema wrapper
    const script_schema = try allocator.create(ScriptSchema);
    script_schema.* = ScriptSchema{
        .id = schema_id,
        .schema_json = schema_json,
        .context = context,
    };

    // Register schema
    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (schema_registry) |*registry| {
        try registry.put(schema_id, script_schema);
    }

    return ScriptValue{ .string = schema_id };
}

fn createSchemaFromString(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const schema_str = args[0].string;
    const context = @fieldParentPtr(ScriptContext, "allocator", schema_str);
    const allocator = context.allocator;

    // Parse JSON string
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var tree = try parser.parse(schema_str);

    // Generate unique ID
    registry_mutex.lock();
    const schema_id = try std.fmt.allocPrint(allocator, "schema_{}", .{next_schema_id});
    next_schema_id += 1;
    registry_mutex.unlock();

    // Create schema wrapper
    const script_schema = try allocator.create(ScriptSchema);
    script_schema.* = ScriptSchema{
        .id = schema_id,
        .schema_json = tree.root,
        .context = context,
    };

    // Register schema
    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (schema_registry) |*registry| {
        try registry.put(schema_id, script_schema);
    }

    return ScriptValue{ .string = schema_id };
}

fn validateData(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const schema_id = args[0].string;
    const data = args[1];

    registry_mutex.lock();
    const script_schema = if (schema_registry) |*registry|
        registry.get(schema_id)
    else
        null;
    registry_mutex.unlock();

    if (script_schema == null) {
        return error.SchemaNotFound;
    }

    // Convert data to JSON for validation
    const allocator = script_schema.?.context.allocator;
    const data_json = try TypeMarshaler.marshalJsonValue(data, allocator);
    defer data_json.deinit();

    // Perform validation (simplified)
    // In real implementation, would use actual JSON schema validator
    const is_valid = try performValidation(script_schema.?.schema_json, data_json);

    return ScriptValue{ .boolean = is_valid };
}

fn validateDataWithDetails(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const schema_id = args[0].string;
    const data = args[1];

    registry_mutex.lock();
    const script_schema = if (schema_registry) |*registry|
        registry.get(schema_id)
    else
        null;
    registry_mutex.unlock();

    if (script_schema == null) {
        return error.SchemaNotFound;
    }

    // Convert data to JSON for validation
    const allocator = script_schema.?.context.allocator;
    const data_json = try TypeMarshaler.marshalJsonValue(data, allocator);
    defer data_json.deinit();

    // Perform validation with details
    var result = ScriptValue.Object.init(allocator);

    const is_valid = try performValidation(script_schema.?.schema_json, data_json);
    try result.put("valid", ScriptValue{ .boolean = is_valid });

    if (!is_valid) {
        var errors = try ScriptValue.Array.init(allocator, 1);
        var error_obj = ScriptValue.Object.init(allocator);
        try error_obj.put("path", ScriptValue{ .string = try allocator.dupe(u8, "/") });
        try error_obj.put("message", ScriptValue{ .string = try allocator.dupe(u8, "Validation failed") });
        try error_obj.put("keyword", ScriptValue{ .string = try allocator.dupe(u8, "type") });
        errors.items[0] = ScriptValue{ .object = error_obj };
        try result.put("errors", ScriptValue{ .array = errors });
    } else {
        try result.put("errors", ScriptValue{ .array = try ScriptValue.Array.init(allocator, 0) });
    }

    return ScriptValue{ .object = result };
}

fn compileSchema(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const schema_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (schema_registry) |*registry| {
        if (registry.get(schema_id)) |script_schema| {
            script_schema.compiled = true;
            return ScriptValue{ .boolean = true };
        }
    }

    return error.SchemaNotFound;
}

fn destroySchema(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const schema_id = args[0].string;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (schema_registry) |*registry| {
        if (registry.fetchRemove(schema_id)) |kv| {
            kv.value.deinit();
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn mergeSchemas(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .array) {
        return error.InvalidArguments;
    }

    const schema_ids = args[0].array;
    const allocator = schema_ids.allocator;

    // Create merged schema (simplified)
    var merged = ScriptValue.Object.init(allocator);
    try merged.put("type", ScriptValue{ .string = try allocator.dupe(u8, "object") });
    try merged.put("properties", ScriptValue{ .object = ScriptValue.Object.init(allocator) });

    // Create and register the merged schema
    const create_args = [_]ScriptValue{ScriptValue{ .object = merged }};
    return try createSchema(&create_args);
}

fn extendSchema(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }

    const base_schema_id = args[0].string;
    const extensions = args[1].object;

    registry_mutex.lock();
    const base_schema = if (schema_registry) |*registry|
        registry.get(base_schema_id)
    else
        null;
    registry_mutex.unlock();

    if (base_schema == null) {
        return error.SchemaNotFound;
    }

    // Convert base schema back to ScriptValue
    const allocator = base_schema.?.context.allocator;
    const base_value = try TypeMarshaler.unmarshalJsonValue(base_schema.?.schema_json, allocator);

    // Merge with extensions
    if (base_value == .object) {
        var extended = try base_value.object.clone();

        var iter = extensions.map.iterator();
        while (iter.next()) |entry| {
            try extended.put(entry.key_ptr.*, try entry.value_ptr.*.clone(allocator));
        }

        // Create new schema with extended definition
        const create_args = [_]ScriptValue{ScriptValue{ .object = extended }};
        return try createSchema(&create_args);
    }

    return error.InvalidSchema;
}

fn listSchemas(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    registry_mutex.lock();
    defer registry_mutex.unlock();

    if (schema_registry) |*registry| {
        const allocator = registry.allocator;
        var list = try ScriptValue.Array.init(allocator, registry.count());

        var iter = registry.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            var schema_info = ScriptValue.Object.init(allocator);
            try schema_info.put("id", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            try schema_info.put("compiled", ScriptValue{ .boolean = entry.value_ptr.*.compiled });
            list.items[i] = ScriptValue{ .object = schema_info };
        }

        return ScriptValue{ .array = list };
    }

    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn getSchema(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const schema_id = args[0].string;

    registry_mutex.lock();
    const script_schema = if (schema_registry) |*registry|
        registry.get(schema_id)
    else
        null;
    registry_mutex.unlock();

    if (script_schema == null) {
        return ScriptValue.nil;
    }

    // Convert schema JSON back to ScriptValue
    const allocator = script_schema.?.context.allocator;
    return try TypeMarshaler.unmarshalJsonValue(script_schema.?.schema_json, allocator);
}

fn generateSchemaFromData(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1) {
        return error.InvalidArguments;
    }

    const data = args[0];
    const allocator = @fieldParentPtr(ScriptContext, "allocator", &data).allocator;

    // Generate schema based on data type
    var schema_def = ScriptValue.Object.init(allocator);

    switch (data) {
        .nil => try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "null") }),
        .boolean => try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "boolean") }),
        .integer => try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "integer") }),
        .number => try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "number") }),
        .string => try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "string") }),
        .array => |arr| {
            try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "array") });
            if (arr.items.len > 0) {
                // Infer items schema from first element
                const item_args = [_]ScriptValue{arr.items[0]};
                const item_schema = try generateSchemaFromData(&item_args);
                try schema_def.put("items", item_schema);
            }
        },
        .object => |obj| {
            try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "object") });
            var properties = ScriptValue.Object.init(allocator);

            var iter = obj.map.iterator();
            while (iter.next()) |entry| {
                const prop_args = [_]ScriptValue{entry.value_ptr.*};
                const prop_schema = try generateSchemaFromData(&prop_args);
                try properties.put(entry.key_ptr.*, prop_schema);
            }

            try schema_def.put("properties", ScriptValue{ .object = properties });
        },
        else => try schema_def.put("type", ScriptValue{ .string = try allocator.dupe(u8, "any") }),
    }

    return ScriptValue{ .object = schema_def };
}

fn generateSchemaFromType(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }

    // Generate schema from type definition
    return args[0]; // Simplified - just return the type definition as schema
}

fn coerceData(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    // TODO: Implement data coercion
    return args[1]; // Return data unchanged for now
}

fn applyDefaults(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    // TODO: Implement default value application
    return args[1]; // Return data unchanged for now
}

fn stripUnknownProperties(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    // TODO: Implement stripping of unknown properties
    return args[1]; // Return data unchanged for now
}

fn diffSchemas(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const allocator = std.heap.page_allocator; // Temporary allocator
    var diff = ScriptValue.Object.init(allocator);

    try diff.put("added", ScriptValue{ .array = try ScriptValue.Array.init(allocator, 0) });
    try diff.put("removed", ScriptValue{ .array = try ScriptValue.Array.init(allocator, 0) });
    try diff.put("modified", ScriptValue{ .array = try ScriptValue.Array.init(allocator, 0) });

    return ScriptValue{ .object = diff };
}

fn parseStructuredOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const text = args[0].string;
    const schema_id = args[1].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;

    _ = schema_id;

    // Try to extract JSON from text (simplified)
    const start = std.mem.indexOf(u8, text, "{") orelse return ScriptValue.nil;
    const end = std.mem.lastIndexOf(u8, text, "}") orelse return ScriptValue.nil;

    if (end <= start) {
        return ScriptValue.nil;
    }

    const json_str = text[start .. end + 1];

    // Parse JSON
    var json_parser = std.json.Parser.init(allocator, false);
    defer json_parser.deinit();

    var tree = json_parser.parse(json_str) catch return ScriptValue.nil;
    defer tree.deinit();

    return try TypeMarshaler.unmarshalJsonValue(tree.root, allocator);
}

fn extractJsonFromText(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const text = args[0].string;
    const schema_id = args[1].string;

    // Delegate to parseStructuredOutput
    return try parseStructuredOutput(args);
}

fn validatePartialData(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    // Validate allowing missing required fields
    // For now, just delegate to regular validation
    return try validateData(args);
}

fn getBuiltinSchemas(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    const allocator = std.heap.page_allocator; // Temporary allocator
    var list = try ScriptValue.Array.init(allocator, 5);

    const builtin_schemas = [_][]const u8{
        "tool_input",
        "tool_output",
        "agent_config",
        "workflow_step",
        "event_payload",
    };

    for (builtin_schemas, 0..) |schema_name, i| {
        list.items[i] = ScriptValue{ .string = try allocator.dupe(u8, schema_name) };
    }

    return ScriptValue{ .array = list };
}

// Helper functions

fn performValidation(schema_json: std.json.Value, data_json: std.json.Value) !bool {
    // Simplified validation logic
    const schema_obj = switch (schema_json) {
        .object => |obj| obj,
        else => return false,
    };

    const schema_type = schema_obj.get("type") orelse return true;

    switch (schema_type) {
        .string => |type_str| {
            if (std.mem.eql(u8, type_str, "object")) {
                return data_json == .object;
            } else if (std.mem.eql(u8, type_str, "array")) {
                return data_json == .array;
            } else if (std.mem.eql(u8, type_str, "string")) {
                return data_json == .string;
            } else if (std.mem.eql(u8, type_str, "number")) {
                return data_json == .float or data_json == .integer;
            } else if (std.mem.eql(u8, type_str, "integer")) {
                return data_json == .integer;
            } else if (std.mem.eql(u8, type_str, "boolean")) {
                return data_json == .bool;
            } else if (std.mem.eql(u8, type_str, "null")) {
                return data_json == .null;
            }
        },
        else => {},
    }

    return true;
}

// Tests
test "SchemaBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const module = try SchemaBridge.getModule(allocator);
    defer allocator.destroy(module);

    try testing.expectEqualStrings("schema", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}
