// ABOUTME: Tool discovery mechanisms for finding and loading tools from various sources
// ABOUTME: Supports filesystem scanning, manifest files, and plugin architectures

const std = @import("std");
const tool_mod = @import("../tool.zig");
const Tool = tool_mod.Tool;
const ToolMetadata = Tool.ToolMetadata;
const registry_mod = @import("../tool_registry.zig");
const ToolRegistry = registry_mod.ToolRegistry;
const ToolInfo = registry_mod.ToolInfo;

// Tool manifest structure
pub const ToolManifest = struct {
    version: []const u8 = "1.0",
    name: []const u8,
    description: []const u8,
    author: ?[]const u8 = null,
    tools: []const ToolEntry,
    dependencies: []const Dependency = &[_]Dependency{},
    
    pub const ToolEntry = struct {
        name: []const u8,
        description: []const u8,
        entry_point: []const u8,
        category: ?[]const u8 = null,
        tags: []const []const u8 = &[_][]const u8{},
        config: ?std.json.Value = null,
    };
    
    pub const Dependency = struct {
        name: []const u8,
        version: []const u8,
        optional: bool = false,
    };
    
    pub fn fromJson(allocator: std.mem.Allocator, json: []const u8) !ToolManifest {
        const parsed = try std.json.parseFromSlice(ToolManifest, allocator, json, .{
            .ignore_unknown_fields = true,
        });
        return parsed.value;
    }
    
    pub fn toJson(self: ToolManifest, allocator: std.mem.Allocator) ![]const u8 {
        return std.json.stringifyAlloc(allocator, self, .{ .whitespace = .indent_2 });
    }
};

// Tool discoverer interface
pub const ToolDiscoverer = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        discover: *const fn (self: *ToolDiscoverer, registry: *ToolRegistry) anyerror!DiscoveryResult,
        deinit: *const fn (self: *ToolDiscoverer) void,
    };
    
    pub const DiscoveryResult = struct {
        tools_found: usize,
        tools_loaded: usize,
        errors: []const Error,
        allocator: std.mem.Allocator,
        
        pub const Error = struct {
            source: []const u8,
            message: []const u8,
        };
        
        pub fn deinit(self: *DiscoveryResult) void {
            for (self.errors) |err| {
                self.allocator.free(err.source);
                self.allocator.free(err.message);
            }
            self.allocator.free(self.errors);
        }
    };
    
    pub fn discover(self: *ToolDiscoverer, registry: *ToolRegistry) !DiscoveryResult {
        return self.vtable.discover(self, registry);
    }
    
    pub fn deinit(self: *ToolDiscoverer) void {
        self.vtable.deinit(self);
    }
};

