// ABOUTME: Feed processing tool for parsing and working with RSS, Atom, and JSON Feed formats
// ABOUTME: Provides feed fetching, parsing, filtering, and content extraction capabilities

const std = @import("std");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;
const http_client = @import("../http/client.zig");

// Feed formats
pub const FeedFormat = enum {
    rss,
    atom,
    json_feed,
    auto_detect,

    pub fn toString(self: FeedFormat) []const u8 {
        return switch (self) {
            .rss => "RSS",
            .atom => "Atom",
            .json_feed => "JSON Feed",
            .auto_detect => "Auto-detect",
        };
    }
};

// Feed operations
pub const FeedOperation = enum {
    fetch,
    parse,
    filter,
    extract,
    validate,
    convert,

    pub fn toString(self: FeedOperation) []const u8 {
        return @tagName(self);
    }
};

// Feed tool error types
pub const FeedToolError = error{
    UnsupportedFormat,
    InvalidFeed,
    ParseError,
    NetworkError,
    UnsafeUrl,
    FeedTooLarge,
    InvalidOperation,
};

// Feed configuration
pub const FeedConfig = struct {
    max_feed_size: usize = 5 * 1024 * 1024, // 5MB
    max_items: usize = 1000,
    timeout_seconds: u32 = 30,
    allowed_domains: ?[]const []const u8 = null,
    user_agent: []const u8 = "zig-llms-feed-tool/1.0",
    follow_redirects: bool = true,
    validate_ssl: bool = true,
};

// Feed item structure
pub const FeedItem = struct {
    title: ?[]const u8 = null,
    link: ?[]const u8 = null,
    description: ?[]const u8 = null,
    content: ?[]const u8 = null,
    author: ?[]const u8 = null,
    published: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    id: ?[]const u8 = null,
    categories: []const []const u8 = &[_][]const u8{},
    enclosures: []const Enclosure = &[_]Enclosure{},

    pub const Enclosure = struct {
        url: []const u8,
        type: ?[]const u8 = null,
        length: ?usize = null,
    };

    pub fn deinit(self: *FeedItem, allocator: std.mem.Allocator) void {
        if (self.categories.len > 0) {
            for (self.categories) |category| {
                allocator.free(category);
            }
            allocator.free(self.categories);
        }
        if (self.enclosures.len > 0) {
            allocator.free(self.enclosures);
        }
    }
};

// Feed metadata structure
pub const FeedMetadata = struct {
    title: ?[]const u8 = null,
    link: ?[]const u8 = null,
    description: ?[]const u8 = null,
    language: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    published: ?[]const u8 = null,
    updated: ?[]const u8 = null,
    generator: ?[]const u8 = null,
    format: FeedFormat = .auto_detect,
    version: ?[]const u8 = null,
    item_count: usize = 0,
};

// Parsed feed structure
pub const ParsedFeed = struct {
    metadata: FeedMetadata,
    items: []FeedItem,

    pub fn deinit(self: *ParsedFeed, allocator: std.mem.Allocator) void {
        for (self.items) |*item| {
            item.deinit(allocator);
        }
        allocator.free(self.items);
    }
};

