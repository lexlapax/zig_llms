# Lua Engine Architecture for zig_llms

## Executive Summary

This document presents the comprehensive architecture for the Lua 5.4 scripting engine integration in zig_llms. It synthesizes extensive research into a unified design that provides secure, performant, and feature-rich scripting capabilities while maintaining seamless integration with the existing zig_llms infrastructure.

### Key Design Principles

1. **Security First**: Multi-layer sandboxing with bytecode validation
2. **Performance Optimized**: Configurable GC, state pooling, minimal overhead
3. **Developer Friendly**: Full debugging support, comprehensive tooling
4. **Type Safe**: Bidirectional type conversion with ScriptValue bridge
5. **Async Native**: Coroutine-based async/await patterns
6. **Production Ready**: Warning system, monitoring, adaptive optimization

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Components](#core-components)
3. [Memory Management](#memory-management)
4. [Type System Bridge](#type-system-bridge)
5. [Security Architecture](#security-architecture)
6. [Async/Coroutine System](#asynccoroutine-system)
7. [Garbage Collection Strategy](#garbage-collection-strategy)
8. [Warning and Diagnostics](#warning-and-diagnostics)
9. [Debug and Development Tools](#debug-and-development-tools)
10. [API Bridge Integration](#api-bridge-integration)
11. [Performance Optimization](#performance-optimization)
12. [Implementation Plan](#implementation-plan)

---

## Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         zig_llms Application                     │
├─────────────────────────────────────────────────────────────────┤
│                    ScriptingEngine Interface                     │
├─────────────────────────────────────────────────────────────────┤
│                        LuaEngine Implementation                  │
│  ┌─────────────┬──────────────┬──────────────┬───────────────┐ │
│  │   State     │    Type      │   Security   │    Async      │ │
│  │  Manager    │  Converter   │   Manager    │   Manager     │ │
│  ├─────────────┼──────────────┼──────────────┼───────────────┤ │
│  │   Debug     │   Warning    │      GC      │   API         │ │
│  │  Manager    │   Handler    │   Strategy   │  Bridges      │ │
│  └─────────────┴──────────────┴──────────────┴───────────────┘ │
├─────────────────────────────────────────────────────────────────┤
│                         Lua 5.4 Runtime                          │
└─────────────────────────────────────────────────────────────────┘
```

### Component Interaction Flow

```zig
pub const LuaEngine = struct {
    const Self = @This();
    
    // Core components
    state_manager: *LuaStateManager,      // lua_State lifecycle and pooling
    converter: *LuaConverter,             // ScriptValue ↔ Lua conversion
    security_manager: *LuaSecurityManager,// Sandboxing and validation
    coroutine_manager: *LuaCoroutineManager, // Async/await support
    
    // Supporting systems
    warning_handler: *LuaWarningHandler,  // Runtime diagnostics
    gc_strategy: *LuaGCStrategy,          // Adaptive GC management
    debug_manager: ?*LuaDebugManager,     // Development tools
    api_bridge: *LuaAPIBridge,            // zig_llms API access
    
    // ScriptingEngine interface
    engine: ScriptingEngine,
    
    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        const self = try allocator.create(Self);
        
        // Initialize in dependency order
        self.state_manager = try LuaStateManager.init(allocator, config);
        self.converter = try LuaConverter.init(allocator);
        self.security_manager = try LuaSecurityManager.init(allocator, config);
        
        // Optional components based on config
        if (config.features.async_support) {
            self.coroutine_manager = try LuaCoroutineManager.init(allocator, self.state_manager);
        }
        
        if (config.features.debugging) {
            self.debug_manager = try LuaDebugManager.init(allocator, config.debug_config);
        }
        
        // Set up vtable
        self.engine = ScriptingEngine{
            .impl = self,
            .metadata = getLuaEngineMetadata(),
            .vtable = &LUA_ENGINE_VTABLE,
        };
        
        return self;
    }
};
```

---

## Core Components

### 1. LuaStateManager

Manages lua_State lifecycle with pooling for performance and isolation for security.

```zig
pub const LuaStateManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    main_state: *c.lua_State,
    state_pool: StatePool,
    state_registry: std.AutoHashMap(*c.lua_State, StateInfo),
    config: StateConfig,
    
    pub const StateConfig = struct {
        pool_size: usize = 10,
        enable_pooling: bool = true,
        state_isolation: IsolationLevel = .thread_local,
        memory_limit_per_state: ?usize = null,
    };
    
    pub const IsolationLevel = enum {
        shared,        // Single state, not thread-safe
        thread_local,  // State per thread
        per_context,   // State per ScriptContext
    };
    
    pub fn acquireState(self: *Self, context: *ScriptContext) !*LuaState {
        // Get or create state based on isolation level
        const state = switch (self.config.state_isolation) {
            .shared => self.main_state,
            .thread_local => try self.getThreadLocalState(),
            .per_context => try self.getContextState(context),
        };
        
        // Apply security and resource limits
        try self.security_manager.setupSecurity(state, context);
        
        // Set up warning handler
        c.lua_setwarnf(state.state, LuaWarningHandler.warnCallback, self.warning_handler);
        
        return state;
    }
};
```

### 2. LuaConverter

Handles bidirectional type conversion between ScriptValue and Lua types.

```zig
pub const LuaConverter = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    type_cache: TypeCache,
    stack_guard_enabled: bool = true,
    
    pub fn scriptValueToLua(self: *Self, state: *c.lua_State, value: ScriptValue) !void {
        const guard = if (self.stack_guard_enabled) LuaStackGuard.init(state) else null;
        defer if (guard) |g| g.deinit();
        
        switch (value) {
            .nil => c.lua_pushnil(state),
            .boolean => |b| c.lua_pushboolean(state, if (b) 1 else 0),
            .integer => |i| c.lua_pushinteger(state, i),
            .number => |n| c.lua_pushnumber(state, n),
            .string => |s| c.lua_pushlstring(state, s.ptr, s.len),
            .array => |arr| try self.pushArray(state, arr),
            .object => |obj| try self.pushObject(state, obj),
            .function => |func| try self.pushFunction(state, func),
            .userdata => |ud| try self.pushUserData(state, ud),
        }
    }
    
    pub fn luaToScriptValue(self: *Self, state: *c.lua_State, index: i32) !ScriptValue {
        const lua_type = c.lua_type(state, index);
        
        return switch (lua_type) {
            c.LUA_TNIL => ScriptValue.nil,
            c.LUA_TBOOLEAN => ScriptValue{ .boolean = c.lua_toboolean(state, index) != 0 },
            c.LUA_TNUMBER => self.convertNumber(state, index),
            c.LUA_TSTRING => try self.convertString(state, index),
            c.LUA_TTABLE => try self.convertTable(state, index),
            c.LUA_TFUNCTION => try self.convertFunction(state, index),
            c.LUA_TUSERDATA => try self.convertUserData(state, index),
            c.LUA_TTHREAD => try self.convertThread(state, index),
            else => error.UnsupportedLuaType,
        };
    }
    
    // Optimized table detection
    fn isArrayLikeTable(self: *Self, state: *c.lua_State, index: i32) bool {
        const len = c.lua_rawlen(state, index);
        if (len == 0) return false;
        
        // Check if keys 1..len exist and no other keys
        var expected_count: usize = 0;
        c.lua_pushnil(state);
        while (c.lua_next(state, index) != 0) : (expected_count += 1) {
            defer c.lua_pop(state, 1);
            
            // Must be positive integer key
            if (c.lua_type(state, -2) != c.LUA_TNUMBER) {
                c.lua_pop(state, 1);
                return false;
            }
            
            if (c.lua_isinteger(state, -2) == 0) {
                c.lua_pop(state, 1);
                return false;
            }
            
            const key = c.lua_tointeger(state, -2);
            if (key < 1 or key > len) {
                c.lua_pop(state, 1);
                return false;
            }
        }
        
        return expected_count == len;
    }
};
```

---

## Memory Management

### Zig Allocator Integration

```zig
fn luaAllocator(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
    const alloc_ctx = @ptrCast(*AllocatorContext, @alignCast(@alignOf(*AllocatorContext), ud));
    
    // Track memory for limits
    if (alloc_ctx.memory_limit) |limit| {
        const new_total = alloc_ctx.current_usage + nsize - osize;
        if (new_total > limit) {
            return null; // Allocation denied
        }
        alloc_ctx.current_usage = new_total;
    }
    
    if (nsize == 0) {
        // Free
        if (ptr) |p| {
            const slice = @ptrCast([*]u8, p)[0..osize];
            alloc_ctx.allocator.free(slice);
        }
        return null;
    } else if (ptr == null) {
        // Allocate
        const slice = alloc_ctx.allocator.alloc(u8, nsize) catch return null;
        return slice.ptr;
    } else {
        // Reallocate
        const old_slice = @ptrCast([*]u8, ptr)[0..osize];
        const new_slice = alloc_ctx.allocator.realloc(old_slice, nsize) catch return null;
        return new_slice.ptr;
    }
}
```

### State Pool Management

```zig
pub const StatePool = struct {
    const Self = @This();
    
    available: std.ArrayList(*LuaState),
    active: std.HashMap(*LuaState, StateInfo),
    max_pool_size: usize,
    
    // Performance tracking
    pool_hits: u64 = 0,
    pool_misses: u64 = 0,
    
    pub fn acquire(self: *Self) !*LuaState {
        if (self.available.items.len > 0) {
            const state = self.available.pop();
            try self.resetState(state);
            self.pool_hits += 1;
            return state;
        }
        
        if (self.active.count() < self.max_pool_size) {
            const state = try self.createNewState();
            self.pool_misses += 1;
            return state;
        }
        
        return error.PoolExhausted;
    }
    
    fn resetState(self: *Self, state: *LuaState) !void {
        // Fast reset without full reinitialization
        c.lua_settop(state.state, 0);
        
        // Clear registry entries except critical ones
        self.clearUserRegistry(state);
        
        // Reset hooks
        c.lua_sethook(state.state, null, 0, 0);
        
        // Collect garbage
        _ = c.lua_gc(state.state, c.LUA_GCCOLLECT, 0);
    }
};
```

---

## Security Architecture

### Multi-Layer Security Model

```
┌─────────────────────────────────────────┐
│         Layer 1: Engine Level           │
│    - Bytecode validation               │
│    - Binary chunk blocking             │
│    - Module loading restrictions       │
├─────────────────────────────────────────┤
│         Layer 2: Context Level          │
│    - Resource limits (CPU, memory)     │
│    - Execution timeouts                │
│    - Instruction counting              │
├─────────────────────────────────────────┤
│         Layer 3: Environment Level      │
│    - Isolated global environments      │
│    - Function whitelisting             │
│    - Metatable protection              │
├─────────────────────────────────────────┤
│         Layer 4: Runtime Level          │
│    - Pattern matching limits           │
│    - String operation safety           │
│    - Table traversal protection        │
└─────────────────────────────────────────┘
```

### Security Manager Implementation

```zig
pub const LuaSecurityManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    policies: std.EnumMap(SandboxLevel, SecurityPolicy),
    bytecode_validator: *BytecodeValidator,
    environment_builder: *EnvironmentBuilder,
    
    pub fn setupSecurity(self: *Self, state: *c.lua_State, context: *ScriptContext) !void {
        const policy = self.policies.get(context.sandbox_level);
        
        // Layer 1: Bytecode security
        if (policy.validate_bytecode) {
            self.installBytecodeValidator(state);
        }
        
        // Layer 2: Resource limits
        if (policy.enable_resource_limits) {
            try self.installResourceMonitor(state, context.limits);
        }
        
        // Layer 3: Environment isolation
        const env = try self.environment_builder.createSecureEnvironment(state, policy);
        self.setScriptEnvironment(state, env);
        
        // Layer 4: Runtime protections
        self.installRuntimeProtections(state, policy);
    }
    
    fn installResourceMonitor(self: *Self, state: *c.lua_State, limits: ResourceLimits) !void {
        const hook_mask = c.LUA_MASKCOUNT | 
                         (if (limits.trace_execution) c.LUA_MASKLINE else 0);
        
        c.lua_sethook(state, resourceLimitHook, hook_mask, 1000);
        
        // Store limits in registry
        c.lua_pushlightuserdata(state, &limits);
        c.lua_setfield(state, c.LUA_REGISTRYINDEX, "RESOURCE_LIMITS");
    }
};
```

### Bytecode Validation

```zig
pub const BytecodeValidator = struct {
    const Self = @This();
    
    config: ValidationConfig,
    
    pub fn validate(self: *Self, bytecode: []const u8) !void {
        // Size check
        if (bytecode.len > self.config.max_bytecode_size) {
            return error.BytecodeTooLarge;
        }
        
        // Header validation
        if (bytecode.len < 12 or !std.mem.eql(u8, bytecode[0..4], "\x1bLua")) {
            return error.InvalidBytecodeHeader;
        }
        
        // Version check
        if (bytecode[4] != 0x54) { // Lua 5.4
            return error.UnsupportedLuaVersion;
        }
        
        // Deep validation
        try self.validateInstructions(bytecode);
        try self.validateConstants(bytecode);
        try self.validateDebugInfo(bytecode);
    }
    
    pub fn createSecureLoader(self: *Self) c.lua_CFunction {
        return struct {
            fn loader(L: ?*c.lua_State) callconv(.C) c_int {
                const chunk = c.lua_tostring(L, 1);
                const mode = c.lua_tostring(L, 3) orelse "t";
                
                // Force text mode in secure environments
                if (std.mem.indexOf(u8, std.mem.span(mode), "b") != null) {
                    _ = c.luaL_error(L, "Binary chunks are not permitted");
                    return 0;
                }
                
                return c.luaL_loadbufferx(L, chunk, std.mem.len(chunk), "chunk", "t");
            }
        }.loader;
    }
};
```

### Safe Environment Builder

```zig
pub const EnvironmentBuilder = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    
    pub fn createSecureEnvironment(self: *Self, state: *c.lua_State, policy: SecurityPolicy) !void {
        // Create new environment table
        c.lua_newtable(state);
        const env_idx = c.lua_gettop(state);
        
        // Add safe standard library functions
        if (policy.allow_standard_libs) {
            self.addSafeStandardLibs(state, env_idx, policy);
        }
        
        // Add custom safe functions
        self.addCustomSafeFunctions(state, env_idx);
        
        // Set up metatable for controlled access
        c.lua_newtable(state);
        c.lua_pushcfunction(state, secureEnvIndex);
        c.lua_setfield(state, -2, "__index");
        c.lua_pushcfunction(state, secureEnvNewIndex);
        c.lua_setfield(state, -2, "__newindex");
        c.lua_setmetatable(state, env_idx);
        
        return env_idx;
    }
    
    fn addSafeStandardLibs(self: *Self, state: *c.lua_State, env_idx: i32, policy: SecurityPolicy) void {
        // Safe math library
        c.lua_getglobal(state, "math");
        c.lua_setfield(state, env_idx, "math");
        
        // Filtered string library
        c.lua_newtable(state);
        const string_funcs = [_][]const u8{
            "byte", "char", "format", "len", "lower", "upper", "reverse", "sub"
        };
        
        c.lua_getglobal(state, "string");
        for (string_funcs) |func| {
            c.lua_getfield(state, -1, func.ptr);
            c.lua_setfield(state, -3, func.ptr);
        }
        c.lua_pop(state, 1); // Pop original string table
        
        // Add pattern functions with protection
        if (policy.allow_pattern_matching) {
            self.addSafePatternFunctions(state, -1);
        }
        
        c.lua_setfield(state, env_idx, "string");
        
        // Safe table library
        c.lua_getglobal(state, "table");
        c.lua_setfield(state, env_idx, "table");
        
        // Filtered base functions
        const safe_base = [_][]const u8{
            "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall",
            "select", "tonumber", "tostring", "type", "unpack"
        };
        
        for (safe_base) |func| {
            c.lua_getglobal(state, func.ptr);
            c.lua_setfield(state, env_idx, func.ptr);
        }
    }
};
```

---

## Async/Coroutine System

### Promise-Based Async Model

```zig
pub const LuaCoroutineManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    coroutine_pool: CoroutinePool,
    promise_registry: std.AutoHashMap(u64, *LuaPromise),
    scheduler: AsyncScheduler,
    
    pub fn createAsync(self: *Self, script: []const u8, context: *ScriptContext) !*LuaPromise {
        const thread = try self.coroutine_pool.acquire();
        errdefer self.coroutine_pool.release(thread);
        
        // Load function into coroutine
        const result = c.luaL_loadstring(thread, script.ptr);
        if (result != c.LUA_OK) {
            return self.createRejectedPromise(c.lua_tostring(thread, -1));
        }
        
        // Create promise
        const promise = try self.allocator.create(LuaPromise);
        promise.* = LuaPromise{
            .id = self.generatePromiseId(),
            .thread = thread,
            .status = .pending,
            .context = context,
            .manager = self,
        };
        
        try self.promise_registry.put(promise.id, promise);
        try self.scheduler.schedule(promise);
        
        return promise;
    }
    
    pub fn registerAsyncAPIs(self: *Self, state: *c.lua_State) !void {
        // Register async/await functions
        const async_apis = [_]struct { name: []const u8, func: c.lua_CFunction }{
            .{ .name = "async", .func = luaAsync },
            .{ .name = "await", .func = luaAwait },
            .{ .name = "all", .func = luaAwaitAll },
            .{ .name = "race", .func = luaAwaitRace },
            .{ .name = "delay", .func = luaDelay },
        };
        
        for (async_apis) |api| {
            c.lua_pushcfunction(state, api.func);
            c.lua_setglobal(state, api.name.ptr);
        }
    }
};

pub const LuaPromise = struct {
    id: u64,
    thread: *c.lua_State,
    status: PromiseStatus,
    result: ?ScriptValue = null,
    error: ?ScriptError = null,
    context: *ScriptContext,
    manager: *LuaCoroutineManager,
    
    continuations: std.ArrayList(Continuation) = undefined,
    
    pub fn @"then"(self: *LuaPromise, callback: ScriptFunction) !*LuaPromise {
        if (self.status == .resolved) {
            // Immediately execute callback
            return self.manager.executeCallback(callback, self.result);
        }
        
        const continuation = Continuation{
            .type = .then_callback,
            .callback = callback,
            .promise = try self.manager.createPendingPromise(),
        };
        
        try self.continuations.append(continuation);
        return continuation.promise;
    }
    
    pub fn @"catch"(self: *LuaPromise, error_handler: ScriptFunction) !*LuaPromise {
        if (self.status == .rejected) {
            // Immediately execute error handler
            return self.manager.executeErrorHandler(error_handler, self.error);
        }
        
        const continuation = Continuation{
            .type = .catch_callback,
            .callback = error_handler,
            .promise = try self.manager.createPendingPromise(),
        };
        
        try self.continuations.append(continuation);
        return continuation.promise;
    }
};
```

### Async I/O Integration

```zig
// Example async HTTP integration
export fn luaHttpGet(L: ?*c.lua_State) callconv(.C) c_int {
    const url = c.lua_tostring(L, 1) orelse {
        return c.luaL_error(L, "http_get requires URL string");
    };
    
    const manager = getCoroutineManager(L);
    
    // Start async operation
    const request_id = manager.startAsyncOperation(.http_get, .{
        .url = std.mem.span(url),
    }) catch {
        return c.luaL_error(L, "Failed to start HTTP request");
    };
    
    // Yield with continuation
    return c.lua_yieldk(L, 0, request_id, httpGetContinuation);
}

fn httpGetContinuation(L: ?*c.lua_State, status: c_int, ctx: c.lua_KContext) callconv(.C) c_int {
    const request_id = @intCast(u64, ctx);
    const manager = getCoroutineManager(L);
    
    const result = manager.getAsyncResult(request_id) catch {
        return c.luaL_error(L, "Failed to get HTTP result");
    };
    
    switch (result) {
        .pending => {
            // Still waiting, yield again
            return c.lua_yieldk(L, 0, ctx, httpGetContinuation);
        },
        .completed => |response| {
            // Push response table
            c.lua_newtable(L);
            
            c.lua_pushinteger(L, response.status_code);
            c.lua_setfield(L, -2, "status");
            
            c.lua_pushlstring(L, response.body.ptr, response.body.len);
            c.lua_setfield(L, -2, "body");
            
            // Push headers table
            pushHeaders(L, response.headers);
            c.lua_setfield(L, -2, "headers");
            
            return 1;
        },
        .failed => |err| {
            return c.luaL_error(L, "HTTP request failed: %s", err.message.ptr);
        },
    }
}
```

---

## Garbage Collection Strategy

### Adaptive GC Management

```zig
pub const LuaGCStrategy = struct {
    const Self = @This();
    
    current_mode: GCMode,
    config: GCConfig,
    metrics: GCMetrics,
    adaptation_enabled: bool = true,
    
    pub const GCMode = enum {
        incremental,
        generational,
    };
    
    pub fn selectModeForWorkload(self: *Self, workload: WorkloadProfile) !void {
        const new_mode = switch (workload) {
            .web_service => .generational,    // Short-lived objects
            .game_engine => .incremental,      // Predictable pauses
            .data_processing => .generational, // Throughput focused
            .general_purpose => .incremental,  // Safe default
        };
        
        if (new_mode != self.current_mode) {
            try self.switchMode(new_mode);
        }
    }
    
    pub fn applyToState(self: *Self, L: *c.lua_State) !void {
        switch (self.current_mode) {
            .incremental => {
                _ = c.luaL_dostring(L, "collectgarbage('incremental')");
                _ = c.lua_gc(L, c.LUA_GCSETPAUSE, self.config.incremental.pause);
                _ = c.lua_gc(L, c.LUA_GCSETSTEPMUL, self.config.incremental.step_mul);
            },
            .generational => {
                _ = c.luaL_dostring(L, "collectgarbage('generational')");
                const cmd = try std.fmt.allocPrint(self.allocator,
                    "collectgarbage('setminorpause', {})\n" ++
                    "collectgarbage('setmajorpause', {})",
                    .{ self.config.generational.minor_pause, self.config.generational.major_pause }
                );
                defer self.allocator.free(cmd);
                _ = c.luaL_dostring(L, cmd.ptr);
            },
        }
    }
    
    pub fn adaptToMetrics(self: *Self) !void {
        if (!self.adaptation_enabled) return;
        
        const overhead = self.metrics.getGCOverheadPercent();
        const pause_variance = self.metrics.getPauseVariance();
        
        // High overhead with incremental -> try generational
        if (self.current_mode == .incremental and overhead > 15.0) {
            try self.switchMode(.generational);
            return;
        }
        
        // High pause variance with generational -> try incremental
        if (self.current_mode == .generational and pause_variance > 100.0) {
            try self.switchMode(.incremental);
            return;
        }
        
        // Tune current mode parameters
        try self.tuneCurrentMode();
    }
};
```

### GC Configuration Presets

```zig
pub const GCPresets = struct {
    pub fn lowLatency() GCConfig {
        return .{
            .mode = .incremental,
            .incremental = .{
                .pause = 150,     // Earlier collection
                .step_mul = 50,   // Smaller steps
            },
        };
    }
    
    pub fn highThroughput() GCConfig {
        return .{
            .mode = .generational,
            .generational = .{
                .minor_pause = 30,  // Less frequent minor
                .major_pause = 300, // Delay major
            },
        };
    }
    
    pub fn balanced() GCConfig {
        return .{
            .mode = .incremental,
            .incremental = .{
                .pause = 200,     // Default
                .step_mul = 100,  // Default
            },
        };
    }
};
```

---

## Warning and Diagnostics

### Warning System Integration

```zig
pub const LuaWarningHandler = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    processor: *WarningProcessor,
    config: WarningConfig,
    buffer: std.ArrayList(u8),
    
    pub fn init(allocator: std.mem.Allocator, config: WarningConfig) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .processor = try WarningProcessor.init(allocator, config),
            .config = config,
            .buffer = std.ArrayList(u8).init(allocator),
        };
        
        // Set up filters
        if (config.categories) |cats| {
            const filter = try CategoryFilter.init(cats);
            try self.processor.addFilter(filter);
        }
        
        if (config.rate_limit) |rate| {
            const filter = try RateLimitFilter.init(rate);
            try self.processor.addFilter(filter);
        }
        
        return self;
    }
    
    pub fn warnCallback(ud: ?*anyopaque, msg: [*c]const u8, tocont: c_int) callconv(.C) void {
        const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ud));
        const message = std.mem.span(msg);
        
        // Handle control messages
        if (std.mem.eql(u8, message, "@on")) {
            self.config.enabled = true;
            return;
        }
        if (std.mem.eql(u8, message, "@off")) {
            self.config.enabled = false;
            return;
        }
        
        if (!self.config.enabled) return;
        
        self.handleWarning(message, tocont != 0) catch |err| {
            std.log.err("Warning handler error: {}", .{err});
        };
    }
    
    fn handleWarning(self: *Self, msg: []const u8, is_continuation: bool) !void {
        if (is_continuation) {
            try self.buffer.appendSlice(msg);
        } else {
            if (self.buffer.items.len > 0) {
                try self.buffer.appendSlice(msg);
                try self.processWarning(self.buffer.items);
                self.buffer.clearRetainingCapacity();
            } else {
                try self.processWarning(msg);
            }
        }
    }
    
    fn processWarning(self: *Self, message: []const u8) !void {
        const warning = try self.parseWarning(message);
        try self.processor.process(warning);
    }
};

