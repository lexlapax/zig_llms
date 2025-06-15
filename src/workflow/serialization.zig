// ABOUTME: Workflow serialization support for JSON and YAML formats
// ABOUTME: Enables saving and loading workflow definitions from files

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowStepType = definition.WorkflowStepType;

// Serialization format
pub const SerializationFormat = enum {
    json,
    yaml,
    binary,
};

// Workflow serializer
pub const WorkflowSerializer = struct {
    allocator: std.mem.Allocator,
    format: SerializationFormat = .json,
    pretty_print: bool = true,
    include_metadata: bool = true,
    
    pub fn init(allocator: std.mem.Allocator) WorkflowSerializer {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn serialize(self: *WorkflowSerializer, workflow: WorkflowDefinition, writer: anytype) !void {
        switch (self.format) {
            .json => try self.serializeJson(workflow, writer),
            .yaml => try self.serializeYaml(workflow, writer),
            .binary => try self.serializeBinary(workflow, writer),
        }
    }
    
    pub fn deserialize(self: *WorkflowSerializer, reader: anytype) !WorkflowDefinition {
        return switch (self.format) {
            .json => try self.deserializeJson(reader),
            .yaml => try self.deserializeYaml(reader),
            .binary => try self.deserializeBinary(reader),
        };
    }
    
    fn serializeJson(self: *WorkflowSerializer, workflow: WorkflowDefinition, writer: anytype) !void {
        var root = std.json.ObjectMap.init(self.allocator);
        defer root.deinit();
        
        // Basic workflow info
        try root.put("id", .{ .string = workflow.id });
        try root.put("name", .{ .string = workflow.name });
        try root.put("version", .{ .string = workflow.version });
        
        if (workflow.description) |desc| {
            try root.put("description", .{ .string = desc });
        }
        
        if (workflow.author) |author| {
            try root.put("author", .{ .string = author });
        }
        
        // Variables
        var variables_obj = std.json.ObjectMap.init(self.allocator);
        var var_iter = workflow.variables.iterator();
        while (var_iter.next()) |entry| {
            try variables_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try root.put("variables", .{ .object = variables_obj });
        
        // Steps
        var steps_array = std.json.Array.init(self.allocator);
        for (workflow.steps) |step| {
            const step_json = try self.stepToJson(step);
            try steps_array.append(step_json);
        }
        try root.put("steps", .{ .array = steps_array });
        
        // Schemas
        if (workflow.input_schema) |schema| {
            try root.put("input_schema", schema);
        }
        if (workflow.output_schema) |schema| {
            try root.put("output_schema", schema);
        }
        
        // Metadata
        if (self.include_metadata) {
            var metadata_obj = std.json.ObjectMap.init(self.allocator);
            
            // Tags
            var tags_array = std.json.Array.init(self.allocator);
            for (workflow.metadata.tags) |tag| {
                try tags_array.append(.{ .string = tag });
            }
            try metadata_obj.put("tags", .{ .array = tags_array });
            
            if (workflow.metadata.timeout_ms) |timeout| {
                try metadata_obj.put("timeout_ms", .{ .integer = @intCast(timeout) });
            }
            
            try metadata_obj.put("max_retries", .{ .integer = workflow.metadata.max_retries });
            
            if (workflow.metadata.created_at) |created| {
                try metadata_obj.put("created_at", .{ .integer = created });
            }
            
            if (workflow.metadata.updated_at) |updated| {
                try metadata_obj.put("updated_at", .{ .integer = updated });
            }
            
            try root.put("metadata", .{ .object = metadata_obj });
        }
        
        // Write JSON
        const options = if (self.pretty_print) 
            std.json.StringifyOptions{ .whitespace = .indent_2 }
        else 
            std.json.StringifyOptions{};
            
        try std.json.stringify(.{ .object = root }, options, writer);
    }
    
    fn deserializeJson(self: *WorkflowSerializer, reader: anytype) !WorkflowDefinition {
        const content = try reader.readAllAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        defer self.allocator.free(content);
        
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();
        
        if (parsed.value != .object) return error.InvalidFormat;
        
        const root = parsed.value.object;
        
        // Extract basic info
        const id = if (root.get("id")) |v| v.string else return error.MissingField;
        const name = if (root.get("name")) |v| v.string else return error.MissingField;
        const version = if (root.get("version")) |v| v.string else "1.0.0";
        
        var workflow = WorkflowDefinition.init(self.allocator, id, name);
        workflow.version = version;
        
        // Optional fields
        if (root.get("description")) |desc| {
            workflow.description = desc.string;
        }
        
        if (root.get("author")) |author| {
            workflow.author = author.string;
        }
        
        // Variables
        if (root.get("variables")) |vars| {
            if (vars == .object) {
                var var_iter = vars.object.iterator();
                while (var_iter.next()) |entry| {
                    try workflow.variables.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
        
        // Steps
        if (root.get("steps")) |steps| {
            if (steps == .array) {
                var step_list = std.ArrayList(WorkflowStep).init(self.allocator);
                defer step_list.deinit();
                
                for (steps.array.items) |step_json| {
                    const step = try self.jsonToStep(step_json);
                    try step_list.append(step);
                }
                
                workflow.steps = try step_list.toOwnedSlice();
            }
        }
        
        // Schemas
        if (root.get("input_schema")) |schema| {
            workflow.input_schema = schema;
        }
        if (root.get("output_schema")) |schema| {
            workflow.output_schema = schema;
        }
        
        // Metadata
        if (root.get("metadata")) |meta| {
            if (meta == .object) {
                const meta_obj = meta.object;
                
                if (meta_obj.get("tags")) |tags| {
                    if (tags == .array) {
                        var tag_list = std.ArrayList([]const u8).init(self.allocator);
                        defer tag_list.deinit();
                        
                        for (tags.array.items) |tag| {
                            try tag_list.append(tag.string);
                        }
                        
                        workflow.metadata.tags = try tag_list.toOwnedSlice();
                    }
                }
                
                if (meta_obj.get("timeout_ms")) |timeout| {
                    workflow.metadata.timeout_ms = @intCast(timeout.integer);
                }
                
                if (meta_obj.get("max_retries")) |retries| {
                    workflow.metadata.max_retries = @intCast(retries.integer);
                }
                
                if (meta_obj.get("created_at")) |created| {
                    workflow.metadata.created_at = created.integer;
                }
                
                if (meta_obj.get("updated_at")) |updated| {
                    workflow.metadata.updated_at = updated.integer;
                }
            }
        }
        
        return workflow;
    }
    
    fn serializeYaml(self: *WorkflowSerializer, workflow: WorkflowDefinition, writer: anytype) !void {
        // Convert to JSON first, then format as YAML
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        const old_format = self.format;
        self.format = .json;
        self.pretty_print = false;
        defer {
            self.format = old_format;
            self.pretty_print = true;
        }
        
        try self.serializeJson(workflow, buffer.writer());
        
        // Parse JSON and convert to YAML format
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, buffer.items, .{});
        defer parsed.deinit();
        
        try self.writeYamlValue(parsed.value, writer, 0);
    }
    
    fn deserializeYaml(self: *WorkflowSerializer, reader: anytype) !WorkflowDefinition {
        // For now, assume YAML is JSON-compatible
        // TODO: Implement proper YAML parsing
        return self.deserializeJson(reader);
    }
    
    fn serializeBinary(self: *WorkflowSerializer, workflow: WorkflowDefinition, writer: anytype) !void {
        // Binary format header
        try writer.writeAll("ZLWF"); // ZigLLMs Workflow
        try writer.writeInt(u32, 1, .little); // Version
        
        // Write workflow data
        try self.writeString(writer, workflow.id);
        try self.writeString(writer, workflow.name);
        try self.writeString(writer, workflow.version);
        try self.writeOptionalString(writer, workflow.description);
        try self.writeOptionalString(writer, workflow.author);
        
        // Write variables count and data
        try writer.writeInt(u32, @intCast(workflow.variables.count()), .little);
        var var_iter = workflow.variables.iterator();
        while (var_iter.next()) |entry| {
            try self.writeString(writer, entry.key_ptr.*);
            try self.writeJsonValue(writer, entry.value_ptr.*);
        }
        
        // Write steps
        try writer.writeInt(u32, @intCast(workflow.steps.len), .little);
        for (workflow.steps) |step| {
            try self.writeBinaryStep(writer, step);
        }
    }
    
    fn deserializeBinary(self: *WorkflowSerializer, reader: anytype) !WorkflowDefinition {
        // Read header
        var magic: [4]u8 = undefined;
        _ = try reader.read(&magic);
        if (!std.mem.eql(u8, &magic, "ZLWF")) {
            return error.InvalidFormat;
        }
        
        const version = try reader.readInt(u32, .little);
        if (version != 1) {
            return error.UnsupportedVersion;
        }
        
        // Read workflow data
        const id = try self.readString(reader);
        const name = try self.readString(reader);
        const version_str = try self.readString(reader);
        
        var workflow = WorkflowDefinition.init(self.allocator, id, name);
        workflow.version = version_str;
        workflow.description = try self.readOptionalString(reader);
        workflow.author = try self.readOptionalString(reader);
        
        // Read variables
        const var_count = try reader.readInt(u32, .little);
        var i: u32 = 0;
        while (i < var_count) : (i += 1) {
            const var_name = try self.readString(reader);
            const var_value = try self.readJsonValue(reader);
            try workflow.variables.put(var_name, var_value);
        }
        
        // Read steps
        const step_count = try reader.readInt(u32, .little);
        var steps = try self.allocator.alloc(WorkflowStep, step_count);
        for (0..step_count) |step_idx| {
            steps[step_idx] = try self.readBinaryStep(reader);
        }
        workflow.steps = steps;
        
        return workflow;
    }
    
    fn stepToJson(self: *WorkflowSerializer, step: WorkflowStep) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        
        try obj.put("id", .{ .string = step.id });
        try obj.put("name", .{ .string = step.name });
        try obj.put("type", .{ .string = @tagName(step.step_type) });
        
        // Step configuration
        var config_obj = std.json.ObjectMap.init(self.allocator);
        switch (step.config) {
            .agent => |agent_config| {
                try config_obj.put("agent_name", .{ .string = agent_config.agent_name });
                // TODO: Add input/output mapping serialization
            },
            .tool => |tool_config| {
                try config_obj.put("tool_name", .{ .string = tool_config.tool_name });
                // TODO: Add input/output mapping serialization
            },
            .delay => |delay_config| {
                try config_obj.put("duration_ms", .{ .integer = @intCast(delay_config.duration_ms) });
                try config_obj.put("jitter_percent", .{ .float = delay_config.jitter_percent });
            },
            .transform => |transform_config| {
                try config_obj.put("transform_type", .{ .string = @tagName(transform_config.transform_type) });
                try config_obj.put("expression", .{ .string = transform_config.expression });
            },
            else => {
                // TODO: Implement other step types
            },
        }
        try obj.put("config", .{ .object = config_obj });
        
        // Metadata
        var metadata_obj = std.json.ObjectMap.init(self.allocator);
        if (step.metadata.description) |desc| {
            try metadata_obj.put("description", .{ .string = desc });
        }
        if (step.metadata.timeout_ms) |timeout| {
            try metadata_obj.put("timeout_ms", .{ .integer = @intCast(timeout) });
        }
        try metadata_obj.put("retry_count", .{ .integer = step.metadata.retry_count });
        try metadata_obj.put("retry_delay_ms", .{ .integer = @intCast(step.metadata.retry_delay_ms) });
        try metadata_obj.put("continue_on_error", .{ .bool = step.metadata.continue_on_error });
        
        try obj.put("metadata", .{ .object = metadata_obj });
        
        return .{ .object = obj };
    }
    
    fn jsonToStep(_: *WorkflowSerializer, value: std.json.Value) !WorkflowStep {
        if (value != .object) return error.InvalidFormat;
        
        const obj = value.object;
        
        const id = if (obj.get("id")) |v| v.string else return error.MissingField;
        const name = if (obj.get("name")) |v| v.string else return error.MissingField;
        const type_str = if (obj.get("type")) |v| v.string else return error.MissingField;
        
        // Parse step type
        const step_type = std.meta.stringToEnum(WorkflowStepType, type_str) orelse return error.InvalidStepType;
        
        // Parse configuration (simplified for now)
        const config = switch (step_type) {
            .delay => blk: {
                if (obj.get("config")) |cfg| {
                    if (cfg == .object) {
                        const cfg_obj = cfg.object;
                        const duration = if (cfg_obj.get("duration_ms")) |d| @as(u32, @intCast(d.integer)) else 0;
                        const jitter = if (cfg_obj.get("jitter_percent")) |j| @as(f32, @floatCast(j.float)) else 0.0;
                        
                        break :blk definition.WorkflowStep.StepConfig{
                            .delay = .{
                                .duration_ms = duration,
                                .jitter_percent = jitter,
                            },
                        };
                    }
                }
                break :blk definition.WorkflowStep.StepConfig{
                    .delay = .{ .duration_ms = 1000 },
                };
            },
            else => {
                // TODO: Implement other step types
                return error.StepTypeNotImplemented;
            },
        };
        
        return WorkflowStep{
            .id = id,
            .name = name,
            .step_type = step_type,
            .config = config,
        };
    }
    
    fn writeYamlValue(self: *WorkflowSerializer, value: std.json.Value, writer: anytype, indent: u32) !void {
        const indent_str = try self.allocator.alloc(u8, indent * 2);
        defer self.allocator.free(indent_str);
        @memset(indent_str, ' ');
        
        switch (value) {
            .object => |obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    try writer.writeAll(indent_str);
                    try writer.print("{s}:\n", .{entry.key_ptr.*});
                    try self.writeYamlValue(entry.value_ptr.*, writer, indent + 1);
                }
            },
            .array => |arr| {
                for (arr.items) |item| {
                    try writer.writeAll(indent_str);
                    try writer.writeAll("- ");
                    try self.writeYamlValue(item, writer, indent + 1);
                }
            },
            .string => |str| {
                try writer.print("\"{s}\"\n", .{str});
            },
            .integer => |int| {
                try writer.print("{d}\n", .{int});
            },
            .float => |float| {
                try writer.print("{d}\n", .{float});
            },
            .bool => |boolean| {
                try writer.print("{}\n", .{boolean});
            },
            .null => {
                try writer.writeAll("null\n");
            },
        }
    }
    
    // Helper functions for binary serialization
    fn writeString(self: *WorkflowSerializer, writer: anytype, str: []const u8) !void {
        _ = self;
        try writer.writeInt(u32, @intCast(str.len), .little);
        try writer.writeAll(str);
    }
    
    fn readString(self: *WorkflowSerializer, reader: anytype) ![]const u8 {
        const len = try reader.readInt(u32, .little);
        const str = try self.allocator.alloc(u8, len);
        _ = try reader.read(str);
        return str;
    }
    
    fn writeOptionalString(self: *WorkflowSerializer, writer: anytype, str: ?[]const u8) !void {
        if (str) |s| {
            try writer.writeByte(1);
            try self.writeString(writer, s);
        } else {
            try writer.writeByte(0);
        }
    }
    
    fn readOptionalString(self: *WorkflowSerializer, reader: anytype) !?[]const u8 {
        const has_value = try reader.readByte();
        if (has_value == 1) {
            return try self.readString(reader);
        }
        return null;
    }
    
    fn writeJsonValue(self: *WorkflowSerializer, writer: anytype, value: std.json.Value) !void {
        // Simple JSON value serialization for binary format
        _ = self;
        _ = writer;
        _ = value;
        // TODO: Implement binary JSON serialization
    }
    
    fn readJsonValue(self: *WorkflowSerializer, reader: anytype) !std.json.Value {
        // Simple JSON value deserialization for binary format
        _ = self;
        _ = reader;
        // TODO: Implement binary JSON deserialization
        return .{ .null = {} };
    }
    
    fn writeBinaryStep(self: *WorkflowSerializer, writer: anytype, step: WorkflowStep) !void {
        _ = self;
        _ = writer;
        _ = step;
        // TODO: Implement binary step serialization
    }
    
    fn readBinaryStep(self: *WorkflowSerializer, reader: anytype) !WorkflowStep {
        _ = self;
        _ = reader;
        // TODO: Implement binary step deserialization
        return WorkflowStep{
            .id = "temp",
            .name = "temp",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 0 } },
        };
    }
};

// Convenience functions
pub fn saveWorkflowToFile(workflow: WorkflowDefinition, path: []const u8, format: SerializationFormat, allocator: std.mem.Allocator) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    var serializer = WorkflowSerializer.init(allocator);
    serializer.format = format;
    
    try serializer.serialize(workflow, file.writer());
}

pub fn loadWorkflowFromFile(path: []const u8, format: SerializationFormat, allocator: std.mem.Allocator) !WorkflowDefinition {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    var serializer = WorkflowSerializer.init(allocator);
    serializer.format = format;
    
    return serializer.deserialize(file.reader());
}

// Tests
test "workflow serialization to JSON" {
    const allocator = std.testing.allocator;
    
    var workflow = WorkflowDefinition.init(allocator, "test_workflow", "Test Workflow");
    defer workflow.deinit();
    
    workflow.description = "A test workflow";
    workflow.version = "1.0.0";
    
    var serializer = WorkflowSerializer.init(allocator);
    
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try serializer.serialize(workflow, buffer.writer());
    
    // Basic check that JSON was generated
    try std.testing.expect(buffer.items.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer.items, "test_workflow") != null);
}