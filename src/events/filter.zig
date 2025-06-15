// ABOUTME: Event filtering system with composable filter expressions
// ABOUTME: Provides complex filtering capabilities for event selection and routing

const std = @import("std");
const types = @import("types.zig");
const Event = types.Event;
const EventCategory = types.EventCategory;
const EventSeverity = types.EventSeverity;

// Filter operators
pub const FilterOp = enum {
    eq,     // Equal
    ne,     // Not equal
    gt,     // Greater than
    gte,    // Greater than or equal
    lt,     // Less than
    lte,    // Less than or equal
    contains,
    starts_with,
    ends_with,
    matches, // Pattern match
    in,     // In list
    not_in, // Not in list
};

// Filter field
pub const FilterField = enum {
    id,
    name,
    category,
    severity,
    source,
    correlation_id,
    user_id,
    session_id,
    tags,
    timestamp,
    payload_field,
    metadata_field,
};

// Filter value
pub const FilterValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    string_list: []const []const u8,
    category: EventCategory,
    severity: EventSeverity,
    json_path: []const u8,
};

// Filter condition
pub const FilterCondition = struct {
    field: FilterField,
    op: FilterOp,
    value: FilterValue,
    field_path: ?[]const u8 = null, // For payload_field and metadata_field
    
    pub fn matches(self: *const FilterCondition, event: *const Event) bool {
        return switch (self.field) {
            .id => self.matchString(event.id),
            .name => self.matchString(event.name),
            .category => self.matchCategory(event.category),
            .severity => self.matchSeverity(event.severity),
            .source => self.matchString(event.metadata.source),
            .correlation_id => self.matchOptionalString(event.metadata.correlation_id),
            .user_id => self.matchOptionalString(event.metadata.user_id),
            .session_id => self.matchOptionalString(event.metadata.session_id),
            .tags => self.matchTags(event.metadata.tags),
            .timestamp => self.matchInteger(event.metadata.timestamp),
            .payload_field => self.matchJsonField(event.payload, self.field_path),
            .metadata_field => self.matchJsonField(event.metadata.custom orelse .{ .null = {} }, self.field_path),
        };
    }
    
    fn matchString(self: *const FilterCondition, value: []const u8) bool {
        return switch (self.value) {
            .string => |filter_str| switch (self.op) {
                .eq => std.mem.eql(u8, value, filter_str),
                .ne => !std.mem.eql(u8, value, filter_str),
                .contains => std.mem.indexOf(u8, value, filter_str) != null,
                .starts_with => std.mem.startsWith(u8, value, filter_str),
                .ends_with => std.mem.endsWith(u8, value, filter_str),
                .matches => matchesPattern(value, filter_str),
                else => false,
            },
            .string_list => |list| switch (self.op) {
                .in => {
                    for (list) |item| {
                        if (std.mem.eql(u8, value, item)) return true;
                    }
                    return false;
                },
                .not_in => {
                    for (list) |item| {
                        if (std.mem.eql(u8, value, item)) return false;
                    }
                    return true;
                },
                else => false,
            },
            else => false,
        };
    }
    
    fn matchOptionalString(self: *const FilterCondition, value: ?[]const u8) bool {
        if (value) |str| {
            return self.matchString(str);
        }
        return self.op == .eq and self.value == .string and 
               std.mem.eql(u8, self.value.string, "");
    }
    
    fn matchCategory(self: *const FilterCondition, value: EventCategory) bool {
        return switch (self.value) {
            .category => |cat| switch (self.op) {
                .eq => value == cat,
                .ne => value != cat,
                else => false,
            },
            .string => |str| {
                const cat_str = value.toString();
                return switch (self.op) {
                    .eq => std.mem.eql(u8, cat_str, str),
                    .ne => !std.mem.eql(u8, cat_str, str),
                    else => false,
                };
            },
            else => false,
        };
    }
    
    fn matchSeverity(self: *const FilterCondition, value: EventSeverity) bool {
        return switch (self.value) {
            .severity => |sev| switch (self.op) {
                .eq => value == sev,
                .ne => value != sev,
                .gt => @intFromEnum(value) > @intFromEnum(sev),
                .gte => @intFromEnum(value) >= @intFromEnum(sev),
                .lt => @intFromEnum(value) < @intFromEnum(sev),
                .lte => @intFromEnum(value) <= @intFromEnum(sev),
                else => false,
            },
            .string => |str| {
                const sev_str = value.toString();
                return switch (self.op) {
                    .eq => std.mem.eql(u8, sev_str, str),
                    .ne => !std.mem.eql(u8, sev_str, str),
                    else => false,
                };
            },
            else => false,
        };
    }
    
    fn matchInteger(self: *const FilterCondition, value: i64) bool {
        return switch (self.value) {
            .integer => |int| switch (self.op) {
                .eq => value == int,
                .ne => value != int,
                .gt => value > int,
                .gte => value >= int,
                .lt => value < int,
                .lte => value <= int,
                else => false,
            },
            else => false,
        };
    }
    
    fn matchTags(self: *const FilterCondition, tags: []const []const u8) bool {
        return switch (self.value) {
            .string => |str| switch (self.op) {
                .contains => {
                    for (tags) |tag| {
                        if (std.mem.eql(u8, tag, str)) return true;
                    }
                    return false;
                },
                else => false,
            },
            .string_list => |list| switch (self.op) {
                .contains => {
                    // All filter tags must be present
                    for (list) |filter_tag| {
                        var found = false;
                        for (tags) |event_tag| {
                            if (std.mem.eql(u8, event_tag, filter_tag)) {
                                found = true;
                                break;
                            }
                        }
                        if (!found) return false;
                    }
                    return true;
                },
                else => false,
            },
            else => false,
        };
    }
    
    fn matchJsonField(self: *const FilterCondition, json: std.json.Value, path: ?[]const u8) bool {
        const field_path = path orelse return false;
        
        // Navigate JSON path
        var current = json;
        var iter = std.mem.tokenize(u8, field_path, ".");
        
        while (iter.next()) |segment| {
            switch (current) {
                .object => |obj| {
                    current = obj.get(segment) orelse return false;
                },
                else => return false,
            }
        }
        
        // Match the value
        return switch (current) {
            .string => |str| switch (self.value) {
                .string => self.matchString(str),
                else => false,
            },
            .integer => |int| switch (self.value) {
                .integer => self.matchInteger(int),
                else => false,
            },
            .float => |f| switch (self.value) {
                .float => |filter_float| switch (self.op) {
                    .eq => f == filter_float,
                    .ne => f != filter_float,
                    .gt => f > filter_float,
                    .gte => f >= filter_float,
                    .lt => f < filter_float,
                    .lte => f <= filter_float,
                    else => false,
                },
                else => false,
            },
            .bool => |b| switch (self.value) {
                .boolean => |filter_bool| switch (self.op) {
                    .eq => b == filter_bool,
                    .ne => b != filter_bool,
                    else => false,
                },
                else => false,
            },
            else => false,
        };
    }
};

