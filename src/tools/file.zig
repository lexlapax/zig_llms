// ABOUTME: File operations tool for reading, writing, and manipulating files and directories
// ABOUTME: Provides comprehensive file system operations with safety checks and validation

const std = @import("std");
const tool = @import("../tool.zig");
const Tool = tool.Tool;
const ToolMetadata = tool.ToolMetadata;
const ToolResult = tool.ToolResult;
const BaseTool = tool.BaseTool;
const schema = @import("../schema/validator.zig");

// File operation types
pub const FileOperation = enum {
    read,
    write,
    append,
    create,
    delete,
    copy,
    move,
    mkdir,
    rmdir,
    list,
    exists,
    stat,
    chmod,
    
    pub fn toString(self: FileOperation) []const u8 {
        return @tagName(self);
    }
};

// File tool error types
pub const FileToolError = error{
    FileNotFound,
    PermissionDenied,
    InvalidPath,
    DirectoryNotEmpty,
    FileAlreadyExists,
    InvalidOperation,
    UnsafeOperation,
    PathTraversal,
};

// Safety configuration
pub const SafetyConfig = struct {
    allow_absolute_paths: bool = false,
    allowed_extensions: ?[]const []const u8 = null,
    blocked_paths: []const []const u8 = &[_][]const u8{},
    max_file_size: usize = 10 * 1024 * 1024, // 10MB default
    sandbox_directory: ?[]const u8 = null,
    read_only: bool = false,
};

// File information structure
pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    is_directory: bool,
    is_file: bool,
    permissions: u32,
    created_time: i64,
    modified_time: i64,
    accessed_time: i64,
};

