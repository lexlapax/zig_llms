// ABOUTME: Output API bridge for exposing output parsing functionality to scripts
// ABOUTME: Enables structured output parsing, JSON extraction, and format conversion from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms output parsing API
const output_parser = @import("../../output/parser.zig");
const json_extractor = @import("../../output/json_extractor.zig");
const format_converter = @import("../../output/format_converter.zig");
const structure_validator = @import("../../output/structure_validator.zig");

/// Script parser configuration
const ScriptParserConfig = struct {
    format: OutputFormat,
    strict: bool = false,
    fallback_enabled: bool = true,
    custom_patterns: ?[]const []const u8 = null,
    
    const OutputFormat = enum {
        json,
        yaml,
        xml,
        markdown,
        csv,
        plain_text,
        code_block,
        structured,
    };
};

/// Output Bridge implementation
pub const OutputBridge = struct {
    pub const bridge = APIBridge{
        .name = "output",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };
    
    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);
        
        module.* = ScriptModule{
            .name = "output",
            .functions = &output_functions,
            .constants = &output_constants,
            .description = "Output parsing and structured data extraction API",
            .version = "1.0.0",
        };
        
        return module;
    }
    
    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;
        _ = context;
        // No global state needed for output parsing
    }
    
    fn deinit() void {
        // No cleanup needed
    }
};

// Output module functions
const output_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "parseJson",
        "Parse JSON from text output",
        1,
        parseJsonOutput,
    ),
    createModuleFunction(
        "parseJsonWithFallback",
        "Parse JSON with fallback strategies",
        2,
        parseJsonWithFallback,
    ),
    createModuleFunction(
        "extractJson",
        "Extract JSON blocks from text",
        1,
        extractJsonBlocks,
    ),
    createModuleFunction(
        "extractCodeBlocks",
        "Extract code blocks by language",
        2,
        extractCodeBlocks,
    ),
    createModuleFunction(
        "parseYaml",
        "Parse YAML from text output",
        1,
        parseYamlOutput,
    ),
    createModuleFunction(
        "parseXml",
        "Parse XML from text output",
        1,
        parseXmlOutput,
    ),
    createModuleFunction(
        "parseCsv",
        "Parse CSV data with options",
        2,
        parseCsvData,
    ),
    createModuleFunction(
        "parseMarkdown",
        "Parse markdown structure",
        1,
        parseMarkdownStructure,
    ),
    createModuleFunction(
        "parseStructured",
        "Parse with structure definition",
        2,
        parseStructuredOutput,
    ),
    createModuleFunction(
        "extractTables",
        "Extract tables from text",
        1,
        extractTables,
    ),
    createModuleFunction(
        "extractLists",
        "Extract lists from text",
        1,
        extractLists,
    ),
    createModuleFunction(
        "extractKeyValue",
        "Extract key-value pairs",
        2,
        extractKeyValuePairs,
    ),
    createModuleFunction(
        "convert",
        "Convert between formats",
        3,
        convertFormat,
    ),
    createModuleFunction(
        "validate",
        "Validate output structure",
        2,
        validateStructure,
    ),
    createModuleFunction(
        "repair",
        "Repair malformed output",
        2,
        repairOutput,
    ),
    createModuleFunction(
        "clean",
        "Clean and normalize output",
        2,
        cleanOutput,
    ),
    createModuleFunction(
        "template",
        "Apply output template",
        2,
        applyTemplate,
    ),
    createModuleFunction(
        "split",
        "Split output by delimiter",
        2,
        splitOutput,
    ),
    createModuleFunction(
        "merge",
        "Merge multiple outputs",
        2,
        mergeOutputs,
    ),
    createModuleFunction(
        "format",
        "Format output for display",
        2,
        formatOutput,
    ),
};

