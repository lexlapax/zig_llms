// ABOUTME: Input/output validation hooks for ensuring data integrity
// ABOUTME: Provides schema-based validation, custom validators, and error handling

const std = @import("std");
const types = @import("types.zig");
const Hook = types.Hook;
const HookContext = types.HookContext;
const HookResult = types.HookResult;
const HookPoint = types.HookPoint;
const schema_mod = @import("../schema/validator.zig");

// Validation error types
pub const ValidationError = error{
    RequiredFieldMissing,
    TypeMismatch,
    ValueOutOfRange,
    PatternMismatch,
    InvalidFormat,
    CustomValidationFailed,
    SchemaNotFound,
    InvalidSchema,
};

// Validation result
pub const ValidationResult = struct {
    valid: bool,
    errors: std.ArrayList(ValidationIssue),
    warnings: std.ArrayList(ValidationIssue),
    
    pub const ValidationIssue = struct {
        path: []const u8,
        message: []const u8,
        code: []const u8,
        severity: Severity,
        
        pub const Severity = enum {
            error,
            warning,
            info,
        };
    };
    
    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .valid = true,
            .errors = std.ArrayList(ValidationIssue).init(allocator),
            .warnings = std.ArrayList(ValidationIssue).init(allocator),
        };
    }
    
    pub fn deinit(self: *ValidationResult) void {
        self.errors.deinit();
        self.warnings.deinit();
    }
    
    pub fn addError(self: *ValidationResult, path: []const u8, message: []const u8, code: []const u8) !void {
        self.valid = false;
        try self.errors.append(.{
            .path = path,
            .message = message,
            .code = code,
            .severity = .error,
        });
    }
    
    pub fn addWarning(self: *ValidationResult, path: []const u8, message: []const u8, code: []const u8) !void {
        try self.warnings.append(.{
            .path = path,
            .message = message,
            .code = code,
            .severity = .warning,
        });
    }
    
    pub fn merge(self: *ValidationResult, other: *const ValidationResult) !void {
        if (!other.valid) {
            self.valid = false;
        }
        try self.errors.appendSlice(other.errors.items);
        try self.warnings.appendSlice(other.warnings.items);
    }
};

// Validator interface
pub const Validator = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        validate: *const fn (validator: *const Validator, value: std.json.Value, allocator: std.mem.Allocator) anyerror!ValidationResult,
        getName: *const fn (validator: *const Validator) []const u8,
        deinit: ?*const fn (validator: *Validator) void = null,
    };
    
    pub fn validate(self: *const Validator, value: std.json.Value, allocator: std.mem.Allocator) !ValidationResult {
        return self.vtable.validate(self, value, allocator);
    }
    
    pub fn getName(self: *const Validator) []const u8 {
        return self.vtable.getName(self);
    }
    
    pub fn deinit(self: *Validator) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self);
        }
    }
};

