//! End-to-end tests: a real shell on a real PTY, driving the real parser into
//! the real grid. Everything below the renderer, verified without a window.

const std = @import("std");
const vt = @import("vt.zig");
const grid = @import("grid.zig");
const cli = @import("cli.zig");
const rec = @import("rec.zig");
const check = @import("check.zig");
const replay = @import("replay.zig");
const sel = @import("sel.zig");
const Terminal = @import("terminal.zig").Terminal;
const Pty = @import("pty.zig").Pty;

const testing = std.testing;

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Drive a real shell and return the terminal it produced.
const Session = struct {
    term: Terminal,
    pty: Pty,
    parser: vt.Parser = .{},

    fn start(cols: usize, rows: usize) !Session {
        var s = Session{
            .term = try Terminal.init(testing.allocator, cols, rows),
            .pty = try Pty.open(@intCast(cols), @intCast(rows), "/bin/sh"),
        };
        s.pty.setNonBlocking();

        // The line discipline echoes everything we type, so a search for
        // "FOO" would match the command that produces FOO rather than its
        // output. Turning echo off makes the screen show only real output.
        try s.send("stty -echo\n");
        _ = try s.pumpUntil("\x00", 150);
        s.term.fullReset();
        return s;
    }

    fn deinit(self: *Session) void {
        self.pty.deinit();
        self.term.deinit();
    }

    fn send(self: *Session, bytes: []const u8) !void {
        try self.pty.writeAll(bytes);
    }

    /// Pump the PTY into the terminal until `needle` shows up on screen or
    /// the deadline passes. Shells emit output in unpredictable chunks, so
    /// this loops on poll rather than assuming one read is enough -- and it
    /// always terminates, even when the needle never arrives.
    fn pumpUntil(self: *Session, needle: []const u8, timeout_ms: i32) !bool {
        var buf: [8192]u8 = undefined;
        const deadline = nowMs() + @as(u64, @intCast(timeout_ms));

        while (true) {
            const now = nowMs();
            if (now >= deadline) break;
            const remaining: i32 = @intCast(deadline - now);
            if (!self.pty.waitReadable(remaining)) break;

            const n = self.pty.read(&buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
            if (n == 0) break;
            self.parser.feed(&self.term, buf[0..n]);
            if (self.contains(needle)) return true;
        }
        return self.contains(needle);
    }

    fn contains(self: *Session, needle: []const u8) bool {
        var line: [1024]u8 = undefined;
        for (0..self.term.rows) |y| {
            const text = self.rowText(y, &line);
            if (std.mem.indexOf(u8, text, needle) != null) return true;
        }
        return false;
    }

    fn rowText(self: *Session, y: usize, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.term.screen().row(y)) |cell| {
            if (cell.wide == .spacer) continue;
            n += std.unicode.utf8Encode(cell.cp, buf[n..]) catch 0;
        }
        return std.mem.trimEnd(u8, buf[0..n], " ");
    }

    fn findRow(self: *Session, needle: []const u8) ?usize {
        var line: [1024]u8 = undefined;
        for (0..self.term.rows) |y| {
            if (std.mem.indexOf(u8, self.rowText(y, &line), needle) != null) return y;
        }
        return null;
    }

    // -- selection ------------------------------------------------------

    /// A selection over viewport cells, inclusive at both ends -- the same
    /// coordinates a click produces.
    fn selectCells(self: *Session, y0: usize, x0: usize, y1: usize, x1: usize) sel.Selection {
        return .{
            .anchor = sel.pointAt(&self.term, .{ .x = x0, .y = y0 }).?,
            .head = sel.pointAt(&self.term, .{ .x = x1, .y = y1 }).?,
        };
    }

    fn copyText(self: *Session, s: sel.Selection) ![:0]u8 {
        const norm = sel.normalize(&self.term, s) orelse
            return testing.allocator.dupeZ(u8, "");
        return sel.extract(testing.allocator, &self.term, norm);
    }

    /// Which viewport row a resolved ordinal is showing at, as a signed
    /// number: negative means it has scrolled off the top of the view.
    fn viewRowOf(self: *Session, ord: usize) isize {
        return @as(isize, @intCast(ord + self.term.view_offset)) -
            @as(isize, @intCast(self.term.scrollback.len));
    }
};

test "a real shell's output lands on the grid" {
    var s = try Session.start(80, 24);
    defer s.deinit();

    try s.send("printf 'MARKER-%s\\n' ok\n");
    try testing.expect(try s.pumpUntil("MARKER-ok", 200));
}

