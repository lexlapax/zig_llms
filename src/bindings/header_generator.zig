// ABOUTME: C header file generator for automatic creation of language bindings
// ABOUTME: Generates .h files from Zig C-API definitions for integration with other languages

const std = @import("std");

// Header generation configuration
pub const HeaderConfig = struct {
    library_name: []const u8 = "zigllms",
    version: []const u8 = "1.0.0",
    include_guards: bool = true,
    include_docs: bool = true,
    include_examples: bool = true,
    c_standard: CStandard = .c99,
    platform_specific: bool = true,
    
    pub const CStandard = enum {
        c89,
        c99,
        c11,
        c17,
        
        pub fn toString(self: CStandard) []const u8 {
            return switch (self) {
                .c89 => "C89",
                .c99 => "C99", 
                .c11 => "C11",
                .c17 => "C17",
            };
        }
    };
};

// Function parameter information
pub const ParamInfo = struct {
    name: []const u8,
    type_name: []const u8,
    description: []const u8 = "",
    is_optional: bool = false,
    is_output: bool = false,
};

// Function information for header generation
pub const FunctionInfo = struct {
    name: []const u8,
    return_type: []const u8,
    parameters: []const ParamInfo,
    description: []const u8 = "",
    since_version: []const u8 = "1.0.0",
    deprecated: bool = false,
    example: []const u8 = "",
};

// Type definition information
pub const TypeInfo = struct {
    name: []const u8,
    c_type: []const u8,
    description: []const u8 = "",
    is_opaque: bool = false,
    is_enum: bool = false,
    enum_values: []const EnumValue = &[_]EnumValue{},
    
    pub const EnumValue = struct {
        name: []const u8,
        value: c_int,
        description: []const u8 = "",
    };
};

