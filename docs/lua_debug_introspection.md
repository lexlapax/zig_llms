# Lua Debug Introspection Capabilities for Development Tools

## Executive Summary

This document explores Lua's powerful debug library and introspection capabilities for building development tools in the zig_llms Lua scripting engine. The research covers debugging hooks, stack inspection, variable access, profiling, and integration strategies for creating comprehensive development experiences.

## Table of Contents

1. [Lua Debug Library Overview](#lua-debug-library-overview)
2. [Debug Hooks System](#debug-hooks-system)
3. [Stack Introspection](#stack-introspection)
4. [Variable Access and Manipulation](#variable-access-and-manipulation)
5. [Source Code Mapping](#source-code-mapping)
6. [Profiling and Performance Analysis](#profiling-and-performance-analysis)
7. [Breakpoint Implementation](#breakpoint-implementation)
8. [REPL and Interactive Debugging](#repl-and-interactive-debugging)
9. [Development Tool Integration](#development-tool-integration)
10. [Security Considerations](#security-considerations)
11. [Best Practices and Guidelines](#best-practices-and-guidelines)

---

## Lua Debug Library Overview

### Core Debug Functions

The Lua debug library provides low-level access to the interpreter's internal state:

```lua
-- Main debug functions
debug.debug()          -- Enter interactive debug mode
debug.getinfo()        -- Get function/activation record info
debug.getlocal()       -- Get local variable value
debug.setlocal()       -- Set local variable value
debug.getupvalue()     -- Get upvalue (closed variable)
debug.setupvalue()     -- Set upvalue
debug.sethook()        -- Set debug hook
debug.gethook()        -- Get current hook settings
debug.traceback()      -- Generate stack traceback
debug.getregistry()    -- Access Lua registry
debug.getmetatable()   -- Get metatable (bypasses __metatable)
debug.setmetatable()   -- Set metatable (bypasses protection)
```

### C API Debug Functions

```c
// Core C API debug functions
lua_Debug              // Debug information structure
lua_getstack()         // Get activation record
lua_getinfo()          // Get detailed function info
lua_getlocal()         // Access local variables
lua_setlocal()         // Modify local variables
lua_getupvalue()       // Access upvalues
lua_setupvalue()       // Modify upvalues
lua_sethook()          // Install debug hook
lua_gethook()          // Query hook settings
lua_gethookmask()      // Get hook event mask
lua_gethookcount()     // Get hook count
```

---

## Debug Hooks System

### Hook Types and Events

```c
// Hook event masks
#define LUA_MASKCALL    (1 << LUA_HOOKCALL)     // Function calls
#define LUA_MASKRET     (1 << LUA_HOOKRET)      // Function returns
#define LUA_MASKLINE    (1 << LUA_HOOKLINE)     // Line execution
#define LUA_MASKCOUNT   (1 << LUA_HOOKCOUNT)    // Instruction count

// Hook function signature
typedef void (*lua_Hook)(lua_State *L, lua_Debug *ar);
```

### Comprehensive Hook Implementation

```zig
pub const DebugHookManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    hooks: std.ArrayList(*DebugHook),
    active_mask: c_int = 0,
    instruction_count: u64 = 0,
    breakpoints: BreakpointManager,
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .hooks = std.ArrayList(*DebugHook).init(allocator),
            .breakpoints = try BreakpointManager.init(allocator),
        };
        return self;
    }
    
    pub fn installHook(self: *Self, L: *c.lua_State, events: HookEvents) !void {
        var mask: c_int = 0;
        
        if (events.on_call) mask |= c.LUA_MASKCALL;
        if (events.on_return) mask |= c.LUA_MASKRET;
        if (events.on_line) mask |= c.LUA_MASKLINE;
        
        if (events.instruction_count) |count| {
            mask |= c.LUA_MASKCOUNT;
            c.lua_sethook(L, debugHookCallback, mask, count);
        } else {
            c.lua_sethook(L, debugHookCallback, mask, 0);
        }
        
        self.active_mask = mask;
    }
    
    fn debugHookCallback(L: ?*c.lua_State, ar: ?*c.lua_Debug) callconv(.C) void {
        const manager = getHookManager(L) orelse return;
        
        const event = switch (ar.?.event) {
            c.LUA_HOOKCALL => HookEvent.call,
            c.LUA_HOOKRET => HookEvent.@"return",
            c.LUA_HOOKLINE => HookEvent.line,
            c.LUA_HOOKCOUNT => HookEvent.count,
            else => return,
        };
        
        manager.handleHookEvent(L.?, ar.?, event) catch |err| {
            std.log.err("Debug hook error: {}", .{err});
        };
    }
    
    fn handleHookEvent(self: *Self, L: *c.lua_State, ar: *c.lua_Debug, event: HookEvent) !void {
        // Fill debug info
        _ = c.lua_getinfo(L, "nSluf", ar);
        
        const info = DebugInfo{
            .event = event,
            .name = if (ar.name) |n| std.mem.span(n) else null,
            .source = if (ar.source) |s| std.mem.span(s) else null,
            .current_line = ar.currentline,
            .line_defined = ar.linedefined,
            .last_line_defined = ar.lastlinedefined,
            .what = std.mem.span(ar.what),
            .n_upvalues = ar.nups,
            .n_params = ar.nparams,
            .is_vararg = ar.isvararg != 0,
            .is_tail_call = ar.istailcall != 0,
        };
        
        // Check breakpoints
        if (event == .line) {
            if (try self.breakpoints.shouldBreak(info)) {
                try self.handleBreakpoint(L, info);
            }
        }
        
        // Execute registered hooks
        for (self.hooks.items) |hook| {
            try hook.execute(L, info);
        }
    }
};

pub const DebugInfo = struct {
    event: HookEvent,
    name: ?[]const u8,
    source: ?[]const u8,
    current_line: i32,
    line_defined: i32,
    last_line_defined: i32,
    what: []const u8,  // "Lua", "C", "main", "tail"
    n_upvalues: u8,
    n_params: u8,
    is_vararg: bool,
    is_tail_call: bool,
};
```

### Advanced Hook Features

```zig
pub const ProfilerHook = struct {
    const Self = @This();
    
    hook: DebugHook,
    call_stack: std.ArrayList(CallInfo),
    function_stats: std.StringHashMap(FunctionStats),
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .hook = DebugHook{
                .vtable = &.{
                    .execute = executeImpl,
                },
            },
            .call_stack = std.ArrayList(CallInfo).init(allocator),
            .function_stats = std.StringHashMap(FunctionStats).init(allocator),
        };
        return self;
    }
    
    fn executeImpl(ctx: *anyopaque, L: *c.lua_State, info: DebugInfo) !void {
        const self = @fieldParentPtr(Self, "hook", @ptrCast(*DebugHook, ctx));
        
        switch (info.event) {
            .call => {
                const call_info = CallInfo{
                    .function_name = try self.getFunctionName(info),
                    .start_time = std.time.nanoTimestamp(),
                    .start_memory = c.lua_gc(L, c.LUA_GCCOUNT, 0) * 1024,
                };
                try self.call_stack.append(call_info);
            },
            .@"return" => {
                if (self.call_stack.popOrNull()) |call_info| {
                    const duration = std.time.nanoTimestamp() - call_info.start_time;
                    const memory_delta = c.lua_gc(L, c.LUA_GCCOUNT, 0) * 1024 - call_info.start_memory;
                    
                    const stats = try self.function_stats.getOrPut(call_info.function_name);
                    if (!stats.found_existing) {
                        stats.value_ptr.* = FunctionStats{};
                    }
                    
                    stats.value_ptr.call_count += 1;
                    stats.value_ptr.total_time += duration;
                    stats.value_ptr.total_memory += memory_delta;
                    stats.value_ptr.max_time = @max(stats.value_ptr.max_time, duration);
                }
            },
            else => {},
        }
    }
};
```

---

## Stack Introspection

### Stack Frame Analysis

```zig
pub const StackInspector = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    
    pub fn captureStackTrace(self: *Self, L: *c.lua_State) ![]StackFrame {
        var frames = std.ArrayList(StackFrame).init(self.allocator);
        defer frames.deinit();
        
        var level: c_int = 0;
        var ar: c.lua_Debug = undefined;
        
        while (c.lua_getstack(L, level, &ar) != 0) : (level += 1) {
            // Get detailed info about this stack level
            _ = c.lua_getinfo(L, "nSluf", &ar);
            
            const frame = StackFrame{
                .level = level,
                .function_name = if (ar.name) |n| try self.allocator.dupe(u8, std.mem.span(n)) else null,
                .source = if (ar.source) |s| try self.allocator.dupe(u8, std.mem.span(s)) else null,
                .line = ar.currentline,
                .type = try self.getFunctionType(ar.what),
                .locals = try self.captureLocals(L, level),
                .upvalues = try self.captureUpvalues(L, level),
            };
            
            try frames.append(frame);
        }
        
        return frames.toOwnedSlice();
    }
    
    fn captureLocals(self: *Self, L: *c.lua_State, level: c_int) ![]Variable {
        var locals = std.ArrayList(Variable).init(self.allocator);
        defer locals.deinit();
        
        var ar: c.lua_Debug = undefined;
        if (c.lua_getstack(L, level, &ar) == 0) return &[_]Variable{};
        
        var index: c_int = 1;
        while (true) : (index += 1) {
            const name = c.lua_getlocal(L, &ar, index);
            if (name == null) break;
            
            const variable = Variable{
                .name = try self.allocator.dupe(u8, std.mem.span(name)),
                .value = try self.captureValue(L, -1),
                .type = self.getLuaType(L, -1),
                .index = index,
            };
            
            try locals.append(variable);
            c.lua_pop(L, 1); // Pop the value
        }
        
        return locals.toOwnedSlice();
    }
    
    fn captureUpvalues(self: *Self, L: *c.lua_State, level: c_int) ![]Variable {
        var upvalues = std.ArrayList(Variable).init(self.allocator);
        defer upvalues.deinit();
        
        var ar: c.lua_Debug = undefined;
        if (c.lua_getstack(L, level, &ar) == 0) return &[_]Variable{};
        
        // Get function on stack
        _ = c.lua_getinfo(L, "f", &ar);
        
        var index: c_int = 1;
        while (true) : (index += 1) {
            const name = c.lua_getupvalue(L, -1, index);
            if (name == null) break;
            
            const variable = Variable{
                .name = try self.allocator.dupe(u8, std.mem.span(name)),
                .value = try self.captureValue(L, -1),
                .type = self.getLuaType(L, -1),
                .index = index,
            };
            
            try upvalues.append(variable);
            c.lua_pop(L, 1); // Pop the value
        }
        
        c.lua_pop(L, 1); // Pop the function
        return upvalues.toOwnedSlice();
    }
    
    fn captureValue(self: *Self, L: *c.lua_State, index: c_int) !Value {
        const lua_type = c.lua_type(L, index);
        
        return switch (lua_type) {
            c.LUA_TNIL => Value{ .nil = {} },
            c.LUA_TBOOLEAN => Value{ .boolean = c.lua_toboolean(L, index) != 0 },
            c.LUA_TNUMBER => Value{ .number = c.lua_tonumber(L, index) },
            c.LUA_TSTRING => blk: {
                var len: usize = 0;
                const str = c.lua_tolstring(L, index, &len);
                break :blk Value{ .string = try self.allocator.dupe(u8, str[0..len]) };
            },
            c.LUA_TTABLE => Value{ .table = try self.captureTableInfo(L, index) },
            c.LUA_TFUNCTION => Value{ .function = try self.captureFunctionInfo(L, index) },
            c.LUA_TUSERDATA => Value{ .userdata = .{ .type_name = "userdata" } },
            c.LUA_TTHREAD => Value{ .thread = .{ .status = c.lua_status(L) } },
            else => Value{ .unknown = .{ .type_id = lua_type } },
        };
    }
};

pub const StackFrame = struct {
    level: i32,
    function_name: ?[]const u8,
    source: ?[]const u8,
    line: i32,
    type: FunctionType,
    locals: []Variable,
    upvalues: []Variable,
};

pub const Variable = struct {
    name: []const u8,
    value: Value,
    type: []const u8,
    index: i32,
};
```

---

## Variable Access and Manipulation

### Variable Inspector

```zig
pub const VariableInspector = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    max_depth: u32 = 5,
    max_table_entries: u32 = 100,
    
    pub fn inspectVariable(self: *Self, L: *c.lua_State, path: []const u8) !VariableInfo {
        // Parse variable path (e.g., "myTable.field[5].value")
        const segments = try self.parseVariablePath(path);
        defer self.allocator.free(segments);
        
        // Start with global environment
        c.lua_pushglobaltable(L);
        defer c.lua_pop(L, 1);
        
        // Navigate to target variable
        for (segments) |segment| {
            switch (segment) {
                .field => |name| {
                    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
                        return error.NotATable;
                    }
                    c.lua_getfield(L, -1, name.ptr);
                    c.lua_remove(L, -2); // Remove parent table
                },
                .index => |idx| {
                    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
                        return error.NotATable;
                    }
                    c.lua_rawgeti(L, -1, idx);
                    c.lua_remove(L, -2); // Remove parent table
                },
            }
        }
        
        return self.createVariableInfo(L, -1, path);
    }
    
    pub fn setVariable(self: *Self, L: *c.lua_State, path: []const u8, value: Value) !void {
        const segments = try self.parseVariablePath(path);
        defer self.allocator.free(segments);
        
        if (segments.len == 0) return error.InvalidPath;
        
        // Navigate to parent
        c.lua_pushglobaltable(L);
        
        for (segments[0..segments.len - 1]) |segment| {
            switch (segment) {
                .field => |name| {
                    c.lua_getfield(L, -1, name.ptr);
                    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
                        c.lua_pop(L, 2);
                        return error.NotATable;
                    }
                    c.lua_remove(L, -2);
                },
                .index => |idx| {
                    c.lua_rawgeti(L, -1, idx);
                    if (c.lua_type(L, -1) != c.LUA_TTABLE) {
                        c.lua_pop(L, 2);
                        return error.NotATable;
                    }
                    c.lua_remove(L, -2);
                },
            }
        }
        
        // Push value
        try self.pushValue(L, value);
        
        // Set the final segment
        const last_segment = segments[segments.len - 1];
        switch (last_segment) {
            .field => |name| c.lua_setfield(L, -2, name.ptr),
            .index => |idx| c.lua_rawseti(L, -2, idx),
        }
        
        c.lua_pop(L, 1); // Pop parent table
    }
    
    pub fn watchVariable(self: *Self, L: *c.lua_State, path: []const u8, callback: WatchCallback) !*VariableWatch {
        const watch = try self.allocator.create(VariableWatch);
        watch.* = VariableWatch{
            .path = try self.allocator.dupe(u8, path),
            .callback = callback,
            .last_value = try self.inspectVariable(L, path),
        };
        
        // Install metatable hook for change detection
        try self.installWatchHook(L, watch);
        
        return watch;
    }
};

pub const VariableInfo = struct {
    path: []const u8,
    value: Value,
    type: []const u8,
    size: ?usize,
    metadata: std.StringHashMap([]const u8),
    children: ?[]VariableInfo,
};
```

### Table Inspection

```zig
pub const TableInspector = struct {
    const Self = @This();
    
    pub fn inspectTable(self: *Self, L: *c.lua_State, index: c_int) !TableInfo {
        const abs_index = if (index < 0) c.lua_gettop(L) + index + 1 else index;
        
        var info = TableInfo{
            .size = 0,
            .array_size = c.lua_rawlen(L, abs_index),
            .has_metatable = c.lua_getmetatable(L, abs_index) != 0,
            .entries = std.ArrayList(TableEntry).init(self.allocator),
        };
        
        if (info.has_metatable) {
            c.lua_pop(L, 1); // Pop metatable
        }
        
        // Iterate table
        c.lua_pushnil(L);
        while (c.lua_next(L, abs_index) != 0) {
            defer c.lua_pop(L, 1); // Pop value, keep key
            
            const entry = TableEntry{
                .key = try self.captureValue(L, -2),
                .value = try self.captureValue(L, -1),
                .key_type = self.getLuaType(L, -2),
                .value_type = self.getLuaType(L, -1),
            };
            
            try info.entries.append(entry);
            info.size += 1;
            
            if (info.size >= self.max_table_entries) {
                info.truncated = true;
                break;
            }
        }
        
        return info;
    }
    
    pub fn getTablePath(self: *Self, L: *c.lua_State, table_index: c_int, target_index: c_int) !?[]const u8 {
        // Find path from table to target value
        var visited = std.AutoHashMap(*anyopaque, void).init(self.allocator);
        defer visited.deinit();
        
        var path_buffer = std.ArrayList(u8).init(self.allocator);
        defer path_buffer.deinit();
        
        const found = try self.searchTableRecursive(L, table_index, target_index, &visited, &path_buffer);
        
        if (found) {
            return path_buffer.toOwnedSlice();
        } else {
            return null;
        }
    }
};
```

---

## Source Code Mapping

### Source Code Manager

```zig
pub const SourceCodeManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    source_cache: std.StringHashMap(SourceFile),
    chunk_mappings: std.HashMap(usize, ChunkInfo),
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .source_cache = std.StringHashMap(SourceFile).init(allocator),
            .chunk_mappings = std.HashMap(usize, ChunkInfo).init(allocator),
        };
        return self;
    }
    
    pub fn loadSource(self: *Self, source_path: []const u8) !void {
        if (self.source_cache.contains(source_path)) return;
        
        const content = try std.fs.cwd().readFileAlloc(self.allocator, source_path, 1024 * 1024);
        
        var lines = std.ArrayList([]const u8).init(self.allocator);
        var iter = std.mem.tokenize(u8, content, "\n");
        while (iter.next()) |line| {
            try lines.append(line);
        }
        
        try self.source_cache.put(source_path, SourceFile{
            .path = source_path,
            .content = content,
            .lines = lines.toOwnedSlice(),
        });
    }
    
    pub fn getSourceLine(self: *Self, source: []const u8, line_number: i32) !?[]const u8 {
        // Handle special source names
        if (std.mem.startsWith(u8, source, "=")) {
            return null; // String chunk
        }
        
        if (std.mem.startsWith(u8, source, "@")) {
            const file_path = source[1..];
            try self.loadSource(file_path);
            
            if (self.source_cache.get(file_path)) |file| {
                if (line_number > 0 and line_number <= file.lines.len) {
                    return file.lines[@intCast(usize, line_number - 1)];
                }
            }
        }
        
        return null;
    }
    
    pub fn mapChunkToSource(self: *Self, L: *c.lua_State, level: c_int) !ChunkInfo {
        var ar: c.lua_Debug = undefined;
        if (c.lua_getstack(L, level, &ar) == 0) {
            return error.InvalidStackLevel;
        }
        
        _ = c.lua_getinfo(L, "S", &ar);
        
        return ChunkInfo{
            .source = if (ar.source) |s| try self.allocator.dupe(u8, std.mem.span(s)) else null,
            .short_source = try self.allocator.dupe(u8, &ar.short_src),
            .line_defined = ar.linedefined,
            .last_line_defined = ar.lastlinedefined,
            .what = try self.allocator.dupe(u8, std.mem.span(ar.what)),
        };
    }
};

pub const SourceFile = struct {
    path: []const u8,
    content: []u8,
    lines: [][]const u8,
};
```

### Source Annotation

```zig
pub const SourceAnnotator = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    annotations: std.HashMap(SourceLocation, []Annotation),
    
    pub fn annotateSource(self: *Self, location: SourceLocation, annotation: Annotation) !void {
        const entry = try self.annotations.getOrPut(location);
        if (!entry.found_existing) {
            entry.value_ptr.* = std.ArrayList(Annotation).init(self.allocator);
        }
        try entry.value_ptr.append(annotation);
    }
    
    pub fn renderAnnotatedSource(self: *Self, source_file: SourceFile, writer: anytype) !void {
        for (source_file.lines, 1..) |line, line_num| {
            // Line number
            try writer.print("{d:>4} | ", .{line_num});
            
            // Check for annotations
            const location = SourceLocation{
                .file = source_file.path,
                .line = @intCast(i32, line_num),
            };
            
            if (self.annotations.get(location)) |anns| {
                try writer.writeAll(">>> ");
            } else {
                try writer.writeAll("    ");
            }
            
            // Source line
            try writer.writeAll(line);
            try writer.writeAll("\n");
            
            // Render annotations
            if (self.annotations.get(location)) |anns| {
                for (anns) |ann| {
                    try writer.print("     |     {s}: {s}\n", .{ @tagName(ann.type), ann.message });
                }
            }
        }
    }
};

pub const Annotation = struct {
    type: enum { breakpoint, coverage, profile, warning, error },
    message: []const u8,
    severity: enum { info, warning, error },
};
```

---

## Profiling and Performance Analysis

### Comprehensive Profiler

```zig
pub const LuaProfiler = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    mode: ProfileMode,
    sample_interval: u32 = 1000, // Instructions
    call_graph: CallGraph,
    line_stats: std.HashMap(SourceLocation, LineStats),
    memory_tracker: MemoryTracker,
    
    pub const ProfileMode = enum {
        statistical,    // Sample-based profiling
        deterministic,  // Exact call counts
        memory,         // Memory allocation tracking
        hybrid,         // All of the above
    };
    
    pub fn startProfiling(self: *Self, L: *c.lua_State) !void {
        const mask = switch (self.mode) {
            .statistical => c.LUA_MASKCOUNT,
            .deterministic => c.LUA_MASKCALL | c.LUA_MASKRET,
            .memory => c.LUA_MASKCALL | c.LUA_MASKRET | c.LUA_MASKLINE,
            .hybrid => c.LUA_MASKCALL | c.LUA_MASKRET | c.LUA_MASKLINE | c.LUA_MASKCOUNT,
        };
        
        c.lua_sethook(L, profileHook, mask, self.sample_interval);
        
        // Store profiler reference in registry
        c.lua_pushlightuserdata(L, self);
        c.lua_setfield(L, c.LUA_REGISTRYINDEX, "PROFILER");
    }
    
    fn profileHook(L: ?*c.lua_State, ar: ?*c.lua_Debug) callconv(.C) void {
        const profiler = getProfiler(L) orelse return;
        
        profiler.handleProfileEvent(L.?, ar.?) catch |err| {
            std.log.err("Profiler error: {}", .{err});
        };
    }
    
    fn handleProfileEvent(self: *Self, L: *c.lua_State, ar: *c.lua_Debug) !void {
        _ = c.lua_getinfo(L, "nSlf", ar);
        
        const location = SourceLocation{
            .file = if (ar.source) |s| std.mem.span(s) else "?",
            .line = ar.currentline,
        };
        
        switch (ar.event) {
            c.LUA_HOOKCALL => {
                const func_info = try self.getFunctionInfo(ar);
                try self.call_graph.enterFunction(func_info);
                
                if (self.mode == .memory or self.mode == .hybrid) {
                    self.memory_tracker.startTracking(func_info);
                }
            },
            c.LUA_HOOKRET => {
                const func_info = try self.call_graph.getCurrentFunction();
                try self.call_graph.exitFunction();
                
                if (self.mode == .memory or self.mode == .hybrid) {
                    const mem_delta = self.memory_tracker.stopTracking(func_info);
                    try self.recordMemoryAllocation(func_info, mem_delta);
                }
            },
            c.LUA_HOOKLINE => {
                const stats = try self.line_stats.getOrPut(location);
                if (!stats.found_existing) {
                    stats.value_ptr.* = LineStats{};
                }
                stats.value_ptr.hits += 1;
                stats.value_ptr.last_hit = std.time.milliTimestamp();
            },
            c.LUA_HOOKCOUNT => {
                // Statistical sampling
                if (self.mode == .statistical or self.mode == .hybrid) {
                    try self.takeSample(L, ar);
                }
            },
            else => {},
        }
    }
    
    pub fn generateReport(self: *Self) !ProfileReport {
        var report = ProfileReport{
            .total_time = std.time.milliTimestamp() - self.start_time,
            .functions = std.ArrayList(FunctionProfile).init(self.allocator),
            .hotspots = std.ArrayList(HotSpot).init(self.allocator),
            .call_graph_dot = try self.call_graph.generateDot(self.allocator),
        };
        
        // Analyze function statistics
        var iter = self.call_graph.functions.iterator();
        while (iter.next()) |entry| {
            const func_profile = FunctionProfile{
                .name = entry.key_ptr.*,
                .calls = entry.value_ptr.call_count,
                .total_time = entry.value_ptr.total_time,
                .self_time = entry.value_ptr.self_time,
                .avg_time = entry.value_ptr.total_time / @max(1, entry.value_ptr.call_count),
                .memory_allocated = entry.value_ptr.memory_allocated,
            };
            try report.functions.append(func_profile);
        }
        
        // Sort by total time
        std.sort.sort(FunctionProfile, report.functions.items, {}, compareByTotalTime);
        
        // Find hotspots
        var line_iter = self.line_stats.iterator();
        while (line_iter.next()) |entry| {
            if (entry.value_ptr.hits > 1000) { // Threshold for hotspot
                try report.hotspots.append(HotSpot{
                    .location = entry.key_ptr.*,
                    .hits = entry.value_ptr.hits,
                });
            }
        }
        
        return report;
    }
};

pub const CallGraph = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    functions: std.StringHashMap(FunctionStats),
    edges: std.ArrayList(CallEdge),
    call_stack: std.ArrayList(CallFrame),
    
    pub fn enterFunction(self: *Self, func_info: FunctionInfo) !void {
        const frame = CallFrame{
            .function = func_info,
            .start_time = std.time.nanoTimestamp(),
            .start_memory = getCurrentMemory(),
        };
        
        try self.call_stack.append(frame);
        
        // Record call edge
        if (self.call_stack.items.len > 1) {
            const caller = self.call_stack.items[self.call_stack.items.len - 2];
            try self.edges.append(CallEdge{
                .from = caller.function.name,
                .to = func_info.name,
                .count = 1,
            });
        }
    }
    
    pub fn generateDot(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();
        
        try writer.writeAll("digraph CallGraph {\n");
        try writer.writeAll("  rankdir=TB;\n");
        try writer.writeAll("  node [shape=box];\n\n");
        
        // Nodes
        var iter = self.functions.iterator();
        while (iter.next()) |entry| {
            const stats = entry.value_ptr;
            const color = if (stats.self_time > self.total_time / 10) "red" else "black";
            
            try writer.print(
                "  \"{s}\" [label=\"{s}\\ncalls: {}\\ntime: {d:.2}ms\", color={s}];\n",
                .{ entry.key_ptr.*, entry.key_ptr.*, stats.call_count, 
                   @intToFloat(f64, stats.self_time) / 1_000_000.0, color }
            );
        }
        
        // Edges
        for (self.edges.items) |edge| {
            try writer.print(
                "  \"{s}\" -> \"{s}\" [label=\"{}\"];\n",
                .{ edge.from, edge.to, edge.count }
            );
        }
        
        try writer.writeAll("}\n");
        return buffer.toOwnedSlice();
    }
};
```

---

## Breakpoint Implementation

### Breakpoint Manager

```zig
pub const BreakpointManager = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    breakpoints: std.ArrayList(Breakpoint),
    conditional_breakpoints: std.ArrayList(ConditionalBreakpoint),
    watchpoints: std.ArrayList(Watchpoint),
    break_handler: ?BreakHandler = null,
    
    pub fn addBreakpoint(self: *Self, location: SourceLocation) !*Breakpoint {
        const bp = Breakpoint{
            .id = self.generateId(),
            .location = location,
            .enabled = true,
            .hit_count = 0,
        };
        try self.breakpoints.append(bp);
        return &self.breakpoints.items[self.breakpoints.items.len - 1];
    }
    
    pub fn addConditionalBreakpoint(self: *Self, location: SourceLocation, condition: []const u8) !*ConditionalBreakpoint {
        const bp = ConditionalBreakpoint{
            .base = Breakpoint{
                .id = self.generateId(),
                .location = location,
                .enabled = true,
                .hit_count = 0,
            },
            .condition = try self.allocator.dupe(u8, condition),
            .compiled_condition = null,
        };
        try self.conditional_breakpoints.append(bp);
        return &self.conditional_breakpoints.items[self.conditional_breakpoints.items.len - 1];
    }
    
    pub fn shouldBreak(self: *Self, info: DebugInfo) !bool {
        const location = SourceLocation{
            .file = info.source orelse return false,
            .line = info.current_line,
        };
        
        // Check regular breakpoints
        for (self.breakpoints.items) |*bp| {
            if (bp.enabled and bp.location.equals(location)) {
                bp.hit_count += 1;
                return true;
            }
        }
        
        // Check conditional breakpoints
        for (self.conditional_breakpoints.items) |*cbp| {
            if (cbp.base.enabled and cbp.base.location.equals(location)) {
                cbp.base.hit_count += 1;
                if (try self.evaluateCondition(cbp)) {
                    return true;
                }
            }
        }
        
        return false;
    }
    
    fn evaluateCondition(self: *Self, cbp: *ConditionalBreakpoint) !bool {
        // Compile condition if needed
        if (cbp.compiled_condition == null) {
            const L = self.getLuaState();
            const result = c.luaL_loadstring(L, cbp.condition.ptr);
            if (result != c.LUA_OK) {
                const err = c.lua_tostring(L, -1);
                c.lua_pop(L, 1);
                return error.InvalidCondition;
            }
            cbp.compiled_condition = c.luaL_ref(L, c.LUA_REGISTRYINDEX);
        }
        
        // Evaluate condition
        const L = self.getLuaState();
        c.lua_rawgeti(L, c.LUA_REGISTRYINDEX, cbp.compiled_condition.?);
        const result = c.lua_pcall(L, 0, 1, 0);
        
        if (result != c.LUA_OK) {
            const err = c.lua_tostring(L, -1);
            c.lua_pop(L, 1);
            return false;
        }
        
        const condition_met = c.lua_toboolean(L, -1) != 0;
        c.lua_pop(L, 1);
        
        return condition_met;
    }
};

pub const Breakpoint = struct {
    id: u32,
    location: SourceLocation,
    enabled: bool,
    hit_count: u32,
    log_message: ?[]const u8 = null,
};

pub const ConditionalBreakpoint = struct {
    base: Breakpoint,
    condition: []const u8,
    compiled_condition: ?c_int = null,
};

pub const Watchpoint = struct {
    id: u32,
    variable_path: []const u8,
    watch_type: enum { read, write, read_write },
    enabled: bool,
    old_value: ?Value = null,
    hit_count: u32,
};
```

---

## REPL and Interactive Debugging

### Interactive Debugger

```zig
pub const InteractiveDebugger = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    lua_state: *c.lua_State,
    debug_state: DebugState,
    command_history: std.ArrayList([]const u8),
    stack_inspector: *StackInspector,
    variable_inspector: *VariableInspector,
    
    pub const DebugState = enum {
        running,
        paused,
        stepping,
        step_over,
        step_out,
    };
    
    pub fn enterDebugMode(self: *Self, reason: []const u8) !void {
        self.debug_state = .paused;
        
        try self.printDebugHeader(reason);
        try self.printCurrentLocation();
        
        while (self.debug_state == .paused) {
            const command = try self.readCommand();
            defer self.allocator.free(command);
            
            try self.executeCommand(command);
        }
    }
    
    pub fn executeCommand(self: *Self, command: []const u8) !void {
        var iter = std.mem.tokenize(u8, command, " ");
        const cmd = iter.next() orelse return;
        
        if (std.mem.eql(u8, cmd, "bt") or std.mem.eql(u8, cmd, "backtrace")) {
            try self.printBacktrace();
        } else if (std.mem.eql(u8, cmd, "l") or std.mem.eql(u8, cmd, "list")) {
            const line_str = iter.next();
            try self.listSource(line_str);
        } else if (std.mem.eql(u8, cmd, "p") or std.mem.eql(u8, cmd, "print")) {
            const expr = iter.rest();
            try self.printExpression(expr);
        } else if (std.mem.eql(u8, cmd, "locals")) {
            try self.printLocals();
        } else if (std.mem.eql(u8, cmd, "up")) {
            try self.moveStackFrame(-1);
        } else if (std.mem.eql(u8, cmd, "down")) {
            try self.moveStackFrame(1);
        } else if (std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "continue")) {
            self.debug_state = .running;
        } else if (std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "next")) {
            self.debug_state = .step_over;
        } else if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step")) {
            self.debug_state = .stepping;
        } else if (std.mem.eql(u8, cmd, "finish")) {
            self.debug_state = .step_out;
        } else if (std.mem.eql(u8, cmd, "b") or std.mem.eql(u8, cmd, "break")) {
            const location = iter.rest();
            try self.setBreakpoint(location);
        } else if (std.mem.eql(u8, cmd, "watch")) {
            const expr = iter.rest();
            try self.setWatchpoint(expr);
        } else if (std.mem.eql(u8, cmd, "eval")) {
            const code = iter.rest();
            try self.evaluateLua(code);
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
            try self.printHelp();
        } else {
            try self.print("Unknown command: {s}\n", .{cmd});
        }
    }
    
    fn printExpression(self: *Self, expr: []const u8) !void {
        // Evaluate expression in current context
        const frame_level = self.current_frame;
        
        // Build evaluation code with local variable injection
        var eval_code = std.ArrayList(u8).init(self.allocator);
        defer eval_code.deinit();
        
        // Inject locals
        const locals = try self.stack_inspector.captureLocals(self.lua_state, frame_level);
        for (locals) |local| {
            try eval_code.writer().print("local {s} = ...; ", .{local.name});
        }
        
        try eval_code.writer().print("return {s}", .{expr});
        
        // Compile and execute
        const result = c.luaL_loadstring(self.lua_state, eval_code.items.ptr);
        if (result != c.LUA_OK) {
            const err = c.lua_tostring(self.lua_state, -1);
            try self.print("Error: {s}\n", .{std.mem.span(err)});
            c.lua_pop(self.lua_state, 1);
            return;
        }
        
        // Push local values
        for (locals) |local| {
            try self.variable_inspector.pushValue(self.lua_state, local.value);
        }
        
        // Execute
        const call_result = c.lua_pcall(self.lua_state, @intCast(c_int, locals.len), c.LUA_MULTRET, 0);
        if (call_result != c.LUA_OK) {
            const err = c.lua_tostring(self.lua_state, -1);
            try self.print("Runtime error: {s}\n", .{std.mem.span(err)});
            c.lua_pop(self.lua_state, 1);
            return;
        }
        
        // Print results
        const nresults = c.lua_gettop(self.lua_state);
        for (0..@intCast(usize, nresults)) |i| {
            const value = try self.variable_inspector.captureValue(self.lua_state, @intCast(c_int, i + 1));
            try self.printValue(value);
        }
        c.lua_pop(self.lua_state, nresults);
    }
};

pub const DebugCommands = struct {
    pub const commands = [_]Command{
        .{ .name = "backtrace", .aliases = &[_][]const u8{"bt"}, .help = "Print call stack" },
        .{ .name = "list", .aliases = &[_][]const u8{"l"}, .help = "List source code" },
        .{ .name = "print", .aliases = &[_][]const u8{"p"}, .help = "Print expression value" },
        .{ .name = "locals", .aliases = &[_][]const u8{}, .help = "Print local variables" },
        .{ .name = "up", .aliases = &[_][]const u8{}, .help = "Move up stack frame" },
        .{ .name = "down", .aliases = &[_][]const u8{}, .help = "Move down stack frame" },
        .{ .name = "continue", .aliases = &[_][]const u8{"c"}, .help = "Continue execution" },
        .{ .name = "next", .aliases = &[_][]const u8{"n"}, .help = "Step over" },
        .{ .name = "step", .aliases = &[_][]const u8{"s"}, .help = "Step into" },
        .{ .name = "finish", .aliases = &[_][]const u8{}, .help = "Step out" },
        .{ .name = "break", .aliases = &[_][]const u8{"b"}, .help = "Set breakpoint" },
        .{ .name = "watch", .aliases = &[_][]const u8{}, .help = "Set watchpoint" },
        .{ .name = "eval", .aliases = &[_][]const u8{}, .help = "Evaluate Lua code" },
        .{ .name = "help", .aliases = &[_][]const u8{"h"}, .help = "Show help" },
    };
};
```

---

## Development Tool Integration

### Debug Adapter Protocol (DAP) Implementation

```zig
pub const DAPServer = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    debugger: *InteractiveDebugger,
    transport: Transport,
    sequence: u32 = 1,
    
    pub fn handleRequest(self: *Self, request: DAPRequest) !void {
        const response = switch (request.command) {
            .initialize => try self.handleInitialize(request),
            .launch => try self.handleLaunch(request),
            .setBreakpoints => try self.handleSetBreakpoints(request),
            .stackTrace => try self.handleStackTrace(request),
            .scopes => try self.handleScopes(request),
            .variables => try self.handleVariables(request),
            .@"continue" => try self.handleContinue(request),
            .next => try self.handleNext(request),
            .stepIn => try self.handleStepIn(request),
            .stepOut => try self.handleStepOut(request),
            .evaluate => try self.handleEvaluate(request),
            else => try self.createErrorResponse(request, "Unsupported command"),
        };
        
        try self.sendResponse(response);
    }
    
    fn handleStackTrace(self: *Self, request: DAPRequest) !DAPResponse {
        const args = request.arguments.?.stackTrace;
        const frames = try self.debugger.stack_inspector.captureStackTrace(self.debugger.lua_state);
        
        var dap_frames = std.ArrayList(DAPStackFrame).init(self.allocator);
        defer dap_frames.deinit();
        
        const start = @min(args.startFrame orelse 0, frames.len);
        const end = @min(start + (args.levels orelse frames.len), frames.len);
        
        for (frames[start..end]) |frame, i| {
            try dap_frames.append(DAPStackFrame{
                .id = @intCast(i32, start + i),
                .name = frame.function_name orelse "<anonymous>",
                .source = if (frame.source) |s| DAPSource{
                    .path = s,
                    .name = std.fs.path.basename(s),
                } else null,
                .line = frame.line,
                .column = 0,
            });
        }
        
        return DAPResponse{
            .request_seq = request.seq,
            .success = true,
            .command = request.command,
            .body = .{
                .stackTrace = .{
                    .stackFrames = dap_frames.toOwnedSlice(),
                    .totalFrames = frames.len,
                },
            },
        };
    }
};
```

### IDE Integration Helper

```zig
pub const IDEIntegration = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    language_server: *LuaLanguageServer,
    debugger: *InteractiveDebugger,
    
    pub fn provideCompletions(self: *Self, L: *c.lua_State, position: Position) ![]CompletionItem {
        var completions = std.ArrayList(CompletionItem).init(self.allocator);
        defer completions.deinit();
        
        // Get context at position
        const context = try self.getContextAtPosition(L, position);
        
        // Global completions
        if (context.is_global) {
            c.lua_pushglobaltable(L);
            c.lua_pushnil(L);
            
            while (c.lua_next(L, -2) != 0) {
                defer c.lua_pop(L, 1);
                
                if (c.lua_type(L, -2) == c.LUA_TSTRING) {
                    const name = c.lua_tostring(L, -2);
                    const value_type = c.lua_type(L, -1);
                    
                    try completions.append(CompletionItem{
                        .label = std.mem.span(name),
                        .kind = self.getCompletionKind(value_type),
                        .detail = try self.getTypeString(L, -1),
                    });
                }
            }
            
            c.lua_pop(L, 1); // Pop global table
        }
        
        // Local completions
        if (context.stack_level) |level| {
            const locals = try self.debugger.stack_inspector.captureLocals(L, level);
            for (locals) |local| {
                try completions.append(CompletionItem{
                    .label = local.name,
                    .kind = .Variable,
                    .detail = local.type,
                });
            }
        }
        
        return completions.toOwnedSlice();
    }
    
    pub fn provideHover(self: *Self, L: *c.lua_State, position: Position) !?HoverInfo {
        const identifier = try self.getIdentifierAtPosition(position);
        if (identifier == null) return null;
        
        // Look up value
        const value_info = try self.debugger.variable_inspector.inspectVariable(L, identifier.?);
        
        return HoverInfo{
            .contents = try std.fmt.allocPrint(self.allocator,
                "**{s}**\n\nType: `{s}`\nValue: `{s}`",
                .{ identifier.?, value_info.type, try self.formatValue(value_info.value) }
            ),
            .range = identifier.?.range,
        };
    }
    
    pub fn provideSignatureHelp(self: *Self, L: *c.lua_State, position: Position) !?SignatureHelp {
        // Analyze current function call context
        const call_context = try self.analyzeCallContext(position);
        if (call_context == null) return null;
        
        // Get function info
        c.lua_getglobal(L, call_context.?.function_name.ptr);
        if (c.lua_type(L, -1) != c.LUA_TFUNCTION) {
            c.lua_pop(L, 1);
            return null;
        }
        
        var ar: c.lua_Debug = undefined;
        c.lua_pushvalue(L, -1);
        _ = c.lua_getinfo(L, ">u", &ar);
        
        const signature = SignatureHelp{
            .signatures = &[_]SignatureInfo{
                .{
                    .label = try std.fmt.allocPrint(self.allocator,
                        "{s}({s})",
                        .{ call_context.?.function_name, self.getParameterList(ar) }
                    ),
                    .parameters = try self.getParameters(ar),
                },
            },
            .activeSignature = 0,
            .activeParameter = call_context.?.current_parameter,
        };
        
        c.lua_pop(L, 1);
        return signature;
    }
};
```

---

## Security Considerations

### Debug Library Security

```zig
pub const DebugSecurity = struct {
    const Self = @This();
    
    allowed_functions: std.StringHashMap(bool),
    max_stack_depth: u32 = 100,
    max_execution_time: u64 = 30_000_000_000, // 30 seconds
    
    pub fn createSecureDebugEnvironment(self: *Self, L: *c.lua_State) !void {
        // Create filtered debug table
        c.lua_newtable(L);
        
        // Only expose safe debug functions
        const safe_functions = [_]struct { name: []const u8, func: c.lua_CFunction }{
            .{ .name = "traceback", .func = safeTraceback },
            .{ .name = "getinfo", .func = safeGetInfo },
            .{ .name = "getlocal", .func = safeGetLocal },
            // Explicitly exclude: sethook, getregistry, setupvalue, setlocal
        };
        
        for (safe_functions) |sf| {
            c.lua_pushcfunction(L, sf.func);
            c.lua_setfield(L, -2, sf.name.ptr);
        }
        
        c.lua_setglobal(L, "debug");
    }
    
    fn safeGetInfo(L: ?*c.lua_State) callconv(.C) c_int {
        // Validate arguments
        const level = c.luaL_checkinteger(L, 1);
        const what = c.luaL_checkstring(L, 2);
        
        // Restrict what information can be accessed
        var filtered_what = std.ArrayList(u8).init(std.heap.page_allocator);
        defer filtered_what.deinit();
        
        // Only allow safe options
        const allowed = "nlS"; // name, currentline, source
        for (std.mem.span(what)) |ch| {
            if (std.mem.indexOf(u8, allowed, &[_]u8{ch}) != null) {
                filtered_what.append(ch) catch return 0;
            }
        }
        
        // Create result table
        c.lua_newtable(L);
        
        var ar: c.lua_Debug = undefined;
        if (c.lua_getstack(L, @intCast(c_int, level), &ar) == 0) {
            return 1; // Return empty table
        }
        
        _ = c.lua_getinfo(L, filtered_what.items.ptr, &ar);
        
        // Copy safe fields to result
        if (ar.name) |name| {
            c.lua_pushstring(L, name);
            c.lua_setfield(L, -2, "name");
        }
        
        c.lua_pushinteger(L, ar.currentline);
        c.lua_setfield(L, -2, "currentline");
        
        if (ar.source) |source| {
            // Sanitize source path
            const safe_source = sanitizeSourcePath(source);
            c.lua_pushstring(L, safe_source.ptr);
            c.lua_setfield(L, -2, "source");
        }
        
        return 1;
    }
};
```

### Sandbox Debug Access

```zig
pub const SandboxedDebugger = struct {
    const Self = @This();
    
    permissions: DebugPermissions,
    audit_log: *AuditLog,
    
    pub const DebugPermissions = struct {
        allow_stack_inspection: bool = false,
        allow_variable_read: bool = true,
        allow_variable_write: bool = false,
        allow_breakpoints: bool = true,
        allow_profiling: bool = true,
        max_inspect_depth: u32 = 3,
        restricted_paths: []const []const u8 = &.{},
    };
    
    pub fn inspectVariableSecure(self: *Self, L: *c.lua_State, path: []const u8) !?VariableInfo {
        if (!self.permissions.allow_variable_read) {
            try self.audit_log.log("Variable read denied", .{ .path = path });
            return error.PermissionDenied;
        }
        
        // Check path restrictions
        for (self.permissions.restricted_paths) |restricted| {
            if (std.mem.startsWith(u8, path, restricted)) {
                try self.audit_log.log("Restricted variable access", .{ .path = path });
                return error.RestrictedPath;
            }
        }
        
        // Perform inspection with depth limit
        var inspector = VariableInspector{
            .allocator = self.allocator,
            .max_depth = self.permissions.max_inspect_depth,
        };
        
        const result = try inspector.inspectVariable(L, path);
        
        try self.audit_log.log("Variable inspected", .{
            .path = path,
            .type = result.type,
        });
        
        return result;
    }
};
```

---

## Best Practices and Guidelines

### Development Tool Configuration

```zig
pub const DebugConfig = struct {
    // Feature flags
    enable_debugger: bool = true,
    enable_profiler: bool = true,
    enable_coverage: bool = false,
    
    // Security settings
    sandbox_debug_access: bool = true,
    debug_permissions: SandboxedDebugger.DebugPermissions = .{},
    
    // Performance settings
    profile_sample_rate: u32 = 1000,
    max_stack_capture_depth: u32 = 50,
    max_table_inspect_size: u32 = 1000,
    
    // Integration settings
    enable_dap_server: bool = false,
    dap_port: u16 = 9229,
    enable_language_server: bool = false,
    lsp_port: u16 = 9230,
    
    pub fn development() DebugConfig {
        return .{
            .enable_debugger = true,
            .enable_profiler = true,
            .enable_coverage = true,
            .sandbox_debug_access = false,
            .debug_permissions = .{
                .allow_stack_inspection = true,
                .allow_variable_read = true,
                .allow_variable_write = true,
                .allow_breakpoints = true,
                .allow_profiling = true,
            },
        };
    }
    
    pub fn production() DebugConfig {
        return .{
            .enable_debugger = false,
            .enable_profiler = true,
            .enable_coverage = false,
            .sandbox_debug_access = true,
            .debug_permissions = .{
                .allow_stack_inspection = false,
                .allow_variable_read = false,
                .allow_variable_write = false,
                .allow_breakpoints = false,
                .allow_profiling = true,
            },
            .profile_sample_rate = 10000, // Less frequent sampling
        };
    }
};
```

### Debug Tool Integration Pattern

```zig
pub fn createLuaEngineWithDebugTools(allocator: std.mem.Allocator, config: EngineConfig) !*LuaEngine {
    const engine = try LuaEngine.init(allocator, config);
    
    if (config.debug_config.enable_debugger) {
        engine.debugger = try InteractiveDebugger.init(allocator, engine.main_state);
        engine.breakpoint_manager = try BreakpointManager.init(allocator);
        
        // Install debug hooks
        const hook_manager = try DebugHookManager.init(allocator);
        try hook_manager.installHook(engine.main_state, .{
            .on_line = true,
            .on_call = config.debug_config.enable_profiler,
            .on_return = config.debug_config.enable_profiler,
        });
    }
    
    if (config.debug_config.enable_profiler) {
        engine.profiler = try LuaProfiler.init(allocator, .{
            .mode = .hybrid,
            .sample_interval = config.debug_config.profile_sample_rate,
        });
    }
    
    if (config.debug_config.enable_dap_server) {
        engine.dap_server = try DAPServer.init(allocator, .{
            .port = config.debug_config.dap_port,
            .debugger = engine.debugger,
        });
        try engine.dap_server.start();
    }
    
    return engine;
}
```

### Performance Monitoring

```zig
pub const DebugPerformanceMonitor = struct {
    const Self = @This();
    
    hook_overhead: RollingAverage,
    inspection_times: Histogram,
    profile_overhead: RollingAverage,
    
    pub fn measureDebugOverhead(self: *Self, baseline: fn() !void, with_debug: fn() !void) !f64 {
        // Measure baseline
        const baseline_start = std.time.nanoTimestamp();
        try baseline();
        const baseline_time = std.time.nanoTimestamp() - baseline_start;
        
        // Measure with debug
        const debug_start = std.time.nanoTimestamp();
        try with_debug();
        const debug_time = std.time.nanoTimestamp() - debug_start;
        
        const overhead_percent = @intToFloat(f64, debug_time - baseline_time) / 
                                @intToFloat(f64, baseline_time) * 100.0;
        
        self.hook_overhead.add(overhead_percent);
        
        return overhead_percent;
    }
    
    pub fn getPerformanceReport(self: *Self) PerformanceReport {
        return .{
            .avg_hook_overhead = self.hook_overhead.getAverage(),
            .p99_inspection_time = self.inspection_times.getPercentile(0.99),
            .avg_profile_overhead = self.profile_overhead.getAverage(),
            .recommendations = self.generateRecommendations(),
        };
    }
};
```

## Conclusion

Lua's debug library provides comprehensive introspection capabilities that enable powerful development tools:

1. **Debug Hooks** - Fine-grained execution control with minimal overhead
2. **Stack Introspection** - Complete visibility into call stacks and variables
3. **Source Mapping** - Accurate source location tracking and annotation
4. **Profiling** - Statistical and deterministic performance analysis
5. **Interactive Debugging** - Full-featured debugging with breakpoints and stepping
6. **IDE Integration** - DAP and LSP support for modern development environments

Key considerations for zig_llms integration:
- Security-first approach with sandboxed debug access
- Performance monitoring to minimize debug overhead
- Flexible configuration for development vs production
- Comprehensive tool integration for enhanced developer experience

The debug introspection capabilities make Lua an excellent choice for creating sophisticated development and debugging tools within the zig_llms framework.