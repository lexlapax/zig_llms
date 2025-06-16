// ABOUTME: Tool validation system for ensuring tool safety and correctness
// ABOUTME: Validates tool metadata, schemas, permissions, and runtime behavior

const std = @import("std");
const tool_mod = @import("../tool.zig");
const Tool = tool_mod.Tool;
const ToolMetadata = Tool.ToolMetadata;
const schema_mod = @import("../schema/validator.zig");
const RunContext = @import("../context.zig").RunContext;

// Validation result
pub const ValidationResult = struct {
    valid: bool,
    errors: []const ValidationError,
    warnings: []const ValidationWarning,
    metadata: ?ValidationMetadata = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ValidationResult) void {
        for (self.errors) |err| {
            self.allocator.free(err.message);
            if (err.context) |ctx| self.allocator.free(ctx);
        }
        self.allocator.free(self.errors);

        for (self.warnings) |warn| {
            self.allocator.free(warn.message);
            if (warn.context) |ctx| self.allocator.free(ctx);
        }
        self.allocator.free(self.warnings);

        if (self.metadata) |*meta| {
            meta.deinit();
        }
    }

    pub fn hasError(self: *const ValidationResult, kind: ValidationError.Kind) bool {
        for (self.errors) |err| {
            if (err.kind == kind) return true;
        }
        return false;
    }

    pub fn getError(self: *const ValidationResult, kind: ValidationError.Kind) ?ValidationError {
        for (self.errors) |err| {
            if (err.kind == kind) return err;
        }
        return null;
    }
};

pub const ValidationError = struct {
    kind: Kind,
    message: []const u8,
    severity: Severity = .@"error",
    context: ?[]const u8 = null,

    pub const Kind = enum {
        invalid_metadata,
        invalid_schema,
        missing_required_field,
        invalid_version,
        security_violation,
        permission_denied,
        execution_failed,
        timeout,
        resource_limit,
        incompatible_context,
        dependency_missing,
        other,
    };

    pub const Severity = enum {
        @"error",
        critical,
        fatal,
    };
};

pub const ValidationWarning = struct {
    kind: Kind,
    message: []const u8,
    context: ?[]const u8 = null,

    pub const Kind = enum {
        deprecated_api,
        performance_concern,
        security_advisory,
        best_practice,
        compatibility,
        other,
    };
};

pub const ValidationMetadata = struct {
    execution_time_ms: ?u64 = null,
    memory_used: ?usize = null,
    permissions_required: []const Permission = &[_]Permission{},
    test_coverage: ?f32 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ValidationMetadata) void {
        self.allocator.free(self.permissions_required);
    }
};

pub const Permission = enum {
    network_access,
    filesystem_read,
    filesystem_write,
    process_spawn,
    system_info,
    memory_allocate,
};