pub const WarningConfig = struct {
    enabled: bool = true,
    categories: ?std.EnumSet(WarningCategory) = null,
    rate_limit: ?f64 = null,
    batch_size: usize = 100,
    persistence: bool = false,
    
    pub fn production() WarningConfig {
        return .{
            .enabled = true,
            .categories = std.EnumSet(WarningCategory).init(.{
                .security = true,
                .undefined_behavior = true,
                .deprecation = true,
            }),
            .rate_limit = 10.0, // 10 warnings/second max
            .batch_size = 100,
            .persistence = true,
        };
    }
};
```

---

## Debug and Development Tools

### Debug Manager Architecture

```zig
pub const LuaDebugManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    config: DebugConfig,
    
    // Core components
    hook_manager: *DebugHookManager,
    stack_inspector: *StackInspector,
    breakpoint_manager: *BreakpointManager,
    
    // Optional components
    profiler: ?*LuaProfiler = null,
    debugger: ?*InteractiveDebugger = null,
    dap_server: ?*DAPServer = null,
    
    pub fn init(allocator: std.mem.Allocator, config: DebugConfig) !*Self {
        const self = try allocator.create(Self);
        
        self.allocator = allocator;
        self.config = config;
        
        // Always create core components
        self.hook_manager = try DebugHookManager.init(allocator);
        self.stack_inspector = try StackInspector.init(allocator);
        self.breakpoint_manager = try BreakpointManager.init(allocator);
        
        // Optional based on config
        if (config.enable_profiler) {
            self.profiler = try LuaProfiler.init(allocator, config.profiler_config);
        }
        
        if (config.enable_interactive_debugger) {
            self.debugger = try InteractiveDebugger.init(allocator);
        }
        
        if (config.enable_dap) {
            self.dap_server = try DAPServer.init(allocator, config.dap_config);
        }
        
        return self;
    }
    
    pub fn attachToState(self: *Self, L: *c.lua_State) !void {
        // Store reference in registry
        c.lua_pushlightuserdata(L, self);
        c.lua_setfield(L, c.LUA_REGISTRYINDEX, "DEBUG_MANAGER");
        
        // Install hooks based on config
        var events = HookEvents{};
        
        if (self.config.enable_breakpoints) {
            events.on_line = true;
        }
        
        if (self.profiler != null) {
            events.on_call = true;
            events.on_return = true;
            events.instruction_count = self.config.profiler_config.sample_interval;
        }
        
        try self.hook_manager.installHook(L, events);
    }
};