test "shell colors arrive as SGR attributes on the right cells" {
    var s = try Session.start(80, 24);
    defer s.deinit();

    // Print a red word, then a plain one, and check the styling actually
    // reached the cells rather than being printed as literal escape text.
    try s.send("printf '\\033[31mREDWORD\\033[0m PLAIN\\n'\n");
    try testing.expect(try s.pumpUntil("REDWORD PLAIN", 200));

    const y = s.findRow("REDWORD PLAIN").?;
    const row = s.term.screen().row(y);
    const start = std.mem.indexOf(u8, blk: {
        var buf: [1024]u8 = undefined;
        break :blk s.rowText(y, &buf);
    }, "REDWORD").?;

    try testing.expect(row[start].fg.eql(.{ .indexed = 1 })); // 'R' is red
    try testing.expect(row[start + 8].fg.eql(.default)); // 'P' is not
}

test "cursor addressing from a shell repositions output" {
    var s = try Session.start(40, 10);
    defer s.deinit();

    // Jump to row 5 col 10, print, and confirm it landed there.
    try s.send("printf '\\033[5;10HPLACED\\n'\n");
    try testing.expect(try s.pumpUntil("PLACED", 200));

    const row = s.term.screen().row(4); // row 5, zero-indexed
    try testing.expectEqual(@as(u21, 'P'), row[9].cp); // col 10, zero-indexed
}

test "clearing the screen empties the grid but keeps history" {
    var s = try Session.start(60, 12);
    defer s.deinit();

    try s.send("printf 'BEFORE-CLEAR\\n'\n");
    try testing.expect(try s.pumpUntil("BEFORE-CLEAR", 200));

    try s.send("printf '\\033[2J\\033[H'; printf 'AFTER-CLEAR\\n'\n");
    try testing.expect(try s.pumpUntil("AFTER-CLEAR", 200));
    try testing.expect(!s.contains("BEFORE-CLEAR"));
}

test "long output scrolls and fills scrollback" {
    var s = try Session.start(40, 6);
    defer s.deinit();

    try s.send("i=1; while [ $i -le 40 ]; do echo LINE$i; i=$((i+1)); done\n");
    try testing.expect(try s.pumpUntil("LINE40", 500));

    // The screen is 6 rows, so the early lines must have scrolled off into
    // history rather than vanished.
    try testing.expect(!s.contains("LINE1\n"));
    try testing.expect(s.term.scrollback.len > 20);

    // And they must be readable back through the viewport.
    s.term.scrollView(30);
    var found_early = false;
    var buf: [1024]u8 = undefined;
    for (0..s.term.rows) |y| {
        const text = s.term.viewRow(y);
        var n: usize = 0;
        for (text) |cell| n += std.unicode.utf8Encode(cell.cp, buf[n..]) catch 0;
        if (std.mem.indexOf(u8, buf[0..n], "LINE1") != null) found_early = true;
    }
    try testing.expect(found_early);
}

test "the child sees the window size we gave it" {
    var s = try Session.start(77, 21);
    defer s.deinit();

    // stty reads the size straight from the kernel's termios, so this proves
    // TIOCSWINSZ actually took effect rather than us just believing it did.
    try s.send("stty size\n");
    try testing.expect(try s.pumpUntil("21 77", 300));
}

test "resize propagates to the child process" {
    var s = try Session.start(80, 24);
    defer s.deinit();

    try s.send("printf 'READY\\n'\n");
    _ = try s.pumpUntil("READY", 200);

    try s.term.resize(100, 30);
    s.pty.resize(100, 30);

    try s.send("stty size\n");
    try testing.expect(try s.pumpUntil("30 100", 300));
}

test "utf-8 from a shell decodes into single cells" {
    var s = try Session.start(40, 8);
    defer s.deinit();

    try s.send("printf 'UTF:\\xe2\\x94\\x80\\xc3\\xa9\\n'\n");
    try testing.expect(try s.pumpUntil("UTF:", 200));

    const y = s.findRow("UTF:").?;
    const row = s.term.screen().row(y);
    try testing.expectEqual(@as(u21, 0x2500), row[4].cp); // box drawing
    try testing.expectEqual(@as(u21, 0xe9), row[5].cp); // e-acute
}

// ---------------------------------------------------------------------------
// The record
// ---------------------------------------------------------------------------
//
// L0 of docs/roadmap/record.md, and the arbiter that page names:
// **materialization**. A session is driven live on a real pty while it is
// recorded; the recording is then replayed into a fresh `Terminal` and the
// two grid checksums must be equal. If they are not, either the recorder is
// missing something the terminal did, or the replayer is not doing what the
// terminal did -- and the difference between those two is what the events in
// the file tell you.
//
// The privacy rows of S6 (docs/roadmap/security.md) are tested here and in
// `rec.zig`, together, because a recorder that ships before its privacy tests
// is a recorder that ships without them.

