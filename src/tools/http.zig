// ABOUTME: HTTP request tool for making web requests and API calls
// ABOUTME: Provides comprehensive HTTP operations with safety checks, timeouts, and response handling

const std = @import("std");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;
const http_client = @import("../http/client.zig");

// HTTP methods
pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,
    
    pub fn toString(self: HttpMethod) []const u8 {
        return @tagName(self);
    }
};

// HTTP tool error types
pub const HttpToolError = error{
    InvalidUrl,
    UnsupportedMethod,
    RequestTimeout,
    ConnectionFailed,
    InvalidResponse,
    UnsafeUrl,
    RateLimited,
    TooManyRedirects,
};

// Safety configuration for HTTP requests
pub const HttpSafetyConfig = struct {
    allowed_domains: ?[]const []const u8 = null,
    blocked_domains: []const []const u8 = &[_][]const u8{},
    allow_private_ips: bool = false,
    allow_redirects: bool = true,
    max_redirects: u32 = 5,
    timeout_ms: u32 = 30000, // 30 seconds
    max_response_size: usize = 10 * 1024 * 1024, // 10MB
    allowed_schemes: []const []const u8 = &[_][]const u8{ "http", "https" },
    user_agent: []const u8 = "zig-llms-http-tool/1.0",
};

// HTTP response structure
pub const HttpResponse = struct {
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    content_type: ?[]const u8,
    content_length: ?usize,
    elapsed_ms: u64,
    
    pub fn init(allocator: std.mem.Allocator) HttpResponse {
        return .{
            .status_code = 0,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = "",
            .content_type = null,
            .content_length = null,
            .elapsed_ms = 0,
        };
    }
    
    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }
};

