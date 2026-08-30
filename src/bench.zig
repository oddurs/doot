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
const redact = @import("redact.zig");
const check = @import("check.zig");
const ckpt = @import("ckpt.zig");
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
    // Recorded from real sessions rather than generated -- see
    // src/record.zig and docs/roadmap/agentic.md's A0.
    .{
        .name = "agent-claude",
        .what = "a recorded agent CLI session, TUI and all",
        .bytes = @embedFile("corpus_agent_claude"),
    },
    .{
        .name = "agent-stream",
        .what = "a recorded colourised diff streaming at full speed",
        .bytes = @embedFile("corpus_agent_stream"),
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
    var screen = try grid.Screen.init(alloc, cols, rows, 1);
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
        \\doot benchmarks
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

    // Kept so the 200x60 table below can say what widening cost.
    var narrow_mib: [corpora.len]f64 = @splat(0);

    for (corpora, 0..) |corpus, ci| {
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
        narrow_mib[ci] = mibPerSec(total, b);

        try out.print(
            "  {s:<11} {d:>10.1} {d:>10.1} {d:>12.2} {d:>10.0}  {s}\n",
            .{ corpus.name, mibPerSec(total, b), mibPerSec(total, m), ns_per_byte, kib_per_frame, corpus.what },
        );
    }

    // -- parse at 200x60 -----------------------------------------------
    //
    // A second table rather than a second column, so every number in
    // bench/baseline.txt keeps meaning what it meant.
    //
    // Why it exists: **every budget on the record roadmap is stated at
    // 200x60 and nothing measured parse there.** L1 has to materialize a
    // screen in under 50 ms at that geometry, and the checkpoint spacing is
    // derived from the rate -- so deriving it from the 80x24 number would be
    // deriving it from the wrong one. Width scales every `clearRows` fill and
    // every region-scroll memcpy; height decides how often they happen.

    try out.print("\nparse: the same corpora at 200x60, the geometry the record budgets are stated at\n\n", .{});
    try out.print(
        "  {s:<11} {s:>10} {s:>10} {s:>12} {s:>12}  {s}\n",
        .{ "corpus", "MiB/s", "median", "vs 80x24", "1 MiB in ms", "what it is" },
    );
    try out.print("  {s:-<11} {s:->10} {s:->10} {s:->12} {s:->12}  {s:-<40}\n", .{ "", "", "", "", "", "" });

    for (corpora, 0..) |corpus, ci| {
        const passes = @max(1, (16 * 1024 * 1024) / corpus.bytes.len);
        const total = corpus.bytes.len * passes;

        var samples: [reps]u64 = undefined;
        for (&samples) |*s| {
            const r = try timeParse(gpa, corpus.bytes, passes, 200, 60);
            s.* = r.ns;
            sink +%= r.sink;
        }

        const b = best(&samples);
        const m = median(&samples);
        const mib = mibPerSec(total, b);
        // How long one checkpoint interval of output takes to replay: the
        // number the interval was chosen from.
        const one_mib_ms = 1000.0 / mib;

        try out.print(
            "  {s:<11} {d:>10.1} {d:>10.1} {d:>11.2}x {d:>12.1}  {s}\n",
            .{ corpus.name, mib, mibPerSec(total, m), mib / narrow_mib[ci], one_mib_ms, corpus.what },
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

    // -- redact --------------------------------------------------------
    //
    // L0 scrubs every byte off the pty before it reaches the recording, so
    // this scan sits directly in the drain path and its throughput is a
    // budget, not a curiosity: `bench/dump.sh` drains at around 48 MiB/s
    // through the real app, and a scanner slower than that halves the pty
    // rate on its own.
    //
    // The corpora are clean -- `zig build check-corpora` says so -- which
    // is also the honest worst case: every byte is examined and no match
    // ever short-circuits the scan.

    try out.print("\nredact: secret scan over pty bytes, before they are recorded\n\n", .{});
    try out.print(
        "  {s:<11} {s:>10} {s:>10} {s:>12}  {s}\n",
        .{ "corpus", "MiB/s", "median", "ns/byte", "what it is" },
    );
    try out.print("  {s:-<11} {s:->10} {s:->10} {s:->12}  {s:-<40}\n", .{ "", "", "", "", "" });

    for (corpora) |corpus| {
        // A mutable copy: scrub works in place. Made once and scrubbed
        // repeatedly, which is the same work every pass because the corpora
        // carry nothing to replace and redaction is idempotent regardless.
        const copy = try gpa.dupe(u8, corpus.bytes);
        defer gpa.free(copy);

        const passes = @max(1, (16 * 1024 * 1024) / corpus.bytes.len);
        const total = corpus.bytes.len * passes;

        var samples: [reps]u64 = undefined;
        for (&samples) |*s| {
            const t0 = nowNs();
            // Deliberately not folded into `sink`: that value is printed as
            // the `checksum` line at the bottom, and every recorded baseline
            // carries it. Adding to it would invalidate all of them to no
            // purpose.
            for (0..passes) |_| std.mem.doNotOptimizeAway(redact.scrub(copy, null));
            s.* = nowNs() - t0;
        }

        const b = best(&samples);
        const m = median(&samples);
        try out.print(
            "  {s:<11} {d:>10.1} {d:>10.1} {d:>12.2}  {s}\n",
            .{
                corpus.name,
                mibPerSec(total, b),
                mibPerSec(total, m),
                @as(f64, @floatFromInt(b)) / @as(f64, @floatFromInt(total)),
                corpus.what,
            },
        );
    }

    // -- checkpoint ----------------------------------------------------
    //
    // L1's own budget, measured before L1's design was allowed to rely on
    // it. A checkpoint is a whole terminal serialised -- two screens, the
    // scrollback, the modes -- and the sprint plan carried an *estimate* of
    // ~25 KB at 80x24 and ~780 KB at 200x60 with a full ring, together with
    // a rule: if a 200x60 full-history checkpoint exceeded about 2 MB or
    // about 20 ms to encode, the full-scrollback checkpoint was dead and the
    // design fell back to two tiers. This table is what that rule was
    // decided against.
    //
    // Each corpus is fed once into a fresh terminal at each geometry and the
    // resulting state is encoded and decoded `ck_reps` times. The `+ring`
    // rows are the worst case rather than the corpus's: a terminal whose
    // 10,000-line scrollback has been filled to capacity first.

    try out.print("\ncheckpoint: a whole terminal serialised, the unit of an L1 seek\n\n", .{});
    try out.print(
        "  {s:<11} {s:>9} {s:>11} {s:>11} {s:>11} {s:>11}\n",
        .{ "corpus", "geometry", "bytes", "encode us", "decode us", "sb lines" },
    );
    try out.print("  {s:-<11} {s:->9} {s:->11} {s:->11} {s:->11} {s:->11}\n", .{ "", "", "", "", "", "" });

    const ck_reps = 5;
    const ck_geoms = [_]struct { cols: usize, rows: usize, label: []const u8 }{
        .{ .cols = 80, .rows = 24, .label = "80x24" },
        .{ .cols = 200, .rows = 60, .label = "200x60" },
    };

    for (corpora) |corpus| {
        for (ck_geoms) |g| {
            var term = try Terminal.init(gpa, g.cols, g.rows);
            defer term.deinit();
            var parser: vt.Parser = .{};
            parser.feed(&term, corpus.bytes);
            term.replies.clearRetainingCapacity();

            var enc_samples: [ck_reps]u64 = undefined;
            var dec_samples: [ck_reps]u64 = undefined;
            var size: usize = 0;
            for (0..ck_reps) |i| {
                const t0 = nowNs();
                var e = try ckpt.encode(gpa, &term, .{}, false);
                enc_samples[i] = nowNs() - t0;
                size = e.bytes();

                var dst = try Terminal.init(gpa, g.cols, g.rows);
                const t1 = nowNs();
                _ = try ckpt.decode(gpa, e.head, e.scrollback, &dst);
                dec_samples[i] = nowNs() - t1;
                sink +%= check.checksum(&dst);
                dst.deinit();
                e.deinit(gpa);
            }

            try out.print(
                "  {s:<11} {s:>9} {d:>11} {d:>11.0} {d:>11.0} {d:>11}\n",
                .{
                    corpus.name,
                    g.label,
                    size,
                    @as(f64, @floatFromInt(best(&enc_samples))) / 1000.0,
                    @as(f64, @floatFromInt(best(&dec_samples))) / 1000.0,
                    term.scrollback.len,
                },
            );
        }
    }

    // The worst case the design rule was written about: a scrollback filled
    // to capacity, at both geometries, with content varied enough that the
    // style table cannot collapse it to nothing.
    for (ck_geoms) |g| {
        var term = try Terminal.init(gpa, g.cols, g.rows);
        defer term.deinit();
        var parser: vt.Parser = .{};
        var line: [512]u8 = undefined;
        var i: usize = 0;
        while (term.scrollback.len < @import("terminal.zig").scrollback_lines) : (i += 1) {
            const text = try std.fmt.bufPrint(
                &line,
                "\x1b[{d}m{d:0>6} the quick brown fox jumps over the lazy dog {d}\r\n",
                .{ 30 + (i % 8), i, i * 7 },
            );
            parser.feed(&term, text);
        }
        term.replies.clearRetainingCapacity();

        var enc_samples: [ck_reps]u64 = undefined;
        var dec_samples: [ck_reps]u64 = undefined;
        var size: usize = 0;
        for (0..ck_reps) |k| {
            const t0 = nowNs();
            var e = try ckpt.encode(gpa, &term, .{}, false);
            enc_samples[k] = nowNs() - t0;
            size = e.bytes();

            var dst = try Terminal.init(gpa, g.cols, g.rows);
            const t1 = nowNs();
            _ = try ckpt.decode(gpa, e.head, e.scrollback, &dst);
            dec_samples[k] = nowNs() - t1;
            sink +%= check.checksum(&dst);
            dst.deinit();
            e.deinit(gpa);
        }

        // And the flag the whole agent/TUI case rests on: with the history
        // unchanged, the encoder writes screens only and the index points at
        // the previous blob. This is the size of a checkpoint taken while a
        // full-screen program is running.
        var reuse = try ckpt.encode(gpa, &term, .{}, true);
        defer reuse.deinit(gpa);

        var label: [24]u8 = undefined;
        try out.print(
            "  {s:<11} {s:>9} {d:>11} {d:>11.0} {d:>11.0} {d:>11}\n",
            .{
                "+full ring",
                g.label,
                size,
                @as(f64, @floatFromInt(best(&enc_samples))) / 1000.0,
                @as(f64, @floatFromInt(best(&dec_samples))) / 1000.0,
                term.scrollback.len,
            },
        );
        try out.print(
            "  {s:<11} {s:>9} {d:>11} {s:>11} {s:>11} {s:>11}\n",
            .{
                try std.fmt.bufPrint(&label, "+unchanged", .{}),
                g.label,
                reuse.bytes(),
                "-",
                "-",
                "reused",
            },
        );
    }

    // -- grid checksum -------------------------------------------------
    //
    // Not a timing. This is the number a replay of a recording of these
    // bytes has to reproduce -- the arbiter for docs/roadmap/record.md,
    // printed here so a change to the parser or the grid that alters the
    // resulting screen is visible next to the diff. One pass, fixed
    // geometry, so it is reproducible on any machine.

    try out.print("\ngrid-checksum: the terminal state a replay must reproduce (one pass, 80x24)\n\n", .{});
    try out.print("  {s:<11} {s:>20}  {s}\n", .{ "corpus", "checksum", "bytes" });
    try out.print("  {s:-<11} {s:->20}  {s:-<12}\n", .{ "", "", "" });

    for (corpora) |corpus| {
        var term = try Terminal.init(gpa, 80, 24);
        defer term.deinit();
        var parser: vt.Parser = .{};
        parser.feed(&term, corpus.bytes);
        try out.print(
            "  {s:<11} {x:>20}  {d}\n",
            .{ corpus.name, check.checksum(&term), corpus.bytes.len },
        );
    }

    // Printed so the compiler cannot prove the measured work is unobservable
    // and delete it. The value itself means nothing.
    try out.print("\nchecksum {d}\n", .{sink});
    try out.flush();
}
