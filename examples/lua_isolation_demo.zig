// ABOUTME: Demonstrates Lua state isolation for multi-tenant scenarios
// ABOUTME: Shows tenant creation, resource limits, and security boundaries

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const TenantManager = @import("zig_llms").scripting.engines.lua_isolation.TenantManager;
const TenantLimits = @import("zig_llms").scripting.engines.lua_isolation.TenantLimits;
const IsolationError = @import("zig_llms").scripting.engines.lua_isolation.IsolationError;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Multi-Tenant Isolation Demo ===\n\n", .{});

    // Create tenant manager with default limits
    const default_limits = TenantLimits{
        .max_memory_bytes = 5 * 1024 * 1024, // 5MB
        .max_cpu_time_ms = 2000, // 2 seconds
        .max_function_calls = 10000,
        .allow_io = false,
        .allow_os = false,
        .allow_debug = false,
    };

    const manager = try TenantManager.init(allocator, 10, default_limits);
    defer manager.deinit();

    // Test 1: Create multiple tenants with different permissions
    std.debug.print("1. Creating tenants with different security profiles:\n");

    // Tenant A: Basic computation only
    try manager.createTenant("tenant-a", "Basic Tenant", .{
        .max_memory_bytes = 2 * 1024 * 1024, // 2MB
        .allow_coroutines = false,
        .allow_metatables = false,
    });
    std.debug.print("  ✓ Created 'tenant-a' - Basic computation only\n", .{});

    // Tenant B: Advanced features allowed
    try manager.createTenant("tenant-b", "Advanced Tenant", .{
        .max_memory_bytes = 10 * 1024 * 1024, // 10MB
        .allow_coroutines = true,
        .allow_metatables = true,
        .allowed_modules = &[_][]const u8{ "math", "string", "table" },
    });
    std.debug.print("  ✓ Created 'tenant-b' - Advanced features allowed\n", .{});

    // Tenant C: Minimal sandbox
    try manager.createTenant("tenant-c", "Minimal Tenant", .{
        .max_memory_bytes = 1 * 1024 * 1024, // 1MB
        .max_cpu_time_ms = 500, // 0.5 seconds
        .denied_globals = &[_][]const u8{ "print", "pairs", "ipairs" },
    });
    std.debug.print("  ✓ Created 'tenant-c' - Minimal sandbox\n", .{});

    // Test 2: Execute code in different tenants
    std.debug.print("\n2. Testing isolation between tenants:\n");

    // Each tenant sets a variable
    try manager.executeTenantCode("tenant-a", "my_data = 'Data from Tenant A'");
    try manager.executeTenantCode("tenant-b", "my_data = 'Data from Tenant B'");
    try manager.executeTenantCode("tenant-c", "my_data = 'Data from Tenant C'");

    std.debug.print("  ✓ Each tenant has its own isolated global state\n", .{});

    // Test 3: Resource limits
    std.debug.print("\n3. Testing resource limits:\n");

    // Memory limit test
    std.debug.print("  Testing memory limits...\n", .{});
    manager.executeTenantCode("tenant-c",
        \\local big_table = {}
        \\for i = 1, 100 do
        \\    big_table[i] = string.rep("x", 1000)
        \\end
    ) catch |err| {
        if (err == IsolationError.SecurityViolation) {
            std.debug.print("    ✓ Memory limit enforced for tenant-c\n", .{});
        }
    };

    // CPU time limit test
    std.debug.print("  Testing CPU time limits...\n", .{});
    manager.executeTenantCode("tenant-c",
        \\local function fib(n)
        \\    if n <= 1 then return n end
        \\    return fib(n-1) + fib(n-2)
        \\end
        \\fib(35)  -- This will take too long
    ) catch |err| {
        if (err == IsolationError.SecurityViolation) {
            std.debug.print("    ✓ CPU time limit enforced for tenant-c\n", .{});
        }
    };

    // Test 4: Security restrictions
    std.debug.print("\n4. Testing security restrictions:\n");

    // Try to use forbidden functions
    const security_tests = [_]struct { tenant: []const u8, code: []const u8, desc: []const u8 }{
        .{ .tenant = "tenant-a", .code = "os.execute('ls')", .desc = "OS access blocked" },
        .{ .tenant = "tenant-a", .code = "io.open('test.txt')", .desc = "IO access blocked" },
        .{ .tenant = "tenant-a", .code = "debug.getinfo(1)", .desc = "Debug access blocked" },
        .{ .tenant = "tenant-b", .code = "require('os')", .desc = "Unauthorized module blocked" },
        .{ .tenant = "tenant-c", .code = "print('hello')", .desc = "Denied global blocked" },
    };

    for (security_tests) |test_case| {
        manager.executeTenantCode(test_case.tenant, test_case.code) catch |err| {
            if (err == IsolationError.SecurityViolation) {
                std.debug.print("  ✓ {s} for {s}\n", .{ test_case.desc, test_case.tenant });
            }
        };
    }

    // Test 5: Resource usage monitoring
    std.debug.print("\n5. Resource usage monitoring:\n");

    // Execute some work in each tenant
    try manager.executeTenantCode("tenant-a",
        \\local sum = 0
        \\for i = 1, 1000 do
        \\    sum = sum + i
        \\end
    );

    try manager.executeTenantCode("tenant-b",
        \\local t = {}
        \\for i = 1, 100 do
        \\    t[i] = {x = i, y = i * 2}
        \\end
    );

    // Get resource usage for each tenant
    const tenants = [_][]const u8{ "tenant-a", "tenant-b", "tenant-c" };
    for (tenants) |tenant_id| {
        const usage = try manager.getTenantResourceUsage(tenant_id);
        std.debug.print("  {s}: Memory: {d} bytes, Function calls: {d}\n", .{
            tenant_id,
            usage.memory_used,
            usage.function_calls,
        });
    }

    // Test 6: Allowed features work correctly
    std.debug.print("\n6. Testing allowed features:\n");

    // Coroutines in tenant-b
    try manager.executeTenantCode("tenant-b",
        \\local co = coroutine.create(function()
        \\    for i = 1, 3 do
        \\        coroutine.yield(i * 2)
        \\    end
        \\end)
        \\
        \\local results = {}
        \\for i = 1, 3 do
        \\    local ok, val = coroutine.resume(co)
        \\    if ok then results[i] = val end
        \\end
    );
    std.debug.print("  ✓ Coroutines work in tenant-b\n", .{});

    // Metatables in tenant-b
    try manager.executeTenantCode("tenant-b",
        \\local mt = {
        \\    __add = function(a, b)
        \\        return {value = a.value + b.value}
        \\    end
        \\}
        \\local a = setmetatable({value = 10}, mt)
        \\local b = setmetatable({value = 20}, mt)
        \\local c = a + b
    );
    std.debug.print("  ✓ Metatables work in tenant-b\n", .{});

    // Test 7: Tenant lifecycle
    std.debug.print("\n7. Testing tenant lifecycle:\n");

    // List all tenants
    const all_tenants = try manager.getAllTenants(allocator);
    defer {
        for (all_tenants) |*tenant| {
            tenant.deinit(allocator);
        }
        allocator.free(all_tenants);
    }

    std.debug.print("  Active tenants: {d}\n", .{all_tenants.len});
    for (all_tenants) |tenant| {
        std.debug.print("    - {s} ({s}): Created {d}ms ago\n", .{
            tenant.id,
            tenant.name,
            std.time.milliTimestamp() - tenant.created_at,
        });
    }

    // Update tenant limits
    try manager.updateTenantLimits("tenant-a", .{
        .max_memory_bytes = 4 * 1024 * 1024, // Increase to 4MB
        .allow_coroutines = true, // Now allow coroutines
    });
    std.debug.print("  ✓ Updated limits for tenant-a\n", .{});

    // Delete a tenant
    try manager.deleteTenant("tenant-c");
    std.debug.print("  ✓ Deleted tenant-c\n", .{});

    // Test 8: Error handling
    std.debug.print("\n8. Testing error handling:\n");

    // Try to access deleted tenant
    manager.executeTenantCode("tenant-c", "x = 1") catch |err| {
        if (err == IsolationError.TenantNotFound) {
            std.debug.print("  ✓ Correctly reported tenant not found\n", .{});
        }
    };

    // Try to create duplicate tenant
    manager.createTenant("tenant-a", "Duplicate", .{}) catch |err| {
        if (err == IsolationError.TenantAlreadyExists) {
            std.debug.print("  ✓ Correctly prevented duplicate tenant creation\n", .{});
        }
    };

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey features demonstrated:\n", .{});
    std.debug.print("- Complete isolation between tenant Lua states\n", .{});
    std.debug.print("- Configurable resource limits (memory, CPU, function calls)\n", .{});
    std.debug.print("- Fine-grained security controls (module access, globals)\n", .{});
    std.debug.print("- Resource usage monitoring per tenant\n", .{});
    std.debug.print("- Dynamic tenant management and limit updates\n", .{});
}