// HTTP tool implementation
pub const HttpTool = struct {
    base: BaseTool,
    safety_config: HttpSafetyConfig,
    client: *http_client.HttpClient,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        safety_config: HttpSafetyConfig,
        client: *http_client.HttpClient,
    ) !*HttpTool {
        const self = try allocator.create(HttpTool);
        
        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "http_request",
            .description = "Make HTTP requests to web APIs and endpoints",
            .version = "1.0.0",
            .category = .network,
            .capabilities = &[_][]const u8{ "http_get", "http_post", "rest_api" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "GET request to API",
                    .input = .{ .object = try createExampleInput(allocator, "GET", "https://api.example.com/data", null, null) },
                    .output = .{ .object = try createExampleOutput(allocator, true, 200, "API response data") },
                },
                .{
                    .description = "POST request with JSON",
                    .input = .{ .object = try createExampleInput(allocator, "POST", "https://api.example.com/users", "{\"name\": \"John\"}", "application/json") },
                    .output = .{ .object = try createExampleOutput(allocator, true, 201, "User created") },
                },
            },
        };
        
        self.* = .{
            .base = BaseTool.init(metadata),
            .safety_config = safety_config,
            .client = client,
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
        const self = @fieldParentPtr(HttpTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        
        // Parse input
        const method_str = input.object.get("method") orelse return error.MissingMethod;
        const url_val = input.object.get("url") orelse return error.MissingUrl;
        
        if (method_str != .string or url_val != .string) {
            return error.InvalidInput;
        }
        
        const method = std.meta.stringToEnum(HttpMethod, method_str.string) orelse {
            return error.UnsupportedMethod;
        };
        
        const url = url_val.string;
        
        // Validate URL safety
        try self.validateUrl(url);
        
        // Parse optional parameters
        const body = if (input.object.get("body")) |b| b.string else null;
        const headers = try self.parseHeaders(input.object.get("headers"), allocator);
        defer if (headers) |h| h.deinit();
        
        const timeout = if (input.object.get("timeout")) |t| 
            @as(u32, @intCast(t.integer))
        else 
            self.safety_config.timeout_ms;
        
        // Make the HTTP request
        return self.makeRequest(method, url, body, headers, timeout, allocator);
    }
    
    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;
        
        // Basic validation
        if (input != .object) return false;
        
        const method = input.object.get("method") orelse return false;
        const url = input.object.get("url") orelse return false;
        
        if (method != .string or url != .string) return false;
        
        // Validate method is supported
        const http_method = std.meta.stringToEnum(HttpMethod, method.string) orelse return false;
        _ = http_method;
        
        // Basic URL validation
        if (url.string.len == 0) return false;
        if (!std.mem.startsWith(u8, url.string, "http://") and !std.mem.startsWith(u8, url.string, "https://")) {
            return false;
        }
        
        // Validate optional fields
        if (input.object.get("timeout")) |t| {
            if (t != .integer or t.integer < 0) return false;
        }
        
        if (input.object.get("headers")) |h| {
            if (h != .object) return false;
        }
        
        return true;
    }
    
    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(HttpTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }
    
    fn validateUrl(self: *const HttpTool, url: []const u8) !void {
        // Basic scheme validation
        var found_scheme = false;
        for (self.safety_config.allowed_schemes) |scheme| {
            const scheme_prefix = try std.fmt.allocPrint(self.allocator, "{s}://", .{scheme});
            defer self.allocator.free(scheme_prefix);
            
            if (std.mem.startsWith(u8, url, scheme_prefix)) {
                found_scheme = true;
                break;
            }
        }
        
        if (!found_scheme) {
            return HttpToolError.UnsafeUrl;
        }
        
        // Parse URL to get domain
        const uri = std.Uri.parse(url) catch return HttpToolError.InvalidUrl;
        const host = uri.host orelse return HttpToolError.InvalidUrl;
        
        // Check against blocked domains
        for (self.safety_config.blocked_domains) |blocked| {
            if (std.mem.indexOf(u8, host, blocked) != null) {
                return HttpToolError.UnsafeUrl;
            }
        }
        
        // Check against allowed domains
        if (self.safety_config.allowed_domains) |allowed| {
            var found_allowed = false;
            for (allowed) |allowed_domain| {
                if (std.mem.indexOf(u8, host, allowed_domain) != null) {
                    found_allowed = true;
                    break;
                }
            }
            if (!found_allowed) {
                return HttpToolError.UnsafeUrl;
            }
        }
        
        // Check for private IP addresses if not allowed
        if (!self.safety_config.allow_private_ips) {
            if (self.isPrivateIp(host)) {
                return HttpToolError.UnsafeUrl;
            }
        }
    }
    
    fn isPrivateIp(self: *const HttpTool, host: []const u8) bool {
        _ = self;
        
        // Simple check for common private IP ranges
        // This is a basic implementation - could be more comprehensive
        if (std.mem.startsWith(u8, host, "127.") or
            std.mem.startsWith(u8, host, "10.") or
            std.mem.startsWith(u8, host, "192.168.") or
            std.mem.startsWith(u8, host, "172.") or
            std.mem.eql(u8, host, "localhost"))
        {
            return true;
        }
        
        return false;
    }
    
    fn parseHeaders(self: *const HttpTool, headers_val: ?std.json.Value, allocator: std.mem.Allocator) !?std.StringHashMap([]const u8) {
        _ = self;
        
        if (headers_val) |headers| {
            if (headers != .object) return null;
            
            var result = std.StringHashMap([]const u8).init(allocator);
            var iter = headers.object.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == .string) {
                    try result.put(entry.key_ptr.*, entry.value_ptr.*.string);
                }
            }
            return result;
        }
        
        return null;
    }
    
    fn makeRequest(
        self: *const HttpTool,
        method: HttpMethod,
        url: []const u8,
        body: ?[]const u8,
        headers: ?std.StringHashMap([]const u8),
        timeout: u32,
        allocator: std.mem.Allocator,
    ) !ToolResult {
        const start_time = std.time.milliTimestamp();
        
        // Create HTTP request
        var request_headers = std.StringHashMap([]const u8).init(allocator);
        defer request_headers.deinit();
        
        // Add default headers
        try request_headers.put("User-Agent", self.safety_config.user_agent);
        
        // Add custom headers
        if (headers) |h| {
            var iter = h.iterator();
            while (iter.next()) |entry| {
                try request_headers.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        
        // Set content type for POST/PUT requests with body
        if (body != null and (method == .POST or method == .PUT or method == .PATCH)) {
            if (!request_headers.contains("Content-Type")) {
                try request_headers.put("Content-Type", "application/json");
            }
        }
        
        // Make the request using our HTTP client
        const response = self.client.request(.{
            .method = method.toString(),
            .url = url,
            .headers = request_headers,
            .body = body,
            .timeout_ms = timeout,
            .max_response_size = self.safety_config.max_response_size,
        }, allocator) catch |err| switch (err) {
            error.Timeout => return ToolResult.failure("Request timeout"),
            error.ConnectionRefused => return ToolResult.failure("Connection refused"),
            error.UnknownHostName => return ToolResult.failure("Unknown host"),
            error.TlsFailure => return ToolResult.failure("TLS handshake failed"),
            else => return ToolResult.failure("Request failed"),
        };
        defer response.deinit();
        
        const elapsed = std.time.milliTimestamp() - start_time;
        
        // Build response object
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("status_code", .{ .integer = @as(i64, @intCast(response.status_code)) });
        try result_obj.put("body", .{ .string = response.body });
        try result_obj.put("elapsed_ms", .{ .integer = elapsed });
        
        // Add headers to response
        var headers_obj = std.json.ObjectMap.init(allocator);
        var header_iter = response.headers.iterator();
        while (header_iter.next()) |header| {
            try headers_obj.put(header.key_ptr.*, .{ .string = header.value_ptr.* });
        }
        try result_obj.put("headers", .{ .object = headers_obj });
        
        // Add content info
        if (response.content_type) |ct| {
            try result_obj.put("content_type", .{ .string = ct });
        }
        
        if (response.content_length) |cl| {
            try result_obj.put("content_length", .{ .integer = @as(i64, @intCast(cl)) });
        }
        
        // Determine if request was successful
        const success = response.status_code >= 200 and response.status_code < 300;
        
        if (success) {
            return ToolResult.success(.{ .object = result_obj });
        } else {
            const error_msg = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ response.status_code, response.body });
            return ToolResult.failure(error_msg);
        }
    }
};

