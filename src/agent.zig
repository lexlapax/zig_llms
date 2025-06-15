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

// Base implementation for all agents
pub const BaseAgent = struct {
    agent: Agent,
    name: []const u8,
    description: []const u8,
    config: AgentConfig,
    context: ?*RunContext,
    allocator: std.mem.Allocator,
    
    const vtable = Agent.VTable{
        .initialize = baseInitialize,
        .beforeRun = baseBeforeRun,
        .run = baseRun,
        .afterRun = baseAfterRun,
        .cleanup = baseCleanup,
    };
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, config: AgentConfig) !*BaseAgent {
        const self = try allocator.create(BaseAgent);
        
        const state = try allocator.create(State);
        state.* = State.init(allocator);
        
        self.* = BaseAgent{
            .agent = Agent{
                .vtable = &vtable,
                .state = state,
            },
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, config.description orelse ""),
            .config = config,
            .context = null,
            .allocator = allocator,
        };
        
        return self;
    }
    
    pub fn deinit(self: *BaseAgent) void {
        self.agent.state.deinit();
        self.allocator.destroy(self.agent.state);
        self.allocator.free(self.name);
        self.allocator.free(self.description);
        self.allocator.destroy(self);
    }
    
    fn baseInitialize(agent: *Agent, context: *RunContext) anyerror!void {
        const self: *BaseAgent = @fieldParentPtr("agent", agent);
        self.context = context;
        
        // Store initialization metadata
        try agent.state.metadata.put("initialized_at", .{ .integer = std.time.timestamp() });
        try agent.state.metadata.put("agent_name", .{ .string = self.name });
    }
    
    fn baseBeforeRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        // Base implementation - can be overridden
        _ = agent;
        return input;
    }
    
    fn baseRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        // Base implementation - must be overridden in derived agents
        _ = agent;
        _ = input;
        return error.NotImplemented;
    }
    
    fn baseAfterRun(agent: *Agent, output: std.json.Value) anyerror!std.json.Value {
        // Base implementation - can be overridden
        _ = agent;
        return output;
    }
    
    fn baseCleanup(agent: *Agent) void {
        const self: *BaseAgent = @fieldParentPtr("agent", agent);
        
        // Clear context reference
        self.context = null;
        
        // Update metadata
        agent.state.metadata.put("cleaned_up_at", .{ .integer = std.time.timestamp() }) catch {};
    }
};

