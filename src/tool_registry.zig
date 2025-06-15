// ABOUTME: Enhanced tool registry with dynamic registration and discovery
// ABOUTME: Supports lazy loading, persistence, and external tool callbacks

const std = @import("std");
const Tool = @import("tool.zig").Tool;

pub const ToolFactory = *const fn (allocator: std.mem.Allocator) anyerror!*Tool;

pub const ToolInfo = struct {
    metadata: Tool.ToolMetadata,
    factory: ToolFactory,
};

pub const ToolRegistry = struct {
    builtin_tools: std.StringHashMap(ToolInfo),
    dynamic_tools: std.StringHashMap(ToolInfo),
    instances: std.StringHashMap(*Tool),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return ToolRegistry{
            .builtin_tools = std.StringHashMap(ToolInfo).init(allocator),
            .dynamic_tools = std.StringHashMap(ToolInfo).init(allocator),
            .instances = std.StringHashMap(*Tool).init(allocator),
            .mutex = std.Thread.Mutex{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ToolRegistry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Clean up tool instances
        var iter = self.instances.iterator();
        while (iter.next()) |entry| {
            // TODO: Call tool cleanup
            self.allocator.destroy(entry.value_ptr.*);
        }
        
        self.builtin_tools.deinit();
        self.dynamic_tools.deinit();
        self.instances.deinit();
    }
    
    pub fn discover(self: *ToolRegistry) ![]Tool.ToolMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        var metadata_list = std.ArrayList(Tool.ToolMetadata).init(self.allocator);
        defer metadata_list.deinit();
        
        // Add builtin tools
        var builtin_iter = self.builtin_tools.iterator();
        while (builtin_iter.next()) |entry| {
            try metadata_list.append(entry.value_ptr.metadata);
        }
        
        // Add dynamic tools
        var dynamic_iter = self.dynamic_tools.iterator();
        while (dynamic_iter.next()) |entry| {
            try metadata_list.append(entry.value_ptr.metadata);
        }
        
        return metadata_list.toOwnedSlice();
    }
    
    pub fn create(self: *ToolRegistry, name: []const u8) !*Tool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Check if already instantiated
        if (self.instances.get(name)) |tool| {
            return tool;
        }
        
        // Look for tool info
        const info = self.builtin_tools.get(name) orelse
                    self.dynamic_tools.get(name) orelse
                    return error.ToolNotFound;
        
        // Create instance
        const tool = try info.factory(self.allocator);
        try self.instances.put(name, tool);
        
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
        
        // TODO: Implement loading from JSON
        _ = reader;
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