// Helper functions for schema creation
fn createInputSchema(allocator: std.mem.Allocator) !std.json.Value {
    var schema = std.json.ObjectMap.init(allocator);
    try schema.put("type", .{ .string = "object" });
    
    var properties = std.json.ObjectMap.init(allocator);
    
    var method_prop = std.json.ObjectMap.init(allocator);
    try method_prop.put("type", .{ .string = "string" });
    try method_prop.put("enum", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "GET" },
        .{ .string = "POST" },
        .{ .string = "PUT" },
        .{ .string = "PATCH" },
        .{ .string = "DELETE" },
        .{ .string = "HEAD" },
        .{ .string = "OPTIONS" },
    })) });
    try method_prop.put("description", .{ .string = "HTTP method to use" });
    try properties.put("method", .{ .object = method_prop });
    
    var url_prop = std.json.ObjectMap.init(allocator);
    try url_prop.put("type", .{ .string = "string" });
    try url_prop.put("format", .{ .string = "uri" });
    try url_prop.put("description", .{ .string = "URL to make the request to" });
    try properties.put("url", .{ .object = url_prop });
    
    var body_prop = std.json.ObjectMap.init(allocator);
    try body_prop.put("type", .{ .string = "string" });
    try body_prop.put("description", .{ .string = "Request body (for POST, PUT, PATCH methods)" });
    try properties.put("body", .{ .object = body_prop });
    
    var headers_prop = std.json.ObjectMap.init(allocator);
    try headers_prop.put("type", .{ .string = "object" });
    try headers_prop.put("description", .{ .string = "HTTP headers to include" });
    var headers_additional = std.json.ObjectMap.init(allocator);
    try headers_additional.put("type", .{ .string = "string" });
    try headers_prop.put("additionalProperties", .{ .object = headers_additional });
    try properties.put("headers", .{ .object = headers_prop });
    
    var timeout_prop = std.json.ObjectMap.init(allocator);
    try timeout_prop.put("type", .{ .string = "integer" });
    try timeout_prop.put("minimum", .{ .integer = 1000 });
    try timeout_prop.put("maximum", .{ .integer = 300000 });
    try timeout_prop.put("description", .{ .string = "Request timeout in milliseconds" });
    try properties.put("timeout", .{ .object = timeout_prop });
    
    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "method" },
        .{ .string = "url" },
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
    
    var data_props = std.json.ObjectMap.init(allocator);
    
    var status_prop = std.json.ObjectMap.init(allocator);
    try status_prop.put("type", .{ .string = "integer" });
    try data_props.put("status_code", .{ .object = status_prop });
    
    var body_prop = std.json.ObjectMap.init(allocator);
    try body_prop.put("type", .{ .string = "string" });
    try data_props.put("body", .{ .object = body_prop });
    
    var elapsed_prop = std.json.ObjectMap.init(allocator);
    try elapsed_prop.put("type", .{ .string = "integer" });
    try data_props.put("elapsed_ms", .{ .object = elapsed_prop });
    
    try data_prop.put("properties", .{ .object = data_props });
    try properties.put("data", .{ .object = data_prop });
    
    var error_prop = std.json.ObjectMap.init(allocator);
    try error_prop.put("type", .{ .string = "string" });
    try properties.put("error", .{ .object = error_prop });
    
    try schema.put("properties", .{ .object = properties });
    
    return .{ .object = schema };
}

