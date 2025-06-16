// ABOUTME: Schema repository implementations for storing and retrieving schemas
// ABOUTME: Provides in-memory and file-based storage options for schema management

const std = @import("std");
const Schema = @import("validator.zig").Schema;

pub const SchemaRepository = struct {
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (self: *SchemaRepository, id: []const u8) anyerror!?Schema,
        put: *const fn (self: *SchemaRepository, id: []const u8, schema: Schema) anyerror!void,
        list: *const fn (self: *SchemaRepository, allocator: std.mem.Allocator) anyerror![]const []const u8,
        delete: *const fn (self: *SchemaRepository, id: []const u8) anyerror!void,
        close: *const fn (self: *SchemaRepository) void,
    };

    pub fn get(self: *SchemaRepository, id: []const u8) !?Schema {
        return self.vtable.get(self, id);
    }

    pub fn put(self: *SchemaRepository, id: []const u8, schema: Schema) !void {
        return self.vtable.put(self, id, schema);
    }

    pub fn list(self: *SchemaRepository, allocator: std.mem.Allocator) ![]const []const u8 {
        return self.vtable.list(self, allocator);
    }

    pub fn delete(self: *SchemaRepository, id: []const u8) !void {
        return self.vtable.delete(self, id);
    }

    pub fn close(self: *SchemaRepository) void {
        self.vtable.close(self);
    }
};

// In-memory implementation
pub const InMemoryRepository = struct {
    base: SchemaRepository,
    schemas: std.StringHashMap(Schema),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    const vtable = SchemaRepository.VTable{
        .get = get,
        .put = put,
        .list = list,
        .delete = delete,
        .close = close,
    };

    pub fn init(allocator: std.mem.Allocator) InMemoryRepository {
        return InMemoryRepository{
            .base = SchemaRepository{ .vtable = &vtable },
            .schemas = std.StringHashMap(Schema).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }

    fn get(base: *SchemaRepository, id: []const u8) !?Schema {
        const self = @fieldParentPtr(InMemoryRepository, "base", base);
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.schemas.get(id);
    }

    fn put(base: *SchemaRepository, id: []const u8, schema: Schema) !void {
        const self = @fieldParentPtr(InMemoryRepository, "base", base);
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.schemas.put(id, schema);
    }

    fn list(base: *SchemaRepository, allocator: std.mem.Allocator) ![]const []const u8 {
        const self = @fieldParentPtr(InMemoryRepository, "base", base);
        self.mutex.lock();
        defer self.mutex.unlock();

        var keys = std.ArrayList([]const u8).init(allocator);
        defer keys.deinit();

        var iter = self.schemas.iterator();
        while (iter.next()) |entry| {
            try keys.append(entry.key_ptr.*);
        }

        return keys.toOwnedSlice();
    }

    fn delete(base: *SchemaRepository, id: []const u8) !void {
        const self = @fieldParentPtr(InMemoryRepository, "base", base);
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.schemas.remove(id);
    }

    fn close(base: *SchemaRepository) void {
        const self = @fieldParentPtr(InMemoryRepository, "base", base);
        self.mutex.lock();
        defer self.mutex.unlock();

        self.schemas.deinit();
    }
};

// File-based implementation
pub const FileRepository = struct {
    base: SchemaRepository,
    base_path: []const u8,
    format: Format,
    allocator: std.mem.Allocator,

    pub const Format = enum {
        json,
        yaml,
    };

    const vtable = SchemaRepository.VTable{
        .get = get,
        .put = put,
        .list = list,
        .delete = delete,
        .close = close,
    };

    pub fn init(allocator: std.mem.Allocator, base_path: []const u8, format: Format) !FileRepository {
        // Ensure directory exists
        try std.fs.cwd().makePath(base_path);

        return FileRepository{
            .base = SchemaRepository{ .vtable = &vtable },
            .base_path = base_path,
            .format = format,
            .allocator = allocator,
        };
    }

    fn getFilePath(self: *const FileRepository, allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
        const extension = switch (self.format) {
            .json => ".json",
            .yaml => ".yaml",
        };
        return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ self.base_path, id, extension });
    }

    fn get(base: *SchemaRepository, id: []const u8) !?Schema {
        const self = @fieldParentPtr(FileRepository, "base", base);

        const file_path = try self.getFilePath(self.allocator, id);
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        // TODO: Parse schema from JSON/YAML
        _ = content;
        return null;
    }

    fn put(base: *SchemaRepository, id: []const u8, schema: Schema) !void {
        const self = @fieldParentPtr(FileRepository, "base", base);

        const file_path = try self.getFilePath(self.allocator, id);
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // TODO: Serialize schema to JSON/YAML
        _ = schema;
    }

    fn list(base: *SchemaRepository, allocator: std.mem.Allocator) ![]const []const u8 {
        const self = @fieldParentPtr(FileRepository, "base", base);

        var keys = std.ArrayList([]const u8).init(allocator);
        defer keys.deinit();

        var dir = try std.fs.cwd().openIterableDir(self.base_path, .{});
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            const extension = switch (self.format) {
                .json => ".json",
                .yaml => ".yaml",
            };

            if (std.mem.endsWith(u8, entry.name, extension)) {
                const id = entry.name[0 .. entry.name.len - extension.len];
                try keys.append(try allocator.dupe(u8, id));
            }
        }

        return keys.toOwnedSlice();
    }

    fn delete(base: *SchemaRepository, id: []const u8) !void {
        const self = @fieldParentPtr(FileRepository, "base", base);

        const file_path = try self.getFilePath(self.allocator, id);
        defer self.allocator.free(file_path);

        try std.fs.cwd().deleteFile(file_path);
    }

    fn close(base: *SchemaRepository) void {
        _ = base;
        // Nothing to cleanup for file repository
    }
};