// Tool validator
pub const ToolValidator = struct {
    config: ValidationConfig,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: ValidationConfig) ToolValidator {
        return .{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn validate(self: *ToolValidator, tool: *Tool, context: ?*RunContext) !ValidationResult {
        var errors = std.ArrayList(ValidationError).init(self.allocator);
        defer errors.deinit();

        var warnings = std.ArrayList(ValidationWarning).init(self.allocator);
        defer warnings.deinit();

        var metadata = ValidationMetadata{
            .allocator = self.allocator,
        };

        // Validate metadata
        try self.validateMetadata(&tool.metadata, &errors, &warnings);

        // Validate schemas
        if (self.config.validate_schemas) {
            try self.validateSchemas(&tool.metadata, &errors);
        }

        // Check permissions
        if (self.config.check_permissions) {
            try self.checkPermissions(&tool.metadata, &errors, &metadata);
        }

        // Run test execution if requested
        if (self.config.test_execution and context != null) {
            try self.testExecution(tool, context.?, &errors, &warnings, &metadata);
        }

        // Check dependencies
        if (self.config.check_dependencies) {
            try self.checkDependencies(tool, &errors);
        }

        return ValidationResult{
            .valid = errors.items.len == 0,
            .errors = try errors.toOwnedSlice(),
            .warnings = try warnings.toOwnedSlice(),
            .metadata = if (self.config.collect_metadata) metadata else null,
            .allocator = self.allocator,
        };
    }

    fn validateMetadata(
        self: *ToolValidator,
        metadata: *const ToolMetadata,
        errors: *std.ArrayList(ValidationError),
        warnings: *std.ArrayList(ValidationWarning),
    ) !void {
        // Check required fields
        if (metadata.name.len == 0) {
            try errors.append(.{
                .kind = .missing_required_field,
                .message = try self.allocator.dupe(u8, "Tool name is required"),
            });
        }

        if (metadata.description.len == 0) {
            try errors.append(.{
                .kind = .missing_required_field,
                .message = try self.allocator.dupe(u8, "Tool description is required"),
            });
        }

        // Validate name format
        if (!isValidToolName(metadata.name)) {
            try errors.append(.{
                .kind = .invalid_metadata,
                .message = try std.fmt.allocPrint(self.allocator, "Invalid tool name: '{s}'. Must contain only alphanumeric, underscore, and dash", .{metadata.name}),
            });
        }

        // Check version format
        if (!isValidVersion(metadata.version)) {
            try errors.append(.{
                .kind = .invalid_version,
                .message = try std.fmt.allocPrint(self.allocator, "Invalid version format: '{s}'. Expected semver format (e.g., 1.0.0)", .{metadata.version}),
            });
        }

        // Warn about missing optional fields
        if (metadata.author == null and self.config.strict) {
            try warnings.append(.{
                .kind = .best_practice,
                .message = try self.allocator.dupe(u8, "Tool author information is recommended"),
            });
        }

        if (metadata.examples.len == 0 and self.config.strict) {
            try warnings.append(.{
                .kind = .best_practice,
                .message = try self.allocator.dupe(u8, "Tool examples are recommended for documentation"),
            });
        }
    }

    fn validateSchemas(
        self: *ToolValidator,
        metadata: *const ToolMetadata,
        errors: *std.ArrayList(ValidationError),
    ) !void {
        // Validate input schema
        const input_validation = metadata.input_schema.validate(std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) }) catch |err| {
            try errors.append(.{
                .kind = .invalid_schema,
                .message = try std.fmt.allocPrint(self.allocator, "Invalid input schema: {s}", .{@errorName(err)}),
                .context = try self.allocator.dupe(u8, "input_schema"),
            });
            return;
        };

        if (!input_validation.valid and self.config.strict) {
            try errors.append(.{
                .kind = .invalid_schema,
                .message = try self.allocator.dupe(u8, "Input schema validation failed"),
                .context = try self.allocator.dupe(u8, "input_schema"),
            });
        }

        // Validate output schema
        const output_validation = metadata.output_schema.validate(std.json.Value{ .null = {} }) catch |err| {
            try errors.append(.{
                .kind = .invalid_schema,
                .message = try std.fmt.allocPrint(self.allocator, "Invalid output schema: {s}", .{@errorName(err)}),
                .context = try self.allocator.dupe(u8, "output_schema"),
            });
        };

        if (!output_validation.valid and self.config.strict) {
            try errors.append(.{
                .kind = .invalid_schema,
                .message = try self.allocator.dupe(u8, "Output schema validation failed"),
                .context = try self.allocator.dupe(u8, "output_schema"),
            });
        }
    }

    fn checkPermissions(
        self: *ToolValidator,
        metadata: *const ToolMetadata,
        errors: *std.ArrayList(ValidationError),
        validation_meta: *ValidationMetadata,
    ) !void {
        var required_perms = std.ArrayList(Permission).init(self.allocator);
        defer required_perms.deinit();

        // Check declared requirements
        if (metadata.requires_network) {
            try required_perms.append(.network_access);

            if (!self.config.allow_network) {
                try errors.append(.{
                    .kind = .permission_denied,
                    .message = try self.allocator.dupe(u8, "Tool requires network access which is not allowed"),
                });
            }
        }

        if (metadata.requires_filesystem) {
            try required_perms.append(.filesystem_read);

            if (!self.config.allow_filesystem) {
                try errors.append(.{
                    .kind = .permission_denied,
                    .message = try self.allocator.dupe(u8, "Tool requires filesystem access which is not allowed"),
                });
            }
        }

        validation_meta.permissions_required = try required_perms.toOwnedSlice();
    }

    fn testExecution(
        self: *ToolValidator,
        tool: *Tool,
        context: *RunContext,
        errors: *std.ArrayList(ValidationError),
        warnings: *std.ArrayList(ValidationWarning),
        metadata: *ValidationMetadata,
    ) !void {
        // Create a safe test input
        const test_input = createTestInput(self.allocator, tool.metadata.input_schema) catch |err| {
            try warnings.append(.{
                .kind = .other,
                .message = try std.fmt.allocPrint(self.allocator, "Could not generate test input: {s}", .{@errorName(err)}),
            });
            return;
        };
        defer if (test_input != .null) test_input.deinit(self.allocator);

        const start_time = std.time.milliTimestamp();

        // Set timeout if configured
        const timeout_ms = tool.metadata.timeout_ms orelse self.config.default_timeout_ms;

        // Execute tool with timeout
        const result = executeWithTimeout(tool, context, test_input, timeout_ms) catch |err| {
            try errors.append(.{
                .kind = if (err == error.Timeout) .timeout else .execution_failed,
                .message = try std.fmt.allocPrint(self.allocator, "Test execution failed: {s}", .{@errorName(err)}),
            });
            return;
        };
        defer if (result != .null) result.deinit(self.allocator);

        const execution_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        metadata.execution_time_ms = execution_time;

        // Validate output against schema
        const output_validation = tool.metadata.output_schema.validate(result) catch |err| {
            try errors.append(.{
                .kind = .invalid_schema,
                .message = try std.fmt.allocPrint(self.allocator, "Output does not match schema: {s}", .{@errorName(err)}),
                .context = try self.allocator.dupe(u8, "test_output"),
            });
        };

        if (!output_validation.valid) {
            try errors.append(.{
                .kind = .execution_failed,
                .message = try self.allocator.dupe(u8, "Test output validation failed"),
            });
        }

        // Check performance
        if (self.config.max_execution_time_ms) |max_time| {
            if (execution_time > max_time) {
                try warnings.append(.{
                    .kind = .performance_concern,
                    .message = try std.fmt.allocPrint(self.allocator, "Execution time ({d}ms) exceeds recommended maximum ({d}ms)", .{ execution_time, max_time }),
                });
            }
        }
    }

    fn checkDependencies(
        self: *ToolValidator,
        tool: *Tool,
        errors: *std.ArrayList(ValidationError),
    ) !void {
        // This would check for tool dependencies
        // For now, just a placeholder
        _ = self;
        _ = tool;
        _ = errors;
    }
};