fn createExampleInput(allocator: std.mem.Allocator, method: []const u8, url: []const u8, body: ?[]const u8, content_type: ?[]const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("method", .{ .string = method });
    try input.put("url", .{ .string = url });
    
    if (body) |b| {
        try input.put("body", .{ .string = b });
        
        if (content_type) |ct| {
            var headers = std.json.ObjectMap.init(allocator);
            try headers.put("Content-Type", .{ .string = ct });
            try input.put("headers", .{ .object = headers });
        }
    }
    
    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, status_code: u16, body: []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });
    
    var data = std.json.ObjectMap.init(allocator);
    try data.put("status_code", .{ .integer = @as(i64, @intCast(status_code)) });
    try data.put("body", .{ .string = body });
    try data.put("elapsed_ms", .{ .integer = 150 });
    
    try output.put("data", .{ .object = data });
    
    return output;
}

// Builder function for easy creation
pub fn createHttpTool(
    allocator: std.mem.Allocator,
    safety_config: HttpSafetyConfig,
    client: *http_client.HttpClient,
) !*Tool {
    const http_tool = try HttpTool.init(allocator, safety_config, client);
    return &http_tool.base.tool;
}

// Tests
test "http tool creation" {
    const allocator = std.testing.allocator;
    
    // Create a mock HTTP client for testing
    var client = try http_client.HttpClient.init(allocator, .{});
    defer client.deinit();
    
    const tool_ptr = try createHttpTool(allocator, .{}, &client);
    defer tool_ptr.deinit();
    
    try std.testing.expectEqualStrings("http_request", tool_ptr.metadata.name);
}

test "http tool validation" {
    const allocator = std.testing.allocator;
    
    var client = try http_client.HttpClient.init(allocator, .{});
    defer client.deinit();
    
    const tool_ptr = try createHttpTool(allocator, .{}, &client);
    defer tool_ptr.deinit();
    
    // Valid input
    var valid_input = std.json.ObjectMap.init(allocator);
    defer valid_input.deinit();
    try valid_input.put("method", .{ .string = "GET" });
    try valid_input.put("url", .{ .string = "https://api.example.com/data" });
    
    const valid = try tool_ptr.validate(.{ .object = valid_input }, allocator);
    try std.testing.expect(valid);
    
    // Invalid input (unsupported method)
    var invalid_input = std.json.ObjectMap.init(allocator);
    defer invalid_input.deinit();
    try invalid_input.put("method", .{ .string = "INVALID" });
    try invalid_input.put("url", .{ .string = "https://api.example.com/data" });
    
    const invalid = try tool_ptr.validate(.{ .object = invalid_input }, allocator);
    try std.testing.expect(!invalid);
}

test "url safety validation" {
    const allocator = std.testing.allocator;
    
    var client = try http_client.HttpClient.init(allocator, .{});
    defer client.deinit();
    
    // Create tool with restricted domains
    const safety_config = HttpSafetyConfig{
        .allowed_domains = &[_][]const u8{"api.example.com"},
        .allow_private_ips = false,
    };
    
    const http_tool = try HttpTool.init(allocator, safety_config, &client);
    defer http_tool.allocator.destroy(http_tool);
    
    // Test allowed domain
    http_tool.validateUrl("https://api.example.com/data") catch unreachable;
    
    // Test blocked domain
    const blocked_result = http_tool.validateUrl("https://malicious.com/data");
    try std.testing.expectError(HttpToolError.UnsafeUrl, blocked_result);
    
    // Test private IP
    const private_ip_result = http_tool.validateUrl("http://127.0.0.1:8080/");
    try std.testing.expectError(HttpToolError.UnsafeUrl, private_ip_result);
}