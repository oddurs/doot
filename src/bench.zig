//! Performance benchmarks.
//!
//! Sprint 0 of docs/roadmap/performance.md. Everything else on that plan claims a win, and
//! without a baseline none of those claims can be defended -- nor can the
//! last sprint be talked out of, which is just as valuable.
//!
//! Three things are measured here, all headless:
//!
//!   parse    Bytes from a PTY through `vt.Parser` into `Terminal`. This is
//!            the whole stack below the renderer, which is where a terminal
//!            spends its time when something dumps output at it.
//!
//!   scroll   The same corpus against a taller and taller screen. A
//!            controlled experiment rather than a measurement: it is what
//!            identified the scroll memmove as the parse bottleneck, and it
//!            now stands as the regression test for the fix. These rows
//!            should read flat.
//!
//!   scan     A full-grid read, the walk `render.draw` performs every frame.
//!            A proxy for the repaint cost that damage tracking removes and
//!            for whether shrinking `Cell` would buy anything.
//!
//! No SDL, no FreeType, no window: `vt`, `grid` and `terminal` import nothing
//! but `std`, so this runs anywhere, including a Linux CI runner.
//!
//! Numbers are reported as best-of and median across repetitions. Best-of is
//! the honest figure for "how fast can this go" -- it is the run least
//! polluted by whatever else the machine was doing -- and a median far from
//! it means the measurement is noisy and should not be trusted.

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt.zig");
const grid = @import("grid.zig");
const Terminal = @import("terminal.zig").Terminal;

/// A 60 Hz frame. Used only to express throughput in units a terminal
/// actually cares about: how much output can land between two vblanks.
const frame_ns: u64 = 16_666_667;

const Corpus = struct {
    name: []const u8,
    what: []const u8,
    bytes: []const u8,
};

