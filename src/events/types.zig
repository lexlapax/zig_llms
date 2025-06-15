// ABOUTME: Event types and structures for the event system
// ABOUTME: Provides serializable event definitions with metadata and payload support

const std = @import("std");

// Event severity levels
pub const EventSeverity = enum(u8) {
    debug = 0,
    info = 1,
    warning = 2,
    @"error" = 3,
    critical = 4,
    
    pub fn toString(self: EventSeverity) []const u8 {
        return @tagName(self);
    }
    
    pub fn fromString(str: []const u8) ?EventSeverity {
        return std.meta.stringToEnum(EventSeverity, str);
    }
};

// Event categories
pub const EventCategory = enum {
    agent,
    provider,
    tool,
    workflow,
    memory,
    system,
    network,
    security,
    performance,
    custom,
    
    pub fn toString(self: EventCategory) []const u8 {
        return @tagName(self);
    }
};

// Event metadata
pub const EventMetadata = struct {
    timestamp: i64,
    source: []const u8,
    correlation_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    tags: []const []const u8 = &[_][]const u8{},
    custom: ?std.json.Value = null,
    
    pub fn deinit(self: *EventMetadata, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Metadata fields are managed by the event owner
    }
    
    pub fn toJson(self: *const EventMetadata, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        errdefer obj.deinit();
        
        try obj.put("timestamp", .{ .integer = self.timestamp });
        try obj.put("source", .{ .string = self.source });
        
        if (self.correlation_id) |id| {
            try obj.put("correlation_id", .{ .string = id });
        }
        
        if (self.user_id) |id| {
            try obj.put("user_id", .{ .string = id });
        }
        
        if (self.session_id) |id| {
            try obj.put("session_id", .{ .string = id });
        }
        
        var tags_array = std.json.Array.init(allocator);
        for (self.tags) |tag| {
            try tags_array.append(.{ .string = tag });
        }
        try obj.put("tags", .{ .array = tags_array });
        
        if (self.custom) |custom| {
            try obj.put("custom", custom);
        }
        
        return .{ .object = obj };
    }
};

// Base event structure
pub const Event = struct {
    id: []const u8,
    name: []const u8,
    category: EventCategory,
    severity: EventSeverity,
    metadata: EventMetadata,
    payload: std.json.Value,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        category: EventCategory,
        severity: EventSeverity,
        source: []const u8,
        payload: std.json.Value,
    ) !Event {
        const id = try generateEventId(allocator);
        
        return Event{
            .id = id,
            .name = name,
            .category = category,
            .severity = severity,
            .metadata = EventMetadata{
                .timestamp = std.time.milliTimestamp(),
                .source = source,
            },
            .payload = payload,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Event) void {
        self.allocator.free(self.id);
        self.metadata.deinit(self.allocator);
        // Payload is managed externally
    }
    
    pub fn toJson(self: *const Event) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        try obj.put("id", .{ .string = self.id });
        try obj.put("name", .{ .string = self.name });
        try obj.put("category", .{ .string = self.category.toString() });
        try obj.put("severity", .{ .string = self.severity.toString() });
        try obj.put("metadata", try self.metadata.toJson(self.allocator));
        try obj.put("payload", self.payload);
        
        return .{ .object = obj };
    }
    
    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Event {
        if (value != .object) return error.InvalidFormat;
        
        const obj = value.object;
        
        const id = if (obj.get("id")) |v| v.string else return error.MissingField;
        const name = if (obj.get("name")) |v| v.string else return error.MissingField;
        
        const category_str = if (obj.get("category")) |v| v.string else return error.MissingField;
        const category = std.meta.stringToEnum(EventCategory, category_str) orelse return error.InvalidCategory;
        
        const severity_str = if (obj.get("severity")) |v| v.string else return error.MissingField;
        const severity = std.meta.stringToEnum(EventSeverity, severity_str) orelse return error.InvalidSeverity;
        
        const metadata_obj = if (obj.get("metadata")) |v| v else return error.MissingField;
        const metadata = try parseMetadata(allocator, metadata_obj);
        
        const payload = if (obj.get("payload")) |v| v else .{ .null = {} };
        
        return Event{
            .id = try allocator.dupe(u8, id),
            .name = name,
            .category = category,
            .severity = severity,
            .metadata = metadata,
            .payload = payload,
            .allocator = allocator,
        };
    }
    
    pub fn clone(self: *const Event, allocator: std.mem.Allocator) !Event {
        return Event{
            .id = try allocator.dupe(u8, self.id),
            .name = self.name,
            .category = self.category,
            .severity = self.severity,
            .metadata = self.metadata, // Shallow copy
            .payload = self.payload, // Shallow copy
            .allocator = allocator,
        };
    }
    
    pub fn withCorrelationId(self: *Event, correlation_id: []const u8) *Event {
        self.metadata.correlation_id = correlation_id;
        return self;
    }
    
    pub fn withUserId(self: *Event, user_id: []const u8) *Event {
        self.metadata.user_id = user_id;
        return self;
    }
    
    pub fn withSessionId(self: *Event, session_id: []const u8) *Event {
        self.metadata.session_id = session_id;
        return self;
    }
    
    pub fn withTags(self: *Event, tags: []const []const u8) *Event {
        self.metadata.tags = tags;
        return self;
    }
    
    pub fn withCustomMetadata(self: *Event, custom: std.json.Value) *Event {
        self.metadata.custom = custom;
        return self;
    }
};