// Filter expression
pub const FilterExpression = union(enum) {
    condition: FilterCondition,
    and_expr: struct {
        left: *FilterExpression,
        right: *FilterExpression,
    },
    or_expr: struct {
        left: *FilterExpression,
        right: *FilterExpression,
    },
    not_expr: *FilterExpression,
    
    pub fn matches(self: *const FilterExpression, event: *const Event) bool {
        return switch (self.*) {
            .condition => |*cond| cond.matches(event),
            .and_expr => |expr| expr.left.matches(event) and expr.right.matches(event),
            .or_expr => |expr| expr.left.matches(event) or expr.right.matches(event),
            .not_expr => |expr| !expr.matches(event),
        };
    }
    
    pub fn deinit(self: *FilterExpression, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .condition => {},
            .and_expr => |expr| {
                expr.left.deinit(allocator);
                expr.right.deinit(allocator);
                allocator.destroy(expr.left);
                allocator.destroy(expr.right);
            },
            .or_expr => |expr| {
                expr.left.deinit(allocator);
                expr.right.deinit(allocator);
                allocator.destroy(expr.left);
                allocator.destroy(expr.right);
            },
            .not_expr => |expr| {
                expr.deinit(allocator);
                allocator.destroy(expr);
            },
        }
    }
};

// Filter builder for fluent API
pub const FilterBuilder = struct {
    allocator: std.mem.Allocator,
    expression: ?*FilterExpression = null,
    
    pub fn init(allocator: std.mem.Allocator) FilterBuilder {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *FilterBuilder) void {
        if (self.expression) |expr| {
            expr.deinit(self.allocator);
            self.allocator.destroy(expr);
        }
    }
    
    pub fn where(self: *FilterBuilder, field: FilterField, op: FilterOp, value: FilterValue) !*FilterBuilder {
        const expr = try self.allocator.create(FilterExpression);
        expr.* = .{ .condition = FilterCondition{
            .field = field,
            .op = op,
            .value = value,
        } };
        
        if (self.expression) |existing| {
            existing.deinit(self.allocator);
            self.allocator.destroy(existing);
        }
        
        self.expression = expr;
        return self;
    }
    
    pub fn whereField(self: *FilterBuilder, field: FilterField, path: []const u8, op: FilterOp, value: FilterValue) !*FilterBuilder {
        const expr = try self.allocator.create(FilterExpression);
        expr.* = .{ .condition = FilterCondition{
            .field = field,
            .op = op,
            .value = value,
            .field_path = path,
        } };
        
        if (self.expression) |existing| {
            existing.deinit(self.allocator);
            self.allocator.destroy(existing);
        }
        
        self.expression = expr;
        return self;
    }
    
    pub fn andWhere(self: *FilterBuilder, field: FilterField, op: FilterOp, value: FilterValue) !*FilterBuilder {
        if (self.expression == null) {
            return self.where(field, op, value);
        }
        
        const right = try self.allocator.create(FilterExpression);
        right.* = .{ .condition = FilterCondition{
            .field = field,
            .op = op,
            .value = value,
        } };
        
        const and_expr = try self.allocator.create(FilterExpression);
        and_expr.* = .{ .and_expr = .{
            .left = self.expression.?,
            .right = right,
        } };
        
        self.expression = and_expr;
        return self;
    }
    
    pub fn orWhere(self: *FilterBuilder, field: FilterField, op: FilterOp, value: FilterValue) !*FilterBuilder {
        if (self.expression == null) {
            return self.where(field, op, value);
        }
        
        const right = try self.allocator.create(FilterExpression);
        right.* = .{ .condition = FilterCondition{
            .field = field,
            .op = op,
            .value = value,
        } };
        
        const or_expr = try self.allocator.create(FilterExpression);
        or_expr.* = .{ .or_expr = .{
            .left = self.expression.?,
            .right = right,
        } };
        
        self.expression = or_expr;
        return self;
    }
    
    pub fn not(self: *FilterBuilder) !*FilterBuilder {
        if (self.expression) |expr| {
            const not_expr = try self.allocator.create(FilterExpression);
            not_expr.* = .{ .not_expr = expr };
            self.expression = not_expr;
        }
        return self;
    }
    
    pub fn build(self: *FilterBuilder) ?*FilterExpression {
        const expr = self.expression;
        self.expression = null;
        return expr;
    }
};