// Output module constants
const output_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "FORMAT_JSON",
        ScriptValue{ .string = "json" },
        "JSON output format",
    ),
    createModuleConstant(
        "FORMAT_YAML",
        ScriptValue{ .string = "yaml" },
        "YAML output format",
    ),
    createModuleConstant(
        "FORMAT_XML",
        ScriptValue{ .string = "xml" },
        "XML output format",
    ),
    createModuleConstant(
        "FORMAT_MARKDOWN",
        ScriptValue{ .string = "markdown" },
        "Markdown output format",
    ),
    createModuleConstant(
        "FORMAT_CSV",
        ScriptValue{ .string = "csv" },
        "CSV output format",
    ),
    createModuleConstant(
        "FORMAT_PLAIN",
        ScriptValue{ .string = "plain_text" },
        "Plain text output format",
    ),
    createModuleConstant(
        "FORMAT_CODE",
        ScriptValue{ .string = "code_block" },
        "Code block output format",
    ),
    createModuleConstant(
        "FORMAT_STRUCTURED",
        ScriptValue{ .string = "structured" },
        "Structured output format",
    ),
    createModuleConstant(
        "REPAIR_STRATEGY_NONE",
        ScriptValue{ .string = "none" },
        "No repair strategy",
    ),
    createModuleConstant(
        "REPAIR_STRATEGY_BASIC",
        ScriptValue{ .string = "basic" },
        "Basic repair strategy",
    ),
    createModuleConstant(
        "REPAIR_STRATEGY_AGGRESSIVE",
        ScriptValue{ .string = "aggressive" },
        "Aggressive repair strategy",
    ),
};

// Implementation functions

fn parseJsonOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    // Try to find JSON in the text
    const json_start = std.mem.indexOf(u8, text, "{") orelse std.mem.indexOf(u8, text, "[") orelse return ScriptValue.nil;
    
    var depth: i32 = 0;
    var json_end: ?usize = null;
    var in_string = false;
    var escape_next = false;
    
    for (text[json_start..], json_start..) |char, i| {
        if (escape_next) {
            escape_next = false;
            continue;
        }
        
        if (char == '\\' and in_string) {
            escape_next = true;
            continue;
        }
        
        if (char == '"' and !escape_next) {
            in_string = !in_string;
            continue;
        }
        
        if (!in_string) {
            switch (char) {
                '{', '[' => depth += 1,
                '}', ']' => {
                    depth -= 1;
                    if (depth == 0) {
                        json_end = i + 1;
                        break;
                    }
                },
                else => {},
            }
        }
    }
    
    if (json_end) |end| {
        const json_str = text[json_start..end];
        
        // Parse JSON
        var parser = std.json.Parser.init(allocator, false);
        defer parser.deinit();
        
        var tree = parser.parse(json_str) catch return ScriptValue.nil;
        defer tree.deinit();
        
        return try TypeMarshaler.unmarshalJsonValue(tree.root, allocator);
    }
    
    return ScriptValue.nil;
}

fn parseJsonWithFallback(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const options = args[1].object;
    const allocator = options.allocator;
    
    // Try normal JSON parsing first
    const parse_args = [_]ScriptValue{args[0]};
    const result = parseJsonOutput(&parse_args) catch ScriptValue.nil;
    
    if (result != .nil) {
        return result;
    }
    
    // Apply fallback strategies
    const strategies = options.get("strategies") orelse return ScriptValue.nil;
    
    if (strategies == .array) {
        for (strategies.array.items) |strategy| {
            if (strategy == .string) {
                if (std.mem.eql(u8, strategy.string, "repair")) {
                    // Try to repair JSON
                    const repaired = try repairJsonString(text, allocator);
                    defer allocator.free(repaired);
                    
                    const repair_args = [_]ScriptValue{ScriptValue{ .string = repaired }};
                    const repaired_result = parseJsonOutput(&repair_args) catch ScriptValue.nil;
                    
                    if (repaired_result != .nil) {
                        return repaired_result;
                    }
                } else if (std.mem.eql(u8, strategy.string, "extract_values")) {
                    // Extract key-value pairs as fallback
                    var result_obj = ScriptValue.Object.init(allocator);
                    
                    // Simple key-value extraction
                    var lines = std.mem.tokenize(u8, text, "\n");
                    while (lines.next()) |line| {
                        if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                            const key = std.mem.trim(u8, line[0..colon_pos], " \t\"'");
                            const value = std.mem.trim(u8, line[colon_pos + 1..], " \t\"'");
                            try result_obj.put(key, ScriptValue{ .string = try allocator.dupe(u8, value) });
                        }
                    }
                    
                    if (result_obj.map.count() > 0) {
                        return ScriptValue{ .object = result_obj };
                    }
                }
            }
        }
    }
    
    return ScriptValue.nil;
}

