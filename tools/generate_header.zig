// ABOUTME: Standalone tool to generate C header file for zig_llms
// ABOUTME: Creates zigllms.h with complete API definitions for external language integration

const std = @import("std");
const header_gen = @import("../src/bindings/header_generator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const config = header_gen.HeaderConfig{
        .library_name = "zigllms",
        .version = "1.0.0",
        .include_guards = true,
        .include_docs = true,
        .include_examples = true,
        .c_standard = .c99,
        .platform_specific = true,
    };
    
    std.log.info("Generating C header file for zig_llms...", .{});
    
    const header_content = try header_gen.generateZigLLMSHeader(allocator, config);
    defer allocator.free(header_content);
    
    // Write to file
    const output_path = "include/zigllms.h";
    
    // Create include directory if it doesn't exist
    std.fs.cwd().makeDir("include") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    
    try file.writeAll(header_content);
    
    std.log.info("Successfully generated {s} ({d} bytes)", .{ output_path, header_content.len });
    
    // Also generate structure definitions file
    try generateStructuresHeader(allocator);
}

fn generateStructuresHeader(allocator: std.mem.Allocator) !void {
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    const writer = output.writer();
    
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @file zigllms_structs.h\n");
    try writer.writeAll(" * @brief ZigLLMS Structure Definitions\n");
    try writer.writeAll(" * @version 1.0.0\n");
    try writer.writeAll(" *\n");
    try writer.writeAll(" * Detailed structure definitions for the ZigLLMS C API.\n");
    try writer.writeAll(" */\n\n");
    
    try writer.writeAll("#ifndef ZIGLLMS_STRUCTS_H\n");
    try writer.writeAll("#define ZIGLLMS_STRUCTS_H\n\n");
    
    try writer.writeAll("#include <stdint.h>\n");
    try writer.writeAll("#include <stdbool.h>\n\n");
    
    try writer.writeAll("#ifdef __cplusplus\n");
    try writer.writeAll("extern \"C\" {\n");
    try writer.writeAll("#endif\n\n");
    
    // Library configuration structure
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Library configuration structure\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("typedef struct ZigLLMSConfig {\n");
    try writer.writeAll("    int allocator_type;    /**< Allocator type: 0=default, 1=arena, 2=pool */\n");
    try writer.writeAll("    int log_level;         /**< Log level: 0=debug, 1=info, 2=warn, 3=error */\n");
    try writer.writeAll("    bool enable_events;    /**< Enable event system */\n");
    try writer.writeAll("    bool enable_metrics;   /**< Enable metrics collection */\n");
    try writer.writeAll("    int max_memory_mb;     /**< Maximum memory usage in MB */\n");
    try writer.writeAll("} ZigLLMSConfig;\n\n");
    
    // Agent configuration structure
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Agent configuration structure\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("typedef struct ZigLLMSAgentConfig {\n");
    try writer.writeAll("    const char* name;        /**< Agent name */\n");
    try writer.writeAll("    const char* description; /**< Agent description */\n");
    try writer.writeAll("    int provider_type;       /**< Provider: 0=openai, 1=anthropic, 2=ollama, 3=gemini */\n");
    try writer.writeAll("    const char* model_name;  /**< Model name */\n");
    try writer.writeAll("    const char* api_key;     /**< API key */\n");
    try writer.writeAll("    const char* api_url;     /**< API URL (optional) */\n");
    try writer.writeAll("    int max_tokens;          /**< Maximum tokens */\n");
    try writer.writeAll("    float temperature;       /**< Temperature parameter */\n");
    try writer.writeAll("    bool enable_memory;      /**< Enable memory */\n");
    try writer.writeAll("    bool enable_tools;       /**< Enable tools */\n");
    try writer.writeAll("} ZigLLMSAgentConfig;\n\n");
    
    // Result structure
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Result structure for API calls\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("typedef struct ZigLLMSResult {\n");
    try writer.writeAll("    int error_code;            /**< Error code (0 = success) */\n");
    try writer.writeAll("    const char* data;          /**< Result data (JSON string) */\n");
    try writer.writeAll("    int data_length;           /**< Data length in bytes */\n");
    try writer.writeAll("    const char* error_message; /**< Error message (if any) */\n");
    try writer.writeAll("} ZigLLMSResult;\n\n");
    
    // Callback types
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Error callback function type\n");
    try writer.writeAll(" * @param error_code Error code\n");
    try writer.writeAll(" * @param category Error category\n");
    try writer.writeAll(" * @param severity Error severity\n");
    try writer.writeAll(" * @param message Error message\n");
    try writer.writeAll(" * @param context Error context\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("typedef void (*ZigLLMSErrorCallback)(\n");
    try writer.writeAll("    int error_code,\n");
    try writer.writeAll("    int category,\n");
    try writer.writeAll("    int severity,\n");
    try writer.writeAll("    const char* message,\n");
    try writer.writeAll("    const char* context\n");
    try writer.writeAll(");\n\n");
    
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Tool callback function type\n");
    try writer.writeAll(" * @param input_json Input JSON string\n");
    try writer.writeAll(" * @return Output JSON string (must be freed by caller)\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("typedef const char* (*ZigLLMSToolCallback)(const char* input_json);\n\n");
    
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Event callback function type\n");
    try writer.writeAll(" * @param event_data Event data JSON string\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("typedef void (*ZigLLMSEventCallback)(const char* event_data);\n\n");
    
    // Default configuration helpers
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Default library configuration\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("#define ZIGLLMS_DEFAULT_CONFIG() { \\\n");
    try writer.writeAll("    .allocator_type = 0, \\\n");
    try writer.writeAll("    .log_level = 1, \\\n");
    try writer.writeAll("    .enable_events = true, \\\n");
    try writer.writeAll("    .enable_metrics = false, \\\n");
    try writer.writeAll("    .max_memory_mb = 100 \\\n");
    try writer.writeAll("}\n\n");
    
    try writer.writeAll("/**\n");
    try writer.writeAll(" * @brief Default agent configuration\n");
    try writer.writeAll(" */\n");
    try writer.writeAll("#define ZIGLLMS_DEFAULT_AGENT_CONFIG() { \\\n");
    try writer.writeAll("    .name = \"default_agent\", \\\n");
    try writer.writeAll("    .description = \"Default agent\", \\\n");
    try writer.writeAll("    .provider_type = 0, \\\n");
    try writer.writeAll("    .model_name = \"gpt-3.5-turbo\", \\\n");
    try writer.writeAll("    .api_key = NULL, \\\n");
    try writer.writeAll("    .api_url = NULL, \\\n");
    try writer.writeAll("    .max_tokens = 1000, \\\n");
    try writer.writeAll("    .temperature = 0.7f, \\\n");
    try writer.writeAll("    .enable_memory = true, \\\n");
    try writer.writeAll("    .enable_tools = true \\\n");
    try writer.writeAll("}\n\n");
    
    try writer.writeAll("#ifdef __cplusplus\n");
    try writer.writeAll("}\n");
    try writer.writeAll("#endif\n\n");
    
    try writer.writeAll("#endif /* ZIGLLMS_STRUCTS_H */\n");
    
    // Write structures header
    const structs_file = try std.fs.cwd().createFile("include/zigllms_structs.h", .{});
    defer structs_file.close();
    
    try structs_file.writeAll(output.items);
    
    std.log.info("Successfully generated include/zigllms_structs.h ({d} bytes)", .{output.items.len});
}