pub const DebugConfig = struct {
    enable_breakpoints: bool = true,
    enable_profiler: bool = false,
    enable_interactive_debugger: bool = false,
    enable_dap: bool = false,
    
    sandbox_debug_access: bool = true,
    max_stack_depth: u32 = 100,
    max_inspect_depth: u32 = 5,
    
    profiler_config: ProfilerConfig = .{},
    dap_config: DAPConfig = .{},
    
    pub fn development() DebugConfig {
        return .{
            .enable_breakpoints = true,
            .enable_profiler = true,
            .enable_interactive_debugger = true,
            .sandbox_debug_access = false,
            .max_stack_depth = 1000,
            .max_inspect_depth = 10,
        };
    }
    
    pub fn production() DebugConfig {
        return .{
            .enable_breakpoints = false,
            .enable_profiler = true,
            .enable_interactive_debugger = false,
            .sandbox_debug_access = true,
            .profiler_config = .{
                .mode = .statistical,
                .sample_interval = 10000,
            },
        };
    }
};
```

### Development Tool Integration

```zig
pub fn createDevelopmentLuaEngine(allocator: std.mem.Allocator) !*LuaEngine {
    const config = EngineConfig{
        .allocator = allocator,
        .sandbox_level = .none, // Full access for development
        .features = .{
            .async_support = true,
            .debugging = true,
            .sandboxing = false,
        },
        .gc_config = GCPresets.lowLatency(),
        .warning_config = WarningConfig{
            .enabled = true,
            .categories = null, // All categories
        },
        .debug_config = DebugConfig.development(),
    };
    
    const engine = try LuaEngine.init(allocator, config);
    
    // Start DAP server for IDE integration
    if (engine.debug_manager) |dm| {
        if (dm.dap_server) |dap| {
            try dap.start();
            std.log.info("DAP server listening on port {}", .{dap.config.port});
        }
    }
    
    return engine;
}
```

---

## API Bridge Integration

### Unified API Bridge System

```zig
pub const LuaAPIBridge = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    bridges: std.StringHashMap(*APIBridge),
    
    pub fn init(allocator: std.mem.Allocator, api_bridges: APIBridges) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.bridges = std.StringHashMap(*APIBridge).init(allocator);
        
        // Register all bridges
        try self.bridges.put("agent", api_bridges.agent_bridge);
        try self.bridges.put("tool", api_bridges.tool_bridge);
        try self.bridges.put("workflow", api_bridges.workflow_bridge);
        try self.bridges.put("provider", api_bridges.provider_bridge);
        try self.bridges.put("event", api_bridges.event_bridge);
        try self.bridges.put("test", api_bridges.test_bridge);
        try self.bridges.put("schema", api_bridges.schema_bridge);
        try self.bridges.put("memory", api_bridges.memory_bridge);
        try self.bridges.put("hook", api_bridges.hook_bridge);
        try self.bridges.put("output", api_bridges.output_bridge);
        
        return self;
    }
    
    pub fn registerAPIs(self: *Self, L: *c.lua_State) !void {
        // Create zigllms global table
        c.lua_newtable(L);
        
        // Register each bridge
        var iter = self.bridges.iterator();
        while (iter.next()) |entry| {
            const bridge_name = entry.key_ptr.*;
            const bridge = entry.value_ptr.*;
            
            // Create module table
            c.lua_newtable(L);
            
            // Register functions
            try self.registerBridgeFunctions(L, bridge);
            
            // Set as zigllms.module
            c.lua_setfield(L, -2, bridge_name.ptr);
        }
        
        c.lua_setglobal(L, "zigllms");
    }
    
    fn registerBridgeFunctions(self: *Self, L: *c.lua_State, bridge: *APIBridge) !void {
        const functions = try bridge.getFunctions();
        
        for (functions) |func| {
            // Create wrapper function
            const wrapper = try self.createLuaWrapper(func);
            c.lua_pushcfunction(L, wrapper);
            c.lua_setfield(L, -2, func.name.ptr);
        }
    }
};
```

### Example API Usage in Lua

```lua
-- Agent API
local agent = zigllms.agent.create({
    name = "assistant",
    provider = "openai",
    model = "gpt-4",
    temperature = 0.7
})

