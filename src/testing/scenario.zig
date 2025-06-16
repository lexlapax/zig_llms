// ABOUTME: Declarative test scenario framework for end-to-end agent testing
// ABOUTME: Provides structured test definitions with setup, execution, and validation phases

const std = @import("std");
const types = @import("../types.zig");
const Provider = @import("../provider.zig").Provider;
const RunContext = @import("../context.zig").RunContext;
const Agent = @import("../agent.zig").Agent;

pub const ScenarioStep = struct {
    name: []const u8,
    input: types.Message,
    expected_output: ?[]const u8 = null,
    expected_role: ?types.Role = null,
    should_fail: bool = false,
    timeout_ms: ?u32 = null,

    pub fn init(name: []const u8, input: types.Message) ScenarioStep {
        return ScenarioStep{
            .name = name,
            .input = input,
        };
    }

    pub fn expectOutput(self: ScenarioStep, output: []const u8) ScenarioStep {
        var updated_step = self;
        updated_step.expected_output = output;
        return updated_step;
    }

    pub fn expectRole(self: ScenarioStep, role: types.Role) ScenarioStep {
        var updated_step = self;
        updated_step.expected_role = role;
        return updated_step;
    }

    pub fn expectFailure(self: ScenarioStep) ScenarioStep {
        var updated_step = self;
        updated_step.should_fail = true;
        return updated_step;
    }

    pub fn withTimeout(self: ScenarioStep, timeout_ms: u32) ScenarioStep {
        var updated_step = self;
        updated_step.timeout_ms = timeout_ms;
        return updated_step;
    }
};

pub const ScenarioSetup = struct {
    provider_config: ?std.json.Value = null,
    tools: []const []const u8 = &.{},
    memory_max_messages: usize = 100,
    memory_max_tokens: u32 = 10000,
    custom_setup: ?*const fn (allocator: std.mem.Allocator, context: *RunContext) anyerror!void = null,

    pub fn withProviderConfig(self: ScenarioSetup, config: std.json.Value) ScenarioSetup {
        var setup = self;
        setup.provider_config = config;
        return setup;
    }

    pub fn withTools(self: ScenarioSetup, tools: []const []const u8) ScenarioSetup {
        var setup = self;
        setup.tools = tools;
        return setup;
    }

    pub fn withMemoryLimits(self: ScenarioSetup, max_messages: usize, max_tokens: u32) ScenarioSetup {
        var setup = self;
        setup.memory_max_messages = max_messages;
        setup.memory_max_tokens = max_tokens;
        return setup;
    }

    pub fn withCustomSetup(self: ScenarioSetup, setup_fn: *const fn (allocator: std.mem.Allocator, context: *RunContext) anyerror!void) ScenarioSetup {
        var setup = self;
        setup.custom_setup = setup_fn;
        return setup;
    }
};

pub const ScenarioResult = struct {
    success: bool,
    step_results: []const StepResult,
    error_message: ?[]const u8 = null,
    execution_time_ms: u64,

    pub const StepResult = struct {
        step_name: []const u8,
        success: bool,
        actual_output: ?[]const u8 = null,
        actual_role: ?types.Role = null,
        error_message: ?[]const u8 = null,
        execution_time_ms: u64,
    };

    pub fn deinit(self: *ScenarioResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }

        for (self.step_results) |*result| {
            if (result.actual_output) |output| {
                allocator.free(output);
            }
            if (result.error_message) |msg| {
                allocator.free(msg);
            }
        }

        allocator.free(self.step_results);
    }
};

