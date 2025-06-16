// ABOUTME: Enhanced tool registry with dynamic registration and discovery
// ABOUTME: Supports lazy loading, persistence, and external tool callbacks

const std = @import("std");
const tool_mod = @import("tool.zig");
const Tool = tool_mod.Tool;
const ToolCategory = tool_mod.ToolCategory;
const ToolCapability = tool_mod.ToolCapability;
const RunContext = @import("context.zig").RunContext;

pub const ToolFactory = *const fn (allocator: std.mem.Allocator) anyerror!*Tool;

pub const ToolInfo = struct {
    metadata: Tool.ToolMetadata,
    factory: ToolFactory,
    lazy_load: bool = false,
    external_path: ?[]const u8 = null,
    dependencies: []const []const u8 = &[_][]const u8{},
};

// Tool filter for discovery
pub const ToolFilter = struct {
    category: ?ToolCategory = null,
    tags: []const []const u8 = &[_][]const u8{},
    capabilities: []const ToolCapability = &[_]ToolCapability{},
    name_pattern: ?[]const u8 = null,
};

pub const ToolRegistry = struct {
    builtin_tools: std.StringHashMap(ToolInfo),
    dynamic_tools: std.StringHashMap(ToolInfo),
    instances: std.StringHashMap(*Tool),
    external_loaders: std.StringHashMap(ExternalLoader),
    tool_paths: std.ArrayList([]const u8),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    config: RegistryConfig,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return ToolRegistry{
            .builtin_tools = std.StringHashMap(ToolInfo).init(allocator),
            .dynamic_tools = std.StringHashMap(ToolInfo).init(allocator),
            .instances = std.StringHashMap(*Tool).init(allocator),
            .external_loaders = std.StringHashMap(ExternalLoader).init(allocator),
            .tool_paths = std.ArrayList([]const u8).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
            .config = RegistryConfig{},
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: RegistryConfig) !ToolRegistry {
        var registry = init(allocator);
        registry.config = config;

        // Add default tool paths
        if (config.scan_default_paths) {
            try registry.addToolPath("./tools");
            try registry.addToolPath("~/.zig_llms/tools");
        }

        return registry;
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up tool instances
        var iter = self.instances.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.cleanup();
            self.allocator.destroy(entry.value_ptr.*);
        }

        // Clean up external loaders
        var loader_iter = self.external_loaders.iterator();
        while (loader_iter.next()) |entry| {
            if (entry.value_ptr.deinit) |deinitFn| {
                deinitFn();
            }
        }

        self.builtin_tools.deinit();
        self.dynamic_tools.deinit();
        self.instances.deinit();
        self.external_loaders.deinit();
        self.tool_paths.deinit();
    }

    pub fn discover(self: *ToolRegistry) ![]Tool.ToolMetadata {
        return self.discoverWithFilter(ToolFilter{});
    }

    pub fn discoverWithFilter(self: *ToolRegistry, filter: ToolFilter) ![]Tool.ToolMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        var metadata_list = std.ArrayList(Tool.ToolMetadata).init(self.allocator);
        defer metadata_list.deinit();

        // Helper to check if tool matches filter
        const matchesFilter = struct {
            fn match(meta: Tool.ToolMetadata, f: ToolFilter) bool {
                // Check category
                if (f.category) |cat| {
                    if (meta.category != cat) return false;
                }

                // Check tags
                for (f.tags) |required_tag| {
                    if (!meta.hasTag(required_tag)) return false;
                }

                // Check capabilities
                for (f.capabilities) |cap| {
                    if (!meta.hasCapability(cap)) return false;
                }

                // Check name pattern
                if (f.name_pattern) |pattern| {
                    if (!matchesPattern(meta.name, pattern)) return false;
                }

                return true;
            }
        }.match;

        // Add matching builtin tools
        var builtin_iter = self.builtin_tools.iterator();
        while (builtin_iter.next()) |entry| {
            if (matchesFilter(entry.value_ptr.metadata, filter)) {
                try metadata_list.append(entry.value_ptr.metadata);
            }
        }

        // Add matching dynamic tools
        var dynamic_iter = self.dynamic_tools.iterator();
        while (dynamic_iter.next()) |entry| {
            if (matchesFilter(entry.value_ptr.metadata, filter)) {
                try metadata_list.append(entry.value_ptr.metadata);
            }
        }

        // Scan tool paths if enabled
        if (self.config.auto_discover) {
            try self.scanToolPaths();
        }

        return metadata_list.toOwnedSlice();
    }

    pub fn create(self: *ToolRegistry, name: []const u8) !*Tool {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if already instantiated
        if (self.instances.get(name)) |tool| {
            if (self.config.reuse_instances) {
                return tool;
            }
        }

        // Look for tool info
        const info = self.builtin_tools.get(name) orelse
            self.dynamic_tools.get(name) orelse
            return error.ToolNotFound;

        // Check dependencies
        for (info.dependencies) |dep| {
            _ = self.create(dep) catch {
                return error.DependencyNotFound;
            };
        }

        // Create instance
        const tool = if (info.external_path) |path|
            try self.loadExternalTool(path, info)
        else
            try info.factory(self.allocator);

        if (self.config.cache_instances) {
            try self.instances.put(name, tool);
        }

        return tool;
    }

    pub fn registerTool(self: *ToolRegistry, info: Tool.ToolMetadata, factory: ToolFactory) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tool_info = ToolInfo{
            .metadata = info,
            .factory = factory,
        };

        try self.dynamic_tools.put(info.name, tool_info);
    }

    pub fn unregisterTool(self: *ToolRegistry, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove from dynamic tools
        _ = self.dynamic_tools.remove(name);

        // Remove instance if exists
        if (self.instances.fetchRemove(name)) |entry| {
            entry.value.cleanup();
            self.allocator.destroy(entry.value);
        }
    }

    pub fn save(self: *ToolRegistry, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var tools_data = std.json.ObjectMap.init(self.allocator);
        defer tools_data.deinit();

        var dynamic_iter = self.dynamic_tools.iterator();
        while (dynamic_iter.next()) |entry| {
            const metadata = entry.value_ptr.metadata;

            var tool_obj = std.json.ObjectMap.init(self.allocator);
            defer tool_obj.deinit();

            try tool_obj.put("name", std.json.Value{ .string = metadata.name });
            try tool_obj.put("description", std.json.Value{ .string = metadata.description });
            // TODO: Serialize schema

            try tools_data.put(metadata.name, std.json.Value{ .object = tool_obj });
        }

        const data = std.json.Value{ .object = tools_data };
        try std.json.stringify(data, .{}, writer);
    }

    pub fn load(self: *ToolRegistry, reader: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const content = try reader.readAllAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidFormat;

        var iter = parsed.value.object.iterator();
        while (iter.next()) |entry| {
            const tool_name = entry.key_ptr.*;
            if (entry.value_ptr.* != .object) continue;

            const tool_data = entry.value_ptr.*.object;

            // Extract metadata from JSON
            const description = if (tool_data.get("description")) |d| d.string else "";

            // TODO: Reconstruct full metadata and factory from JSON
            _ = tool_name;
            _ = description;
        }
    }

    pub fn registerBuiltinTool(self: *ToolRegistry, info: Tool.ToolMetadata, factory: ToolFactory) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const tool_info = ToolInfo{
            .metadata = info,
            .factory = factory,
        };

        try self.builtin_tools.put(info.name, tool_info);
    }

    pub fn addToolPath(self: *ToolRegistry, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.tool_paths.append(try self.allocator.dupe(u8, path));
    }

    pub fn scanToolPaths(self: *ToolRegistry) !void {
        for (self.tool_paths.items) |path| {
            try self.scanPath(path);
        }
    }

    fn scanPath(self: *ToolRegistry, path: []const u8) !void {
        // TODO: Implement directory scanning for tool files
        _ = self;
        _ = path;
    }

    fn loadExternalTool(self: *ToolRegistry, path: []const u8, info: ToolInfo) !*Tool {
        // Check if we have a loader for this type
        const ext = std.fs.path.extension(path);

        if (self.external_loaders.get(ext)) |loader| {
            return loader.load(path, info.metadata, self.allocator);
        }

        return error.NoLoaderForExtension;
    }

    pub fn registerExternalLoader(self: *ToolRegistry, extension: []const u8, loader: ExternalLoader) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.external_loaders.put(extension, loader);
    }

    // Get tool by name with optional validation
    pub fn getTool(self: *ToolRegistry, name: []const u8, context: ?*RunContext) !*Tool {
        const tool = try self.create(name);

        // Validate tool if context provided
        if (context) |ctx| {
            if (self.config.validate_on_get) {
                try self.validateTool(tool, ctx);
            }
        }

        return tool;
    }

    fn validateTool(self: *ToolRegistry, tool: *Tool, context: *RunContext) !void {
        _ = self;

        // Check required capabilities
        if (tool.metadata.requires_network) {
            // TODO: Check network availability in context
            _ = context;
        }

        if (tool.metadata.requires_filesystem) {
            // TODO: Check filesystem permissions in context
        }
    }
};

