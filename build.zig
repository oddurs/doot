const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Borrowed plumbing: SDL3 gives us a window, input and a Metal-backed
    // 2D renderer; FreeType rasterizes glyphs. Everything above these two
    // lines -- the VT parser, the grid, the atlas -- is ours.
    mod.linkSystemLibrary("sdl3", .{});
    mod.linkSystemLibrary("freetype2", .{});

    const exe = b.addExecutable(.{
        .name = "terminator",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the terminal");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit and end-to-end tests");

    // Unit tests. These need their own root that names every module: Zig
    // skips imports nothing references, and in a test build nothing
    // references main().
    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_mod.linkSystemLibrary("freetype2", .{});
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // End-to-end tests drive a real shell on a real PTY, so they live in
    // their own root and get their own module.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    e2e_mod.linkSystemLibrary("sdl3", .{});
    e2e_mod.linkSystemLibrary("freetype2", .{});
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);
}