/// A shell on a real pty, with a session recorder attached, driven in the
/// same order `main.zig` drives them.
///
/// The ordering matters and is the thing under test: output is recorded
/// *before* it is parsed, so a crash between the two loses nothing; `resize`
/// and `control` are recorded at the point the terminal is mutated, because
/// that is what fixes their position relative to concurrent output. This
/// harness is single-threaded, so what it verifies is the *sequence*; the
/// mutex discipline that makes the sequence true under two threads is
/// documented on `App.rec_mutex`.
const Recorded = struct {
    term: Terminal,
    pty: Pty,
    parser: vt.Parser = .{},
    rec: rec.Writer,
    path: []u8,

    fn start(dir: []const u8, cols: u16, rows: u16, opts: rec.Options) !Recorded {
        var o = opts;
        o.cols = cols;
        o.rows = rows;
        var w = try rec.Writer.open(testing.allocator, dir, o);
        errdefer w.deinit();
        const path = try testing.allocator.dupe(u8, w.path);
        errdefer testing.allocator.free(path);

        var s = Recorded{
            .term = try Terminal.init(testing.allocator, cols, rows),
            .pty = try Pty.open(cols, rows, "/bin/sh"),
            .rec = w,
            .path = path,
        };
        s.pty.setNonBlocking();
        return s;
    }

    fn deinit(self: *Recorded) void {
        self.rec.deinit();
        self.pty.deinit();
        self.term.deinit();
        testing.allocator.free(self.path);
    }

    fn send(self: *Recorded, bytes: []const u8) !void {
        try self.pty.writeAll(bytes);
    }

    /// Pump until `needle` shows up or the deadline passes, recording every
    /// read before parsing it.
    fn pumpUntil(self: *Recorded, needle: []const u8, timeout_ms: i32) !bool {
        var buf: [8192]u8 = undefined;
        const deadline = nowMs() + @as(u64, @intCast(timeout_ms));
        while (true) {
            const now = nowMs();
            if (now >= deadline) break;
            const remaining: i32 = @intCast(deadline - now);
            if (!self.pty.waitReadable(remaining)) break;
            const n = self.pty.read(&buf) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
            if (n == 0) break;
            self.rec.output(buf[0..n], rec.nowNs());
            self.parser.feed(&self.term, buf[0..n]);
            if (self.contains(needle)) return true;
        }
        return self.contains(needle);
    }

    /// What `main.zig` does after `reader.join()`: the child is gone but the
    /// bytes it wrote before exiting are still in the pty buffer. Recorded as
    /// well as parsed, or the replay is short by a program's last output.
    fn drainAfterExit(self: *Recorded, timeout_ms: i32) void {
        var buf: [8192]u8 = undefined;
        const deadline = nowMs() + @as(u64, @intCast(timeout_ms));
        while (nowMs() < deadline and self.pty.waitReadable(20)) {
            const n = self.pty.read(&buf) catch break;
            if (n == 0) break;
            self.rec.output(buf[0..n], rec.nowNs());
            self.parser.feed(&self.term, buf[0..n]);
        }
    }

    fn resize(self: *Recorded, cols: u16, rows: u16) !void {
        try self.term.resize(cols, rows);
        self.rec.resize(cols, rows, rec.nowNs());
        self.pty.resize(cols, rows);
    }

    fn fullReset(self: *Recorded) void {
        self.term.fullReset();
        self.rec.control(.full_reset, rec.nowNs());
    }

    /// Whether the screen shows `needle`, **across row boundaries**.
    ///
    /// Row by row would be wrong here and is a trap the older `Session`
    /// helper in this file still has: a shell prompt is as long as the
    /// working directory's name, so whether a marker wraps onto the next row
    /// depends on where the checkout happens to live. It is a screen, not a
    /// list of lines; searching it as one string is what a person does.
    fn contains(self: *Recorded, needle: []const u8) bool {
        var screen: [64 * 1024]u8 = undefined;
        var n: usize = 0;
        for (0..self.term.rows) |y| {
            for (self.term.screen().row(y)) |cell| {
                if (cell.wide == .spacer) continue;
                if (n + 4 > screen.len) break;
                n += std.unicode.utf8Encode(cell.cp, screen[n..]) catch 0;
            }
        }
        return std.mem.indexOf(u8, screen[0..n], needle) != null;
    }
};