const corpora = [_]Corpus{
    .{
        .name = "ascii",
        .what = "plain source dump, no escapes",
        .bytes = @embedFile("corpus_ascii"),
    },
    .{
        .name = "sgr",
        .what = "colourised build log, dense SGR",
        .bytes = @embedFile("corpus_sgr"),
    },
    .{
        .name = "scroll",
        .what = "short lines, scrolls every line",
        .bytes = @embedFile("corpus_scroll"),
    },
    .{
        .name = "altscreen",
        .what = "full-screen app redraw, absolute cursor",
        .bytes = @embedFile("corpus_altscreen"),
    },
    .{
        .name = "cjk",
        .what = "wide and multibyte text",
        .bytes = @embedFile("corpus_cjk"),
    },
    .{
        .name = "region",
        .what = "DECSTBM region + status line (vim/less/tmux)",
        .bytes = @embedFile("corpus_region"),
    },
};

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Sorted in place, so callers must not care about order afterwards.
fn median(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

fn best(xs: []const u64) u64 {
    var m: u64 = std.math.maxInt(u64);
    for (xs) |x| m = @min(m, x);
    return m;
}

fn mibPerSec(bytes: u64, ns: u64) f64 {
    if (ns == 0) return 0;
    const b: f64 = @floatFromInt(bytes);
    const s: f64 = @as(f64, @floatFromInt(ns)) / 1e9;
    return b / s / (1024.0 * 1024.0);
}

/// Feed a corpus through a fresh terminal `passes` times and return the
/// elapsed nanoseconds.
///
/// The terminal is built once and fed repeatedly rather than rebuilt per
/// pass, because that is what a real one does with a long output stream --
/// scrollback fills, the screen churns, and the allocator is not on the hot
/// path. Only the feed loop is timed.
fn timeParse(alloc: std.mem.Allocator, corpus: []const u8, passes: usize, cols: usize, rows: usize) !struct { ns: u64, sink: u64 } {
    var term = try Terminal.init(alloc, cols, rows);
    defer term.deinit();
    var parser: vt.Parser = .{};

    const t0 = nowNs();
    for (0..passes) |_| {
        parser.feed(&term, corpus);
        // Device reports would otherwise accumulate for the whole run. A
        // real terminal drains these down the PTY every frame.
        term.replies.clearRetainingCapacity();
    }
    const elapsed = nowNs() - t0;

    // Read the screen back so the optimizer cannot decide the parse was
    // dead code. Cheap next to the parse itself, and outside the timer.
    var sink: u64 = 0;
    for (term.screen().cells) |cell| sink +%= cell.cp;
    return .{ .ns = elapsed, .sink = sink };
}

/// Walk every cell of a screen the way a full repaint does.
fn timeScan(alloc: std.mem.Allocator, cols: usize, rows: usize, passes: usize) !struct { ns: u64, sink: u64 } {
    var screen = try grid.Screen.init(alloc, cols, rows);
    defer screen.deinit(alloc);

    // Fill with something varied: an all-blank screen is not what a repaint
    // walks, and a uniform one lets the branch predictor cheat.
    for (screen.cells, 0..) |*cell, i| {
        cell.cp = @intCast(0x20 + (i % 0x5e));
        cell.fg = if (i % 3 == 0) .{ .indexed = @intCast(i % 256) } else .default;
        cell.bg = if (i % 7 == 0) .{ .rgb = .{ .r = @intCast(i % 256), .g = 0x40, .b = 0x80 } } else .default;
        cell.attrs = .{ .bold = i % 5 == 0, .underline = i % 11 == 0 };
    }

    var sink: u64 = 0;
    const t0 = nowNs();
    for (0..passes) |_| {
        for (0..rows) |y| {
            for (screen.row(y)) |cell| {
                sink +%= cell.cp;
                sink +%= @intFromBool(cell.attrs.bold);
                sink +%= switch (cell.bg) {
                    .default => 0,
                    .indexed => |ix| ix,
                    .rgb => |c| c.r,
                };
            }
        }
    }
    const elapsed = nowNs() - t0;
    return .{ .ns = elapsed, .sink = sink };
}

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out_buf: [8192]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &out_buf);
    const out = &writer.interface;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const reps = 9;
    var sink: u64 = 0;

    try out.print(
        \\terminator benchmarks
        \\
        \\  zig {f} / {s} / {s}-{s}
        \\  Cell = {d} bytes, scrollback = {d} lines
        \\  best of {d} repetitions, 80x24 terminal
        \\
        \\
    , .{
        builtin.zig_version,
        @tagName(builtin.mode),
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @sizeOf(grid.Cell),
        @import("terminal.zig").scrollback_lines,
        reps,
    });

    // -- parse ---------------------------------------------------------

    try out.print("parse: PTY bytes through vt.Parser into Terminal\n\n", .{});
    try out.print(
        "  {s:<11} {s:>10} {s:>10} {s:>12} {s:>10}  {s}\n",
        .{ "corpus", "MiB/s", "median", "ns/byte", "KiB/frame", "what it is" },
    );
    try out.print("  {s:-<11} {s:->10} {s:->10} {s:->12} {s:->10}  {s:-<40}\n", .{ "", "", "", "", "", "" });

    for (corpora) |corpus| {
        // Aim at roughly 16 MiB of work per repetition so a repetition is
        // long enough to swamp clock granularity.
        const passes = @max(1, (16 * 1024 * 1024) / corpus.bytes.len);
        const total = corpus.bytes.len * passes;

        var samples: [reps]u64 = undefined;
        for (&samples) |*s| {
            const r = try timeParse(gpa, corpus.bytes, passes, 80, 24);
            s.* = r.ns;
            sink +%= r.sink;
        }

        const b = best(&samples);
        const m = median(&samples);
        const ns_per_byte = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(total));
        const kib_per_frame = mibPerSec(total, b) * 1024.0 * (@as(f64, @floatFromInt(frame_ns)) / 1e9);

        try out.print(
            "  {s:<11} {d:>10.1} {d:>10.1} {d:>12.2} {d:>10.0}  {s}\n",
            .{ corpus.name, mibPerSec(total, b), mibPerSec(total, m), ns_per_byte, kib_per_frame, corpus.what },
        );
    }

    // -- scroll sensitivity --------------------------------------------
    //
    // The one experiment that paid for this whole harness, kept as the
    // regression test for what it found.
    //
    // Throughput used to track newline density almost exactly (r = 0.99),
    // because a full-screen scroll memmoved (rows-1) x cols cells on every
    // line feed -- so the same bytes against a taller screen ran
    // proportionally slower, bottoming out at 0.20x by 80x200. Screen is a
    // ring now and rotates instead, and these rows should read flat.
    //
    // If a future change makes this curve slope again, the fast path in
    // Screen.scrollUp has stopped firing.

    try out.print("\nscroll: ascii corpus vs terminal height (same bytes, taller screen)\n\n", .{});
    try out.print(
        "  {s:<11} {s:>10} {s:>10} {s:>14} {s:>12}\n",
        .{ "geometry", "MiB/s", "median", "vs 80x24", "was moving" },
    );
    try out.print("  {s:-<11} {s:->10} {s:->10} {s:->14} {s:->12}\n", .{ "", "", "", "", "" });

    const heights = [_]usize{ 24, 48, 100, 200 };
    var base_mib: f64 = 0;
    for (heights) |h| {
        const corpus = corpora[0].bytes; // ascii
        const passes = @max(1, (8 * 1024 * 1024) / corpus.len);
        const total = corpus.len * passes;

        var samples: [reps]u64 = undefined;
        for (&samples) |*s| {
            const r = try timeParse(gpa, corpus, passes, 80, h);
            s.* = r.ns;
            sink +%= r.sink;
        }

        const b = best(&samples);
        const m = median(&samples);
        const mib = mibPerSec(total, b);
        if (h == 24) base_mib = mib;

        var label_buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "80x{d}", .{h});
        // What a line feed used to move at this height, before the ring.
        // Not a measurement of the current code, which moves no rows at
        // all here -- it is the size of the problem that went away.
        const moved_kib = (h - 1) * 80 * @sizeOf(grid.Cell) / 1024;

        try out.print(
            "  {s:<11} {d:>10.1} {d:>10.1} {d:>13.2}x {d:>12}\n",
            .{ label, mib, mibPerSec(total, m), mib / base_mib, moved_kib },
        );
    }

    // -- scan ----------------------------------------------------------

    try out.print("\nscan: full-grid read, the walk render.draw does every frame\n\n", .{});
    try out.print(
        "  {s:<11} {s:>10} {s:>10} {s:>12} {s:>10}  {s}\n",
        .{ "geometry", "us/scan", "median", "ns/cell", "KiB", "scans per 60Hz frame" },
    );
    try out.print("  {s:-<11} {s:->10} {s:->10} {s:->12} {s:->10}  {s:-<40}\n", .{ "", "", "", "", "", "" });

    const geometries = [_]struct { cols: usize, rows: usize }{
        .{ .cols = 80, .rows = 24 },
        .{ .cols = 120, .rows = 40 },
        .{ .cols = 200, .rows = 60 },
        .{ .cols = 400, .rows = 100 },
    };

    for (geometries) |g| {
        const passes = 2000;
        var samples: [reps]u64 = undefined;
        for (&samples) |*s| {
            const r = try timeScan(gpa, g.cols, g.rows, passes);
            s.* = r.ns;
            sink +%= r.sink;
        }

        const b = best(&samples);
        const m = median(&samples);
        const cells = g.cols * g.rows;
        const per_scan_ns = @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(passes));
        const per_scan_ns_med = @as(f64, @floatFromInt(m)) / @as(f64, @floatFromInt(passes));
        const kib = cells * @sizeOf(grid.Cell) / 1024;

        var label_buf: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{d}x{d}", .{ g.cols, g.rows });

        try out.print(
            "  {s:<11} {d:>10.1} {d:>10.1} {d:>12.2} {d:>10}  {d:.0}\n",
            .{
                label,
                per_scan_ns / 1000.0,
                per_scan_ns_med / 1000.0,
                per_scan_ns / @as(f64, @floatFromInt(cells)),
                kib,
                @as(f64, @floatFromInt(frame_ns)) / per_scan_ns,
            },
        );
    }

    // Printed so the compiler cannot prove the measured work is unobservable
    // and delete it. The value itself means nothing.
    try out.print("\nchecksum {d}\n", .{sink});
    try out.flush();
}