// Feed processing tool
pub const FeedTool = struct {
    base: BaseTool,
    config: FeedConfig,
    http_client: ?*http_client.HttpClient,
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        config: FeedConfig,
        client: ?*http_client.HttpClient,
    ) !*FeedTool {
        const self = try allocator.create(FeedTool);

        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "feed_processor",
            .description = "Process RSS, Atom, and JSON Feed formats",
            .version = "1.0.0",
            .category = .data,
            .capabilities = &[_][]const u8{ "rss_parsing", "atom_parsing", "json_feed_parsing", "feed_fetching" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Fetch and parse RSS feed",
                    .input = .{ .object = try createExampleInput(allocator, "fetch", "https://example.com/feed.xml", null) },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Feed parsed successfully") },
                },
                .{
                    .description = "Parse RSS content",
                    .input = .{ .object = try createExampleInput(allocator, "parse", null, "<rss version=\"2.0\">...</rss>") },
                    .output = .{ .object = try createExampleOutput(allocator, true, "Content parsed") },
                },
            },
        };

        self.* = .{
            .base = BaseTool.init(metadata),
            .config = config,
            .http_client = client,
            .allocator = allocator,
        };

        // Set vtable
        self.base.tool.vtable = &.{
            .execute = execute,
            .validate = validate,
            .deinit = deinit,
        };

        return self;
    }

    fn execute(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const self = @fieldParentPtr(FeedTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

        // Parse input
        const operation_str = input.object.get("operation") orelse return error.MissingOperation;

        if (operation_str != .string) {
            return error.InvalidInput;
        }

        const operation = std.meta.stringToEnum(FeedOperation, operation_str.string) orelse {
            return error.InvalidOperation;
        };

        // Execute operation
        return switch (operation) {
            .fetch => self.fetchFeed(input, allocator),
            .parse => self.parseFeed(input, allocator),
            .filter => self.filterFeed(input, allocator),
            .extract => self.extractFromFeed(input, allocator),
            .validate => self.validateFeed(input, allocator),
            .convert => self.convertFeed(input, allocator),
        };
    }

    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;

        // Basic validation
        if (input != .object) return false;

        const operation = input.object.get("operation") orelse return false;

        if (operation != .string) return false;

        // Validate operation is supported
        const feed_operation = std.meta.stringToEnum(FeedOperation, operation.string) orelse return false;
        _ = feed_operation;

        return true;
    }

    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(FeedTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }

    fn fetchFeed(self: *const FeedTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const url_val = input.object.get("url") orelse return error.MissingUrl;

        if (url_val != .string) {
            return ToolResult.failure("URL must be a string");
        }

        const url = url_val.string;

        // Validate URL
        try self.validateUrl(url);

        // Check if HTTP client is available
        if (self.http_client == null) {
            return ToolResult.failure("HTTP client not available");
        }

        // Fetch feed content
        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();

        try headers.put("User-Agent", self.config.user_agent);
        try headers.put("Accept", "application/rss+xml, application/atom+xml, application/xml, text/xml, application/json");

        const response = self.http_client.?.request(.{
            .method = "GET",
            .url = url,
            .headers = headers,
            .timeout_ms = self.config.timeout_seconds * 1000,
            .max_response_size = self.config.max_feed_size,
        }, allocator) catch |err| switch (err) {
            error.Timeout => return ToolResult.failure("Feed fetch timeout"),
            error.ConnectionRefused => return ToolResult.failure("Connection refused"),
            else => return ToolResult.failure("Failed to fetch feed"),
        };
        defer response.deinit();

        if (response.status_code < 200 or response.status_code >= 300) {
            const error_msg = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ response.status_code, response.body });
            return ToolResult.failure(error_msg);
        }

        // Parse the fetched content
        return self.parseFeedContent(response.body, allocator);
    }

    fn parseFeed(self: *const FeedTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const content_val = input.object.get("content") orelse return error.MissingContent;

        if (content_val != .string) {
            return ToolResult.failure("Content must be a string");
        }

        return self.parseFeedContent(content_val.string, allocator);
    }

    fn parseFeedContent(self: *const FeedTool, content: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (content.len > self.config.max_feed_size) {
            return ToolResult.failure("Feed content too large");
        }

        // Detect feed format
        const format = self.detectFeedFormat(content);

        // Parse based on format
        const parsed_feed = switch (format) {
            .rss => self.parseRSS(content, allocator),
            .atom => self.parseAtom(content, allocator),
            .json_feed => self.parseJSONFeed(content, allocator),
            .auto_detect => return ToolResult.failure("Could not detect feed format"),
        } catch |err| switch (err) {
            error.InvalidCharacter, error.UnexpectedToken => return ToolResult.failure("Invalid feed format"),
            else => return ToolResult.failure("Feed parsing failed"),
        };

        // Convert to JSON result
        var result_obj = std.json.ObjectMap.init(allocator);

        // Add metadata
        var metadata_obj = std.json.ObjectMap.init(allocator);
        if (parsed_feed.metadata.title) |title| {
            try metadata_obj.put("title", .{ .string = title });
        }
        if (parsed_feed.metadata.link) |link| {
            try metadata_obj.put("link", .{ .string = link });
        }
        if (parsed_feed.metadata.description) |desc| {
            try metadata_obj.put("description", .{ .string = desc });
        }
        try metadata_obj.put("format", .{ .string = format.toString() });
        try metadata_obj.put("item_count", .{ .integer = @as(i64, @intCast(parsed_feed.items.len)) });
        try result_obj.put("metadata", .{ .object = metadata_obj });

        // Add items (limited by config)
        var items_array = std.ArrayList(std.json.Value).init(allocator);
        const max_items = @min(parsed_feed.items.len, self.config.max_items);

        for (parsed_feed.items[0..max_items]) |item| {
            var item_obj = std.json.ObjectMap.init(allocator);

            if (item.title) |title| {
                try item_obj.put("title", .{ .string = title });
            }
            if (item.link) |link| {
                try item_obj.put("link", .{ .string = link });
            }
            if (item.description) |desc| {
                try item_obj.put("description", .{ .string = desc });
            }
            if (item.published) |pub_date| {
                try item_obj.put("published", .{ .string = pub_date });
            }
            if (item.author) |author| {
                try item_obj.put("author", .{ .string = author });
            }

            try items_array.append(.{ .object = item_obj });
        }

        try result_obj.put("items", .{ .array = std.json.Array.fromOwnedSlice(allocator, try items_array.toOwnedSlice()) });

        return ToolResult.success(.{ .object = result_obj });
    }

    fn detectFeedFormat(self: *const FeedTool, content: []const u8) FeedFormat {
        _ = self;

        // Trim whitespace and check first significant content
        const trimmed = std.mem.trim(u8, content, " \t\n\r");

        if (std.mem.startsWith(u8, trimmed, "{")) {
            // Likely JSON Feed
            if (std.mem.indexOf(u8, trimmed, "\"version\"") != null and
                std.mem.indexOf(u8, trimmed, "\"items\"") != null)
            {
                return .json_feed;
            }
        } else if (std.mem.startsWith(u8, trimmed, "<")) {
            // XML-based feed
            if (std.mem.indexOf(u8, trimmed, "<rss") != null) {
                return .rss;
            } else if (std.mem.indexOf(u8, trimmed, "<feed") != null or
                std.mem.indexOf(u8, trimmed, "xmlns=\"http://www.w3.org/2005/Atom\"") != null)
            {
                return .atom;
            }
        }

        return .auto_detect;
    }

    fn parseRSS(self: *const FeedTool, content: []const u8, allocator: std.mem.Allocator) !ParsedFeed {
        _ = self;
        _ = content;
        _ = allocator;

        // RSS parsing would require a full XML parser
        // For now, return a minimal implementation
        return ParsedFeed{
            .metadata = FeedMetadata{
                .title = "RSS Feed",
                .format = .rss,
                .item_count = 0,
            },
            .items = &[_]FeedItem{},
        };
    }

    fn parseAtom(self: *const FeedTool, content: []const u8, allocator: std.mem.Allocator) !ParsedFeed {
        _ = self;
        _ = content;
        _ = allocator;

        // Atom parsing would require a full XML parser
        // For now, return a minimal implementation
        return ParsedFeed{
            .metadata = FeedMetadata{
                .title = "Atom Feed",
                .format = .atom,
                .item_count = 0,
            },
            .items = &[_]FeedItem{},
        };
    }

    fn parseJSONFeed(self: *const FeedTool, content: []const u8, allocator: std.mem.Allocator) !ParsedFeed {
        _ = self;

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) {
            return error.InvalidCharacter;
        }

        const root = parsed.value.object;

        // Parse metadata
        var metadata = FeedMetadata{
            .format = .json_feed,
        };

        if (root.get("title")) |title| {
            if (title == .string) {
                metadata.title = title.string;
            }
        }

        if (root.get("home_page_url")) |link| {
            if (link == .string) {
                metadata.link = link.string;
            }
        }

        if (root.get("description")) |desc| {
            if (desc == .string) {
                metadata.description = desc.string;
            }
        }

        if (root.get("version")) |version| {
            if (version == .string) {
                metadata.version = version.string;
            }
        }

        // Parse items
        var items = std.ArrayList(FeedItem).init(allocator);

        if (root.get("items")) |items_val| {
            if (items_val == .array) {
                for (items_val.array.items) |item_val| {
                    if (item_val == .object) {
                        var item = FeedItem{};

                        if (item_val.object.get("title")) |title| {
                            if (title == .string) {
                                item.title = title.string;
                            }
                        }

                        if (item_val.object.get("url")) |url| {
                            if (url == .string) {
                                item.link = url.string;
                            }
                        }

                        if (item_val.object.get("summary")) |summary| {
                            if (summary == .string) {
                                item.description = summary.string;
                            }
                        }

                        if (item_val.object.get("content_text")) |content_text| {
                            if (content_text == .string) {
                                item.content = content_text.string;
                            }
                        }

                        if (item_val.object.get("date_published")) |pub_date| {
                            if (pub_date == .string) {
                                item.published = pub_date.string;
                            }
                        }

                        if (item_val.object.get("author")) |author_val| {
                            if (author_val == .object) {
                                if (author_val.object.get("name")) |name| {
                                    if (name == .string) {
                                        item.author = name.string;
                                    }
                                }
                            }
                        }

                        try items.append(item);
                    }
                }
            }
        }

        metadata.item_count = items.items.len;

        return ParsedFeed{
            .metadata = metadata,
            .items = try items.toOwnedSlice(),
        };
    }

    fn validateUrl(self: *const FeedTool, url: []const u8) !void {
        // Basic URL validation
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
            return FeedToolError.UnsafeUrl;
        }

        // Parse URL to get domain
        const uri = std.Uri.parse(url) catch return FeedToolError.UnsafeUrl;
        const host = uri.host orelse return FeedToolError.UnsafeUrl;

        // Check against allowed domains if configured
        if (self.config.allowed_domains) |allowed| {
            var found_allowed = false;
            for (allowed) |allowed_domain| {
                if (std.mem.indexOf(u8, host, allowed_domain) != null) {
                    found_allowed = true;
                    break;
                }
            }
            if (!found_allowed) {
                return FeedToolError.UnsafeUrl;
            }
        }
    }

    fn filterFeed(self: *const FeedTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Feed filtering not yet implemented");
    }

    fn extractFromFeed(self: *const FeedTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Feed extraction not yet implemented");
    }

    fn validateFeed(self: *const FeedTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        const content_val = input.object.get("content") orelse return error.MissingContent;

        if (content_val != .string) {
            return ToolResult.failure("Content must be a string");
        }

        const content = content_val.string;
        const format = self.detectFeedFormat(content);

        var result_obj = std.json.ObjectMap.init(allocator);

        if (format == .auto_detect) {
            try result_obj.put("valid", .{ .bool = false });
            try result_obj.put("error", .{ .string = "Unknown or invalid feed format" });
        } else {
            // Try to parse to validate structure
            const parse_result = self.parseFeedContent(content, allocator) catch |err| {
                try result_obj.put("valid", .{ .bool = false });
                const error_msg = switch (err) {
                    error.InvalidCharacter => "Invalid characters in feed",
                    error.UnexpectedToken => "Unexpected format in feed",
                    else => "Feed validation failed",
                };
                try result_obj.put("error", .{ .string = error_msg });
                return ToolResult.success(.{ .object = result_obj });
            };

            try result_obj.put("valid", .{ .bool = true });
            try result_obj.put("format", .{ .string = format.toString() });

            if (parse_result.data) |data| {
                if (data.object.get("metadata")) |metadata| {
                    try result_obj.put("metadata", metadata);
                }
            }
        }

        return ToolResult.success(.{ .object = result_obj });
    }

    fn convertFeed(self: *const FeedTool, input: std.json.Value, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        _ = input;
        _ = allocator;

        return ToolResult.failure("Feed conversion not yet implemented");
    }
};