local response = zigllms.agent.run(agent, "Hello, how are you?")
print(response.content)

-- Tool API
local file_tool = zigllms.tool.get("file_operations")
local result = zigllms.tool.execute(file_tool, {
    operation = "read",
    path = "config.json"
})

-- Async workflow
local workflow = async(function()
    local data = await(zigllms.provider.chat({
        messages = { { role = "user", content = "Generate a story" } }
    }))
    
    local saved = await(zigllms.tool.execute("file_operations", {
        operation = "write",
        path = "story.txt",
        content = data.content
    }))
    
    return saved
end)

local result = await(workflow)
```

---

## Performance Optimization

### Optimization Strategies

```zig
pub const PerformanceOptimizer = struct {
    const Self = @This();
    
    config: OptimizationConfig,
    metrics: PerformanceMetrics,
    
    pub const OptimizationConfig = struct {
        // State pooling
        enable_state_pooling: bool = true,
        pool_size: usize = 10,
        
        // Type conversion caching
        enable_type_cache: bool = true,
        cache_size: usize = 1000,
        
        // Bytecode caching
        enable_bytecode_cache: bool = true,
        bytecode_cache_size: usize = 100,
        
        // JIT compilation (if available)
        enable_jit: bool = false,
        
        // GC tuning
        adaptive_gc: bool = true,
        gc_monitoring: bool = true,
    };
    
    pub fn optimizeEngine(self: *Self, engine: *LuaEngine) !void {
        // State pooling
        if (self.config.enable_state_pooling) {
            engine.state_manager.enablePooling(self.config.pool_size);
        }
        
        // Type caching
        if (self.config.enable_type_cache) {
            engine.converter.enableCaching(self.config.cache_size);
        }
        
        // Bytecode cache
        if (self.config.enable_bytecode_cache) {
            try self.setupBytecodeCache(engine);
        }
        
        // GC optimization
        if (self.config.adaptive_gc) {
            engine.gc_strategy.adaptation_enabled = true;
        }
    }
    
    pub fn measurePerformance(self: *Self, benchmark: Benchmark) !PerformanceReport {
        const results = try benchmark.run();
        
        return PerformanceReport{
            .script_execution = .{
                .avg_time_ns = results.avg_execution_time,
                .p99_time_ns = results.p99_execution_time,
                .throughput = results.scripts_per_second,
            },
            .type_conversion = .{
                .to_lua_avg_ns = results.avg_to_lua_time,
                .from_lua_avg_ns = results.avg_from_lua_time,
            },
            .memory = .{
                .heap_size_bytes = results.avg_heap_size,
                .gc_overhead_percent = results.gc_overhead,
            },
            .recommendations = try self.generateRecommendations(results),
        };
    }
};
```

### Performance Benchmarks

```zig
pub const LuaBenchmarks = struct {
    pub fn runAll(engine: *LuaEngine) !BenchmarkResults {
        return .{
            .basic_execution = try benchmarkBasicExecution(engine),
            .type_conversion = try benchmarkTypeConversion(engine),
            .async_operations = try benchmarkAsyncOperations(engine),
            .api_bridges = try benchmarkAPIBridges(engine),
            .security_overhead = try benchmarkSecurityOverhead(engine),
        };
    }
    
    fn benchmarkBasicExecution(engine: *LuaEngine) !ExecutionBenchmark {
        const scripts = [_][]const u8{
            "return 42",
            "local sum = 0; for i = 1, 1000 do sum = sum + i end; return sum",
            "local t = {}; for i = 1, 100 do t[i] = i * 2 end; return #t",
        };
        
        var total_time: u64 = 0;
        const iterations = 10000;
        
        for (scripts) |script| {
            const start = std.time.nanoTimestamp();
            
            for (0..iterations) |_| {
                const context = try ScriptContext.init(engine.allocator, .{});
                defer context.deinit();
                
                _ = try engine.executeScript(script, context);
            }
            
            total_time += std.time.nanoTimestamp() - start;
        }
        
        return .{
            .avg_time_ns = total_time / (scripts.len * iterations),
            .scripts_per_second = @intToFloat(f64, scripts.len * iterations) / 
                                 (@intToFloat(f64, total_time) / 1e9),
        };
    }
};
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1)