// Configuration for the registry
pub const RegistryConfig = struct {
    auto_discover: bool = true,
    scan_default_paths: bool = true,
    cache_instances: bool = true,
    reuse_instances: bool = true,
    validate_on_get: bool = false,
    max_instances: ?usize = null,
};

// External tool loader interface
pub const ExternalLoader = struct {
    load: *const fn (path: []const u8, metadata: Tool.ToolMetadata, allocator: std.mem.Allocator) anyerror!*Tool,
    deinit: ?*const fn () void = null,
};

// Helper function for pattern matching
fn matchesPattern(str: []const u8, pattern: []const u8) bool {
    // Simple wildcard matching with * and ?
    var str_idx: usize = 0;
    var pat_idx: usize = 0;

    while (str_idx < str.len and pat_idx < pattern.len) {
        if (pattern[pat_idx] == '*') {
            // Skip consecutive wildcards
            while (pat_idx < pattern.len and pattern[pat_idx] == '*') {
                pat_idx += 1;
            }
            if (pat_idx == pattern.len) return true;

            // Try to match rest of pattern
            while (str_idx < str.len) {
                if (matchesPattern(str[str_idx..], pattern[pat_idx..])) {
                    return true;
                }
                str_idx += 1;
            }
            return false;
        } else if (pattern[pat_idx] == '?' or pattern[pat_idx] == str[str_idx]) {
            str_idx += 1;
            pat_idx += 1;
        } else {
            return false;
        }
    }

    // Handle trailing wildcards
    while (pat_idx < pattern.len and pattern[pat_idx] == '*') {
        pat_idx += 1;
    }

    return str_idx == str.len and pat_idx == pattern.len;
}