fn tempDir(buf: []u8, tag: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/doot-e2e-{s}-{d}-{d}", .{
        tag, std.c.getpid(), rec.nowNs() % 1_000_000,
    }) catch unreachable;
}

fn removeTree(dir: []const u8) void {
    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch return;
    if (std.c.opendir(p.ptr)) |dp| {
        while (std.c.readdir(dp)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child: [std.c.PATH_MAX]u8 = undefined;
            const c = std.fmt.bufPrintZ(&child, "{s}/{s}", .{ dir, name }) catch continue;
            _ = std.c.unlink(c.ptr);
        }
        _ = std.c.closedir(dp);
    }
    _ = std.c.rmdir(p.ptr);
}

/// Every name in `dir`, with its size, sorted -- a listing that changes if
/// anything at all is created, removed or written to.
fn listing(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch unreachable;
    if (std.c.opendir(p.ptr)) |dp| {
        defer _ = std.c.closedir(dp);
        while (std.c.readdir(dp)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var child: [std.c.PATH_MAX]u8 = undefined;
            const c = std.fmt.bufPrintZ(&child, "{s}/{s}", .{ dir, name }) catch continue;
            const fd = std.c.open(c.ptr, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            var size: i64 = -1;
            if (fd >= 0) {
                var st: std.c.Stat = undefined;
                if (std.c.fstat(fd, &st) == 0) size = st.size;
                _ = std.c.close(fd);
            }
            try names.append(alloc, try std.fmt.allocPrint(alloc, "{s} {d}\n", .{ name, size }));
        }
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (names.items) |n| try out.appendSlice(alloc, n);
    return out.toOwnedSlice(alloc);
}

test "a recorded session replays to the same grid" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "arbiter");
    defer removeTree(dir);

    var s = try Recorded.start(dir, 40, 8, .{ .cols = 0, .rows = 0 });
    defer s.deinit();

    // The line discipline echoes what we type, so turn it off and reset --
    // and record the reset, because it is a terminal mutation no bytes went
    // through the parser for. Without the record the replay diverges here
    // and nowhere else, which is exactly how `Cmd K` would have broken it.
    // Echo off and no prompt, so the screen shows the output under test
    // rather than the name of whatever directory this was run from.
    try s.send("stty -echo; PS1=''\n");
    _ = try s.pumpUntil("\x00", 250);
    s.fullReset();

    // SGR, so colour and attributes have to survive.
    try s.send("printf '\\033[31;1mREDBOLD\\033[0m PLAIN\\n'\n");
    try testing.expect(try s.pumpUntil("REDBOLD PLAIN", 400));

    // A line longer than the screen is wide, so the wrap -- and the deferred
    // wrap at the right margin -- has to replay identically.
    try s.send("printf '%s\\n' AAAAAAAAAABBBBBBBBBBCCCCCCCCCCDDDDDDDDDDEEEEEEEEEE\n");
    try testing.expect(try s.pumpUntil("EEEEEEEEEE", 400));

    // Enough lines to push content into scrollback, which the checksum walks
    // through `back(i)` rather than in memory order.
    try s.send("i=1; while [ $i -le 30 ]; do echo LINE$i; i=$((i+1)); done\n");
    try testing.expect(try s.pumpUntil("LINE30", 800));

    // Alt screen in and out. The primary must come back exactly, and the
    // parked alt is hashed too.
    try s.send("printf '\\033[?1049hALTSCREEN\\033[?1049l'\n");
    try testing.expect(try s.pumpUntil("LINE30", 400));

    // A resize in the middle of the stream. In the app this happens under
    // the terminal mutex with the recorder nested inside it; here the point
    // is that the record lands between the output before it and the output
    // after it.
    try s.resize(60, 12);

    // A second `fullReset`, **after** the resize, and this one is what makes
    // the `control` record testable at all. `Terminal.resize` throws the
    // whole scrollback away when `cols` changes, so the only trace the first
    // reset left -- a shorter history -- was erased three lines above, and
    // dropping `.full_reset => term.fullReset()` from `replay.zig` changed no
    // checksum. Nothing below discards state, so this one has to replay.
    s.fullReset();

    try s.send("printf 'AFTER-RESIZE\\n'\n");
    try testing.expect(try s.pumpUntil("AFTER-RESIZE", 400));

    // And exit -- printing on the way out, without pumping for it, so the
    // bytes really are still in the pty when the child is gone and the
    // post-exit drain is the only thing that can collect them. Mutation
    // testing is why this is shaped like this: an `exit` on its own left
    // nothing in the buffer, so dropping the drain's `rec.output` call
    // changed no checksum and the test passed anyway.
    try s.send("printf 'DRAIN-TAIL-8823\\n'; exit\n");
    s.drainAfterExit(400);
    try testing.expect(s.contains("DRAIN-TAIL-8823"));

    const live = check.checksum(&s.term);
    s.rec.close(.clean);

    const bytes = try rec.readFile(testing.allocator, s.path, 64 << 20);
    defer testing.allocator.free(bytes);
    var session = try rec.parse(testing.allocator, bytes);
    defer session.deinit(testing.allocator);

    try testing.expect(session.closed_cleanly);
    try testing.expectEqual(@as(?u64, null), session.truncated_at);
    // A real shell session carries no secret shape, so nothing was replaced.
    // If this ever fires, the recording is not a faithful copy of the screen
    // and the checksum below is comparing two different things.
    try testing.expectEqual(@as(usize, 0), session.redactions());
    try testing.expectEqual(@as(u64, 0), s.rec.stats.redactions);
    // The mutations that never went through the parser are in the file.
    try testing.expectEqual(@as(usize, 2), session.count(.control));
    try testing.expectEqual(@as(usize, 1), session.count(.resize));
    // Input was never asked for, so none of it is here.
    try testing.expectEqual(@as(usize, 0), session.count(.input));

    // The header carries the geometry, and the fresh terminal is built from
    // it: replaying into a different-sized grid is a different session.
    var replayed = try replay.materialize(testing.allocator, session);
    defer replayed.deinit();
    // The resize happened mid-session, so the header's geometry is not the
    // final one -- which is the point of recording the resize at all.
    try testing.expectEqual(@as(u16, 40), session.header.cols);
    try testing.expectEqual(@as(usize, 60), replayed.cols);
    try testing.expectEqual(@as(usize, 12), replayed.rows);

    const materialized = check.checksum(&replayed);
    if (live != materialized) {
        std.debug.print(
            "live grid {x} != replayed grid {x} over {d} events\n",
            .{ live, materialized, session.events.len },
        );
        return error.ReplayDiverged;
    }
}