// Event builder for fluent API
pub const EventBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    category: EventCategory = .custom,
    severity: EventSeverity = .info,
    source: []const u8,
    payload: std.json.Value = .{ .null = {} },
    correlation_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    tags: std.ArrayList([]const u8),
    custom_metadata: ?std.json.Value = null,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, source: []const u8) EventBuilder {
        return .{
            .allocator = allocator,
            .name = name,
            .source = source,
            .tags = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *EventBuilder) void {
        self.tags.deinit();
    }
    
    pub fn withCategory(self: *EventBuilder, category: EventCategory) *EventBuilder {
        self.category = category;
        return self;
    }
    
    pub fn withSeverity(self: *EventBuilder, severity: EventSeverity) *EventBuilder {
        self.severity = severity;
        return self;
    }
    
    pub fn withPayload(self: *EventBuilder, payload: std.json.Value) *EventBuilder {
        self.payload = payload;
        return self;
    }
    
    pub fn withCorrelationId(self: *EventBuilder, id: []const u8) *EventBuilder {
        self.correlation_id = id;
        return self;
    }
    
    pub fn withUserId(self: *EventBuilder, id: []const u8) *EventBuilder {
        self.user_id = id;
        return self;
    }
    
    pub fn withSessionId(self: *EventBuilder, id: []const u8) *EventBuilder {
        self.session_id = id;
        return self;
    }
    
    pub fn addTag(self: *EventBuilder, tag: []const u8) !*EventBuilder {
        try self.tags.append(tag);
        return self;
    }
    
    pub fn withCustomMetadata(self: *EventBuilder, metadata: std.json.Value) *EventBuilder {
        self.custom_metadata = metadata;
        return self;
    }
    
    pub fn build(self: *EventBuilder) !Event {
        var event = try Event.init(
            self.allocator,
            self.name,
            self.category,
            self.severity,
            self.source,
            self.payload,
        );
        
        event.metadata.correlation_id = self.correlation_id;
        event.metadata.user_id = self.user_id;
        event.metadata.session_id = self.session_id;
        event.metadata.tags = try self.tags.toOwnedSlice();
        event.metadata.custom = self.custom_metadata;
        
        return event;
    }
};

// Common event types
pub const AgentEvent = struct {
    pub fn started(allocator: std.mem.Allocator, agent_id: []const u8, agent_type: []const u8) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("agent_id", .{ .string = agent_id });
        try payload.put("agent_type", .{ .string = agent_type });
        
        return Event.init(
            allocator,
            "agent.started",
            .agent,
            .info,
            agent_id,
            .{ .object = payload },
        );
    }
    
    pub fn completed(allocator: std.mem.Allocator, agent_id: []const u8, duration_ms: u64) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("agent_id", .{ .string = agent_id });
        try payload.put("duration_ms", .{ .integer = @as(i64, @intCast(duration_ms)) });
        
        return Event.init(
            allocator,
            "agent.completed",
            .agent,
            .info,
            agent_id,
            .{ .object = payload },
        );
    }
    
    pub fn failed(allocator: std.mem.Allocator, agent_id: []const u8, error_message: []const u8) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("agent_id", .{ .string = agent_id });
        try payload.put("error_message", .{ .string = error_message });
        
        return Event.init(
            allocator,
            "agent.failed",
            .agent,
            .@"error",
            agent_id,
            .{ .object = payload },
        );
    }
};

