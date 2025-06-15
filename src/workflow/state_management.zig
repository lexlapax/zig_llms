// ABOUTME: Advanced state management for workflows with persistence and recovery
// ABOUTME: Provides checkpointing, state snapshots, and workflow resumption capabilities

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const WorkflowExecutionState = definition.WorkflowExecutionState;
const State = @import("../state.zig").State;
const StateSnapshot = @import("../state.zig").StateSnapshot;

// Workflow state manager
pub const WorkflowStateManager = struct {
    workflow_id: []const u8,
    instance_id: []const u8,
    state_store: StateStore,
    checkpoint_strategy: CheckpointStrategy,
    recovery_strategy: RecoveryStrategy,
    allocator: std.mem.Allocator,
    
    pub fn init(
        allocator: std.mem.Allocator,
        workflow_id: []const u8,
        config: StateManagerConfig,
    ) !WorkflowStateManager {
        const instance_id = try generateInstanceId(allocator);
        
        return WorkflowStateManager{
            .workflow_id = workflow_id,
            .instance_id = instance_id,
            .state_store = try StateStore.init(allocator, config.storage_backend),
            .checkpoint_strategy = config.checkpoint_strategy,
            .recovery_strategy = config.recovery_strategy,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WorkflowStateManager) void {
        self.allocator.free(self.instance_id);
        self.state_store.deinit();
    }
    
    pub fn saveState(self: *WorkflowStateManager, context: *WorkflowExecutionContext) !void {
        const state_data = try self.serializeContext(context);
        defer self.allocator.free(state_data);
        
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.workflow_id, self.instance_id });
        defer self.allocator.free(key);
        
        try self.state_store.save(key, state_data);
    }
    
    pub fn loadState(self: *WorkflowStateManager, context: *WorkflowExecutionContext) !bool {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.workflow_id, self.instance_id });
        defer self.allocator.free(key);
        
        const state_data = self.state_store.load(key) catch return false;
        defer self.allocator.free(state_data);
        
        try self.deserializeContext(state_data, context);
        return true;
    }
    
    pub fn createCheckpoint(self: *WorkflowStateManager, context: *WorkflowExecutionContext, checkpoint_id: []const u8) !void {
        const checkpoint = try Checkpoint.create(self.allocator, checkpoint_id, context);
        defer checkpoint.deinit();
        
        const checkpoint_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:checkpoint:{s}", 
            .{ self.workflow_id, self.instance_id, checkpoint_id });
        defer self.allocator.free(checkpoint_key);
        
        const checkpoint_data = try checkpoint.serialize(self.allocator);
        defer self.allocator.free(checkpoint_data);
        
        try self.state_store.save(checkpoint_key, checkpoint_data);
    }
    
    pub fn restoreCheckpoint(self: *WorkflowStateManager, checkpoint_id: []const u8, context: *WorkflowExecutionContext) !bool {
        const checkpoint_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:checkpoint:{s}", 
            .{ self.workflow_id, self.instance_id, checkpoint_id });
        defer self.allocator.free(checkpoint_key);
        
        const checkpoint_data = self.state_store.load(checkpoint_key) catch return false;
        defer self.allocator.free(checkpoint_data);
        
        var checkpoint = try Checkpoint.deserialize(self.allocator, checkpoint_data);
        defer checkpoint.deinit();
        
        try checkpoint.restore(context);
        return true;
    }
    
    pub fn listCheckpoints(self: *WorkflowStateManager) ![][]const u8 {
        const pattern = try std.fmt.allocPrint(self.allocator, "{s}:{s}:checkpoint:*", 
            .{ self.workflow_id, self.instance_id });
        defer self.allocator.free(pattern);
        
        return self.state_store.listKeys(pattern);
    }
    
    pub fn deleteCheckpoint(self: *WorkflowStateManager, checkpoint_id: []const u8) !void {
        const checkpoint_key = try std.fmt.allocPrint(self.allocator, "{s}:{s}:checkpoint:{s}", 
            .{ self.workflow_id, self.instance_id, checkpoint_id });
        defer self.allocator.free(checkpoint_key);
        
        try self.state_store.delete(checkpoint_key);
    }
    
    fn serializeContext(self: *WorkflowStateManager, context: *WorkflowExecutionContext) ![]u8 {
        var obj = std.json.ObjectMap.init(self.allocator);
        defer obj.deinit();
        
        // Serialize execution state
        try obj.put("execution_state", .{ .string = @tagName(context.execution_state) });
        
        if (context.current_step) |step| {
            try obj.put("current_step", .{ .string = step });
        }
        
        // Serialize variables
        var variables_obj = std.json.ObjectMap.init(self.allocator);
        var var_iter = context.variables.iterator();
        while (var_iter.next()) |entry| {
            try variables_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("variables", .{ .object = variables_obj });
        
        // Serialize step results
        var results_obj = std.json.ObjectMap.init(self.allocator);
        var result_iter = context.step_results.iterator();
        while (result_iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("step_results", .{ .object = results_obj });
        
        // Add metadata
        try obj.put("workflow_id", .{ .string = self.workflow_id });
        try obj.put("instance_id", .{ .string = self.instance_id });
        try obj.put("timestamp", .{ .integer = std.time.milliTimestamp() });
        
        return std.json.stringifyAlloc(self.allocator, std.json.Value{ .object = obj }, .{});
    }
    
    fn deserializeContext(self: *WorkflowStateManager, data: []const u8, context: *WorkflowExecutionContext) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, data, .{});
        defer parsed.deinit();
        
        if (parsed.value != .object) return error.InvalidStateFormat;
        const obj = parsed.value.object;
        
        // Restore execution state
        if (obj.get("execution_state")) |state_str| {
            if (state_str == .string) {
                context.execution_state = std.meta.stringToEnum(WorkflowExecutionState, state_str.string) orelse .pending;
            }
        }
        
        // Restore current step
        if (obj.get("current_step")) |step| {
            if (step == .string) {
                context.current_step = step.string;
            }
        }
        
        // Restore variables
        if (obj.get("variables")) |vars| {
            if (vars == .object) {
                var var_iter = vars.object.iterator();
                while (var_iter.next()) |entry| {
                    try context.variables.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
        
        // Restore step results
        if (obj.get("step_results")) |results| {
            if (results == .object) {
                var result_iter = results.object.iterator();
                while (result_iter.next()) |entry| {
                    try context.step_results.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
    }
};

// State manager configuration
pub const StateManagerConfig = struct {
    storage_backend: StorageBackend = .memory,
    checkpoint_strategy: CheckpointStrategy = .on_step_completion,
    recovery_strategy: RecoveryStrategy = .resume_from_checkpoint,
    auto_save_interval_ms: ?u32 = 5000,
    max_checkpoints: u32 = 10,
    compress_state: bool = true,
};

// Storage backend types
pub const StorageBackend = enum {
    memory,
    file,
    redis,
    postgres,
    custom,
};

// Checkpoint strategies
pub const CheckpointStrategy = enum {
    never,
    on_step_completion,
    on_milestone,
    periodic,
    on_state_change,
};

// Recovery strategies
pub const RecoveryStrategy = enum {
    restart_from_beginning,
    resume_from_checkpoint,
    resume_from_last_successful_step,
    custom,
};

// State store interface
pub const StateStore = struct {
    backend: Backend,
    allocator: std.mem.Allocator,
    
    pub const Backend = union(enum) {
        memory: MemoryBackend,
        file: FileBackend,
        custom: CustomBackend,
    };
    
    pub fn init(allocator: std.mem.Allocator, backend_type: StorageBackend) !StateStore {
        const backend = switch (backend_type) {
            .memory => Backend{ .memory = MemoryBackend.init(allocator) },
            .file => Backend{ .file = try FileBackend.init(allocator, "workflow_states") },
            else => return error.BackendNotImplemented,
        };
        
        return StateStore{
            .backend = backend,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *StateStore) void {
        switch (self.backend) {
            .memory => |*b| b.deinit(),
            .file => |*b| b.deinit(),
            .custom => |*b| b.deinit(),
        }
    }
    
    pub fn save(self: *StateStore, key: []const u8, data: []const u8) !void {
        return switch (self.backend) {
            .memory => |*b| b.save(key, data),
            .file => |*b| b.save(key, data),
            .custom => |*b| b.save(key, data),
        };
    }
    
    pub fn load(self: *StateStore, key: []const u8) ![]u8 {
        return switch (self.backend) {
            .memory => |*b| b.load(key),
            .file => |*b| b.load(key),
            .custom => |*b| b.load(key),
        };
    }
    
    pub fn delete(self: *StateStore, key: []const u8) !void {
        return switch (self.backend) {
            .memory => |*b| b.delete(key),
            .file => |*b| b.delete(key),
            .custom => |*b| b.delete(key),
        };
    }
    
    pub fn listKeys(self: *StateStore, pattern: []const u8) ![][]const u8 {
        return switch (self.backend) {
            .memory => |*b| b.listKeys(pattern),
            .file => |*b| b.listKeys(pattern),
            .custom => |*b| b.listKeys(pattern),
        };
    }
};

// Memory backend
pub const MemoryBackend = struct {
    store: std.StringHashMap([]u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MemoryBackend {
        return .{
            .store = std.StringHashMap([]u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MemoryBackend) void {
        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.store.deinit();
    }
    
    pub fn save(self: *MemoryBackend, key: []const u8, data: []const u8) !void {
        const data_copy = try self.allocator.dupe(u8, data);
        
        if (self.store.fetchPut(try self.allocator.dupe(u8, key), data_copy)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
    }
    
    pub fn load(self: *MemoryBackend, key: []const u8) ![]u8 {
        if (self.store.get(key)) |data| {
            return self.allocator.dupe(u8, data);
        }
        return error.KeyNotFound;
    }
    
    pub fn delete(self: *MemoryBackend, key: []const u8) !void {
        if (self.store.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }
    
    pub fn listKeys(self: *MemoryBackend, pattern: []const u8) ![][]const u8 {
        var keys = std.ArrayList([]const u8).init(self.allocator);
        errdefer keys.deinit();
        
        var iter = self.store.iterator();
        while (iter.next()) |entry| {
            if (matchesPattern(entry.key_ptr.*, pattern)) {
                try keys.append(try self.allocator.dupe(u8, entry.key_ptr.*));
            }
        }
        
        return try keys.toOwnedSlice();
    }
};

// File backend
pub const FileBackend = struct {
    base_path: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, base_path: []const u8) !FileBackend {
        // Create directory if it doesn't exist
        std.fs.cwd().makeDir(base_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
        
        return .{
            .base_path = try allocator.dupe(u8, base_path),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *FileBackend) void {
        self.allocator.free(self.base_path);
    }
    
    pub fn save(self: *FileBackend, key: []const u8, data: []const u8) !void {
        const file_path = try self.getFilePath(key);
        defer self.allocator.free(file_path);
        
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        
        try file.writeAll(data);
    }
    
    pub fn load(self: *FileBackend, key: []const u8) ![]u8 {
        const file_path = try self.getFilePath(key);
        defer self.allocator.free(file_path);
        
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();
        
        return try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
    }
    
    pub fn delete(self: *FileBackend, key: []const u8) !void {
        const file_path = try self.getFilePath(key);
        defer self.allocator.free(file_path);
        
        try std.fs.cwd().deleteFile(file_path);
    }
    
    pub fn listKeys(self: *FileBackend, pattern: []const u8) ![][]const u8 {
        _ = pattern;
        // TODO: Implement file listing with pattern matching
        return self.allocator.alloc([]const u8, 0);
    }
    
    fn getFilePath(self: *FileBackend, key: []const u8) ![]u8 {
        // Replace colons with underscores for filesystem compatibility
        var safe_key = try self.allocator.dupe(u8, key);
        defer self.allocator.free(safe_key);
        
        for (safe_key) |*c| {
            if (c.* == ':') c.* = '_';
        }
        
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{ self.base_path, safe_key });
    }
};

// Custom backend interface
pub const CustomBackend = struct {
    vtable: *const VTable,
    
    pub const VTable = struct {
        save: *const fn (backend: *CustomBackend, key: []const u8, data: []const u8) anyerror!void,
        load: *const fn (backend: *CustomBackend, key: []const u8) anyerror![]u8,
        delete: *const fn (backend: *CustomBackend, key: []const u8) anyerror!void,
        listKeys: *const fn (backend: *CustomBackend, pattern: []const u8) anyerror![][]const u8,
        deinit: *const fn (backend: *CustomBackend) void,
    };
    
    pub fn save(self: *CustomBackend, key: []const u8, data: []const u8) !void {
        return self.vtable.save(self, key, data);
    }
    
    pub fn load(self: *CustomBackend, key: []const u8) ![]u8 {
        return self.vtable.load(self, key);
    }
    
    pub fn delete(self: *CustomBackend, key: []const u8) !void {
        return self.vtable.delete(self, key);
    }
    
    pub fn listKeys(self: *CustomBackend, pattern: []const u8) ![][]const u8 {
        return self.vtable.listKeys(self, pattern);
    }
    
    pub fn deinit(self: *CustomBackend) void {
        self.vtable.deinit(self);
    }
};

// Checkpoint
pub const Checkpoint = struct {
    id: []const u8,
    timestamp: i64,
    context_snapshot: std.json.Value,
    metadata: std.json.ObjectMap,
    allocator: std.mem.Allocator,
    
    pub fn create(allocator: std.mem.Allocator, id: []const u8, context: *WorkflowExecutionContext) !Checkpoint {
        var metadata = std.json.ObjectMap.init(allocator);
        try metadata.put("created_at", .{ .integer = std.time.milliTimestamp() });
        
        // Create context snapshot
        var snapshot = std.json.ObjectMap.init(allocator);
        
        // Copy variables
        var variables_obj = std.json.ObjectMap.init(allocator);
        var var_iter = context.variables.iterator();
        while (var_iter.next()) |entry| {
            try variables_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try snapshot.put("variables", .{ .object = variables_obj });
        
        // Copy step results
        var results_obj = std.json.ObjectMap.init(allocator);
        var result_iter = context.step_results.iterator();
        while (result_iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try snapshot.put("step_results", .{ .object = results_obj });
        
        try snapshot.put("execution_state", .{ .string = @tagName(context.execution_state) });
        if (context.current_step) |step| {
            try snapshot.put("current_step", .{ .string = step });
        }
        
        return Checkpoint{
            .id = id,
            .timestamp = std.time.milliTimestamp(),
            .context_snapshot = .{ .object = snapshot },
            .metadata = metadata,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Checkpoint) void {
        self.metadata.deinit();
    }
    
    pub fn serialize(self: *const Checkpoint, allocator: std.mem.Allocator) ![]u8 {
        var obj = std.json.ObjectMap.init(allocator);
        defer obj.deinit();
        
        try obj.put("id", .{ .string = self.id });
        try obj.put("timestamp", .{ .integer = self.timestamp });
        try obj.put("context_snapshot", self.context_snapshot);
        try obj.put("metadata", .{ .object = self.metadata });
        
        return std.json.stringifyAlloc(allocator, std.json.Value{ .object = obj }, .{});
    }
    
    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !Checkpoint {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();
        
        if (parsed.value != .object) return error.InvalidCheckpointFormat;
        const obj = parsed.value.object;
        
        return Checkpoint{
            .id = obj.get("id").?.string,
            .timestamp = obj.get("timestamp").?.integer,
            .context_snapshot = obj.get("context_snapshot").?,
            .metadata = obj.get("metadata").?.object,
            .allocator = allocator,
        };
    }
    
    pub fn restore(self: *const Checkpoint, context: *WorkflowExecutionContext) !void {
        if (self.context_snapshot != .object) return error.InvalidSnapshot;
        const snapshot = self.context_snapshot.object;
        
        // Restore variables
        if (snapshot.get("variables")) |vars| {
            if (vars == .object) {
                context.variables.clearRetainingCapacity();
                var var_iter = vars.object.iterator();
                while (var_iter.next()) |entry| {
                    try context.variables.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
        
        // Restore step results
        if (snapshot.get("step_results")) |results| {
            if (results == .object) {
                context.step_results.clearRetainingCapacity();
                var result_iter = results.object.iterator();
                while (result_iter.next()) |entry| {
                    try context.step_results.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
        
        // Restore execution state
        if (snapshot.get("execution_state")) |state| {
            if (state == .string) {
                context.execution_state = std.meta.stringToEnum(WorkflowExecutionState, state.string) orelse .pending;
            }
        }
        
        // Restore current step
        if (snapshot.get("current_step")) |step| {
            if (step == .string) {
                context.current_step = step.string;
            }
        }
    }
};

// Helper functions
fn generateInstanceId(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = @as(u64, @intCast(std.time.microTimestamp()));
    var rng = std.Random.DefaultPrng.init(timestamp);
    const random = rng.random().int(u32);
    
    return std.fmt.allocPrint(allocator, "{x}-{x}", .{ timestamp, random });
}

fn matchesPattern(key: []const u8, pattern: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) {
        const prefix = pattern[0 .. pattern.len - 1];
        return std.mem.startsWith(u8, key, prefix);
    }
    return std.mem.eql(u8, key, pattern);
}

// Tests
test "workflow state manager" {
    const allocator = std.testing.allocator;
    
    var state_manager = try WorkflowStateManager.init(allocator, "test_workflow", .{
        .storage_backend = .memory,
    });
    defer state_manager.deinit();
    
    // Create test context
    const workflow = WorkflowDefinition.init(allocator, "test", "Test");
    var context = WorkflowExecutionContext.init(allocator, &workflow);
    defer context.deinit();
    
    try context.setVariable("test_var", .{ .string = "test_value" });
    try context.setStepResult("step1", .{ .bool = true });
    
    // Save state
    try state_manager.saveState(&context);
    
    // Clear context
    context.variables.clearRetainingCapacity();
    context.step_results.clearRetainingCapacity();
    
    // Load state
    const loaded = try state_manager.loadState(&context);
    try std.testing.expect(loaded);
    
    // Verify state was restored
    try std.testing.expect(context.getVariable("test_var") != null);
    try std.testing.expectEqualStrings("test_value", context.getVariable("test_var").?.string);
    try std.testing.expect(context.getStepResult("step1") != null);
    try std.testing.expect(context.getStepResult("step1").?.bool);
}

test "checkpoints" {
    const allocator = std.testing.allocator;
    
    var state_manager = try WorkflowStateManager.init(allocator, "test_workflow", .{});
    defer state_manager.deinit();
    
    const workflow = WorkflowDefinition.init(allocator, "test", "Test");
    var context = WorkflowExecutionContext.init(allocator, &workflow);
    defer context.deinit();
    
    try context.setVariable("step", .{ .integer = 1 });
    
    // Create checkpoint
    try state_manager.createCheckpoint(&context, "checkpoint1");
    
    // Modify context
    try context.setVariable("step", .{ .integer = 2 });
    
    // Restore checkpoint
    const restored = try state_manager.restoreCheckpoint("checkpoint1", &context);
    try std.testing.expect(restored);
    
    // Verify checkpoint was restored
    try std.testing.expectEqual(@as(i64, 1), context.getVariable("step").?.integer);
}