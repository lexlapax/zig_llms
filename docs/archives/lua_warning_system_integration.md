# Lua 5.4 Warning System Integration for zig_llms

## Executive Summary

This document investigates the Lua 5.4 warning system and designs its integration with the zig_llms Lua scripting engine. The warning system provides runtime diagnostics without interrupting execution, enabling better debugging and code quality monitoring in production environments.

## Table of Contents

1. [Lua 5.4 Warning System Overview](#lua-54-warning-system-overview)
2. [Warning System API](#warning-system-api)
3. [Warning Categories and Types](#warning-categories-and-types)
4. [Integration Architecture](#integration-architecture)
5. [Warning Handler Design](#warning-handler-design)
6. [Zig Integration Strategy](#zig-integration-strategy)
7. [Performance Considerations](#performance-considerations)
8. [Testing and Validation](#testing-and-validation)
9. [Best Practices and Recommendations](#best-practices-and-recommendations)

---

## Lua 5.4 Warning System Overview

### What's New in Lua 5.4

Lua 5.4 introduced a formal warning system that allows the interpreter to emit non-fatal diagnostic messages during execution. This system is designed to:

1. **Report potential issues** without halting execution
2. **Enable gradual deprecation** of features
3. **Provide debugging information** in production
4. **Support custom warning handlers** for application-specific needs

### Key Features

- **Non-blocking**: Warnings don't interrupt program flow
- **Configurable**: Can be enabled/disabled per warning type
- **Extensible**: Custom warning handlers can be registered
- **Contextual**: Warnings include source location information
- **Efficient**: Minimal performance impact when disabled

---

## Warning System API

### Core Functions

```c
// Set warning function
void lua_setwarnf(lua_State *L, lua_WarnFunction f, void *ud);

// Warning function signature
typedef void (*lua_WarnFunction)(void *ud, const char *msg, int tocont);

// Emit a warning from C
void lua_warning(lua_State *L, const char *msg, int tocont);

// Control warnings (Lua side)
warn("@on")   -- Enable warnings
warn("@off")  -- Disable warnings
warn(msg)     -- Emit custom warning
```

### Warning Message Protocol

1. **tocont = 0**: Complete warning message
2. **tocont = 1**: Message fragment (more to come)
3. **Message prefixes**:
   - `@on`: Enable warnings
   - `@off`: Disable warnings
   - Regular text: Warning content

---

## Warning Categories and Types

### Built-in Warning Types

1. **Deprecated Features**
   ```lua
   -- Using deprecated syntax
   function f(x)
     return x < 0 and -x or x  -- May warn about ambiguous syntax
   end
   ```

2. **Undefined Behavior**
   ```lua
   -- Modifying a table during traversal
   for k, v in pairs(t) do
     t[k] = nil  -- Warning: table modified during traversal
   end
   ```

3. **Performance Issues**
   ```lua
   -- Creating excessive garbage
   for i = 1, 1000000 do
     local s = "prefix" .. i  -- Warning: excessive string concatenation
   end
   ```

4. **Type Mismatches**
   ```lua
   -- Implicit conversions
   local n = "10" + 5  -- Warning: implicit string to number conversion
   ```

### Custom Warning Categories

```lua
-- Application-specific warnings
warn("SECURITY: Attempting to access restricted resource")
warn("PERFORMANCE: Query took " .. time .. "ms")
warn("DEPRECATION: This API will be removed in v2.0")
```

---

## Integration Architecture

### Design Goals

1. **Seamless Integration**: Warning system should work naturally with zig_llms logging
2. **Structured Data**: Convert string warnings to structured log entries
3. **Filtering**: Support warning filtering by category and severity
4. **Persistence**: Option to store warnings for analysis
5. **Metrics**: Track warning frequency and patterns

### Component Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Lua Warning System                       │
├─────────────────────────────────────────────────────────────┤
│ Lua Runtime ──> lua_WarnFunction ──> LuaWarningHandler     │
│                                           │                 │
│                                           ▼                 │
│                                    WarningProcessor         │
│                                           │                 │
│                         ┌─────────────────┴────────────┐    │
│                         ▼                              ▼    │
│                  WarningLogger                 WarningMetrics│
│                         │                              │    │
│                         ▼                              ▼    │
│                  Zig Logging System            Metrics System│
└─────────────────────────────────────────────────────────────┘
```

---

## Warning Handler Design

### LuaWarningHandler Implementation

```zig
pub const LuaWarningHandler = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    processor: *WarningProcessor,
    buffer: std.ArrayList(u8),
    enabled: bool = true,
    warning_count: u64 = 0,
    
    pub fn init(allocator: std.mem.Allocator, processor: *WarningProcessor) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .processor = processor,
            .buffer = std.ArrayList(u8).init(allocator),
            .enabled = true,
            .warning_count = 0,
        };
        return self;
    }
    
    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.allocator.destroy(self);
    }
    
    // C callback function
    pub fn warnCallback(ud: ?*anyopaque, msg: [*c]const u8, tocont: c_int) callconv(.C) void {
        const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), ud));
        self.handleWarning(std.mem.span(msg), tocont != 0) catch |err| {
            std.log.err("Failed to handle Lua warning: {}", .{err});
        };
    }
    
    fn handleWarning(self: *Self, msg: []const u8, is_continuation: bool) !void {
        // Handle control messages
        if (std.mem.eql(u8, msg, "@on")) {
            self.enabled = true;
            return;
        }
        if (std.mem.eql(u8, msg, "@off")) {
            self.enabled = false;
            return;
        }
        
        if (!self.enabled) return;
        
        // Buffer continuation messages
        if (is_continuation) {
            try self.buffer.appendSlice(msg);
        } else {
            // Complete message received
            if (self.buffer.items.len > 0) {
                try self.buffer.appendSlice(msg);
                try self.processCompleteWarning(self.buffer.items);
                self.buffer.clearRetainingCapacity();
            } else {
                try self.processCompleteWarning(msg);
            }
        }
    }
    
    fn processCompleteWarning(self: *Self, message: []const u8) !void {
        self.warning_count += 1;
        
        // Parse warning structure
        const warning = try self.parseWarning(message);
        
        // Send to processor
        try self.processor.processWarning(warning);
    }
    
    fn parseWarning(self: *Self, message: []const u8) !Warning {
        // Parse warning format: [source:line] category: message
        var warning = Warning{
            .message = message,
            .category = .unknown,
            .severity = .warning,
            .source_location = null,
            .timestamp = std.time.timestamp(),
            .metadata = std.StringHashMap([]const u8).init(self.allocator),
        };
        
        // Extract source location if present
        if (std.mem.indexOf(u8, message, ":")) |colon_pos| {
            if (std.mem.lastIndexOf(u8, message[0..colon_pos], "[")) |bracket_start| {
                if (std.mem.indexOf(u8, message[bracket_start..], "]")) |bracket_end_offset| {
                    const location_str = message[bracket_start + 1..bracket_start + bracket_end_offset];
                    warning.source_location = try self.parseSourceLocation(location_str);
                    warning.message = std.mem.trim(u8, message[bracket_start + bracket_end_offset + 1..], " ");
                }
            }
        }
        
        // Categorize warning
        warning.category = self.categorizeWarning(warning.message);
        
        return warning;
    }
    
    fn categorizeWarning(self: *Self, message: []const u8) WarningCategory {
        if (std.mem.startsWith(u8, message, "DEPRECATION:")) return .deprecation;
        if (std.mem.startsWith(u8, message, "SECURITY:")) return .security;
        if (std.mem.startsWith(u8, message, "PERFORMANCE:")) return .performance;
        if (std.mem.indexOf(u8, message, "undefined") != null) return .undefined_behavior;
        if (std.mem.indexOf(u8, message, "implicit") != null) return .type_mismatch;
        return .unknown;
    }
};
```

### Warning Data Structures

```zig
pub const Warning = struct {
    message: []const u8,
    category: WarningCategory,
    severity: WarningSeverity,
    source_location: ?SourceLocation,
    timestamp: i64,
    metadata: std.StringHashMap([]const u8),
};

pub const WarningCategory = enum {
    deprecation,
    undefined_behavior,
    performance,
    type_mismatch,
    security,
    custom,
    unknown,
};

pub const WarningSeverity = enum {
    info,
    warning,
    error,
};

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: ?u32 = null,
    function: ?[]const u8 = null,
};
```

### Warning Processor

```zig
pub const WarningProcessor = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    logger: *WarningLogger,
    metrics: *WarningMetrics,
    filters: std.ArrayList(*WarningFilter),
    handlers: std.ArrayList(*WarningHandler),
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .logger = try WarningLogger.init(allocator),
            .metrics = try WarningMetrics.init(allocator),
            .filters = std.ArrayList(*WarningFilter).init(allocator),
            .handlers = std.ArrayList(*WarningHandler).init(allocator),
        };
        return self;
    }
    
    pub fn processWarning(self: *Self, warning: Warning) !void {
        // Apply filters
        for (self.filters.items) |filter| {
            if (!try filter.shouldProcess(warning)) {
                return;
            }
        }
        
        // Update metrics
        try self.metrics.recordWarning(warning);
        
        // Log warning
        try self.logger.logWarning(warning);
        
        // Execute handlers
        for (self.handlers.items) |handler| {
            try handler.handleWarning(warning);
        }
    }
    
    pub fn addFilter(self: *Self, filter: *WarningFilter) !void {
        try self.filters.append(filter);
    }
    
    pub fn addHandler(self: *Self, handler: *WarningHandler) !void {
        try self.handlers.append(handler);
    }
};
```

---

## Zig Integration Strategy

### 1. Integration with Logging System

```zig
pub const WarningLogger = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    log_level_map: std.EnumMap(WarningCategory, std.log.Level),
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .log_level_map = std.EnumMap(WarningCategory, std.log.Level).init(.{
                .deprecation = .warn,
                .undefined_behavior = .err,
                .performance = .info,
                .type_mismatch = .warn,
                .security = .err,
                .custom = .info,
                .unknown = .debug,
            }),
        };
        return self;
    }
    
    pub fn logWarning(self: *Self, warning: Warning) !void {
        const level = self.log_level_map.get(warning.category) orelse .debug;
        
        // Format structured log entry
        if (warning.source_location) |loc| {
            std.log.scoped(.lua_warning).log(
                level,
                "[{s}:{d}] {s}: {s}",
                .{ loc.file, loc.line, @tagName(warning.category), warning.message }
            );
        } else {
            std.log.scoped(.lua_warning).log(
                level,
                "{s}: {s}",
                .{ @tagName(warning.category), warning.message }
            );
        }
    }
};
```

### 2. Integration with Metrics System

```zig
pub const WarningMetrics = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    warning_counts: std.EnumMap(WarningCategory, u64),
    warning_rate: RateCalculator,
    recent_warnings: RingBuffer(Warning, 100),
    
    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .allocator = allocator,
            .warning_counts = std.EnumMap(WarningCategory, u64).initFull(0),
            .warning_rate = RateCalculator.init(),
            .recent_warnings = RingBuffer(Warning, 100).init(),
        };
        return self;
    }
    
    pub fn recordWarning(self: *Self, warning: Warning) !void {
        // Update counts
        const count = self.warning_counts.getPtr(warning.category).?;
        count.* += 1;
        
        // Update rate
        self.warning_rate.recordEvent();
        
        // Store recent warning
        self.recent_warnings.push(warning);
        
        // Check thresholds
        if (count.* > self.getThreshold(warning.category)) {
            try self.handleThresholdExceeded(warning.category, count.*);
        }
    }
    
    pub fn getMetrics(self: *Self) WarningMetricsSnapshot {
        return WarningMetricsSnapshot{
            .total_warnings = self.getTotalWarnings(),
            .warnings_per_category = self.warning_counts,
            .warning_rate = self.warning_rate.getRate(),
            .recent_warnings = self.recent_warnings.toSlice(),
        };
    }
    
    fn getThreshold(self: *Self, category: WarningCategory) u64 {
        return switch (category) {
            .security => 1,        // Alert on first security warning
            .undefined_behavior => 10,
            .deprecation => 100,
            .performance => 50,
            else => 1000,
        };
    }
};
```

### 3. Warning Filters

```zig
pub const WarningFilter = struct {
    const Self = @This();
    
    vtable: *const VTable,
    
    pub const VTable = struct {
        shouldProcess: *const fn (self: *anyopaque, warning: Warning) anyerror!bool,
    };
    
    pub fn shouldProcess(self: *Self, warning: Warning) !bool {
        return self.vtable.shouldProcess(self, warning);
    }
};

