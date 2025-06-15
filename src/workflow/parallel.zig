// ABOUTME: Parallel workflow agent implementation with thread pool management
// ABOUTME: Executes workflow steps concurrently with configurable parallelism and error handling

const std = @import("std");
const definition = @import("definition.zig");
const WorkflowAgent = definition.WorkflowAgent;
const WorkflowDefinition = definition.WorkflowDefinition;
const WorkflowStep = definition.WorkflowStep;
const WorkflowExecutionContext = definition.WorkflowExecutionContext;
const ParallelStepConfig = definition.ParallelStepConfig;
const agent_mod = @import("../agent.zig");
const Agent = agent_mod.Agent;
const BaseAgent = agent_mod.BaseAgent;
const AgentConfig = agent_mod.AgentConfig;
const RunContext = @import("../context.zig").RunContext;

// Parallel execution result
pub const ParallelExecutionResult = struct {
    success: bool,
    completed_steps: usize,
    failed_steps: []const []const u8,
    step_results: std.StringHashMap(std.json.Value),
    errors: std.StringHashMap([]const u8),
    execution_time_ms: u64,
    max_concurrency_used: u32,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *ParallelExecutionResult) void {
        // Clean up failed steps
        for (self.failed_steps) |step| {
            self.allocator.free(step);
        }
        self.allocator.free(self.failed_steps);
        
        // Clean up step results
        var result_iter = self.step_results.iterator();
        while (result_iter.next()) |entry| {
            _ = entry; // Results managed by context
        }
        self.step_results.deinit();
        
        // Clean up errors
        var error_iter = self.errors.iterator();
        while (error_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.errors.deinit();
    }
    
    pub fn toJson(self: *ParallelExecutionResult) !std.json.Value {
        var obj = std.json.ObjectMap.init(self.allocator);
        errdefer obj.deinit();
        
        try obj.put("success", .{ .bool = self.success });
        try obj.put("completed_steps", .{ .integer = @as(i64, @intCast(self.completed_steps)) });
        try obj.put("execution_time_ms", .{ .integer = @as(i64, @intCast(self.execution_time_ms)) });
        try obj.put("max_concurrency_used", .{ .integer = @as(i64, @intCast(self.max_concurrency_used)) });
        
        // Failed steps
        var failed_array = std.json.Array.init(self.allocator);
        for (self.failed_steps) |step| {
            try failed_array.append(.{ .string = step });
        }
        try obj.put("failed_steps", .{ .array = failed_array });
        
        // Step results
        var results_obj = std.json.ObjectMap.init(self.allocator);
        var result_iter = self.step_results.iterator();
        while (result_iter.next()) |entry| {
            try results_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        try obj.put("step_results", .{ .object = results_obj });
        
        // Errors
        var errors_obj = std.json.ObjectMap.init(self.allocator);
        var error_iter = self.errors.iterator();
        while (error_iter.next()) |entry| {
            try errors_obj.put(entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }
        try obj.put("errors", .{ .object = errors_obj });
        
        return .{ .object = obj };
    }
};

// Thread pool for parallel execution
pub const WorkflowThreadPool = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    work_queue: WorkQueue,
    shutdown: std.atomic.Value(bool),
    
    const WorkItem = struct {
        step: WorkflowStep,
        context: *WorkflowExecutionContext,
        run_context: *RunContext,
        result: *?std.json.Value,
        error_result: *?[]const u8,
        completed: *std.atomic.Value(bool),
        executor: *ParallelWorkflowExecutor,
    };
    
    const WorkQueue = struct {
        items: std.ArrayList(WorkItem),
        mutex: std.Thread.Mutex,
        condition: std.Thread.Condition,
        
        pub fn init(allocator: std.mem.Allocator) WorkQueue {
            return .{
                .items = std.ArrayList(WorkItem).init(allocator),
                .mutex = .{},
                .condition = .{},
            };
        }
        
        pub fn deinit(self: *WorkQueue) void {
            self.items.deinit();
        }
        
        pub fn push(self: *WorkQueue, item: WorkItem) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            try self.items.append(item);
            self.condition.signal();
        }
        
        pub fn pop(self: *WorkQueue) ?WorkItem {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            while (self.items.items.len == 0) {
                self.condition.wait(&self.mutex);
            }
            
            return self.items.orderedRemove(0);
        }
        
        pub fn isEmpty(self: *WorkQueue) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len == 0;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator, thread_count: u32) !WorkflowThreadPool {
        var pool = WorkflowThreadPool{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, thread_count),
            .work_queue = WorkQueue.init(allocator),
            .shutdown = std.atomic.Value(bool).init(false),
        };
        
        // Start worker threads
        for (pool.threads, 0..) |*thread, i| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{ &pool, i });
        }
        
        return pool;
    }
    
    pub fn deinit(self: *WorkflowThreadPool) void {
        // Signal shutdown
        self.shutdown.store(true, .Release);
        
        // Wake up all threads
        for (0..self.threads.len) |_| {
            self.work_queue.condition.signal();
        }
        
        // Wait for threads to finish
        for (self.threads) |thread| {
            thread.join();
        }
        
        self.allocator.free(self.threads);
        self.work_queue.deinit();
    }
    
    pub fn submitWork(self: *WorkflowThreadPool, work: WorkItem) !void {
        try self.work_queue.push(work);
    }
    
    fn workerThread(pool: *WorkflowThreadPool, thread_id: usize) void {
        _ = thread_id;
        
        while (!pool.shutdown.load(.Acquire)) {
            const work_item = pool.work_queue.pop() orelse continue;
            
            if (pool.shutdown.load(.Acquire)) break;
            
            // Execute the work item
            const result = work_item.executor.executeStep(
                work_item.step,
                work_item.context,
                work_item.run_context,
            ) catch |err| {
                work_item.error_result.* = pool.allocator.dupe(u8, @errorName(err)) catch null;
                work_item.completed.store(true, .Release);
                continue;
            };
            
            work_item.result.* = result;
            work_item.completed.store(true, .Release);
        }
    }
};