test "the recording holds the bytes the screen was painted from" {
    // The checksum says the two grids agree. This says the file is a
    // recording of *this* session rather than of some other one that happens
    // to produce the same screen.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "faithful");
    defer removeTree(dir);

    var s = try Recorded.start(dir, 60, 10, .{ .cols = 0, .rows = 0 });
    defer s.deinit();
    try s.send("stty -echo; PS1=''\n");
    _ = try s.pumpUntil("\x00", 250);
    try s.send("printf 'UNIQUE-MARKER-9137\\n'\n");
    try testing.expect(try s.pumpUntil("UNIQUE-MARKER-9137", 400));
    s.rec.close(.clean);

    const bytes = try rec.readFile(testing.allocator, s.path, 64 << 20);
    defer testing.allocator.free(bytes);
    var session = try rec.parse(testing.allocator, bytes);
    defer session.deinit(testing.allocator);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (session.events) |e| {
        if (e.kind == .output) try joined.appendSlice(testing.allocator, e.payload);
    }
    try testing.expect(std.mem.indexOf(u8, joined.items, "UNIQUE-MARKER-9137") != null);
}

test "a replay refuses a resize record no writer could have produced" {
    // Records carry no CRC, so one flipped byte in a four-byte payload is a
    // `Terminal.resize(65535, 65535)` -- 4.3 billion cells, about 68 GB --
    // from a file the reader was otherwise happy with. The writer is bounded
    // by `rec.max_dim`; before this the reader bounded nothing.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "geom");
    defer removeTree(dir);

    var w = try rec.Writer.open(testing.allocator, dir, .{ .cols = 40, .rows = 8 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);
    w.output("hello\n", rec.nowNs());
    w.resize(60, 12, rec.nowNs());
    w.close(.clean);
    w.deinit();

    const bytes = try rec.readFile(testing.allocator, path, 64 << 20);
    defer testing.allocator.free(bytes);

    // Walk the records rather than searching for a byte pattern: a payload
    // can spell a record header, and a test that patched the wrong four
    // bytes would pass for the wrong reason.
    var off: usize = rec.header_len;
    var payload_at: ?usize = null;
    while (off + rec.record_header_len <= bytes.len) {
        const len = std.mem.readInt(u16, bytes[off + 2 ..][0..2], .little);
        if (bytes[off] == @intFromEnum(rec.Type.resize)) {
            payload_at = off + rec.record_header_len;
            break;
        }
        off += rec.record_header_len + len;
    }
    @memset(bytes[payload_at.?..][0..4], 0xff);

    var session = try rec.parse(testing.allocator, bytes);
    defer session.deinit(testing.allocator);
    try testing.expectError(
        error.GeometryOutOfRange,
        replay.materialize(testing.allocator, session),
    );
}

// -- S6: the privacy rows -------------------------------------------------

test "S6: a session with no flags records output and never a keystroke" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "s6-default");
    defer removeTree(dir);

    // The decision main.zig makes, made the same way: parse the flags, and
    // open a recorder only if they said to.
    const argv = [_][*:0]const u8{"doot"};
    const opts = cli.parseArgs(&argv).run;
    try testing.expect(opts.record);
    try testing.expect(!opts.record_input);

    var s = try Recorded.start(dir, 40, 8, .{
        .cols = 0,
        .rows = 0,
        .record_input = opts.record_input,
    });
    defer s.deinit();

    // Type something that would be a password if this were one.
    const typed = "SECRET-PASSPHRASE-4471\n";
    s.rec.input(typed, rec.nowNs());
    try s.send("stty -echo; PS1=''\n");
    _ = try s.pumpUntil("\x00", 250);
    try s.send("printf 'VISIBLE\\n'\n");
    try testing.expect(try s.pumpUntil("VISIBLE", 400));
    s.rec.close(.clean);

    const bytes = try rec.readFile(testing.allocator, s.path, 64 << 20);
    defer testing.allocator.free(bytes);

    // Scanned over the whole file, not read back off a flag: a flag says
    // what the writer believed, and the question is what is on the disk.
    try testing.expect(std.mem.indexOf(u8, bytes, "SECRET-PASSPHRASE") == null);
    var session = try rec.parse(testing.allocator, bytes);
    defer session.deinit(testing.allocator);
    for (session.events) |e| {
        if (e.kind == .input) return error.InputWasRecordedByDefault;
    }
    try testing.expect(session.count(.output) > 0);
}