pub const ToolEvent = struct {
    pub fn invoked(allocator: std.mem.Allocator, tool_name: []const u8, input: std.json.Value) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("tool_name", .{ .string = tool_name });
        try payload.put("input", input);
        
        return Event.init(
            allocator,
            "tool.invoked",
            .tool,
            .info,
            tool_name,
            .{ .object = payload },
        );
    }
    
    pub fn succeeded(allocator: std.mem.Allocator, tool_name: []const u8, output: std.json.Value, duration_ms: u64) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("tool_name", .{ .string = tool_name });
        try payload.put("output", output);
        try payload.put("duration_ms", .{ .integer = @as(i64, @intCast(duration_ms)) });
        
        return Event.init(
            allocator,
            "tool.succeeded",
            .tool,
            .info,
            tool_name,
            .{ .object = payload },
        );
    }
    
    pub fn failed(allocator: std.mem.Allocator, tool_name: []const u8, error_message: []const u8) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("tool_name", .{ .string = tool_name });
        try payload.put("error_message", .{ .string = error_message });
        
        return Event.init(
            allocator,
            "tool.failed",
            .tool,
            .@"error",
            tool_name,
            .{ .object = payload },
        );
    }
};

pub const WorkflowEvent = struct {
    pub fn stepStarted(allocator: std.mem.Allocator, workflow_id: []const u8, step_id: []const u8) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("workflow_id", .{ .string = workflow_id });
        try payload.put("step_id", .{ .string = step_id });
        
        return Event.init(
            allocator,
            "workflow.step_started",
            .workflow,
            .info,
            workflow_id,
            .{ .object = payload },
        );
    }
    
    pub fn stepCompleted(allocator: std.mem.Allocator, workflow_id: []const u8, step_id: []const u8, result: std.json.Value) !Event {
        var payload = std.json.ObjectMap.init(allocator);
        try payload.put("workflow_id", .{ .string = workflow_id });
        try payload.put("step_id", .{ .string = step_id });
        try payload.put("result", result);
        
        return Event.init(
            allocator,
            "workflow.step_completed",
            .workflow,
            .info,
            workflow_id,
            .{ .object = payload },
        );
    }
};

// Helper functions
fn generateEventId(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = @as(u64, @intCast(std.time.microTimestamp()));
    var rng = std.Random.DefaultPrng.init(timestamp);
    const random = rng.random().int(u32);
    
    return std.fmt.allocPrint(allocator, "{x}-{x}", .{ timestamp, random });
}

fn parseMetadata(allocator: std.mem.Allocator, value: std.json.Value) !EventMetadata {
    _ = allocator;
    
    if (value != .object) return error.InvalidFormat;
    const obj = value.object;
    
    const timestamp = if (obj.get("timestamp")) |v| v.integer else std.time.milliTimestamp();
    const source = if (obj.get("source")) |v| v.string else "unknown";
    
    return EventMetadata{
        .timestamp = timestamp,
        .source = source,
        .correlation_id = if (obj.get("correlation_id")) |v| v.string else null,
        .user_id = if (obj.get("user_id")) |v| v.string else null,
        .session_id = if (obj.get("session_id")) |v| v.string else null,
        .tags = &[_][]const u8{}, // TODO: Parse tags array
        .custom = if (obj.get("custom")) |v| v else null,
    };
}

// Tests
test "event creation" {
    const allocator = std.testing.allocator;
    
    var payload = std.json.ObjectMap.init(allocator);
    defer payload.deinit();
    try payload.put("test", .{ .string = "value" });
    
    var event = try Event.init(
        allocator,
        "test.event",
        .custom,
        .info,
        "test_source",
        .{ .object = payload },
    );
    defer event.deinit();
    
    try std.testing.expectEqualStrings("test.event", event.name);
    try std.testing.expectEqual(EventCategory.custom, event.category);
    try std.testing.expectEqual(EventSeverity.info, event.severity);
    try std.testing.expectEqualStrings("test_source", event.metadata.source);
}

test "event builder" {
    const allocator = std.testing.allocator;
    
    var builder = EventBuilder.init(allocator, "test.built", "builder_source");
    defer builder.deinit();
    
    _ = try builder.withCategory(.agent)
        .withSeverity(.warning)
        .withCorrelationId("corr-123")
        .addTag("test-tag");
    
    var event = try builder.build();
    defer event.deinit();
    
    try std.testing.expectEqualStrings("test.built", event.name);
    try std.testing.expectEqual(EventCategory.agent, event.category);
    try std.testing.expectEqual(EventSeverity.warning, event.severity);
    try std.testing.expectEqualStrings("corr-123", event.metadata.correlation_id.?);
    try std.testing.expectEqual(@as(usize, 1), event.metadata.tags.len);
}

test "event serialization" {
    const allocator = std.testing.allocator;
    
    var event = try AgentEvent.started(allocator, "agent-123", "LLMAgent");
    defer event.deinit();
    
    const json = try event.toJson();
    
    // Basic validation
    try std.testing.expect(json == .object);
    try std.testing.expect(json.object.contains("id"));
    try std.testing.expect(json.object.contains("name"));
    try std.testing.expect(json.object.contains("metadata"));
    try std.testing.expect(json.object.contains("payload"));
}