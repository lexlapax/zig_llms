// ABOUTME: HTTP connection pooling for efficient connection reuse
// ABOUTME: Manages persistent connections and reduces connection overhead for frequent requests

pub const retry = @import("retry.zig");
pub const RetryableHttpClient = retry.RetryableHttpClient;
pub const RetryConfig = retry.RetryConfig;

const std = @import("std");
const HttpClient = @import("client.zig").HttpClient;
const HttpClientConfig = @import("client.zig").HttpClientConfig;

pub const ConnectionPoolConfig = struct {
    max_connections: u32 = 10,
    max_idle_time_ms: u32 = 300000, // 5 minutes
    connection_timeout_ms: u32 = 5000,
    keep_alive: bool = true,
};

pub const PooledConnection = struct {
    client: HttpClient,
    last_used: i64,
    in_use: bool,
    host: []const u8,
    port: u16,
    is_https: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, is_https: bool, config: HttpClientConfig) !PooledConnection {
        return PooledConnection{
            .client = HttpClient.init(allocator, config),
            .last_used = std.time.timestamp(),
            .in_use = false,
            .host = try allocator.dupe(u8, host),
            .port = port,
            .is_https = is_https,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PooledConnection) void {
        self.client.deinit();
        self.allocator.free(self.host);
    }

    pub fn isExpired(self: *const PooledConnection, max_idle_time_ms: u32) bool {
        const now = std.time.timestamp();
        const idle_time_ms = @as(u32, @intCast((now - self.last_used) * 1000));
        return idle_time_ms > max_idle_time_ms;
    }

    pub fn matches(self: *const PooledConnection, host: []const u8, port: u16, is_https: bool) bool {
        return std.mem.eql(u8, self.host, host) and self.port == port and self.is_https == is_https;
    }

    pub fn markUsed(self: *PooledConnection) void {
        self.last_used = std.time.timestamp();
        self.in_use = true;
    }

    pub fn markReleased(self: *PooledConnection) void {
        self.last_used = std.time.timestamp();
        self.in_use = false;
    }
};

