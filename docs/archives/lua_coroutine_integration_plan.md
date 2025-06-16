# Lua Coroutine Integration Plan for Async Operations

## Executive Summary

This document outlines the integration plan for Lua 5.4 coroutines in the zig_llms Lua scripting engine, enabling async/await-style programming patterns while maintaining compatibility with existing systems.

## 1. Lua 5.4 Coroutine System Overview

### Core API Functions

| Function | Purpose | Returns | Notes |
|----------|---------|---------|-------|
| `lua_newthread(L)` | Creates new coroutine | `*lua_State` | Shares global environment |
| `lua_resume(L, from, nargs)` | Starts/resumes execution | Status code | `LUA_YIELD`, `LUA_OK`, or error |
| `lua_yield(L, nresults)` | Suspends execution | Never returns | Uses `longjmp` internally |
| `lua_yieldk(L, nresults, ctx, k)` | Yieldable API version | Never returns | Continuation-safe |

### Coroutine Lifecycle

```
[New] --resume--> [Running] --yield--> [Suspended]
  |                   |                     |
  |                   v                     |
  +--resume--> [Running] <---resume--------+
                   |
                   v
               [Dead]
```

## 2. Async/Await Integration Architecture

### Core Components

```zig
const LuaCoroutineManager = struct {
    allocator: std.mem.Allocator,
    main_thread: *lua_State,
    coroutine_pool: CoroutinePool,
    async_scheduler: AsyncScheduler,
    promise_registry: PromiseRegistry,
    
    pub fn createAsync(self: *LuaCoroutineManager, script: []const u8, context: *ScriptContext) !*LuaPromise;
    pub fn await(self: *LuaCoroutineManager, promise: *LuaPromise) !ScriptValue;
    pub fn pump(self: *LuaCoroutineManager) !void;
};

const LuaPromise = struct {
    thread: *lua_State,
    status: PromiseStatus,
    result: ?ScriptValue,
    error: ?ScriptError,
    context: *ScriptContext,
    
    pub fn await(self: *LuaPromise) !ScriptValue;
    pub fn then(self: *LuaPromise, callback: ScriptFunction) !*LuaPromise;
    pub fn catch(self: *LuaPromise, error_handler: ScriptFunction) !*LuaPromise;
};

const PromiseStatus = enum {
    pending,
    resolved,
    rejected,
    cancelled,
};
```

### Promise-based Async Pattern

```zig
// Lua script example:
// local promise = async(function()
//     local result = yield_for_http("https://api.example.com")
//     return process_result(result)
// end)
// 
// local value = await(promise)

pub fn luaAsync(L: ?*c.lua_State) callconv(.C) i32 {
    const engine = getLuaEngine(L);
    
    // Get function from stack
    if (!c.lua_isfunction(L, 1)) {
        return luaError(L, "async() requires a function argument");
    }
    
    // Create new coroutine
    const thread = c.lua_newthread(L);
    c.lua_pushvalue(L, 1); // Copy function to new thread
    c.lua_xmove(L, thread, 1); // Move function to coroutine
    
    // Create promise
    const promise = engine.coroutine_manager.createPromise(thread) catch {
        return luaError(L, "Failed to create promise");
    };
    
    // Push promise as userdata
    pushLuaPromise(L, promise);
    return 1;
}

pub fn luaAwait(L: ?*c.lua_State) callconv(.C) i32 {
    const promise = getLuaPromise(L, 1) orelse {
        return luaError(L, "await() requires a promise argument");
    };
    
    // Yield current coroutine until promise resolves
    const continuation_context = AwaitContext{
        .promise = promise,
        .waiting_thread = L,
    };
    
    return c.lua_yieldk(L, 0, @ptrCast(&continuation_context), awaitContinuation);
}

fn awaitContinuation(L: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.C) c_int {
    const await_ctx = @ptrCast(*AwaitContext, ctx);
    
    switch (await_ctx.promise.status) {
        .resolved => {
            // Push resolved value
            pushScriptValue(L, await_ctx.promise.result.?);
            return 1;
        },
        .rejected => {
            // Push error
            const error_msg = await_ctx.promise.error.?.message;
            c.lua_pushstring(L, error_msg.ptr);
            return c.lua_error(L);
        },
        .pending => {
            // Still waiting, yield again
            return c.lua_yieldk(L, 0, ctx, awaitContinuation);
        },
        .cancelled => {
            return luaError(L, "Promise was cancelled");
        },
    }
}
```

