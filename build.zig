const std = @import("std");

pub fn build(b: *std.Build) void {
    const mode = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Main antiphony module
    const antiphony_mod = b.addModule("antiphony", .{
        .root_source_file = b.path("src/antiphony.zig"),
        .target = target,
        .optimize = mode,
    });

    // Add s2s dependency
    const s2s_mod = b.dependency("s2s", .{}).module("s2s");
    antiphony_mod.addImport("s2s", s2s_mod);

    // Linux example
    const linux_example = b.addExecutable(.{
        .name = "linux-socketpair-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/linux.zig"),
            .optimize = mode,
            .target = target,
            .imports = &.{.{ .name = "antiphony", .module = antiphony_mod }},
        }),
    });
    b.installArtifact(linux_example);

    // macOS example
    const macos_example = b.addExecutable(.{
        .name = "macos-socketpair-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/macos.zig"),
            .optimize = mode,
            .target = target,
            .imports = &.{.{ .name = "antiphony", .module = antiphony_mod }},
        }),
    });
    b.installArtifact(macos_example);

    // Run steps for examples
    const run_linux = b.addRunArtifact(linux_example);
    const run_linux_step = b.step("run-linux", "Run the Linux socketpair example");
    run_linux_step.dependOn(&run_linux.step);

    const run_macos = b.addRunArtifact(macos_example);
    const run_macos_step = b.step("run-macos", "Run the macOS machport example");
    run_macos_step.dependOn(&run_macos.step);

    // Tests
    const main_tests = b.addTest(.{
        .name = "antiphony",
        .root_module = antiphony_mod,
    });
    main_tests.root_module.addImport("s2s", s2s_mod);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
