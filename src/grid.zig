//! The cell grid: what a terminal actually *is* underneath the escape codes.
//!
//! A screen is a flat `rows * cols` array of cells, not an array of row
//! pointers. That keeps a full repaint walking memory in a straight line,
//! which is the single biggest thing that makes a terminal feel fast when
//! something dumps a megabyte of output at it.

const std = @import("std");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Color = union(enum) {
    /// The theme's foreground/background, whichever role this slot plays.
    default,
    /// A slot in the 256-color palette (0-15 are the ANSI colors).
    indexed: u8,
    rgb: Rgb,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |i| b == .indexed and b.indexed == i,
            .rgb => |c| b == .rgb and std.meta.eql(b.rgb, c),
        };
    }
};

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
};

/// How a cell participates in a double-width character. A wide glyph occupies
/// a `.wide` cell followed by a `.spacer` cell that draws nothing.
pub const Wide = enum(u2) { narrow, wide, spacer };

pub const Cell = struct {
    cp: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
    wide: Wide = .narrow,

    pub const blank: Cell = .{};

    pub fn isBlank(self: Cell) bool {
        return self.cp == ' ' and self.bg == .default and !self.attrs.reverse;
    }
};

pub const Screen = struct {
    cells: []Cell,
    cols: usize,
    rows: usize,
    /// Physical index of logical row 0. Scrolling the whole screen rotates
    /// this rather than moving every row, which is what makes a line feed
    /// cost one row instead of the entire grid. The scrollback ring has
    /// always worked this way; the screen now does too.
    ///
    /// Rows stay individually contiguous, so `row()` still hands out a plain
    /// slice and nothing above this file has to know the ring exists. What
    /// it does mean is that logical rows are no longer adjacent to each
    /// other in memory, so anything spanning several rows must go row by row
    /// rather than slabbing across `cells`.
    offset: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cols: usize, rows: usize) !Screen {
        const cells = try alloc.alloc(Cell, cols * rows);
        @memset(cells, .blank);
        return .{ .cells = cells, .cols = cols, .rows = rows };
    }

    pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        self.* = undefined;
    }

    /// Where logical row `y` actually lives. Both `offset` and `y` are below
    /// `rows`, so their sum is below `2 * rows` and one conditional
    /// subtraction does the job of a modulo.
    inline fn physical(self: *const Screen, y: usize) usize {
        const p = self.offset + y;
        return if (p >= self.rows) p - self.rows else p;
    }

    pub fn row(self: *const Screen, y: usize) []Cell {
        const start = self.physical(y) * self.cols;
        return self.cells[start .. start + self.cols];
    }

    pub fn at(self: *const Screen, x: usize, y: usize) *Cell {
        return &self.cells[self.physical(y) * self.cols + x];
    }

    pub fn fill(self: *Screen, cell: Cell) void {
        // Every cell ends up identical, so where the ring is pointing makes
        // no difference to the result.
        @memset(self.cells, cell);
    }

    /// Clear rows `top..=bot` (inclusive).
    pub fn clearRows(self: *Screen, top: usize, bot: usize, cell: Cell) void {
        if (top > bot or top >= self.rows) return;
        const end = @min(bot, self.rows - 1);
        for (top..end + 1) |y| @memset(self.row(y), cell);
    }

    /// Scroll the region `top..=bot` up by `n` lines; blank lines enter at the
    /// bottom. This is the hot path for every line of shell output.
    pub fn scrollUp(self: *Screen, top: usize, bot: usize, n: usize, cell: Cell) void {
        if (top > bot or bot >= self.rows or n == 0) return;
        const height = bot - top + 1;
        if (n >= height) {
            self.clearRows(top, bot, cell);
            return;
        }
        // Whole-screen scroll -- every line feed with no scroll region set,
        // which is nearly all of them. Rotating the ring turns this from
        // O(rows * cols) into O(n * cols): at 80x24 that is ~28 KiB of
        // memmove per line feed replaced by clearing one row.
        if (top == 0 and bot == self.rows - 1) {
            self.offset = self.physical(n);
            self.clearRows(height - n, bot, cell);
            return;
        }

        // A scroll region still has to move rows, but logical rows are no
        // longer adjacent in memory, so this goes one row at a time. Ascending
        // order reads ahead of where it writes; distinct logical rows always
        // map to distinct physical ones, so the copies never overlap.
        for (top..bot + 1 - n) |y| {
            @memcpy(self.row(y), self.row(y + n));
        }
        self.clearRows(bot - n + 1, bot, cell);
    }

    /// Scroll the region `top..=bot` down by `n` lines; blanks enter at the top.
    pub fn scrollDown(self: *Screen, top: usize, bot: usize, n: usize, cell: Cell) void {
        if (top > bot or bot >= self.rows or n == 0) return;
        const height = bot - top + 1;
        if (n >= height) {
            self.clearRows(top, bot, cell);
            return;
        }
        if (top == 0 and bot == self.rows - 1) {
            self.offset = self.physical(self.rows - n);
            self.clearRows(top, top + n - 1, cell);
            return;
        }

        // Descending, for the same reason scrollUp ascends.
        var y = bot + 1;
        while (y > top + n) {
            y -= 1;
            @memcpy(self.row(y), self.row(y - n));
        }
        self.clearRows(top, top + n - 1, cell);
    }

    /// Shift cells right within one row, dropping what falls off the end (ICH).
    pub fn insertCells(self: *Screen, x: usize, y: usize, n: usize, cell: Cell) void {
        const r = self.row(y);
        if (x >= r.len or n == 0) return;
        const count = @min(n, r.len - x);
        const movable = r.len - x - count;
        if (movable > 0) {
            std.mem.copyBackwards(Cell, r[x + count ..], r[x .. x + movable]);
        }
        @memset(r[x .. x + count], cell);
    }

    /// Shift cells left within one row, blanking the tail (DCH).
    pub fn deleteCells(self: *Screen, x: usize, y: usize, n: usize, cell: Cell) void {
        const r = self.row(y);
        if (x >= r.len or n == 0) return;
        const count = @min(n, r.len - x);
        const movable = r.len - x - count;
        if (movable > 0) {
            std.mem.copyForwards(Cell, r[x .. x + movable], r[x + count ..]);
        }
        @memset(r[r.len - count ..], cell);
    }
};