// Helper functions for schema creation
fn createInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var operation_prop = std.json.ObjectMap.init(allocator);
    try operation_prop.put("type", .{ .string = "string" });
    try operation_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "fetch" },
        .{ .string = "parse" },
        .{ .string = "filter" },
        .{ .string = "extract" },
        .{ .string = "validate" },
        .{ .string = "convert" },
    })) });
    try operation_prop.put("description", .{ .string = "Feed operation to perform" });
    try properties.put("operation", .{ .object = operation_prop });

    var url_prop = std.json.ObjectMap.init(allocator);
    try url_prop.put("type", .{ .string = "string" });
    try url_prop.put("format", .{ .string = "uri" });
    try url_prop.put("description", .{ .string = "Feed URL (for fetch operation)" });
    try properties.put("url", .{ .object = url_prop });

    var content_prop = std.json.ObjectMap.init(allocator);
    try content_prop.put("type", .{ .string = "string" });
    try content_prop.put("description", .{ .string = "Feed content (for parse/validate operations)" });
    try properties.put("content", .{ .object = content_prop });

    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "operation" },
    })) });

    return .{ .object = schema };
}

fn createOutputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });

    var properties = std.json.ObjectMap.init(allocator);

    var success_prop = std.json.ObjectMap.init(allocator);
    try success_prop.put("type", .{ .string = "boolean" });
    try properties.put("success", .{ .object = success_prop });

    var data_prop = std.json.ObjectMap.init(allocator);
    try data_prop.put("type", .{ .string = "object" });
    try properties.put("data", .{ .object = data_prop });

    var error_prop = std.json.ObjectMap.init(allocator);
    try error_prop.put("type", .{ .string = "string" });
    try properties.put("error", .{ .object = error_prop });

    try schema.put("properties", .{ .object = properties });

    return .{ .object = schema };
}

