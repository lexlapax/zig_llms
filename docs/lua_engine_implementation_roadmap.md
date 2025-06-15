# Lua Engine Implementation Roadmap

## Executive Summary

This document provides a comprehensive implementation roadmap for the zig_llms Lua scripting engine, consolidating all research and design work into a practical, phased implementation plan. The roadmap incorporates lua_State management, type conversion systems, coroutine integration, security sandboxing, and seamless integration with existing zig_llms infrastructure.

## Table of Contents

1. [Implementation Overview](#implementation-overview)
2. [Phase 1: Foundation (Week 1)](#phase-1-foundation-week-1)
3. [Phase 2: Core Engine (Week 2)](#phase-2-core-engine-week-2)
4. [Phase 3: Advanced Features (Week 3)](#phase-3-advanced-features-week-3)
5. [Phase 4: Integration & Polish (Week 4)](#phase-4-integration--polish-week-4)
6. [File Structure](#file-structure)
7. [Dependencies & Build Integration](#dependencies--build-integration)
8. [Testing Strategy](#testing-strategy)
9. [Performance Targets](#performance-targets)
10. [Milestones & Deliverables](#milestones--deliverables)

---

## Implementation Overview

### Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│                    zig_llms Lua Engine                      │
├─────────────────────────────────────────────────────────────┤
│ ScriptingEngine Interface (existing)                       │
├─────────────────────────────────────────────────────────────┤
│ LuaEngine Implementation                                    │
│ ├── LuaState Management (lua_State lifecycle)              │
│ ├── Type Conversion (ScriptValue ↔ Lua types)              │ 
│ ├── Security Sandbox (multi-layer protection)             │
│ ├── Coroutine Manager (async/await support)                │
│ └── API Bridge Integration (10 existing bridges)           │
├─────────────────────────────────────────────────────────────┤
│ Lua 5.4 C API                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Components to Implement

1. **LuaEngine** - Main engine implementing `ScriptingEngine` interface
2. **LuaStateManager** - `lua_State` lifecycle and pooling
3. **LuaConverter** - ScriptValue ↔ Lua type conversion system
4. **LuaSecurityManager** - Multi-layer security sandboxing
5. **LuaCoroutineManager** - Async/await coroutine support
6. **LuaAPIBridge** - Integration with existing API bridges

### Implementation Priorities

- **P0 (Critical)**: Basic engine functionality, security, type conversion
- **P1 (High)**: Coroutine support, API bridge integration  
- **P2 (Medium)**: Performance optimization, advanced features
- **P3 (Low)**: Enhanced debugging, monitoring features

---

## Phase 1: Foundation (Week 1)

### Day 1-2: Project Setup & Dependencies

#### 1.1 Build System Integration
```zig
// In build.zig - add Lua dependency
pub fn build(b: *std.Build) void {
    // ... existing build setup
    
    // Add Lua 5.4 dependency
    const lua_dep = b.dependency("lua", .{
        .target = target,
        .optimize = optimize,
    });
    
    const lua_lib = lua_dep.artifact("lua");
    exe.linkLibrary(lua_lib);
    exe.addIncludePath(lua_dep.path("src"));
    
    // Add Lua engine module
    const lua_engine_module = b.addModule("lua_engine", .{
        .source_file = .{ .path = "src/lua/engine.zig" },
        .dependencies = &.{
            .{ .name = "scripting", .module = scripting_module },
        },
    });
}
```

#### 1.2 Core File Structure Creation
```bash
# Create directory structure
mkdir -p src/lua/{engine,state,converter,security,coroutine,bindings}
mkdir -p test/lua/{unit,integration,security,performance}
mkdir -p examples/lua/
```

#### 1.3 Dependencies Setup
- **External**: Lua 5.4.6 (latest stable)
- **Internal**: Existing scripting engine interface, value bridge, error bridge

### Day 3-4: Core Engine Structure

#### 1.4 LuaEngine Implementation (P0)
```zig
// src/lua/engine.zig
const std = @import("std");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});
const ScriptingEngine = @import("../scripting/interface.zig").ScriptingEngine;
const ScriptValue = @import("../scripting/value_bridge.zig").ScriptValue;
const ScriptContext = @import("../scripting/context.zig").ScriptContext;

pub const LuaEngine = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    state_manager: *LuaStateManager,
    converter: *LuaConverter,
    security_manager: *LuaSecurityManager,
    coroutine_manager: ?*LuaCoroutineManager,
    
    // ScriptingEngine interface implementation
    engine: ScriptingEngine,
    
    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*LuaEngine {
        const self = try allocator.create(LuaEngine);
        errdefer allocator.destroy(self);
        
        self.allocator = allocator;
        self.state_manager = try LuaStateManager.init(allocator, config);
        self.converter = try LuaConverter.init(allocator);
        self.security_manager = try LuaSecurityManager.init(allocator, config);
        
        if (config.features.async_support) {
            self.coroutine_manager = try LuaCoroutineManager.init(allocator, config);
        }
        
        // Set up vtable
        self.engine = ScriptingEngine{
            .impl = self,
            .metadata = getEngineMetadata(),
            .vtable = &ENGINE_VTABLE,
        };
        
        return self;
    }
    
    pub fn deinit(self: *LuaEngine) void {
        if (self.coroutine_manager) |coro_mgr| {
            coro_mgr.deinit();
            self.allocator.destroy(coro_mgr);
        }
        self.security_manager.deinit();
        self.allocator.destroy(self.security_manager);
        self.converter.deinit();
        self.allocator.destroy(self.converter);
        self.state_manager.deinit();
        self.allocator.destroy(self.state_manager);
        self.allocator.destroy(self);
    }
};

const ENGINE_VTABLE = ScriptingEngine.VTable{
    .execute_script = executeScriptImpl,
    .call_function = callFunctionImpl,
    .get_global = getGlobalImpl,
    .set_global = setGlobalImpl,
    .create_context = createContextImpl,
    .destroy_context = destroyContextImpl,
};
```

#### 1.5 LuaStateManager Implementation (P0)
```zig
// src/lua/state/manager.zig
pub const LuaStateManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    main_state: *c.lua_State,
    state_pool: StatePool,
    config: EngineConfig,
    
    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        
        self.allocator = allocator;
        self.config = config;
        
        // Create main Lua state with custom allocator
        self.main_state = c.lua_newstate(luaAllocator, &self.allocator);
        if (self.main_state == null) {
            return error.LuaStateCreationFailed;
        }
        
        // Open standard libraries (securely)
        c.luaL_openlibs(self.main_state);
        
        // Initialize state pool
        self.state_pool = try StatePool.init(allocator, self.main_state, config.pool_size);
        
        return self;
    }
    
    pub fn acquireState(self: *Self, context: *ScriptContext) !*LuaState {
        const lua_state = try self.state_pool.acquire();
        
        // Set up security context
        try self.setupSecurity(lua_state, context);
        
        return lua_state;
    }
    
    pub fn releaseState(self: *Self, lua_state: *LuaState) void {
        self.state_pool.release(lua_state);
    }
    
    fn luaAllocator(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.C) ?*anyopaque {
        const allocator = @ptrCast(*std.mem.Allocator, @alignCast(@alignOf(*std.mem.Allocator), ud));
        
        if (nsize == 0) {
            if (ptr != null) {
                const slice = @ptrCast([*]u8, ptr)[0..osize];
                allocator.free(slice);
            }
            return null;
        } else if (ptr == null) {
            const slice = allocator.alloc(u8, nsize) catch return null;
            return slice.ptr;
        } else {
            const old_slice = @ptrCast([*]u8, ptr)[0..osize];
            const new_slice = allocator.realloc(old_slice, nsize) catch return null;
            return new_slice.ptr;
        }
    }
};
```

### Day 5-7: Basic Type Conversion

#### 1.6 LuaConverter Implementation (P0)
```zig
// src/lua/converter/converter.zig
pub const LuaConverter = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    type_cache: TypeCache,
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.type_cache = TypeCache.init(allocator);
        return self;
    }
    
    pub fn scriptValueToLua(self: *Self, state: *c.lua_State, value: ScriptValue) !void {
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
            c.LUA_TNUMBER => try self.convertNumber(state, index),
            c.LUA_TSTRING => try self.convertString(state, index),
            c.LUA_TTABLE => try self.convertTable(state, index),
            c.LUA_TFUNCTION => try self.convertFunction(state, index),
            c.LUA_TUSERDATA => try self.convertUserData(state, index),
            c.LUA_TLIGHTUSERDATA => try self.convertLightUserData(state, index),
            c.LUA_TTHREAD => try self.convertThread(state, index),
            else => error.UnsupportedLuaType,
        };
    }
};
```

---

## Phase 2: Core Engine (Week 2)

### Day 8-10: Security Implementation

#### 2.1 LuaSecurityManager Implementation (P0)
```zig
// src/lua/security/manager.zig
pub const LuaSecurityManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    policies: std.HashMap(SecurityLevel, LuaSecurityPolicy),
    contexts: std.HashMap(*c.lua_State, *LuaSecurityContext),
    
    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.policies = std.HashMap(SecurityLevel, LuaSecurityPolicy).init(allocator);
        self.contexts = std.HashMap(*c.lua_State, *LuaSecurityContext).init(allocator);
        
        // Initialize default policies
        try self.setupDefaultPolicies();
        
        return self;
    }
    
    pub fn setupSecurity(self: *Self, state: *c.lua_State, script_context: *ScriptContext) !void {
        const policy = self.policies.get(script_context.sandbox_level) orelse 
            return error.UnknownSecurityLevel;
        
        // Create security context
        const lua_ctx = try self.allocator.create(LuaSecurityContext);
        lua_ctx.* = LuaSecurityContext{
            .policy = policy,
            .script_context = script_context,
            .start_time = std.time.milliTimestamp(),
            .instruction_count = 0,
            .allocated_bytes = 0,
        };
        
        try self.contexts.put(state, lua_ctx);
        
        // Set up security measures
        try self.setupEnvironment(state, lua_ctx);
        try self.setupResourceMonitoring(state, lua_ctx);
        try self.setupFunctionRestrictions(state, lua_ctx);
    }
    
    fn setupEnvironment(self: *Self, state: *c.lua_State, ctx: *LuaSecurityContext) !void {
        if (!ctx.policy.isolated_globals) return;
        
        // Create sandbox environment
        c.lua_newtable(state);
        const env_index = c.lua_gettop(state);
        
        // Add safe functions
        try self.addSafeFunctions(state, env_index, ctx);
        
        // Set metatable for controlled access
        c.lua_newtable(state);
        c.lua_pushstring(state, "__index");
        c.lua_pushcfunction(state, sandboxIndex);
        c.lua_settable(state, -3);
        c.lua_pushstring(state, "__newindex");
        c.lua_pushcfunction(state, sandboxNewIndex);
        c.lua_settable(state, -3);
        c.lua_setmetatable(state, env_index);
        
        // Store as registry entry
        c.lua_setfield(state, c.LUA_REGISTRYINDEX, "SANDBOX_ENV");
    }
};
```

#### 2.2 Security Hook Implementation (P0)
```zig
// src/lua/security/hooks.zig
export fn instructionCountHook(L: ?*c.lua_State, ar: *c.lua_Debug) void {
    const ctx = getSecurityContext(L) orelse return;
    
    ctx.instruction_count += 1;
    
    // Check limits periodically
    if (ctx.instruction_count % 10000 == 0) {
        checkResourceLimits(ctx) catch {
            _ = c.luaL_error(L, "Resource limit exceeded");
        };
    }
}

export fn sandboxIndex(L: ?*c.lua_State) callconv(.C) i32 {
    const key = c.lua_tostring(L, 2);
    const ctx = getSecurityContext(L) orelse return 0;
    
    if (!isFunctionAllowed(ctx, std.mem.span(key))) {
        _ = c.luaL_error(L, "Access to '%s' is not permitted", key);
        return 0;
    }
    
    c.lua_pushnil(L);
    return 1;
}

export fn sandboxNewIndex(L: ?*c.lua_State) callconv(.C) i32 {
    const key = c.lua_tostring(L, 2);
    const ctx = getSecurityContext(L) orelse return 0;
    
    if (!isGlobalModificationAllowed(ctx, std.mem.span(key))) {
        _ = c.luaL_error(L, "Modification of '%s' is not permitted", key);
        return 0;
    }
    
    c.lua_rawset(L, 1);
    return 0;
}
```

### Day 11-12: Basic Script Execution

#### 2.3 Script Execution Implementation (P0)
```zig
// src/lua/engine.zig - execution methods
fn executeScriptImpl(engine: *ScriptingEngine, script: []const u8, context: *ScriptContext) !ScriptValue {
    const self = @fieldParentPtr(LuaEngine, "engine", engine);
    
    // Acquire Lua state
    const lua_state = try self.state_manager.acquireState(context);
    defer self.state_manager.releaseState(lua_state);
    
    // Set up stack guard
    const guard = LuaStackGuard.init(lua_state.state);
    defer guard.deinit();
    
    // Load script
    const result = c.luaL_loadbuffer(lua_state.state, script.ptr, script.len, "script");
    if (result != c.LUA_OK) {
        const error_msg = c.lua_tostring(lua_state.state, -1);
        return ScriptError.fromLuaError(std.mem.span(error_msg));
    }
    
    // Execute script
    const exec_result = c.lua_pcall(lua_state.state, 0, 1, 0);
    if (exec_result != c.LUA_OK) {
        const error_msg = c.lua_tostring(lua_state.state, -1);
        return ScriptError.fromLuaError(std.mem.span(error_msg));
    }
    
    // Convert result
    if (c.lua_gettop(lua_state.state) > 0) {
        return self.converter.luaToScriptValue(lua_state.state, -1, context.allocator);
    } else {
        return ScriptValue.nil;
    }
}

fn callFunctionImpl(engine: *ScriptingEngine, name: []const u8, args: []const ScriptValue, context: *ScriptContext) !ScriptValue {
    const self = @fieldParentPtr(LuaEngine, "engine", engine);
    
    const lua_state = try self.state_manager.acquireState(context);
    defer self.state_manager.releaseState(lua_state);
    
    const guard = LuaStackGuard.init(lua_state.state);
    defer guard.deinit();
    
    // Get function
    c.lua_getglobal(lua_state.state, name.ptr);
    if (!c.lua_isfunction(lua_state.state, -1)) {
        return error.FunctionNotFound;
    }
    
    // Push arguments
    for (args) |arg| {
        try self.converter.scriptValueToLua(lua_state.state, arg);
    }
    
    // Call function
    const result = c.lua_pcall(lua_state.state, @intCast(args.len), 1, 0);
    if (result != c.LUA_OK) {
        const error_msg = c.lua_tostring(lua_state.state, -1);
        return ScriptError.fromLuaError(std.mem.span(error_msg));
    }
    
    // Convert result
    return self.converter.luaToScriptValue(lua_state.state, -1, context.allocator);
}
```

### Day 13-14: Testing Framework

#### 2.4 Basic Test Suite (P0)
```zig
// test/lua/unit/basic_execution_test.zig
const std = @import("std");
const testing = std.testing;
const LuaEngine = @import("../../../src/lua/engine.zig").LuaEngine;
const ScriptValue = @import("../../../src/scripting/value_bridge.zig").ScriptValue;
const ScriptContext = @import("../../../src/scripting/context.zig").ScriptContext;
const EngineConfig = @import("../../../src/scripting/interface.zig").EngineConfig;

test "basic script execution" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create engine
    const config = EngineConfig{
        .allocator = allocator,
        .sandbox_level = .restricted,
        .max_memory_bytes = 1024 * 1024,
        .max_execution_time_ms = 5000,
    };
    
    const engine = try LuaEngine.init(allocator, config);
    defer engine.deinit();
    
    // Create context
    const context = try ScriptContext.init(allocator, .{
        .sandbox_level = .restricted,
        .permissions = .{},
        .limits = .{
            .max_memory_bytes = 1024 * 1024,
            .max_execution_time_ms = 5000,
        },
    });
    defer context.deinit();
    
    // Execute simple script
    const script = "return 42";
    const result = try engine.engine.vtable.execute_script(&engine.engine, script, context);
    defer result.deinit(allocator);
    
    try testing.expect(result == .integer);
    try testing.expect(result.integer == 42);
}

test "function call" {
    // Similar setup...
    
    const script = 
        \\function add(a, b)
        \\    return a + b
        \\end
    ;
    
    _ = try engine.engine.vtable.execute_script(&engine.engine, script, context);
    
    const args = [_]ScriptValue{
        ScriptValue{ .integer = 10 },
        ScriptValue{ .integer = 32 },
    };
    
    const result = try engine.engine.vtable.call_function(&engine.engine, "add", &args, context);
    defer result.deinit(allocator);
    
    try testing.expect(result == .integer);
    try testing.expect(result.integer == 42);
}
```

---

## Phase 3: Advanced Features (Week 3)

### Day 15-17: Coroutine Implementation

#### 3.1 LuaCoroutineManager Implementation (P1)
```zig
// src/lua/coroutine/manager.zig
pub const LuaCoroutineManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    main_state: *c.lua_State,
    coroutine_pool: CoroutinePool,
    scheduler: AsyncScheduler,
    promises: std.HashMap(u64, *LuaPromise),
    next_promise_id: u64,
    
    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.main_state = config.main_state;
        self.coroutine_pool = try CoroutinePool.init(allocator, config.coroutine_pool_size);
        self.scheduler = try AsyncScheduler.init(allocator);
        self.promises = std.HashMap(u64, *LuaPromise).init(allocator);
        self.next_promise_id = 1;
        
        return self;
    }
    
    pub fn createAsync(self: *Self, script: []const u8, context: *ScriptContext) !*LuaPromise {
        // Get coroutine from pool
        const thread = try self.coroutine_pool.acquire();
        errdefer self.coroutine_pool.release(thread);
        
        // Load script into coroutine
        const result = c.luaL_loadbuffer(thread, script.ptr, script.len, "async_script");
        if (result != c.LUA_OK) {
            const error_msg = c.lua_tostring(thread, -1);
            return ScriptError.fromLuaError(std.mem.span(error_msg));
        }
        
        // Create promise
        const promise = try self.allocator.create(LuaPromise);
        promise.* = LuaPromise{
            .id = self.next_promise_id,
            .thread = thread,
            .status = .pending,
            .result = null,
            .error = null,
            .context = context,
            .manager = self,
        };
        
        try self.promises.put(self.next_promise_id, promise);
        self.next_promise_id += 1;
        
        // Schedule for execution
        try self.scheduler.schedule(promise);
        
        return promise;
    }
    
    pub fn pump(self: *Self) !void {
        try self.scheduler.pump(16); // 16ms time slice
    }
};
```

#### 3.2 Async/Await API Implementation (P1)
```zig
// src/lua/coroutine/api.zig
export fn luaAsync(L: ?*c.lua_State) callconv(.C) i32 {
    // Get function argument
    if (!c.lua_isfunction(L, 1)) {
        return c.luaL_error(L, "async() requires a function argument");
    }
    
    // Get coroutine manager
    c.lua_getfield(L, c.LUA_REGISTRYINDEX, "COROUTINE_MANAGER");
    const manager_ptr = c.lua_touserdata(L, -1);
    const manager = @ptrCast(*LuaCoroutineManager, @alignCast(@alignOf(*LuaCoroutineManager), manager_ptr));
    c.lua_pop(L, 1);
    
    // Create new coroutine
    const thread = c.lua_newthread(L);
    c.lua_pushvalue(L, 1); // Copy function
    c.lua_xmove(L, thread, 1); // Move to coroutine
    
    // Create promise
    const promise = manager.createPromiseFromThread(thread) catch {
        return c.luaL_error(L, "Failed to create async promise");
    };
    
    // Push promise as userdata
    const promise_ud = c.lua_newuserdata(L, @sizeOf(*LuaPromise));
    @as(**LuaPromise, @ptrCast(@alignCast(promise_ud))).* = promise;
    
    // Set metatable
    c.luaL_getmetatable(L, "LuaPromise");
    c.lua_setmetatable(L, -2);
    
    return 1;
}

export fn luaAwait(L: ?*c.lua_State) callconv(.C) i32 {
    // Get promise argument
    const promise_ud = c.luaL_checkudata(L, 1, "LuaPromise");
    const promise = @as(**LuaPromise, @ptrCast(@alignCast(promise_ud))).*;
    
    // Set up continuation context
    const await_ctx = c.lua_newuserdata(L, @sizeOf(AwaitContext));
    const ctx = @ptrCast(*AwaitContext, @alignCast(@alignOf(AwaitContext), await_ctx));
    ctx.* = AwaitContext{
        .promise = promise,
        .waiting_thread = L,
    };
    
    return c.lua_yieldk(L, 0, @ptrCast(c.lua_KContext, ctx), awaitContinuation);
}

export fn awaitContinuation(L: ?*c.lua_State, status: c_int, ctx_ptr: c.lua_KContext) callconv(.C) i32 {
    const ctx = @ptrCast(*AwaitContext, ctx_ptr);
    
    switch (ctx.promise.status) {
        .resolved => {
            // Push resolved value
            // Convert ScriptValue to Lua and push
            return 1;
        },
        .rejected => {
            const error_msg = ctx.promise.error.?.message;
            c.lua_pushstring(L, error_msg.ptr);
            return c.lua_error(L);
        },
        .pending => {
            // Still waiting, yield again
            return c.lua_yieldk(L, 0, ctx_ptr, awaitContinuation);
        },
        .cancelled => {
            return c.luaL_error(L, "Promise was cancelled");
        },
    }
}
```

### Day 18-19: API Bridge Integration

#### 3.3 API Bridge Integration (P1)
```zig
// src/lua/bindings/api_bridges.zig
pub const LuaAPIBridge = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    agent_bridge: *AgentBridge,
    tool_bridge: *ToolBridge,
    workflow_bridge: *WorkflowBridge,
    // ... other bridges
    
    pub fn init(allocator: std.mem.Allocator, bridges: APIBridges) !*Self {
        const self = try allocator.create(Self);
        self.allocator = allocator;
        self.agent_bridge = bridges.agent_bridge;
        self.tool_bridge = bridges.tool_bridge;
        self.workflow_bridge = bridges.workflow_bridge;
        // ... initialize other bridges
        
        return self;
    }
    
    pub fn setupLuaAPIs(self: *Self, state: *c.lua_State) !void {
        // Register agent API
        try self.registerAgentAPI(state);
        try self.registerToolAPI(state);
        try self.registerWorkflowAPI(state);
        // ... register other APIs
    }
    
    fn registerAgentAPI(self: *Self, L: *c.lua_State) !void {
        // Create zigllms.agent module
        c.lua_newtable(L);
        const agent_table = c.lua_gettop(L);
        
        // Add agent functions
        c.lua_pushstring(L, "create");
        c.lua_pushcfunction(L, luaAgentCreate);
        c.lua_settable(L, agent_table);
        
        c.lua_pushstring(L, "run");
        c.lua_pushcfunction(L, luaAgentRun);
        c.lua_settable(L, agent_table);
        
        c.lua_pushstring(L, "get_info");
        c.lua_pushcfunction(L, luaAgentGetInfo);
        c.lua_settable(L, agent_table);
        
        // Set as global
        c.lua_setglobal(L, "zigllms");
        c.lua_getglobal(L, "zigllms");
        c.lua_pushvalue(L, agent_table);
        c.lua_setfield(L, -2, "agent");
        c.lua_pop(L, 1);
    }
};

// Agent API implementations
export fn luaAgentCreate(L: ?*c.lua_State) callconv(.C) i32 {
    // Get config table from Lua
    if (!c.lua_istable(L, 1)) {
        return c.luaL_error(L, "agent.create() requires a config table");
    }
    
    // Convert Lua table to AgentConfig
    const config_value = luaTableToScriptValue(L, 1) catch {
        return c.luaL_error(L, "Failed to convert config table");
    };
    defer config_value.deinit(getAllocator(L));
    
    const config = config_value.toZig(AgentConfig, getAllocator(L)) catch {
        return c.luaL_error(L, "Invalid agent configuration");
    };
    
    // Get agent bridge
    const bridge = getAgentBridge(L);
    
    // Create agent
    const agent = bridge.createAgent(config) catch {
        return c.luaL_error(L, "Failed to create agent");
    };
    
    // Convert agent to Lua userdata
    const agent_value = ScriptValue.fromZig(*Agent, agent, getAllocator(L)) catch {
        return c.luaL_error(L, "Failed to convert agent");
    };
    
    scriptValueToLua(L, agent_value) catch {
        return c.luaL_error(L, "Failed to push agent to Lua");
    };
    
    return 1;
}
```

### Day 20-21: Performance Optimization

#### 3.4 Performance Optimizations (P2)
```zig
// src/lua/state/pool.zig - Optimized state pooling
pub const StatePool = struct {
    const Self = @This();
    
    available_states: std.ArrayList(*LuaState),
    active_states: std.HashMap(*LuaState, StateInfo),
    allocator: std.mem.Allocator,
    main_state: *c.lua_State,
    pool_size: usize,
    
    // Performance metrics
    pool_hits: u64 = 0,
    pool_misses: u64 = 0,
    reset_times: std.ArrayList(u64),
    
    pub fn acquire(self: *Self) !*LuaState {
        const start_time = std.time.nanoTimestamp();
        
        if (self.available_states.items.len > 0) {
            const state = self.available_states.pop();
            try self.resetState(state);
            self.pool_hits += 1;
            
            const reset_time = std.time.nanoTimestamp() - start_time;
            try self.reset_times.append(reset_time);
            
            return state;
        }
        
        // Create new state
        if (self.active_states.count() < self.pool_size) {
            const state = try self.createNewState();
            self.pool_misses += 1;
            return state;
        }
        
        return error.PoolExhausted;
    }
    
    fn resetState(self: *Self, state: *LuaState) !void {
        // Fast reset - clear stack without full re-initialization
        c.lua_settop(state.state, 0);
        
        // Clear registry entries
        c.lua_pushnil(state.state);
        c.lua_setfield(state.state, c.LUA_REGISTRYINDEX, "SECURITY_CONTEXT");
        
        // Reset debug hooks
        c.lua_sethook(state.state, null, 0, 0);
        
        // Verify state is reusable
        const status = c.lua_status(state.state);
        if (status != c.LUA_OK) {
            return error.StateNotReusable;
        }
    }
    
    pub fn getStats(self: *Self) PoolStats {
        const avg_reset_time = if (self.reset_times.items.len > 0) 
            self.calculateAverage(self.reset_times.items) else 0;
            
        return PoolStats{
            .pool_hits = self.pool_hits,
            .pool_misses = self.pool_misses,
            .hit_ratio = @as(f64, @floatFromInt(self.pool_hits)) / 
                        @as(f64, @floatFromInt(self.pool_hits + self.pool_misses)),
            .avg_reset_time_ns = avg_reset_time,
            .available_states = self.available_states.items.len,
            .active_states = self.active_states.count(),
        };
    }
};
```

---

## Phase 4: Integration & Polish (Week 4)

### Day 22-24: Full Integration

#### 4.1 Registry Integration (P1)
```zig
// src/lua/integration.zig - Engine registration
pub fn registerLuaEngine() !void {
    const registry = ScriptingEngineRegistry.getInstance();
    
    const factory = EngineFactory{
        .name = "lua",
        .version = "5.4.6",
        .extensions = &[_][]const u8{ ".lua", ".luac" },
        .features = EngineFeatures{
            .async_support = true,
            .coroutines = true,
            .hot_reload = false,
            .debugging = true,
            .profiling = true,
            .sandboxing = true,
        },
        .create_fn = createLuaEngine,
        .metadata = getLuaEngineMetadata(),
    };
    
    try registry.register(factory);
}

fn createLuaEngine(allocator: std.mem.Allocator, config: EngineConfig) !*ScriptingEngine {
    const lua_engine = try LuaEngine.init(allocator, config);
    return &lua_engine.engine;
}
```

#### 4.2 Module System Integration (P1)
```zig
// src/lua/modules/module_loader.zig
pub const LuaModuleLoader = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    module_system: *ModuleSystem,
    api_bridges: *LuaAPIBridge,
    
    pub fn setupModuleSystem(self: *Self, L: *c.lua_State) !void {
        // Replace package.searchers with secure version
        c.lua_getglobal(L, "package");
        if (c.lua_istable(L, -1)) {
            // Create secure searchers
            c.lua_newtable(L);
            c.lua_pushcfunction(L, secureModuleSearcher);
            c.lua_rawseti(L, -2, 1);
            c.lua_setfield(L, -2, "searchers");
        }
        c.lua_pop(L, 1);
        
        // Register zig_llms modules
        try self.registerZigLLMSModules(L);
    }
    
    fn registerZigLLMSModules(self: *Self, L: *c.lua_State) !void {
        const modules = [_]struct { name: []const u8, loader: c.lua_CFunction }{
            .{ .name = "zigllms.agent", .loader = loadAgentModule },
            .{ .name = "zigllms.tool", .loader = loadToolModule },
            .{ .name = "zigllms.workflow", .loader = loadWorkflowModule },
            .{ .name = "zigllms.event", .loader = loadEventModule },
            .{ .name = "zigllms.schema", .loader = loadSchemaModule },
            .{ .name = "zigllms.memory", .loader = loadMemoryModule },
            .{ .name = "zigllms.hook", .loader = loadHookModule },
            .{ .name = "zigllms.output", .loader = loadOutputModule },
        };
        
        c.lua_getfield(L, c.LUA_REGISTRYINDEX, "_LOADED");
        for (modules) |module| {
            c.lua_pushcfunction(L, module.loader);
            c.lua_pushstring(L, module.name.ptr);
            c.lua_call(L, 1, 1);
            c.lua_setfield(L, -2, module.name.ptr);
        }
        c.lua_pop(L, 1);
    }
};
```

### Day 25-26: Testing & Benchmarking

#### 4.3 Comprehensive Test Suite (P1)
```zig
// test/lua/integration/full_integration_test.zig
test "full Lua engine integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Register Lua engine
    try registerLuaEngine();
    
    // Get engine through registry
    const registry = ScriptingEngineRegistry.getInstance();
    const engine = try registry.createEngine("lua", allocator, .{
        .sandbox_level = .restricted,
        .features = .{
            .async_support = true,
            .debugging = true,
            .sandboxing = true,
        },
    });
    defer registry.destroyEngine(engine);
    
    // Create context with full API access
    const context = try ScriptContext.init(allocator, .{
        .sandbox_level = .restricted,
        .permissions = .{
            .basic_functions = true,
            .agent_operations = true,
            .tool_operations = true,
            .workflow_operations = true,
        },
    });
    defer context.deinit();
    
    // Test complex script with async operations
    const script = 
        \\local zigllms = require("zigllms.agent")
        \\
        \\local agent_config = {
        \\    name = "test_agent",
        \\    provider = "openai",
        \\    model = "gpt-4",
        \\    temperature = 0.7
        \\}
        \\
        \\local agent = zigllms.create(agent_config)
        \\
        \\-- Test async execution
        \\local result = await(async(function()
        \\    local response = zigllms.run(agent, "Hello, world!")
        \\    return response.content
        \\end))
        \\
        \\return {
        \\    agent_id = zigllms.get_info(agent).id,
        \\    response = result
        \\}
    ;
    
    const result = try engine.vtable.execute_script(engine, script, context);
    defer result.deinit(allocator);
    
    try testing.expect(result == .object);
    try testing.expect(result.object.get("agent_id") != null);
    try testing.expect(result.object.get("response") != null);
}
```

#### 4.4 Performance Benchmarks (P2)
```zig
// test/lua/performance/benchmark_suite.zig
const BenchmarkSuite = struct {
    pub fn runAllBenchmarks() !void {
        try benchmarkBasicExecution();
        try benchmarkTypeConversion();
        try benchmarkSecurityOverhead();
        try benchmarkCoroutinePerformance();
        try benchmarkMemoryUsage();
    }
    
    fn benchmarkBasicExecution() !void {
        const iterations = 10000;
        const script = "return math.sqrt(42)";
        
        const start = std.time.nanoTimestamp();
        for (0..iterations) |_| {
            _ = try executeScript(script);
        }
        const end = std.time.nanoTimestamp();
        
        const avg_time_ns = (end - start) / iterations;
        std.debug.print("Basic execution: {d}ns per script\n", .{avg_time_ns});
        
        // Target: <100,000ns (0.1ms) per script
        try testing.expect(avg_time_ns < 100_000);
    }
    
    fn benchmarkSecurityOverhead() !void {
        const script = "local sum = 0; for i=1,1000 do sum = sum + i end; return sum";
        
        // Benchmark without security
        const unsecure_time = try benchmarkScript(script, .none);
        
        // Benchmark with security
        const secure_time = try benchmarkScript(script, .restricted);
        
        const overhead_percent = (@as(f64, @floatFromInt(secure_time - unsecure_time)) / 
                                 @as(f64, @floatFromInt(unsecure_time))) * 100.0;
        
        std.debug.print("Security overhead: {d:.2}%\n", .{overhead_percent});
        
        // Target: <50% overhead
        try testing.expect(overhead_percent < 50.0);
    }
};
```

### Day 27-28: Documentation & Examples

#### 4.5 Example Scripts (P2)
```lua
-- examples/lua/basic_agent.lua
local zigllms = require("zigllms.agent")

-- Create an agent
local agent = zigllms.create({
    name = "helper_agent",
    provider = "openai",
    model = "gpt-4",
    temperature = 0.7
})

-- Run the agent
local response = zigllms.run(agent, "Explain quantum computing")
print("Agent response:", response.content)

-- Get agent information
local info = zigllms.get_info(agent)
print("Agent ID:", info.id)
print("Total tokens used:", info.usage.total_tokens)
```

```lua
-- examples/lua/async_workflow.lua
local agent = require("zigllms.agent")
local workflow = require("zigllms.workflow")

-- Create multiple agents for different tasks
local research_agent = agent.create({
    name = "researcher",
    model = "gpt-4",
    system_prompt = "You are a research assistant."
})

local writer_agent = agent.create({
    name = "writer", 
    model = "gpt-4",
    system_prompt = "You are a technical writer."
})

-- Define async workflow
async(function()
    -- Research phase
    local research_result = await(async(function()
        return agent.run(research_agent, "Research the latest developments in AI")
    end))
    
    -- Writing phase
    local article = await(async(function()
        return agent.run(writer_agent, "Write an article based on: " .. research_result.content)
    end))
    
    print("Final article:", article.content)
end)
```

---

## File Structure

```
src/lua/
├── engine.zig                 # Main LuaEngine implementation
├── state/
│   ├── manager.zig            # LuaStateManager
│   ├── pool.zig               # State pooling
│   └── lifecycle.zig          # State lifecycle management
├── converter/
│   ├── converter.zig          # LuaConverter main implementation
│   ├── types.zig              # Type conversion utilities
│   └── cache.zig              # Type conversion caching
├── security/
│   ├── manager.zig            # LuaSecurityManager
│   ├── policies.zig           # Security policies
│   ├── hooks.zig              # Security hooks
│   └── sandbox.zig            # Sandbox implementation
├── coroutine/
│   ├── manager.zig            # LuaCoroutineManager
│   ├── promise.zig            # Promise implementation
│   ├── scheduler.zig          # Async scheduler
│   └── api.zig                # Lua async/await API
├── bindings/
│   ├── api_bridges.zig        # API bridge integration
│   ├── agent_api.zig          # Agent API bindings
│   ├── tool_api.zig           # Tool API bindings
│   ├── workflow_api.zig       # Workflow API bindings
│   ├── event_api.zig          # Event API bindings
│   ├── schema_api.zig         # Schema API bindings
│   ├── memory_api.zig         # Memory API bindings
│   ├── hook_api.zig           # Hook API bindings
│   └── output_api.zig         # Output API bindings
├── modules/
│   ├── module_loader.zig      # Module system integration
│   └── require.zig            # Secure require implementation
├── utils/
│   ├── stack_guard.zig        # Stack management utilities
│   ├── error_handling.zig     # Error conversion utilities
│   └── performance.zig        # Performance monitoring
└── integration.zig            # Engine registration and setup

test/lua/
├── unit/
│   ├── basic_execution_test.zig
│   ├── type_conversion_test.zig
│   ├── security_test.zig
│   └── coroutine_test.zig
├── integration/
│   ├── full_integration_test.zig
│   ├── api_bridge_test.zig
│   └── module_system_test.zig
├── security/
│   ├── vulnerability_test.zig
│   ├── sandbox_escape_test.zig
│   └── resource_limit_test.zig
└── performance/
    ├── benchmark_suite.zig
    ├── memory_benchmark.zig
    └── security_overhead_test.zig

examples/lua/
├── basic_agent.lua
├── async_workflow.lua
├── tool_usage.lua
├── event_handling.lua
├── schema_validation.lua
└── memory_management.lua

docs/
├── lua_state_analysis.md
├── lua_type_conversion_design.md
├── lua_coroutine_integration_plan.md
├── lua_security_design.md
└── lua_engine_implementation_roadmap.md
```

---

## Dependencies & Build Integration

### External Dependencies
- **Lua 5.4.6** - Latest stable Lua interpreter
- **System libraries** - libc for standard C library functions

### Build.zig Integration
```zig
// Add to build.zig
pub fn build(b: *std.Build) void {
    // ... existing setup
    
    // Add Lua dependency
    const lua_dep = b.dependency("lua", .{
        .target = target,
        .optimize = optimize,
    });
    
    // Link Lua library
    const lua_lib = lua_dep.artifact("lua");
    exe.linkLibrary(lua_lib);
    exe.addIncludePath(lua_dep.path("src"));
    
    // Add Lua engine module
    const lua_engine_module = b.addModule("lua_engine", .{
        .source_file = .{ .path = "src/lua/engine.zig" },
        .dependencies = &.{
            .{ .name = "scripting", .module = scripting_module },
        },
    });
    
    // Add Lua tests
    const lua_tests = b.addTest(.{
        .root_source_file = .{ .path = "test/lua/test_suite.zig" },
        .target = target,
        .optimize = optimize,
    });
    lua_tests.linkLibrary(lua_lib);
    lua_tests.addIncludePath(lua_dep.path("src"));
    
    const lua_test_step = b.step("test-lua", "Run Lua engine tests");
    lua_test_step.dependOn(&lua_tests.step);
}
```

### Makefile Integration
```makefile
# Add Lua-specific targets
.PHONY: lua-test lua-bench lua-security-test

lua-test:
	zig build test-lua

lua-bench:
	zig build bench-lua

lua-security-test:
	zig build test-lua-security

test: lua-test
bench: lua-bench
```

---

## Testing Strategy

### Test Categories

#### 1. Unit Tests (P0)
- **Basic Execution**: Script loading, execution, result handling
- **Type Conversion**: ScriptValue ↔ Lua type conversion in both directions
- **Security**: Sandbox functionality, resource limits, function restrictions
- **Coroutines**: Async/await operations, promise handling, scheduler

#### 2. Integration Tests (P1)
- **Full Integration**: Complete engine functionality with all components
- **API Bridges**: All 10 API bridges working with Lua scripts
- **Module System**: Secure module loading and API exposure
- **Error Handling**: Error propagation and recovery

#### 3. Security Tests (P0)
- **Vulnerability Tests**: Known Lua security vulnerabilities
- **Sandbox Escape**: Attempts to break out of security restrictions
- **Resource Limits**: Memory, CPU, and instruction counting limits
- **Bytecode Security**: Malicious bytecode injection attempts

#### 4. Performance Tests (P2)
- **Execution Benchmarks**: Script execution performance
- **Memory Benchmarks**: Memory usage and garbage collection
- **Security Overhead**: Performance impact of security measures
- **Scalability**: Performance under load

### Test Execution Strategy

```bash
# Development testing
make lua-test          # Fast unit tests
make lua-security-test # Security vulnerability tests
make lua-bench         # Performance benchmarks

# CI/CD testing
make test-all         # All tests including Lua
make bench-all        # All benchmarks including Lua
make security-audit   # Full security test suite
```

---

## Performance Targets

### Execution Performance
- **Basic script execution**: <0.1ms per simple script
- **Function calls**: <0.05ms per function call  
- **Type conversion**: <0.01ms per ScriptValue conversion
- **State acquisition**: <0.001ms from pool

### Security Overhead
- **Instruction counting**: <10% overhead
- **Memory tracking**: <5% overhead
- **Function restrictions**: <15% overhead
- **Overall security**: <50% total overhead

### Memory Usage
- **Base engine**: <1MB memory footprint
- **Per script context**: <100KB
- **State pool**: 100 states in <10MB
- **Type conversion cache**: <1MB cache size

### Scalability
- **Concurrent scripts**: 1000+ scripts simultaneously
- **State pool efficiency**: >90% pool hit ratio
- **Garbage collection**: <10ms pause times
- **Memory growth**: <1MB/hour under load

---

## Milestones & Deliverables

### Week 1 Milestones
- ✅ **M1.1**: Project setup and build integration complete
- ✅ **M1.2**: LuaEngine basic structure implemented
- ✅ **M1.3**: LuaStateManager with pooling functional
- ✅ **M1.4**: Basic type conversion working
- ✅ **M1.5**: Simple script execution passing tests

### Week 2 Milestones
- ✅ **M2.1**: Security sandbox fully implemented
- ✅ **M2.2**: Resource monitoring and limits working
- ✅ **M2.3**: Function restrictions in place
- ✅ **M2.4**: Basic test suite passing
- ✅ **M2.5**: Security vulnerability tests all passing

### Week 3 Milestones
- ✅ **M3.1**: Coroutine manager implemented
- ✅ **M3.2**: Async/await API working in Lua
- ✅ **M3.3**: API bridges integrated (agent, tool, workflow)
- ✅ **M3.4**: Remaining API bridges integrated (event, schema, memory, hook, output)
- ✅ **M3.5**: Performance optimizations implemented

### Week 4 Milestones
- ✅ **M4.1**: Engine registration complete
- ✅ **M4.2**: Module system integration working
- ✅ **M4.3**: Full integration tests passing
- ✅ **M4.4**: Performance benchmarks meeting targets
- ✅ **M4.5**: Documentation and examples complete

### Final Deliverables
1. **Fully functional Lua scripting engine** integrated with zig_llms
2. **Comprehensive security sandbox** protecting against all known vulnerabilities
3. **Async/await support** with coroutine-based concurrency
4. **Complete API bridge integration** for all 10 existing bridges
5. **Performance-optimized implementation** meeting all targets
6. **Comprehensive test suite** with >90% code coverage
7. **Security test suite** validating protection against attack vectors
8. **Performance benchmark suite** for ongoing monitoring
9. **Complete documentation** including API reference and examples
10. **Example scripts** demonstrating all major features

### Success Criteria
- All unit tests passing (>95% success rate)
- All security tests passing (100% success rate) 
- Performance targets met (all benchmarks passing)
- Integration tests with existing zig_llms systems passing
- Zero critical security vulnerabilities
- Memory leaks <1MB over 24 hours
- Documentation complete and reviewed
- Example scripts working and tested

This comprehensive roadmap provides a clear path from initial setup to full production deployment of the Lua scripting engine within zig_llms, ensuring security, performance, and seamless integration with existing systems.