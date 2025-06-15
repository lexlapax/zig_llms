// ABOUTME: HTTP client wrapper providing unified interface for API requests
// ABOUTME: Handles authentication, request/response serialization, and error handling

const std = @import("std");
const json = std.json;

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    
    pub fn toString(self: HttpMethod) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
        };
    }
};

pub const HttpHeaders = std.StringHashMap([]const u8);

pub const HttpRequest = struct {
    method: HttpMethod,
    url: []const u8,
    headers: HttpHeaders,
    body: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, method: HttpMethod, url: []const u8) HttpRequest {
        return HttpRequest{
            .method = method,
            .url = url,
            .headers = HttpHeaders.init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
        if (self.body) |body| {
            self.allocator.free(body);
        }
    }
    
    pub fn setHeader(self: *HttpRequest, key: []const u8, value: []const u8) !void {
        try self.headers.put(key, value);
    }
    
    pub fn setJsonBody(self: *HttpRequest, data: anytype) !void {
        const json_string = try json.stringifyAlloc(self.allocator, data, .{});
        self.body = json_string;
        try self.setHeader("Content-Type", "application/json");
    }
    
    pub fn setBodyString(self: *HttpRequest, body: []const u8) !void {
        self.body = try self.allocator.dupe(u8, body);
    }
    
    pub fn setBearerAuth(self: *HttpRequest, token: []const u8) !void {
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token});
        try self.setHeader("Authorization", auth_header);
    }
    
    pub fn setUserAgent(self: *HttpRequest, user_agent: []const u8) !void {
        try self.setHeader("User-Agent", user_agent);
    }
};

pub const HttpResponse = struct {
    status_code: u16,
    headers: HttpHeaders,
    body: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, status_code: u16, body: []const u8) !HttpResponse {
        return HttpResponse{
            .status_code = status_code,
            .headers = HttpHeaders.init(allocator),
            .body = try allocator.dupe(u8, body),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
        self.allocator.free(self.body);
    }
    
    pub fn isSuccess(self: *const HttpResponse) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }
    
    pub fn parseJson(self: *const HttpResponse, comptime T: type) !json.Parsed(T) {
        return json.parseFromSlice(T, self.allocator, self.body, .{});
    }
    
    pub fn parseJsonValue(self: *const HttpResponse) !json.Parsed(json.Value) {
        return json.parseFromSlice(json.Value, self.allocator, self.body, .{});
    }
    
    pub fn getHeader(self: *const HttpResponse, key: []const u8) ?[]const u8 {
        return self.headers.get(key);
    }
};

pub const HttpClientConfig = struct {
    timeout_ms: u32 = 30000,
    max_redirects: u8 = 5,
    user_agent: []const u8 = "zig-llms/1.0.0",
    verify_ssl: bool = true,
};

pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    config: HttpClientConfig,
    client: std.http.Client,
    
    pub fn init(allocator: std.mem.Allocator, config: HttpClientConfig) HttpClient {
        return HttpClient{
            .allocator = allocator,
            .config = config,
            .client = std.http.Client{ .allocator = allocator },
        };
    }
    
    pub fn deinit(self: *HttpClient) void {
        self.client.deinit();
    }
    
    pub fn execute(self: *HttpClient, http_request: *HttpRequest) !HttpResponse {
        // Set default headers if not present
        if (!http_request.headers.contains("User-Agent")) {
            try http_request.setHeader("User-Agent", self.config.user_agent);
        }
        
        // Parse URL
        const uri = try std.Uri.parse(http_request.url);
        
        // Convert headers to array for extra_headers
        var extra_headers = std.ArrayList(std.http.Header).init(self.allocator);
        defer extra_headers.deinit();
        
        var header_iter = http_request.headers.iterator();
        while (header_iter.next()) |header| {
            try extra_headers.append(.{
                .name = header.key_ptr.*,
                .value = header.value_ptr.*,
            });
        }
        
        // Prepare request
        var req = try self.client.open(
            std.meta.stringToEnum(std.http.Method, http_request.method.toString()) orelse return error.InvalidMethod,
            uri,
            .{
                .server_header_buffer = try self.allocator.alloc(u8, 16384),
                .extra_headers = extra_headers.items,
            },
        );
        defer req.deinit();
        
        // Send request
        try req.send();
        
        // Send body if present
        if (http_request.body) |body| {
            try req.writeAll(body);
        }
        
        try req.finish();
        try req.wait();
        
        // Read response
        const response_body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 10); // 10MB max
        
        var response = try HttpResponse.init(self.allocator, @intFromEnum(req.response.status), response_body);
        
        // Copy response headers
        var iter = req.response.iterateHeaders();
        while (iter.next()) |header| {
            try response.headers.put(header.name, header.value);
        }
        
        return response;
    }
    
    pub fn get(self: *HttpClient, url: []const u8) !HttpResponse {
        var http_request = HttpRequest.init(self.allocator, .GET, url);
        defer http_request.deinit();
        
        return self.execute(&http_request);
    }
    
    pub fn post(self: *HttpClient, url: []const u8, body: ?[]const u8) !HttpResponse {
        var http_request = HttpRequest.init(self.allocator, .POST, url);
        defer http_request.deinit();
        
        if (body) |b| {
            try http_request.setBodyString(b);
        }
        
        return self.execute(&http_request);
    }
    
    pub fn postJson(self: *HttpClient, url: []const u8, data: anytype) !HttpResponse {
        var http_request = HttpRequest.init(self.allocator, .POST, url);
        defer http_request.deinit();
        
        try http_request.setJsonBody(data);
        
        return self.execute(&http_request);
    }
    
    pub fn put(self: *HttpClient, url: []const u8, body: ?[]const u8) !HttpResponse {
        var http_request = HttpRequest.init(self.allocator, .PUT, url);
        defer http_request.deinit();
        
        if (body) |b| {
            try http_request.setBodyString(b);
        }
        
        return self.execute(&http_request);
    }
    
    pub fn delete(self: *HttpClient, url: []const u8) !HttpResponse {
        var http_request = HttpRequest.init(self.allocator, .DELETE, url);
        defer http_request.deinit();
        
        return self.execute(&http_request);
    }
};

// Convenience builder functions
pub fn request(allocator: std.mem.Allocator, method: HttpMethod, url: []const u8) HttpRequest {
    return HttpRequest.init(allocator, method, url);
}

pub fn get(allocator: std.mem.Allocator, url: []const u8) HttpRequest {
    return request(allocator, .GET, url);
}

pub fn post(allocator: std.mem.Allocator, url: []const u8) HttpRequest {
    return request(allocator, .POST, url);
}

// Tests
test "http request creation" {
    const allocator = std.testing.allocator;
    
    var req = HttpRequest.init(allocator, .GET, "https://api.example.com/test");
    defer req.deinit();
    
    try req.setHeader("Accept", "application/json");
    try req.setBearerAuth("test-token");
    
    try std.testing.expectEqualStrings("GET", req.method.toString());
    try std.testing.expectEqualStrings("https://api.example.com/test", req.url);
    try std.testing.expectEqualStrings("application/json", req.headers.get("Accept").?);
}

test "http request json body" {
    const allocator = std.testing.allocator;
    
    var req = HttpRequest.init(allocator, .POST, "https://api.example.com/test");
    defer req.deinit();
    
    const test_data = struct {
        message: []const u8,
        count: u32,
    }{
        .message = "hello",
        .count = 42,
    };
    
    try req.setJsonBody(test_data);
    
    try std.testing.expect(req.body != null);
    try std.testing.expectEqualStrings("application/json", req.headers.get("Content-Type").?);
}

test "http response parsing" {
    const allocator = std.testing.allocator;
    
    const response_body = 
        \\{"message": "success", "data": {"id": 123, "name": "test"}}
    ;
    
    var response = try HttpResponse.init(allocator, 200, response_body);
    defer response.deinit();
    
    try std.testing.expect(response.isSuccess());
    
    const parsed = try response.parseJsonValue();
    defer parsed.deinit();
    
    const message = parsed.value.object.get("message").?.string;
    try std.testing.expectEqualStrings("success", message);
}

test "http client configuration" {
    const allocator = std.testing.allocator;
    
    const config = HttpClientConfig{
        .timeout_ms = 5000,
        .user_agent = "test-client/1.0.0",
        .verify_ssl = false,
    };
    
    var client = HttpClient.init(allocator, config);
    defer client.deinit();
    
    try std.testing.expectEqual(@as(u32, 5000), client.config.timeout_ms);
    try std.testing.expectEqualStrings("test-client/1.0.0", client.config.user_agent);
    try std.testing.expectEqual(false, client.config.verify_ssl);
}