// Filesystem discoverer
pub const FilesystemDiscoverer = struct {
    base: ToolDiscoverer,
    paths: std.ArrayList([]const u8),
    extensions: []const []const u8,
    recursive: bool,
    allocator: std.mem.Allocator,
    
    const vtable = ToolDiscoverer.VTable{
        .discover = discover,
        .deinit = deinit,
    };
    
    pub fn init(allocator: std.mem.Allocator) FilesystemDiscoverer {
        return .{
            .base = ToolDiscoverer{ .vtable = &vtable },
            .paths = std.ArrayList([]const u8).init(allocator),
            .extensions = &[_][]const u8{ ".zig", ".so", ".dll", ".dylib" },
            .recursive = true,
            .allocator = allocator,
        };
    }
    
    pub fn addPath(self: *FilesystemDiscoverer, path: []const u8) !void {
        try self.paths.append(try self.allocator.dupe(u8, path));
    }
    
    fn discover(base: *ToolDiscoverer, registry: *ToolRegistry) !ToolDiscoverer.DiscoveryResult {
        const self: *FilesystemDiscoverer = @fieldParentPtr("base", base);
        
        var errors = std.ArrayList(ToolDiscoverer.DiscoveryResult.Error).init(self.allocator);
        defer errors.deinit();
        
        var tools_found: usize = 0;
        var tools_loaded: usize = 0;
        
        for (self.paths.items) |path| {
            const result = self.discoverInPath(path, registry, &errors) catch |err| {
                try errors.append(.{
                    .source = try self.allocator.dupe(u8, path),
                    .message = try self.allocator.dupe(u8, @errorName(err)),
                });
                continue;
            };
            
            tools_found += result.found;
            tools_loaded += result.loaded;
        }
        
        return .{
            .tools_found = tools_found,
            .tools_loaded = tools_loaded,
            .errors = try errors.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
    
    fn discoverInPath(
        self: *FilesystemDiscoverer,
        path: []const u8,
        registry: *ToolRegistry,
        errors: *std.ArrayList(ToolDiscoverer.DiscoveryResult.Error),
    ) !struct { found: usize, loaded: usize } {
        var found: usize = 0;
        var loaded: usize = 0;
        
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    // Check if file has valid extension
                    const name = entry.name;
                    var has_valid_ext = false;
                    for (self.extensions) |ext| {
                        if (std.mem.endsWith(u8, name, ext)) {
                            has_valid_ext = true;
                            break;
                        }
                    }
                    
                    if (!has_valid_ext) continue;
                    
                    found += 1;
                    
                    // Try to load tool
                    const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{ path, name });
                    defer self.allocator.free(full_path);
                    
                    self.loadToolFromFile(full_path, registry) catch |err| {
                        try errors.append(.{
                            .source = try self.allocator.dupe(u8, full_path),
                            .message = try self.allocator.dupe(u8, @errorName(err)),
                        });
                        continue;
                    };
                    
                    loaded += 1;
                },
                .directory => {
                    if (self.recursive) {
                        const sub_path = try std.fs.path.join(self.allocator, &[_][]const u8{ path, entry.name });
                        defer self.allocator.free(sub_path);
                        
                        const sub_result = try self.discoverInPath(sub_path, registry, errors);
                        found += sub_result.found;
                        loaded += sub_result.loaded;
                    }
                },
                else => {},
            }
        }
        
        // Also check for manifest files
        if (dir.openFile("tools.json", .{})) |file| {
            defer file.close();
            
            const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(content);
            
            const manifest = try ToolManifest.fromJson(self.allocator, content);
            
            for (manifest.tools) |tool_entry| {
                found += 1;
                self.loadToolFromManifest(tool_entry, path, registry) catch |err| {
                    try errors.append(.{
                        .source = try self.allocator.dupe(u8, tool_entry.name),
                        .message = try self.allocator.dupe(u8, @errorName(err)),
                    });
                    continue;
                };
                loaded += 1;
            }
        } else |_| {}
        
        return .{ .found = found, .loaded = loaded };
    }
    
    fn loadToolFromFile(self: *FilesystemDiscoverer, path: []const u8, registry: *ToolRegistry) !void {
        // TODO: Implement actual loading based on file type
        _ = self;
        _ = path;
        _ = registry;
    }
    
    fn loadToolFromManifest(
        self: *FilesystemDiscoverer,
        entry: ToolManifest.ToolEntry,
        base_path: []const u8,
        registry: *ToolRegistry,
    ) !void {
        // TODO: Implement loading from manifest entry
        _ = self;
        _ = entry;
        _ = base_path;
        _ = registry;
    }
    
    fn deinit(base: *ToolDiscoverer) void {
        const self: *FilesystemDiscoverer = @fieldParentPtr("base", base);
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }
        self.paths.deinit();
    }
};

// Environment variable discoverer
pub const EnvDiscoverer = struct {
    base: ToolDiscoverer,
    env_vars: []const []const u8,
    allocator: std.mem.Allocator,
    
    const vtable = ToolDiscoverer.VTable{
        .discover = discover,
        .deinit = deinit,
    };
    
    pub fn init(allocator: std.mem.Allocator) EnvDiscoverer {
        return .{
            .base = ToolDiscoverer{ .vtable = &vtable },
            .env_vars = &[_][]const u8{ "ZIG_LLMS_TOOLS", "TOOL_PATH" },
            .allocator = allocator,
        };
    }
    
    fn discover(base: *ToolDiscoverer, registry: *ToolRegistry) !ToolDiscoverer.DiscoveryResult {
        const self: *EnvDiscoverer = @fieldParentPtr("base", base);
        
        var fs_discoverer = FilesystemDiscoverer.init(self.allocator);
        defer fs_discoverer.base.deinit();
        
        // Add paths from environment variables
        for (self.env_vars) |var_name| {
            if (std.process.getEnvVarOwned(self.allocator, var_name)) |value| {
                defer self.allocator.free(value);
                
                // Split by path separator
                var iter = std.mem.tokenize(u8, value, if (std.builtin.os.tag == .windows) ";" else ":");
                while (iter.next()) |path| {
                    try fs_discoverer.addPath(path);
                }
            } else |_| {}
        }
        
        return fs_discoverer.base.discover(registry);
    }
    
    fn deinit(base: *ToolDiscoverer) void {
        _ = base;
    }
};