## 3. Async I/O Integration

### HTTP Request Example

```zig
pub fn luaHttpGet(L: ?*c.lua_State) callconv(.C) i32 {
    const url = c.lua_tostring(L, 1);
    if (url == null) {
        return luaError(L, "http_get() requires URL string");
    }
    
    const http_context = HttpRequestContext{
        .url = std.mem.span(url),
        .method = .GET,
        .thread = L,
    };
    
    // Start async HTTP request
    startHttpRequest(&http_context) catch {
        return luaError(L, "Failed to start HTTP request");
    };
    
    // Yield with continuation
    return c.lua_yieldk(L, 0, @ptrCast(&http_context), httpContinuation);
}

fn httpContinuation(L: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.C) c_int {
    const http_ctx = @ptrCast(*HttpRequestContext, ctx);
    
    if (http_ctx.response == null) {
        // Still waiting
        return c.lua_yieldk(L, 0, ctx, httpContinuation);
    }
    
    const response = http_ctx.response.?;
    
    // Create response table
    c.lua_createtable(L, 0, 3);
    
    // response.status
    c.lua_pushstring(L, "status");
    c.lua_pushinteger(L, response.status_code);
    c.lua_settable(L, -3);
    
    // response.body
    c.lua_pushstring(L, "body");
    c.lua_pushlstring(L, response.body.ptr, response.body.len);
    c.lua_settable(L, -3);
    
    // response.headers
    c.lua_pushstring(L, "headers");
    pushHttpHeaders(L, response.headers);
    c.lua_settable(L, -3);
    
    return 1;
}
```

### Event-driven Async Model

```zig
const AsyncEvent = struct {
    id: u64,
    event_type: AsyncEventType,
    coroutine: *lua_State,
    data: union {
        timer: TimerData,
        http: HttpData,
        file_io: FileIOData,
        custom: []const u8,
    },
};

const AsyncScheduler = struct {
    pending_events: std.ArrayList(AsyncEvent),
    timer_heap: std.PriorityQueue(TimerEvent, void, compareTimers),
    event_loop: *EventEmitter,
    
    pub fn schedule(self: *AsyncScheduler, event: AsyncEvent) !void {
        switch (event.event_type) {
            .timer => try self.timer_heap.add(event.data.timer),
            .immediate => try self.pending_events.append(event),
            .io => try self.registerIOEvent(event),
        }
    }
    
    pub fn pump(self: *AsyncScheduler, max_time_ms: u32) !void {
        const start_time = std.time.milliTimestamp();
        
        while (std.time.milliTimestamp() - start_time < max_time_ms) {
            // Process expired timers
            try self.processTimers();
            
            // Process immediate events
            try self.processImmediate();
            
            // Process I/O events
            try self.processIO();
            
            if (self.isEmpty()) break;
        }
    }
};
```

## 4. Error Handling Strategy

### Error Propagation in Coroutines

```zig
const CoroutineError = error{
    YieldFromMainThread,
    CoroutineAlreadyDead,
    InvalidCoroutineState,
    ExecutionTimeoutExceeded,
    MemoryLimitExceeded,
    StackOverflow,
    RuntimeError,
};

fn resumeCoroutineSafe(ctx: *ScriptContext, thread: *lua_State, args: []const ScriptValue) !CoroutineResult {
    const guard = LuaStackGuard.init(thread);
    defer guard.deinit();
    
    // Check coroutine status
    const status = c.lua_status(thread);
    if (status != c.LUA_OK and status != c.LUA_YIELD) {
        return CoroutineError.InvalidCoroutineState;
    }
    
    // Push arguments
    for (args) |arg| {
        try pushScriptValue(thread, arg);
    }
    
    // Set instruction limit hook
    if (ctx.sandbox_level != .none) {
        c.lua_sethook(thread, instructionLimitHook, c.LUA_MASKCOUNT, 1000);
    }
    
    // Resume with timeout
    const start_time = std.time.milliTimestamp();
    const result = c.lua_resume(thread, ctx.engine_context, @intCast(args.len));
    const elapsed = std.time.milliTimestamp() - start_time;
    
    // Check for timeout
    if (elapsed > ctx.max_execution_time_ms) {
        return CoroutineError.ExecutionTimeoutExceeded;
    }
    
    return switch (result) {
        c.LUA_OK => CoroutineResult{
            .completed = try pullScriptValue(thread, -1, ctx.allocator),
        },
        c.LUA_YIELD => CoroutineResult{
            .yielded = try pullYieldValues(thread, ctx.allocator),
        },
        c.LUA_ERRRUN => CoroutineResult{
            .error = ScriptError.fromLuaError(c.lua_tostring(thread, -1)),
        },
        c.LUA_ERRMEM => CoroutineError.MemoryLimitExceeded,
        else => CoroutineError.RuntimeError,
    };
}
```

