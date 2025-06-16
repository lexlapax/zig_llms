// ABOUTME: Memory API bridge for exposing memory management functionality to scripts
// ABOUTME: Enables conversation history, context management, and memory operations from scripts

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms memory API
const memory = @import("../../memory.zig");
const short_term = @import("../../memory/short_term.zig");
const types = @import("../../types.zig");

/// Script memory store wrapper
const ScriptMemoryStore = struct {
    id: []const u8,
    store_type: MemoryType,
    context: *ScriptContext,
    messages: std.ArrayList(types.Message),
    max_messages: u32 = 100,
    max_tokens: ?u32 = null,

    const MemoryType = enum {
        short_term,
        conversation,
        episodic,
        semantic,
    };

    pub fn deinit(self: *ScriptMemoryStore) void {
        const allocator = self.context.allocator;
        allocator.free(self.id);

        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit();

        allocator.destroy(self);
    }
};

/// Global memory store registry
var memory_stores: ?std.StringHashMap(*ScriptMemoryStore) = null;
var stores_mutex = std.Thread.Mutex{};
var next_store_id: u32 = 1;

/// Memory Bridge implementation
pub const MemoryBridge = struct {
    pub const bridge = APIBridge{
        .name = "memory",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };

    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);

        module.* = ScriptModule{
            .name = "memory",
            .functions = &memory_functions,
            .constants = &memory_constants,
            .description = "Memory management and conversation history API",
            .version = "1.0.0",
        };

        return module;
    }

    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;

        stores_mutex.lock();
        defer stores_mutex.unlock();

        if (memory_stores == null) {
            memory_stores = std.StringHashMap(*ScriptMemoryStore).init(context.allocator);
        }
    }

    fn deinit() void {
        stores_mutex.lock();
        defer stores_mutex.unlock();

        if (memory_stores) |*stores| {
            var iter = stores.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            stores.deinit();
            memory_stores = null;
        }
    }
};

// Memory module functions
const memory_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "create",
        "Create a new memory store",
        1,
        createMemoryStore,
    ),
    createModuleFunction(
        "destroy",
        "Destroy a memory store and free resources",
        1,
        destroyMemoryStore,
    ),
    createModuleFunction(
        "add",
        "Add a message to memory",
        2,
        addMessage,
    ),
    createModuleFunction(
        "addBatch",
        "Add multiple messages to memory",
        2,
        addMessageBatch,
    ),
    createModuleFunction(
        "get",
        "Get messages from memory",
        2,
        getMessages,
    ),
    createModuleFunction(
        "getLast",
        "Get last N messages",
        2,
        getLastMessages,
    ),
    createModuleFunction(
        "getByRole",
        "Get messages filtered by role",
        2,
        getMessagesByRole,
    ),
    createModuleFunction(
        "search",
        "Search messages by content",
        2,
        searchMessages,
    ),
    createModuleFunction(
        "clear",
        "Clear all messages from memory",
        1,
        clearMemory,
    ),
    createModuleFunction(
        "truncate",
        "Truncate memory to size limit",
        2,
        truncateMemory,
    ),
    createModuleFunction(
        "getSize",
        "Get memory size information",
        1,
        getMemorySize,
    ),
    createModuleFunction(
        "getTokenCount",
        "Get total token count",
        1,
        getTokenCount,
    ),
    createModuleFunction(
        "summarize",
        "Summarize conversation history",
        1,
        summarizeMemory,
    ),
    createModuleFunction(
        "export",
        "Export memory to format",
        2,
        exportMemory,
    ),
    createModuleFunction(
        "import",
        "Import memory from data",
        2,
        importMemory,
    ),
    createModuleFunction(
        "merge",
        "Merge two memory stores",
        2,
        mergeMemoryStores,
    ),
    createModuleFunction(
        "fork",
        "Fork a memory store",
        1,
        forkMemoryStore,
    ),
    createModuleFunction(
        "snapshot",
        "Create a memory snapshot",
        1,
        snapshotMemory,
    ),
    createModuleFunction(
        "restore",
        "Restore from snapshot",
        2,
        restoreSnapshot,
    ),
    createModuleFunction(
        "list",
        "List all memory stores",
        0,
        listMemoryStores,
    ),
    createModuleFunction(
        "setLimit",
        "Set memory size limit",
        2,
        setMemoryLimit,
    ),
    createModuleFunction(
        "optimize",
        "Optimize memory storage",
        1,
        optimizeMemory,
    ),
};