pub const TestScenario = struct {
    name: []const u8,
    description: []const u8,
    setup: ScenarioSetup,
    steps: []const ScenarioStep,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, description: []const u8) TestScenario {
        return TestScenario{
            .name = name,
            .description = description,
            .setup = ScenarioSetup{},
            .steps = &.{},
            .allocator = allocator,
        };
    }

    pub fn withSetup(self: TestScenario, setup: ScenarioSetup) TestScenario {
        var updated_scenario = self;
        updated_scenario.setup = setup;
        return updated_scenario;
    }

    pub fn withSteps(self: TestScenario, steps: []const ScenarioStep) TestScenario {
        var updated_scenario = self;
        updated_scenario.steps = steps;
        return updated_scenario;
    }

    pub fn run(self: *const TestScenario, provider: *Provider) !ScenarioResult {
        const start_time = std.time.milliTimestamp();

        // Initialize step results array
        var step_results = try std.ArrayList(ScenarioResult.StepResult).initCapacity(self.allocator, self.steps.len);
        defer step_results.deinit();

        // Setup test environment
        var context = try self.setupContext(provider);
        defer self.cleanupContext(&context);

        // Execute steps sequentially
        var overall_success = true;
        for (self.steps) |scenario_step| {
            const step_start = std.time.milliTimestamp();

            const step_result = self.executeStep(scenario_step, &context) catch |err| blk: {
                const error_msg = try std.fmt.allocPrint(self.allocator, "Step execution failed: {}", .{err});
                break :blk ScenarioResult.StepResult{
                    .step_name = scenario_step.name,
                    .success = false,
                    .error_message = error_msg,
                    .execution_time_ms = @intCast(std.time.milliTimestamp() - step_start),
                };
            };

            if (!step_result.success) {
                overall_success = false;
            }

            try step_results.append(step_result);

            // Stop on first failure unless step expected to fail
            if (!step_result.success and !scenario_step.should_fail) {
                break;
            }
        }

        const execution_time: u64 = @intCast(std.time.milliTimestamp() - start_time);

        return ScenarioResult{
            .success = overall_success,
            .step_results = try step_results.toOwnedSlice(),
            .execution_time_ms = execution_time,
        };
    }

    fn setupContext(self: *const TestScenario, provider: *Provider) !RunContext {
        // Create mock context components
        var tools = @import("../tool_registry.zig").ToolRegistry.init(self.allocator);
        var state = @import("../state.zig").State.init(self.allocator);

        var context = RunContext.init(self.allocator, provider, &tools, &state);

        // Apply custom setup if provided
        if (self.setup.custom_setup) |setup_fn| {
            try setup_fn(self.allocator, &context);
        }

        return context;
    }

    fn cleanupContext(self: *const TestScenario, context: *RunContext) void {
        _ = self;
        context.tools.deinit();
        context.state.deinit();
    }

    fn executeStep(self: *const TestScenario, scenario_step: ScenarioStep, context: *RunContext) !ScenarioResult.StepResult {
        const step_start = std.time.milliTimestamp();

        // Execute the step with timeout if specified
        const response = if (scenario_step.timeout_ms) |timeout| blk: {
            // TODO: Implement timeout mechanism
            _ = timeout;
            break :blk try context.provider.generate(&.{scenario_step.input}, types.GenerateOptions{});
        } else try context.provider.generate(&.{scenario_step.input}, types.GenerateOptions{});

        const execution_time: u64 = @intCast(std.time.milliTimestamp() - step_start);

        // Validate the response
        var success = true;
        var error_msg: ?[]const u8 = null;

        if (scenario_step.expected_output) |expected| {
            if (!std.mem.eql(u8, response.content, expected)) {
                success = false;
                error_msg = try std.fmt.allocPrint(self.allocator, "Output mismatch. Expected: '{s}', Got: '{s}'", .{ expected, response.content });
            }
        }

        // Create step result
        return ScenarioResult.StepResult{
            .step_name = scenario_step.name,
            .success = success and !scenario_step.should_fail,
            .actual_output = try self.allocator.dupe(u8, response.content),
            .error_message = error_msg,
            .execution_time_ms = execution_time,
        };
    }
};