fn extractJsonBlocks(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var blocks = std.ArrayList(ScriptValue).init(allocator);
    
    // Find all potential JSON blocks
    var start_pos: usize = 0;
    while (start_pos < text.len) {
        const json_start = (std.mem.indexOfPos(u8, text, start_pos, "{") orelse text.len);
        const array_start = (std.mem.indexOfPos(u8, text, start_pos, "[") orelse text.len);
        
        const next_start = @min(json_start, array_start);
        if (next_start >= text.len) break;
        
        // Try to parse from this position
        const parse_args = [_]ScriptValue{ScriptValue{ .string = text[next_start..] }};
        const result = parseJsonOutput(&parse_args) catch ScriptValue.nil;
        
        if (result != .nil) {
            try blocks.append(result);
        }
        
        start_pos = next_start + 1;
    }
    
    return ScriptValue{ .array = .{ .items = try blocks.toOwnedSlice(), .allocator = allocator } };
}

fn extractCodeBlocks(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const language = if (args[1] == .string) args[1].string else null;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var blocks = std.ArrayList(ScriptValue).init(allocator);
    
    // Find markdown code blocks
    var pos: usize = 0;
    while (pos < text.len) {
        const block_start = std.mem.indexOfPos(u8, text, pos, "```") orelse break;
        const lang_start = block_start + 3;
        
        // Find end of language specifier
        const newline_pos = std.mem.indexOfPos(u8, text, lang_start, "\n") orelse break;
        const lang_spec = std.mem.trim(u8, text[lang_start..newline_pos], " \r");
        
        // Find end of code block
        const content_start = newline_pos + 1;
        const block_end = std.mem.indexOfPos(u8, text, content_start, "```") orelse break;
        
        // Check if language matches (if specified)
        if (language == null or std.mem.eql(u8, lang_spec, language.?)) {
            var block_obj = ScriptValue.Object.init(allocator);
            try block_obj.put("language", ScriptValue{ .string = try allocator.dupe(u8, lang_spec) });
            try block_obj.put("content", ScriptValue{ .string = try allocator.dupe(u8, text[content_start..block_end]) });
            try blocks.append(ScriptValue{ .object = block_obj });
        }
        
        pos = block_end + 3;
    }
    
    return ScriptValue{ .array = .{ .items = try blocks.toOwnedSlice(), .allocator = allocator } };
}

fn parseYamlOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    // Simplified YAML parsing (basic key-value)
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var result = ScriptValue.Object.init(allocator);
    
    var lines = std.mem.tokenize(u8, text, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            const value = std.mem.trim(u8, trimmed[colon_pos + 1..], " \t");
            
            // Simple type inference
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                try result.put(key, ScriptValue{ .boolean = std.mem.eql(u8, value, "true") });
            } else if (std.fmt.parseInt(i64, value, 10)) |int_val| {
                try result.put(key, ScriptValue{ .integer = int_val });
            } else if (std.fmt.parseFloat(f64, value)) |float_val| {
                try result.put(key, ScriptValue{ .number = float_val });
            } else {
                try result.put(key, ScriptValue{ .string = try allocator.dupe(u8, value) });
            }
        }
    }
    
    return ScriptValue{ .object = result };
}

fn parseXmlOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    // Simplified XML parsing (extract tag content)
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var result = ScriptValue.Object.init(allocator);
    
    // Extract simple tags
    var pos: usize = 0;
    while (pos < text.len) {
        const tag_start = std.mem.indexOfPos(u8, text, pos, "<") orelse break;
        const tag_end = std.mem.indexOfPos(u8, text, tag_start, ">") orelse break;
        
        const tag = text[tag_start + 1..tag_end];
        if (tag[0] == '/' or tag[0] == '?' or tag[0] == '!') {
            pos = tag_end + 1;
            continue;
        }
        
        // Find closing tag
        const close_tag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
        defer allocator.free(close_tag);
        
        const content_start = tag_end + 1;
        if (std.mem.indexOfPos(u8, text, content_start, close_tag)) |close_pos| {
            const content = std.mem.trim(u8, text[content_start..close_pos], " \t\n\r");
            try result.put(tag, ScriptValue{ .string = try allocator.dupe(u8, content) });
            pos = close_pos + close_tag.len;
        } else {
            pos = tag_end + 1;
        }
    }
    
    return ScriptValue{ .object = result };
}