// Memory module constants
const memory_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "TYPE_SHORT_TERM",
        ScriptValue{ .string = "short_term" },
        "Short-term conversation memory",
    ),
    createModuleConstant(
        "TYPE_CONVERSATION",
        ScriptValue{ .string = "conversation" },
        "Full conversation history",
    ),
    createModuleConstant(
        "TYPE_EPISODIC",
        ScriptValue{ .string = "episodic" },
        "Episodic memory with events",
    ),
    createModuleConstant(
        "TYPE_SEMANTIC",
        ScriptValue{ .string = "semantic" },
        "Semantic long-term memory",
    ),
    createModuleConstant(
        "ROLE_SYSTEM",
        ScriptValue{ .string = "system" },
        "System message role",
    ),
    createModuleConstant(
        "ROLE_USER",
        ScriptValue{ .string = "user" },
        "User message role",
    ),
    createModuleConstant(
        "ROLE_ASSISTANT",
        ScriptValue{ .string = "assistant" },
        "Assistant message role",
    ),
    createModuleConstant(
        "ROLE_FUNCTION",
        ScriptValue{ .string = "function" },
        "Function call/result role",
    ),
    createModuleConstant(
        "FORMAT_JSON",
        ScriptValue{ .string = "json" },
        "JSON export format",
    ),
    createModuleConstant(
        "FORMAT_TEXT",
        ScriptValue{ .string = "text" },
        "Plain text export format",
    ),
    createModuleConstant(
        "FORMAT_MARKDOWN",
        ScriptValue{ .string = "markdown" },
        "Markdown export format",
    ),
};

// Implementation functions

fn createMemoryStore(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }

    const config = args[0].object;
    const context = @fieldParentPtr(ScriptContext, "allocator", config.allocator);
    const allocator = context.allocator;

    // Extract configuration
    const store_type_str = if (config.get("type")) |t|
        try t.toZig([]const u8, allocator)
    else
        "short_term";

    const store_type = blk: {
        if (std.mem.eql(u8, store_type_str, "short_term")) {
            break :blk ScriptMemoryStore.MemoryType.short_term;
        } else if (std.mem.eql(u8, store_type_str, "conversation")) {
            break :blk ScriptMemoryStore.MemoryType.conversation;
        } else if (std.mem.eql(u8, store_type_str, "episodic")) {
            break :blk ScriptMemoryStore.MemoryType.episodic;
        } else if (std.mem.eql(u8, store_type_str, "semantic")) {
            break :blk ScriptMemoryStore.MemoryType.semantic;
        } else {
            return error.InvalidMemoryType;
        }
    };

    const max_messages = if (config.get("max_messages")) |m|
        try m.toZig(u32, allocator)
    else
        100;

    const max_tokens = if (config.get("max_tokens")) |t|
        try t.toZig(u32, allocator)
    else
        null;

    // Generate unique ID
    stores_mutex.lock();
    const store_id = try std.fmt.allocPrint(allocator, "memory_{}", .{next_store_id});
    next_store_id += 1;
    stores_mutex.unlock();

    // Create memory store
    const store = try allocator.create(ScriptMemoryStore);
    store.* = ScriptMemoryStore{
        .id = store_id,
        .store_type = store_type,
        .context = context,
        .messages = std.ArrayList(types.Message).init(allocator),
        .max_messages = max_messages,
        .max_tokens = max_tokens,
    };

    // Register store
    stores_mutex.lock();
    defer stores_mutex.unlock();

    if (memory_stores) |*stores| {
        try stores.put(store_id, store);
    }

    return ScriptValue{ .string = store_id };
}

fn destroyMemoryStore(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;

    stores_mutex.lock();
    defer stores_mutex.unlock();

    if (memory_stores) |*stores| {
        if (stores.fetchRemove(store_id)) |kv| {
            kv.value.deinit();
            return ScriptValue{ .boolean = true };
        }
    }

    return ScriptValue{ .boolean = false };
}

fn addMessage(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const message_obj = args[1].object;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = store.?.context.allocator;

    // Convert to Message
    const role_str = if (message_obj.get("role")) |r|
        try r.toZig([]const u8, allocator)
    else
        return error.MissingField;

    const role = try parseRole(role_str);

    const content_str = if (message_obj.get("content")) |c|
        try c.toZig([]const u8, allocator)
    else
        return error.MissingField;

    var message = types.Message{
        .role = role,
        .content = std.ArrayList(types.Content).init(allocator),
    };

    // Add text content
    const text_content = types.Content{
        .text = .{ .text = try allocator.dupe(u8, content_str) },
    };
    try message.content.append(text_content);

    // Add to store
    try store.?.messages.append(message);

    // Enforce limits
    if (store.?.max_messages > 0 and store.?.messages.items.len > store.?.max_messages) {
        // Remove oldest messages
        const to_remove = store.?.messages.items.len - store.?.max_messages;
        for (store.?.messages.items[0..to_remove]) |*msg| {
            msg.deinit();
        }
        std.mem.copy(types.Message, store.?.messages.items[0..], store.?.messages.items[to_remove..]);
        store.?.messages.shrinkRetainingCapacity(store.?.max_messages);
    }

    return ScriptValue{ .boolean = true };
}

