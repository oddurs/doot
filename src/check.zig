//! The arbiter for the record: a hash of everything a replay must reproduce.
//!
//! [record.md](../docs/roadmap/record.md) says any screen at any moment is
//! reproduced from the log, bit-identical to what was drawn. "Bit-identical"
//! needs one number that says so, and this is it: run a session live, replay
//! its `.trec` into a fresh `Terminal`, and the two checksums are equal or
//! the recording is wrong.
//!
//! **Wyhash, not a sum.** `grid.zig` makes the screen a ring, so logical row
//! order and memory order are different things -- and a sum is exactly the
//! wrong shape, because it cannot tell a correct screen from a rotated one.
//! Every walk here goes through `row(y)` and `back(i)`, in logical order, and
//! the hash is order-sensitive on purpose.
//!
//! **What is deliberately excluded**, because it is a property of the window
//! rather than of the stream: `view_offset` (where the user scrolled to),
//! `dirty` (whose value depends only on when the renderer last looked),
//! `bell`, `title` and `replies` (drained down the pty every frame, so a
//! replay that never drains them would diverge for a reason that says
//! nothing about the recording).
//!
//! Both screens are hashed, not just the active one. An alt-screen program
//! that exits leaves the primary behind it, and a replay that got the
//! primary wrong while `on_alt` happened to be false would otherwise pass.
//!
//! std only: this runs on the Linux CI runner, in the bench, and in
//! `replay.zig`.

const std = @import("std");
const grid = @import("grid.zig");
const Terminal = @import("terminal.zig").Terminal;

const Hasher = std.hash.Wyhash;

fn u8v(h: *Hasher, v: u8) void {
    h.update(&[_]u8{v});
}

fn u64v(h: *Hasher, v: u64) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    h.update(&b);
}

fn boolv(h: *Hasher, v: bool) void {
    u8v(h, @intFromBool(v));
}

/// A colour, tag first. Written by hand rather than hashing the union's
/// bytes: a tagged union has padding, and padding is whatever was in the
/// allocation before it.
fn colorv(h: *Hasher, c: grid.Color) void {
    switch (c) {
        .default => u8v(h, 0),
        .indexed => |i| {
            u8v(h, 1);
            u8v(h, i);
        },
        .rgb => |v| {
            u8v(h, 2);
            u8v(h, v.r);
            u8v(h, v.g);
            u8v(h, v.b);
        },
    }
}

/// Every field of a cell that the parser can set. `Cell` is 16 bytes with
/// padding in it, so this is field by field for the same reason `colorv` is.
fn cellv(h: *Hasher, c: grid.Cell) void {
    u64v(h, c.cp);
    colorv(h, c.fg);
    colorv(h, c.bg);
    u8v(h, @as(u8, @bitCast(c.attrs)));
    u8v(h, @intFromEnum(c.wide));
}

fn cursorv(h: *Hasher, c: @import("terminal.zig").Cursor) void {
    u64v(h, c.x);
    u64v(h, c.y);
    colorv(h, c.fg);
    colorv(h, c.bg);
    u8v(h, @as(u8, @bitCast(c.attrs)));
}

fn screenv(h: *Hasher, s: *const grid.Screen) void {
    u64v(h, s.cols);
    u64v(h, s.rows);
    // Logical order, one row at a time. `s.cells` is in ring order and
    // hashing it directly would call a rotated screen equal to a correct
    // one -- which is the single most likely way a replay goes wrong.
    for (0..s.rows) |y| for (s.row(y)) |cell| cellv(h, cell);
}

/// A hash of the terminal state a replay has to reproduce.
pub fn checksum(term: *Terminal) u64 {
    var h = Hasher.init(0);

    u64v(&h, term.cols);
    u64v(&h, term.rows);

    cursorv(&h, term.cursor);
    cursorv(&h, term.saved_cursor);
    boolv(&h, term.pending_wrap);
    boolv(&h, term.on_alt);

    u64v(&h, term.scroll_top);
    u64v(&h, term.scroll_bot);

    const m = term.modes;
    boolv(&h, m.wrap);
    boolv(&h, m.cursor_visible);
    boolv(&h, m.app_cursor);
    boolv(&h, m.origin);
    boolv(&h, m.app_keypad);
    boolv(&h, m.bracketed_paste);
    boolv(&h, m.mouse);

    u64v(&h, term.tabstops.len);
    for (term.tabstops) |t| boolv(&h, t);

    screenv(&h, &term.primary);
    screenv(&h, &term.alt);

    // Scrollback newest-first through `back`, which is the only accessor
    // that knows where the ring's head is.
    u64v(&h, term.scrollback.len);
    for (0..term.scrollback.len) |i| {
        const line = term.scrollback.back(i) orelse break;
        for (line) |cell| cellv(&h, cell);
    }

    return h.final();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// An arbiter that cannot tell two different terminals apart is worse than no
// arbiter, because it makes every replay test pass. So the tests here are
// mutations: change one thing the checksum claims to cover and assert the
// number moves.

const testing = std.testing;
const vt = @import("vt.zig");

fn feed(term: *Terminal, bytes: []const u8) void {
    var p: vt.Parser = .{};
    p.feed(term, bytes);
}

test "the same bytes into the same geometry give the same checksum" {
    var a = try Terminal.init(testing.allocator, 20, 5);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 20, 5);
    defer b.deinit();

    const bytes = "hello\r\n\x1b[31mred\x1b[0m\r\nthird line\r\n";
    feed(&a, bytes);
    feed(&b, bytes);
    try testing.expectEqual(checksum(&a), checksum(&b));
}

