// ABOUTME: Test API bridge for exposing testing framework functionality to scripts
// ABOUTME: Enables creation and execution of tests from scripts with full test utilities

const std = @import("std");
const ScriptValue = @import("../value_bridge.zig").ScriptValue;
const ScriptModule = @import("../interface.zig").ScriptModule;
const ScriptContext = @import("../context.zig").ScriptContext;
const ScriptingEngine = @import("../interface.zig").ScriptingEngine;
const APIBridge = @import("../module_system.zig").APIBridge;
const createModuleFunction = @import("../module_system.zig").createModuleFunction;
const createModuleConstant = @import("../module_system.zig").createModuleConstant;
const TypeMarshaler = @import("../type_marshaler.zig").TypeMarshaler;

// Import zig_llms testing API
const testing_framework = @import("../../testing.zig");
const test_scenario = @import("../../testing/scenario.zig");
const test_matcher = @import("../../testing/matcher.zig");

/// Script test case wrapper
const ScriptTestCase = struct {
    name: []const u8,
    description: []const u8,
    test_fn: *ScriptValue.function,
    context: *ScriptContext,
    timeout_ms: u32 = 30000,
    tags: []const []const u8 = &[_][]const u8{},
    setup_fn: ?*ScriptValue.function = null,
    teardown_fn: ?*ScriptValue.function = null,

    pub fn deinit(self: *ScriptTestCase) void {
        const allocator = self.context.allocator;
        allocator.free(self.name);
        allocator.free(self.description);
        for (self.tags) |tag| {
            allocator.free(tag);
        }
        allocator.free(self.tags);
        allocator.destroy(self);
    }
};

/// Script test suite
const ScriptTestSuite = struct {
    name: []const u8,
    tests: std.ArrayList(*ScriptTestCase),
    context: *ScriptContext,
    before_all: ?*ScriptValue.function = null,
    after_all: ?*ScriptValue.function = null,
    before_each: ?*ScriptValue.function = null,
    after_each: ?*ScriptValue.function = null,

    pub fn deinit(self: *ScriptTestSuite) void {
        const allocator = self.context.allocator;
        allocator.free(self.name);
        for (self.tests.items) |test_case| {
            test_case.deinit();
        }
        self.tests.deinit();
        allocator.destroy(self);
    }
};

/// Global test registry
var test_suites: ?std.StringHashMap(*ScriptTestSuite) = null;
var suites_mutex = std.Thread.Mutex{};

/// Test result tracking
const TestResult = struct {
    passed: bool,
    error_message: ?[]const u8 = null,
    duration_ms: u32,
    assertions: u32 = 0,
};

/// Test Bridge implementation
pub const TestBridge = struct {
    pub const bridge = APIBridge{
        .name = "test",
        .getModule = getModule,
        .init = init,
        .deinit = deinit,
    };

    fn getModule(allocator: std.mem.Allocator) anyerror!*ScriptModule {
        const module = try allocator.create(ScriptModule);

        module.* = ScriptModule{
            .name = "test",
            .functions = &test_functions,
            .constants = &test_constants,
            .description = "Testing framework API for script-based tests",
            .version = "1.0.0",
        };

        return module;
    }

    fn init(engine: *ScriptingEngine, context: *ScriptContext) anyerror!void {
        _ = engine;

        suites_mutex.lock();
        defer suites_mutex.unlock();

        if (test_suites == null) {
            test_suites = std.StringHashMap(*ScriptTestSuite).init(context.allocator);
        }
    }

    fn deinit() void {
        suites_mutex.lock();
        defer suites_mutex.unlock();

        if (test_suites) |*suites| {
            var iter = suites.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            suites.deinit();
            test_suites = null;
        }
    }
};