// Schema validator
pub const SchemaValidator = struct {
    validator: Validator,
    schema: std.json.Value,
    name: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, schema: std.json.Value) !*SchemaValidator {
        const self = try allocator.create(SchemaValidator);
        self.* = .{
            .validator = .{
                .vtable = &.{
                    .validate = validate,
                    .getName = getName,
                    .deinit = deinit,
                },
            },
            .schema = schema,
            .name = name,
            .allocator = allocator,
        };
        return self;
    }
    
    fn validate(validator: *const Validator, value: std.json.Value, allocator: std.mem.Allocator) !ValidationResult {
        const self = @fieldParentPtr(SchemaValidator, "validator", validator);
        
        var result = ValidationResult.init(allocator);
        errdefer result.deinit();
        
        try self.validateValue(&result, "", value, self.schema);
        
        return result;
    }
    
    fn validateValue(self: *const SchemaValidator, result: *ValidationResult, path: []const u8, value: std.json.Value, schema: std.json.Value) !void {
        if (schema != .object) {
            try result.addError(path, "Invalid schema format", "invalid_schema");
            return;
        }
        
        const schema_obj = schema.object;
        
        // Check type
        if (schema_obj.get("type")) |type_spec| {
            if (type_spec == .string) {
                const expected_type = type_spec.string;
                if (!self.checkType(value, expected_type)) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Expected type '{s}', got '{s}'",
                        .{ expected_type, @tagName(value) },
                    );
                    defer self.allocator.free(msg);
                    try result.addError(path, msg, "type_mismatch");
                }
            }
        }
        
        // Check required fields for objects
        if (value == .object and schema_obj.get("required")) |required| {
            if (required == .array) {
                for (required.array.items) |req_field| {
                    if (req_field == .string) {
                        if (value.object.get(req_field.string) == null) {
                            const msg = try std.fmt.allocPrint(
                                self.allocator,
                                "Required field '{s}' is missing",
                                .{req_field.string},
                            );
                            defer self.allocator.free(msg);
                            
                            const field_path = if (path.len > 0)
                                try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, req_field.string })
                            else
                                req_field.string;
                            defer if (path.len > 0) self.allocator.free(field_path);
                            
                            try result.addError(field_path, msg, "required_field_missing");
                        }
                    }
                }
            }
        }
        
        // Validate object properties
        if (value == .object and schema_obj.get("properties")) |properties| {
            if (properties == .object) {
                var iter = value.object.iterator();
                while (iter.next()) |entry| {
                    if (properties.object.get(entry.key_ptr.*)) |prop_schema| {
                        const prop_path = if (path.len > 0)
                            try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, entry.key_ptr.* })
                        else
                            entry.key_ptr.*;
                        defer if (path.len > 0) self.allocator.free(prop_path);
                        
                        try self.validateValue(result, prop_path, entry.value_ptr.*, prop_schema);
                    }
                }
            }
        }
        
        // Validate array items
        if (value == .array and schema_obj.get("items")) |items_schema| {
            for (value.array.items, 0..) |item, i| {
                const item_path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ path, i });
                defer self.allocator.free(item_path);
                
                try self.validateValue(result, item_path, item, items_schema);
            }
        }
        
        // Check string constraints
        if (value == .string) {
            const str = value.string;
            
            if (schema_obj.get("minLength")) |min_len| {
                if (min_len == .integer and str.len < @as(usize, @intCast(min_len.integer))) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "String length {d} is less than minimum {d}",
                        .{ str.len, min_len.integer },
                    );
                    defer self.allocator.free(msg);
                    try result.addError(path, msg, "min_length_violation");
                }
            }
            
            if (schema_obj.get("maxLength")) |max_len| {
                if (max_len == .integer and str.len > @as(usize, @intCast(max_len.integer))) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "String length {d} exceeds maximum {d}",
                        .{ str.len, max_len.integer },
                    );
                    defer self.allocator.free(msg);
                    try result.addError(path, msg, "max_length_violation");
                }
            }
            
            if (schema_obj.get("pattern")) |pattern| {
                if (pattern == .string) {
                    // TODO: Implement regex pattern matching
                    _ = pattern.string;
                }
            }
        }
        
        // Check number constraints
        if (value == .integer or value == .float) {
            const num_value = switch (value) {
                .integer => |i| @as(f64, @floatFromInt(i)),
                .float => |f| f,
                else => unreachable,
            };
            
            if (schema_obj.get("minimum")) |min| {
                const min_value = switch (min) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f| f,
                    else => 0,
                };
                
                if (num_value < min_value) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Value {d} is less than minimum {d}",
                        .{ num_value, min_value },
                    );
                    defer self.allocator.free(msg);
                    try result.addError(path, msg, "minimum_violation");
                }
            }
            
            if (schema_obj.get("maximum")) |max| {
                const max_value = switch (max) {
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    .float => |f| f,
                    else => 0,
                };
                
                if (num_value > max_value) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Value {d} exceeds maximum {d}",
                        .{ num_value, max_value },
                    );
                    defer self.allocator.free(msg);
                    try result.addError(path, msg, "maximum_violation");
                }
            }
        }
        
        // Check enum values
        if (schema_obj.get("enum")) |enum_values| {
            if (enum_values == .array) {
                var found = false;
                for (enum_values.array.items) |enum_val| {
                    if (std.meta.eql(value, enum_val)) {
                        found = true;
                        break;
                    }
                }
                
                if (!found) {
                    const msg = try std.fmt.allocPrint(
                        self.allocator,
                        "Value is not one of the allowed enum values",
                        .{},
                    );
                    defer self.allocator.free(msg);
                    try result.addError(path, msg, "enum_violation");
                }
            }
        }
    }
    
    fn checkType(self: *const SchemaValidator, value: std.json.Value, expected_type: []const u8) bool {
        _ = self;
        if (std.mem.eql(u8, expected_type, "null")) {
            return value == .null;
        } else if (std.mem.eql(u8, expected_type, "boolean")) {
            return value == .bool;
        } else if (std.mem.eql(u8, expected_type, "integer")) {
            return value == .integer;
        } else if (std.mem.eql(u8, expected_type, "number")) {
            return value == .integer or value == .float;
        } else if (std.mem.eql(u8, expected_type, "string")) {
            return value == .string;
        } else if (std.mem.eql(u8, expected_type, "array")) {
            return value == .array;
        } else if (std.mem.eql(u8, expected_type, "object")) {
            return value == .object;
        }
        return false;
    }
    
    fn getName(validator: *const Validator) []const u8 {
        const self = @fieldParentPtr(SchemaValidator, "validator", validator);
        return self.name;
    }
    
    fn deinit(validator: *Validator) void {
        const self = @fieldParentPtr(SchemaValidator, "validator", validator);
        self.allocator.destroy(self);
    }
};