test "a rotated screen does not hash the same as an unrotated one" {
    // The property a sum would get wrong. Both terminals end up holding the
    // same rows in the same *memory*, but in a different logical order.
    var a = try Terminal.init(testing.allocator, 4, 3);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 4, 3);
    defer b.deinit();

    feed(&a, "aaaa\r\nbbbb\r\ncccc");
    feed(&b, "bbbb\r\ncccc\r\naaaa");
    try testing.expect(checksum(&a) != checksum(&b));
}

test "every field the checksum claims to cover moves it" {
    const Case = struct { name: []const u8, bytes: []const u8 };
    const base = "text\r\n\x1b[2;3Hx";

    const cases = [_]Case{
        .{ .name = "a printed cell", .bytes = base ++ "Z" },
        .{ .name = "cursor position", .bytes = base ++ "\x1b[5;5H" },
        .{ .name = "cursor colour", .bytes = base ++ "\x1b[38;5;99m" },
        .{ .name = "cursor attributes", .bytes = base ++ "\x1b[1m" },
        .{ .name = "saved cursor", .bytes = base ++ "\x1b[9;9H\x1b7\x1b[1;1H" },
        .{ .name = "scroll region", .bytes = base ++ "\x1b[2;4r" },
        .{ .name = "wrap mode", .bytes = base ++ "\x1b[?7l" },
        .{ .name = "cursor visibility", .bytes = base ++ "\x1b[?25l" },
        .{ .name = "application cursor keys", .bytes = base ++ "\x1b[?1h" },
        .{ .name = "origin mode", .bytes = base ++ "\x1b[?6h" },
        .{ .name = "bracketed paste", .bytes = base ++ "\x1b[?2004h" },
        .{ .name = "mouse reporting", .bytes = base ++ "\x1b[?1000h" },
        .{ .name = "the alt screen", .bytes = base ++ "\x1b[?1049h" },
        .{ .name = "tab stops", .bytes = base ++ "\x1b[3g" },
        .{ .name = "scrollback", .bytes = base ++ "\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n" },
    };

    var plain = try Terminal.init(testing.allocator, 20, 5);
    defer plain.deinit();
    feed(&plain, base);
    const reference = checksum(&plain);

    for (cases) |case| {
        var t = try Terminal.init(testing.allocator, 20, 5);
        defer t.deinit();
        feed(&t, case.bytes);
        if (checksum(&t) == reference) {
            std.debug.print("checksum is blind to: {s}\n", .{case.name});
            return error.ChecksumMissesAField;
        }
    }
}

test "pending_wrap moves the checksum on its own" {
    // Printing exactly `cols` characters leaves the cursor on the last
    // column with the wrap deferred; printing one fewer does not. Nothing
    // else about the two screens differs, so this field has to be hashed
    // or a replay could stop one character short and still pass.
    var a = try Terminal.init(testing.allocator, 5, 3);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 5, 3);
    defer b.deinit();

    feed(&a, "abcde");
    feed(&b, "abcde\x1b[5G");
    try testing.expect(a.pending_wrap and !b.pending_wrap);
    try testing.expect(checksum(&a) != checksum(&b));
}

test "the inactive screen is hashed too" {
    // Enter the alt screen, write to it, leave. `on_alt` is false in both,
    // the primary is identical in both, and only the parked alt differs.
    var a = try Terminal.init(testing.allocator, 10, 3);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 10, 3);
    defer b.deinit();

    feed(&a, "\x1b[?1049hALT-A\x1b[?1049l");
    feed(&b, "\x1b[?1049hALT-B\x1b[?1049l");
    try testing.expect(!a.on_alt and !b.on_alt);
    try testing.expect(checksum(&a) != checksum(&b));
}

test "scrollback content moves the checksum with the screen held still" {
    // Isolating scrollback, which the case table above cannot: every way of
    // producing history also moves the screen and the cursor, so a checksum
    // that hashed the screen and skipped the ring entirely still passed.
    // Mutation testing found that; this is the test it was missing.
    //
    // Two two-row terminals whose visible rows, cursor and modes are
    // identical, and whose history is not.
    var a = try Terminal.init(testing.allocator, 4, 2);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 4, 2);
    defer b.deinit();

    feed(&a, "AAA\r\nBBB\r\nCCC\r\nDDD");
    feed(&b, "ZZZ\r\nBBB\r\nCCC\r\nDDD");

    // The screens really are the same, so only the history can be the
    // difference the checksum sees.
    for (0..2) |y| {
        for (a.screen().row(y), b.screen().row(y)) |ca, cb| {
            try testing.expectEqual(ca.cp, cb.cp);
        }
    }
    try testing.expectEqual(a.cursor.x, b.cursor.x);
    try testing.expectEqual(a.cursor.y, b.cursor.y);
    try testing.expectEqual(a.scrollback.len, b.scrollback.len);
    try testing.expect(checksum(&a) != checksum(&b));
}

test "how much history there is moves the checksum" {
    var a = try Terminal.init(testing.allocator, 4, 2);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 4, 2);
    defer b.deinit();

    feed(&a, "CCC\r\nDDD");
    feed(&b, "AAA\r\nCCC\r\nDDD");
    try testing.expect(a.scrollback.len != b.scrollback.len);
    try testing.expect(checksum(&a) != checksum(&b));
}

test "the view offset and the dirty flag are not part of it" {
    var t = try Terminal.init(testing.allocator, 10, 3);
    defer t.deinit();
    feed(&t, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");

    const before = checksum(&t);
    t.scrollView(2);
    t.dirty = true;
    t.bell = true;
    try t.replies.appendSlice(testing.allocator, "\x1b[0n");
    try t.title.appendSlice(testing.allocator, "a title");
    try testing.expectEqual(before, checksum(&t));
}
