// ABOUTME: Tool persistence for saving and loading tool configurations and state
// ABOUTME: Supports JSON, binary formats, and tool state snapshots

const std = @import("std");
const tool_mod = @import("../tool.zig");
const Tool = tool_mod.Tool;
const registry_mod = @import("../tool_registry.zig");
const ToolRegistry = registry_mod.ToolRegistry;
const ToolInfo = registry_mod.ToolInfo;

// Tool state that can be persisted
pub const ToolState = struct {
    metadata: Tool.ToolMetadata,
    config: ?std.json.Value = null,
    statistics: ToolStatistics = .{},
    last_used: ?i64 = null,
    custom_data: ?std.json.Value = null,
    
    pub const ToolStatistics = struct {
        execution_count: u64 = 0,
        success_count: u64 = 0,
        failure_count: u64 = 0,
        total_execution_time_ms: u64 = 0,
        average_execution_time_ms: u64 = 0,
    };
};

// Persistence format
pub const PersistenceFormat = enum {
    json,
    binary,
    compressed,
};

// Tool persister
pub const ToolPersister = struct {
    allocator: std.mem.Allocator,
    format: PersistenceFormat = .json,
    compress: bool = false,
    
    pub fn init(allocator: std.mem.Allocator) ToolPersister {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn saveRegistry(self: *ToolPersister, registry: *ToolRegistry, writer: anytype) !void {
        switch (self.format) {
            .json => try self.saveRegistryJson(registry, writer),
            .binary => try self.saveRegistryBinary(registry, writer),
            .compressed => {
                // TODO: Implement compression
                try self.saveRegistryBinary(registry, writer);
            },
        }
    }
    
    pub fn loadRegistry(self: *ToolPersister, registry: *ToolRegistry, reader: anytype) !void {
        switch (self.format) {
            .json => try self.loadRegistryJson(registry, reader),
            .binary => try self.loadRegistryBinary(registry, reader),
            .compressed => {
                // TODO: Implement decompression
                try self.loadRegistryBinary(registry, reader);
            },
        }
    }
    
    fn saveRegistryJson(self: *ToolPersister, registry: *ToolRegistry, writer: anytype) !void {
        var root = std.json.ObjectMap.init(self.allocator);
        defer root.deinit();
        
        // Save version info
        try root.put("version", .{ .string = "1.0" });
        try root.put("format", .{ .string = "json" });
        
        // Save tools
        var tools_array = std.json.Array.init(self.allocator);
        defer tools_array.deinit();
        
        registry.mutex.lock();
        defer registry.mutex.unlock();
        
        // Save dynamic tools
        var iter = registry.dynamic_tools.iterator();
        while (iter.next()) |entry| {
            const tool_data = try self.toolInfoToJson(entry.value_ptr.*);
            try tools_array.append(tool_data);
        }
        
        try root.put("tools", .{ .array = tools_array });
        
        // Write JSON
        try std.json.stringify(.{ .object = root }, .{ .whitespace = .indent_2 }, writer);
    }
    
    fn loadRegistryJson(self: *ToolPersister, _: *ToolRegistry, reader: anytype) !void {
        const content = try reader.readAllAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);
        
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();
        
        if (parsed.value != .object) return error.InvalidFormat;
        
        const root = parsed.value.object;
        
        // Check version
        if (root.get("version")) |version| {
            if (version != .string or !std.mem.eql(u8, version.string, "1.0")) {
                return error.UnsupportedVersion;
            }
        }
        
        // Load tools
        if (root.get("tools")) |tools| {
            if (tools != .array) return error.InvalidFormat;
            
            for (tools.array.items) |tool_data| {
                const tool_info = try self.jsonToToolInfo(tool_data);
                // TODO: Register the tool with the registry
                _ = tool_info;
            }
        }
    }
    
    fn saveRegistryBinary(self: *ToolPersister, registry: *ToolRegistry, writer: anytype) !void {
        // Binary format header
        try writer.writeAll("ZLMT"); // ZigLLMs Tool
        try writer.writeInt(u32, 1, .little); // Version
        
        registry.mutex.lock();
        defer registry.mutex.unlock();
        
        // Write tool count
        const tool_count = registry.dynamic_tools.count();
        try writer.writeInt(u32, @intCast(tool_count), .little);
        
        // Write each tool
        var iter = registry.dynamic_tools.iterator();
        while (iter.next()) |entry| {
            try self.writeToolInfoBinary(entry.value_ptr.*, writer);
        }
    }
    
    fn loadRegistryBinary(self: *ToolPersister, _: *ToolRegistry, reader: anytype) !void {
        // Read header
        var magic: [4]u8 = undefined;
        _ = try reader.read(&magic);
        if (!std.mem.eql(u8, &magic, "ZLMT")) {
            return error.InvalidFormat;
        }
        
        const version = try reader.readInt(u32, .little);
        if (version != 1) {
            return error.UnsupportedVersion;
        }
        
        // Read tool count
        const tool_count = try reader.readInt(u32, .little);
        
        // Read each tool
        var i: u32 = 0;
        while (i < tool_count) : (i += 1) {
            const tool_info = try self.readToolInfoBinary(reader);
            // TODO: Register the tool with the registry
            _ = tool_info;
        }
    }
    
    fn toolInfoToJson(self: *ToolPersister, info: ToolInfo) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        
        try obj.put("name", .{ .string = info.metadata.name });
        try obj.put("description", .{ .string = info.metadata.description });
        try obj.put("version", .{ .string = info.metadata.version });
        
        if (info.metadata.author) |author| {
            try obj.put("author", .{ .string = author });
        }
        
        if (info.metadata.category) |cat| {
            try obj.put("category", .{ .string = @tagName(cat) });
        }
        
        // Tags
        var tags_array = std.json.Array.init(self.allocator);
        for (info.metadata.tags) |tag| {
            try tags_array.append(.{ .string = tag });
        }
        try obj.put("tags", .{ .array = tags_array });
        
        // Capabilities
        try obj.put("requires_network", .{ .bool = info.metadata.requires_network });
        try obj.put("requires_filesystem", .{ .bool = info.metadata.requires_filesystem });
        
        if (info.metadata.timeout_ms) |timeout| {
            try obj.put("timeout_ms", .{ .integer = @intCast(timeout) });
        }
        
        // Additional info
        try obj.put("lazy_load", .{ .bool = info.lazy_load });
        if (info.external_path) |path| {
            try obj.put("external_path", .{ .string = path });
        }
        
        return .{ .object = obj };
    }
    
    fn jsonToToolInfo(self: *ToolPersister, value: std.json.Value) !ToolInfo {
        if (value != .object) return error.InvalidFormat;
        
        const obj = value.object;
        
        // Extract metadata fields
        const name = if (obj.get("name")) |n| n.string else return error.MissingField;
        const description = if (obj.get("description")) |d| d.string else return error.MissingField;
        const version = if (obj.get("version")) |v| v.string else "1.0.0";
        
        // TODO: Create proper ToolInfo with metadata
        _ = self;
        _ = name;
        _ = description;
        _ = version;
        
        return error.NotImplemented;
    }
    
    fn writeToolInfoBinary(self: *ToolPersister, info: ToolInfo, writer: anytype) !void {
        // Write metadata
        try self.writeString(writer, info.metadata.name);
        try self.writeString(writer, info.metadata.description);
        try self.writeString(writer, info.metadata.version);
        
        // Write optional fields
        try self.writeOptionalString(writer, info.metadata.author);
        
        // Write category
        if (info.metadata.category) |cat| {
            try writer.writeByte(1); // Has category
            try writer.writeByte(@intFromEnum(cat));
        } else {
            try writer.writeByte(0); // No category
        }
        
        // Write capabilities
        try writer.writeByte(@intFromBool(info.metadata.requires_network));
        try writer.writeByte(@intFromBool(info.metadata.requires_filesystem));
        
        // Write additional info
        try writer.writeByte(@intFromBool(info.lazy_load));
        try self.writeOptionalString(writer, info.external_path);
    }
    
    fn readToolInfoBinary(self: *ToolPersister, reader: anytype) !ToolInfo {
        // Read metadata
        const name = try self.readString(reader);
        const description = try self.readString(reader);
        const version = try self.readString(reader);
        
        // Read optional fields
        const author = try self.readOptionalString(reader);
        
        // Read category
        const has_category = try reader.readByte();
        const category = if (has_category == 1) blk: {
            const cat_byte = try reader.readByte();
            break :blk @as(tool_mod.ToolCategory, @enumFromInt(cat_byte));
        } else null;
        
        // Read capabilities
        const requires_network = (try reader.readByte()) != 0;
        const requires_filesystem = (try reader.readByte()) != 0;
        
        // Read additional info
        const lazy_load = (try reader.readByte()) != 0;
        const external_path = try self.readOptionalString(reader);
        
        // TODO: Create proper ToolInfo
        _ = name;
        _ = description;
        _ = version;
        _ = author;
        _ = category;
        _ = requires_network;
        _ = requires_filesystem;
        _ = lazy_load;
        _ = external_path;
        
        return error.NotImplemented;
    }
    
    fn writeString(self: *ToolPersister, writer: anytype, str: []const u8) !void {
        _ = self;
        try writer.writeInt(u32, @intCast(str.len), .little);
        try writer.writeAll(str);
    }
    
    fn readString(self: *ToolPersister, reader: anytype) ![]const u8 {
        const len = try reader.readInt(u32, .little);
        const str = try self.allocator.alloc(u8, len);
        _ = try reader.read(str);
        return str;
    }
    
    fn writeOptionalString(self: *ToolPersister, writer: anytype, str: ?[]const u8) !void {
        if (str) |s| {
            try writer.writeByte(1);
            try self.writeString(writer, s);
        } else {
            try writer.writeByte(0);
        }
    }
    
    fn readOptionalString(self: *ToolPersister, reader: anytype) !?[]const u8 {
        const has_value = try reader.readByte();
        if (has_value == 1) {
            return try self.readString(reader);
        }
        return null;
    }
};