// Validation configuration
pub const ValidationConfig = struct {
    validate_schemas: bool = true,
    check_permissions: bool = true,
    check_dependencies: bool = true,
    test_execution: bool = false,
    collect_metadata: bool = true,
    strict: bool = false,
    allow_network: bool = false,
    allow_filesystem: bool = true,
    default_timeout_ms: u64 = 5000,
    max_execution_time_ms: ?u64 = 10000,
    max_memory_mb: ?usize = 100,
};

// Helper functions
fn isValidToolName(name: []const u8) bool {
    if (name.len == 0) return false;

    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') {
            return false;
        }
    }

    return true;
}

fn isValidVersion(version: []const u8) bool {
    // Simple semver validation
    var parts = std.mem.tokenize(u8, version, ".");
    var count: u8 = 0;

    while (parts.next()) |part| : (count += 1) {
        if (count >= 3) return false;

        _ = std.fmt.parseInt(u32, part, 10) catch return false;
    }

    return count == 3;
}

fn createTestInput(allocator: std.mem.Allocator, schema: schema_mod.Schema) !std.json.Value {
    // Generate test input based on schema
    // This is a simplified version
    return switch (schema.root) {
        .string => std.json.Value{ .string = "test" },
        .number => std.json.Value{ .integer = 42 },
        .boolean => std.json.Value{ .bool = true },
        .object => |_| blk: {
            const obj = std.json.ObjectMap.init(allocator);
            break :blk std.json.Value{ .object = obj };
        },
        .array => |_| blk: {
            const arr = std.json.Array.init(allocator);
            break :blk std.json.Value{ .array = arr };
        },
        else => std.json.Value{ .null = {} },
    };
}

fn executeWithTimeout(
    tool: *Tool,
    context: *RunContext,
    input: std.json.Value,
    timeout_ms: u64,
) !std.json.Value {
    // This would implement actual timeout logic
    // For now, just execute directly
    _ = timeout_ms;
    return tool.execute(context, input);
}

// Batch validation
pub fn validateTools(
    allocator: std.mem.Allocator,
    tools: []*Tool,
    config: ValidationConfig,
    context: ?*RunContext,
) ![]ValidationResult {
    var results = try allocator.alloc(ValidationResult, tools.len);
    var validator = ToolValidator.init(allocator, config);

    for (tools, 0..) |tool, i| {
        results[i] = try validator.validate(tool, context);
    }

    return results;
}

// Tests
test "tool name validation" {
    try std.testing.expect(isValidToolName("valid_tool_name"));
    try std.testing.expect(isValidToolName("tool-with-dash"));
    try std.testing.expect(isValidToolName("tool123"));

    try std.testing.expect(!isValidToolName(""));
    try std.testing.expect(!isValidToolName("tool with space"));
    try std.testing.expect(!isValidToolName("tool@special"));
}

test "version validation" {
    try std.testing.expect(isValidVersion("1.0.0"));
    try std.testing.expect(isValidVersion("0.1.0"));
    try std.testing.expect(isValidVersion("10.20.30"));

    try std.testing.expect(!isValidVersion("1.0"));
    try std.testing.expect(!isValidVersion("1.0.0.0"));
    try std.testing.expect(!isValidVersion("v1.0.0"));
    try std.testing.expect(!isValidVersion("1.a.0"));
}
