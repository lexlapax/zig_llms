// ABOUTME: Main build script for the zig_llms library and its examples
// ABOUTME: Defines build targets for library, examples, and tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const enable_lua = b.option(bool, "enable-lua", "Enable Lua scripting engine support") orelse true;
    const lua_jit = b.option(bool, "lua-jit", "Use LuaJIT instead of standard Lua") orelse false;

    // Create a separate Lua static library if enabled
    var lua_lib: ?*std.Build.Step.Compile = null;
    if (enable_lua) {
        if (lua_jit) {
            // LuaJIT configuration (for future implementation)
            @panic("LuaJIT support not yet implemented");
        } else {
            // Build Lua as a separate static library
            lua_lib = buildLuaLib(b, target, optimize);
        }
    }

    const lib = b.addStaticLibrary(.{
        .name = "zig_llms",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add build options to the library
    const options = b.addOptions();
    options.addOption(bool, "enable_lua", enable_lua);
    options.addOption(bool, "lua_jit", lua_jit);
    lib.root_module.addOptions("build_options", options);

    // Link Lua if enabled
    if (lua_lib) |lua| {
        lib.linkLibrary(lua);
        lib.addIncludePath(b.path("deps/lua-5.4.6/src"));
    }

    b.installArtifact(lib);

    // Example executable
    const example_exe = b.addExecutable(.{
        .name = "basic_tool_usage_example",
        .root_source_file = b.path("examples/basic_tool_usage.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_exe.root_module.addImport("zig_llms", lib.root_module);
    example_exe.linkLibrary(lib);
    b.installArtifact(example_exe);

    const run_example_cmd = b.addRunArtifact(example_exe);
    const run_step = b.step("run-example", "Run the basic_tool_usage example");
    run_step.dependOn(&run_example_cmd.step);
    
    // Retry example
    const retry_example = b.addExecutable(.{
        .name = "retry_example",
        .root_source_file = b.path("examples/retry_example.zig"),
        .target = target,
        .optimize = optimize,
    });
    retry_example.root_module.addImport("zig_llms", lib.root_module);
    retry_example.linkLibrary(lib);
    b.installArtifact(retry_example);
    
    const run_retry_cmd = b.addRunArtifact(retry_example);
    const run_retry_step = b.step("run-retry-example", "Run the retry example");
    run_retry_step.dependOn(&run_retry_cmd.step);

    // Tests
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link with Lua if enabled
    if (lua_lib) |lua| {
        main_tests.linkLibrary(lua);
        main_tests.addIncludePath(b.path("deps/lua-5.4.6/src"));
    }
    main_tests.root_module.addOptions("build_options", options);
    
    const run_main_tests = b.addRunArtifact(main_tests);
    
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
    
    // Lua-specific examples if enabled
    if (enable_lua) {
        const lua_example = b.addExecutable(.{
            .name = "lua_example",
            .root_source_file = b.path("examples/lua/basic_lua_script.zig"),
            .target = target,
            .optimize = optimize,
        });
        lua_example.root_module.addImport("zig_llms", lib.root_module);
        lua_example.linkLibrary(lib);
        
        const run_lua_example = b.addRunArtifact(lua_example);
        const run_lua_step = b.step("run-lua-example", "Run the Lua scripting example");
        run_lua_step.dependOn(&run_lua_example.step);
        
        // Add Lua lifecycle demo
        const lua_lifecycle_example = b.addExecutable(.{
            .name = "lua_lifecycle_demo",
            .root_source_file = b.path("examples/lua_lifecycle_demo.zig"),
            .target = target,
            .optimize = optimize,
        });
        lua_lifecycle_example.root_module.addImport("zig_llms", lib.root_module);
        lua_lifecycle_example.linkLibrary(lib);
        
        const run_lua_lifecycle = b.addRunArtifact(lua_lifecycle_example);
        const run_lua_lifecycle_step = b.step("run-lua-lifecycle", "Run the Lua lifecycle management demo");
        run_lua_lifecycle_step.dependOn(&run_lua_lifecycle.step);
        
        // Add Lua memory demo
        const lua_memory_example = b.addExecutable(.{
            .name = "lua_memory_demo",
            .root_source_file = b.path("examples/lua_memory_demo.zig"),
            .target = target,
            .optimize = optimize,
        });
        lua_memory_example.root_module.addImport("zig_llms", lib.root_module);
        lua_memory_example.linkLibrary(lib);
        
        const run_lua_memory = b.addRunArtifact(lua_memory_example);
        const run_lua_memory_step = b.step("run-lua-memory", "Run the Lua memory management demo");
        run_lua_memory_step.dependOn(&run_lua_memory.step);
        
        // Add Lua execution demo
        const lua_execution_example = b.addExecutable(.{
            .name = "lua_execution_demo",
            .root_source_file = b.path("examples/lua_execution_demo.zig"),
            .target = target,
            .optimize = optimize,
        });
        lua_execution_example.root_module.addImport("zig_llms", lib.root_module);
        lua_execution_example.linkLibrary(lib);
        
        const run_lua_execution = b.addRunArtifact(lua_execution_example);
        const run_lua_execution_step = b.step("run-lua-execution", "Run the Lua script execution demo");
        run_lua_execution_step.dependOn(&run_lua_execution.step);
    }
}

fn buildLuaLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lua_lib = b.addStaticLibrary(.{
        .name = "lua",
        .target = target,
        .optimize = optimize,
    });
    
    // Determine Lua source location
    const lua_src_path = "deps/lua-5.4.6/src";
    
    // Add Lua include directory
    lua_lib.addIncludePath(b.path(lua_src_path));
    
    // Define Lua configuration based on target
    const target_info = target.result;
    
    // Platform-specific defines
    switch (target_info.os.tag) {
        .linux => {
            lua_lib.root_module.addCMacro("LUA_USE_LINUX", "");
            lua_lib.root_module.addCMacro("LUA_USE_POSIX", "");
            lua_lib.root_module.addCMacro("LUA_USE_DLOPEN", "");
            lua_lib.linkSystemLibrary("m");
            lua_lib.linkSystemLibrary("dl");
        },
        .macos => {
            lua_lib.root_module.addCMacro("LUA_USE_MACOSX", "");
            lua_lib.root_module.addCMacro("LUA_USE_POSIX", "");
            lua_lib.root_module.addCMacro("LUA_USE_DLOPEN", "");
        },
        .windows => {
            lua_lib.root_module.addCMacro("LUA_BUILD_AS_DLL", "");
        },
        else => {
            // Generic POSIX
            lua_lib.root_module.addCMacro("LUA_USE_POSIX", "");
        },
    }
    
    // Common Lua defines
    lua_lib.root_module.addCMacro("LUA_COMPAT_5_3", ""); // Compatibility with Lua 5.3
    
    // Add Lua C source files
    const lua_sources = [_][]const u8{
        "lapi.c",
        "lauxlib.c",
        "lbaselib.c",
        "lcode.c",
        "lcorolib.c",
        "lctype.c",
        "ldblib.c",
        "ldebug.c",
        "ldo.c",
        "ldump.c",
        "lfunc.c",
        "lgc.c",
        "linit.c",
        "liolib.c",
        "llex.c",
        "lmathlib.c",
        "lmem.c",
        "loadlib.c",
        "lobject.c",
        "lopcodes.c",
        "loslib.c",
        "lparser.c",
        "lstate.c",
        "lstring.c",
        "lstrlib.c",
        "ltable.c",
        "ltablib.c",
        "ltm.c",
        "lundump.c",
        "lutf8lib.c",
        "lvm.c",
        "lzio.c",
    };
    
    for (lua_sources) |src| {
        const src_path = b.fmt("{s}/{s}", .{ lua_src_path, src });
        lua_lib.addCSourceFile(.{
            .file = b.path(src_path),
            .flags = &.{
                "-std=c99",
                "-O2",
                "-Wall",
                "-Wextra",
                "-DLUA_COMPAT_5_3",
            },
        });
    }
    
    // Link libc
    lua_lib.linkLibC();
    
    return lua_lib;
}