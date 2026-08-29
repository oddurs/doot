//! End-to-end tests: a real shell on a real PTY, driving the real parser into
//! the real grid. Everything below the renderer, verified without a window.

const std = @import("std");
const vt = @import("vt.zig");
const grid = @import("grid.zig");
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