// Test module functions
const test_functions = [_]ScriptModule.FunctionDef{
    createModuleFunction(
        "suite",
        "Create a new test suite",
        1,
        createTestSuite,
    ),
    createModuleFunction(
        "test",
        "Define a test case",
        3,
        defineTest,
    ),
    createModuleFunction(
        "beforeAll",
        "Set before-all hook for suite",
        2,
        setBeforeAll,
    ),
    createModuleFunction(
        "afterAll",
        "Set after-all hook for suite",
        2,
        setAfterAll,
    ),
    createModuleFunction(
        "beforeEach",
        "Set before-each hook for suite",
        2,
        setBeforeEach,
    ),
    createModuleFunction(
        "afterEach",
        "Set after-each hook for suite",
        2,
        setAfterEach,
    ),
    createModuleFunction(
        "run",
        "Run a test suite",
        1,
        runTestSuite,
    ),
    createModuleFunction(
        "runAll",
        "Run all test suites",
        0,
        runAllTestSuites,
    ),
    createModuleFunction(
        "runWithFilter",
        "Run tests matching filter",
        1,
        runTestsWithFilter,
    ),
    createModuleFunction(
        "assert",
        "Basic assertion",
        2,
        assertEqual,
    ),
    createModuleFunction(
        "assertEq",
        "Assert values are equal",
        2,
        assertEqual,
    ),
    createModuleFunction(
        "assertNe",
        "Assert values are not equal",
        2,
        assertNotEqual,
    ),
    createModuleFunction(
        "assertTrue",
        "Assert value is true",
        1,
        assertTrue,
    ),
    createModuleFunction(
        "assertFalse",
        "Assert value is false",
        1,
        assertFalse,
    ),
    createModuleFunction(
        "assertNil",
        "Assert value is nil",
        1,
        assertNil,
    ),
    createModuleFunction(
        "assertNotNil",
        "Assert value is not nil",
        1,
        assertNotNil,
    ),
    createModuleFunction(
        "assertContains",
        "Assert string/array contains value",
        2,
        assertContains,
    ),
    createModuleFunction(
        "assertThrows",
        "Assert function throws error",
        1,
        assertThrows,
    ),
    createModuleFunction(
        "assertNoThrow",
        "Assert function doesn't throw",
        1,
        assertNoThrow,
    ),
    createModuleFunction(
        "fail",
        "Fail the current test",
        1,
        failTest,
    ),
    createModuleFunction(
        "skip",
        "Skip the current test",
        1,
        skipTest,
    ),
    createModuleFunction(
        "createMock",
        "Create a mock function",
        1,
        createMock,
    ),
    createModuleFunction(
        "createStub",
        "Create a stub function",
        2,
        createStub,
    ),
    createModuleFunction(
        "createSpy",
        "Create a spy function",
        1,
        createSpy,
    ),
    createModuleFunction(
        "getResults",
        "Get test results summary",
        0,
        getTestResults,
    ),
    createModuleFunction(
        "generateReport",
        "Generate test report",
        1,
        generateTestReport,
    ),
};

// Test module constants
const test_constants = [_]ScriptModule.ConstantDef{
    createModuleConstant(
        "RESULT_PASSED",
        ScriptValue{ .string = "passed" },
        "Test passed successfully",
    ),
    createModuleConstant(
        "RESULT_FAILED",
        ScriptValue{ .string = "failed" },
        "Test failed",
    ),
    createModuleConstant(
        "RESULT_SKIPPED",
        ScriptValue{ .string = "skipped" },
        "Test was skipped",
    ),
    createModuleConstant(
        "RESULT_TIMEOUT",
        ScriptValue{ .string = "timeout" },
        "Test timed out",
    ),
    createModuleConstant(
        "REPORT_FORMAT_TEXT",
        ScriptValue{ .string = "text" },
        "Plain text report format",
    ),
    createModuleConstant(
        "REPORT_FORMAT_JSON",
        ScriptValue{ .string = "json" },
        "JSON report format",
    ),
    createModuleConstant(
        "REPORT_FORMAT_XML",
        ScriptValue{ .string = "xml" },
        "XML/JUnit report format",
    ),
};