fn parseCsvData(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const options = args[1].object;
    const allocator = options.allocator;
    
    const delimiter = if (options.get("delimiter")) |d|
        (try d.toZig([]const u8, allocator))[0]
    else
        ',';
        
    const has_header = if (options.get("header")) |h|
        try h.toZig(bool, allocator)
    else
        true;
    
    var rows = std.ArrayList(ScriptValue).init(allocator);
    var headers: ?[][]const u8 = null;
    defer if (headers) |h| allocator.free(h);
    
    var lines = std.mem.tokenize(u8, text, "\n\r");
    var line_num: usize = 0;
    
    while (lines.next()) |line| : (line_num += 1) {
        var fields = std.ArrayList([]const u8).init(allocator);
        defer fields.deinit();
        
        // Simple CSV parsing (doesn't handle quoted fields with delimiters)
        var field_iter = std.mem.tokenize(u8, line, &[_]u8{delimiter});
        while (field_iter.next()) |field| {
            try fields.append(std.mem.trim(u8, field, " \t\""));
        }
        
        if (line_num == 0 and has_header) {
            headers = try fields.toOwnedSlice();
        } else {
            if (headers) |hdrs| {
                var row_obj = ScriptValue.Object.init(allocator);
                for (fields.items, 0..) |field, i| {
                    const key = if (i < hdrs.len) hdrs[i] else try std.fmt.allocPrint(allocator, "field{}", .{i});
                    try row_obj.put(key, ScriptValue{ .string = try allocator.dupe(u8, field) });
                }
                try rows.append(ScriptValue{ .object = row_obj });
            } else {
                var row_array = try ScriptValue.Array.init(allocator, fields.items.len);
                for (fields.items, 0..) |field, i| {
                    row_array.items[i] = ScriptValue{ .string = try allocator.dupe(u8, field) };
                }
                try rows.append(ScriptValue{ .array = row_array });
            }
        }
    }
    
    return ScriptValue{ .array = .{ .items = try rows.toOwnedSlice(), .allocator = allocator } };
}

fn parseMarkdownStructure(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var structure = ScriptValue.Object.init(allocator);
    var sections = std.ArrayList(ScriptValue).init(allocator);
    
    var lines = std.mem.split(u8, text, "\n");
    var current_section: ?ScriptValue.Object = null;
    var current_content = std.ArrayList(u8).init(allocator);
    
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "#")) {
            // Save previous section
            if (current_section) |*section| {
                try section.put("content", ScriptValue{ .string = try current_content.toOwnedSlice() });
                try sections.append(ScriptValue{ .object = section.* });
                current_content = std.ArrayList(u8).init(allocator);
            }
            
            // Parse heading level and text
            var level: u32 = 0;
            for (line) |char| {
                if (char == '#') level += 1 else break;
            }
            
            const heading_text = std.mem.trim(u8, line[level..], " \t");
            
            current_section = ScriptValue.Object.init(allocator);
            try current_section.?.put("level", ScriptValue{ .integer = @intCast(level) });
            try current_section.?.put("heading", ScriptValue{ .string = try allocator.dupe(u8, heading_text) });
        } else if (current_section != null) {
            try current_content.appendSlice(line);
            try current_content.append('\n');
        }
    }
    
    // Save last section
    if (current_section) |*section| {
        try section.put("content", ScriptValue{ .string = try current_content.toOwnedSlice() });
        try sections.append(ScriptValue{ .object = section.* });
    }
    
    try structure.put("sections", ScriptValue{ .array = .{ .items = try sections.toOwnedSlice(), .allocator = allocator } });
    
    return ScriptValue{ .object = structure };
}

fn parseStructuredOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const structure_def = args[1].object;
    const allocator = structure_def.allocator;
    
    // Try different parsing strategies based on structure definition
    if (structure_def.get("format")) |format| {
        if (format == .string) {
            if (std.mem.eql(u8, format.string, "json")) {
                const json_args = [_]ScriptValue{args[0]};
                return try parseJsonOutput(&json_args);
            } else if (std.mem.eql(u8, format.string, "yaml")) {
                const yaml_args = [_]ScriptValue{args[0]};
                return try parseYamlOutput(&yaml_args);
            } else if (std.mem.eql(u8, format.string, "xml")) {
                const xml_args = [_]ScriptValue{args[0]};
                return try parseXmlOutput(&xml_args);
            }
        }
    }
    
    // Default to key-value extraction
    var options = ScriptValue.Object.init(allocator);
    try options.put("delimiter", ScriptValue{ .string = try allocator.dupe(u8, ":") });
    
    const kv_args = [_]ScriptValue{ args[0], ScriptValue{ .object = options } };
    return try extractKeyValuePairs(&kv_args);
}

