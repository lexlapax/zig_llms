// ABOUTME: Output parser interface for extracting structured data from LLM responses
// ABOUTME: Provides unified parsing API with error recovery and format detection

const std = @import("std");
const schema = @import("../schema/validator.zig");

pub const ParseError = error{
    InvalidFormat,
    UnexpectedToken,
    UnterminatedString,
    InvalidEscape,
    InvalidNumber,
    MissingDelimiter,
    StructureMismatch,
    RecoveryFailed,
    SchemaValidationFailed,
};

pub const ParseOptions = struct {
    // Enable error recovery
    enable_recovery: bool = true,
    // Maximum recovery attempts
    max_recovery_attempts: u32 = 3,
    // Strict mode - fail on any deviation from expected format
    strict: bool = false,
    // Schema for validation
    validation_schema: ?schema.Schema = null,
    // Extract only specific fields
    extract_fields: ?[]const []const u8 = null,
    // Allow partial results
    allow_partial: bool = true,
    // Format hint for ambiguous content
    format_hint: ?Format = null,
    
    pub const Format = enum {
        json,
        yaml,
        xml,
        markdown_codeblock,
        plain_text,
    };
};

pub const ParseResult = struct {
    value: std.json.Value,
    format: ParseOptions.Format,
    success: bool,
    errors: []const ParseError = &[_]ParseError{},
    warnings: []const []const u8 = &[_][]const u8{},
    recovery_applied: bool = false,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ParseResult) void {
        // Clean up allocated memory
        if (self.errors.len > 0) {
            self.allocator.free(self.errors);
        }
        for (self.warnings) |warning| {
            self.allocator.free(warning);
        }
        if (self.warnings.len > 0) {
            self.allocator.free(self.warnings);
        }
    }
};

pub const Parser = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        parse: *const fn (parser: *Parser, input: []const u8, options: ParseOptions, allocator: std.mem.Allocator) ParseError!ParseResult,
        canParse: *const fn (parser: *Parser, input: []const u8) bool,
        getFormat: *const fn (parser: *Parser) ParseOptions.Format,
        getName: *const fn (parser: *Parser) []const u8,
        deinit: *const fn (parser: *Parser) void,
    };
    
    pub fn parse(self: *Parser, input: []const u8, options: ParseOptions, allocator: std.mem.Allocator) ParseError!ParseResult {
        return self.vtable.parse(self, input, options, allocator);
    }
    
    pub fn canParse(self: *Parser, input: []const u8) bool {
        return self.vtable.canParse(self, input);
    }
    
    pub fn getFormat(self: *Parser) ParseOptions.Format {
        return self.vtable.getFormat(self);
    }
    
    pub fn getName(self: *Parser) []const u8 {
        return self.vtable.getName(self);
    }
    
    pub fn deinit(self: *Parser) void {
        self.vtable.deinit(self);
    }
};

// Common parsing utilities
pub const utils = struct {
    // Extract content from markdown code blocks
    pub fn extractCodeBlock(input: []const u8, language: ?[]const u8) ?[]const u8 {
        var start_marker = "```";
        if (language) |lang| {
            var buf: [256]u8 = undefined;
            start_marker = std.fmt.bufPrint(&buf, "```{s}", .{lang}) catch return null;
        }
        
        const start = std.mem.indexOf(u8, input, start_marker) orelse return null;
        const content_start = std.mem.indexOf(u8, input[start..], "\n") orelse return null;
        const end = std.mem.indexOf(u8, input[start + content_start + 1..], "```") orelse return null;
        
        return input[start + content_start + 1..][0..end];
    }
    
    // Find JSON-like content in text
    pub fn findJsonContent(input: []const u8) ?[]const u8 {
        // Look for JSON object or array boundaries
        var depth: i32 = 0;
        var start: ?usize = null;
        var in_string = false;
        var escape = false;
        
        for (input, 0..) |char, i| {
            if (escape) {
                escape = false;
                continue;
            }
            
            if (char == '\\' and in_string) {
                escape = true;
                continue;
            }
            
            if (char == '"' and !in_string) {
                in_string = true;
            } else if (char == '"' and in_string) {
                in_string = false;
            }
            
            if (!in_string) {
                switch (char) {
                    '{', '[' => {
                        if (start == null) start = i;
                        depth += 1;
                    },
                    '}', ']' => {
                        depth -= 1;
                        if (depth == 0 and start != null) {
                            return input[start.?..i + 1];
                        }
                    },
                    else => {},
                }
            }
        }
        
        return null;
    }
    
    // Detect likely format from content
    pub fn detectFormat(input: []const u8) ParseOptions.Format {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        
        // Check for markdown code blocks
        if (std.mem.indexOf(u8, trimmed, "```") != null) {
            return .markdown_codeblock;
        }
        
        // Check for JSON
        if ((std.mem.startsWith(u8, trimmed, "{") and std.mem.endsWith(u8, trimmed, "}")) or
            (std.mem.startsWith(u8, trimmed, "[") and std.mem.endsWith(u8, trimmed, "]"))) {
            return .json;
        }
        
        // Check for XML
        if (std.mem.startsWith(u8, trimmed, "<") and std.mem.endsWith(u8, trimmed, ">")) {
            return .xml;
        }
        
        // Check for YAML
        if (std.mem.indexOf(u8, trimmed, ":") != null and 
            (std.mem.indexOf(u8, trimmed, "\n") != null or trimmed.len < 100)) {
            // Simple heuristic: has colons and newlines or is short
            return .yaml;
        }
        
        return .plain_text;
    }
    
    // Clean common LLM response artifacts
    pub fn cleanLlmResponse(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        // Remove common prefixes/suffixes
        var content = input;
        
        // Remove "Here is..." or similar prefixes
        const prefixes = [_][]const u8{
            "Here is the JSON:",
            "Here's the JSON:",
            "JSON:",
            "```json",
            "```",
        };
        
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, content, prefix)) {
                content = content[prefix.len..];
                break;
            }
        }
        
        // Remove trailing markers
        const suffixes = [_][]const u8{
            "```",
        };
        
        for (suffixes) |suffix| {
            if (std.mem.endsWith(u8, content, suffix)) {
                content = content[0..content.len - suffix.len];
                break;
            }
        }
        
        // Trim whitespace
        content = std.mem.trim(u8, content, " \t\r\n");
        
        try result.appendSlice(content);
        return result.toOwnedSlice();
    }
    
    // Extract specific fields using JSON path
    pub fn extractFields(
        allocator: std.mem.Allocator,
        value: std.json.Value,
        fields: []const []const u8,
    ) !std.json.Value {
        var result = std.json.ObjectMap.init(allocator);
        errdefer result.deinit();
        
        for (fields) |field_path| {
            if (getValueByPath(value, field_path)) |field_value| {
                // Get the last segment of the path as the key
                var iter = std.mem.tokenize(u8, field_path, ".");
                var last_segment: []const u8 = field_path;
                while (iter.next()) |segment| {
                    last_segment = segment;
                }
                
                try result.put(last_segment, field_value);
            }
        }
        
        return std.json.Value{ .object = result };
    }
    
    fn getValueByPath(value: std.json.Value, path: []const u8) ?std.json.Value {
        var current = value;
        var iter = std.mem.tokenize(u8, path, ".");
        
        while (iter.next()) |segment| {
            switch (current) {
                .object => |obj| {
                    if (obj.get(segment)) |next| {
                        current = next;
                    } else {
                        return null;
                    }
                },
                .array => |arr| {
                    const index = std.fmt.parseInt(usize, segment, 10) catch return null;
                    if (index >= arr.items.len) return null;
                    current = arr.items[index];
                },
                else => return null,
            }
        }
        
        return current;
    }
};

