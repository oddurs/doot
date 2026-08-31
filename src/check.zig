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
//! Two things E1 added are on opposite sides of that line, and which side
//! each is on is the whole argument:
//!
//! - A row's **`wrapped` flag is hashed.** It is a property of the byte
//!   stream -- a replay that got wrapping wrong *is* wrong -- and it is the
//!   only thing that tells two screens with identical cells apart when one
//!   was reached by wrapping at the margin and the other by a line feed.
//! - A row's **line id is not**, and neither is the **selection**. An id is a
//!   property of this terminal's history: two terminals fed the same bytes
//!   from different starting points hold the same screen with different
//!   numbers on it. The selection is view state, like `view_offset`. Hashing
//!   either would manufacture divergences that say nothing about the
//!   recording -- the exact failure mode this file exists to avoid.
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

/// A row's metadata, minus its identity. See the header: the flags are the
/// stream's, the id is this terminal's history's.
fn flagsv(h: *Hasher, m: grid.RowMeta) void {
    u8v(h, @as(u8, @bitCast(m.flags)));
}

fn screenv(h: *Hasher, s: *const grid.Screen) void {
    u64v(h, s.cols);
    u64v(h, s.rows);
    // Logical order, one row at a time. `s.cells` is in ring order and
    // hashing it directly would call a rotated screen equal to a correct
    // one -- which is the single most likely way a replay goes wrong.
    for (0..s.rows) |y| {
        flagsv(h, s.rowMeta(y).*);
        for (s.row(y)) |cell| cellv(h, cell);
    }
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
    boolv(&h, m.mouse_sgr);

    u64v(&h, term.tabstops.len);
    for (term.tabstops) |t| boolv(&h, t);

    screenv(&h, &term.primary);
    screenv(&h, &term.alt);

    // Scrollback newest-first through `back`, which is the only accessor
    // that knows where the ring's head is.
    u64v(&h, term.scrollback.len);
    for (0..term.scrollback.len) |i| {
        const line = term.scrollback.back(i) orelse break;
        flagsv(&h, term.scrollback.backMeta(i).?);
        for (line) |cell| cellv(&h, cell);
    }

    return h.final();
}

/// One field this checksum claims to cover, and the bytes that move it.
///
/// **Exported on purpose.** L1's checkpoint codec has to carry everything
/// hashed here, and the two files drifting apart is the way a seek silently
/// loses a field. `src/ckpt.zig`'s round-trip test iterates *this* table
/// rather than a copy of it, so a case added here is a case exercised there
/// without anyone remembering to. The comptime field counts in `ckpt.zig` are
/// the other half of the same mechanism.
pub const FieldCase = struct { name: []const u8, bytes: []const u8 };

const case_base = "text\r\n\x1b[2;3Hx";