// Composite discoverer that combines multiple discoverers
pub const CompositeDiscoverer = struct {
    base: ToolDiscoverer,
    discoverers: std.ArrayList(*ToolDiscoverer),
    allocator: std.mem.Allocator,
    
    const vtable = ToolDiscoverer.VTable{
        .discover = discover,
        .deinit = deinit,
    };
    
    pub fn init(allocator: std.mem.Allocator) CompositeDiscoverer {
        return .{
            .base = ToolDiscoverer{ .vtable = &vtable },
            .discoverers = std.ArrayList(*ToolDiscoverer).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn addDiscoverer(self: *CompositeDiscoverer, discoverer: *ToolDiscoverer) !void {
        try self.discoverers.append(discoverer);
    }
    
    fn discover(base: *ToolDiscoverer, registry: *ToolRegistry) !ToolDiscoverer.DiscoveryResult {
        const self: *CompositeDiscoverer = @fieldParentPtr("base", base);
        
        var total_found: usize = 0;
        var total_loaded: usize = 0;
        var all_errors = std.ArrayList(ToolDiscoverer.DiscoveryResult.Error).init(self.allocator);
        defer all_errors.deinit();
        
        for (self.discoverers.items) |discoverer| {
            var result = try discoverer.discover(registry);
            defer result.deinit();
            
            total_found += result.tools_found;
            total_loaded += result.tools_loaded;
            
            try all_errors.appendSlice(result.errors);
        }
        
        return .{
            .tools_found = total_found,
            .tools_loaded = total_loaded,
            .errors = try all_errors.toOwnedSlice(),
            .allocator = self.allocator,
        };
    }
    
    fn deinit(base: *ToolDiscoverer) void {
        const self: *CompositeDiscoverer = @fieldParentPtr("base", base);
        self.discoverers.deinit();
    }
};

// Default discoverer with standard paths
pub fn createDefaultDiscoverer(allocator: std.mem.Allocator) !*CompositeDiscoverer {
    const composite = try allocator.create(CompositeDiscoverer);
    composite.* = CompositeDiscoverer.init(allocator);
    
    // Add filesystem discoverer with common paths
    const fs_disc = try allocator.create(FilesystemDiscoverer);
    fs_disc.* = FilesystemDiscoverer.init(allocator);
    try fs_disc.addPath("./tools");
    try fs_disc.addPath("~/.zig_llms/tools");
    try composite.addDiscoverer(&fs_disc.base);
    
    // Add environment discoverer
    const env_disc = try allocator.create(EnvDiscoverer);
    env_disc.* = EnvDiscoverer.init(allocator);
    try composite.addDiscoverer(&env_disc.base);
    
    return composite;
}

// Tests
test "tool manifest parsing" {
    const allocator = std.testing.allocator;
    
    const manifest_json =
        \\{
        \\  "version": "1.0",
        \\  "name": "example-tools",
        \\  "description": "Example tool collection",
        \\  "tools": [
        \\    {
        \\      "name": "file_reader",
        \\      "description": "Reads files",
        \\      "entry_point": "file_reader.zig",
        \\      "category": "file_system",
        \\      "tags": ["file", "io"]
        \\    }
        \\  ]
        \\}
    ;
    
    const manifest = try ToolManifest.fromJson(allocator, manifest_json);
    
    try std.testing.expectEqualStrings("1.0", manifest.version);
    try std.testing.expectEqualStrings("example-tools", manifest.name);
    try std.testing.expectEqual(@as(usize, 1), manifest.tools.len);
    try std.testing.expectEqualStrings("file_reader", manifest.tools[0].name);
}

test "filesystem discoverer" {
    const allocator = std.testing.allocator;
    
    var fs_disc = FilesystemDiscoverer.init(allocator);
    defer fs_disc.base.deinit();
    
    // Add test path
    try fs_disc.addPath("./test_tools");
    
    try std.testing.expectEqual(@as(usize, 1), fs_disc.paths.items.len);
}