pub const CategoryFilter = struct {
    const Self = @This();
    
    filter: WarningFilter,
    allowed_categories: std.EnumSet(WarningCategory),
    
    pub fn init(allowed_categories: std.EnumSet(WarningCategory)) Self {
        return Self{
            .filter = WarningFilter{
                .vtable = &.{
                    .shouldProcess = shouldProcessImpl,
                },
            },
            .allowed_categories = allowed_categories,
        };
    }
    
    fn shouldProcessImpl(ctx: *anyopaque, warning: Warning) !bool {
        const self = @fieldParentPtr(Self, "filter", @ptrCast(*WarningFilter, ctx));
        return self.allowed_categories.contains(warning.category);
    }
};

pub const RateLimitFilter = struct {
    const Self = @This();
    
    filter: WarningFilter,
    rate_limiter: *RateLimiter,
    
    pub fn init(max_warnings_per_second: f64) !*Self {
        const self = try allocator.create(Self);
        self.* = Self{
            .filter = WarningFilter{
                .vtable = &.{
                    .shouldProcess = shouldProcessImpl,
                },
            },
            .rate_limiter = try RateLimiter.init(max_warnings_per_second),
        };
        return self;
    }
    
    fn shouldProcessImpl(ctx: *anyopaque, warning: Warning) !bool {
        const self = @fieldParentPtr(Self, "filter", @ptrCast(*WarningFilter, ctx));
        return self.rate_limiter.tryAcquire();
    }
};
```

### 4. Custom Warning Handlers

```zig
pub const WarningHandler = struct {
    const Self = @This();
    
    vtable: *const VTable,
    
    pub const VTable = struct {
        handleWarning: *const fn (self: *anyopaque, warning: Warning) anyerror!void,
    };
    
    pub fn handleWarning(self: *Self, warning: Warning) !void {
        return self.vtable.handleWarning(self, warning);
    }
};