fn extractTables(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var tables = std.ArrayList(ScriptValue).init(allocator);
    
    // Simple table detection (looks for lines with multiple | characters)
    var lines = std.mem.split(u8, text, "\n");
    var in_table = false;
    var current_table = std.ArrayList([]const u8).init(allocator);
    
    while (lines.next()) |line| {
        const pipe_count = std.mem.count(u8, line, "|");
        
        if (pipe_count >= 2) {
            in_table = true;
            try current_table.append(line);
        } else if (in_table and (pipe_count == 0 or line.len == 0)) {
            // End of table
            if (current_table.items.len > 0) {
                // Parse table
                var table_obj = ScriptValue.Object.init(allocator);
                
                // Assume first row is header
                if (current_table.items.len > 0) {
                    var headers = std.ArrayList([]const u8).init(allocator);
                    var header_iter = std.mem.tokenize(u8, current_table.items[0], "|");
                    while (header_iter.next()) |header| {
                        try headers.append(std.mem.trim(u8, header, " \t"));
                    }
                    
                    var rows_array = std.ArrayList(ScriptValue).init(allocator);
                    
                    // Skip separator line if present
                    const start_idx: usize = if (current_table.items.len > 1 and std.mem.count(u8, current_table.items[1], "-") > 3) 2 else 1;
                    
                    for (current_table.items[start_idx..]) |row_line| {
                        var row_obj = ScriptValue.Object.init(allocator);
                        var cell_iter = std.mem.tokenize(u8, row_line, "|");
                        var col_idx: usize = 0;
                        
                        while (cell_iter.next()) |cell| : (col_idx += 1) {
                            if (col_idx < headers.items.len) {
                                try row_obj.put(headers.items[col_idx], ScriptValue{ .string = try allocator.dupe(u8, std.mem.trim(u8, cell, " \t")) });
                            }
                        }
                        
                        try rows_array.append(ScriptValue{ .object = row_obj });
                    }
                    
                    try table_obj.put("headers", ScriptValue{ .array = .{
                        .items = blk: {
                            var h = try allocator.alloc(ScriptValue, headers.items.len);
                            for (headers.items, 0..) |hdr, i| {
                                h[i] = ScriptValue{ .string = try allocator.dupe(u8, hdr) };
                            }
                            break :blk h;
                        },
                        .allocator = allocator,
                    } });
                    try table_obj.put("rows", ScriptValue{ .array = .{ .items = try rows_array.toOwnedSlice(), .allocator = allocator } });
                    
                    try tables.append(ScriptValue{ .object = table_obj });
                }
                
                current_table.clearRetainingCapacity();
            }
            in_table = false;
        }
    }
    
    return ScriptValue{ .array = .{ .items = try tables.toOwnedSlice(), .allocator = allocator } };
}

fn extractLists(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var lists = std.ArrayList(ScriptValue).init(allocator);
    var current_list = std.ArrayList(ScriptValue).init(allocator);
    var in_list = false;
    
    var lines = std.mem.split(u8, text, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        
        // Check for list markers
        const is_list_item = std.mem.startsWith(u8, trimmed, "- ") or
                            std.mem.startsWith(u8, trimmed, "* ") or
                            std.mem.startsWith(u8, trimmed, "+ ") or
                            (trimmed.len > 2 and trimmed[0] >= '0' and trimmed[0] <= '9' and trimmed[1] == '.');
        
        if (is_list_item) {
            in_list = true;
            const content_start = if (trimmed[1] == ' ') 2 else 3; // Handle "- " or "1. "
            const content = std.mem.trim(u8, trimmed[content_start..], " \t");
            try current_list.append(ScriptValue{ .string = try allocator.dupe(u8, content) });
        } else if (in_list and trimmed.len == 0) {
            // End of list
            if (current_list.items.len > 0) {
                try lists.append(ScriptValue{ .array = .{ .items = try current_list.toOwnedSlice(), .allocator = allocator } });
                current_list = std.ArrayList(ScriptValue).init(allocator);
            }
            in_list = false;
        }
    }
    
    // Save last list
    if (current_list.items.len > 0) {
        try lists.append(ScriptValue{ .array = .{ .items = try current_list.toOwnedSlice(), .allocator = allocator } });
    }
    
    return ScriptValue{ .array = .{ .items = try lists.toOwnedSlice(), .allocator = allocator } };
}