pub const field_cases = [_]FieldCase{
    .{ .name = "a printed cell", .bytes = case_base ++ "Z" },
    .{ .name = "cursor position", .bytes = case_base ++ "\x1b[5;5H" },
    .{ .name = "cursor colour", .bytes = case_base ++ "\x1b[38;5;99m" },
    .{ .name = "cursor attributes", .bytes = case_base ++ "\x1b[1m" },
    .{ .name = "saved cursor", .bytes = case_base ++ "\x1b[9;9H\x1b7\x1b[1;1H" },
    // The case above saves the cursor with SGR at its defaults, so it
    // exercises the saved *position* only. A codec that dropped the saved
    // cursor's colour passed the whole suite until this row existed.
    .{ .name = "a saved cursor colour", .bytes = case_base ++ "\x1b[38;5;99m\x1b[1m\x1b7\x1b[0m" },
    .{ .name = "scroll region", .bytes = case_base ++ "\x1b[2;4r" },
    .{ .name = "wrap mode", .bytes = case_base ++ "\x1b[?7l" },
    .{ .name = "cursor visibility", .bytes = case_base ++ "\x1b[?25l" },
    .{ .name = "application cursor keys", .bytes = case_base ++ "\x1b[?1h" },
    .{ .name = "origin mode", .bytes = case_base ++ "\x1b[?6h" },
    .{ .name = "bracketed paste", .bytes = case_base ++ "\x1b[?2004h" },
    .{ .name = "mouse reporting", .bytes = case_base ++ "\x1b[?1000h" },
    .{ .name = "the mouse encoding", .bytes = case_base ++ "\x1b[?1006h" },
    .{ .name = "the alt screen", .bytes = case_base ++ "\x1b[?1049h" },
    .{ .name = "tab stops", .bytes = case_base ++ "\x1b[3g" },
    .{ .name = "scrollback", .bytes = case_base ++ "\r\n\r\n\r\n\r\n\r\n\r\n\r\n\r\n" },
    // Not hashed by this file, and carried by a checkpoint all the same --
    // which is exactly why the table is shared. See `ckpt.zig`'s header.
    .{ .name = "the window title", .bytes = case_base ++ "\x1b]0;a title\x07" },
    .{ .name = "a wrapped row", .bytes = "abcdefghijklmnopqrstuvwxyz0123456789" },
    // **Exactly twenty printable characters**, which is the width both this
    // file's test and `ckpt.zig`'s round-trip build their terminals at. The
    // cursor then sits past the last column with the wrap deferred, which is
    // a state no other case here reaches: 36 characters wrap and land at
    // column 17 with `pending_wrap` false. A checkpoint that dropped the flag
    // survived the whole first mutation pass because of that gap.
    .{ .name = "a deferred wrap at the right margin", .bytes = case_base ++ "\x1b[4;1H01234567890123456789" },
    .{ .name = "the application keypad", .bytes = case_base ++ "\x1b=" },
};

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
    var plain = try Terminal.init(testing.allocator, 20, 5);
    defer plain.deinit();
    feed(&plain, case_base);
    const reference = checksum(&plain);

    // One case in the shared table is deliberately *not* hashed here: the
    // title is window state, and a checkpoint carries it all the same. That
    // asymmetry is the reason the table is shared rather than duplicated, so
    // the exclusion is named here instead of being kept out of the table.
    const not_hashed = [_][]const u8{"the window title"};

    cases: for (field_cases) |case| {
        for (not_hashed) |n| {
            if (std.mem.eql(u8, n, case.name)) continue :cases;
        }
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

// -- E1: the wrap flag is in, the line id and the selection are not --------

test "a wrapped row does not hash the same as two rows" {
    // The case nothing else in this file can see: identical cells, identical
    // cursor, identical everything -- and one screen's first row ran off the
    // right margin while the other's was ended by a line feed. That is a
    // different document, and a replay that got it backwards would paste
    // differently and search differently.
    var a = try Terminal.init(testing.allocator, 4, 3);
    defer a.deinit();
    var b = try Terminal.init(testing.allocator, 4, 3);
    defer b.deinit();

    feed(&a, "abcdefgh"); // wraps at the margin
    feed(&b, "abcd\r\nefgh"); // two lines that happen to fill their rows

    // The cells really are identical, so the flag is the only difference.
    for (0..3) |y| {
        try testing.expectEqualSlices(
            grid.Cell,
            a.screen().row(y),
            b.screen().row(y),
        );
    }
    try testing.expect(a.screen().rowMeta(0).flags.wrapped);
    try testing.expect(!b.screen().rowMeta(0).flags.wrapped);
    try testing.expect(checksum(&a) != checksum(&b));
}

test "line ids and the selection are not part of it" {
    // The other half of the argument. Two terminals showing the same screen
    // must hash the same however much history each one has behind it, or
    // every replay of a long session fails for a reason that says nothing
    // about the recording -- and a selection is view state, like the view
    // offset above.
    var t = try Terminal.init(testing.allocator, 10, 3);
    defer t.deinit();
    feed(&t, "one\r\ntwo\r\nthree");

    const before = checksum(&t);
    t.next_line_id += 5_000;
    t.setSelection(.{
        .anchor = .{ .line = t.screen().rowMeta(0).id, .x = 0 },
        .head = .{ .line = t.screen().rowMeta(1).id, .x = 2 },
    });
    try testing.expect(t.selection != null);
    try testing.expectEqual(before, checksum(&t));

    // And relabelling every row on the screen, without touching a cell,
    // leaves the checksum where it was.
    for (0..t.rows) |y| t.screen().rowMeta(y).id += 100_000;
    try testing.expectEqual(before, checksum(&t));
}
