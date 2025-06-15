// ABOUTME: Main build script for the zig_llms library and its examples
// ABOUTME: Defines build targets for library, examples, and tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "zig_llms",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    // Example executable
    const example_exe = b.addExecutable(.{
        .name = "basic_tool_usage_example",
        .root_source_file = b.path("examples/basic_tool_usage.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_exe.linkLibrary(lib);
    b.installArtifact(example_exe);

    const run_example_cmd = b.addRunArtifact(example_exe);
    const run_step = b.step("run-example", "Run the basic_tool_usage example");
    run_step.dependOn(&run_example_cmd.step);

    // Tests
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const run_main_tests = b.addRunArtifact(main_tests);
    
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}