### Try-Catch Integration

```zig
// Lua API for error handling:
// try_async(function()
//     local result = yield_for_http("https://api.example.com")
//     return result
// end):catch(function(error)
//     print("Error:", error.message)
//     return nil
// end)

pub fn luaTryAsync(L: ?*c.lua_State) callconv(.C) i32 {
    const promise = luaAsync(L); // Create async promise
    if (promise == 0) return 0;
    
    // Add error handling methods
    c.lua_getfield(L, -1, "catch");
    if (c.lua_isnil(L, -1)) {
        c.lua_pop(L, 1);
        // Add catch method
        c.lua_pushcfunction(L, luaPromiseCatch);
        c.lua_setfield(L, -2, "catch");
    }
    
    return 1;
}

pub fn luaPromiseCatch(L: ?*c.lua_State) callconv(.C) i32 {
    const promise = getLuaPromise(L, 1);
    const error_handler = getLuaFunction(L, 2);
    
    promise.error_handler = error_handler;
    
    // Return promise for chaining
    c.lua_pushvalue(L, 1);
    return 1;
}
```

## 5. Performance Optimization

### Coroutine Pooling

```zig
const CoroutinePool = struct {
    available: std.ArrayList(*lua_State),
    active: std.HashMap(*lua_State, CoroutineInfo),
    allocator: std.mem.Allocator,
    main_thread: *lua_State,
    pool_size: usize,
    
    pub fn acquire(self: *CoroutinePool) !*lua_State {
        if (self.available.items.len > 0) {
            const thread = self.available.pop();
            try self.resetCoroutine(thread);
            return thread;
        }
        
        if (self.active.count() < self.pool_size) {
            const thread = c.lua_newthread(self.main_thread);
            if (thread == null) return error.CoroutineCreationFailed;
            
            // Keep reference to prevent GC
            const ref = c.luaL_ref(self.main_thread, c.LUA_REGISTRYINDEX);
            try self.active.put(thread, CoroutineInfo{ .registry_ref = ref });
            
            return thread;
        }
        
        return error.PoolExhausted;
    }
    
    pub fn release(self: *CoroutinePool, thread: *lua_State) void {
        if (self.available.items.len < self.pool_size / 2) {
            self.available.append(thread) catch {
                // Pool full, remove from active
                self.removeFromActive(thread);
            };
        } else {
            self.removeFromActive(thread);
        }
    }
    
    fn resetCoroutine(self: *CoroutinePool, thread: *lua_State) !void {
        // Clear stack
        c.lua_settop(thread, 0);
        
        // Reset debug hooks
        c.lua_sethook(thread, null, 0, 0);
        
        // Verify coroutine is in correct state
        const status = c.lua_status(thread);
        if (status != c.LUA_OK) {
            return error.CoroutineNotReusable;
        }
    }
};
```

### Batch Execution

```zig
pub fn executeBatch(scheduler: *AsyncScheduler, time_budget_ms: u32) !ExecutionStats {
    var stats = ExecutionStats{};
    const start_time = std.time.milliTimestamp();
    
    while (std.time.milliTimestamp() - start_time < time_budget_ms) {
        const batch_start = std.time.milliTimestamp();
        
        // Process ready coroutines
        var executed_count: u32 = 0;
        for (scheduler.ready_queue.items) |promise| {
            if (promise.status == .pending) {
                try promise.resume();
                executed_count += 1;
                
                // Yield CPU every 10 coroutines
                if (executed_count % 10 == 0) {
                    break;
                }
            }
        }
        
        stats.coroutines_executed += executed_count;
        stats.batch_count += 1;
        
        if (executed_count == 0) break; // No work to do
        
        const batch_time = std.time.milliTimestamp() - batch_start;
        stats.total_execution_time += batch_time;
    }
    
    return stats;
}
```

## 6. Security and Sandboxing

### Secure Coroutine Environment

