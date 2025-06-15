# Lua Scripting Engine Security Sandboxing Design

## Executive Summary

This document outlines a comprehensive, multi-layered security sandboxing approach for the zig_llms Lua scripting engine. The design prioritizes defense-in-depth, integrating seamlessly with existing zig_llms security infrastructure while addressing all known attack vectors and vulnerabilities specific to Lua environments.

## Table of Contents

1. [Security Threat Analysis](#security-threat-analysis)
2. [Multi-Layer Security Architecture](#multi-layer-security-architecture)
3. [Environment Isolation Strategy](#environment-isolation-strategy)
4. [Bytecode Security Framework](#bytecode-security-framework)
5. [Resource Management System](#resource-management-system)
6. [Module Loading Security](#module-loading-security)
7. [Metatable Protection](#metatable-protection)
8. [String Pattern Safety](#string-pattern-safety)
9. [Integration with zig_llms Security](#integration-with-zig_llms-security)
10. [Performance Optimization](#performance-optimization)
11. [Implementation Roadmap](#implementation-roadmap)

---

## Security Threat Analysis

### 1. Primary Attack Vectors

#### Environment Pollution
- **CVE-2022-0543**: Redis Lua sandbox escape via uncleaned `package` variable
- **Global contamination**: Modifying shared environments across sandbox boundaries
- **Metatable poisoning**: Corrupting string metatables affecting external code
- **Function environment escape**: Using `getfenv`/`setfenv` to access parent scopes

#### Bytecode Injection
- **Malicious bytecode**: Crafted binary chunks causing interpreter crashes or RCE
- **Validation bypass**: Exploiting lack of bytecode consistency checks
- **Load function abuse**: Using `load()` with binary data to execute arbitrary code
- **String.dump exploitation**: Manipulating serialized function bytecode

#### Resource Exhaustion
- **Infinite loops**: CPU consumption without instruction counting limits
- **Memory bombs**: Unbounded memory allocation through table creation
- **ReDoS attacks**: Exponential backtracking in string pattern matching
- **GC manipulation**: Abuse of `__gc` metamethods for persistent execution

#### Sandbox Escape Techniques
- **Debug library access**: Using `debug.*` functions to break containment
- **Parent traversal**: Following object parent chains to escape sandbox
- **Module system abuse**: Exploiting `require()` and `package.*` for file access
- **Coroutine manipulation**: Using coroutines to bypass execution limits

### 2. Common Vulnerable Functions

```lua
-- CRITICAL: Complete removal required
debug.*           -- All debug library functions
loadstring        -- Bytecode execution
load              -- Bytecode and string loading
dofile            -- File execution
loadfile          -- File loading
getfenv           -- Environment access
setfenv           -- Environment modification
rawget/rawset     -- Metatable bypass
require           -- Module loading
module            -- Module creation

-- HIGH RISK: Restricted access required
string.dump       -- Function serialization
collectgarbage    -- GC control
coroutine.*       -- Coroutine manipulation
os.*              -- System access
io.*              -- File I/O
package.*         -- Package management

-- MEDIUM RISK: Monitoring required
string.match      -- Pattern matching (ReDoS)
string.gmatch     -- Global pattern matching
string.gsub       -- Pattern substitution
string.find       -- Pattern searching
```

---

## Multi-Layer Security Architecture

### Layer 1: Engine-Level Security
```zig
pub const LuaSecurityLevel = enum {
    none,        // No restrictions (development only)
    restricted,  // Standard restrictions
    strict,      // Maximum security
    paranoid,    // Ultra-restrictive for untrusted code
};

pub const LuaSecurityPolicy = struct {
    level: LuaSecurityLevel,
    
    // Environment isolation
    isolated_globals: bool = true,
    custom_env_table: bool = true,
    block_env_access: bool = true,
    
    // Function restrictions
    whitelist_functions: bool = true,
    allow_debug_functions: bool = false,
    allow_load_functions: bool = false,
    allow_file_functions: bool = false,
    
    // Bytecode security
    validate_bytecode: bool = true,
    block_binary_chunks: bool = true,
    require_source_mode: bool = true,
    
    // Resource limits
    enable_instruction_counting: bool = true,
    enable_memory_tracking: bool = true,
    enable_execution_timeout: bool = true,
    
    // Module system
    restrict_require: bool = true,
    custom_module_loader: bool = true,
    whitelist_modules: ?[]const []const u8 = null,
    
    // Metatable protection
    protect_string_metatable: bool = true,
    block_metatable_access: bool = true,
    sandbox_metamethods: bool = true,
    
    // Pattern matching
    limit_pattern_complexity: bool = true,
    timeout_pattern_matching: bool = true,
    
    pub fn forSandboxLevel(level: SandboxLevel) LuaSecurityPolicy {
        return switch (level) {
            .none => LuaSecurityPolicy{
                .level = .none,
                .isolated_globals = false,
                .whitelist_functions = false,
                .validate_bytecode = false,
                .enable_instruction_counting = false,
            },
            .restricted => LuaSecurityPolicy{
                .level = .restricted,
                // Use struct defaults (secure by default)
            },
            .strict => LuaSecurityPolicy{
                .level = .strict,
                .block_env_access = true,
                .allow_debug_functions = false,
                .allow_load_functions = false,
                .block_binary_chunks = true,
                .enable_instruction_counting = true,
                .limit_pattern_complexity = true,
            },
        };
    }
};
```

### Layer 2: Context-Level Security
```zig
pub const LuaSecurityContext = struct {
    policy: LuaSecurityPolicy,
    resource_monitor: *ResourceMonitor,
    function_whitelist: std.StringHashMap(bool),
    module_whitelist: std.StringHashMap(bool),
    
    // Execution state
    instruction_count: u64 = 0,
    max_instructions: u64 = 1000000,
    start_time: i64,
    timeout_ms: u32 = 30000,
    
    // Memory tracking
    allocated_bytes: usize = 0,
    max_memory_bytes: usize = 10 * 1024 * 1024, // 10MB
    allocation_count: usize = 0,
    
    pub fn checkResourceLimits(self: *LuaSecurityContext) !void {
        // Check instruction count
        if (self.instruction_count > self.max_instructions) {
            return error.InstructionLimitExceeded;
        }
        
        // Check timeout
        const elapsed = std.time.milliTimestamp() - self.start_time;
        if (elapsed > self.timeout_ms) {
            return error.ExecutionTimeout;
        }
        
        // Check memory
        if (self.allocated_bytes > self.max_memory_bytes) {
            return error.MemoryLimitExceeded;
        }
    }
};
```

---

## Environment Isolation Strategy

### 1. Custom Environment Creation
```c
// Create isolated environment table
static int create_sandbox_env(lua_State *L, const LuaSecurityPolicy *policy) {
    // Create new environment table
    lua_createtable(L, 0, 50);
    int env_index = lua_gettop(L);
    
    // Add safe functions only
    if (policy->whitelist_functions) {
        // Math library (safe)
        lua_getglobal(L, "math");
        lua_setfield(L, env_index, "math");
        
        // String library (filtered)
        create_safe_string_library(L, policy);
        lua_setfield(L, env_index, "string");
        
        // Table library (filtered)
        create_safe_table_library(L);
        lua_setfield(L, env_index, "table");
        
        // Basic functions (filtered)
        add_safe_basic_functions(L, env_index, policy);
    }
    
    // Set metatable to prevent leakage
    lua_createtable(L, 0, 2);
    lua_pushstring(L, "__index");
    lua_pushcfunction(L, sandbox_env_index);
    lua_settable(L, -3);
    lua_pushstring(L, "__newindex");
    lua_pushcfunction(L, sandbox_env_newindex);
    lua_settable(L, -3);
    lua_setmetatable(L, env_index);
    
    return env_index;
}

// Controlled environment access
static int sandbox_env_index(lua_State *L) {
    const char *key = luaL_checkstring(L, 2);
    LuaSecurityContext *ctx = get_security_context(L);
    
    // Check if key is whitelisted
    if (!is_function_allowed(ctx, key)) {
        luaL_error(L, "Access to '%s' is not permitted", key);
        return 0;
    }
    
    // Log access attempt
    log_env_access(ctx, key, "read");
    
    // Return nil for unauthorized access
    lua_pushnil(L);
    return 1;
}

static int sandbox_env_newindex(lua_State *L) {
    const char *key = luaL_checkstring(L, 2);
    LuaSecurityContext *ctx = get_security_context(L);
    
    // Check if modification is allowed
    if (!is_global_modification_allowed(ctx, key)) {
        luaL_error(L, "Modification of '%s' is not permitted", key);
        return 0;
    }
    
    // Log modification
    log_env_access(ctx, key, "write");
    
    // Store in sandbox-local table
    lua_rawset(L, 1);
    return 0;
}
```

### 2. Function Whitelisting
```c
// Safe function definitions
static const char* SAFE_BASIC_FUNCTIONS[] = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall",
    "select", "tonumber", "tostring", "type", "unpack",
    NULL
};

static const char* SAFE_STRING_FUNCTIONS[] = {
    "byte", "char", "format", "len", "lower", "rep", "reverse", 
    "sub", "upper",
    // Pattern functions excluded by default due to ReDoS risk
    NULL
};

static const char* SAFE_TABLE_FUNCTIONS[] = {
    "concat", "insert", "remove", "sort",
    // pack/unpack handled separately
    NULL
};

static const char* BLOCKED_FUNCTIONS[] = {
    // Debug library
    "debug", "getfenv", "setfenv",
    // Loading functions
    "load", "loadfile", "loadstring", "dofile",
    // System access
    "require", "module",
    // Metatable access
    "getmetatable", "setmetatable", "rawget", "rawset",
    // Garbage collection
    "collectgarbage",
    NULL
};
```

---

## Bytecode Security Framework

### 1. Bytecode Validation
```c
// Bytecode security checker
static int secure_load_function(lua_State *L) {
    size_t len;
    const char *chunk = luaL_checklstring(L, 1, &len);
    const char *chunkname = luaL_optstring(L, 2, "chunk");
    const char *mode = luaL_optstring(L, 3, "t"); // Force text mode
    
    LuaSecurityContext *ctx = get_security_context(L);
    
    // Check if loading is permitted
    if (!ctx->policy.allow_load_functions) {
        return luaL_error(L, "Loading code is not permitted in this sandbox");
    }
    
    // Validate bytecode signature
    if (len > 0 && chunk[0] == LUA_SIGNATURE[0]) {
        if (ctx->policy.block_binary_chunks) {
            return luaL_error(L, "Binary chunks are not permitted");
        }
        
        // Validate bytecode structure
        if (!validate_lua_bytecode(chunk, len)) {
            return luaL_error(L, "Invalid or malicious bytecode detected");
        }
    }
    
    // Force text-only mode for maximum security
    if (ctx->policy.require_source_mode) {
        mode = "t";
    }
    
    // Load with restricted environment
    int result = lua_load(L, chunk_reader, (void*)chunk, chunkname, mode);
    if (result != LUA_OK) {
        return lua_error(L);
    }
    
    // Set sandbox environment
    lua_pushvalue(L, lua_upvalueindex(1)); // sandbox env
    lua_setupvalue(L, -2, 1); // _ENV
    
    return 1;
}

// Bytecode validation (simplified)
static bool validate_lua_bytecode(const char *chunk, size_t len) {
    if (len < 12) return false; // Minimum header size
    
    // Check Lua signature
    if (memcmp(chunk, LUA_SIGNATURE, 4) != 0) return false;
    
    // Check version compatibility
    if (chunk[4] != LUAC_VERSION) return false;
    
    // Check format version
    if (chunk[5] != LUAC_FORMAT) return false;
    
    // Additional integrity checks would go here
    // This is a simplified example
    
    return true;
}
```

### 2. Safe Loading Wrapper
```c
// Replace standard load functions
static const luaL_Reg secure_loaders[] = {
    {"load", secure_load_function},
    {"loadstring", secure_load_function}, // Redirect to same function
    {"dofile", blocked_function},
    {"loadfile", blocked_function},
    {NULL, NULL}
};

static int blocked_function(lua_State *L) {
    const char *func_name = lua_tostring(L, lua_upvalueindex(1));
    return luaL_error(L, "Function '%s' is blocked in sandbox", func_name);
}
```

---

## Resource Management System

### 1. Instruction Counting with lua_sethook
```c
// Hook function for instruction counting
static void instruction_count_hook(lua_State *L, lua_Debug *ar) {
    LuaSecurityContext *ctx = get_security_context(L);
    if (!ctx) return;
    
    ctx->instruction_count++;
    
    // Check resource limits periodically
    if (ctx->instruction_count % 10000 == 0) {
        // Check timeout
        int64_t elapsed = get_time_ms() - ctx->start_time;
        if (elapsed > ctx->timeout_ms) {
            luaL_error(L, "Execution timeout exceeded (%d ms)", ctx->timeout_ms);
        }
        
        // Check memory usage
        if (ctx->allocated_bytes > ctx->max_memory_bytes) {
            luaL_error(L, "Memory limit exceeded (%zu bytes)", ctx->max_memory_bytes);
        }
        
        // Check instruction count
        if (ctx->instruction_count > ctx->max_instructions) {
            luaL_error(L, "Instruction limit exceeded (%lld instructions)", 
                      ctx->max_instructions);
        }
    }
}

// Set up instruction counting
static void setup_resource_monitoring(lua_State *L, LuaSecurityContext *ctx) {
    if (ctx->policy.enable_instruction_counting) {
        // Set hook for every 1000 instructions
        lua_sethook(L, instruction_count_hook, LUA_MASKCOUNT, 1000);
    }
    
    if (ctx->policy.enable_execution_timeout) {
        ctx->start_time = get_time_ms();
    }
}
```

### 2. Memory Tracking
```c
// Custom allocator for memory tracking
static void *secure_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    LuaSecurityContext *ctx = (LuaSecurityContext *)ud;
    
    if (nsize == 0) {
        // Freeing memory
        if (ptr) {
            ctx->allocated_bytes -= osize;
            free(ptr);
        }
        return NULL;
    }
    
    // Check memory limit before allocation
    if (ptr == NULL) {
        // New allocation
        if (ctx->allocated_bytes + nsize > ctx->max_memory_bytes) {
            return NULL; // Trigger Lua memory error
        }
        ctx->allocation_count++;
    } else {
        // Reallocation
        size_t size_diff = (nsize > osize) ? (nsize - osize) : 0;
        if (ctx->allocated_bytes + size_diff > ctx->max_memory_bytes) {
            return NULL;
        }
    }
    
    // Perform allocation
    void *new_ptr = realloc(ptr, nsize);
    if (new_ptr) {
        ctx->allocated_bytes = ctx->allocated_bytes - osize + nsize;
    }
    
    return new_ptr;
}
```

---

## Module Loading Security

### 1. Custom Module Loader
```c
// Secure require implementation
static int secure_require(lua_State *L) {
    const char *module_name = luaL_checkstring(L, 1);
    LuaSecurityContext *ctx = get_security_context(L);
    
    // Check if module is whitelisted
    if (!is_module_allowed(ctx, module_name)) {
        return luaL_error(L, "Module '%s' is not permitted", module_name);
    }
    
    // Check if already loaded
    lua_getfield(L, LUA_REGISTRYINDEX, "_LOADED");
    lua_getfield(L, -1, module_name);
    if (!lua_isnil(L, -1)) {
        return 1; // Return cached module
    }
    lua_pop(L, 2);
    
    // Load from secure module registry
    return load_secure_module(L, module_name);
}

// Module whitelist check
static bool is_module_allowed(LuaSecurityContext *ctx, const char *module_name) {
    // Check against whitelist
    if (ctx->policy.whitelist_modules) {
        for (size_t i = 0; ctx->policy.whitelist_modules[i]; i++) {
            if (strcmp(ctx->policy.whitelist_modules[i], module_name) == 0) {
                return true;
            }
        }
        return false;
    }
    
    // Default allowed modules
    static const char* DEFAULT_ALLOWED[] = {
        "zigllms.agent", "zigllms.tool", "zigllms.workflow",
        "zigllms.event", "zigllms.schema", "zigllms.memory",
        NULL
    };
    
    for (size_t i = 0; DEFAULT_ALLOWED[i]; i++) {
        if (strcmp(DEFAULT_ALLOWED[i], module_name) == 0) {
            return true;
        }
    }
    
    return false;
}
```

### 2. Secure Package System
```c
// Replace package.searchers with secure version
static void setup_secure_package_system(lua_State *L) {
    // Get package table
    lua_getglobal(L, "package");
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1);
        return;
    }
    
    // Clear dangerous fields
    lua_pushnil(L);
    lua_setfield(L, -2, "loadlib");
    lua_pushnil(L);
    lua_setfield(L, -2, "path");
    lua_pushnil(L);
    lua_setfield(L, -2, "cpath");
    
    // Create secure searchers table
    lua_createtable(L, 1, 0);
    lua_pushcfunction(L, secure_module_searcher);
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "searchers");
    
    lua_pop(L, 1); // pop package table
}

static int secure_module_searcher(lua_State *L) {
    const char *module_name = luaL_checkstring(L, 1);
    LuaSecurityContext *ctx = get_security_context(L);
    
    // Check whitelist
    if (!is_module_allowed(ctx, module_name)) {
        lua_pushfstring(L, "Module '%s' not found (not whitelisted)", module_name);
        return 1;
    }
    
    // Return loader function
    lua_pushcfunction(L, secure_module_loader);
    lua_pushstring(L, module_name);
    return 2;
}
```

---

## Metatable Protection

### 1. String Metatable Protection
```c
// Protect string metatable from modification
static void protect_string_metatable(lua_State *L) {
    // Get string metatable
    lua_pushliteral(L, "");
    lua_getmetatable(L, -1);
    
    if (lua_istable(L, -1)) {
        // Set __metatable to prevent access
        lua_pushliteral(L, "protected");
        lua_setfield(L, -2, "__metatable");
        
        // Remove dangerous metamethods
        lua_pushnil(L);
        lua_setfield(L, -2, "__index");
        lua_pushnil(L);
        lua_setfield(L, -2, "__newindex");
    }
    
    lua_pop(L, 2); // pop metatable and string
}

// Controlled metatable access
static int secure_getmetatable(lua_State *L) {
    LuaSecurityContext *ctx = get_security_context(L);
    
    if (!ctx->policy.block_metatable_access) {
        return lua_getmetatable(L, 1) ? 1 : 0;
    }
    
    // Check if access is allowed for this object type
    int obj_type = lua_type(L, 1);
    if (obj_type == LUA_TSTRING) {
        return luaL_error(L, "Access to string metatable is restricted");
    }
    
    return lua_getmetatable(L, 1) ? 1 : 0;
}

static int secure_setmetatable(lua_State *L) {
    LuaSecurityContext *ctx = get_security_context(L);
    
    if (ctx->policy.block_metatable_access) {
        return luaL_error(L, "Metatable modification is not permitted");
    }
    
    return lua_setmetatable(L, 1);
}
```

### 2. Metamethod Sandboxing
```c
// Wrap metamethods to prevent escape
static int safe_metamethod_wrapper(lua_State *L) {
    // Get original metamethod
    lua_pushvalue(L, lua_upvalueindex(1));
    
    // Copy arguments
    int nargs = lua_gettop(L);
    for (int i = 1; i <= nargs; i++) {
        lua_pushvalue(L, i);
    }
    
    // Call original metamethod in protected mode
    int result = lua_pcall(L, nargs, LUA_MULTRET, 0);
    if (result != LUA_OK) {
        lua_error(L); // Re-throw error
    }
    
    return lua_gettop(L) - nargs;
}
```

---

## String Pattern Safety

### 1. ReDoS Prevention
```c
// Pattern complexity analyzer
static bool is_pattern_safe(const char *pattern) {
    size_t len = strlen(pattern);
    int nesting_level = 0;
    int quantifier_count = 0;
    
    for (size_t i = 0; i < len; i++) {
        switch (pattern[i]) {
            case '(':
                nesting_level++;
                if (nesting_level > 5) return false; // Max nesting
                break;
            case ')':
                nesting_level--;
                break;
            case '*':
            case '+':
            case '?':
                quantifier_count++;
                if (quantifier_count > 10) return false; // Max quantifiers
                break;
            case '-':
                if (i > 0 && pattern[i-1] == ']') break; // Character class
                quantifier_count++;
                if (quantifier_count > 10) return false;
                break;
        }
        
        // Check for dangerous patterns
        if (i < len - 1) {
            // Nested quantifiers (catastrophic backtracking)
            if ((pattern[i] == '*' || pattern[i] == '+') &&
                (pattern[i+1] == '*' || pattern[i+1] == '+')) {
                return false;
            }
        }
    }
    
    return true;
}

// Secure pattern matching with timeout
static int secure_string_match(lua_State *L) {
    const char *str = luaL_checkstring(L, 1);
    const char *pattern = luaL_checkstring(L, 2);
    LuaSecurityContext *ctx = get_security_context(L);
    
    // Check pattern safety
    if (ctx->policy.limit_pattern_complexity && !is_pattern_safe(pattern)) {
        return luaL_error(L, "Pattern too complex or potentially dangerous");
    }
    
    // Set timeout for pattern matching
    if (ctx->policy.timeout_pattern_matching) {
        int64_t start_time = get_time_ms();
        
        // This would need integration with Lua's pattern matcher
        // to check timeout during execution
        
        // For now, limit string length
        if (strlen(str) > 10000) {
            return luaL_error(L, "String too long for pattern matching");
        }
    }
    
    // Perform the actual pattern matching
    return original_string_match(L);
}
```

### 2. Pattern Function Wrapping
```c
// Wrap dangerous string functions
static const luaL_Reg secure_string_functions[] = {
    {"match", secure_string_match},
    {"gmatch", secure_string_gmatch},
    {"gsub", secure_string_gsub},
    {"find", secure_string_find},
    // Safe functions
    {"byte", original_string_byte},
    {"char", original_string_char},
    {"format", original_string_format},
    {"len", original_string_len},
    {"lower", original_string_lower},
    {"rep", original_string_rep},
    {"reverse", original_string_reverse},
    {"sub", original_string_sub},
    {"upper", original_string_upper},
    {NULL, NULL}
};
```

---

## Integration with zig_llms Security

### 1. SecurityPermissions Integration
```zig
pub fn createLuaSecurityPolicy(
    permissions: SecurityPermissions, 
    limits: ResourceLimits
) LuaSecurityPolicy {
    return LuaSecurityPolicy{
        .level = switch (permissions.max_stack_depth) {
            0...500 => .strict,
            501...1000 => .restricted,
            else => .none,
        },
        
        // Map permissions to Lua security settings
        .allow_file_functions = permissions.file_read or permissions.file_write,
        .allow_debug_functions = false, // Never allow debug in production
        .allow_load_functions = permissions.native_modules,
        
        // Resource limits mapping
        .max_instructions = limits.max_allocations,
        .timeout_ms = limits.max_execution_time_ms,
        .max_memory_bytes = limits.max_memory_bytes,
        
        // Module restrictions
        .whitelist_modules = permissions.allowed_modules,
        .restrict_require = !permissions.native_modules,
        
        // Enhanced security for network/process permissions
        .block_env_access = permissions.network_access or permissions.process_execute,
        .validate_bytecode = true,
        .enable_instruction_counting = true,
    };
}
```

### 2. Context Integration
```zig
pub fn setupLuaSecurityContext(
    context: *ScriptContext,
    lua_state: *c.lua_State
) !void {
    const security_policy = createLuaSecurityPolicy(
        context.permissions,
        context.limits
    );
    
    // Create security context
    const lua_ctx = try context.allocator.create(LuaSecurityContext);
    lua_ctx.* = LuaSecurityContext{
        .policy = security_policy,
        .resource_monitor = try ResourceMonitor.init(context.allocator),
        .function_whitelist = std.StringHashMap(bool).init(context.allocator),
        .module_whitelist = std.StringHashMap(bool).init(context.allocator),
        .max_instructions = security_policy.max_instructions,
        .timeout_ms = security_policy.timeout_ms,
        .max_memory_bytes = security_policy.max_memory_bytes,
    };
    
    // Set up Lua state with security context
    c.lua_pushlightuserdata(lua_state, lua_ctx);
    c.lua_setfield(lua_state, c.LUA_REGISTRYINDEX, "SECURITY_CONTEXT");
    
    // Initialize security measures
    try setupLuaEnvironment(lua_state, lua_ctx);
    try setupResourceMonitoring(lua_state, lua_ctx);
    try setupModuleSecurity(lua_state, lua_ctx);
}
```

### 3. Error Bridge Integration
```zig
pub fn handleLuaSecurityError(
    context: *ScriptContext,
    lua_error: []const u8
) ScriptError {
    if (std.mem.indexOf(u8, lua_error, "timeout") != null) {
        return ScriptError{
            .type = .timeout,
            .message = try context.allocator.dupe(u8, "Script execution timeout"),
            .stack_trace = try context.allocator.dupe(u8, lua_error),
            .source_location = .{
                .file = "lua_script",
                .line = 0,
                .column = 0,
            },
        };
    }
    
    if (std.mem.indexOf(u8, lua_error, "Memory limit") != null) {
        return ScriptError{
            .type = .resource_limit,
            .message = try context.allocator.dupe(u8, "Memory limit exceeded"),
            .stack_trace = try context.allocator.dupe(u8, lua_error),
            .source_location = .{
                .file = "lua_script",
                .line = 0,
                .column = 0,
            },
        };
    }
    
    if (std.mem.indexOf(u8, lua_error, "not permitted") != null) {
        return ScriptError{
            .type = .security_violation,
            .message = try context.allocator.dupe(u8, "Security policy violation"),
            .stack_trace = try context.allocator.dupe(u8, lua_error),
            .source_location = .{
                .file = "lua_script",
                .line = 0,
                .column = 0,
            },
        };
    }
    
    // Default error handling
    return ScriptError{
        .type = .runtime_error,
        .message = try context.allocator.dupe(u8, lua_error),
        .stack_trace = try context.allocator.dupe(u8, lua_error),
        .source_location = .{
            .file = "lua_script",
            .line = 0,
            .column = 0,
        },
    };
}
```

---

## Performance Optimization

### 1. Hook Frequency Optimization
```c
// Adaptive hook frequency based on workload
static void adjust_hook_frequency(lua_State *L, LuaSecurityContext *ctx) {
    static int base_frequency = 1000;
    int current_frequency = base_frequency;
    
    // Adjust based on execution time
    int64_t elapsed = get_time_ms() - ctx->start_time;
    if (elapsed < 100) {
        // Fast execution, reduce hook frequency
        current_frequency = base_frequency * 2;
    } else if (elapsed > 5000) {
        // Slow execution, increase monitoring
        current_frequency = base_frequency / 2;
    }
    
    // Adjust based on memory usage
    double memory_usage_ratio = (double)ctx->allocated_bytes / ctx->max_memory_bytes;
    if (memory_usage_ratio > 0.8) {
        // High memory usage, increase monitoring
        current_frequency = current_frequency / 2;
    }
    
    lua_sethook(L, instruction_count_hook, LUA_MASKCOUNT, current_frequency);
}
```

### 2. Function Caching
```c
// Cache frequently used security checks
typedef struct {
    const char *name;
    bool allowed;
    int64_t cache_time;
} FunctionCacheEntry;

static FunctionCacheEntry function_cache[256];
static int cache_size = 0;
static const int64_t CACHE_TTL_MS = 60000; // 1 minute

static bool is_function_allowed_cached(LuaSecurityContext *ctx, const char *name) {
    int64_t now = get_time_ms();
    
    // Check cache first
    for (int i = 0; i < cache_size; i++) {
        if (strcmp(function_cache[i].name, name) == 0) {
            if (now - function_cache[i].cache_time < CACHE_TTL_MS) {
                return function_cache[i].allowed;
            }
            // Cache expired, will refresh
            break;
        }
    }
    
    // Not in cache or expired, compute result
    bool allowed = is_function_allowed_uncached(ctx, name);
    
    // Add to cache
    if (cache_size < 256) {
        function_cache[cache_size].name = strdup(name);
        function_cache[cache_size].allowed = allowed;
        function_cache[cache_size].cache_time = now;
        cache_size++;
    }
    
    return allowed;
}
```

### 3. Memory Pool Optimization
```c
// Pre-allocated memory pools for common allocations
typedef struct {
    void *pool;
    size_t pool_size;
    size_t pool_used;
    size_t block_size;
} MemoryPool;

static MemoryPool small_blocks = {0}; // 64 bytes
static MemoryPool medium_blocks = {0}; // 512 bytes
static MemoryPool large_blocks = {0}; // 4096 bytes

static void *pool_alloc(MemoryPool *pool, size_t size) {
    if (size > pool->block_size) return NULL;
    if (pool->pool_used + size > pool->pool_size) return NULL;
    
    void *ptr = (char*)pool->pool + pool->pool_used;
    pool->pool_used += size;
    return ptr;
}

// Optimized allocator using pools
static void *optimized_secure_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    LuaSecurityContext *ctx = (LuaSecurityContext *)ud;
    
    if (nsize == 0) {
        // Freeing - update counters but don't actually free pools
        if (ptr) {
            ctx->allocated_bytes -= osize;
        }
        return NULL;
    }
    
    // Try pool allocation first for small allocations
    if (ptr == NULL && nsize <= 64) {
        void *pool_ptr = pool_alloc(&small_blocks, nsize);
        if (pool_ptr) {
            ctx->allocated_bytes += nsize;
            return pool_ptr;
        }
    }
    
    // Fall back to regular allocation
    return secure_alloc(ud, ptr, osize, nsize);
}
```

---

## Implementation Roadmap

### Phase 1: Core Security Infrastructure (Week 1)
1. **LuaSecurityPolicy and LuaSecurityContext structures**
   - Define security levels and policies
   - Create context management
   - Implement basic resource tracking

2. **Environment Isolation**
   - Create sandbox environment table
   - Implement controlled __index/__newindex
   - Set up function whitelisting

3. **Basic Resource Monitoring**
   - Implement instruction counting hook
   - Add timeout mechanism
   - Create memory tracking allocator

### Phase 2: Function and Module Security (Week 2)
1. **Function Restrictions**
   - Block dangerous functions (debug.*, load*, etc.)
   - Implement safe function wrappers
   - Create function whitelist system

2. **Module Loading Security**
   - Replace require() with secure version
   - Implement module whitelisting
   - Set up secure package system

3. **Bytecode Protection**
   - Add bytecode validation
   - Block binary chunk loading
   - Implement safe loading wrapper

### Phase 3: Advanced Protection (Week 3)
1. **Metatable Protection**
   - Protect string metatable
   - Implement controlled metatable access
   - Add metamethod sandboxing

2. **Pattern Matching Security**
   - Implement ReDoS prevention
   - Add pattern complexity analysis
   - Create secure string function wrappers

3. **Performance Optimization**
   - Implement adaptive hook frequency
   - Add function caching
   - Optimize memory allocation

### Phase 4: Integration and Testing (Week 4)
1. **zig_llms Integration**
   - Map SecurityPermissions to LuaSecurityPolicy
   - Integrate with ScriptContext
   - Connect to error handling system

2. **Comprehensive Testing**
   - Security vulnerability tests
   - Performance benchmarks
   - Integration test suite

3. **Documentation and Examples**
   - Security configuration guide
   - Best practices documentation
   - Example secure scripts

---

## Security Testing Framework

### 1. Vulnerability Test Suite
```zig
const SecurityTestSuite = struct {
    pub fn testEnvironmentEscape() !void {
        const malicious_code = 
            \\ debug.getregistry()._G.os.execute("echo pwned")
        ;
        
        const result = try executeLuaWithSecurity(malicious_code, .strict);
        try testing.expect(result.isError());
        try testing.expect(std.mem.indexOf(u8, result.error_message, "not permitted") != null);
    }
    
    pub fn testBytecodeInjection() !void {
        const bytecode = "\x1bLua"; // Lua bytecode signature
        
        const result = try executeLuaWithSecurity(bytecode, .strict);
        try testing.expect(result.isError());
        try testing.expect(std.mem.indexOf(u8, result.error_message, "Binary chunks") != null);
    }
    
    pub fn testResourceExhaustion() !void {
        const infinite_loop = "while true do end";
        
        const result = try executeLuaWithTimeout(infinite_loop, 1000); // 1 second
        try testing.expect(result.isError());
        try testing.expect(std.mem.indexOf(u8, result.error_message, "timeout") != null);
    }
    
    pub fn testMemoryBomb() !void {
        const memory_bomb = 
            \\ local t = {}
            \\ for i = 1, 1000000 do
            \\     t[i] = string.rep("A", 1000)
            \\ end
        ;
        
        const result = try executeLuaWithMemoryLimit(memory_bomb, 1024 * 1024); // 1MB
        try testing.expect(result.isError());
        try testing.expect(std.mem.indexOf(u8, result.error_message, "Memory limit") != null);
    }
    
    pub fn testPatternReDoS() !void {
        const redos_pattern = 
            \\ local s = string.rep("a", 30) .. "X"
            \\ string.match(s, "^(a+)+$")
        ;
        
        const result = try executeLuaWithPatternSafety(redos_pattern);
        try testing.expect(result.isError());
        try testing.expect(std.mem.indexOf(u8, result.error_message, "complex") != null);
    }
};
```

### 2. Performance Benchmarks
```zig
const SecurityBenchmarks = struct {
    pub fn benchmarkHookOverhead() !void {
        const simple_code = 
            \\ local sum = 0
            \\ for i = 1, 100000 do
            \\     sum = sum + i
            \\ end
            \\ return sum
        ;
        
        // Benchmark without security
        const start_time = std.time.nanoTimestamp();
        _ = try executeLua(simple_code);
        const unsecure_time = std.time.nanoTimestamp() - start_time;
        
        // Benchmark with security
        const secure_start = std.time.nanoTimestamp();
        _ = try executeLuaWithSecurity(simple_code, .restricted);
        const secure_time = std.time.nanoTimestamp() - secure_start;
        
        const overhead_percent = @as(f64, @floatFromInt(secure_time - unsecure_time)) / 
                                @as(f64, @floatFromInt(unsecure_time)) * 100.0;
        
        std.debug.print("Security overhead: {d:.2}%\n", .{overhead_percent});
        try testing.expect(overhead_percent < 50.0); // Max 50% overhead
    }
};
```

---

## Conclusion

This comprehensive security design provides a robust, multi-layered defense system for the zig_llms Lua scripting engine. The approach addresses all known attack vectors while maintaining integration with the existing security infrastructure.

Key strengths of this design:

1. **Defense in Depth**: Multiple security layers prevent single points of failure
2. **Performance Awareness**: Optimizations minimize security overhead
3. **Flexible Configuration**: Adaptable security levels for different use cases
4. **Comprehensive Coverage**: Addresses all known Lua security vulnerabilities
5. **Integration Ready**: Seamlessly integrates with existing zig_llms systems

The implementation roadmap provides a clear path to production-ready security, with extensive testing and benchmarking to ensure both security and performance requirements are met.

This design will enable zig_llms to safely execute untrusted Lua scripts while maintaining the flexibility and power that makes Lua an excellent choice for embedded scripting.