// Header generator
pub const HeaderGenerator = struct {
    config: HeaderConfig,
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator, config: HeaderConfig) HeaderGenerator {
        return HeaderGenerator{
            .config = config,
            .allocator = allocator,
            .output = std.ArrayList(u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *HeaderGenerator) void {
        self.output.deinit();
    }
    
    pub fn generate(self: *HeaderGenerator, types: []const TypeInfo, functions: []const FunctionInfo) ![]u8 {
        try self.generateHeader();
        try self.generateIncludes();
        try self.generateTypes(types);
        try self.generateFunctions(functions);
        try self.generateFooter();
        
        return try self.output.toOwnedSlice();
    }
    
    fn generateHeader(self: *HeaderGenerator) !void {
        const writer = self.output.writer();
        
        // File header comment
        try writer.print("/**\n");
        try writer.print(" * @file {s}.h\n", .{self.config.library_name});
        try writer.print(" * @brief {s} C API Header\n", .{self.config.library_name});
        try writer.print(" * @version {s}\n", .{self.config.version});
        try writer.print(" * @date {d}\n", .{std.time.timestamp()});
        try writer.print(" *\n");
        try writer.print(" * This header file provides C bindings for the {s} library.\n", .{self.config.library_name});
        try writer.print(" * Generated automatically - do not edit manually.\n");
        try writer.print(" */\n\n");
        
        // Include guards
        if (self.config.include_guards) {
            const guard_name = try std.ascii.allocUpperString(self.allocator, self.config.library_name);
            defer self.allocator.free(guard_name);
            
            try writer.print("#ifndef {s}_H\n", .{guard_name});
            try writer.print("#define {s}_H\n\n", .{guard_name});
        }
        
        // C++ compatibility
        try writer.writeAll("#ifdef __cplusplus\n");
        try writer.writeAll("extern \"C\" {\n");
        try writer.writeAll("#endif\n\n");
    }
    
    fn generateIncludes(self: *HeaderGenerator) !void {
        const writer = self.output.writer();
        
        try writer.writeAll("/* Standard includes */\n");
        try writer.writeAll("#include <stdint.h>\n");
        try writer.writeAll("#include <stdbool.h>\n");
        try writer.writeAll("#include <stddef.h>\n\n");
        
        if (self.config.platform_specific) {
            try writer.writeAll("/* Platform-specific includes */\n");
            try writer.writeAll("#ifdef _WIN32\n");
            try writer.writeAll("    #ifdef ZIGLLMS_EXPORT\n");
            try writer.writeAll("        #define ZIGLLMS_API __declspec(dllexport)\n");
            try writer.writeAll("    #else\n");
            try writer.writeAll("        #define ZIGLLMS_API __declspec(dllimport)\n");
            try writer.writeAll("    #endif\n");
            try writer.writeAll("#else\n");
            try writer.writeAll("    #define ZIGLLMS_API\n");
            try writer.writeAll("#endif\n\n");
        } else {
            try writer.writeAll("#define ZIGLLMS_API\n\n");
        }
    }
    
    fn generateTypes(self: *HeaderGenerator, types: []const TypeInfo) !void {
        const writer = self.output.writer();
        
        try writer.writeAll("/* =============================================================================\n");
        try writer.writeAll(" * TYPE DEFINITIONS\n");
        try writer.writeAll(" * =============================================================================*/\n\n");
        
        // Version constants
        try writer.writeAll("/* Library version */\n");
        try writer.writeAll("#define ZIGLLMS_VERSION_MAJOR 1\n");
        try writer.writeAll("#define ZIGLLMS_VERSION_MINOR 0\n");
        try writer.writeAll("#define ZIGLLMS_VERSION_PATCH 0\n\n");
        
        // Generate each type
        for (types) |type_info| {
            try self.generateType(type_info);
        }
    }
    
    fn generateType(self: *HeaderGenerator, type_info: TypeInfo) !void {
        const writer = self.output.writer();
        
        if (self.config.include_docs and type_info.description.len > 0) {
            try writer.print("/** {s} */\n", .{type_info.description});
        }
        
        if (type_info.is_opaque) {
            try writer.print("typedef struct {s} {s};\n\n", .{ type_info.name, type_info.name });
        } else if (type_info.is_enum) {
            try writer.print("typedef enum {s} {{\n", .{type_info.name});
            
            for (type_info.enum_values) |enum_val| {
                if (self.config.include_docs and enum_val.description.len > 0) {
                    try writer.print("    {s} = {d}, /**< {s} */\n", .{ enum_val.name, enum_val.value, enum_val.description });
                } else {
                    try writer.print("    {s} = {d},\n", .{ enum_val.name, enum_val.value });
                }
            }
            
            try writer.print("}} {s};\n\n", .{type_info.name});
        } else {
            try writer.print("typedef {s} {s};\n\n", .{ type_info.c_type, type_info.name });
        }
    }
    
    fn generateFunctions(self: *HeaderGenerator, functions: []const FunctionInfo) !void {
        const writer = self.output.writer();
        
        try writer.writeAll("/* =============================================================================\n");
        try writer.writeAll(" * FUNCTION DECLARATIONS\n");
        try writer.writeAll(" * =============================================================================*/\n\n");
        
        for (functions) |func_info| {
            try self.generateFunction(func_info);
        }
    }
    
    fn generateFunction(self: *HeaderGenerator, func_info: FunctionInfo) !void {
        const writer = self.output.writer();
        
        // Function documentation
        if (self.config.include_docs) {
            try writer.writeAll("/**\n");
            if (func_info.description.len > 0) {
                try writer.print(" * @brief {s}\n", .{func_info.description});
                try writer.writeAll(" *\n");
            }
            
            // Parameter documentation
            for (func_info.parameters) |param| {
                if (param.description.len > 0) {
                    const param_doc = if (param.is_output) "out" else "in";
                    try writer.print(" * @param[{s}] {s} {s}\n", .{ param_doc, param.name, param.description });
                }
            }
            
            // Return value documentation
            if (!std.mem.eql(u8, func_info.return_type, "void")) {
                try writer.print(" * @return {s}\n", .{func_info.return_type});
            }
            
            try writer.print(" * @since {s}\n", .{func_info.since_version});
            
            if (func_info.deprecated) {
                try writer.writeAll(" * @deprecated This function is deprecated\n");
            }
            
            try writer.writeAll(" */\n");
        }
        
        // Function declaration
        try writer.print("ZIGLLMS_API {s} {s}(", .{ func_info.return_type, func_info.name });
        
        if (func_info.parameters.len == 0) {
            try writer.writeAll("void");
        } else {
            for (func_info.parameters, 0..) |param, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("{s} {s}", .{ param.type_name, param.name });
            }
        }
        
        try writer.writeAll(");\n\n");
        
        // Example code
        if (self.config.include_examples and func_info.example.len > 0) {
            try writer.writeAll("/*\n");
            try writer.print(" * Example usage:\n");
            try writer.print(" * {s}\n", .{func_info.example});
            try writer.writeAll(" */\n\n");
        }
    }
    
    fn generateFooter(self: *HeaderGenerator) !void {
        const writer = self.output.writer();
        
        // C++ compatibility end
        try writer.writeAll("#ifdef __cplusplus\n");
        try writer.writeAll("}\n");
        try writer.writeAll("#endif\n\n");
        
        // Include guard end
        if (self.config.include_guards) {
            const guard_name = try std.ascii.allocUpperString(self.allocator, self.config.library_name);
            defer self.allocator.free(guard_name);
            
            try writer.print("#endif /* {s}_H */\n", .{guard_name});
        }
    }
};