test "S6: an incognito session leaves the sessions directory byte-identical" {
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "s6-incognito");
    defer removeTree(dir);
    try testing.expect(rec.makeDir(dir));

    // A recording already in the directory, so "unchanged" means something
    // stronger than "still empty".
    var earlier = try rec.Writer.open(testing.allocator, dir, .{ .cols = 10, .rows = 3 });
    earlier.output("an earlier session\n", rec.nowNs());
    earlier.close(.clean);
    earlier.deinit();

    const before = try listing(testing.allocator, dir);
    defer testing.allocator.free(before);
    try testing.expect(before.len > 0);

    const argv = [_][*:0]const u8{ "doot", "--incognito", "--record-dir", "/unused" };
    const opts = cli.parseArgs(&argv).run;
    try testing.expect(!opts.record);
    try testing.expectEqual(cli.RecordState.incognito, opts.recordState());

    // Run a real session through the branch main.zig takes. Nothing is
    // opened, so nothing is created -- and if that branch is ever inverted,
    // the listing below moves.
    var w = if (opts.record)
        try rec.Writer.open(testing.allocator, dir, .{ .cols = 40, .rows = 8 })
    else
        rec.Writer.disabled(testing.allocator);
    defer w.deinit();

    var term = try Terminal.init(testing.allocator, 40, 8);
    defer term.deinit();
    var pty = try Pty.open(40, 8, "/bin/sh");
    defer pty.deinit();
    pty.setNonBlocking();
    var parser: vt.Parser = .{};

    try pty.writeAll("printf 'INCOGNITO-OUTPUT\\n'\n");
    var buf: [8192]u8 = undefined;
    const deadline = nowMs() + 400;
    while (nowMs() < deadline and pty.waitReadable(50)) {
        const n = pty.read(&buf) catch break;
        if (n == 0) break;
        w.output(buf[0..n], rec.nowNs());
        parser.feed(&term, buf[0..n]);
    }
    w.close(.clean);

    const after = try listing(testing.allocator, dir);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
}

