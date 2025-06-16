// ABOUTME: Demonstrates Lua panic handler integration with Zig error handling
// ABOUTME: Shows panic recovery, diagnostic reporting, and protected execution

const std = @import("std");
const zig_llms = @import("zig_llms");

const lua = @import("zig_llms").bindings.lua;
const PanicHandler = @import("zig_llms").scripting.engines.lua_panic.PanicHandler;
const ProtectedExecutor = @import("zig_llms").scripting.engines.lua_panic.ProtectedExecutor;
const PanicHandlerConfig = @import("zig_llms").scripting.engines.lua_panic.PanicHandlerConfig;
const RecoveryUtils = @import("zig_llms").scripting.engines.lua_panic.RecoveryUtils;

pub fn main() !void {
    if (!lua.lua_enabled) {
        std.debug.print("Lua support is not enabled. Build with -Dlua=true\n", .{});
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Panic Handler Demo ===\n\n", .{});

    // Test 1: Basic panic handler installation
    std.debug.print("1. Basic panic handler setup:\n", .{});

    const wrapper = try lua.LuaWrapper.init(allocator);
    defer wrapper.deinit();

    const config = PanicHandlerConfig{
        .enable_recovery = true,
        .capture_stack_trace = true,
        .log_panics = true,
        .recovery_strategy = .reset_state,
    };

    var panic_handler = try PanicHandler.init(wrapper, config);
    defer panic_handler.deinit();

    try panic_handler.install();
    std.debug.print("  ✓ Panic handler installed successfully\n", .{});

    // Test 2: Protected execution
    std.debug.print("\n2. Protected script execution:\n", .{});

    var protected_executor = try ProtectedExecutor.init(allocator, wrapper, config);
    defer protected_executor.deinit();

    // Safe execution
    try protected_executor.executeProtected("safe_variable = 'Hello from Lua'");
    std.debug.print("  ✓ Safe script executed successfully\n", .{});

    // Test 3: Error scenarios (simulated)
    std.debug.print("\n3. Error handling scenarios:\n", .{});

    // Stack overflow simulation (careful - this could actually cause issues)
    std.debug.print("  Testing stack overflow protection...\n", .{});
    protected_executor.executeProtected(
        \\function recursive_function(n)
        \\    if n > 100 then  -- Limit recursion for safety
        \\        error("Simulated stack overflow")
        \\    end
        \\    return recursive_function(n + 1)
        \\end
    ) catch |err| {
        std.debug.print("    ✓ Caught error during setup: {}\n", .{err});
    };

    // Try to call the recursive function
    protected_executor.executeProtected("recursive_function(1)") catch |err| {
        std.debug.print("    ✓ Protected execution caught error: {}\n", .{err});

        if (panic_handler.getLastPanic()) |panic| {
            std.debug.print("    Panic details: {s}\n", .{panic.message});
        }
    };

    // Memory allocation error simulation
    std.debug.print("  Testing memory error handling...\n", .{});
    protected_executor.executeProtected(
        \\-- Create a large table (simulated memory pressure)
        \\large_table = {}
        \\for i = 1, 1000 do
        \\    large_table[i] = string.rep("x", 1000)
        \\end
    ) catch |err| {
        std.debug.print("    ✓ Memory pressure handled: {}\n", .{err});
    };

    // Test 4: Diagnostic reporting
    std.debug.print("\n4. Diagnostic reporting:\n", .{});

    if (panic_handler.getLastPanic()) |panic_info| {
        std.debug.print("  Last panic occurred at: {d}\n", .{panic_info.timestamp});
        std.debug.print("  Panic type: {s}\n", .{@tagName(panic_info.error_type)});
        std.debug.print("  Message: {s}\n", .{panic_info.message});

        if (panic_info.stack_trace) |trace| {
            std.debug.print("  Stack trace available: {} characters\n", .{trace.len});
        }

        // Generate diagnostic report
        const report = try RecoveryUtils.createDiagnosticReport(allocator, &panic_info, wrapper);
        defer allocator.free(report);

        std.debug.print("  Generated diagnostic report ({d} bytes)\n", .{report.len});
        std.debug.print("  Report preview:\n");
        const preview_len = @min(200, report.len);
        std.debug.print("    {s}...\n", .{report[0..preview_len]});
    } else {
        std.debug.print("  No panics recorded\n", .{});
    }

    // Test 5: State recovery
    std.debug.print("\n5. State recovery testing:\n", .{});

    // Test state recovery
    RecoveryUtils.attemptStateRecovery(wrapper) catch |err| {
        std.debug.print("  Recovery attempt failed: {}\n", .{err});
    };
    std.debug.print("  ✓ State recovery attempted\n", .{});

    // Verify state is still functional
    try protected_executor.executeProtected("recovery_test = 42");
    std.debug.print("  ✓ State functional after recovery\n", .{});

    // Test 6: Panic statistics
    std.debug.print("\n6. Panic statistics:\n", .{});
    std.debug.print("  Total panics recorded: {d}\n", .{panic_handler.getPanicCount()});

    // Test 7: Configuration variations
    std.debug.print("\n7. Configuration variations:\n", .{});

    // Create handler with different config
    const strict_config = PanicHandlerConfig{
        .enable_recovery = false,
        .capture_stack_trace = true,
        .log_panics = true,
        .recovery_strategy = .propagate,
        .max_stack_depth = 10,
    };

    var strict_handler = try PanicHandler.init(wrapper, strict_config);
    defer strict_handler.deinit();

    std.debug.print("  ✓ Created strict panic handler (no recovery)\n", .{});

    // Test 8: Custom panic callback (demonstration)
    std.debug.print("\n8. Custom panic callback:\n", .{});

    const callback_config = PanicHandlerConfig{
        .enable_recovery = true,
        .capture_stack_trace = true,
        .log_panics = false, // We'll handle logging in callback
        .panic_callback = struct {
            fn panicCallback(panic_info: *@import("zig_llms").scripting.engines.lua_panic.PanicInfo) void {
                std.debug.print("    🚨 Custom callback triggered!\n", .{});
                std.debug.print("    Error: {s}\n", .{panic_info.message});
                std.debug.print("    Type: {s}\n", .{@tagName(panic_info.error_type)});
            }
        }.panicCallback,
    };

    var callback_handler = try PanicHandler.init(wrapper, callback_config);
    defer callback_handler.deinit();

    std.debug.print("  ✓ Created handler with custom callback\n", .{});

    // Test 9: Cleanup and verification
    std.debug.print("\n9. Cleanup and verification:\n", .{});

    // Clear panic history
    panic_handler.clearHistory();
    std.debug.print("  ✓ Panic history cleared\n", .{});
    std.debug.print("  Panic count after clear: {d}\n", .{panic_handler.getPanicCount()});

    // Uninstall handlers
    try panic_handler.uninstall();
    std.debug.print("  ✓ Main panic handler uninstalled\n", .{});

    // Final state verification
    try wrapper.doString("final_test = 'Handler demo completed'");
    std.debug.print("  ✓ Final state verification successful\n", .{});

    std.debug.print("\n=== Demo Complete ===\n", .{});
    std.debug.print("\nKey features demonstrated:\n", .{});
    std.debug.print("- Panic handler installation and configuration\n", .{});
    std.debug.print("- Protected script execution with error recovery\n", .{});
    std.debug.print("- Stack trace capture and panic type detection\n", .{});
    std.debug.print("- Diagnostic report generation\n", .{});
    std.debug.print("- State recovery mechanisms\n", .{});
    std.debug.print("- Custom panic callbacks\n", .{});
    std.debug.print("- Panic statistics and history management\n", .{});
}