// Tool state manager for runtime persistence
pub const ToolStateManager = struct {
    states: std.StringHashMap(ToolState),
    allocator: std.mem.Allocator,
    auto_save: bool = true,
    save_path: ?[]const u8 = null,
    
    pub fn init(allocator: std.mem.Allocator) ToolStateManager {
        return .{
            .states = std.StringHashMap(ToolState).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ToolStateManager) void {
        if (self.auto_save and self.save_path != null) {
            self.saveToFile(self.save_path.?) catch {};
        }
        self.states.deinit();
    }
    
    pub fn updateState(self: *ToolStateManager, tool_name: []const u8, update_fn: *const fn (*ToolState) void) !void {
        const state = try self.states.getOrPut(tool_name);
        if (!state.found_existing) {
            state.value_ptr.* = ToolState{
                .metadata = undefined, // Should be set by caller
            };
        }
        update_fn(state.value_ptr);
        
        if (self.auto_save and self.save_path != null) {
            try self.saveToFile(self.save_path.?);
        }
    }
    
    pub fn getState(self: *ToolStateManager, tool_name: []const u8) ?*ToolState {
        return self.states.getPtr(tool_name);
    }
    
    pub fn recordExecution(self: *ToolStateManager, tool_name: []const u8, success: bool, execution_time_ms: u64) !void {
        try self.updateState(tool_name, struct {
            fn update(state: *ToolState) void {
                state.statistics.execution_count += 1;
                if (success) {
                    state.statistics.success_count += 1;
                } else {
                    state.statistics.failure_count += 1;
                }
                state.statistics.total_execution_time_ms += execution_time_ms;
                state.statistics.average_execution_time_ms = 
                    state.statistics.total_execution_time_ms / state.statistics.execution_count;
                state.last_used = std.time.timestamp();
            }
        }.update);
    }
    
    pub fn saveToFile(self: *ToolStateManager, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        
        var buffered_writer = std.io.bufferedWriter(file.writer());
        const writer = buffered_writer.writer();
        
        var persister = ToolPersister.init(self.allocator);
        persister.format = .json;
        
        // Convert states to JSON
        var root = std.json.ObjectMap.init(self.allocator);
        defer root.deinit();
        
        var states_obj = std.json.ObjectMap.init(self.allocator);
        
        var iter = self.states.iterator();
        while (iter.next()) |entry| {
            const state_json = try self.stateToJson(entry.value_ptr.*);
            try states_obj.put(entry.key_ptr.*, state_json);
        }
        
        try root.put("states", .{ .object = states_obj });
        try root.put("timestamp", .{ .integer = std.time.timestamp() });
        
        try std.json.stringify(.{ .object = root }, .{ .whitespace = .indent_2 }, writer);
        try buffered_writer.flush();
    }
    
    fn stateToJson(self: *ToolStateManager, state: ToolState) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        
        // Statistics
        var stats_obj = std.json.ObjectMap.init(self.allocator);
        try stats_obj.put("execution_count", .{ .integer = @intCast(state.statistics.execution_count) });
        try stats_obj.put("success_count", .{ .integer = @intCast(state.statistics.success_count) });
        try stats_obj.put("failure_count", .{ .integer = @intCast(state.statistics.failure_count) });
        try stats_obj.put("total_execution_time_ms", .{ .integer = @intCast(state.statistics.total_execution_time_ms) });
        try stats_obj.put("average_execution_time_ms", .{ .integer = @intCast(state.statistics.average_execution_time_ms) });
        try obj.put("statistics", .{ .object = stats_obj });
        
        if (state.last_used) |last| {
            try obj.put("last_used", .{ .integer = last });
        }
        
        if (state.config) |config| {
            try obj.put("config", config);
        }
        
        if (state.custom_data) |data| {
            try obj.put("custom_data", data);
        }
        
        return .{ .object = obj };
    }
};

// Tests
test "tool state manager" {
    const allocator = std.testing.allocator;
    
    var manager = ToolStateManager.init(allocator);
    defer manager.deinit();
    
    // Record some executions
    try manager.recordExecution("test_tool", true, 100);
    try manager.recordExecution("test_tool", true, 150);
    try manager.recordExecution("test_tool", false, 200);
    
    // Check state
    const state = manager.getState("test_tool").?;
    try std.testing.expectEqual(@as(u64, 3), state.statistics.execution_count);
    try std.testing.expectEqual(@as(u64, 2), state.statistics.success_count);
    try std.testing.expectEqual(@as(u64, 1), state.statistics.failure_count);
    try std.testing.expectEqual(@as(u64, 150), state.statistics.average_execution_time_ms);
}