// Custom validator
pub const CustomValidator = struct {
    validator: Validator,
    name: []const u8,
    validate_fn: *const fn (value: std.json.Value, context: *anyopaque) ValidationError!void,
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        validate_fn: *const fn (value: std.json.Value, context: *anyopaque) ValidationError!void,
        context: ?*anyopaque,
    ) !*CustomValidator {
        const self = try allocator.create(CustomValidator);
        self.* = .{
            .validator = .{
                .vtable = &.{
                    .validate = validate,
                    .getName = getName,
                    .deinit = deinit,
                },
            },
            .name = name,
            .validate_fn = validate_fn,
            .context = context,
            .allocator = allocator,
        };
        return self;
    }
    
    fn validate(validator: *const Validator, value: std.json.Value, allocator: std.mem.Allocator) !ValidationResult {
        const self = @fieldParentPtr(CustomValidator, "validator", validator);
        
        var result = ValidationResult.init(allocator);
        errdefer result.deinit();
        
        self.validate_fn(value, self.context orelse @as(*anyopaque, undefined)) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "Custom validation failed: {s}", .{@errorName(err)});
            defer allocator.free(msg);
            try result.addError("", msg, "custom_validation_failed");
        };
        
        return result;
    }
    
    fn getName(validator: *const Validator) []const u8 {
        const self = @fieldParentPtr(CustomValidator, "validator", validator);
        return self.name;
    }
    
    fn deinit(validator: *Validator) void {
        const self = @fieldParentPtr(CustomValidator, "validator", validator);
        self.allocator.destroy(self);
    }
};

// Composite validator
pub const CompositeValidator = struct {
    validator: Validator,
    name: []const u8,
    validators: std.ArrayList(*Validator),
    mode: CompositeMode,
    allocator: std.mem.Allocator,
    
    pub const CompositeMode = enum {
        all,    // All validators must pass
        any,    // At least one validator must pass
        one_of, // Exactly one validator must pass
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        mode: CompositeMode,
    ) !*CompositeValidator {
        const self = try allocator.create(CompositeValidator);
        self.* = .{
            .validator = .{
                .vtable = &.{
                    .validate = validate,
                    .getName = getName,
                    .deinit = deinit,
                },
            },
            .name = name,
            .validators = std.ArrayList(*Validator).init(allocator),
            .mode = mode,
            .allocator = allocator,
        };
        return self;
    }
    
    pub fn addValidator(self: *CompositeValidator, validator: *Validator) !void {
        try self.validators.append(validator);
    }
    
    fn validate(validator: *const Validator, value: std.json.Value, allocator: std.mem.Allocator) !ValidationResult {
        const self = @fieldParentPtr(CompositeValidator, "validator", validator);
        
        var result = ValidationResult.init(allocator);
        errdefer result.deinit();
        
        var valid_count: usize = 0;
        var all_results = std.ArrayList(ValidationResult).init(allocator);
        defer {
            for (all_results.items) |*res| {
                res.deinit();
            }
            all_results.deinit();
        }
        
        for (self.validators.items) |sub_validator| {
            var sub_result = try sub_validator.validate(value, allocator);
            
            if (sub_result.valid) {
                valid_count += 1;
            }
            
            try all_results.append(sub_result);
        }
        
        switch (self.mode) {
            .all => {
                if (valid_count == self.validators.items.len) {
                    result.valid = true;
                } else {
                    result.valid = false;
                    for (all_results.items) |*sub_result| {
                        try result.merge(sub_result);
                    }
                }
            },
            .any => {
                if (valid_count > 0) {
                    result.valid = true;
                    // Include warnings from all validators
                    for (all_results.items) |*sub_result| {
                        try result.warnings.appendSlice(sub_result.warnings.items);
                    }
                } else {
                    result.valid = false;
                    for (all_results.items) |*sub_result| {
                        try result.merge(sub_result);
                    }
                }
            },
            .one_of => {
                if (valid_count == 1) {
                    result.valid = true;
                } else {
                    result.valid = false;
                    const msg = try std.fmt.allocPrint(
                        allocator,
                        "Expected exactly one validator to pass, but {d} passed",
                        .{valid_count},
                    );
                    defer allocator.free(msg);
                    try result.addError("", msg, "one_of_violation");
                }
            },
        }
        
        return result;
    }
    
    fn getName(validator: *const Validator) []const u8 {
        const self = @fieldParentPtr(CompositeValidator, "validator", validator);
        return self.name;
    }
    
    fn deinit(validator: *Validator) void {
        const self = @fieldParentPtr(CompositeValidator, "validator", validator);
        for (self.validators.items) |v| {
            v.deinit();
        }
        self.validators.deinit();
        self.allocator.destroy(self);
    }
};