// File operations tool
pub const FileTool = struct {
    base: BaseTool,
    safety_config: SafetyConfig,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, safety_config: SafetyConfig) !*FileTool {
        const self = try allocator.create(FileTool);
        
        // Create tool metadata
        const metadata = ToolMetadata{
            .name = "file_operations",
            .description = "Perform file and directory operations",
            .version = "1.0.0",
            .category = .utility,
            .capabilities = &[_][]const u8{ "file_read", "file_write", "directory_ops" },
            .input_schema = try createInputSchema(allocator),
            .output_schema = try createOutputSchema(allocator),
            .examples = &[_]ToolMetadata.Example{
                .{
                    .description = "Read a text file",
                    .input = .{ .object = try createExampleInput(allocator, "read", "./example.txt", null) },
                    .output = .{ .object = try createExampleOutput(allocator, true, "File content here", null) },
                },
                .{
                    .description = "List directory contents",
                    .input = .{ .object = try createExampleInput(allocator, "list", "./", null) },
                    .output = .{ .object = try createExampleOutput(allocator, true, null, &[_][]const u8{ "file1.txt", "file2.txt" }) },
                },
            },
        };
        
        self.* = .{
            .base = BaseTool.init(metadata),
            .safety_config = safety_config,
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
        const self = @fieldParentPtr(FileTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        
        // Parse input
        const operation_str = input.object.get("operation") orelse return error.MissingOperation;
        const path_val = input.object.get("path") orelse return error.MissingPath;
        
        if (operation_str != .string or path_val != .string) {
            return error.InvalidInput;
        }
        
        const operation = std.meta.stringToEnum(FileOperation, operation_str.string) orelse {
            return error.InvalidOperation;
        };
        
        const path = path_val.string;
        
        // Validate path safety
        try self.validatePath(path);
        
        // Execute operation
        return switch (operation) {
            .read => self.readFile(path, allocator),
            .write => blk: {
                const content = input.object.get("content") orelse return error.MissingContent;
                if (content != .string) return error.InvalidContent;
                break :blk self.writeFile(path, content.string, false, allocator);
            },
            .append => blk: {
                const content = input.object.get("content") orelse return error.MissingContent;
                if (content != .string) return error.InvalidContent;
                break :blk self.writeFile(path, content.string, true, allocator);
            },
            .create => self.createFile(path, allocator),
            .delete => self.deleteFile(path, allocator),
            .copy => blk: {
                const dest = input.object.get("destination") orelse return error.MissingDestination;
                if (dest != .string) return error.InvalidDestination;
                break :blk self.copyFile(path, dest.string, allocator);
            },
            .move => blk: {
                const dest = input.object.get("destination") orelse return error.MissingDestination;
                if (dest != .string) return error.InvalidDestination;
                break :blk self.moveFile(path, dest.string, allocator);
            },
            .mkdir => self.createDirectory(path, allocator),
            .rmdir => self.removeDirectory(path, allocator),
            .list => self.listDirectory(path, allocator),
            .exists => self.checkExists(path, allocator),
            .stat => self.getFileInfo(path, allocator),
            .chmod => blk: {
                const mode = input.object.get("mode") orelse return error.MissingMode;
                if (mode != .integer) return error.InvalidMode;
                break :blk self.changePermissions(path, @as(u32, @intCast(mode.integer)), allocator);
            },
        };
    }
    
    fn validate(tool_ptr: *Tool, input: std.json.Value, allocator: std.mem.Allocator) !bool {
        _ = tool_ptr;
        _ = allocator;
        
        // Basic validation
        if (input != .object) return false;
        
        const operation = input.object.get("operation") orelse return false;
        const path = input.object.get("path") orelse return false;
        
        if (operation != .string or path != .string) return false;
        
        // Validate operation is valid
        const op = std.meta.stringToEnum(FileOperation, operation.string) orelse return false;
        
        // Check operation-specific requirements
        switch (op) {
            .write, .append => {
                const content = input.object.get("content");
                if (content == null or content.? != .string) return false;
            },
            .copy, .move => {
                const dest = input.object.get("destination");
                if (dest == null or dest.? != .string) return false;
            },
            .chmod => {
                const mode = input.object.get("mode");
                if (mode == null or mode.? != .integer) return false;
            },
            else => {},
        }
        
        return true;
    }
    
    fn deinit(tool_ptr: *Tool) void {
        const self = @fieldParentPtr(FileTool, "base", @fieldParentPtr(BaseTool, "tool", tool_ptr));
        self.allocator.destroy(self);
    }
    
    fn validatePath(self: *const FileTool, path: []const u8) !void {
        // Check for path traversal
        if (std.mem.indexOf(u8, path, "..") != null) {
            return FileToolError.PathTraversal;
        }
        
        // Check absolute paths
        if (!self.safety_config.allow_absolute_paths and std.fs.path.isAbsolute(path)) {
            return FileToolError.UnsafeOperation;
        }
        
        // Check against blocked paths
        for (self.safety_config.blocked_paths) |blocked| {
            if (std.mem.startsWith(u8, path, blocked)) {
                return FileToolError.UnsafeOperation;
            }
        }
        
        // Check allowed extensions
        if (self.safety_config.allowed_extensions) |allowed| {
            const ext = std.fs.path.extension(path);
            var found = false;
            for (allowed) |allowed_ext| {
                if (std.mem.eql(u8, ext, allowed_ext)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return FileToolError.UnsafeOperation;
            }
        }
        
        // Check sandbox directory
        if (self.safety_config.sandbox_directory) |sandbox| {
            var resolved_path = std.fs.cwd().realpathAlloc(self.allocator, path) catch |err| switch (err) {
                error.FileNotFound => return, // Allow non-existent files for creation
                else => return err,
            };
            defer self.allocator.free(resolved_path);
            
            const resolved_sandbox = try std.fs.cwd().realpathAlloc(self.allocator, sandbox);
            defer self.allocator.free(resolved_sandbox);
            
            if (!std.mem.startsWith(u8, resolved_path, resolved_sandbox)) {
                return FileToolError.UnsafeOperation;
            }
        }
    }
    
    fn readFile(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("File not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to open file"),
        };
        defer file.close();
        
        const stat = try file.stat();
        if (stat.size > self.safety_config.max_file_size) {
            return ToolResult.failure("File too large");
        }
        
        const content = try file.readToEndAlloc(allocator, self.safety_config.max_file_size);
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("content", .{ .string = content });
        try result_obj.put("size", .{ .integer = @as(i64, @intCast(stat.size)) });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn writeFile(self: *const FileTool, path: []const u8, content: []const u8, append: bool, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        if (content.len > self.safety_config.max_file_size) {
            return ToolResult.failure("Content too large");
        }
        
        const file = if (append)
            std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
                error.FileNotFound => return ToolResult.failure("File not found for append"),
                else => return ToolResult.failure("Failed to open file for append"),
            }
        else
            std.fs.cwd().createFile(path, .{}) catch |err| switch (err) {
                error.AccessDenied => return ToolResult.failure("Permission denied"),
                else => return ToolResult.failure("Failed to create file"),
            };
        defer file.close();
        
        if (append) {
            try file.seekFromEnd(0);
        }
        
        try file.writeAll(content);
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("bytes_written", .{ .integer = @as(i64, @intCast(content.len)) });
        try result_obj.put("operation", .{ .string = if (append) "append" else "write" });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn createFile(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        const file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return ToolResult.failure("File already exists"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to create file"),
        };
        file.close();
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("created", .{ .bool = true });
        try result_obj.put("path", .{ .string = path });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn deleteFile(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("File not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to delete file"),
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("deleted", .{ .bool = true });
        try result_obj.put("path", .{ .string = path });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn copyFile(self: *const FileTool, src: []const u8, dest: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        try self.validatePath(dest);
        
        std.fs.cwd().copyFile(src, std.fs.cwd(), dest, .{}) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("Source file not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            error.PathAlreadyExists => return ToolResult.failure("Destination already exists"),
            else => return ToolResult.failure("Failed to copy file"),
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("copied", .{ .bool = true });
        try result_obj.put("source", .{ .string = src });
        try result_obj.put("destination", .{ .string = dest });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn moveFile(self: *const FileTool, src: []const u8, dest: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        try self.validatePath(dest);
        
        std.fs.cwd().rename(src, dest) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("Source file not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            error.PathAlreadyExists => return ToolResult.failure("Destination already exists"),
            else => return ToolResult.failure("Failed to move file"),
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("moved", .{ .bool = true });
        try result_obj.put("source", .{ .string = src });
        try result_obj.put("destination", .{ .string = dest });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn createDirectory(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => return ToolResult.failure("Directory already exists"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to create directory"),
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("created", .{ .bool = true });
        try result_obj.put("path", .{ .string = path });
        try result_obj.put("type", .{ .string = "directory" });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn removeDirectory(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        std.fs.cwd().deleteDir(path) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("Directory not found"),
            error.DirNotEmpty => return ToolResult.failure("Directory not empty"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to remove directory"),
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("deleted", .{ .bool = true });
        try result_obj.put("path", .{ .string = path });
        try result_obj.put("type", .{ .string = "directory" });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn listDirectory(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        
        const dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("Directory not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            error.NotDir => return ToolResult.failure("Path is not a directory"),
            else => return ToolResult.failure("Failed to open directory"),
        };
        defer dir.close();
        
        var entries = std.ArrayList(std.json.Value).init(allocator);
        var iterator = dir.iterate();
        
        while (try iterator.next()) |entry| {
            var entry_obj = std.json.ObjectMap.init(allocator);
            try entry_obj.put("name", .{ .string = entry.name });
            try entry_obj.put("type", .{ .string = switch (entry.kind) {
                .file => "file",
                .directory => "directory",
                .sym_link => "symlink",
                else => "other",
            } });
            
            try entries.append(.{ .object = entry_obj });
        }
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("entries", .{ .array = std.json.Array.fromOwnedSlice(allocator, try entries.toOwnedSlice()) });
        try result_obj.put("count", .{ .integer = @as(i64, @intCast(entries.items.len)) });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn checkExists(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        
        const exists = blk: {
            std.fs.cwd().access(path, .{}) catch {
                break :blk false;
            };
            break :blk true;
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("exists", .{ .bool = exists });
        try result_obj.put("path", .{ .string = path });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn getFileInfo(self: *const FileTool, path: []const u8, allocator: std.mem.Allocator) !ToolResult {
        _ = self;
        
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("File not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to open file"),
        };
        defer file.close();
        
        const stat = try file.stat();
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("path", .{ .string = path });
        try result_obj.put("size", .{ .integer = @as(i64, @intCast(stat.size)) });
        try result_obj.put("is_file", .{ .bool = stat.kind == .file });
        try result_obj.put("is_directory", .{ .bool = stat.kind == .directory });
        try result_obj.put("mode", .{ .integer = @as(i64, @intCast(stat.mode)) });
        try result_obj.put("created_time", .{ .integer = @as(i64, @intCast(@divFloor(stat.ctime, std.time.ns_per_ms))) });
        try result_obj.put("modified_time", .{ .integer = @as(i64, @intCast(@divFloor(stat.mtime, std.time.ns_per_ms))) });
        try result_obj.put("accessed_time", .{ .integer = @as(i64, @intCast(@divFloor(stat.atime, std.time.ns_per_ms))) });
        
        return ToolResult.success(.{ .object = result_obj });
    }
    
    fn changePermissions(self: *const FileTool, path: []const u8, mode: u32, allocator: std.mem.Allocator) !ToolResult {
        if (self.safety_config.read_only) {
            return ToolResult.failure("Tool is in read-only mode");
        }
        
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return ToolResult.failure("File not found"),
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to open file"),
        };
        defer file.close();
        
        file.chmod(mode) catch |err| switch (err) {
            error.AccessDenied => return ToolResult.failure("Permission denied"),
            else => return ToolResult.failure("Failed to change permissions"),
        };
        
        var result_obj = std.json.ObjectMap.init(allocator);
        try result_obj.put("changed", .{ .bool = true });
        try result_obj.put("path", .{ .string = path });
        try result_obj.put("mode", .{ .integer = @as(i64, @intCast(mode)) });
        
        return ToolResult.success(.{ .object = result_obj });
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
        .{ .string = "read" },
        .{ .string = "write" },
        .{ .string = "append" },
        .{ .string = "create" },
        .{ .string = "delete" },
        .{ .string = "copy" },
        .{ .string = "move" },
        .{ .string = "mkdir" },
        .{ .string = "rmdir" },
        .{ .string = "list" },
        .{ .string = "exists" },
        .{ .string = "stat" },
        .{ .string = "chmod" },
    })) });
    try properties.put("operation", .{ .object = operation_prop });
    
    var path_prop = std.json.ObjectMap.init(allocator);
    try path_prop.put("type", .{ .string = "string" });
    try path_prop.put("description", .{ .string = "File or directory path" });
    try properties.put("path", .{ .object = path_prop });
    
    var content_prop = std.json.ObjectMap.init(allocator);
    try content_prop.put("type", .{ .string = "string" });
    try content_prop.put("description", .{ .string = "Content to write (for write/append operations)" });
    try properties.put("content", .{ .object = content_prop });
    
    var dest_prop = std.json.ObjectMap.init(allocator);
    try dest_prop.put("type", .{ .string = "string" });
    try dest_prop.put("description", .{ .string = "Destination path (for copy/move operations)" });
    try properties.put("destination", .{ .object = dest_prop });
    
    var mode_prop = std.json.ObjectMap.init(allocator);
    try mode_prop.put("type", .{ .string = "integer" });
    try mode_prop.put("description", .{ .string = "File permissions mode (for chmod operation)" });
    try properties.put("mode", .{ .object = mode_prop });
    
    try schema.put("properties", .{ .object = properties });
    try schema.put("required", .{ .array = std.json.Array.fromOwnedSlice(allocator, try allocator.dupe(std.json.Value, &[_]std.json.Value{
        .{ .string = "operation" },
        .{ .string = "path" },
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

fn createExampleInput(allocator: std.mem.Allocator, operation: []const u8, path: []const u8, content: ?[]const u8) !std.json.ObjectMap {
    var input = std.json.ObjectMap.init(allocator);
    try input.put("operation", .{ .string = operation });
    try input.put("path", .{ .string = path });
    if (content) |c| {
        try input.put("content", .{ .string = c });
    }
    return input;
}

fn createExampleOutput(allocator: std.mem.Allocator, success: bool, content: ?[]const u8, files: ?[]const []const u8) !std.json.ObjectMap {
    var output = std.json.ObjectMap.init(allocator);
    try output.put("success", .{ .bool = success });
    
    if (content) |c| {
        var data = std.json.ObjectMap.init(allocator);
        try data.put("content", .{ .string = c });
        try output.put("data", .{ .object = data });
    }
    
    if (files) |f| {
        var data = std.json.ObjectMap.init(allocator);
        var entries = std.ArrayList(std.json.Value).init(allocator);
        for (f) |file| {
            try entries.append(.{ .string = file });
        }
        try data.put("entries", .{ .array = std.json.Array.fromOwnedSlice(allocator, try entries.toOwnedSlice()) });
        try output.put("data", .{ .object = data });
    }
    
    return output;
}

// Builder function for easy creation
pub fn createFileTool(allocator: std.mem.Allocator, safety_config: SafetyConfig) !*Tool {
    const file_tool = try FileTool.init(allocator, safety_config);
    return &file_tool.base.tool;
}

// Tests
test "file tool creation" {
    const allocator = std.testing.allocator;
    
    const tool_ptr = try createFileTool(allocator, .{});
    defer tool_ptr.deinit();
    
    try std.testing.expectEqualStrings("file_operations", tool_ptr.metadata.name);
}

test "file tool validation" {
    const allocator = std.testing.allocator;
    
    const tool_ptr = try createFileTool(allocator, .{});
    defer tool_ptr.deinit();
    
    // Valid input
    var valid_input = std.json.ObjectMap.init(allocator);
    defer valid_input.deinit();
    try valid_input.put("operation", .{ .string = "read" });
    try valid_input.put("path", .{ .string = "test.txt" });
    
    const valid = try tool_ptr.validate(.{ .object = valid_input }, allocator);
    try std.testing.expect(valid);
    
    // Invalid input (missing operation)
    var invalid_input = std.json.ObjectMap.init(allocator);
    defer invalid_input.deinit();
    try invalid_input.put("path", .{ .string = "test.txt" });
    
    const invalid = try tool_ptr.validate(.{ .object = invalid_input }, allocator);
    try std.testing.expect(!invalid);
}

test "file exists check" {
    const allocator = std.testing.allocator;
    
    const tool_ptr = try createFileTool(allocator, .{});
    defer tool_ptr.deinit();
    
    var input = std.json.ObjectMap.init(allocator);
    defer input.deinit();
    try input.put("operation", .{ .string = "exists" });
    try input.put("path", .{ .string = "nonexistent_file.txt" });
    
    const result = try tool_ptr.execute(.{ .object = input }, allocator);
    defer if (result.data) |data| {
        switch (data) {
            .object => |obj| obj.deinit(),
            else => {},
        }
    };
    
    try std.testing.expect(result.success);
    if (result.data) |data| {
        try std.testing.expect(data.object.get("exists").?.bool == false);
    }
}