// Predefined type information for zig_llms
pub fn getZigLLMSTypes(allocator: std.mem.Allocator) ![]TypeInfo {
    var types = std.ArrayList(TypeInfo).init(allocator);
    
    // Opaque handle types
    try types.append(TypeInfo{
        .name = "ZigLLMSHandle",
        .c_type = "struct ZigLLMSHandle",
        .description = "Opaque handle to the main library instance",
        .is_opaque = true,
    });
    
    try types.append(TypeInfo{
        .name = "ZigLLMSAgent",
        .c_type = "struct ZigLLMSAgent",
        .description = "Opaque handle to an agent instance",
        .is_opaque = true,
    });
    
    try types.append(TypeInfo{
        .name = "ZigLLMSTool",
        .c_type = "struct ZigLLMSTool", 
        .description = "Opaque handle to a tool instance",
        .is_opaque = true,
    });
    
    try types.append(TypeInfo{
        .name = "ZigLLMSWorkflow",
        .c_type = "struct ZigLLMSWorkflow",
        .description = "Opaque handle to a workflow instance",
        .is_opaque = true,
    });
    
    try types.append(TypeInfo{
        .name = "ZigLLMSEventEmitter",
        .c_type = "struct ZigLLMSEventEmitter",
        .description = "Opaque handle to an event emitter instance",
        .is_opaque = true,
    });
    
    // Error enum
    const error_values = [_]TypeInfo.EnumValue{
        .{ .name = "ZIGLLMS_SUCCESS", .value = 0, .description = "Operation completed successfully" },
        .{ .name = "ZIGLLMS_NULL_POINTER", .value = -1, .description = "Null pointer provided" },
        .{ .name = "ZIGLLMS_INVALID_PARAMETER", .value = -2, .description = "Invalid parameter value" },
        .{ .name = "ZIGLLMS_MEMORY_ERROR", .value = -3, .description = "Memory allocation failed" },
        .{ .name = "ZIGLLMS_INITIALIZATION_FAILED", .value = -4, .description = "Library initialization failed" },
        .{ .name = "ZIGLLMS_AGENT_ERROR", .value = -5, .description = "Agent operation failed" },
        .{ .name = "ZIGLLMS_TOOL_ERROR", .value = -6, .description = "Tool operation failed" },
        .{ .name = "ZIGLLMS_WORKFLOW_ERROR", .value = -7, .description = "Workflow operation failed" },
        .{ .name = "ZIGLLMS_PROVIDER_ERROR", .value = -8, .description = "Provider operation failed" },
        .{ .name = "ZIGLLMS_JSON_ERROR", .value = -9, .description = "JSON parsing/formatting failed" },
        .{ .name = "ZIGLLMS_TIMEOUT_ERROR", .value = -10, .description = "Operation timed out" },
        .{ .name = "ZIGLLMS_UNKNOWN_ERROR", .value = -99, .description = "Unknown error occurred" },
    };
    
    try types.append(TypeInfo{
        .name = "ZigLLMSError",
        .c_type = "int",
        .description = "Error codes returned by library functions",
        .is_enum = true,
        .enum_values = try allocator.dupe(TypeInfo.EnumValue, &error_values),
    });
    
    // Configuration structures
    try types.append(TypeInfo{
        .name = "ZigLLMSConfig",
        .c_type = "struct ZigLLMSConfig",
        .description = "Library configuration structure",
    });
    
    try types.append(TypeInfo{
        .name = "ZigLLMSAgentConfig", 
        .c_type = "struct ZigLLMSAgentConfig",
        .description = "Agent configuration structure",
    });
    
    try types.append(TypeInfo{
        .name = "ZigLLMSResult",
        .c_type = "struct ZigLLMSResult",
        .description = "Result structure for API calls",
    });
    
    return try types.toOwnedSlice();
}

