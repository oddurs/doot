//! Materialize a recorded session: `.trec` in, `Terminal` out.
//!
//!   zig build replay -- ~/Library/Application\ Support/doot/sessions/….trec
//!
//! This is the other half of the claim [record.md](../docs/roadmap/record.md)
//! makes. `rec.zig` says a session is an append-only log; this says the screen
//! is a view of that log, derived rather than stored. If the checksum printed
//! here does not equal the one the live session had, one of the two is wrong,
//! and the end-to-end test in `src/tests.zig` is what asks.
//!
//! std only, and no window: `vt`, `grid`, `terminal` and `check` import
//! nothing but `std`, so this builds and runs anywhere the core does --
//! including the Linux CI runner, and eventually (M4) a browser.
//!
//! What is replayed and what is not:
//!
//! - `output` is fed to the parser, which is the whole of the emulator.
//! - `resize` and `control` are the mutations that never went through the
//!   parser at all. Without them a session in which the window was dragged,
//!   or `Cmd K` was pressed, replays to a different screen than it showed.
//! - `input` is **not** replayed. Those bytes went to the child, not to the
//!   screen; the child's answer is already in the `output` records.
//! - `focus`, `tick` and `meta` carry no screen state by construction.

const std = @import("std");
const vt = @import("vt.zig");
const rec = @import("rec.zig");
const check = @import("check.zig");
const Terminal = @import("terminal.zig").Terminal;

/// Build the terminal a recording ends at. The caller owns it.
///
/// The geometry comes from the header, not from the caller: a replay into a
/// different-sized grid is a different session, and would fail the checksum
/// for a reason that says nothing about the recording.
pub fn materialize(alloc: std.mem.Allocator, session: rec.Session) !Terminal {
    var term = try Terminal.init(alloc, session.header.cols, session.header.rows);
    errdefer term.deinit();
    var parser: vt.Parser = .{};

    for (session.events) |e| switch (e.kind) {
        .output => {
            parser.feed(&term, e.payload);
            // The live terminal drains these down the pty every frame. A
            // replay has nobody to send them to, and letting them pile up
            // for the length of a session would be a slow leak.
            term.replies.clearRetainingCapacity();
        },
        .resize => {
            if (e.payload.len < 4) continue;
            const cols = std.mem.readInt(u16, e.payload[0..2], .little);
            const rows = std.mem.readInt(u16, e.payload[2..4], .little);
            // Four bytes with no checksum behind them, handed straight to an
            // allocator: at `65535 x 65535` this is 68 GB. The writer will
            // not produce a geometry past `rec.max_dim`, so refusing one is
            // refusing a file that is wrong rather than one that is large.
            if (cols > rec.max_dim or rows > rec.max_dim) {
                return error.GeometryOutOfRange;
            }
            try term.resize(cols, rows);
        },
        .control => {
            if (e.payload.len < 1) continue;
            switch (@as(rec.Control, @enumFromInt(e.payload[0]))) {
                .full_reset => term.fullReset(),
                // A control this build does not know is from a newer writer.
                // Ignoring it is the only thing that can be done, and it is
                // recorded in the summary as a divergence rather than hidden.
                _ => {},
            }
        },
        else => {},
    };

    return term;
}

/// What a replay found, for a caller that wants to say so.
pub const Summary = struct {
    checksum: u64,
    events: usize,
    output_records: usize,
    input_records: usize,
    output_bytes: u64,
    redacted_records: usize,
    duration_us: u64,
    truncated_at: ?u64,
    closed_cleanly: bool,
    end_reason: ?rec.EndReason,
};

pub fn summarize(session: rec.Session, term: *Terminal) Summary {
    var output_bytes: u64 = 0;
    var last_us: u64 = 0;
    for (session.events) |e| {
        if (e.kind == .output) output_bytes += e.payload.len;
        last_us = e.at_us;
    }
    return .{
        .checksum = check.checksum(term),
        .events = session.events.len,
        .output_records = session.count(.output),
        .input_records = session.count(.input),
        .output_bytes = output_bytes,
        .redacted_records = session.redactions(),
        .duration_us = last_us,
        .truncated_at = session.truncated_at,
        .closed_cleanly = session.closed_cleanly,
        .end_reason = session.end_reason,
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print(
            \\usage: replay <session.trec>
            \\
            \\Materializes the terminal a recorded session ends at and prints
            \\its grid checksum -- the number docs/roadmap/record.md calls the
            \\arbiter -- plus what the file contains.
            \\
        , .{});
        std.process.exit(2);
    }
    const path = std.mem.span(argv[1]);

    const bytes = rec.readFile(gpa, path, 1 << 30) catch |err| {
        std.debug.print("replay: cannot read {s}: {t}\n", .{ path, err });
        std.process.exit(1);
    };
    defer gpa.free(bytes);

    var session = rec.parse(gpa, bytes) catch |err| {
        std.debug.print("replay: {s} is not a readable recording: {t}\n", .{ path, err });
        std.process.exit(1);
    };
    defer session.deinit(gpa);

    var term = try materialize(gpa, session);
    defer term.deinit();
    const s = summarize(session, &term);

    const started_s = @divFloor(session.header.wall_start_ns, std.time.ns_per_s);
    var stamp: [20]u8 = undefined;

    std.debug.print(
        \\{s}
        \\  started      {s}
        \\  geometry     {d}x{d}
        \\  session id   {x}
        \\  duration     {d:.3} s
        \\  events       {d} ({d} output, {d} input, {d} redacted)
        \\  output       {d} bytes
        \\  ended        {s}
        \\  grid checksum {x}
        \\
    , .{
        path,
        rec.stampUtc(&stamp, started_s),
        session.header.cols,
        session.header.rows,
        session.header.session_id,
        @as(f64, @floatFromInt(s.duration_us)) / 1e6,
        s.events,
        s.output_records,
        s.input_records,
        s.redacted_records,
        s.output_bytes,
        endText(s),
        s.checksum,
    });

    if (s.truncated_at) |off| {
        std.debug.print("  truncated at byte {d}: the tail of this file is torn\n", .{off});
    }
}

fn endText(s: Summary) []const u8 {
    if (!s.closed_cleanly) return "not closed -- the writer never got to finish";
    return switch (s.end_reason orelse .clean) {
        .clean => "cleanly",
        .size_cap => "at the session size cap",
        // Rare, and not the usual face of a write error: a full disk refuses
        // this record too, and such a file reads as "not closed" above.
        .write_error => "on a write error",
        _ => "for a reason this build does not know",
    };
}