fn addMessageBatch(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .array) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const messages = args[1].array;

    for (messages.items) |msg| {
        const add_args = [_]ScriptValue{ ScriptValue{ .string = store_id }, msg };
        _ = try addMessage(&add_args);
    }

    return ScriptValue{ .integer = @intCast(messages.items.len) };
}

fn getMessages(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const options = if (args[1] == .object) args[1].object else null;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = store.?.context.allocator;
    const messages = store.?.messages.items;

    // Apply filters if provided
    var start: usize = 0;
    var end: usize = messages.len;

    if (options) |opts| {
        if (opts.get("offset")) |offset| {
            start = @min(try offset.toZig(usize, allocator), messages.len);
        }
        if (opts.get("limit")) |limit| {
            end = @min(start + try limit.toZig(usize, allocator), messages.len);
        }
    }

    // Convert messages to ScriptValue
    var result = try ScriptValue.Array.init(allocator, end - start);

    for (messages[start..end], 0..) |msg, i| {
        var msg_obj = ScriptValue.Object.init(allocator);
        try msg_obj.put("role", ScriptValue{ .string = try allocator.dupe(u8, @tagName(msg.role)) });

        // Extract text content
        var content_text = std.ArrayList(u8).init(allocator);
        for (msg.content.items) |content| {
            switch (content) {
                .text => |text| try content_text.appendSlice(text.text),
                else => {},
            }
        }

        try msg_obj.put("content", ScriptValue{ .string = try content_text.toOwnedSlice() });
        result.items[i] = ScriptValue{ .object = msg_obj };
    }

    return ScriptValue{ .array = result };
}

fn getLastMessages(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .integer) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const count = @as(usize, @intCast(args[1].integer));
    const allocator = @fieldParentPtr(ScriptContext, "allocator", store_id).allocator;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const messages = store.?.messages.items;
    const start = if (messages.len > count) messages.len - count else 0;

    var options = ScriptValue.Object.init(allocator);
    try options.put("offset", ScriptValue{ .integer = @intCast(start) });
    try options.put("limit", ScriptValue{ .integer = @intCast(count) });

    const get_args = [_]ScriptValue{
        ScriptValue{ .string = store_id },
        ScriptValue{ .object = options },
    };

    return try getMessages(&get_args);
}

fn getMessagesByRole(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const role_str = args[1].string;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = store.?.context.allocator;
    const role = try parseRole(role_str);

    var filtered = std.ArrayList(ScriptValue).init(allocator);

    for (store.?.messages.items) |msg| {
        if (msg.role == role) {
            var msg_obj = ScriptValue.Object.init(allocator);
            try msg_obj.put("role", ScriptValue{ .string = try allocator.dupe(u8, @tagName(msg.role)) });

            // Extract text content
            var content_text = std.ArrayList(u8).init(allocator);
            for (msg.content.items) |content| {
                switch (content) {
                    .text => |text| try content_text.appendSlice(text.text),
                    else => {},
                }
            }

            try msg_obj.put("content", ScriptValue{ .string = try content_text.toOwnedSlice() });
            try filtered.append(ScriptValue{ .object = msg_obj });
        }
    }

    return ScriptValue{ .array = .{ .items = try filtered.toOwnedSlice(), .allocator = allocator } };
}

fn searchMessages(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const query = args[1].string;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = store.?.context.allocator;
    var results = std.ArrayList(ScriptValue).init(allocator);

    for (store.?.messages.items) |msg| {
        var content_text = std.ArrayList(u8).init(allocator);
        defer content_text.deinit();

        for (msg.content.items) |content| {
            switch (content) {
                .text => |text| try content_text.appendSlice(text.text),
                else => {},
            }
        }

        if (std.mem.containsAtLeast(u8, content_text.items, 1, query)) {
            var msg_obj = ScriptValue.Object.init(allocator);
            try msg_obj.put("role", ScriptValue{ .string = try allocator.dupe(u8, @tagName(msg.role)) });
            try msg_obj.put("content", ScriptValue{ .string = try allocator.dupe(u8, content_text.items) });
            try results.append(ScriptValue{ .object = msg_obj });
        }
    }

    return ScriptValue{ .array = .{ .items = try results.toOwnedSlice(), .allocator = allocator } };
}