/// Fixed-capacity ring of scrolled-off lines. A ring means scrollback costs a
/// bounded amount of memory no matter how long the session runs, and pushing a
/// line never reallocates or memmoves the history.
pub const Scrollback = struct {
    buf: []Cell,
    cols: usize,
    capacity: usize,
    head: usize = 0,
    len: usize = 0,

    pub fn init(alloc: std.mem.Allocator, cols: usize, capacity: usize) !Scrollback {
        const buf = try alloc.alloc(Cell, cols * capacity);
        @memset(buf, .blank);
        return .{ .buf = buf, .cols = cols, .capacity = capacity };
    }

    pub fn deinit(self: *Scrollback, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        self.* = undefined;
    }

    pub fn push(self: *Scrollback, line: []const Cell) void {
        if (self.capacity == 0) return;
        const slot = self.buf[self.head * self.cols ..][0..self.cols];
        const n = @min(line.len, self.cols);
        @memcpy(slot[0..n], line[0..n]);
        @memset(slot[n..], .blank);
        self.head = (self.head + 1) % self.capacity;
        if (self.len < self.capacity) self.len += 1;
    }

    /// Line `i` counting back from the most recent (0 = newest).
    pub fn back(self: *const Scrollback, i: usize) ?[]const Cell {
        if (i >= self.len) return null;
        const idx = (self.head + self.capacity - 1 - i) % self.capacity;
        return self.buf[idx * self.cols ..][0..self.cols];
    }

    pub fn clear(self: *Scrollback) void {
        self.head = 0;
        self.len = 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkScreen(cols: usize, rows: usize) !Screen {
    var s = try Screen.init(testing.allocator, cols, rows);
    // Label each row with a digit so scrolling is easy to assert on.
    for (0..rows) |y| for (s.row(y)) |*c| {
        c.cp = @intCast('0' + y);
    };
    return s;
}

fn rowStr(s: *const Screen, y: usize, buf: []u8) []const u8 {
    for (s.row(y), 0..) |c, i| buf[i] = @intCast(c.cp);
    return buf[0..s.cols];
}

test "scrollUp moves lines and blanks the bottom" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    s.scrollUp(0, 3, 1, .blank);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("111", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("222", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("333", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 3, &buf));
}

test "scrollUp honors a scroll region and leaves the rest alone" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    s.scrollUp(1, 2, 1, .blank);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("000", rowStr(&s, 0, &buf)); // above region
    try testing.expectEqualStrings("222", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("333", rowStr(&s, 3, &buf)); // below region
}

test "scrolling by more than the region height just clears it" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    s.scrollUp(0, 3, 99, .blank);
    var buf: [8]u8 = undefined;
    for (0..4) |y| try testing.expectEqualStrings("   ", rowStr(&s, y, &buf));
}

test "scrollDown moves lines and blanks the top" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    s.scrollDown(0, 3, 2, .blank);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("   ", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("000", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("111", rowStr(&s, 3, &buf));
}

test "insert and delete cells within a row" {
    var s = try Screen.init(testing.allocator, 5, 1);
    defer s.deinit(testing.allocator);
    for ("abcde", 0..) |ch, i| s.at(i, 0).cp = ch;

    s.insertCells(1, 0, 2, .blank);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a  bc", rowStr(&s, 0, &buf));

    s.deleteCells(1, 0, 2, .blank);
    try testing.expectEqualStrings("abc  ", rowStr(&s, 0, &buf));
}

test "scrollback ring keeps the newest lines and bounds memory" {
    var sb = try Scrollback.init(testing.allocator, 2, 3);
    defer sb.deinit(testing.allocator);

    for ("abcde") |ch| {
        const line = [_]Cell{ .{ .cp = ch }, .{ .cp = ch } };
        sb.push(&line);
    }
    // Capacity 3, so only c, d, e survive -- newest first.
    try testing.expectEqual(@as(usize, 3), sb.len);
    try testing.expectEqual(@as(u21, 'e'), sb.back(0).?[0].cp);
    try testing.expectEqual(@as(u21, 'd'), sb.back(1).?[0].cp);
    try testing.expectEqual(@as(u21, 'c'), sb.back(2).?[0].cp);
    try testing.expectEqual(@as(?[]const Cell, null), sb.back(3));
}

// -- ring behaviour ------------------------------------------------------
//
// Rotating the screen instead of moving it is invisible from outside this
// file, which is exactly why it needs its own tests: nothing above `Screen`
// would notice the ring being wrong until a user saw a scrambled screen.

/// Write a row's worth of a single character into logical row `y`.
fn paintRow(s: *Screen, y: usize, ch: u8) void {
    for (s.row(y)) |*c| c.cp = ch;
}

test "whole-screen scrollUp survives the offset wrapping many times over" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    // Ten full rotations of a four-row screen. If the wrap arithmetic is
    // wrong anywhere, the rows come back permuted rather than in order.
    for (0..40) |i| {
        s.scrollUp(0, 3, 1, .blank);
        paintRow(&s, 3, @intCast('a' + (i % 26)));
    }

    for (0..4) |y| {
        const expect = [_]u8{@intCast('a' + ((36 + y) % 26))} ** 3;
        try testing.expectEqualStrings(&expect, rowStr(&s, y, &buf));
    }
}

test "whole-screen scrollDown survives the offset wrapping many times over" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    for (0..40) |i| {
        s.scrollDown(0, 3, 1, .blank);
        paintRow(&s, 0, @intCast('a' + (i % 26)));
    }

    for (0..4) |y| {
        const expect = [_]u8{@intCast('a' + ((39 - y) % 26))} ** 3;
        try testing.expectEqualStrings(&expect, rowStr(&s, y, &buf));
    }
}