// Send critical warnings to monitoring system
pub const AlertHandler = struct {
    const Self = @This();
    
    handler: WarningHandler,
    alert_system: *AlertSystem,
    severity_threshold: WarningSeverity,
    
    pub fn init(alert_system: *AlertSystem, threshold: WarningSeverity) Self {
        return Self{
            .handler = WarningHandler{
                .vtable = &.{
                    .handleWarning = handleWarningImpl,
                },
            },
            .alert_system = alert_system,
            .severity_threshold = threshold,
        };
    }
    
    fn handleWarningImpl(ctx: *anyopaque, warning: Warning) !void {
        const self = @fieldParentPtr(Self, "handler", @ptrCast(*WarningHandler, ctx));
        
        if (@enumToInt(warning.severity) >= @enumToInt(self.severity_threshold)) {
            try self.alert_system.sendAlert(.{
                .title = try std.fmt.allocPrint(
                    self.allocator,
                    "Lua Warning: {s}",
                    .{@tagName(warning.category)}
                ),
                .message = warning.message,
                .severity = warning.severity,
                .metadata = warning.metadata,
            });
        }
    }
};

// Store warnings for later analysis
pub const PersistenceHandler = struct {
    const Self = @This();
    
    handler: WarningHandler,
    storage: *WarningStorage,
    
    pub fn init(storage: *WarningStorage) Self {
        return Self{
            .handler = WarningHandler{
                .vtable = &.{
                    .handleWarning = handleWarningImpl,
                },
            },
            .storage = storage,
        };
    }
    
    fn handleWarningImpl(ctx: *anyopaque, warning: Warning) !void {
        const self = @fieldParentPtr(Self, "handler", @ptrCast(*WarningHandler, ctx));
        try self.storage.storeWarning(warning);
    }
};
```

---

## Performance Considerations

### 1. Overhead Analysis

The warning system has minimal performance impact:

- **Disabled warnings**: Single boolean check per potential warning site
- **Enabled warnings**: Function call + string processing
- **With handlers**: Additional processing based on handler complexity

### 2. Optimization Strategies

```zig
pub const OptimizedWarningHandler = struct {
    const Self = @This();
    
    // Batch warnings to reduce processing overhead
    batch_size: usize = 100,
    batch_timeout_ms: u64 = 1000,
    warning_batch: std.ArrayList(Warning),
    last_flush: i64,
    
    pub fn handleWarning(self: *Self, warning: Warning) !void {
        try self.warning_batch.append(warning);
        
        const now = std.time.milliTimestamp();
        if (self.warning_batch.items.len >= self.batch_size or
            now - self.last_flush > self.batch_timeout_ms) {
            try self.flushBatch();
        }
    }
    
    fn flushBatch(self: *Self) !void {
        if (self.warning_batch.items.len == 0) return;
        
        // Process batch efficiently
        try self.processBatch(self.warning_batch.items);
        
        self.warning_batch.clearRetainingCapacity();
        self.last_flush = std.time.milliTimestamp();
    }
};
```

### 3. Memory Management

```zig
pub const WarningMemoryPool = struct {
    const Self = @This();
    
    allocator: std.mem.Allocator,
    warning_pool: ObjectPool(Warning, 1000),
    string_arena: std.heap.ArenaAllocator,
    
    pub fn allocateWarning(self: *Self) !*Warning {
        return self.warning_pool.acquire() orelse {
            return self.allocator.create(Warning);
        };
    }
    
    pub fn deallocateWarning(self: *Self, warning: *Warning) void {
        warning.metadata.deinit();
        self.warning_pool.release(warning);
    }
    
    pub fn allocateString(self: *Self, str: []const u8) ![]const u8 {
        return self.string_arena.allocator().dupe(u8, str);
    }
};
```

---

## Testing and Validation

### 1. Unit Tests

```zig
test "warning handler processes messages correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var processor = try WarningProcessor.init(allocator);
    defer processor.deinit();
    
    var handler = try LuaWarningHandler.init(allocator, processor);
    defer handler.deinit();
    
    // Test control messages
    try handler.handleWarning("@off", false);
    try testing.expect(!handler.enabled);
    
    try handler.handleWarning("@on", false);
    try testing.expect(handler.enabled);
    
    // Test warning message
    try handler.handleWarning("[test.lua:42] DEPRECATION: Old API usage", false);
    try testing.expect(handler.warning_count == 1);
}