// Tool discovery result
pub const DiscoveryResult = struct {
    tools: []Tool.ToolMetadata,
    errors: []const DiscoveryError,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DiscoveryResult) void {
        self.allocator.free(self.tools);
        self.allocator.free(self.errors);
    }
};

pub const DiscoveryError = struct {
    path: []const u8,
    message: []const u8,
};

test "tool registry" {
    const allocator = std.testing.allocator;

    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    // Test discovery with empty registry
    const tools = try registry.discover();
    defer allocator.free(tools);
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

test "tool registry with filter" {
    const allocator = std.testing.allocator;

    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    // Create test metadata
    const schema = @import("schema/validator.zig");
    var input_schema = schema.Schema.init(allocator, .{ .object = .{
        .properties = std.StringHashMap(schema.SchemaNode).init(allocator),
        .required = &[_][]const u8{},
        .additional_properties = true,
    } });
    defer input_schema.deinit();

    var output_schema = schema.Schema.init(allocator, .{ .string = .{} });
    defer output_schema.deinit();

    // Register a test tool
    const test_factory = struct {
        fn create(alloc: std.mem.Allocator) !*Tool {
            _ = alloc;
            return error.NotImplemented;
        }
    }.create;

    try registry.registerBuiltinTool(.{
        .name = "test_tool",
        .description = "A test tool",
        .input_schema = input_schema,
        .output_schema = output_schema,
        .category = .utility,
        .tags = &[_][]const u8{ "test", "example" },
    }, test_factory);

    // Test filter by category
    const filter = ToolFilter{
        .category = .utility,
    };
    const filtered_tools = try registry.discoverWithFilter(filter);
    defer allocator.free(filtered_tools);

    try std.testing.expectEqual(@as(usize, 1), filtered_tools.len);
    try std.testing.expectEqualStrings("test_tool", filtered_tools[0].name);
}

test "pattern matching" {
    try std.testing.expect(matchesPattern("hello", "hello"));
    try std.testing.expect(matchesPattern("hello", "h*o"));
    try std.testing.expect(matchesPattern("hello", "h?llo"));
    try std.testing.expect(matchesPattern("hello_world", "*world"));
    try std.testing.expect(matchesPattern("hello_world", "hello*"));
    try std.testing.expect(matchesPattern("hello_world", "*_*"));

    try std.testing.expect(!matchesPattern("hello", "hi"));
    try std.testing.expect(!matchesPattern("hello", "h?lo"));
    try std.testing.expect(!matchesPattern("hello", "*world"));
}