test "a scroll region behaves the same after the ring has rotated" {
    // The dangerous interaction: the region path moves rows by hand, and it
    // has to do so in ring order, not memory order. With offset == 0 a bug
    // here is invisible, so rotate first and only then scroll a region.
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    s.scrollUp(0, 3, 3, .blank); // offset is now 3
    paintRow(&s, 0, 'w');
    paintRow(&s, 1, 'x');
    paintRow(&s, 2, 'y');
    paintRow(&s, 3, 'z');

    s.scrollUp(1, 2, 1, .blank); // region strictly inside the screen
    try testing.expectEqualStrings("www", rowStr(&s, 0, &buf)); // untouched
    try testing.expectEqualStrings("yyy", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("zzz", rowStr(&s, 3, &buf)); // untouched

    s.scrollDown(1, 2, 1, .blank);
    try testing.expectEqualStrings("www", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("yyy", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("zzz", rowStr(&s, 3, &buf));
}

test "at() and row() address the same cell once rotated" {
    var s = try mkScreen(5, 4);
    defer s.deinit(testing.allocator);

    s.scrollUp(0, 3, 2, .blank); // offset = 2
    for (0..4) |y| for (0..5) |x| {
        s.at(x, y).cp = @intCast('A' + y * 5 + x);
    };
    for (0..4) |y| for (s.row(y), 0..) |c, x| {
        try testing.expectEqual(@as(u21, @intCast('A' + y * 5 + x)), c.cp);
    };
}

test "clearRows spanning the wrap point clears exactly its range" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    s.scrollUp(0, 3, 3, .blank); // offset = 3, so logical 1..3 wrap around
    for (0..4) |y| paintRow(&s, y, @intCast('p' + y));

    s.clearRows(1, 2, .blank);
    try testing.expectEqualStrings("ppp", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("sss", rowStr(&s, 3, &buf));
}

test "a rotated screen scrolled by its full height is still all blank" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    s.scrollUp(0, 3, 2, .blank);
    s.scrollUp(0, 3, 4, .blank); // n >= height
    for (0..4) |y| try testing.expectEqualStrings("   ", rowStr(&s, y, &buf));
}

test "whole-screen scroll by more than one line rotates by exactly that many" {
    // The fast path rotates by `n`, and a version that rotated by a fixed
    // one line would still pass every single-line test above.
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    s.scrollUp(0, 3, 2, .blank);
    try testing.expectEqualStrings("222", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("333", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 3, &buf));

    var d = try mkScreen(3, 4);
    defer d.deinit(testing.allocator);
    d.scrollDown(0, 3, 2, .blank);
    try testing.expectEqualStrings("   ", rowStr(&d, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&d, 1, &buf));
    try testing.expectEqualStrings("000", rowStr(&d, 2, &buf));
    try testing.expectEqualStrings("111", rowStr(&d, 3, &buf));
}
