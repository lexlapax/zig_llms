// ABOUTME: Execution context for dependency injection across the system
// ABOUTME: Provides access to providers, tools, logging, and tracing for all components

const std = @import("std");
const Provider = @import("provider.zig").Provider;
const ToolRegistry = @import("tool_registry.zig").ToolRegistry;
const State = @import("state.zig").State;

pub const Logger = struct {
    level: LogLevel,
    
    pub const LogLevel = enum {
        debug,
        info,
        warn,
        err,
    };
    
    pub fn log(self: *const Logger, level: LogLevel, comptime format: []const u8, args: anytype) void {
        if (@intFromEnum(level) >= @intFromEnum(self.level)) {
            const level_str = switch (level) {
                .debug => "DEBUG",
                .info => "INFO",
                .warn => "WARN",
                .err => "ERROR",
            };
            std.debug.print("[{s}] " ++ format ++ "\n", .{level_str} ++ args);
        }
    }
    
    pub fn debug(self: *const Logger, comptime format: []const u8, args: anytype) void {
        self.log(.debug, format, args);
    }
    
    pub fn info(self: *const Logger, comptime format: []const u8, args: anytype) void {
        self.log(.info, format, args);
    }
    
    pub fn warn(self: *const Logger, comptime format: []const u8, args: anytype) void {
        self.log(.warn, format, args);
    }
    
    pub fn err(self: *const Logger, comptime format: []const u8, args: anytype) void {
        self.log(.err, format, args);
    }
};

pub const Tracer = struct {
    // TODO: Implement tracing functionality
};

pub const RunContext = struct {
    allocator: std.mem.Allocator,
    provider: *Provider,
    tools: *ToolRegistry,
    logger: Logger,
    tracer: ?*Tracer,
    state: *State,
    parent: ?*const RunContext,
    
    pub fn init(
        allocator: std.mem.Allocator,
        provider: *Provider,
        tools: *ToolRegistry,
        state: *State,
    ) RunContext {
        return RunContext{
            .allocator = allocator,
            .provider = provider,
            .tools = tools,
            .logger = Logger{ .level = .info },
            .tracer = null,
            .state = state,
            .parent = null,
        };
    }
    
    pub fn withLogger(self: RunContext, logger: Logger) RunContext {
        var ctx = self;
        ctx.logger = logger;
        return ctx;
    }
    
    pub fn withTracer(self: RunContext, tracer: *Tracer) RunContext {
        var ctx = self;
        ctx.tracer = tracer;
        return ctx;
    }
    
    pub fn withParent(self: RunContext, parent: *const RunContext) RunContext {
        var ctx = self;
        ctx.parent = parent;
        return ctx;
    }
    
    pub fn createChild(self: *const RunContext, allocator: std.mem.Allocator) !RunContext {
        const child_state = try self.state.clone(allocator);
        
        return RunContext{
            .allocator = allocator,
            .provider = self.provider,
            .tools = self.tools,
            .logger = self.logger,
            .tracer = self.tracer,
            .state = &child_state,
            .parent = self,
        };
    }
};

test "run context" {
    const allocator = std.testing.allocator;
    
    // Mock provider and tools for testing
    var provider = Provider{ .vtable = undefined };
    var tools = ToolRegistry.init(allocator);
    defer tools.deinit();
    
    var state = State.init(allocator);
    defer state.deinit();
    
    const ctx = RunContext.init(allocator, &provider, &tools, &state);
    
    try std.testing.expectEqual(allocator, ctx.allocator);
    try std.testing.expectEqual(&provider, ctx.provider);
    try std.testing.expectEqual(&tools, ctx.tools);
}