fn clearMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    for (store.?.messages.items) |*msg| {
        msg.deinit();
    }
    store.?.messages.clearRetainingCapacity();

    return ScriptValue{ .boolean = true };
}

fn truncateMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .integer) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const max_size = @as(usize, @intCast(args[1].integer));

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    if (store.?.messages.items.len > max_size) {
        const to_remove = store.?.messages.items.len - max_size;
        for (store.?.messages.items[0..to_remove]) |*msg| {
            msg.deinit();
        }
        std.mem.copy(types.Message, store.?.messages.items[0..], store.?.messages.items[to_remove..]);
        store.?.messages.shrinkRetainingCapacity(max_size);
    }

    return ScriptValue{ .boolean = true };
}

fn getMemorySize(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = store.?.context.allocator;
    var size_info = ScriptValue.Object.init(allocator);

    try size_info.put("message_count", ScriptValue{ .integer = @intCast(store.?.messages.items.len) });
    try size_info.put("max_messages", ScriptValue{ .integer = @intCast(store.?.max_messages) });

    if (store.?.max_tokens) |max_tokens| {
        try size_info.put("max_tokens", ScriptValue{ .integer = @intCast(max_tokens) });
    } else {
        try size_info.put("max_tokens", ScriptValue.nil);
    }

    return ScriptValue{ .object = size_info };
}

fn getTokenCount(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    // Estimate token count (simplified - 4 chars per token)
    var total_chars: usize = 0;
    for (store.?.messages.items) |msg| {
        for (msg.content.items) |content| {
            switch (content) {
                .text => |text| total_chars += text.text.len,
                else => {},
            }
        }
    }

    const estimated_tokens = total_chars / 4;
    return ScriptValue{ .integer = @intCast(estimated_tokens) };
}

fn summarizeMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", store_id).allocator;

    // Create a placeholder summary
    var summary = ScriptValue.Object.init(allocator);
    try summary.put("store_id", ScriptValue{ .string = try allocator.dupe(u8, store_id) });
    try summary.put("summary", ScriptValue{ .string = try allocator.dupe(u8, "Conversation summary placeholder") });
    try summary.put("key_points", ScriptValue{ .array = try ScriptValue.Array.init(allocator, 0) });

    return ScriptValue{ .object = summary };
}

fn exportMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const format = args[1].string;

    // Get all messages
    var options = ScriptValue.Object.init(undefined);
    const get_args = [_]ScriptValue{
        ScriptValue{ .string = store_id },
        ScriptValue{ .object = options },
    };

    const messages = try getMessages(&get_args);

    if (std.mem.eql(u8, format, "json")) {
        return messages;
    } else if (std.mem.eql(u8, format, "text")) {
        // Convert to text format
        const allocator = @fieldParentPtr(ScriptContext, "allocator", store_id).allocator;
        var text = std.ArrayList(u8).init(allocator);

        if (messages == .array) {
            for (messages.array.items) |msg| {
                if (msg == .object) {
                    if (msg.object.get("role")) |role| {
                        if (role == .string) {
                            try text.appendSlice(role.string);
                            try text.appendSlice(": ");
                        }
                    }
                    if (msg.object.get("content")) |content| {
                        if (content == .string) {
                            try text.appendSlice(content.string);
                            try text.appendSlice("\n");
                        }
                    }
                }
            }
        }

        return ScriptValue{ .string = try text.toOwnedSlice() };
    }

    return messages;
}

fn importMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const data = args[1];

    // Clear existing messages
    const clear_args = [_]ScriptValue{ScriptValue{ .string = store_id }};
    _ = try clearMemory(&clear_args);

    // Import messages
    if (data == .array) {
        const batch_args = [_]ScriptValue{
            ScriptValue{ .string = store_id },
            data,
        };
        return try addMessageBatch(&batch_args);
    }

    return ScriptValue{ .boolean = false };
}

fn mergeMemoryStores(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .string) {
        return error.InvalidArguments;
    }

    const store1_id = args[0].string;
    const store2_id = args[1].string;

    // Get messages from store2
    var options = ScriptValue.Object.init(undefined);
    const get_args = [_]ScriptValue{
        ScriptValue{ .string = store2_id },
        ScriptValue{ .object = options },
    };

    const messages = try getMessages(&get_args);

    // Add to store1
    if (messages == .array) {
        const batch_args = [_]ScriptValue{
            ScriptValue{ .string = store1_id },
            messages,
        };
        _ = try addMessageBatch(&batch_args);
    }

    return ScriptValue{ .boolean = true };
}