// LLM-based agent
pub const LLMAgent = struct {
    base: BaseAgent,
    provider: *types.Provider,
    system_prompt: ?[]const u8,
    
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        config: AgentConfig,
        provider: *types.Provider,
    ) !*LLMAgent {
        const base = try BaseAgent.init(allocator, name, config);
        errdefer base.deinit();
        
        const self = try allocator.create(LLMAgent);
        self.* = LLMAgent{
            .base = base.*,
            .provider = provider,
            .system_prompt = if (config.system_prompt) |prompt|
                try allocator.dupe(u8, prompt)
            else
                null,
        };
        
        // Override vtable for LLM-specific behavior
        const llm_vtable = try allocator.create(Agent.VTable);
        llm_vtable.* = .{
            .initialize = llmInitialize,
            .beforeRun = llmBeforeRun,
            .run = llmRun,
            .afterRun = llmAfterRun,
            .cleanup = llmCleanup,
        };
        self.base.agent.vtable = llm_vtable;
        
        // Free the base agent struct (we've copied its contents)
        allocator.destroy(base);
        
        return self;
    }
    
    pub fn deinit(self: *LLMAgent) void {
        if (self.system_prompt) |prompt| {
            self.base.allocator.free(prompt);
        }
        self.base.allocator.destroy(self.base.agent.vtable);
        self.base.deinit();
    }
    
    fn llmInitialize(agent: *Agent, context: *RunContext) anyerror!void {
        const self: *BaseAgent = @fieldParentPtr("agent", agent);
        const llm_self: *LLMAgent = @fieldParentPtr("base", self);
        
        // Call base initialization
        try BaseAgent.baseInitialize(agent, context);
        
        // Add LLM-specific initialization
        if (llm_self.system_prompt) |prompt| {
            try agent.state.metadata.put("system_prompt", .{ .string = prompt });
        }
    }
    
    fn llmBeforeRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        // Prepare input for LLM
        const self: *BaseAgent = @fieldParentPtr("agent", agent);
        const llm_self: *LLMAgent = @fieldParentPtr("base", self);
        _ = llm_self;
        
        // TODO: Add input preprocessing (e.g., prompt formatting)
        return input;
    }
    
    fn llmRun(agent: *Agent, input: std.json.Value) anyerror!std.json.Value {
        const self: *BaseAgent = @fieldParentPtr("agent", agent);
        const llm_self: *LLMAgent = @fieldParentPtr("base", self);
        
        // Convert input to messages
        var messages = std.ArrayList(types.Message).init(self.allocator);
        defer messages.deinit();
        
        // Add system message if present
        if (llm_self.system_prompt) |prompt| {
            try messages.append(.{
                .role = .system,
                .content = .{ .text = prompt },
            });
        }
        
        // Add conversation history
        const history = agent.state.getMessages();
        try messages.appendSlice(history);
        
        // Add current input as user message
        const input_text = switch (input) {
            .string => |s| s,
            else => try std.json.stringifyAlloc(self.allocator, input, .{}),
        };
        defer if (input != .string) self.allocator.free(input_text);
        
        try messages.append(.{
            .role = .user,
            .content = .{ .text = input_text },
        });
        
        // Store user message in state
        try agent.state.addMessage(messages.items[messages.items.len - 1]);
        
        // Create request
        const request = types.GenerateRequest{
            .messages = messages.items,
            .options = .{},
        };
        
        // Call LLM provider
        const response = try llm_self.provider.complete(request);
        defer response.deinit();
        
        // Store assistant response in state
        try agent.state.addMessage(.{
            .role = .assistant,
            .content = response.content,
        });
        
        // Convert response to JSON value
        const response_text = switch (response.content) {
            .text => |t| t,
            .json => |j| try std.json.stringifyAlloc(self.allocator, j, .{}),
        };
        defer if (response.content == .json) self.allocator.free(response_text);
        
        return std.json.Value{ .string = response_text };
    }
    
    fn llmAfterRun(agent: *Agent, output: std.json.Value) anyerror!std.json.Value {
        // Post-process LLM output
        return BaseAgent.baseAfterRun(agent, output);
    }
    
    fn llmCleanup(agent: *Agent) void {
        BaseAgent.baseCleanup(agent);
    }
};

// Configuration for agents
pub const AgentConfig = struct {
    description: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_iterations: u32 = 10,
    timeout_ms: u32 = 30000,
    enable_logging: bool = true,
    enable_caching: bool = true,
    metadata: ?std.json.ObjectMap = null,
};

// Agent lifecycle management
pub const AgentLifecycle = struct {
    pub const Status = enum {
        created,
        initializing,
        ready,
        running,
        paused,
        @"error",
        terminated,
    };
    
    status: Status,
    created_at: i64,
    initialized_at: ?i64,
    last_run_at: ?i64,
    error_count: u32,
    run_count: u32,
    
    pub fn init() AgentLifecycle {
        return .{
            .status = .created,
            .created_at = std.time.timestamp(),
            .initialized_at = null,
            .last_run_at = null,
            .error_count = 0,
            .run_count = 0,
        };
    }
    
    pub fn markInitialized(self: *AgentLifecycle) void {
        self.status = .ready;
        self.initialized_at = std.time.timestamp();
    }
    
    pub fn markRunning(self: *AgentLifecycle) void {
        self.status = .running;
        self.last_run_at = std.time.timestamp();
        self.run_count += 1;
    }
    
    pub fn markCompleted(self: *AgentLifecycle) void {
        self.status = .ready;
    }
    
    pub fn markError(self: *AgentLifecycle) void {
        self.status = .@"error";
        self.error_count += 1;
    }
    
    pub fn markTerminated(self: *AgentLifecycle) void {
        self.status = .terminated;
    }
};