// Implementation functions

fn createTestSuite(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;
    const context = @fieldParentPtr(ScriptContext, "allocator", suite_name);
    const allocator = context.allocator;

    // Create test suite
    const suite = try allocator.create(ScriptTestSuite);
    suite.* = ScriptTestSuite{
        .name = try allocator.dupe(u8, suite_name),
        .tests = std.ArrayList(*ScriptTestCase).init(allocator),
        .context = context,
    };

    // Register suite
    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        try suites.put(suite.name, suite);
    }

    return ScriptValue{ .string = suite.name };
}

fn defineTest(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 3 or args[0] != .string or args[1] != .string or args[2] != .function) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;
    const test_name = args[1].string;
    const test_fn = args[2].function;

    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        if (suites.get(suite_name)) |suite| {
            const allocator = suite.context.allocator;

            // Create test case
            const test_case = try allocator.create(ScriptTestCase);
            test_case.* = ScriptTestCase{
                .name = try allocator.dupe(u8, test_name),
                .description = try allocator.dupe(u8, test_name),
                .test_fn = test_fn,
                .context = suite.context,
            };

            try suite.tests.append(test_case);
            return ScriptValue{ .boolean = true };
        }
    }

    return error.SuiteNotFound;
}

fn setBeforeAll(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .function) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;
    const hook_fn = args[1].function;

    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        if (suites.get(suite_name)) |suite| {
            suite.before_all = hook_fn;
            return ScriptValue{ .boolean = true };
        }
    }

    return error.SuiteNotFound;
}

fn setAfterAll(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .function) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;
    const hook_fn = args[1].function;

    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        if (suites.get(suite_name)) |suite| {
            suite.after_all = hook_fn;
            return ScriptValue{ .boolean = true };
        }
    }

    return error.SuiteNotFound;
}

fn setBeforeEach(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .function) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;
    const hook_fn = args[1].function;

    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        if (suites.get(suite_name)) |suite| {
            suite.before_each = hook_fn;
            return ScriptValue{ .boolean = true };
        }
    }

    return error.SuiteNotFound;
}

fn setAfterEach(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string or args[1] != .function) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;
    const hook_fn = args[1].function;

    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        if (suites.get(suite_name)) |suite| {
            suite.after_each = hook_fn;
            return ScriptValue{ .boolean = true };
        }
    }

    return error.SuiteNotFound;
}

fn runTestSuite(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const suite_name = args[0].string;

    suites_mutex.lock();
    const suite = if (test_suites) |*suites|
        suites.get(suite_name)
    else
        null;
    suites_mutex.unlock();

    if (suite == null) {
        return error.SuiteNotFound;
    }

    const allocator = suite.?.context.allocator;
    var results = ScriptValue.Object.init(allocator);

    var passed: u32 = 0;
    var failed: u32 = 0;
    var skipped: u32 = 0;

    // Run before-all hook
    if (suite.?.before_all) |hook| {
        _ = try hook.call(&[_]ScriptValue{});
    }

    // Run each test
    for (suite.?.tests.items) |test_case| {
        // Run before-each hook
        if (suite.?.before_each) |hook| {
            _ = try hook.call(&[_]ScriptValue{});
        }

        // Run test
        const start_time = std.time.milliTimestamp();
        const test_result = test_case.test_fn.call(&[_]ScriptValue{}) catch |err| {
            failed += 1;

            // Run after-each hook even on failure
            if (suite.?.after_each) |hook| {
                _ = hook.call(&[_]ScriptValue{}) catch {};
            }

            return ScriptValue{ .string = @errorName(err) };
        };

        const duration = @as(u32, @intCast(std.time.milliTimestamp() - start_time));
        _ = test_result;
        _ = duration;

        passed += 1;

        // Run after-each hook
        if (suite.?.after_each) |hook| {
            _ = try hook.call(&[_]ScriptValue{});
        }
    }

    // Run after-all hook
    if (suite.?.after_all) |hook| {
        _ = try hook.call(&[_]ScriptValue{});
    }

    // Return results
    try results.put("suite", ScriptValue{ .string = try allocator.dupe(u8, suite_name) });
    try results.put("total", ScriptValue{ .integer = @intCast(suite.?.tests.items.len) });
    try results.put("passed", ScriptValue{ .integer = @intCast(passed) });
    try results.put("failed", ScriptValue{ .integer = @intCast(failed) });
    try results.put("skipped", ScriptValue{ .integer = @intCast(skipped) });

    return ScriptValue{ .object = results };
}

