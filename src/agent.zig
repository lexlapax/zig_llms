// ABOUTME: Core agent implementation with lifecycle management and execution logic
// ABOUTME: Provides base agent interface and state management for LLM interactions

const std = @import("std");
const types = @import("types.zig");
const State = @import("state.zig").State;
const RunContext = @import("context.zig").RunContext;

pub const Agent = struct {
    vtable: *const VTable,
    state: *State,

    pub const VTable = struct {
        initialize: *const fn (self: *Agent, context: *RunContext) anyerror!void,
        beforeRun: *const fn (self: *Agent, input: std.json.Value) anyerror!std.json.Value,
        run: *const fn (self: *Agent, input: std.json.Value) anyerror!std.json.Value,
        afterRun: *const fn (self: *Agent, output: std.json.Value) anyerror!std.json.Value,
        cleanup: *const fn (self: *Agent) void,
    };

    pub fn initialize(self: *Agent, context: *RunContext) !void {
        return self.vtable.initialize(self, context);
    }

    pub fn beforeRun(self: *Agent, input: std.json.Value) !std.json.Value {
        return self.vtable.beforeRun(self, input);
    }

    pub fn run(self: *Agent, input: std.json.Value) !std.json.Value {
        return self.vtable.run(self, input);
    }

    pub fn afterRun(self: *Agent, output: std.json.Value) !std.json.Value {
        return self.vtable.afterRun(self, output);
    }

    pub fn cleanup(self: *Agent) void {
        self.vtable.cleanup(self);
    }

    pub fn execute(self: *Agent, context: *RunContext, input: std.json.Value) !std.json.Value {
        try self.initialize(context);
        defer self.cleanup();

        const processed_input = try self.beforeRun(input);
        const output = try self.run(processed_input);
        const processed_output = try self.afterRun(output);

        return processed_output;
    }
};

pub const AgentType = enum {
    llm,
    workflow,
    tool,
    composite,
};

// TODO: Implement specific agent types (BaseAgent, LLMAgent, WorkflowAgent, etc.)
// TODO: Add agent factory pattern
// TODO: Implement conversation tracking