fn extractKeyValuePairs(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const options = args[1].object;
    const allocator = options.allocator;
    
    const delimiter = if (options.get("delimiter")) |d|
        try d.toZig([]const u8, allocator)
    else
        ":";
    
    var pairs = ScriptValue.Object.init(allocator);
    
    var lines = std.mem.tokenize(u8, text, "\n\r");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, delimiter)) |delim_pos| {
            const key = std.mem.trim(u8, line[0..delim_pos], " \t\"'");
            const value = std.mem.trim(u8, line[delim_pos + delimiter.len..], " \t\"'");
            
            // Type inference for values
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                try pairs.put(key, ScriptValue{ .boolean = std.mem.eql(u8, value, "true") });
            } else if (std.fmt.parseInt(i64, value, 10)) |int_val| {
                try pairs.put(key, ScriptValue{ .integer = int_val });
            } else if (std.fmt.parseFloat(f64, value)) |float_val| {
                try pairs.put(key, ScriptValue{ .number = float_val });
            } else {
                try pairs.put(key, ScriptValue{ .string = try allocator.dupe(u8, value) });
            }
        }
    }
    
    return ScriptValue{ .object = pairs };
}

fn convertFormat(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[1] != .string or args[2] != .string) {
        return error.InvalidArguments;
    }
    
    const data = args[0];
    const from_format = args[1].string;
    const to_format = args[2].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", from_format).allocator;
    
    _ = from_format; // For now, assume input is already parsed
    
    if (std.mem.eql(u8, to_format, "json")) {
        // Convert to JSON
        const json_value = try TypeMarshaler.marshalJsonValue(data, allocator);
        defer json_value.deinit();
        
        var string = std.ArrayList(u8).init(allocator);
        try std.json.stringify(json_value, .{}, string.writer());
        
        return ScriptValue{ .string = try string.toOwnedSlice() };
    } else if (std.mem.eql(u8, to_format, "yaml")) {
        // Simple YAML conversion
        var yaml = std.ArrayList(u8).init(allocator);
        try convertToYaml(data, &yaml, 0);
        return ScriptValue{ .string = try yaml.toOwnedSlice() };
    } else if (std.mem.eql(u8, to_format, "csv")) {
        // Convert array of objects to CSV
        if (data == .array and data.array.items.len > 0 and data.array.items[0] == .object) {
            var csv = std.ArrayList(u8).init(allocator);
            
            // Write headers
            var headers = std.ArrayList([]const u8).init(allocator);
            var iter = data.array.items[0].object.map.iterator();
            while (iter.next()) |entry| {
                try headers.append(entry.key_ptr.*);
            }
            
            for (headers.items, 0..) |header, i| {
                if (i > 0) try csv.append(',');
                try csv.appendSlice(header);
            }
            try csv.append('\n');
            
            // Write rows
            for (data.array.items) |row| {
                if (row == .object) {
                    for (headers.items, 0..) |header, i| {
                        if (i > 0) try csv.append(',');
                        if (row.object.get(header)) |value| {
                            switch (value) {
                                .string => |s| try csv.appendSlice(s),
                                .integer => |n| try csv.writer().print("{}", .{n}),
                                .number => |n| try csv.writer().print("{d}", .{n}),
                                .boolean => |b| try csv.appendSlice(if (b) "true" else "false"),
                                else => {},
                            }
                        }
                    }
                    try csv.append('\n');
                }
            }
            
            return ScriptValue{ .string = try csv.toOwnedSlice() };
        }
    }
    
    return data; // Return unchanged if conversion not supported
}

fn validateStructure(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const data = args[0];
    const expected = args[1].object;
    const allocator = expected.allocator;
    
    var result = ScriptValue.Object.init(allocator);
    var errors = std.ArrayList(ScriptValue).init(allocator);
    
    // Simple structure validation
    const is_valid = try validateValue(data, expected, &errors, allocator);
    
    try result.put("valid", ScriptValue{ .boolean = is_valid });
    try result.put("errors", ScriptValue{ .array = .{ .items = try errors.toOwnedSlice(), .allocator = allocator } });
    
    return ScriptValue{ .object = result };
}

fn repairOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const format = args[1].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    if (std.mem.eql(u8, format, "json")) {
        const repaired = try repairJsonString(text, allocator);
        return ScriptValue{ .string = repaired };
    }
    
    return args[0]; // Return unchanged if repair not supported
}

fn cleanOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const options = args[1].object;
    const allocator = options.allocator;
    
    var cleaned = std.ArrayList(u8).init(allocator);
    
    // Apply cleaning options
    const trim_whitespace = if (options.get("trim_whitespace")) |t|
        try t.toZig(bool, allocator)
    else
        true;
        
    const remove_empty_lines = if (options.get("remove_empty_lines")) |r|
        try r.toZig(bool, allocator)
    else
        false;
    
    var lines = std.mem.split(u8, text, "\n");
    var first_line = true;
    
    while (lines.next()) |line| {
        var processed_line = line;
        
        if (trim_whitespace) {
            processed_line = std.mem.trim(u8, processed_line, " \t\r");
        }
        
        if (remove_empty_lines and processed_line.len == 0) {
            continue;
        }
        
        if (!first_line) try cleaned.append('\n');
        try cleaned.appendSlice(processed_line);
        first_line = false;
    }
    
    return ScriptValue{ .string = try cleaned.toOwnedSlice() };
}