// Parser registry for managing multiple parsers
pub const ParserRegistry = struct {
    allocator: std.mem.Allocator,
    parsers: std.ArrayList(*Parser),
    
    pub fn init(allocator: std.mem.Allocator) ParserRegistry {
        return .{
            .allocator = allocator,
            .parsers = std.ArrayList(*Parser).init(allocator),
        };
    }
    
    pub fn deinit(self: *ParserRegistry) void {
        for (self.parsers.items) |parser| {
            parser.deinit();
        }
        self.parsers.deinit();
    }
    
    pub fn register(self: *ParserRegistry, parser: *Parser) !void {
        try self.parsers.append(parser);
    }
    
    pub fn findParser(self: *ParserRegistry, input: []const u8, format_hint: ?ParseOptions.Format) ?*Parser {
        // If format hint provided, try to find matching parser
        if (format_hint) |format| {
            for (self.parsers.items) |parser| {
                if (parser.getFormat() == format) {
                    return parser;
                }
            }
        }
        
        // Otherwise, find first parser that can handle the input
        for (self.parsers.items) |parser| {
            if (parser.canParse(input)) {
                return parser;
            }
        }
        
        return null;
    }
    
    pub fn parse(
        self: *ParserRegistry,
        input: []const u8,
        options: ParseOptions,
    ) ParseError!ParseResult {
        const parser = self.findParser(input, options.format_hint) orelse
            return ParseError.InvalidFormat;
        
        return parser.parse(input, options, self.allocator);
    }
};

// Tests
test "extract code block" {
    const input =
        \\Some text before
        \\```json
        \\{"key": "value"}
        \\```
        \\Some text after
    ;
    
    const content = utils.extractCodeBlock(input, "json");
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("{\"key\": \"value\"}", content.?);
}

test "find JSON content" {
    const input = "Here is the response: {\"status\": \"ok\", \"count\": 42} - that's all!";
    
    const json_content = utils.findJsonContent(input);
    try std.testing.expect(json_content != null);
    try std.testing.expectEqualStrings("{\"status\": \"ok\", \"count\": 42}", json_content.?);
}

test "detect format" {
    try std.testing.expectEqual(ParseOptions.Format.json, utils.detectFormat("{\"key\": \"value\"}"));
    try std.testing.expectEqual(ParseOptions.Format.json, utils.detectFormat("  [1, 2, 3]  "));
    try std.testing.expectEqual(ParseOptions.Format.markdown_codeblock, utils.detectFormat("```json\n{}\n```"));
    try std.testing.expectEqual(ParseOptions.Format.xml, utils.detectFormat("<root><child/></root>"));
    try std.testing.expectEqual(ParseOptions.Format.yaml, utils.detectFormat("key: value\nother: 123"));
    try std.testing.expectEqual(ParseOptions.Format.plain_text, utils.detectFormat("Just some plain text"));
}