fn forkMemoryStore(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const source_id = args[0].string;

    stores_mutex.lock();
    const source_store = if (memory_stores) |*stores|
        stores.get(source_id)
    else
        null;
    stores_mutex.unlock();

    if (source_store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = source_store.?.context.allocator;

    // Create new store with same configuration
    var config = ScriptValue.Object.init(allocator);
    try config.put("type", ScriptValue{ .string = try allocator.dupe(u8, @tagName(source_store.?.store_type)) });
    try config.put("max_messages", ScriptValue{ .integer = @intCast(source_store.?.max_messages) });

    const create_args = [_]ScriptValue{ScriptValue{ .object = config }};
    const new_store_id = try createMemoryStore(&create_args);

    // Copy messages
    var options = ScriptValue.Object.init(undefined);
    const get_args = [_]ScriptValue{
        ScriptValue{ .string = source_id },
        ScriptValue{ .object = options },
    };

    const messages = try getMessages(&get_args);

    if (messages == .array) {
        const batch_args = [_]ScriptValue{
            new_store_id,
            messages,
        };
        _ = try addMessageBatch(&batch_args);
    }

    return new_store_id;
}

fn snapshotMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const allocator = @fieldParentPtr(ScriptContext, "allocator", store_id).allocator;

    // Export memory as snapshot
    const export_args = [_]ScriptValue{
        ScriptValue{ .string = store_id },
        ScriptValue{ .string = "json" },
    };

    const snapshot_data = try exportMemory(&export_args);

    // Create snapshot object
    var snapshot = ScriptValue.Object.init(allocator);
    try snapshot.put("store_id", ScriptValue{ .string = try allocator.dupe(u8, store_id) });
    try snapshot.put("timestamp", ScriptValue{ .integer = std.time.timestamp() });
    try snapshot.put("data", snapshot_data);

    return ScriptValue{ .object = snapshot };
}

fn restoreSnapshot(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const snapshot = args[1].object;

    if (snapshot.get("data")) |data| {
        const import_args = [_]ScriptValue{
            ScriptValue{ .string = store_id },
            data,
        };
        return try importMemory(&import_args);
    }

    return ScriptValue{ .boolean = false };
}

fn listMemoryStores(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    stores_mutex.lock();
    defer stores_mutex.unlock();

    if (memory_stores) |*stores| {
        const allocator = stores.allocator;
        var list = try ScriptValue.Array.init(allocator, stores.count());

        var iter = stores.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            var store_info = ScriptValue.Object.init(allocator);
            try store_info.put("id", ScriptValue{ .string = try allocator.dupe(u8, entry.key_ptr.*) });
            try store_info.put("type", ScriptValue{ .string = try allocator.dupe(u8, @tagName(entry.value_ptr.*.store_type)) });
            try store_info.put("message_count", ScriptValue{ .integer = @intCast(entry.value_ptr.*.messages.items.len) });
            list.items[i] = ScriptValue{ .object = store_info };
        }

        return ScriptValue{ .array = list };
    }

    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn setMemoryLimit(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .object) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;
    const limits = args[1].object;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    const allocator = store.?.context.allocator;

    if (limits.get("max_messages")) |max_msgs| {
        store.?.max_messages = try max_msgs.toZig(u32, allocator);
    }

    if (limits.get("max_tokens")) |max_toks| {
        store.?.max_tokens = try max_toks.toZig(u32, allocator);
    }

    return ScriptValue{ .boolean = true };
}

fn optimizeMemory(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const store_id = args[0].string;

    stores_mutex.lock();
    const store = if (memory_stores) |*stores|
        stores.get(store_id)
    else
        null;
    stores_mutex.unlock();

    if (store == null) {
        return error.MemoryStoreNotFound;
    }

    // Shrink to fit
    store.?.messages.shrinkAndFree(store.?.messages.items.len);

    return ScriptValue{ .boolean = true };
}

// Helper functions

fn parseRole(role_str: []const u8) !types.Role {
    if (std.mem.eql(u8, role_str, "system")) {
        return .system;
    } else if (std.mem.eql(u8, role_str, "user")) {
        return .user;
    } else if (std.mem.eql(u8, role_str, "assistant")) {
        return .assistant;
    } else if (std.mem.eql(u8, role_str, "function")) {
        return .function;
    }
    return error.InvalidRole;
}

// Tests
test "MemoryBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const module = try MemoryBridge.getModule(allocator);
    defer allocator.destroy(module);

    try testing.expectEqualStrings("memory", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}
