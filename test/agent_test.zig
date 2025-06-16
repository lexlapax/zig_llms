// ABOUTME: Tests for agent system including lifecycle and state management
// ABOUTME: Validates agent initialization, execution hooks, and cleanup

const std = @import("std");
const agent_mod = @import("../src/agent.zig");
const state_mod = @import("../src/state.zig");
const types = @import("../src/types.zig");
const context = @import("../src/context.zig");
const testing = @import("../src/testing/helpers.zig");

test "base agent lifecycle" {
    const allocator = std.testing.allocator;

    const config = agent_mod.AgentConfig{
        .description = "Test agent",
        .max_iterations = 5,
    };

    var base = try agent_mod.BaseAgent.init(allocator, "test_agent", config);
    defer base.deinit();

    var run_context = context.RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();

    // Test initialization
    try base.agent.initialize(&run_context);

    // Verify metadata was set
    const init_time = base.agent.state.metadata.get("initialized_at");
    try std.testing.expect(init_time != null);

    const agent_name = base.agent.state.metadata.get("agent_name");
    try std.testing.expect(agent_name != null);
    try std.testing.expectEqualStrings("test_agent", agent_name.?.string);

    // Test cleanup
    base.agent.cleanup();

    const cleanup_time = base.agent.state.metadata.get("cleaned_up_at");
    try std.testing.expect(cleanup_time != null);
}

test "agent execution flow" {
    const allocator = std.testing.allocator;

    // Create a custom test agent
    const TestAgent = struct {
        base: agent_mod.BaseAgent,
        before_run_called: bool = false,
        run_called: bool = false,
        after_run_called: bool = false,

        pub fn init(alloc: std.mem.Allocator) !*@This() {
            const base = try agent_mod.BaseAgent.init(alloc, "test_exec_agent", .{});
            errdefer base.deinit();

            const self = try alloc.create(@This());
            self.* = .{
                .base = base.*,
                .before_run_called = false,
                .run_called = false,
                .after_run_called = false,
            };

            // Override vtable
            const test_vtable = try alloc.create(agent_mod.Agent.VTable);
            test_vtable.* = .{
                .initialize = agent_mod.BaseAgent.baseInitialize,
                .beforeRun = testBeforeRun,
                .run = testRun,
                .afterRun = testAfterRun,
                .cleanup = agent_mod.BaseAgent.baseCleanup,
            };
            self.base.agent.vtable = test_vtable;

            // Free the base agent struct
            alloc.destroy(base);

            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.base.allocator.destroy(self.base.agent.vtable);
            self.base.deinit();
        }

        fn testBeforeRun(ag: *agent_mod.Agent, input: std.json.Value) anyerror!std.json.Value {
            const base_agent: *agent_mod.BaseAgent = @fieldParentPtr("agent", ag);
            const self: *@This() = @fieldParentPtr("base", base_agent);
            self.before_run_called = true;
            return input;
        }

        fn testRun(ag: *agent_mod.Agent, input: std.json.Value) anyerror!std.json.Value {
            const base_agent: *agent_mod.BaseAgent = @fieldParentPtr("agent", ag);
            const self: *@This() = @fieldParentPtr("base", base_agent);
            self.run_called = true;

            // Echo the input
            return input;
        }

        fn testAfterRun(ag: *agent_mod.Agent, output: std.json.Value) anyerror!std.json.Value {
            const base_agent: *agent_mod.BaseAgent = @fieldParentPtr("agent", ag);
            const self: *@This() = @fieldParentPtr("base", base_agent);
            self.after_run_called = true;
            return output;
        }
    };

    var test_agent = try TestAgent.init(allocator);
    defer test_agent.deinit();

    var run_context = context.RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();

    const input = std.json.Value{ .string = "test input" };
    const result = try test_agent.base.agent.execute(&run_context, input);

    // Verify all hooks were called
    try std.testing.expect(test_agent.before_run_called);
    try std.testing.expect(test_agent.run_called);
    try std.testing.expect(test_agent.after_run_called);

    // Verify result
    try std.testing.expectEqualStrings("test input", result.string);
}

