//! The screenshot gallery: the arbiter for every visual change.
//!
//! X0 of docs/roadmap/experience.md. The performance roadmap has
//! `zig build bench`, and the rule there is that a claim carries a number
//! or it is a guess. Nothing above the renderer has a number, so the
//! experience roadmap gets pictures instead: each capture below renders one
//! canonical screen through the real parser, grid and renderer, and is
//! compared against a committed PNG.
//!
//!   zig build gallery              render and report per-image deltas
//!   zig build gallery -- --update  accept the current renders as expected
//!
//! Headless, via `SDL_VIDEODRIVER=dummy` (set by the build step), so it
//! runs on a CI runner with no display. `--scale` is what makes a 2x
//! capture reproducible on a 1x machine: the app is told to pretend rather
//! than asked what display it is on.
//!
//! The scenes are shell scripts that print fixed bytes. Not `vim` or
//! `htop`: their output varies with version, terminal size, locale and the
//! files lying around, and a pixel diff cannot tell that apart from a
//! regression. The bench corpora are committed files for the same reason.

const std = @import("std");
const png = @import("png.zig");

const Capture = struct {
    name: []const u8,
    scene: []const u8,
    cols: u32,
    rows: u32,
    font_size: u32,
    scale: u32,
    /// `--select R,C,R,C` in viewport coordinates, applied before the frame
    /// is captured. The only way to photograph a highlight: there is no
    /// mouse under `SDL_VIDEODRIVER=dummy`.
    select: ?[]const u8 = null,
    /// `--select-rect`: the same spec read as a rectangle, the way an
    /// `Option`-drag sets it.
    select_rect: bool = false,
    /// L1. `--seek-span N` photographs the last frame of the Nth most recent
    /// full-screen program in *this session's own recording* -- the frame the
    /// live screen no longer has. It is the one capture here that needs the
    /// session recorded, so it gets `--record-dir` where every other capture
    /// gets `--no-record`.
    seek_span: ?u32 = null,
};

/// One row per committed PNG. Sizes are chosen so a capture is a few tens
/// of kilobytes: these live in the repository forever.
const captures = [_]Capture{
    // The typography page at the three sizes the sprint asks for, plus 2x.
    // Baseline placement and cell rounding are what change between them.
    .{ .name = "typography-14pt-1x", .scene = "typography", .cols = 74, .rows = 11, .font_size = 14, .scale = 1 },
    .{ .name = "typography-14pt-2x", .scene = "typography", .cols = 74, .rows = 11, .font_size = 14, .scale = 2 },
    .{ .name = "typography-10pt-1x", .scene = "typography", .cols = 74, .rows = 11, .font_size = 10, .scale = 1 },
    .{ .name = "typography-20pt-1x", .scene = "typography", .cols = 74, .rows = 11, .font_size = 20, .scale = 1 },

    .{ .name = "attributes-14pt-1x", .scene = "attributes", .cols = 74, .rows = 5, .font_size = 14, .scale = 1 },
    .{ .name = "attributes-14pt-2x", .scene = "attributes", .cols = 74, .rows = 5, .font_size = 14, .scale = 2 },

    // `colors` draws rectangles and no glyphs, which makes it the oracle for
    // geometry, projection, the clear colour and channel order -- the things
    // a renderer swap gets wrong. It is held to zero differing pixels, at
    // both scales, where the nine scenes containing text cannot be.
    .{ .name = "colors-14pt-1x", .scene = "colors", .cols = 112, .rows = 7, .font_size = 14, .scale = 1 },
    .{ .name = "colors-14pt-2x", .scene = "colors", .cols = 112, .rows = 7, .font_size = 14, .scale = 2 },

    .{ .name = "tui-14pt-1x", .scene = "tui", .cols = 52, .rows = 12, .font_size = 14, .scale = 1 },

    // The cursor gets its own scene at both scales: X0 is done when a
    // one-pixel change in it shows up as a diff.
    .{ .name = "cursor-14pt-1x", .scene = "cursor", .cols = 48, .rows = 4, .font_size = 14, .scale = 1 },
    .{ .name = "cursor-14pt-2x", .scene = "cursor", .cols = 48, .rows = 4, .font_size = 14, .scale = 2 },

    // E1. One scene, two selections. The first covers all four things the
    // highlight can get wrong at once: it starts mid-row (so the background
    // runs have to split around it), runs to the margin of a *wrapped* row
    // and continues on the next, covers a coloured background that the
    // selection colour has to win against, and stops inside a reverse-video
    // run -- so the same run appears reversed and unreversed side by side,
    // which is the fix for `less`'s status line disappearing while selected.
    .{
        .name = "selection-14pt-1x",
        .scene = "selection",
        .cols = 48,
        .rows = 6,
        .font_size = 14,
        .scale = 1,
        .select = "0,9,4,20",
    },
    // The second lands both edges on a wide character: the start on a
    // `.spacer`, which snaps left onto its partner, and the end on a `.wide`,
    // which extends over the spacer that belongs to it. The highlight is
    // therefore six cells wide over a four-cell request, covering all three
    // ideographs whole. At 2x, because half a covered pair is exactly the
    // sort of thing only a 2x capture shows.
    //
    // The ideographs themselves render blank: the face is SFNSMono and there
    // is no fallback chain yet, which is X2 on the experience roadmap. What
    // this capture is the arbiter for is the *geometry* of the highlight, and
    // that is visible either way.
    .{
        .name = "selection-wide-14pt-2x",
        .scene = "selection",
        .cols = 48,
        .rows = 6,
        .font_size = 14,
        .scale = 2,
        .select = "3,7,3,10",
    },
    // The third is the same columns as a *rectangle*, over three rows, of
    // which only the last carries the wide pair. An adversarial review found
    // that rect mode snapped against the start row alone, so every other row
    // in the block inherited its columns and a pair below could be cut in
    // half. The columns now widen to the union of what each covered row asks
    // for, which is the only answer that is both rectangular and free of half
    // glyphs -- and this capture is what says so: all three rows are
    // highlighted over the *same* six columns, and the block's edges are
    // straight.
    .{
        .name = "selection-rect-14pt-2x",
        .scene = "selection",
        .cols = 48,
        .rows = 6,
        .font_size = 14,
        .scale = 2,
        .select = "1,7,3,10",
        .select_rect = true,
    },

    // L1. The only capture whose subject is not on the screen: a full-screen
    // program takes the alt screen, draws, and exits, and this photographs
    // the frame it drew -- restored from a checkpoint in the session's own
    // recording, with the seek status row painted as the bottom grid row
    // underneath it. Every other terminal has thrown that frame away by the
    // time the shell prints its next line.
    //
    // The three time values in the status row are pinned by `--seek-status`.
    // See `cli.Options.seek_status`: the clock is the real time of day and
    // the bar is a fraction of a session whose length is dominated by shell
    // startup jitter, so none of the three can be reproduced. Everything else
    // -- the row's text, its reverse video, its place in the grid, and the
    // restored frame above it -- is real.
    .{
        .name = "seek-span-14pt-1x",
        .scene = "seek",
        .cols = 60,
        .rows = 14,
        .font_size = 14,
        .scale = 1,
        .seek_span = 1,
    },
};