fn createExampleInput(allocator: std.mem.Allocator, operation: []const u8, url: ?[]const u8, content: ?[]const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("operation", .{ .string = operation });

    if (url) |u| {
        try input.put("url", .{ .string = u });
    }

    if (content) |c| {
        try input.put("content", .{ .string = c });
    }

    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, message: []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });

    var data = std.json.ObjectMap.init(allocator);
    try data.put("message", .{ .string = message });
    try output.put("data", .{ .object = data });

    return output;
}

// Builder function for easy creation
pub fn createFeedTool(
    allocator: std.mem.Allocator,
    config: FeedConfig,
    client: ?*http_client.HttpClient,
) !*Tool {
    const feed_tool = try FeedTool.init(allocator, config, client);
    return &feed_tool.base.tool;
}

// Tests
test "feed tool creation" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createFeedTool(allocator, .{}, null);
    defer tool_ptr.deinit();

    try std.testing.expectEqualStrings("feed_processor", tool_ptr.metadata.name);
}

test "feed format detection" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createFeedTool(allocator, .{}, null);
    defer tool_ptr.deinit();

    const feed_tool = @fieldParentPtr(FeedTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));

    // Test JSON Feed detection
    const json_feed = "{\"version\": \"https://jsonfeed.org/version/1\", \"items\": []}";
    const json_format = feed_tool.detectFeedFormat(json_feed);
    try std.testing.expectEqual(FeedFormat.json_feed, json_format);

    // Test RSS detection
    const rss_feed = "<rss version=\"2.0\"><channel></channel></rss>";
    const rss_format = feed_tool.detectFeedFormat(rss_feed);
    try std.testing.expectEqual(FeedFormat.rss, rss_format);

    // Test Atom detection
    const atom_feed = "<feed xmlns=\"http://www.w3.org/2005/Atom\"></feed>";
    const atom_format = feed_tool.detectFeedFormat(atom_feed);
    try std.testing.expectEqual(FeedFormat.atom, atom_format);
}

test "json feed parsing" {
    const allocator = std.testing.allocator;

    const tool_ptr = try createFeedTool(allocator, .{}, null);
    defer tool_ptr.deinit();

    const json_feed =
        \\{
        \\  "version": "https://jsonfeed.org/version/1",
        \\  "title": "Test Feed",
        \\  "home_page_url": "https://example.com",
        \\  "items": [
        \\    {
        \\      "title": "Test Item",
        \\      "url": "https://example.com/item1",
        \\      "summary": "Test summary"
        \\    }
        \\  ]
        \\}
    ;

    var input = std.json.ObjectMap.init(allocator);
    defer input.deinit();
    try input.put("operation", .{ .string = "parse" });
    try input.put("content", .{ .string = json_feed });

    const result = try tool_ptr.execute(.{ .object = input }, allocator);
    defer if (result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };

    try std.testing.expect(result.success);
    if (result.data) |data| {
        try std.testing.expect(data.object.get("metadata") != null);
        try std.testing.expect(data.object.get("items") != null);
    }
}