// Predefined function information for zig_llms
pub fn getZigLLMSFunctions(allocator: std.mem.Allocator) ![]FunctionInfo {
    var functions = std.ArrayList(FunctionInfo).init(allocator);
    
    // Initialization functions
    try functions.append(FunctionInfo{
        .name = "zigllms_init",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "config", .type_name = "const ZigLLMSConfig*", .description = "Library configuration" },
        },
        .description = "Initialize the zig_llms library",
        .example = "ZigLLMSConfig config = {0}; zigllms_init(&config);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_cleanup",
        .return_type = "void", 
        .parameters = &[_]ParamInfo{},
        .description = "Cleanup and shutdown the library",
        .example = "zigllms_cleanup();",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_get_version",
        .return_type = "void",
        .parameters = &[_]ParamInfo{
            .{ .name = "major", .type_name = "int*", .description = "Major version number", .is_output = true },
            .{ .name = "minor", .type_name = "int*", .description = "Minor version number", .is_output = true },
            .{ .name = "patch", .type_name = "int*", .description = "Patch version number", .is_output = true },
        },
        .description = "Get library version information",
        .example = "int major, minor, patch; zigllms_get_version(&major, &minor, &patch);",
    });
    
    // Agent functions
    try functions.append(FunctionInfo{
        .name = "zigllms_agent_create",
        .return_type = "ZigLLMSAgent*",
        .parameters = &[_]ParamInfo{
            .{ .name = "config", .type_name = "const ZigLLMSAgentConfig*", .description = "Agent configuration" },
        },
        .description = "Create a new agent instance",
        .example = "ZigLLMSAgentConfig config = {0}; ZigLLMSAgent* agent = zigllms_agent_create(&config);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_agent_destroy",
        .return_type = "void",
        .parameters = &[_]ParamInfo{
            .{ .name = "agent", .type_name = "ZigLLMSAgent*", .description = "Agent handle to destroy" },
        },
        .description = "Destroy an agent instance",
        .example = "zigllms_agent_destroy(agent);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_agent_run",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "agent", .type_name = "ZigLLMSAgent*", .description = "Agent handle" },
            .{ .name = "input_json", .type_name = "const char*", .description = "Input JSON string" },
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "Result structure", .is_output = true },
        },
        .description = "Execute agent with input and return result",
        .example = "ZigLLMSResult result; zigllms_agent_run(agent, \"{\\\"message\\\": \\\"hello\\\"}\", &result);",
    });
    
    // Memory functions
    try functions.append(FunctionInfo{
        .name = "zigllms_result_free",
        .return_type = "void",
        .parameters = &[_]ParamInfo{
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "Result to free" },
        },
        .description = "Free a result returned by the API",
        .example = "zigllms_result_free(&result);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_memory_stats",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "Memory statistics", .is_output = true },
        },
        .description = "Get memory usage statistics",
        .example = "ZigLLMSResult stats; zigllms_memory_stats(&stats);",
    });
    
    // Error handling functions
    try functions.append(FunctionInfo{
        .name = "zigllms_get_last_error",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "Last error information", .is_output = true },
        },
        .description = "Get last error information",
        .example = "ZigLLMSResult error_info; zigllms_get_last_error(&error_info);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_clear_errors",
        .return_type = "void",
        .parameters = &[_]ParamInfo{},
        .description = "Clear all errors",
        .example = "zigllms_clear_errors();",
    });
    
    // Tool management functions
    try functions.append(FunctionInfo{
        .name = "zigllms_tool_register",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "name", .type_name = "const char*", .description = "Tool name" },
            .{ .name = "description", .type_name = "const char*", .description = "Tool description" },
            .{ .name = "schema_json", .type_name = "const char*", .description = "Tool schema JSON (optional)" },
            .{ .name = "callback", .type_name = "ZigLLMSToolCallback", .description = "Tool callback function" },
        },
        .description = "Register an external tool with callback",
        .example = "zigllms_tool_register(\"my_tool\", \"My tool\", \"{}\", my_callback);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_tool_execute",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "tool_name", .type_name = "const char*", .description = "Tool name to execute" },
            .{ .name = "input_json", .type_name = "const char*", .description = "Input JSON" },
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "Execution result", .is_output = true },
        },
        .description = "Execute a registered tool",
        .example = "ZigLLMSResult result; zigllms_tool_execute(\"my_tool\", \"{}\", &result);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_tool_list",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "List of registered tools", .is_output = true },
        },
        .description = "List all registered tools",
        .example = "ZigLLMSResult tools; zigllms_tool_list(&tools);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_tool_unregister",
        .return_type = "int", 
        .parameters = &[_]ParamInfo{
            .{ .name = "tool_name", .type_name = "const char*", .description = "Tool name to unregister" },
        },
        .description = "Unregister a tool",
        .example = "zigllms_tool_unregister(\"my_tool\");",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_tool_get_info",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "tool_name", .type_name = "const char*", .description = "Tool name" },
            .{ .name = "result", .type_name = "ZigLLMSResult*", .description = "Tool information", .is_output = true },
        },
        .description = "Get tool information",
        .example = "ZigLLMSResult info; zigllms_tool_get_info(\"my_tool\", &info);",
    });
    
    try functions.append(FunctionInfo{
        .name = "zigllms_tool_exists",
        .return_type = "int",
        .parameters = &[_]ParamInfo{
            .{ .name = "tool_name", .type_name = "const char*", .description = "Tool name to check" },
        },
        .description = "Check if a tool is registered (returns 1 if exists, 0 if not)",
        .example = "int exists = zigllms_tool_exists(\"my_tool\");",
    });
    
    return try functions.toOwnedSlice();
}