test "warning categorization" {
    var handler = try LuaWarningHandler.init(testing.allocator, undefined);
    defer handler.deinit();
    
    const cases = .{
        .{ "DEPRECATION: Old function", .deprecation },
        .{ "SECURITY: SQL injection risk", .security },
        .{ "PERFORMANCE: Slow query", .performance },
        .{ "undefined behavior detected", .undefined_behavior },
        .{ "implicit conversion", .type_mismatch },
        .{ "random message", .unknown },
    };
    
    inline for (cases) |case| {
        const category = handler.categorizeWarning(case[0]);
        try testing.expect(category == case[1]);
    }
}

test "warning filtering" {
    var filter = CategoryFilter.init(std.EnumSet(WarningCategory).init(.{
        .security = true,
        .undefined_behavior = true,
    }));
    
    const security_warning = Warning{
        .message = "Security issue",
        .category = .security,
        .severity = .error,
        .source_location = null,
        .timestamp = 0,
        .metadata = undefined,
    };
    
    const perf_warning = Warning{
        .message = "Performance issue",
        .category = .performance,
        .severity = .info,
        .source_location = null,
        .timestamp = 0,
        .metadata = undefined,
    };
    
    try testing.expect(try filter.filter.shouldProcess(security_warning));
    try testing.expect(!try filter.filter.shouldProcess(perf_warning));
}
```

### 2. Integration Tests

```zig
test "Lua warning system integration" {
    var engine = try LuaEngine.init(testing.allocator, .{
        .enable_warnings = true,
        .warning_categories = std.EnumSet(WarningCategory).init(.{
            .deprecation = true,
            .security = true,
            .undefined_behavior = true,
        }),
    });
    defer engine.deinit();
    
    const script = 
        \\-- Enable warnings
        \\warn("@on")
        \\
        \\-- Custom warning
        \\warn("SECURITY: Accessing sensitive data")
        \\
        \\-- Trigger built-in warning (if available)
        \\local t = {1, 2, 3}
        \\for k, v in pairs(t) do
        \\    t[k] = nil  -- May trigger traversal warning
        \\end
    ;
    
    const context = try ScriptContext.init(testing.allocator, .{});
    defer context.deinit();
    
    _ = try engine.executeScript(script, context);
    
    // Check that warnings were processed
    const metrics = engine.warning_handler.processor.metrics.getMetrics();
    try testing.expect(metrics.total_warnings > 0);
    try testing.expect(metrics.warnings_per_category.get(.security) >= 1);
}
```

### 3. Performance Benchmarks

```zig
test "warning system performance impact" {
    var engine_no_warnings = try LuaEngine.init(testing.allocator, .{
        .enable_warnings = false,
    });
    defer engine_no_warnings.deinit();
    
    var engine_with_warnings = try LuaEngine.init(testing.allocator, .{
        .enable_warnings = true,
    });
    defer engine_with_warnings.deinit();
    
    const script = 
        \\local sum = 0
        \\for i = 1, 1000000 do
        \\    sum = sum + i
        \\end
        \\return sum
    ;
    
    // Benchmark without warnings
    const start_no_warn = std.time.nanoTimestamp();
    _ = try engine_no_warnings.executeScript(script, context);
    const time_no_warn = std.time.nanoTimestamp() - start_no_warn;
    
    // Benchmark with warnings
    const start_warn = std.time.nanoTimestamp();
    _ = try engine_with_warnings.executeScript(script, context);
    const time_warn = std.time.nanoTimestamp() - start_warn;
    
    const overhead_percent = @as(f64, @floatFromInt(time_warn - time_no_warn)) /
                            @as(f64, @floatFromInt(time_no_warn)) * 100.0;
    
    std.debug.print("Warning system overhead: {d:.2}%\n", .{overhead_percent});
    try testing.expect(overhead_percent < 5.0); // Less than 5% overhead
}
```

---

## Best Practices and Recommendations

### 1. Warning Configuration

```zig
pub const WarningConfig = struct {
    // Enable/disable entire warning system
    enabled: bool = true,
    
    // Categories to monitor
    enabled_categories: std.EnumSet(WarningCategory) = std.EnumSet(WarningCategory).initFull(),
    
    // Rate limiting
    max_warnings_per_second: f64 = 100.0,
    
    // Batching for performance
    batch_warnings: bool = true,
    batch_size: usize = 100,
    batch_timeout_ms: u64 = 1000,
    
    // Storage
    persist_warnings: bool = false,
    max_stored_warnings: usize = 10000,
    
    // Alerting
    alert_on_critical: bool = true,
    critical_categories: std.EnumSet(WarningCategory) = std.EnumSet(WarningCategory).init(.{
        .security = true,
        .undefined_behavior = true,
    }),
    
    pub fn production() WarningConfig {
        return .{
            .enabled = true,
            .enabled_categories = std.EnumSet(WarningCategory).init(.{
                .security = true,
                .undefined_behavior = true,
                .deprecation = true,
            }),
            .max_warnings_per_second = 10.0,
            .batch_warnings = true,
            .persist_warnings = true,
            .alert_on_critical = true,
        };
    }
    
    pub fn development() WarningConfig {
        return .{
            .enabled = true,
            .enabled_categories = std.EnumSet(WarningCategory).initFull(),
            .max_warnings_per_second = 1000.0,
            .batch_warnings = false,
            .persist_warnings = false,
            .alert_on_critical = false,
        };
    }
};
```

### 2. Custom Warning Guidelines

```lua
-- Use consistent prefixes for categorization
warn("DEPRECATION: Function 'oldAPI' will be removed in v2.0")
warn("SECURITY: Potential SQL injection in query construction")
warn("PERFORMANCE: Table scan detected, consider adding index")

