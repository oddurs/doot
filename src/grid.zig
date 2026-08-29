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

    pub fn init(alloc: std.mem.Allocator, cols: usize, rows: usize) !Screen {
        const cells = try alloc.alloc(Cell, cols * rows);
        @memset(cells, .blank);
        return .{ .cells = cells, .cols = cols, .rows = rows };
    }

    pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        self.* = undefined;
    }

    pub fn row(self: *const Screen, y: usize) []Cell {
        const start = y * self.cols;
        return self.cells[start .. start + self.cols];
    }

    pub fn at(self: *const Screen, x: usize, y: usize) *Cell {
        return &self.cells[y * self.cols + x];
    }

    pub fn fill(self: *Screen, cell: Cell) void {
        @memset(self.cells, cell);
    }

    /// Clear rows `top..=bot` (inclusive).
    pub fn clearRows(self: *Screen, top: usize, bot: usize, cell: Cell) void {
        if (top > bot or top >= self.rows) return;
        const end = @min(bot, self.rows - 1);
        @memset(self.cells[top * self.cols .. (end + 1) * self.cols], cell);
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
        const dst = top * self.cols;
        const src = (top + n) * self.cols;
        const len = (height - n) * self.cols;
        std.mem.copyForwards(Cell, self.cells[dst .. dst + len], self.cells[src .. src + len]);
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
        const len = (height - n) * self.cols;
        const src = top * self.cols;
        const dst = (top + n) * self.cols;
        std.mem.copyBackwards(Cell, self.cells[dst .. dst + len], self.cells[src .. src + len]);
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