fn runAllTestSuites(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    suites_mutex.lock();
    defer suites_mutex.unlock();

    if (test_suites) |*suites| {
        const allocator = suites.allocator;
        var all_results = try ScriptValue.Array.init(allocator, suites.count());

        var iter = suites.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            const suite_args = [_]ScriptValue{ScriptValue{ .string = entry.key_ptr.* }};
            all_results.items[i] = try runTestSuite(&suite_args);
        }

        return ScriptValue{ .array = all_results };
    }

    return ScriptValue{ .array = ScriptValue.Array{ .items = &[_]ScriptValue{}, .allocator = undefined } };
}

fn runTestsWithFilter(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }

    // TODO: Implement filtered test execution
    return ScriptValue{ .boolean = true };
}

fn assertEqual(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2) {
        return error.InvalidArguments;
    }

    const equal = try compareScriptValues(args[0], args[1]);
    if (!equal) {
        return error.AssertionFailed;
    }

    return ScriptValue{ .boolean = true };
}

fn assertNotEqual(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2) {
        return error.InvalidArguments;
    }

    const equal = try compareScriptValues(args[0], args[1]);
    if (equal) {
        return error.AssertionFailed;
    }

    return ScriptValue{ .boolean = true };
}

fn assertTrue(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1) {
        return error.InvalidArguments;
    }

    switch (args[0]) {
        .boolean => |b| {
            if (!b) return error.AssertionFailed;
        },
        else => return error.InvalidArguments,
    }

    return ScriptValue{ .boolean = true };
}

fn assertFalse(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1) {
        return error.InvalidArguments;
    }

    switch (args[0]) {
        .boolean => |b| {
            if (b) return error.AssertionFailed;
        },
        else => return error.InvalidArguments,
    }

    return ScriptValue{ .boolean = true };
}

fn assertNil(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1) {
        return error.InvalidArguments;
    }

    if (args[0] != .nil) {
        return error.AssertionFailed;
    }

    return ScriptValue{ .boolean = true };
}

fn assertNotNil(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1) {
        return error.InvalidArguments;
    }

    if (args[0] == .nil) {
        return error.AssertionFailed;
    }

    return ScriptValue{ .boolean = true };
}

fn assertContains(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2) {
        return error.InvalidArguments;
    }

    switch (args[0]) {
        .string => |str| {
            if (args[1] == .string) {
                if (!std.mem.containsAtLeast(u8, str, 1, args[1].string)) {
                    return error.AssertionFailed;
                }
            } else {
                return error.InvalidArguments;
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (try compareScriptValues(item, args[1])) {
                    return ScriptValue{ .boolean = true };
                }
            }
            return error.AssertionFailed;
        },
        else => return error.InvalidArguments,
    }

    return ScriptValue{ .boolean = true };
}

fn assertThrows(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .function) {
        return error.InvalidArguments;
    }

    const result = args[0].function.call(&[_]ScriptValue{}) catch {
        return ScriptValue{ .boolean = true };
    };

    _ = result;
    return error.AssertionFailed;
}

fn assertNoThrow(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .function) {
        return error.InvalidArguments;
    }

    _ = try args[0].function.call(&[_]ScriptValue{});
    return ScriptValue{ .boolean = true };
}