// Generate complete header file
pub fn generateZigLLMSHeader(allocator: std.mem.Allocator, config: HeaderConfig) ![]u8 {
    var generator = HeaderGenerator.init(allocator, config);
    defer generator.deinit();
    
    const types = try getZigLLMSTypes(allocator);
    defer allocator.free(types);
    
    const functions = try getZigLLMSFunctions(allocator);
    defer allocator.free(functions);
    
    return try generator.generate(types, functions);
}

// Tests
test "header generator basic functionality" {
    const allocator = std.testing.allocator;
    
    const config = HeaderConfig{
        .library_name = "test",
        .version = "0.1.0",
        .include_docs = false,
        .include_examples = false,
    };
    
    var generator = HeaderGenerator.init(allocator, config);
    defer generator.deinit();
    
    const types = [_]TypeInfo{
        .{
            .name = "TestHandle",
            .c_type = "struct TestHandle",
            .is_opaque = true,
        },
    };
    
    const functions = [_]FunctionInfo{
        .{
            .name = "test_init",
            .return_type = "int",
            .parameters = &[_]ParamInfo{},
        },
    };
    
    const header = try generator.generate(&types, &functions);
    defer allocator.free(header);
    
    try std.testing.expect(std.mem.indexOf(u8, header, "typedef struct TestHandle TestHandle;") != null);
    try std.testing.expect(std.mem.indexOf(u8, header, "int test_init(void);") != null);
}