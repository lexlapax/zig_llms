// ABOUTME: Complex type marshaling between zig_llms structures and script values
// ABOUTME: Handles conversion of agents, tools, workflows, and other complex types

const std = @import("std");
const ScriptValue = @import("value_bridge.zig").ScriptValue;

// Import zig_llms types (these will be available when integrated)
// For now, we define placeholder types for the marshaler design
const AgentConfig = struct {
    name: []const u8,
    provider: []const u8,
    model: []const u8,
    temperature: f32 = 0.7,
    max_tokens: u32 = 1000,
    tools: []const []const u8 = &[_][]const u8{},
};

const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    schema: ?std.json.Value = null,
    execute: ?*const fn (input: std.json.Value) anyerror!std.json.Value = null,
};

const WorkflowStep = struct {
    name: []const u8,
    agent: []const u8,
    action: []const u8,
    params: std.json.Value,
    depends_on: []const []const u8 = &[_][]const u8{},
};

const ProviderConfig = struct {
    name: []const u8,
    type: []const u8,
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    models: []const []const u8 = &[_][]const u8{},
    timeout: u32 = 30000,
};

const EventData = struct {
    event_type: []const u8,
    timestamp: i64,
    data: std.json.Value,
};

const TestScenario = struct {
    name: []const u8,
    fixtures: std.json.Value,
    tests: []const TestCase,
    
    const TestCase = struct {
        name: []const u8,
        input: std.json.Value,
        expected: std.json.Value,
    };
};

/// Type marshaler for complex zig_llms structures
pub const TypeMarshaler = struct {
    
    /// Marshal AgentConfig from ScriptValue
    pub fn marshalAgentConfig(value: ScriptValue, allocator: std.mem.Allocator) !AgentConfig {
        switch (value) {
            .object => |obj| {
                var config = AgentConfig{
                    .name = "",
                    .provider = "",
                    .model = "",
                };
                
                // Required fields
                if (obj.get("name")) |name| {
                    config.name = try name.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("provider")) |provider| {
                    config.provider = try provider.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("model")) |model| {
                    config.model = try model.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                // Optional fields
                if (obj.get("temperature")) |temp| {
                    config.temperature = try temp.toZig(f32, allocator);
                }
                
                if (obj.get("max_tokens")) |tokens| {
                    config.max_tokens = try tokens.toZig(u32, allocator);
                }
                
                if (obj.get("tools")) |tools| {
                    config.tools = try marshalStringArray(tools, allocator);
                }
                
                return config;
            },
            else => return error.TypeMismatch,
        }
    }
    
    /// Marshal ToolDefinition from ScriptValue
    pub fn marshalToolDefinition(value: ScriptValue, allocator: std.mem.Allocator) !ToolDefinition {
        switch (value) {
            .object => |obj| {
                var def = ToolDefinition{
                    .name = "",
                    .description = "",
                };
                
                if (obj.get("name")) |name| {
                    def.name = try name.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("description")) |desc| {
                    def.description = try desc.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("schema")) |schema| {
                    def.schema = try marshalJsonValue(schema, allocator);
                }
                
                // Note: Function callbacks require special handling per engine
                
                return def;
            },
            else => return error.TypeMismatch,
        }
    }
    
    /// Marshal WorkflowStep from ScriptValue
    pub fn marshalWorkflowStep(value: ScriptValue, allocator: std.mem.Allocator) !WorkflowStep {
        switch (value) {
            .object => |obj| {
                var step = WorkflowStep{
                    .name = "",
                    .agent = "",
                    .action = "",
                    .params = std.json.Value.null,
                };
                
                if (obj.get("name")) |name| {
                    step.name = try name.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("agent")) |agent| {
                    step.agent = try agent.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("action")) |action| {
                    step.action = try action.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("params")) |params| {
                    step.params = try marshalJsonValue(params, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("depends_on")) |deps| {
                    step.depends_on = try marshalStringArray(deps, allocator);
                }
                
                return step;
            },
            else => return error.TypeMismatch,
        }
    }
    
    /// Unmarshal response to ScriptValue
    pub fn unmarshalResponse(response: anytype, allocator: std.mem.Allocator) !ScriptValue {
        const T = @TypeOf(response);
        return ScriptValue.fromZig(T, response, allocator);
    }
    
    /// Marshal array of strings
    fn marshalStringArray(value: ScriptValue, allocator: std.mem.Allocator) ![]const []const u8 {
        switch (value) {
            .array => |arr| {
                var result = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    result[i] = try item.toZig([]const u8, allocator);
                }
                return result;
            },
            else => return error.TypeMismatch,
        }
    }
    
    /// Convert ScriptValue to JSON value
    pub fn marshalJsonValue(value: ScriptValue, allocator: std.mem.Allocator) !std.json.Value {
        return switch (value) {
            .nil => std.json.Value.null,
            .boolean => |b| std.json.Value{ .bool = b },
            .integer => |i| std.json.Value{ .integer = i },
            .number => |n| std.json.Value{ .float = n },
            .string => |s| std.json.Value{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                var json_array = std.json.Array.init(allocator);
                for (arr.items) |item| {
                    try json_array.append(try marshalJsonValue(item, allocator));
                }
                break :blk std.json.Value{ .array = json_array };
            },
            .object => |obj| blk: {
                var json_obj = std.json.ObjectMap.init(allocator);
                var iter = obj.map.iterator();
                while (iter.next()) |entry| {
                    const key = try allocator.dupe(u8, entry.key_ptr.*);
                    const val = try marshalJsonValue(entry.value_ptr.*, allocator);
                    try json_obj.put(key, val);
                }
                break :blk std.json.Value{ .object = json_obj };
            },
            .function => return error.CannotMarshalFunction,
            .userdata => return error.CannotMarshalUserdata,
        };
    }
    
    /// Convert JSON value to ScriptValue
    pub fn unmarshalJsonValue(json: std.json.Value, allocator: std.mem.Allocator) !ScriptValue {
        return switch (json) {
            .null => ScriptValue.nil,
            .bool => |b| ScriptValue{ .boolean = b },
            .integer => |i| ScriptValue{ .integer = i },
            .float => |f| ScriptValue{ .number = f },
            .string => |s| ScriptValue{ .string = try allocator.dupe(u8, s) },
            .array => |arr| blk: {
                var script_array = try ScriptValue.Array.init(allocator, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    script_array.items[i] = try unmarshalJsonValue(item, allocator);
                }
                break :blk ScriptValue{ .array = script_array };
            },
            .object => |obj| blk: {
                var script_obj = ScriptValue.Object.init(allocator);
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const val = try unmarshalJsonValue(entry.value_ptr.*, allocator);
                    try script_obj.put(entry.key_ptr.*, val);
                }
                break :blk ScriptValue{ .object = script_obj };
            },
            .number_string => |s| blk: {
                const num = try std.fmt.parseFloat(f64, s);
                break :blk ScriptValue{ .number = num };
            },
        };
    }
    
    /// Marshal provider configuration
    pub fn marshalProviderConfig(value: ScriptValue, allocator: std.mem.Allocator) !ProviderConfig {
        switch (value) {
            .object => |obj| {
                var config = ProviderConfig{
                    .name = "",
                    .type = "",
                };
                
                if (obj.get("name")) |name| {
                    config.name = try name.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("type")) |provider_type| {
                    config.type = try provider_type.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("base_url")) |url| {
                    config.base_url = try url.toZig([]const u8, allocator);
                }
                
                if (obj.get("api_key")) |key| {
                    config.api_key = try key.toZig([]const u8, allocator);
                }
                
                if (obj.get("models")) |models| {
                    config.models = try marshalStringArray(models, allocator);
                }
                
                if (obj.get("timeout")) |timeout| {
                    config.timeout = try timeout.toZig(u32, allocator);
                }
                
                return config;
            },
            else => return error.TypeMismatch,
        }
    }
    
    /// Marshal event data
    pub fn marshalEventData(value: ScriptValue, allocator: std.mem.Allocator) !EventData {
        switch (value) {
            .object => |obj| {
                var event = EventData{
                    .event_type = "",
                    .timestamp = std.time.milliTimestamp(),
                    .data = std.json.Value.null,
                };
                
                if (obj.get("event_type")) |event_type| {
                    event.event_type = try event_type.toZig([]const u8, allocator);
                } else {
                    return error.MissingField;
                }
                
                if (obj.get("timestamp")) |ts| {
                    event.timestamp = try ts.toZig(i64, allocator);
                }
                
                if (obj.get("data")) |data| {
                    event.data = try marshalJsonValue(data, allocator);
                }
                
                return event;
            },
            else => return error.TypeMismatch,
        }
    }
};

