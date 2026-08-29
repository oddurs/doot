const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One source of truth for the version: `build.zig.zon`'s `.version`,
    // handed to the code as a build option rather than retyped as a
    // constant. `--version`, TERM_PROGRAM_VERSION and, later, the bundle's
    // Info.plist all read this string, so there is nothing to keep in step
    // with the changelog by hand.
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    options.addOption([]const u8, "commit", gitCommit(b));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);

    // Borrowed plumbing: SDL3 gives us a window and input; FreeType
    // rasterizes glyphs. Everything above these two lines -- the VT parser,
    // the grid, the atlas, and since D0 the renderer -- is ours.
    mod.linkSystemLibrary("sdl3", .{});
    mod.linkSystemLibrary("freetype2", .{});

    // The platform layer: Objective-C compiled by our own toolchain, behind
    // a C ABI, linking nothing but the system's own frameworks. Only the app
    // module needs it -- neither test root constructs a Renderer, and the
    // bench, audit, gallery, record and check-corpora steps never link it.
    mod.addIncludePath(b.path("src/platform"));
    mod.addCSourceFile(.{
        .file = b.path("src/platform/gpu.m"),
        .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra" },
    });
    mod.linkFramework("Metal", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("Foundation", .{});

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
    unit_mod.addOptions("build_options", options);
    unit_mod.linkSystemLibrary("freetype2", .{});
    const unit_tests = b.addTest(.{ .root_module = unit_mod });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Benchmarks. Always ReleaseFast regardless of -Doptimize: a number
    // measured in Debug is not a number anyone should act on, and having
    // `zig build bench` silently report one would be worse than having no
    // benchmark at all.
    //
    // vt, grid and terminal import nothing but std, so this needs neither
    // SDL nor FreeType and runs headless anywhere.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    // The corpora are committed files rather than generated at run time, so
    // a number from today is comparable with one from six months ago. They
    // are embedded rather than opened so the bench does not care where it
    // was invoked from. See bench/gen_corpus.py.
    const corpus_names = [_][]const u8{
        "ascii",        "sgr",          "scroll", "altscreen", "cjk", "region",
        // Recordings rather than generated: see src/record.zig and A0.
        "agent-claude", "agent-stream",
    };
    inline for (corpus_names) |name| {
        // `-` is not valid in an import name, so the module is named with
        // an underscore while the file keeps the readable name.
        const import_name = "corpus_" ++ comptime blk: {
            var buf: [name.len]u8 = undefined;
            for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
            const final = buf;
            break :blk &final;
        };
        bench_mod.addAnonymousImport(import_name, .{
            .root_source_file = b.path("bench/corpus/" ++ name ++ ".bin"),
        });
    }

    // The protocol audit: what the corpora ask a terminal to do, beside
    // what this one does about it. See src/audit.zig and A0.
    const audit_mod = b.createModule(.{
        .root_source_file = b.path("src/audit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    inline for ([_][]const u8{ "agent-claude", "agent-stream", "altscreen", "sgr", "region" }) |name| {
        const import_name = "corpus_" ++ comptime blk: {
            var buf: [name.len]u8 = undefined;
            for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
            const final = buf;
            break :blk &final;
        };
        audit_mod.addAnonymousImport(import_name, .{
            .root_source_file = b.path("bench/corpus/" ++ name ++ ".bin"),
        });
    }
    const audit_exe = b.addExecutable(.{ .name = "audit", .root_module = audit_mod });
    const audit_run = b.addRunArtifact(audit_exe);
    const audit_step = b.step("audit", "Audit what the corpora ask a terminal to do");
    audit_step.dependOn(&audit_run.step);

    const bench_exe = b.addExecutable(.{ .name = "bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the performance benchmarks");
    bench_step.dependOn(&bench_run.step);

    // The screenshot gallery. Renders each canonical screen through the
    // real app and diffs it against a committed PNG -- the arbiter for the
    // experience roadmap, the way `bench` is for the performance one.
    //
    // It drives the built binary rather than linking the renderer, so it
    // needs neither SDL nor FreeType itself. Running with no display is
    // gallery.zig's job -- it puts SDL_VIDEODRIVER in the child's
    // environment explicitly, because a spawn with no environment map
    // gives the child an empty one and nothing set here would reach it.
    const gallery_mod = b.createModule(.{
        .root_source_file = b.path("src/gallery.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const gallery_exe = b.addExecutable(.{ .name = "gallery", .root_module = gallery_mod });
    const gallery_run = b.addRunArtifact(gallery_exe);
    gallery_run.addArtifactArg(exe);
    gallery_run.has_side_effects = true;
    if (b.args) |args| gallery_run.addArgs(args);
    const gallery_step = b.step("gallery", "Render the screenshot gallery and diff it");
    gallery_step.dependOn(&gallery_run.step);

    // The recorder. Runs a command on a pty and writes what it emits, so
    // the agent corpora are recordings rather than a description of what
    // agent output is imagined to look like.
    const record_mod = b.createModule(.{
        .root_source_file = b.path("src/record.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // pty.zig sets TERM_PROGRAM_VERSION, so it needs the version option.
    record_mod.addOptions("build_options", options);
    const record_exe = b.addExecutable(.{ .name = "record", .root_module = record_mod });
    // Installed as well as runnable through the step: a recording is
    // usually taken with the agent running in some other directory.
    b.installArtifact(record_exe);
    const record_run = b.addRunArtifact(record_exe);
    record_run.has_side_effects = true;
    if (b.args) |args| record_run.addArgs(args);
    const record_step = b.step("record", "Record a command's terminal output as a corpus");
    record_step.dependOn(&record_run.step);

    // The corpus guard: a committed recording must not carry a secret.
    // The check is "redacting it changes nothing", using the same
    // redact.zig the recorder applies at capture time.
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/check_corpora.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const check_exe = b.addExecutable(.{ .name = "check-corpora", .root_module = check_mod });
    const check_run = b.addRunArtifact(check_exe);
    check_run.has_side_effects = true;
    const check_step = b.step("check-corpora", "Fail if a committed corpus carries a secret");
    check_step.dependOn(&check_run.step);

    // End-to-end tests drive a real shell on a real PTY, so they live in
    // their own root and get their own module.
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    e2e_mod.addOptions("build_options", options);
    e2e_mod.linkSystemLibrary("sdl3", .{});
    e2e_mod.linkSystemLibrary("freetype2", .{});
    const e2e_tests = b.addTest(.{ .root_module = e2e_mod });
    test_step.dependOn(&b.addRunArtifact(e2e_tests).step);
}

/// The short commit `--version` reports, or empty when this tree is not
/// itself a checkout.
///
/// A release tarball is built from an export with no `.git`, and failing
/// the build over seven characters would be a poor trade -- `--version`
/// simply prints the number without them.
///
/// The `.git` check is not redundant with asking git: `rev-parse` walks
/// *up* out of the build root, so an unpacked source tarball sitting
/// inside somebody else's working tree would otherwise be stamped with
/// their HEAD -- a provenance string pointing at an unrelated commit,
/// which is worse than none at all.
fn gitCommit(b: *std.Build) []const u8 {
    b.build_root.handle.access(b.graph.io, ".git", .{}) catch return "";
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "git", "-C", b.pathFromRoot("."), "rev-parse", "--short=7", "HEAD" },
        &code,
        .ignore,
    ) catch return "";
    return std.mem.trim(u8, out, " \t\n\r");
}