pub const ConnectionPool = struct {
    connections: std.ArrayList(*PooledConnection),
    config: ConnectionPoolConfig,
    client_config: HttpClientConfig,
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pool_config: ConnectionPoolConfig, client_config: HttpClientConfig) ConnectionPool {
        return ConnectionPool{
            .connections = std.ArrayList(*PooledConnection).init(allocator),
            .config = pool_config,
            .client_config = client_config,
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.connections.deinit();
    }

    pub fn getConnection(self: *ConnectionPool, url: []const u8) !*PooledConnection {
        const uri = try std.Uri.parse(url);
        const host = uri.host orelse return error.InvalidUrl;
        const port = uri.port orelse if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80);
        const is_https = std.mem.eql(u8, uri.scheme, "https");

        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up expired connections
        try self.cleanupExpiredConnections();

        // Look for available connection
        for (self.connections.items) |conn| {
            if (!conn.in_use and conn.matches(host, port, is_https) and !conn.isExpired(self.config.max_idle_time_ms)) {
                conn.markUsed();
                return conn;
            }
        }

        // Create new connection if under limit
        if (self.connections.items.len < self.config.max_connections) {
            const conn = try self.allocator.create(PooledConnection);
            conn.* = try PooledConnection.init(self.allocator, host, port, is_https, self.client_config);
            conn.markUsed();

            try self.connections.append(conn);
            return conn;
        }

        // Pool is full, find least recently used connection
        var lru_conn: ?*PooledConnection = null;
        var oldest_time: i64 = std.time.timestamp();

        for (self.connections.items) |conn| {
            if (!conn.in_use and conn.last_used < oldest_time) {
                lru_conn = conn;
                oldest_time = conn.last_used;
            }
        }

        if (lru_conn) |conn| {
            // Reuse the LRU connection (may need to reconnect)
            conn.deinit();
            conn.* = try PooledConnection.init(self.allocator, host, port, is_https, self.client_config);
            conn.markUsed();
            return conn;
        }

        return error.NoAvailableConnections;
    }

    pub fn releaseConnection(self: *ConnectionPool, connection: *PooledConnection) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        connection.markReleased();
    }

    pub fn getStats(self: *ConnectionPool) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var stats = PoolStats{};

        for (self.connections.items) |conn| {
            stats.total_connections += 1;
            if (conn.in_use) {
                stats.active_connections += 1;
            } else {
                stats.idle_connections += 1;
            }

            if (conn.isExpired(self.config.max_idle_time_ms)) {
                stats.expired_connections += 1;
            }
        }

        return stats;
    }

    fn cleanupExpiredConnections(self: *ConnectionPool) !void {
        var i: usize = 0;
        while (i < self.connections.items.len) {
            const conn = self.connections.items[i];

            if (!conn.in_use and conn.isExpired(self.config.max_idle_time_ms)) {
                conn.deinit();
                self.allocator.destroy(conn);
                _ = self.connections.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn forceCleanup(self: *ConnectionPool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.cleanupExpiredConnections();
    }
};

pub const PoolStats = struct {
    total_connections: u32 = 0,
    active_connections: u32 = 0,
    idle_connections: u32 = 0,
    expired_connections: u32 = 0,
};

// High-level pooled HTTP client
pub const PooledHttpClient = struct {
    pool: ConnectionPool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, pool_config: ConnectionPoolConfig, client_config: HttpClientConfig) PooledHttpClient {
        return PooledHttpClient{
            .pool = ConnectionPool.init(allocator, pool_config, client_config),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PooledHttpClient) void {
        self.pool.deinit();
    }

    pub fn execute(self: *PooledHttpClient, http_request: *@import("client.zig").HttpRequest) !@import("client.zig").HttpResponse {
        const connection = try self.pool.getConnection(http_request.url);
        defer self.pool.releaseConnection(connection);

        return connection.client.execute(http_request);
    }

    pub fn get(self: *PooledHttpClient, url: []const u8) !@import("client.zig").HttpResponse {
        var http_request = @import("client.zig").request(self.allocator, .GET, url);
        defer http_request.deinit();

        return self.execute(&http_request);
    }

    pub fn post(self: *PooledHttpClient, url: []const u8, body: ?[]const u8) !@import("client.zig").HttpResponse {
        var http_request = @import("client.zig").request(self.allocator, .POST, url);
        defer http_request.deinit();

        if (body) |b| {
            try http_request.setBodyString(b);
        }

        return self.execute(&http_request);
    }

    pub fn postJson(self: *PooledHttpClient, url: []const u8, data: anytype) !@import("client.zig").HttpResponse {
        var http_request = @import("client.zig").request(self.allocator, .POST, url);
        defer http_request.deinit();

        try http_request.setJsonBody(data);

        return self.execute(&http_request);
    }

    pub fn getStats(self: *PooledHttpClient) PoolStats {
        return self.pool.getStats();
    }

    pub fn cleanup(self: *PooledHttpClient) !void {
        try self.pool.forceCleanup();
    }
};

// Tests
test "connection pool creation" {
    const allocator = std.testing.allocator;

    const pool_config = ConnectionPoolConfig{
        .max_connections = 5,
        .max_idle_time_ms = 60000,
    };

    const client_config = HttpClientConfig{};

    var pool = ConnectionPool.init(allocator, pool_config, client_config);
    defer pool.deinit();

    const stats = pool.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.total_connections);
}

test "pooled connection lifecycle" {
    const allocator = std.testing.allocator;

    var conn = try PooledConnection.init(allocator, "api.example.com", 443, true, HttpClientConfig{});
    defer conn.deinit();

    try std.testing.expect(!conn.in_use);
    try std.testing.expect(conn.matches("api.example.com", 443, true));
    try std.testing.expect(!conn.matches("api.example.com", 80, false));

    conn.markUsed();
    try std.testing.expect(conn.in_use);

    conn.markReleased();
    try std.testing.expect(!conn.in_use);
}

test "pooled http client" {
    const allocator = std.testing.allocator;

    const pool_config = ConnectionPoolConfig{
        .max_connections = 2,
    };

    const client_config = HttpClientConfig{
        .timeout_ms = 5000,
    };

    var client = PooledHttpClient.init(allocator, pool_config, client_config);
    defer client.deinit();

    const initial_stats = client.getStats();
    try std.testing.expectEqual(@as(u32, 0), initial_stats.total_connections);

    try client.cleanup();
}