// Tests
test "TypeMarshaler AgentConfig" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var obj = ScriptValue.Object.init(allocator);
    defer obj.deinit();
    
    try obj.put("name", ScriptValue{ .string = try allocator.dupe(u8, "test_agent") });
    try obj.put("provider", ScriptValue{ .string = try allocator.dupe(u8, "openai") });
    try obj.put("model", ScriptValue{ .string = try allocator.dupe(u8, "gpt-4") });
    try obj.put("temperature", ScriptValue{ .number = 0.5 });
    try obj.put("max_tokens", ScriptValue{ .integer = 2000 });
    
    const value = ScriptValue{ .object = obj };
    const config = try TypeMarshaler.marshalAgentConfig(value, allocator);
    
    try testing.expectEqualStrings("test_agent", config.name);
    try testing.expectEqualStrings("openai", config.provider);
    try testing.expectEqualStrings("gpt-4", config.model);
    try testing.expectEqual(@as(f32, 0.5), config.temperature);
    try testing.expectEqual(@as(u32, 2000), config.max_tokens);
}

test "TypeMarshaler JSON conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a ScriptValue object
    var obj = ScriptValue.Object.init(allocator);
    defer obj.deinit();
    
    try obj.put("string", ScriptValue{ .string = try allocator.dupe(u8, "hello") });
    try obj.put("number", ScriptValue{ .integer = 42 });
    try obj.put("bool", ScriptValue{ .boolean = true });
    
    const script_val = ScriptValue{ .object = obj };
    
    // Convert to JSON
    const json_val = try TypeMarshaler.marshalJsonValue(script_val, allocator);
    defer json_val.object.deinit();
    
    try testing.expect(json_val == .object);
    try testing.expectEqualStrings("hello", json_val.object.get("string").?.string);
    try testing.expectEqual(@as(i64, 42), json_val.object.get("number").?.integer);
    try testing.expectEqual(true, json_val.object.get("bool").?.bool);
    
    // Convert back to ScriptValue
    const back = try TypeMarshaler.unmarshalJsonValue(json_val, allocator);
    defer back.deinit(allocator);
    
    try testing.expect(back == .object);
}