fn applyTemplate(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const template = args[0].string;
    const data = args[1].object;
    const allocator = data.allocator;
    
    var result = std.ArrayList(u8).init(allocator);
    
    // Simple template substitution
    var pos: usize = 0;
    while (pos < template.len) {
        const var_start = std.mem.indexOfPos(u8, template, pos, "{{") orelse {
            try result.appendSlice(template[pos..]);
            break;
        };
        
        // Add text before variable
        try result.appendSlice(template[pos..var_start]);
        
        const var_end = std.mem.indexOfPos(u8, template, var_start + 2, "}}") orelse {
            try result.appendSlice(template[pos..]);
            break;
        };
        
        const var_name = std.mem.trim(u8, template[var_start + 2..var_end], " \t");
        
        // Substitute variable
        if (data.get(var_name)) |value| {
            switch (value) {
                .string => |s| try result.appendSlice(s),
                .integer => |n| try result.writer().print("{}", .{n}),
                .number => |n| try result.writer().print("{d}", .{n}),
                .boolean => |b| try result.appendSlice(if (b) "true" else "false"),
                else => try result.appendSlice("null"),
            }
        } else {
            try result.writer().print("{{{{{s}}}}}", .{var_name});
        }
        
        pos = var_end + 2;
    }
    
    return ScriptValue{ .string = try result.toOwnedSlice() };
}

fn splitOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }
    
    const text = args[0].string;
    const delimiter = args[1].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", text).allocator;
    
    var parts = std.ArrayList(ScriptValue).init(allocator);
    
    var iter = std.mem.split(u8, text, delimiter);
    while (iter.next()) |part| {
        try parts.append(ScriptValue{ .string = try allocator.dupe(u8, part) });
    }
    
    return ScriptValue{ .array = .{ .items = try parts.toOwnedSlice(), .allocator = allocator } };
}

fn mergeOutputs(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .array or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const outputs = args[0].array;
    const options = args[1].object;
    const allocator = options.allocator;
    
    const strategy = if (options.get("strategy")) |s|
        try s.toZig([]const u8, allocator)
    else
        "concatenate";
    
    if (std.mem.eql(u8, strategy, "concatenate")) {
        const separator = if (options.get("separator")) |sep|
            try sep.toZig([]const u8, allocator)
        else
            "\n";
            
        var merged = std.ArrayList(u8).init(allocator);
        
        for (outputs.items, 0..) |output, i| {
            if (i > 0) try merged.appendSlice(separator);
            switch (output) {
                .string => |s| try merged.appendSlice(s),
                else => {},
            }
        }
        
        return ScriptValue{ .string = try merged.toOwnedSlice() };
    } else if (std.mem.eql(u8, strategy, "merge_objects")) {
        var merged = ScriptValue.Object.init(allocator);
        
        for (outputs.items) |output| {
            if (output == .object) {
                var iter = output.object.map.iterator();
                while (iter.next()) |entry| {
                    try merged.put(entry.key_ptr.*, try entry.value_ptr.*.clone(allocator));
                }
            }
        }
        
        return ScriptValue{ .object = merged };
    }
    
    return args[0]; // Return array unchanged
}

fn formatOutput(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[1] != .object) {
        return error.InvalidArguments;
    }
    
    const data = args[0];
    const options = args[1].object;
    const allocator = options.allocator;
    
    const format_type = if (options.get("type")) |t|
        try t.toZig([]const u8, allocator)
    else
        "pretty";
    
    if (std.mem.eql(u8, format_type, "pretty")) {
        // Convert to pretty-printed JSON
        const json_value = try TypeMarshaler.marshalJsonValue(data, allocator);
        defer json_value.deinit();
        
        var string = std.ArrayList(u8).init(allocator);
        try std.json.stringify(json_value, .{ .whitespace = .{ .indent = .{ .Space = 2 } } }, string.writer());
        
        return ScriptValue{ .string = try string.toOwnedSlice() };
    } else if (std.mem.eql(u8, format_type, "compact")) {
        // Convert to compact JSON
        const json_value = try TypeMarshaler.marshalJsonValue(data, allocator);
        defer json_value.deinit();
        
        var string = std.ArrayList(u8).init(allocator);
        try std.json.stringify(json_value, .{}, string.writer());
        
        return ScriptValue{ .string = try string.toOwnedSlice() };
    }
    
    return data; // Return unchanged
}