test "agent state management" {
    const allocator = std.testing.allocator;

    var base = try agent_mod.BaseAgent.init(allocator, "state_test_agent", .{});
    defer base.deinit();

    // Test state operations
    try base.agent.state.update("key1", .{ .string = "value1" });
    try base.agent.state.update("key2", .{ .integer = 42 });

    const value1 = base.agent.state.get("key1");
    try std.testing.expect(value1 != null);
    try std.testing.expectEqualStrings("value1", value1.?.string);

    // Test message tracking
    const msg = types.Message{
        .role = .user,
        .content = .{ .text = "Hello agent" },
    };
    try base.agent.state.addMessage(msg);

    const messages = base.agent.state.getMessages();
    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("Hello agent", messages[0].content.text);

    // Test artifacts
    try base.agent.state.setArtifact("result", "computation result");
    const artifact = base.agent.state.getArtifact("result");
    try std.testing.expect(artifact != null);
    try std.testing.expectEqualStrings("computation result", artifact.?);
}

test "agent lifecycle status" {
    const allocator = std.testing.allocator;

    var lifecycle = agent_mod.AgentLifecycle.init();

    // Initial status
    try std.testing.expectEqual(agent_mod.AgentLifecycle.Status.created, lifecycle.status);
    try std.testing.expect(lifecycle.initialized_at == null);

    // Mark initialized
    lifecycle.markInitialized();
    try std.testing.expectEqual(agent_mod.AgentLifecycle.Status.ready, lifecycle.status);
    try std.testing.expect(lifecycle.initialized_at != null);

    // Mark running
    lifecycle.markRunning();
    try std.testing.expectEqual(agent_mod.AgentLifecycle.Status.running, lifecycle.status);
    try std.testing.expectEqual(@as(u32, 1), lifecycle.run_count);

    // Mark completed
    lifecycle.markCompleted();
    try std.testing.expectEqual(agent_mod.AgentLifecycle.Status.ready, lifecycle.status);

    // Mark error
    lifecycle.markError();
    try std.testing.expectEqual(agent_mod.AgentLifecycle.Status.@"error", lifecycle.status);
    try std.testing.expectEqual(@as(u32, 1), lifecycle.error_count);

    // Mark terminated
    lifecycle.markTerminated();
    try std.testing.expectEqual(agent_mod.AgentLifecycle.Status.terminated, lifecycle.status);
}

test "state thread safety" {
    const allocator = std.testing.allocator;

    var state = state_mod.State.init(allocator);
    defer state.deinit();

    // Spawn multiple threads to update state concurrently
    const thread_count = 4;
    var threads: [thread_count]std.Thread = undefined;

    const ThreadContext = struct {
        state: *state_mod.State,
        thread_id: u32,

        fn threadFn(ctx: @This()) void {
            const key = std.fmt.allocPrint(ctx.state.allocator, "thread_{}", .{ctx.thread_id}) catch return;
            defer ctx.state.allocator.free(key);

            for (0..10) |i| {
                ctx.state.update(key, .{ .integer = @as(i64, @intCast(i)) }) catch return;
                std.time.sleep(1000); // 1 microsecond
            }
        }
    };

    // Start threads
    for (0..thread_count) |i| {
        const ctx = ThreadContext{
            .state = &state,
            .thread_id = @as(u32, @intCast(i)),
        };
        threads[i] = std.Thread.spawn(.{}, ThreadContext.threadFn, .{ctx}) catch unreachable;
    }

    // Wait for threads
    for (threads) |thread| {
        thread.join();
    }

    // Verify all updates were applied
    for (0..thread_count) |i| {
        const key = try std.fmt.allocPrint(allocator, "thread_{}", .{i});
        defer allocator.free(key);

        const value = state.get(key);
        try std.testing.expect(value != null);
        try std.testing.expectEqual(@as(i64, 9), value.?.integer);
    }
}