-- Include context in warnings
warn(string.format("PERFORMANCE: Query took %dms (threshold: %dms)", elapsed, threshold))

-- Use structured data when possible
warn("METRIC: " .. json.encode({
    type = "slow_query",
    duration_ms = elapsed,
    query_hash = hash,
    timestamp = os.time()
}))
```

### 3. Integration Patterns

```zig
// Engine initialization with warning support
pub fn createLuaEngineWithWarnings(allocator: std.mem.Allocator, config: EngineConfig) !*LuaEngine {
    const engine = try LuaEngine.init(allocator, config);
    
    // Set up warning processor
    const processor = try WarningProcessor.init(allocator);
    
    // Add filters
    if (config.warning_config.enabled_categories) |categories| {
        const filter = try allocator.create(CategoryFilter);
        filter.* = CategoryFilter.init(categories);
        try processor.addFilter(&filter.filter);
    }
    
    if (config.warning_config.max_warnings_per_second) |rate| {
        const filter = try RateLimitFilter.init(rate);
        try processor.addFilter(&filter.filter);
    }
    
    // Add handlers
    if (config.warning_config.alert_on_critical) {
        const handler = try allocator.create(AlertHandler);
        handler.* = AlertHandler.init(engine.alert_system, .error);
        try processor.addHandler(&handler.handler);
    }
    
    if (config.warning_config.persist_warnings) {
        const handler = try allocator.create(PersistenceHandler);
        handler.* = PersistenceHandler.init(engine.warning_storage);
        try processor.addHandler(&handler.handler);
    }
    
    // Create warning handler
    engine.warning_handler = try LuaWarningHandler.init(allocator, processor);
    
    // Register with Lua
    c.lua_setwarnf(
        engine.main_state,
        LuaWarningHandler.warnCallback,
        engine.warning_handler
    );
    
    return engine;
}
```

### 4. Monitoring and Alerting

```zig
pub const WarningMonitor = struct {
    const Self = @This();
    
    metrics: *WarningMetrics,
    thresholds: WarningThresholds,
    alert_system: *AlertSystem,
    
    pub fn checkHealthStatus(self: *Self) !HealthStatus {
        const snapshot = self.metrics.getMetrics();
        
        // Check warning rate
        if (snapshot.warning_rate > self.thresholds.max_rate) {
            try self.alert_system.sendAlert(.{
                .title = "High Lua warning rate",
                .message = try std.fmt.allocPrint(
                    self.allocator,
                    "Warning rate: {d:.2}/s (threshold: {d:.2}/s)",
                    .{ snapshot.warning_rate, self.thresholds.max_rate }
                ),
                .severity = .warning,
            });
            return .degraded;
        }
        
        // Check critical categories
        for (self.thresholds.critical_categories.iterator()) |category| {
            const count = snapshot.warnings_per_category.get(category) orelse 0;
            if (count > 0) {
                try self.alert_system.sendAlert(.{
                    .title = "Critical Lua warnings detected",
                    .message = try std.fmt.allocPrint(
                        self.allocator,
                        "{s} warnings: {} occurrences",
                        .{ @tagName(category), count }
                    ),
                    .severity = .error,
                });
                return .unhealthy;
            }
        }
        
        return .healthy;
    }
};
```

## Conclusion

The Lua 5.4 warning system integration provides valuable runtime diagnostics without performance penalties. Key benefits:

1. **Early Detection**: Identify potential issues before they become errors
2. **Production Safety**: Non-blocking warnings suitable for production use  
3. **Flexible Filtering**: Control warning noise with category and rate filters
4. **Structured Logging**: Convert string warnings to structured log entries
5. **Metrics Integration**: Track warning patterns and trends
6. **Custom Handlers**: Extensible system for application-specific needs

The implementation seamlessly integrates with zig_llms' existing logging, metrics, and alerting systems while maintaining the lightweight nature of the Lua scripting engine.