**Day 1-2: Project Setup**
- Set up Lua 5.4 dependencies in build.zig
- Create directory structure
- Implement basic LuaEngine skeleton

**Day 3-4: State Management**
- Implement LuaStateManager with basic lifecycle
- Add Zig allocator integration
- Create state pooling system

**Day 5-7: Type Conversion**
- Implement LuaConverter with ScriptValue bridge
- Add table detection and conversion
- Create comprehensive test suite

### Phase 2: Core Engine (Week 2)

**Day 8-10: Security Implementation**
- Implement LuaSecurityManager
- Add bytecode validation
- Create secure environment builder

**Day 11-12: Basic Execution**
- Implement script execution
- Add function calling
- Create error handling

**Day 13-14: Testing Framework**
- Create unit tests
- Add integration tests
- Performance benchmarks

### Phase 3: Advanced Features (Week 3)

**Day 15-17: Coroutine System**
- Implement LuaCoroutineManager
- Add promise-based async/await
- Create async I/O integration

**Day 18-19: API Bridge Integration**
- Implement LuaAPIBridge
- Register all 10 API bridges
- Create Lua wrapper functions

**Day 20-21: Performance Optimization**
- Implement state pooling optimization
- Add type conversion caching
- Create adaptive GC strategy

### Phase 4: Integration & Polish (Week 4)