// Validation hook
pub const ValidationHook = struct {
    hook: Hook,
    config: ValidationConfig,
    input_validator: ?*Validator,
    output_validator: ?*Validator,
    allocator: std.mem.Allocator,
    
    pub const ValidationConfig = struct {
        validate_inputs: bool = true,
        validate_outputs: bool = true,
        fail_on_warning: bool = false,
        log_validation_errors: bool = true,
        include_path_in_error: bool = true,
    };
    
    pub fn init(
        allocator: std.mem.Allocator,
        id: []const u8,
        config: ValidationConfig,
    ) !*ValidationHook {
        const self = try allocator.create(ValidationHook);
        
        const vtable = try allocator.create(Hook.VTable);
        vtable.* = .{
            .execute = execute,
            .deinit = hookDeinit,
        };
        
        self.* = .{
            .hook = .{
                .id = id,
                .name = "Validation Hook",
                .description = "Input/output validation for data integrity",
                .vtable = vtable,
                .priority = .high,
                .supported_points = &[_]HookPoint{.custom}, // Supports all points
                .config = .{ .integer = @intFromPtr(self) },
            },
            .config = config,
            .input_validator = null,
            .output_validator = null,
            .allocator = allocator,
        };
        
        return self;
    }
    
    pub fn setInputValidator(self: *ValidationHook, validator: *Validator) void {
        if (self.input_validator) |old| {
            old.deinit();
        }
        self.input_validator = validator;
    }
    
    pub fn setOutputValidator(self: *ValidationHook, validator: *Validator) void {
        if (self.output_validator) |old| {
            old.deinit();
        }
        self.output_validator = validator;
    }
    
    fn hookDeinit(hook: *Hook) void {
        const self = @as(*ValidationHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
        
        if (self.input_validator) |v| {
            v.deinit();
        }
        if (self.output_validator) |v| {
            v.deinit();
        }
        
        self.allocator.destroy(hook.vtable);
        self.allocator.destroy(self);
    }
    
    fn execute(hook: *Hook, context: *HookContext) !HookResult {
        const self = @as(*ValidationHook, @ptrFromInt(@as(usize, @intCast(hook.config.?.integer))));
        
        // Validate input
        if (self.config.validate_inputs and self.input_validator != null and context.input_data != null) {
            var result = try self.input_validator.?.validate(context.input_data.?, self.allocator);
            defer result.deinit();
            
            if (!result.valid or (self.config.fail_on_warning and result.warnings.items.len > 0)) {
                if (self.config.log_validation_errors) {
                    std.log.err("Input validation failed for hook '{s}':", .{hook.id});
                    for (result.errors.items) |issue| {
                        std.log.err("  [{s}] {s}: {s}", .{ issue.path, issue.code, issue.message });
                    }
                }
                
                return HookResult{
                    .continue_processing = false,
                    .error_info = .{
                        .message = "Input validation failed",
                        .error_type = "ValidationError",
                        .recoverable = false,
                    },
                };
            }
        }
        
        // TODO: We can't validate output here since we're not wrapping the actual hook execution
        // This would need to be implemented at a higher level in the hook chain
        
        return HookResult{ .continue_processing = true };
    }
};

// Validation registry for managing validators
pub const ValidationRegistry = struct {
    validators: std.StringHashMap(*Validator),
    schemas: std.StringHashMap(std.json.Value),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ValidationRegistry {
        return .{
            .validators = std.StringHashMap(*Validator).init(allocator),
            .schemas = std.StringHashMap(std.json.Value).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ValidationRegistry) void {
        var validator_iter = self.validators.iterator();
        while (validator_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.validators.deinit();
        self.schemas.deinit();
    }
    
    pub fn registerValidator(self: *ValidationRegistry, name: []const u8, validator: *Validator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        if (self.validators.get(name)) |old| {
            old.deinit();
        }
        
        try self.validators.put(name, validator);
    }
    
    pub fn registerSchema(self: *ValidationRegistry, name: []const u8, schema: std.json.Value) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.schemas.put(name, schema);
        
        // Create validator for schema
        const validator = try SchemaValidator.init(self.allocator, name, schema);
        try self.validators.put(name, &validator.validator);
    }
    
    pub fn getValidator(self: *ValidationRegistry, name: []const u8) ?*Validator {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        return self.validators.get(name);
    }
    
    pub fn validate(self: *ValidationRegistry, validator_name: []const u8, value: std.json.Value) !ValidationResult {
        const validator = self.getValidator(validator_name) orelse return error.ValidatorNotFound;
        return validator.validate(value, self.allocator);
    }
};

// Builder for validation hook
pub fn createValidationHook(
    allocator: std.mem.Allocator,
    id: []const u8,
    config: ValidationHook.ValidationConfig,
) !*Hook {
    const validation_hook = try ValidationHook.init(allocator, id, config);
    return &validation_hook.hook;
}

// Tests
test "schema validator" {
    const allocator = std.testing.allocator;
    
    // Create schema
    var schema = std.json.ObjectMap.init(allocator);
    defer schema.deinit();
    
    try schema.put("type", .{ .string = "object" });
    
    var required = std.json.Array.init(allocator);
    try required.append(.{ .string = "name" });
    try required.append(.{ .string = "age" });
    try schema.put("required", .{ .array = required });
    
    var properties = std.json.ObjectMap.init(allocator);
    
    var name_schema = std.json.ObjectMap.init(allocator);
    try name_schema.put("type", .{ .string = "string" });
    try name_schema.put("minLength", .{ .integer = 1 });
    try properties.put("name", .{ .object = name_schema });
    
    var age_schema = std.json.ObjectMap.init(allocator);
    try age_schema.put("type", .{ .string = "integer" });
    try age_schema.put("minimum", .{ .integer = 0 });
    try age_schema.put("maximum", .{ .integer = 150 });
    try properties.put("age", .{ .object = age_schema });
    
    try schema.put("properties", .{ .object = properties });
    
    const validator = try SchemaValidator.init(allocator, "person", .{ .object = schema });
    defer validator.validator.deinit();
    
    // Test valid object
    var valid_obj = std.json.ObjectMap.init(allocator);
    defer valid_obj.deinit();
    try valid_obj.put("name", .{ .string = "John" });
    try valid_obj.put("age", .{ .integer = 30 });
    
    var result = try validator.validator.validate(.{ .object = valid_obj }, allocator);
    defer result.deinit();
    
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    
    // Test invalid object (missing required field)
    var invalid_obj = std.json.ObjectMap.init(allocator);
    defer invalid_obj.deinit();
    try invalid_obj.put("name", .{ .string = "John" });
    
    var result2 = try validator.validator.validate(.{ .object = invalid_obj }, allocator);
    defer result2.deinit();
    
    try std.testing.expect(!result2.valid);
    try std.testing.expect(result2.errors.items.len > 0);
}

test "custom validator" {
    const allocator = std.testing.allocator;
    
    const validator = try CustomValidator.init(
        allocator,
        "even_number",
        struct {
            fn validate(value: std.json.Value, context: *anyopaque) ValidationError!void {
                _ = context;
                if (value != .integer) return error.TypeMismatch;
                if (@mod(value.integer, 2) != 0) return error.CustomValidationFailed;
            }
        }.validate,
        null,
    );
    defer validator.validator.deinit();
    
    // Test valid even number
    var result = try validator.validator.validate(.{ .integer = 4 }, allocator);
    defer result.deinit();
    try std.testing.expect(result.valid);
    
    // Test invalid odd number
    var result2 = try validator.validator.validate(.{ .integer = 3 }, allocator);
    defer result2.deinit();
    try std.testing.expect(!result2.valid);
}

test "validation registry" {
    const allocator = std.testing.allocator;
    
    var registry = ValidationRegistry.init(allocator);
    defer registry.deinit();
    
    // Register a simple schema
    var schema = std.json.ObjectMap.init(allocator);
    defer schema.deinit();
    try schema.put("type", .{ .string = "string" });
    try schema.put("minLength", .{ .integer = 5 });
    
    try registry.registerSchema("username", .{ .object = schema });
    
    // Validate against schema
    var result = try registry.validate("username", .{ .string = "testuser" });
    defer result.deinit();
    try std.testing.expect(result.valid);
    
    var result2 = try registry.validate("username", .{ .string = "ab" });
    defer result2.deinit();
    try std.testing.expect(!result2.valid);
}