```zig
const SecureCoroutineContext = struct {
    base_context: *ScriptContext,
    permissions: SecurityPermissions,
    limits: ResourceLimits,
    monitor: ResourceMonitor,
    
    pub fn createSecure(allocator: std.mem.Allocator, config: SecureConfig) !*SecureCoroutineContext {
        const ctx = try allocator.create(SecureCoroutineContext);
        ctx.base_context = try ScriptContext.init(allocator);
        ctx.permissions = config.permissions;
        ctx.limits = config.limits;
        ctx.monitor = ResourceMonitor.init(allocator);
        
        return ctx;
    }
    
    pub fn createCoroutine(self: *SecureCoroutineContext, script: []const u8) !*lua_State {
        const thread = c.lua_newthread(self.base_context.engine_context);
        
        // Apply sandbox environment
        try self.applySandbox(thread);
        
        // Set resource limits
        try self.setResourceLimits(thread);
        
        // Load script in protected mode
        if (c.luaL_loadbuffer(thread, script.ptr, script.len, "secure_script") != c.LUA_OK) {
            const error_msg = c.lua_tostring(thread, -1);
            return ScriptError.fromString(error_msg);
        }
        
        return thread;
    }
    
    fn applySandbox(self: *SecureCoroutineContext, thread: *lua_State) !void {
        // Create restricted global environment
        c.lua_newtable(thread);
        const env_table = c.lua_gettop(thread);
        
        // Add allowed functions based on permissions
        if (self.permissions.io_operations) {
            addIOFunctions(thread, env_table);
        }
        
        if (self.permissions.network_access) {
            addNetworkFunctions(thread, env_table);
        }
        
        if (self.permissions.file_system) {
            addFileSystemFunctions(thread, env_table);
        }
        
        // Block dangerous functions
        blockDangerousFunctions(thread, env_table);
        
        // Set as environment for loaded function
        if (!c.lua_setupvalue(thread, -2, 1)) {
            return error.SandboxSetupFailed;
        }
    }
};
```

### Resource Monitoring

```zig
fn instructionLimitHook(L: ?*c.lua_State, ar: *c.lua_Debug) callconv(.C) void {
    const ctx = getScriptContext(L);
    ctx.instruction_count += 1;
    
    if (ctx.instruction_count > ctx.max_instructions) {
        c.luaL_error(L, "Instruction limit exceeded");
    }
    
    // Check memory usage every 1000 instructions
    if (ctx.instruction_count % 1000 == 0) {
        const memory_kb = c.lua_gc(L, c.LUA_GCCOUNT, 0);
        if (memory_kb * 1024 > ctx.max_memory_bytes) {
            c.luaL_error(L, "Memory limit exceeded");
        }
    }
}
```

## 7. Integration with zig_llms Systems

### Hook System Integration

```zig
// New hook points for coroutines
pub const CoroutineHookPoint = enum {
    coroutine_created,
    coroutine_started,
    coroutine_yielded,
    coroutine_resumed,
    coroutine_completed,
    coroutine_failed,
};

pub const CoroutineHookContext = struct {
    thread: *lua_State,
    script_context: *ScriptContext,
    execution_time: u64,
    memory_usage: usize,
    yield_values: ?[]const ScriptValue,
    result: ?ScriptValue,
    error: ?ScriptError,
};

// Integration with existing hook system
fn executeCoroutineHooks(hook_point: CoroutineHookPoint, hook_ctx: CoroutineHookContext) !void {
    const hook_manager = hook_ctx.script_context.hook_manager;
    const zig_hook_point = switch (hook_point) {
        .coroutine_created => HookPoint.agent_init, // Reuse existing points
        .coroutine_completed => HookPoint.agent_after_run,
        // ... map other coroutine events
    };
    
    try hook_manager.execute(zig_hook_point, .{
        .context = hook_ctx.script_context,
        .metadata = .{
            .coroutine_info = hook_ctx,
        },
    });
}
```

### Event System Integration

