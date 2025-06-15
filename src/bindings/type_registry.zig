// ABOUTME: Type conversion registry for bridge-friendly type conversions
// ABOUTME: Centralizes conversions between Zig types and JSON for language bindings

const std = @import("std");
const types = @import("../types.zig");
const Schema = @import("../schema/validator.zig").Schema;

pub const TypeId = enum {
    message,
    schema,
    provider_config,
    tool_metadata,
    workflow_definition,
    error_info,
    custom,
};

pub const Converter = struct {
    to_json: *const fn (value: anytype, allocator: std.mem.Allocator) anyerror!std.json.Value,
    from_json: *const fn (json: std.json.Value, allocator: std.mem.Allocator) anyerror!anytype,
    can_reverse: bool = true,
};

pub const TypeRegistry = struct {
    converters: std.AutoHashMap(TypeId, Converter),
    custom_converters: std.StringHashMap(Converter),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TypeRegistry {
        return TypeRegistry{
            .converters = std.AutoHashMap(TypeId, Converter).init(allocator),
            .custom_converters = std.StringHashMap(Converter).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *TypeRegistry) void {
        self.converters.deinit();
        self.custom_converters.deinit();
    }
    
    pub fn registerConverter(self: *TypeRegistry, type_id: TypeId, converter: Converter) !void {
        try self.converters.put(type_id, converter);
    }
    
    pub fn registerCustomConverter(self: *TypeRegistry, name: []const u8, converter: Converter) !void {
        try self.custom_converters.put(name, converter);
    }
    
    pub fn toJSON(self: *TypeRegistry, type_id: TypeId, value: anytype) !std.json.Value {
        const converter = self.converters.get(type_id) orelse return error.ConverterNotFound;
        return converter.to_json(value, self.allocator);
    }
    
    pub fn fromJSON(self: *TypeRegistry, type_id: TypeId, json: std.json.Value, comptime T: type) !T {
        const converter = self.converters.get(type_id) orelse return error.ConverterNotFound;
        return converter.from_json(json, self.allocator);
    }
};

// Pre-defined converters
pub const messageConverter = Converter{
    .to_json = messageToJSON,
    .from_json = messageFromJSON,
};

fn messageToJSON(value: anytype, allocator: std.mem.Allocator) !std.json.Value {
    const message = @as(types.Message, value);
    
    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    
    try obj.put("role", std.json.Value{ .string = @tagName(message.role) });
    
    switch (message.content) {
        .text => |text| {
            try obj.put("content", std.json.Value{ .string = text });
        },
        .multimodal => |parts| {
            var parts_array = std.json.Array.init(allocator);
            defer parts_array.deinit();
            
            for (parts) |part| {
                var part_obj = std.json.ObjectMap.init(allocator);
                defer part_obj.deinit();
                
                switch (part) {
                    .text => |text| {
                        try part_obj.put("type", std.json.Value{ .string = "text" });
                        try part_obj.put("text", std.json.Value{ .string = text });
                    },
                    .image => |image| {
                        try part_obj.put("type", std.json.Value{ .string = "image" });
                        try part_obj.put("data", std.json.Value{ .string = image.data });
                        try part_obj.put("mime_type", std.json.Value{ .string = image.mime_type });
                    },
                    .file => |file| {
                        try part_obj.put("type", std.json.Value{ .string = "file" });
                        try part_obj.put("path", std.json.Value{ .string = file.path });
                        try part_obj.put("mime_type", std.json.Value{ .string = file.mime_type });
                    },
                }
                
                try parts_array.append(std.json.Value{ .object = part_obj });
            }
            
            try obj.put("content", std.json.Value{ .array = parts_array });
        },
    }
    
    if (message.metadata) |metadata| {
        try obj.put("metadata", metadata);
    }
    
    return std.json.Value{ .object = obj };
}

fn messageFromJSON(json: std.json.Value, allocator: std.mem.Allocator) !types.Message {
    _ = allocator;
    
    const obj = json.object;
    
    const role_str = obj.get("role").?.string;
    const role = std.meta.stringToEnum(types.Role, role_str) orelse return error.InvalidRole;
    
    var message = types.Message{
        .role = role,
        .content = undefined,
        .metadata = if (obj.get("metadata")) |m| m else null,
    };
    
    const content_value = obj.get("content").?;
    
    if (content_value == .string) {
        message.content = .{ .text = content_value.string };
    } else if (content_value == .array) {
        // TODO: Parse multimodal content
        return error.MultimodalNotImplemented;
    }
    
    return message;
}

// Initialize default registry with common converters
pub fn initDefaultRegistry(allocator: std.mem.Allocator) !TypeRegistry {
    var registry = TypeRegistry.init(allocator);
    
    try registry.registerConverter(.message, messageConverter);
    // TODO: Add more default converters
    
    return registry;
}

// C-API helper functions
export fn zig_llms_type_to_json(registry: *TypeRegistry, type_id: c_int, value_ptr: *anyopaque) ?[*:0]const u8 {
    const tid = @as(TypeId, @enumFromInt(type_id));
    
    const json_value = registry.toJSON(tid, value_ptr) catch return null;
    defer json_value.deinit();
    
    const json_string = std.json.stringifyAlloc(registry.allocator, json_value, .{}) catch return null;
    
    // Convert to null-terminated string
    const c_string = registry.allocator.allocSentinel(u8, json_string.len, 0) catch return null;
    @memcpy(c_string, json_string);
    registry.allocator.free(json_string);
    
    return c_string;
}

export fn zig_llms_type_from_json(registry: *TypeRegistry, type_id: c_int, json_str: [*:0]const u8) ?*anyopaque {
    const tid = @as(TypeId, @enumFromInt(type_id));
    const json = std.mem.span(json_str);
    
    const parsed = std.json.parseFromSlice(std.json.Value, registry.allocator, json, .{}) catch return null;
    defer parsed.deinit();
    
    // TODO: Implement type-specific allocation and conversion
    _ = tid;
    
    return null;
}