**Day 22-24: Full Integration**
- Registry integration
- Module system setup
- Warning system integration

**Day 25-26: Debug Tools**
- Implement debug manager
- Add profiler support
- Create development helpers

**Day 27-28: Documentation & Examples**
- Create comprehensive examples
- Write API documentation
- Performance tuning guide

### Success Criteria

1. **Functionality**
   - All ScriptingEngine interface methods implemented
   - All 10 API bridges accessible from Lua
   - Async/await patterns working
   - Debug tools operational

2. **Security**
   - Bytecode validation passing all tests
   - Sandbox escape attempts blocked
   - Resource limits enforced
   - No security vulnerabilities

3. **Performance**
   - <0.1ms basic script execution
   - <50% security overhead
   - >90% state pool hit rate
   - <5% GC overhead for typical workloads

4. **Quality**
   - >95% test coverage
   - All benchmarks passing
   - No memory leaks
   - Clean documentation

## Conclusion

This architecture provides a comprehensive, secure, and performant Lua scripting engine for zig_llms. The design balances flexibility with safety, performance with features, and ease of use with power. The modular architecture allows for incremental implementation while maintaining a clear vision of the complete system.

Key innovations:
- Multi-layer security model prevents all known attack vectors
- Adaptive GC strategy optimizes for different workloads
- Promise-based async model provides familiar programming patterns
- Comprehensive debugging support enables powerful development tools
- Seamless API bridge integration exposes full zig_llms functionality

The implementation plan provides a clear path to production-ready Lua scripting in 4 weeks.