// Helper functions

fn repairJsonString(text: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var repaired = std.ArrayList(u8).init(allocator);
    
    // Basic JSON repair strategies
    var in_string = false;
    var escape_next = false;
    var brace_count: i32 = 0;
    var bracket_count: i32 = 0;
    
    for (text) |char| {
        if (escape_next) {
            try repaired.append(char);
            escape_next = false;
            continue;
        }
        
        if (char == '\\' and in_string) {
            escape_next = true;
            try repaired.append(char);
            continue;
        }
        
        if (char == '"' and !escape_next) {
            in_string = !in_string;
        }
        
        if (!in_string) {
            switch (char) {
                '{' => brace_count += 1,
                '}' => brace_count -= 1,
                '[' => bracket_count += 1,
                ']' => bracket_count -= 1,
                else => {},
            }
        }
        
        try repaired.append(char);
    }
    
    // Add missing closing braces/brackets
    while (brace_count > 0) : (brace_count -= 1) {
        try repaired.append('}');
    }
    while (bracket_count > 0) : (bracket_count -= 1) {
        try repaired.append(']');
    }
    
    return repaired.toOwnedSlice();
}

fn convertToYaml(value: ScriptValue, yaml: *std.ArrayList(u8), indent: usize) !void {
    const spaces = "  ";
    
    switch (value) {
        .nil => try yaml.appendSlice("null"),
        .boolean => |b| try yaml.appendSlice(if (b) "true" else "false"),
        .integer => |n| try yaml.writer().print("{}", .{n}),
        .number => |n| try yaml.writer().print("{d}", .{n}),
        .string => |s| {
            if (std.mem.containsAtLeast(u8, s, 1, "\n")) {
                try yaml.appendSlice("|\n");
                var lines = std.mem.tokenize(u8, s, "\n");
                while (lines.next()) |line| {
                    try yaml.appendSlice(spaces[0..indent + 2]);
                    try yaml.appendSlice(line);
                    try yaml.append('\n');
                }
            } else {
                try yaml.appendSlice(s);
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                try yaml.append('\n');
                try yaml.appendSlice(spaces[0..indent]);
                try yaml.appendSlice("- ");
                try convertToYaml(item, yaml, indent + 2);
            }
        },
        .object => |obj| {
            var iter = obj.map.iterator();
            while (iter.next()) |entry| {
                try yaml.append('\n');
                try yaml.appendSlice(spaces[0..indent]);
                try yaml.appendSlice(entry.key_ptr.*);
                try yaml.appendSlice(": ");
                try convertToYaml(entry.value_ptr.*, yaml, indent + 2);
            }
        },
        else => try yaml.appendSlice("~"),
    }
}

fn validateValue(value: ScriptValue, expected: ScriptValue.Object, errors: *std.ArrayList(ScriptValue), allocator: std.mem.Allocator) !bool {
    if (expected.get("type")) |expected_type| {
        if (expected_type == .string) {
            const type_match = switch (value) {
                .nil => std.mem.eql(u8, expected_type.string, "null"),
                .boolean => std.mem.eql(u8, expected_type.string, "boolean"),
                .integer => std.mem.eql(u8, expected_type.string, "integer") or std.mem.eql(u8, expected_type.string, "number"),
                .number => std.mem.eql(u8, expected_type.string, "number"),
                .string => std.mem.eql(u8, expected_type.string, "string"),
                .array => std.mem.eql(u8, expected_type.string, "array"),
                .object => std.mem.eql(u8, expected_type.string, "object"),
                else => false,
            };
            
            if (!type_match) {
                var error_obj = ScriptValue.Object.init(allocator);
                try error_obj.put("message", ScriptValue{ .string = try allocator.dupe(u8, "Type mismatch") });
                try error_obj.put("expected", expected_type);
                try error_obj.put("actual", ScriptValue{ .string = try allocator.dupe(u8, @tagName(value)) });
                try errors.append(ScriptValue{ .object = error_obj });
                return false;
            }
        }
    }
    
    return true;
}

// Tests
test "OutputBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const module = try OutputBridge.getModule(allocator);
    defer allocator.destroy(module);
    
    try testing.expectEqualStrings("output", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}