const expected_dir = "bench/gallery/expected";
const current_dir = "bench/gallery/current";
/// Where the one recorded capture's `.trec` goes. Under the gitignored
/// render directory, never the user's own sessions folder.
const sessions_dir = "bench/gallery/current/sessions";

fn compare(a: png.Image, b: png.Image) struct { pixels: u64, worst: u8 } {
    var differing: u64 = 0;
    var worst: u8 = 0;
    var i: usize = 0;
    while (i < a.pixels.len) : (i += 4) {
        var changed = false;
        for (0..4) |ch| {
            const d = @abs(@as(i16, a.pixels[i + ch]) - @as(i16, b.pixels[i + ch]));
            if (d != 0) changed = true;
            worst = @max(worst, @as(u8, @intCast(@min(d, 255))));
        }
        if (changed) differing += 1;
    }
    return .{ .pixels = differing, .worst = worst };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: gallery <path-to-doot> [--update]\n", .{});
        std.process.exit(2);
    }
    const doot = std.mem.span(argv[1]);
    var update = false;
    for (argv[2..]) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "--update")) update = true;
    }

    // Spawning with no environment map hands the child an *empty* one, so
    // an SDL_VIDEODRIVER set on this process would never reach it -- the
    // gallery would quietly render through the real window server, and its
    // references would be whatever display the maintainer happened to have.
    // Setting it here rather than inheriting it also means `zig build
    // gallery` is headless however it was invoked.
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.putPosixBlock(init.environ.block.view());
    try environ.put("SDL_VIDEODRIVER", "dummy");

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, current_dir) catch {};
    if (update) cwd.createDirPath(io, expected_dir) catch {};

    std.debug.print(
        \\gallery: {d} captures, headless
        \\
        \\  {s:<22} {s:>11} {s:>12} {s:>9}  {s}
        \\  {s:-<22} {s:->11} {s:->12} {s:->9}  {s:-<28}
        \\
    , .{ captures.len, "capture", "size", "differing", "worst", "result", "", "", "", "", "" });

    var changed: usize = 0;
    var added: usize = 0;

    for (captures) |cap| {
        const scene_path = try std.fmt.allocPrint(gpa, "bench/gallery/{s}.sh", .{cap.scene});
        defer gpa.free(scene_path);
        const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ current_dir, cap.name });
        defer gpa.free(out_path);
        const want_path = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ expected_dir, cap.name });
        defer gpa.free(want_path);

        const size = try std.fmt.allocPrint(gpa, "{d}x{d}", .{ cap.cols, cap.rows });
        defer gpa.free(size);
        const font_size = try std.fmt.allocPrint(gpa, "{d}", .{cap.font_size});
        defer gpa.free(font_size);
        const scale = try std.fmt.allocPrint(gpa, "{d}", .{cap.scale});
        defer gpa.free(scale);

        cwd.deleteFile(io, out_path) catch {};

        // Built rather than written out, because `--select` is on some
        // captures and not others.
        var argv_list: std.ArrayList([]const u8) = .empty;
        defer argv_list.deinit(gpa);
        try argv_list.appendSlice(gpa, &.{
            doot,          "--shell", scene_path, "--size", size,
            "--font-size", font_size, "--scale",  scale,    "--screenshot",
            out_path,
        });
        // Outside the branch below on purpose: a `defer gpa.free` inside it
        // would run at the end of the block, freeing the string while
        // `argv_list` still points at it, and the child would be spawned
        // with a freed argument. That is exactly what happened the first
        // time, and it read as "the seek silently did nothing".
        var span_buf: [8]u8 = undefined;
        if (cap.seek_span) |n| {
            // The one capture that has to be recorded, because what it
            // photographs is a frame out of the recording. Its own
            // directory, under the gitignored render directory rather than
            // the user's sessions folder, and swept after a day so repeated
            // runs do not pile up.
            const span = try std.fmt.bufPrint(&span_buf, "{d}", .{n});
            try argv_list.appendSlice(gpa, &.{
                "--record-dir",         sessions_dir,
                "--record-retain-days", "1",
                "--seek-span",          span,
                // See `cli.Options.seek_status`: pinned so the capture is
                // reproducible, and pinned nowhere else.
                "--seek-status",        "43391,272,42",
            });
        } else {
            // A gallery capture is a test, not a session. Without this
            // every `zig build gallery` drops recordings into the user's
            // own sessions directory, which is exactly the kind of thing
            // an on-by-default recorder has to not do.
            try argv_list.append(gpa, "--no-record");
        }
        if (cap.select) |spec| try argv_list.appendSlice(gpa, &.{ "--select", spec });
        if (cap.select_rect) try argv_list.append(gpa, "--select-rect");

        var child = try std.process.spawn(io, .{
            .argv = argv_list.items,
            .environ_map = &environ,
            // The scenes print and exit; their output is the picture, not
            // something anyone needs to read here.
            .stdout = .ignore,
            .stderr = .ignore,
        });
        _ = try child.wait(io);

        const got_bytes = cwd.readFileAlloc(io, out_path, gpa, .limited(64 << 20)) catch {
            std.debug.print("  {s:<22} {s}\n", .{ cap.name, "FAILED to render" });
            std.process.exit(1);
        };
        defer gpa.free(got_bytes);
        var got = try png.decode(gpa, got_bytes);
        defer got.deinit(gpa);

        const dims = try std.fmt.allocPrint(gpa, "{d}x{d}", .{ got.w, got.h });
        defer gpa.free(dims);

        const want_bytes = cwd.readFileAlloc(io, want_path, gpa, .limited(64 << 20)) catch null;
        if (want_bytes) |wb| {
            defer gpa.free(wb);
            // A reference that will not decode is a reason to report that
            // capture and carry on, not to abandon the other nine.
            var want = png.decode(gpa, wb) catch |err| {
                changed += 1;
                std.debug.print("  {s:<22} {s:>11} {s:>12} {s:>9}  reference unreadable ({t})\n", .{
                    cap.name, dims, "-", "-", err,
                });
                if (update) try cwd.writeFile(io, .{ .sub_path = want_path, .data = got_bytes });
                continue;
            };
            defer want.deinit(gpa);

            if (want.w != got.w or want.h != got.h) {
                changed += 1;
                std.debug.print("  {s:<22} {s:>11} {s:>12} {s:>9}  was {d}x{d}\n", .{
                    cap.name, dims, "-", "-", want.w, want.h,
                });
            } else {
                const d = compare(want, got);
                const total: f64 = @floatFromInt(got.w * got.h);
                if (d.pixels == 0) {
                    std.debug.print("  {s:<22} {s:>11} {s:>12} {s:>9}  identical\n", .{ cap.name, dims, "0", "0" });
                } else {
                    changed += 1;
                    std.debug.print("  {s:<22} {s:>11} {d:>12} {d:>9}  {d:.2}% of pixels\n", .{
                        cap.name,                                          dims, d.pixels, d.worst,
                        @as(f64, @floatFromInt(d.pixels)) / total * 100.0,
                    });
                }
            }
        } else {
            added += 1;
            std.debug.print("  {s:<22} {s:>11} {s:>12} {s:>9}  new\n", .{ cap.name, dims, "-", "-" });
        }

        if (update) try cwd.writeFile(io, .{ .sub_path = want_path, .data = got_bytes });
    }

    if (update) {
        std.debug.print("\nwrote {d} captures to {s}\n", .{ captures.len, expected_dir });
        return;
    }

    std.debug.print("\n", .{});
    if (added > 0) std.debug.print("{d} capture(s) had no committed reference\n", .{added});
    if (changed == 0 and added == 0) {
        std.debug.print("every capture matches its committed reference\n", .{});
    } else {
        // Deliberately not an error. Like the bench, this reports rather
        // than gates: a diff is usually an intended visual change, and the
        // reviewer is the one who decides. Renders are in bench/gallery/current.
        std.debug.print(
            "{d} capture(s) differ -- compare {s} against {s}\n",
            .{ changed, current_dir, expected_dir },
        );
    }
}