// Event filter
pub const EventFilter = struct {
    allocator: std.mem.Allocator,
    expression: ?*FilterExpression = null,
    name: []const u8,
    enabled: bool = true,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8) EventFilter {
        return .{
            .allocator = allocator,
            .name = name,
        };
    }
    
    pub fn deinit(self: *EventFilter) void {
        if (self.expression) |expr| {
            expr.deinit(self.allocator);
            self.allocator.destroy(expr);
        }
    }
    
    pub fn setExpression(self: *EventFilter, expr: *FilterExpression) void {
        if (self.expression) |old_expr| {
            old_expr.deinit(self.allocator);
            self.allocator.destroy(old_expr);
        }
        self.expression = expr;
    }
    
    pub fn matches(self: *const EventFilter, event: *const Event) bool {
        if (!self.enabled) return false;
        if (self.expression) |expr| {
            return expr.matches(event);
        }
        return true; // No filter means match all
    }
    
    pub fn enable(self: *EventFilter) void {
        self.enabled = true;
    }
    
    pub fn disable(self: *EventFilter) void {
        self.enabled = false;
    }
};

// Helper function for pattern matching
fn matchesPattern(text: []const u8, pattern: []const u8) bool {
    // Simple wildcard matching
    if (std.mem.indexOf(u8, pattern, "*")) |wildcard_pos| {
        if (wildcard_pos == 0) {
            // *suffix
            return std.mem.endsWith(u8, text, pattern[1..]);
        } else if (wildcard_pos == pattern.len - 1) {
            // prefix*
            return std.mem.startsWith(u8, text, pattern[0..wildcard_pos]);
        } else {
            // prefix*suffix
            const prefix = pattern[0..wildcard_pos];
            const suffix = pattern[wildcard_pos + 1..];
            return std.mem.startsWith(u8, text, prefix) and std.mem.endsWith(u8, text, suffix);
        }
    }
    
    return std.mem.eql(u8, text, pattern);
}

// Tests
test "filter condition matching" {
    const allocator = std.testing.allocator;
    
    var event = try types.Event.init(
        allocator,
        "test.event",
        .custom,
        .info,
        "test_source",
        .{ .null = {} },
    );
    defer event.deinit();
    
    // Test name equality
    const name_filter = FilterCondition{
        .field = .name,
        .op = .eq,
        .value = .{ .string = "test.event" },
    };
    try std.testing.expect(name_filter.matches(&event));
    
    // Test severity comparison
    const severity_filter = FilterCondition{
        .field = .severity,
        .op = .gte,
        .value = .{ .severity = .info },
    };
    try std.testing.expect(severity_filter.matches(&event));
    
    // Test category
    const category_filter = FilterCondition{
        .field = .category,
        .op = .eq,
        .value = .{ .category = .custom },
    };
    try std.testing.expect(category_filter.matches(&event));
}

test "filter builder" {
    const allocator = std.testing.allocator;
    
    var builder = FilterBuilder.init(allocator);
    defer builder.deinit();
    
    _ = try builder.where(.severity, .gte, .{ .severity = .warning })
        .andWhere(.category, .eq, .{ .category = .agent });
    
    const expr = builder.build();
    try std.testing.expect(expr != null);
    
    if (expr) |e| {
        defer {
            e.deinit(allocator);
            allocator.destroy(e);
        }
        
        var event = try types.Event.init(
            allocator,
            "test.event",
            .agent,
            .@"error",
            "test",
            .{ .null = {} },
        );
        defer event.deinit();
        
        try std.testing.expect(e.matches(&event));
    }
}

test "pattern matching" {
    try std.testing.expect(matchesPattern("test.event", "test.*"));
    try std.testing.expect(matchesPattern("test.event", "*.event"));
    try std.testing.expect(matchesPattern("test.event.name", "test.*.name"));
    try std.testing.expect(!matchesPattern("test.event", "other.*"));
}