// Parallel workflow executor
pub const ParallelWorkflowExecutor = struct {
    allocator: std.mem.Allocator,
    config: ExecutorConfig = .{},
    thread_pool: ?WorkflowThreadPool = null,
    
    pub const ExecutorConfig = struct {
        max_concurrency: ?u32 = null,
        fail_fast: bool = true,
        collect_results: bool = true,
        timeout_ms: ?u32 = null,
        thread_pool_size: u32 = 4,
        use_thread_pool: bool = true,
        wait_for_all: bool = true,
    };
    
    pub fn init(allocator: std.mem.Allocator) ParallelWorkflowExecutor {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ParallelWorkflowExecutor) void {
        if (self.thread_pool) |*pool| {
            pool.deinit();
        }
    }
    
    pub fn execute(
        self: *ParallelWorkflowExecutor,
        workflow: *const WorkflowDefinition,
        input: std.json.Value,
        context: *RunContext,
    ) !ParallelExecutionResult {
        const start_time = std.time.milliTimestamp();
        
        // Initialize thread pool if configured
        if (self.config.use_thread_pool and self.thread_pool == null) {
            self.thread_pool = try WorkflowThreadPool.init(self.allocator, self.config.thread_pool_size);
        }
        
        var execution_context = WorkflowExecutionContext.init(self.allocator, workflow);
        defer execution_context.deinit();
        
        var result = ParallelExecutionResult{
            .success = true,
            .completed_steps = 0,
            .failed_steps = &[_][]const u8{},
            .step_results = std.StringHashMap(std.json.Value).init(self.allocator),
            .errors = std.StringHashMap([]const u8).init(self.allocator),
            .execution_time_ms = 0,
            .max_concurrency_used = 0,
            .allocator = self.allocator,
        };
        
        // Initialize execution context
        try execution_context.setVariable("input", input);
        execution_context.execution_state = .running;
        
        // Determine actual concurrency
        const max_concurrency = self.config.max_concurrency orelse @as(u32, @intCast(workflow.steps.len));
        const actual_concurrency = @min(max_concurrency, @as(u32, @intCast(workflow.steps.len)));
        result.max_concurrency_used = actual_concurrency;
        
        if (self.config.use_thread_pool and self.thread_pool != null) {
            try self.executeWithThreadPool(workflow, &execution_context, context, &result);
        } else {
            try self.executeWithoutThreadPool(workflow, &execution_context, context, &result, actual_concurrency);
        }
        
        execution_context.execution_state = if (result.success) .completed else .failed;
        result.execution_time_ms = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        
        return result;
    }
    
    fn executeWithThreadPool(
        self: *ParallelWorkflowExecutor,
        workflow: *const WorkflowDefinition,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
        result: *ParallelExecutionResult,
    ) !void {
        var pool = &self.thread_pool.?;
        
        // Prepare work items
        var step_results = try self.allocator.alloc(?std.json.Value, workflow.steps.len);
        defer self.allocator.free(step_results);
        
        var step_errors = try self.allocator.alloc(?[]const u8, workflow.steps.len);
        defer self.allocator.free(step_errors);
        
        var completed_flags = try self.allocator.alloc(std.atomic.Value(bool), workflow.steps.len);
        defer self.allocator.free(completed_flags);
        
        // Initialize arrays
        for (0..workflow.steps.len) |i| {
            step_results[i] = null;
            step_errors[i] = null;
            completed_flags[i] = std.atomic.Value(bool).init(false);
        }
        
        // Submit all work items
        for (workflow.steps, 0..) |step, i| {
            const work_item = WorkflowThreadPool.WorkItem{
                .step = step,
                .context = execution_context,
                .run_context = run_context,
                .result = &step_results[i],
                .error_result = &step_errors[i],
                .completed = &completed_flags[i],
                .executor = self,
            };
            
            try pool.submitWork(work_item);
        }
        
        // Wait for completion or timeout
        const timeout_ms = self.config.timeout_ms orelse std.math.maxInt(u32);
        const start_wait = std.time.milliTimestamp();
        
        while (true) {
            // Check if all completed
            var all_completed = true;
            var completed_count: usize = 0;
            
            for (completed_flags) |*flag| {
                if (flag.load(.Acquire)) {
                    completed_count += 1;
                } else {
                    all_completed = false;
                }
            }
            
            result.completed_steps = completed_count;
            
            // Check for fail-fast condition
            if (self.config.fail_fast) {
                for (step_errors, 0..) |error_msg, i| {
                    if (error_msg != null) {
                        result.success = false;
                        try result.errors.put(workflow.steps[i].id, error_msg.?);
                        
                        var failed_list = std.ArrayList([]const u8).init(self.allocator);
                        try failed_list.append(try self.allocator.dupe(u8, workflow.steps[i].id));
                        result.failed_steps = try failed_list.toOwnedSlice();
                        return;
                    }
                }
            }
            
            if (all_completed or (!self.config.wait_for_all and completed_count > 0)) {
                break;
            }
            
            // Check timeout
            const elapsed = @as(u32, @intCast(std.time.milliTimestamp() - start_wait));
            if (elapsed > timeout_ms) {
                result.success = false;
                return;
            }
            
            std.time.sleep(1 * std.time.ns_per_ms); // Wait 1ms
        }
        
        // Collect results and errors
        var failed_list = std.ArrayList([]const u8).init(self.allocator);
        defer failed_list.deinit();
        
        for (workflow.steps, 0..) |step, i| {
            if (step_results[i]) |step_result| {
                try execution_context.setStepResult(step.id, step_result);
                if (self.config.collect_results) {
                    try result.step_results.put(step.id, step_result);
                }
            }
            
            if (step_errors[i]) |error_msg| {
                result.success = false;
                try result.errors.put(step.id, error_msg);
                try failed_list.append(try self.allocator.dupe(u8, step.id));
            }
        }
        
        result.failed_steps = try failed_list.toOwnedSlice();
    }
    
    fn executeWithoutThreadPool(
        self: *ParallelWorkflowExecutor,
        workflow: *const WorkflowDefinition,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
        result: *ParallelExecutionResult,
        concurrency: u32,
    ) !void {
        // Simple parallel execution without thread pool
        // This is a simplified version that executes in batches
        
        var step_index: usize = 0;
        var failed_list = std.ArrayList([]const u8).init(self.allocator);
        defer failed_list.deinit();
        
        while (step_index < workflow.steps.len) {
            const batch_end = @min(step_index + concurrency, workflow.steps.len);
            
            // Execute batch
            for (step_index..batch_end) |i| {
                const step = workflow.steps[i];
                
                const step_result = self.executeStep(step, execution_context, run_context) catch |err| {
                    result.success = false;
                    const error_msg = try self.allocator.dupe(u8, @errorName(err));
                    try result.errors.put(step.id, error_msg);
                    try failed_list.append(try self.allocator.dupe(u8, step.id));
                    
                    if (self.config.fail_fast) {
                        result.failed_steps = try failed_list.toOwnedSlice();
                        return;
                    }
                    continue;
                };
                
                try execution_context.setStepResult(step.id, step_result);
                if (self.config.collect_results) {
                    try result.step_results.put(step.id, step_result);
                }
                
                result.completed_steps += 1;
            }
            
            step_index = batch_end;
        }
        
        result.failed_steps = try failed_list.toOwnedSlice();
    }
    
    pub fn executeStep(
        self: *ParallelWorkflowExecutor,
        step: WorkflowStep,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        return switch (step.step_type) {
            .agent => try self.executeAgentStep(step.config.agent, execution_context, run_context),
            .tool => try self.executeToolStep(step.config.tool, execution_context, run_context),
            .parallel => try self.executeParallelStep(step.config.parallel, execution_context, run_context),
            .delay => try self.executeDelayStep(step.config.delay, execution_context),
            .transform => try self.executeTransformStep(step.config.transform, execution_context),
            else => error.StepTypeNotSupported,
        };
    }
    
    fn executeAgentStep(
        self: *ParallelWorkflowExecutor,
        config: definition.AgentStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        _ = self;
        _ = config;
        _ = execution_context;
        _ = run_context;
        return error.NotImplemented;
    }
    
    fn executeToolStep(
        self: *ParallelWorkflowExecutor,
        config: definition.ToolStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        _ = self;
        _ = config;
        _ = execution_context;
        _ = run_context;
        return error.NotImplemented;
    }
    
    fn executeParallelStep(
        self: *ParallelWorkflowExecutor,
        config: ParallelStepConfig,
        execution_context: *WorkflowExecutionContext,
        run_context: *RunContext,
    ) !std.json.Value {
        // Create a sub-workflow for the parallel steps
        var sub_workflow = WorkflowDefinition.init(self.allocator, "parallel_sub", "Parallel Substeps");
        defer sub_workflow.deinit();
        
        sub_workflow.steps = config.steps;
        
        // Create a sub-executor
        var sub_executor = ParallelWorkflowExecutor.init(self.allocator);
        defer sub_executor.deinit();
        
        sub_executor.config.max_concurrency = config.max_concurrency;
        sub_executor.config.fail_fast = config.fail_fast;
        sub_executor.config.collect_results = config.collect_results;
        sub_executor.config.use_thread_pool = false; // Avoid nested thread pools
        
        // Execute sub-workflow
        const current_input = execution_context.getVariable("input") orelse .{ .null = {} };
        var sub_result = try sub_executor.execute(&sub_workflow, current_input, run_context);
        defer sub_result.deinit();
        
        if (!sub_result.success) {
            return error.SubWorkflowFailed;
        }
        
        return try sub_result.toJson();
    }
    
    fn executeDelayStep(
        self: *ParallelWorkflowExecutor,
        config: definition.DelayStepConfig,
        execution_context: *WorkflowExecutionContext,
    ) !std.json.Value {
        _ = execution_context;
        
        var delay_ms = config.duration_ms;
        
        // Add jitter if specified
        if (config.jitter_percent > 0.0) {
            var rng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
            const jitter = @as(f32, @floatFromInt(delay_ms)) * config.jitter_percent / 100.0;
            const jitter_ms = @as(u32, @intFromFloat(rng.random().float(f32) * jitter));
            delay_ms += jitter_ms;
        }
        
        std.time.sleep(delay_ms * std.time.ns_per_ms);
        
        var result = std.json.ObjectMap.init(self.allocator);
        try result.put("delayed_ms", .{ .integer = @as(i64, @intCast(delay_ms)) });
        try result.put("step_type", .{ .string = "delay" });
        
        return .{ .object = result };
    }
    
    fn executeTransformStep(
        self: *ParallelWorkflowExecutor,
        config: definition.TransformStepConfig,
        execution_context: *WorkflowExecutionContext,
    ) !std.json.Value {
        _ = self;
        _ = config;
        _ = execution_context;
        return error.NotImplemented;
    }
};