test "S6: deleting a recording is the whole of deleting it" {
    // L0 builds no index. The file is the only artifact, so `rm` is the
    // delete -- and this asserts it by scanning every remaining byte in the
    // directory for the session id.
    var dir_buf: [256]u8 = undefined;
    const dir = tempDir(&dir_buf, "s6-delete");
    defer removeTree(dir);

    var w = try rec.Writer.open(testing.allocator, dir, .{ .cols = 40, .rows = 8 });
    const path = try testing.allocator.dupe(u8, w.path);
    defer testing.allocator.free(path);
    const id = w.sessionId();
    w.output("something worth forgetting\n", rec.nowNs());
    w.close(.clean);
    w.deinit();

    // A second recording, so the scan below is over a directory with
    // something in it rather than an empty one.
    var other = try rec.Writer.open(testing.allocator, dir, .{ .cols = 40, .rows = 8 });
    other.output("a session that stays\n", rec.nowNs());
    other.close(.clean);
    other.deinit();

    var path_z: [std.c.PATH_MAX]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path_z, "{s}", .{path}) catch unreachable;
    try testing.expectEqual(@as(c_int, 0), std.c.unlink(p.ptr));

    var dir_z: [std.c.PATH_MAX]u8 = undefined;
    const d = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch unreachable;
    const dp = std.c.opendir(d.ptr).?;
    defer _ = std.c.closedir(dp);
    var files: usize = 0;
    while (std.c.readdir(dp)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var child: [std.c.PATH_MAX]u8 = undefined;
        const c = std.fmt.bufPrintZ(&child, "{s}/{s}", .{ dir, name }) catch continue;
        const content = try rec.readFile(testing.allocator, c, 64 << 20);
        defer testing.allocator.free(content);
        files += 1;
        // Neither the id itself nor the eight hex digits of it in a filename.
        try testing.expect(std.mem.indexOf(u8, content, &id) == null);
        var hex: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ id[0], id[1], id[2], id[3] }) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, name, &hex) == null);
    }
    try testing.expectEqual(@as(usize, 1), files);
    try testing.expectError(error.FileNotFound, rec.readFile(testing.allocator, path, 1 << 20));
}

// ---------------------------------------------------------------------------
// E1: selection over a real pty
// ---------------------------------------------------------------------------
//
// The arbiter docs/roadmap/essentials.md names for this roadmap is this file:
// a real shell, a real pty, assertions on the grid. Each test below drives the
// feature through the shell and fails without it.

/// A shell with echo off and no prompt, so the screen holds the output under
/// test and nothing else -- a prompt is as long as the working directory's
/// name, which decides whether a marker wraps on some machines and not others.
fn quietSession(cols: usize, rows: usize) !Session {
    var s = try Session.start(cols, rows);
    errdefer s.deinit();
    try s.send("PS1=''\n");
    _ = try s.pumpUntil("\x00", 200);
    s.term.fullReset();
    return s;
}

test "a selection stays on its text while a hundred lines scroll under it" {
    // The whole point of the line-id primitive, and what the sprint's `yes`
    // clause means: a selection made before a burst of output covers the same
    // characters afterwards, having moved down the history by exactly as many
    // lines as were printed.
    var s = try quietSession(80, 24);
    defer s.deinit();

    try s.send("printf 'SELECT-ME-4471\\n'\n");
    try testing.expect(try s.pumpUntil("SELECT-ME-4471", 400));

    // Selected while it is on screen, which is the only time a user could
    // have selected it.
    const marker_row = s.findRow("SELECT-ME-4471") orelse return error.MarkerNotOnScreen;
    const selection = sel.normalize(&s.term, s.selectCells(marker_row, 0, marker_row, 13)).?;
    const before = try sel.extract(testing.allocator, &s.term, selection);
    defer testing.allocator.free(before);
    try testing.expectEqualStrings("SELECT-ME-4471", before);

    // Fill the screen, so that from here on every completed line pushes
    // exactly one line into history and the arithmetic below is exact.
    try s.send("i=1; while [ $i -le 40 ]; do echo FILL$i; i=$((i+1)); done\n");
    try testing.expect(try s.pumpUntil("FILL40", 800));
    _ = try s.pumpUntil("\x00", 150);

    const row_before = s.viewRowOf(sel.resolve(&s.term, selection).?.start.ord);
    const history_before = s.term.scrollback.len;

    // A hundred lines, then a sentinel, then drained to quiet: at that point
    // 101 lines have been completed and every one of them pushed a line into
    // history, because the screen was already full.
    try s.send("i=1; while [ $i -le 100 ]; do echo NOISE$i; i=$((i+1)); done; echo SENTINEL\n");
    try testing.expect(try s.pumpUntil("SENTINEL", 2000));
    _ = try s.pumpUntil("\x00", 250);

    const pushed = s.term.scrollback.len - history_before;
    try testing.expectEqual(@as(usize, 101), pushed);

    // Byte-identical. Not "still finds the marker": the same bytes.
    const after = try sel.extract(testing.allocator, &s.term, selection);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);

    // And it is exactly `pushed` rows further back than it was -- the row
    // index moved, the identity did not.
    const row_after = s.viewRowOf(sel.resolve(&s.term, selection).?.start.ord);
    try testing.expectEqual(row_before - @as(isize, @intCast(pushed)), row_after);

    // Scrolling back by that much puts it exactly where it started.
    s.term.scrollView(@intCast(pushed));
    try testing.expectEqual(row_before, s.viewRowOf(sel.resolve(&s.term, selection).?.start.ord));
}