```zig
pub const CoroutineEventData = struct {
    thread_id: u64,
    script_name: []const u8,
    status: PromiseStatus,
    execution_time_ms: u64,
    memory_usage_bytes: usize,
    yield_count: u32,
};

// Emit events for coroutine lifecycle
fn emitCoroutineEvent(event_type: []const u8, data: CoroutineEventData, emitter: *EventEmitter) !void {
    const event = Event{
        .name = event_type,
        .timestamp = std.time.nanoTimestamp(),
        .data = EventData{ .coroutine = data },
    };
    
    try emitter.emit(event);
}

// Usage in coroutine manager
pub fn resumeCoroutine(promise: *LuaPromise) !void {
    const start_time = std.time.milliTimestamp();
    
    // Emit resume event
    try emitCoroutineEvent("coroutine.resume", .{
        .thread_id = @intFromPtr(promise.thread),
        .script_name = promise.context.script_name,
        .status = .pending,
        .execution_time_ms = 0,
        .memory_usage_bytes = getCurrentMemoryUsage(promise.thread),
        .yield_count = promise.yield_count,
    }, promise.context.event_emitter);
    
    // Resume execution
    const result = try resumeCoroutineSafe(promise.context, promise.thread, &.{});
    
    const execution_time = std.time.milliTimestamp() - start_time;
    
    // Emit completion event
    try emitCoroutineEvent("coroutine.completed", .{
        .thread_id = @intFromPtr(promise.thread),
        .script_name = promise.context.script_name,
        .status = if (result == .completed) .resolved else .pending,
        .execution_time_ms = @intCast(execution_time),
        .memory_usage_bytes = getCurrentMemoryUsage(promise.thread),
        .yield_count = promise.yield_count,
    }, promise.context.event_emitter);
}
```

## 8. Implementation Roadmap

### Phase 1: Core Infrastructure (Week 1)
1. **CoroutinePool**: Basic coroutine creation and pooling
2. **LuaPromise**: Promise wrapper for coroutines 
3. **AsyncScheduler**: Simple scheduling and execution
4. **Basic error handling**: Protected execution and error propagation

### Phase 2: Async/Await API (Week 2)
1. **lua_async()**: Function to create async coroutines
2. **lua_await()**: Function to wait for promise resolution
3. **Continuation functions**: Support for yieldk-based async operations
4. **Basic I/O integration**: HTTP requests, timers

### Phase 3: Integration (Week 3)
1. **Hook system integration**: Coroutine lifecycle hooks
2. **Event system integration**: Coroutine event emission
3. **Security integration**: Sandbox and resource limits
4. **ScriptValue integration**: Full type conversion support

### Phase 4: Advanced Features (Week 4)
1. **Performance optimization**: Batch execution, instruction counting
2. **Debugging support**: Debug hooks, execution tracing
3. **Error handling**: Try-catch patterns, error recovery
4. **Documentation and examples**: Usage patterns and best practices

## 9. API Design

### Lua Script API

```lua
-- Basic async/await
local promise = async(function()
    local response = await(http_get("https://api.example.com/data"))
    return json_parse(response.body)
end)

local result = await(promise)

-- Error handling
local safe_promise = try_async(function()
    local data = await(risky_operation())
    return process_data(data)
end):catch(function(error)
    log_error("Operation failed: " .. error.message)
    return default_value()
end)

-- Timer-based async
local delayed = async(function()
    await(sleep(1000)) -- Wait 1 second
    return "delayed result"
end)

-- Parallel execution
local promises = {
    async(function() return await(fetch_user_data()) end),
    async(function() return await(fetch_preferences()) end),
    async(function() return await(fetch_notifications()) end)
}

local results = await(all(promises))
```

### Zig Integration API

```zig
// Create coroutine manager
var coro_manager = try LuaCoroutineManager.init(allocator, .{
    .pool_size = 100,
    .max_execution_time_ms = 5000,
    .max_memory_mb = 50,
});

// Execute async script
const promise = try coro_manager.createAsync(
    \\local result = await(http_get("https://api.example.com"))
    \\return json_parse(result.body)
, script_context);

// Pump event loop
while (promise.status == .pending) {
    try coro_manager.pump();
    std.time.sleep(1_000_000); // 1ms
}

// Get result
const result = try promise.await();
defer result.deinit(allocator);
```

## Conclusion

This integration plan provides a comprehensive roadmap for implementing Lua coroutines with async/await patterns in zig_llms. The design maintains compatibility with existing systems while providing powerful async programming capabilities that integrate seamlessly with the ScriptValue conversion system and security framework.

Key benefits:
- **Seamless Integration**: Works with existing hook, event, and security systems
- **Performance**: Efficient coroutine pooling and batch execution
- **Security**: Full sandboxing and resource limit integration  
- **Developer Experience**: Familiar async/await patterns for script authors
- **Flexibility**: Support for various async patterns (promises, events, continuations)

The modular design allows for incremental implementation and testing, ensuring stability throughout the development process.