// Tests
test "parallel executor with delay steps" {
    const allocator = std.testing.allocator;
    
    // Create a workflow with multiple delay steps
    var workflow = WorkflowDefinition.init(allocator, "parallel_test", "Parallel Test");
    defer workflow.deinit();
    
    const steps = [_]WorkflowStep{
        .{
            .id = "step1",
            .name = "Delay 1",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 10 } },
        },
        .{
            .id = "step2",
            .name = "Delay 2",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 15 } },
        },
        .{
            .id = "step3",
            .name = "Delay 3",
            .step_type = .delay,
            .config = .{ .delay = .{ .duration_ms = 5 } },
        },
    };
    
    workflow.steps = &steps;
    
    var executor = ParallelWorkflowExecutor.init(allocator);
    defer executor.deinit();
    
    executor.config.use_thread_pool = false; // Use simple parallel execution for test
    
    var run_context = RunContext{
        .allocator = allocator,
        .config = std.StringHashMap(std.json.Value).init(allocator),
        .logger = null,
        .tracer = null,
    };
    defer run_context.config.deinit();
    
    const start_time = std.time.milliTimestamp();
    var result = try executor.execute(&workflow, .{ .null = {} }, &run_context);
    defer result.deinit();
    const elapsed = std.time.milliTimestamp() - start_time;
    
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 3), result.completed_steps);
    try std.testing.expectEqual(@as(u32, 3), result.max_concurrency_used);
    
    // Should complete faster than sequential execution (which would take 30ms)
    try std.testing.expect(elapsed < 25); // Should complete in ~15ms (longest step)
}