fn failTest(args: []const ScriptValue) anyerror!ScriptValue {
    const message = if (args.len > 0 and args[0] == .string)
        args[0].string
    else
        "Test failed";

    _ = message;
    return error.TestFailed;
}

fn skipTest(args: []const ScriptValue) anyerror!ScriptValue {
    const reason = if (args.len > 0 and args[0] == .string)
        args[0].string
    else
        "Test skipped";

    _ = reason;
    return error.TestSkipped;
}

fn createMock(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .object) {
        return error.InvalidArguments;
    }

    // TODO: Implement mock creation
    return ScriptValue{ .function = undefined };
}

fn createStub(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 2 or args[0] != .string) {
        return error.InvalidArguments;
    }

    // TODO: Implement stub creation
    return ScriptValue{ .function = undefined };
}

fn createSpy(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .function) {
        return error.InvalidArguments;
    }

    // TODO: Implement spy creation
    return ScriptValue{ .function = undefined };
}

fn getTestResults(args: []const ScriptValue) anyerror!ScriptValue {
    _ = args;

    const allocator = std.heap.page_allocator; // Temporary allocator
    var summary = ScriptValue.Object.init(allocator);

    try summary.put("total_suites", ScriptValue{ .integer = 0 });
    try summary.put("total_tests", ScriptValue{ .integer = 0 });
    try summary.put("passed", ScriptValue{ .integer = 0 });
    try summary.put("failed", ScriptValue{ .integer = 0 });
    try summary.put("skipped", ScriptValue{ .integer = 0 });
    try summary.put("duration_ms", ScriptValue{ .integer = 0 });

    return ScriptValue{ .object = summary };
}

fn generateTestReport(args: []const ScriptValue) anyerror!ScriptValue {
    if (args.len != 1 or args[0] != .string) {
        return error.InvalidArguments;
    }

    const format = args[0].string;
    const allocator = std.heap.page_allocator; // Temporary allocator

    if (std.mem.eql(u8, format, "json")) {
        var report = ScriptValue.Object.init(allocator);
        try report.put("format", ScriptValue{ .string = try allocator.dupe(u8, "json") });
        try report.put("generated_at", ScriptValue{ .integer = std.time.timestamp() });
        return ScriptValue{ .object = report };
    }

    return ScriptValue{ .string = try allocator.dupe(u8, "Test report placeholder") };
}

// Helper functions

fn compareScriptValues(a: ScriptValue, b: ScriptValue) !bool {
    if (@as(std.meta.Tag(ScriptValue), a) != @as(std.meta.Tag(ScriptValue), b)) {
        return false;
    }

    switch (a) {
        .nil => return true,
        .boolean => |val| return val == b.boolean,
        .integer => |val| return val == b.integer,
        .number => |val| return val == b.number,
        .string => |val| return std.mem.eql(u8, val, b.string),
        .array => |arr| {
            if (arr.items.len != b.array.items.len) return false;
            for (arr.items, b.array.items) |item_a, item_b| {
                if (!try compareScriptValues(item_a, item_b)) return false;
            }
            return true;
        },
        .object => |obj| {
            if (obj.map.count() != b.object.map.count()) return false;
            var iter = obj.map.iterator();
            while (iter.next()) |entry| {
                if (b.object.get(entry.key_ptr.*)) |b_val| {
                    if (!try compareScriptValues(entry.value_ptr.*, b_val)) return false;
                } else {
                    return false;
                }
            }
            return true;
        },
        .function => return a.function == b.function,
        .userdata => return a.userdata.ptr == b.userdata.ptr,
    }
}

// Tests
test "TestBridge module creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const module = try TestBridge.getModule(allocator);
    defer allocator.destroy(module);

    try testing.expectEqualStrings("test", module.name);
    try testing.expect(module.functions.len > 0);
    try testing.expect(module.constants.len > 0);
}