test "a selection across a wrapped line copies it as one line" {
    // A narrow terminal, so a line the shell prints as one line arrives as
    // three rows -- and copying it has to give back what the shell printed,
    // with no newlines the shell never sent.
    var s = try quietSession(20, 8);
    defer s.deinit();

    const long = "abcdefghijklmnopqrstuvwxyz0123456789";
    try s.send("printf '%s\\n' abcdefghijklmnopqrstuvwxyz0123456789\n");
    try testing.expect(try s.pumpUntil("0123456789", 400));

    const first = s.findRow("abcdefghij") orelse return error.NotOnScreen;
    const last = s.findRow("0123456789") orelse return error.NotOnScreen;
    try testing.expect(last > first);
    // Every row but the last really did wrap, rather than being separate
    // lines that happen to look like one.
    for (first..last) |y| try testing.expect(s.term.screen().rowMeta(y).flags.wrapped);
    try testing.expect(!s.term.screen().rowMeta(last).flags.wrapped);

    const text = try s.copyText(s.selectCells(first, 0, last, 19));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(long, text);
}

test "a selection across a wide character copies it once, with no spacer" {
    var s = try quietSession(40, 8);
    defer s.deinit();

    // Three ideographs between two ASCII markers, printed as UTF-8 bytes.
    try s.send("printf '[\\344\\270\\200\\344\\272\\214\\344\\270\\211]\\n'\n");
    try testing.expect(try s.pumpUntil("[", 400));
    const y = s.findRow("[") orelse return error.NotOnScreen;
    try testing.expectEqual(grid.Wide.wide, s.term.screen().at(1, y).wide);
    try testing.expectEqual(grid.Wide.spacer, s.term.screen().at(2, y).wide);

    const text = try s.copyText(s.selectCells(y, 0, y, 7));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("[\u{4e00}\u{4e8c}\u{4e09}]", text);

    // And an edge that lands on a spacer snaps onto the character it belongs
    // to rather than copying the blank half of it.
    const half = try s.copyText(s.selectCells(y, 2, y, 2));
    defer testing.allocator.free(half);
    try testing.expectEqualStrings("\u{4e00}", half);
}

test "a selection spanning the scrollback boundary copies both halves" {
    var s = try quietSession(40, 6);
    defer s.deinit();

    try s.send("i=1; while [ $i -le 20 ]; do echo ROW$i; i=$((i+1)); done\n");
    try testing.expect(try s.pumpUntil("ROW20", 800));
    _ = try s.pumpUntil("\x00", 150);
    try testing.expect(s.term.scrollback.len > 10);

    // Scroll back so the viewport straddles the boundary: some rows come from
    // history, the rest from the live screen. One accessor covers both, which
    // is why this needs no special case in the extractor.
    s.term.scrollView(3);
    var buf: [256]u8 = undefined;
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    for (0..s.term.rows) |y| {
        if (y > 0) try want.append(testing.allocator, '\n');
        var n: usize = 0;
        for (s.term.viewRow(y)) |cell| {
            if (cell.wide == .spacer) continue;
            n += std.unicode.utf8Encode(cell.cp, buf[n..]) catch 0;
        }
        try want.appendSlice(testing.allocator, std.mem.trimEnd(u8, buf[0..n], " "));
    }

    const text = try s.copyText(s.selectCells(0, 0, s.term.rows - 1, s.term.cols - 1));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(want.items, text);
    // Really both halves: the first rows came out of the ring, not the screen.
    try testing.expect(std.mem.indexOf(u8, text, "ROW") != null);
}

test "a program taking the alt screen clears the selection" {
    var s = try quietSession(40, 8);
    defer s.deinit();

    try s.send("printf 'PRIMARY-TEXT\\n'\n");
    try testing.expect(try s.pumpUntil("PRIMARY-TEXT", 400));
    const y = s.findRow("PRIMARY-TEXT") orelse return error.NotOnScreen;
    s.term.setSelection(s.selectCells(y, 0, y, 11));
    try testing.expect(s.term.selection != null);

    // What vim, less and htop all do on the way in. The alt screen is a
    // different set of lines, so a highlight left behind would be sitting
    // over text that is not the text it was taken from.
    try s.send("printf '\\033[?1049hALT\\n'\n");
    try testing.expect(try s.pumpUntil("ALT", 400));
    try testing.expect(s.term.selection == null);
}