pub const ScenarioRunner = struct {
    allocator: std.mem.Allocator,
    scenarios: std.ArrayList(TestScenario),

    pub fn init(allocator: std.mem.Allocator) ScenarioRunner {
        return ScenarioRunner{
            .allocator = allocator,
            .scenarios = std.ArrayList(TestScenario).init(allocator),
        };
    }

    pub fn deinit(self: *ScenarioRunner) void {
        self.scenarios.deinit();
    }

    pub fn addScenario(self: *ScenarioRunner, test_scenario: TestScenario) !void {
        try self.scenarios.append(test_scenario);
    }

    pub fn runAll(self: *ScenarioRunner, provider: *Provider) ![]const ScenarioResult {
        var results = try std.ArrayList(ScenarioResult).initCapacity(self.allocator, self.scenarios.items.len);
        defer results.deinit();

        for (self.scenarios.items) |*test_scenario| {
            const result = try test_scenario.run(provider);
            try results.append(result);
        }

        return results.toOwnedSlice();
    }

    pub fn printResults(self: *ScenarioRunner, results: []const ScenarioResult) void {
        std.debug.print("\n=== Test Scenario Results ===\n");

        var total_scenarios: usize = 0;
        var passed_scenarios: usize = 0;
        var total_steps: usize = 0;
        var passed_steps: usize = 0;

        for (results, 0..) |result, i| {
            const test_scenario = &self.scenarios.items[i];
            total_scenarios += 1;
            total_steps += result.step_results.len;

            if (result.success) {
                passed_scenarios += 1;
                std.debug.print("✓ {s} - PASSED ({d}ms)\n", .{ test_scenario.name, result.execution_time_ms });
            } else {
                std.debug.print("✗ {s} - FAILED ({d}ms)\n", .{ test_scenario.name, result.execution_time_ms });
            }

            if (result.error_message) |msg| {
                std.debug.print("  Error: {s}\n", .{msg});
            }

            for (result.step_results) |step_result| {
                if (step_result.success) {
                    passed_steps += 1;
                    std.debug.print("  ✓ {s} ({d}ms)\n", .{ step_result.step_name, step_result.execution_time_ms });
                } else {
                    std.debug.print("  ✗ {s} ({d}ms)\n", .{ step_result.step_name, step_result.execution_time_ms });
                    if (step_result.error_message) |msg| {
                        std.debug.print("    Error: {s}\n", .{msg});
                    }
                }
            }
            std.debug.print("\n");
        }

        std.debug.print("Summary: {d}/{d} scenarios passed, {d}/{d} steps passed\n", .{ passed_scenarios, total_scenarios, passed_steps, total_steps });
    }
};

// Helper functions for building scenarios
pub fn scenario(allocator: std.mem.Allocator, name: []const u8, description: []const u8) TestScenario {
    return TestScenario.init(allocator, name, description);
}

pub fn step(name: []const u8, role: types.Role, content: []const u8) ScenarioStep {
    return ScenarioStep.init(name, types.Message{
        .role = role,
        .content = .{ .text = content },
    });
}

pub fn userStep(name: []const u8, content: []const u8) ScenarioStep {
    return step(name, .user, content);
}

pub fn systemStep(name: []const u8, content: []const u8) ScenarioStep {
    return step(name, .system, content);
}

test "scenario creation" {
    const allocator = std.testing.allocator;

    const test_scenario = scenario(allocator, "Basic test", "A simple test scenario")
        .withSteps(&.{
        userStep("User greeting", "Hello, how are you?")
            .expectRole(.assistant),
    });

    try std.testing.expectEqualStrings("Basic test", test_scenario.name);
    try std.testing.expectEqual(@as(usize, 1), test_scenario.steps.len);
}

test "step configuration" {
    const test_step = userStep("Test step", "Hello")
        .expectOutput("Hi there!")
        .expectRole(.assistant)
        .withTimeout(5000);

    try std.testing.expectEqualStrings("Test step", test_step.name);
    try std.testing.expectEqualStrings("Hi there!", test_step.expected_output.?);
    try std.testing.expectEqual(types.Role.assistant, test_step.expected_role.?);
    try std.testing.expectEqual(@as(u32, 5000), test_step.timeout_ms.?);
}
