//! The cell grid: what a terminal actually *is* underneath the escape codes.
//!
//! A screen is one flat `rows * cols` allocation, not an array of row
//! pointers -- a row is always contiguous, so `row()` hands out a plain
//! slice and a repaint walks each row in a straight line.
//!
//! What that flat block is *not* is in logical order. `Screen.offset` makes
//! it a ring, so that scrolling the whole screen rotates an index instead of
//! moving every row; logical row 0 can sit anywhere in the block, and
//! logical rows wrap round the end. Anything spanning several rows must go
//! through `row()` one row at a time. Slicing `cells[y * cols ..]` directly
//! is what this file used to do and is now a bug.

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

/// What a row is, beside its cells.
///
/// One entry per row, in a parallel array indexed *physically* -- through the
/// same `physical()` that `row()` uses -- so rotating `offset` rotates the
/// metadata with the cells for free and `scrollUp`'s fast path needs no code
/// of its own. A side array that did not rotate with its rows would be
/// metadata on the wrong row, which is the trap
/// [priorities.md](../docs/roadmap/priorities.md) names for this primitive.
///
/// It is a side array rather than fields on `Cell` because `Cell` is 16 bytes
/// and [sprint 5](../docs/roadmap/completed/sprint-5-cell-size.md) retired
/// growing it. The cost is one `RowMeta` per row against `cols` cells: 16
/// bytes against `cols * 16`, so +1.25% at 80 columns and +0.5% at 200.
pub const RowMeta = struct {
    /// A line's identity, stable while the ring rotates and while the row
    /// moves into scrollback. **Minted by `terminal.zig`, never here**:
    /// `grid.zig` holds no policy, so every mutator takes the first id it
    /// should stamp and returns how many it used.
    ///
    /// 0 means "no line" and is never minted -- the counter starts at 1 --
    /// so a zero id can be compared against without being mistaken for a
    /// row somebody could have selected.
    id: u64 = 0,
    flags: Flags = .{},

    pub const Flags = packed struct(u8) {
        /// This row ends because the text ran off the right margin, not
        /// because anything sent a line feed. Selection joins such a row to
        /// the next with no separator (E1), reflow re-wraps by it (E4), and
        /// path detection spans it (A4).
        wrapped: bool = false,
        _pad: u7 = 0,
    };

    pub const none: RowMeta = .{};
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
    /// One per row, indexed physically. See `RowMeta`.
    ///
    /// **Last on purpose.** `cells`, `cols` and `offset` are what `row()`
    /// touches on every line of output; putting a new slice in front of them
    /// moved them across a cache line and cost 25% of the `ascii` corpus and
    /// 35% of `scroll` before this was measured.
    meta: []RowMeta,

    /// `first_id` labels logical row 0; row `y` gets `first_id + y`. The
    /// caller has minted `rows` ids.
    pub fn init(alloc: std.mem.Allocator, cols: usize, rows: usize, first_id: u64) !Screen {
        const cells = try alloc.alloc(Cell, cols * rows);
        errdefer alloc.free(cells);
        @memset(cells, .blank);
        const meta = try alloc.alloc(RowMeta, rows);
        for (meta, 0..) |*m, y| m.* = .{ .id = first_id + y };
        return .{ .cells = cells, .cols = cols, .rows = rows, .meta = meta };
    }

    pub fn deinit(self: *Screen, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        alloc.free(self.meta);
        self.* = undefined;
    }

    /// Where logical row `y` actually lives. Both `offset` and `y` are below
    /// `rows`, so their sum is below `2 * rows` and one conditional
    /// subtraction does the job of a modulo.
    inline fn physical(self: *const Screen, y: usize) usize {
        // Before the ring, `row(rows)` sliced past the end of `cells` and
        // tripped a bounds check. Now it would fold onto a live row and
        // quietly scribble on it, so the precondition has to be asserted
        // rather than left to the slice. It is also what the single
        // conditional subtraction below depends on.
        std.debug.assert(y < self.rows);
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

    /// Logical row `y`'s metadata. Through the *same* `physical()` `row()`
    /// uses -- that is the whole trick, and indexing `meta[y]` directly is
    /// the bug it exists to prevent.
    pub fn rowMeta(self: *const Screen, y: usize) *RowMeta {
        return &self.meta[self.physical(y)];
    }

    /// Blank the whole screen and relabel every row. Returns the ids used,
    /// which is `rows`.
    pub fn fill(self: *Screen, cell: Cell, first_id: u64) usize {
        @memset(self.cells, cell);
        // Every cell is identical now, so rotation cannot change what this
        // screen shows -- but a reset should leave it in a canonical state,
        // or the first person to add a whole-screen copy gets a surprise.
        self.offset = 0;
        for (self.meta, 0..) |*m, y| m.* = .{ .id = first_id + y };
        return self.rows;
    }

    /// Clear rows `top..=bot` (inclusive), stamping each with a fresh id
    /// starting at `first_id` and clearing its flags -- a cleared row is a
    /// new line, not the old one emptied. Returns how many ids were used.
    pub fn clearRows(self: *Screen, top: usize, bot: usize, cell: Cell, first_id: u64) usize {
        if (top > bot or top >= self.rows) return 0;
        const end = @min(bot, self.rows - 1);
        for (top..end + 1) |y| {
            @memset(self.row(y), cell);
            self.rowMeta(y).* = .{ .id = first_id + (y - top) };
        }
        return end + 1 - top;
    }

    /// Scroll the region `top..=bot` up by `n` lines; blank lines enter at the
    /// bottom. This is the hot path for every line of shell output.
    ///
    /// Returns how many ids were consumed from `first_id`. The caller adds
    /// that to its counter rather than predicting it: the `n >= height`
    /// branch below clears the **whole region**, so it stamps `height` rows
    /// and not `n`, and a caller that minted `n` would hand two rows the
    /// same id -- invisible until a selection anchored to one resolves onto
    /// the other.
    pub fn scrollUp(self: *Screen, top: usize, bot: usize, n: usize, cell: Cell, first_id: u64) usize {
        if (top > bot or bot >= self.rows or n == 0) return 0;
        const height = bot - top + 1;
        if (n >= height) {
            return self.clearRows(top, bot, cell, first_id);
        }
        // Whole-screen scroll -- every line feed with no scroll region set,
        // which is nearly all of them. Rotating the ring turns this from
        // O(rows * cols) into O(n * cols): at 80x24 that is ~28 KiB of
        // memmove per line feed replaced by clearing one row.
        if (top == 0 and bot == self.rows - 1) {
            // `meta` is indexed through the same `physical()`, so rotating
            // the offset carries every row's id and flags with its cells and
            // this branch needs no code for them at all.
            self.offset = self.physical(n);
            return self.clearRows(height - n, bot, cell, first_id);
        }

        // A scroll region still has to move rows, but logical rows are no
        // longer adjacent in memory, so this goes one row at a time. Ascending
        // order reads ahead of where it writes; distinct logical rows always
        // map to distinct physical ones, so the copies never overlap.
        //
        // This looks like it should lose to the single slab copy it replaces,
        // and it does not: the old code used std.mem.copyForwards, which is a
        // scalar element loop (and deprecated in favour of @memmove), while
        // each @memcpy here lowers to a vectorised copy. The `region` corpus
        // -- a DECSTBM region with a status line, what vim and less actually
        // do -- runs 1.3x faster this way than it did before the ring.
        for (top..bot + 1 - n) |y| {
            @memcpy(self.row(y), self.row(y + n));
            // The row moved, so its identity and its wrap flag move with it.
            // Leaving this out is a mutant nothing else catches: the cells
            // are right and the metadata describes the row that used to be
            // there.
            self.rowMeta(y).* = self.rowMeta(y + n).*;
        }
        return self.clearRows(bot - n + 1, bot, cell, first_id);
    }

    /// Scroll the region `top..=bot` down by `n` lines; blanks enter at the top.
    /// Returns ids consumed, for the reason `scrollUp` does.
    pub fn scrollDown(self: *Screen, top: usize, bot: usize, n: usize, cell: Cell, first_id: u64) usize {
        if (top > bot or bot >= self.rows or n == 0) return 0;
        const height = bot - top + 1;
        if (n >= height) {
            return self.clearRows(top, bot, cell, first_id);
        }
        if (top == 0 and bot == self.rows - 1) {
            self.offset = self.physical(self.rows - n);
            return self.clearRows(top, top + n - 1, cell, first_id);
        }

        // Descending, for the same reason scrollUp ascends.
        var y = bot + 1;
        while (y > top + n) {
            y -= 1;
            @memcpy(self.row(y), self.row(y - n));
            self.rowMeta(y).* = self.rowMeta(y - n).*;
        }
        return self.clearRows(top, top + n - 1, cell, first_id);
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
    /// How many lines have ever been pushed, and how many times the ring has
    /// been thrown away. **Both live here rather than on `Terminal`** because
    /// `push` already writes `head` and `len` in this struct: a counter beside
    /// them costs no additional cache line, and one at the end of `Terminal`
    /// -- where the E1 fields had to go -- would be touched on every line
    /// feed, which is the hot path sprint R exists to keep clear.
    ///
    /// What they are for: L1's `scrollback_unchanged` flag. A checkpoint whose
    /// `pushes` and `epoch` both equal the previous checkpoint's holds exactly
    /// the same history, so it reuses the previous one's encoded scrollback
    /// verbatim. That is an identity claim, not a delta -- there is no
    /// eviction to reason about -- and it is what makes a checkpoint taken
    /// while a full-screen program is running cost a screen rather than a ring.
    ///
    /// `pushes` counts real pushes: a zero-capacity ring returns early and
    /// counts nothing, because nothing was kept.
    pushes: u64 = 0,
    /// Bumped by `clear`, and by `Terminal.resize` when the column count
    /// changes and the ring is rebuilt. Two rings with the same `pushes` and
    /// different epochs hold different lines.
    epoch: u64 = 0,
    /// One per slot, moving with `push` so a line keeps its identity and its
    /// wrap flag on the way out of the screen. Without this a selection
    /// anchored to a line stops resolving the moment the line scrolls off,
    /// which is precisely the case E1 exists for.
    ///
    /// Last, for the reason `Screen.meta` is.
    meta: []RowMeta,

    pub fn init(alloc: std.mem.Allocator, cols: usize, capacity: usize) !Scrollback {
        const buf = try alloc.alloc(Cell, cols * capacity);
        errdefer alloc.free(buf);
        @memset(buf, .blank);
        const meta = try alloc.alloc(RowMeta, capacity);
        @memset(meta, .none);
        return .{ .buf = buf, .cols = cols, .capacity = capacity, .meta = meta };
    }

    pub fn deinit(self: *Scrollback, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
        alloc.free(self.meta);
        self.* = undefined;
    }

    pub fn push(self: *Scrollback, line: []const Cell, meta: RowMeta) void {
        if (self.capacity == 0) return;
        const slot = self.buf[self.head * self.cols ..][0..self.cols];
        const n = @min(line.len, self.cols);
        @memcpy(slot[0..n], line[0..n]);
        @memset(slot[n..], .blank);
        self.meta[self.head] = meta;
        self.head = (self.head + 1) % self.capacity;
        if (self.len < self.capacity) self.len += 1;
        self.pushes += 1;
    }

    /// Line `i` counting back from the most recent (0 = newest).
    pub fn back(self: *const Scrollback, i: usize) ?[]const Cell {
        if (i >= self.len) return null;
        const idx = (self.head + self.capacity - 1 - i) % self.capacity;
        return self.buf[idx * self.cols ..][0..self.cols];
    }

    /// The metadata of the line `back(i)` returns.
    pub fn backMeta(self: *const Scrollback, i: usize) ?RowMeta {
        if (i >= self.len) return null;
        const idx = (self.head + self.capacity - 1 - i) % self.capacity;
        return self.meta[idx];
    }

    pub fn clear(self: *Scrollback) void {
        self.head = 0;
        self.len = 0;
        self.epoch += 1;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn mkScreen(cols: usize, rows: usize) !Screen {
    var s = try Screen.init(testing.allocator, cols, rows, 1);
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
    _ = s.scrollUp(0, 3, 1, .blank, 0);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("111", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("222", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("333", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 3, &buf));
}

test "scrollUp honors a scroll region and leaves the rest alone" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    _ = s.scrollUp(1, 2, 1, .blank, 0);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("000", rowStr(&s, 0, &buf)); // above region
    try testing.expectEqualStrings("222", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("333", rowStr(&s, 3, &buf)); // below region
}

test "scrolling by more than the region height just clears it" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    _ = s.scrollUp(0, 3, 99, .blank, 0);
    var buf: [8]u8 = undefined;
    for (0..4) |y| try testing.expectEqualStrings("   ", rowStr(&s, y, &buf));
}

test "scrollDown moves lines and blanks the top" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    _ = s.scrollDown(0, 3, 2, .blank, 0);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("   ", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("000", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("111", rowStr(&s, 3, &buf));
}

test "insert and delete cells within a row" {
    var s = try Screen.init(testing.allocator, 5, 1, 1);
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
        sb.push(&line, .{ .id = ch });
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
        _ = s.scrollUp(0, 3, 1, .blank, 0);
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
        _ = s.scrollDown(0, 3, 1, .blank, 0);
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

    _ = s.scrollUp(0, 3, 3, .blank, 0); // offset is now 3
    paintRow(&s, 0, 'w');
    paintRow(&s, 1, 'x');
    paintRow(&s, 2, 'y');
    paintRow(&s, 3, 'z');

    _ = s.scrollUp(1, 2, 1, .blank, 0); // region strictly inside the screen
    try testing.expectEqualStrings("www", rowStr(&s, 0, &buf)); // untouched
    try testing.expectEqualStrings("yyy", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("zzz", rowStr(&s, 3, &buf)); // untouched

    _ = s.scrollDown(1, 2, 1, .blank, 0);
    try testing.expectEqualStrings("www", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("yyy", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("zzz", rowStr(&s, 3, &buf));
}

test "at() and row() address the same cell once rotated" {
    var s = try mkScreen(5, 4);
    defer s.deinit(testing.allocator);

    _ = s.scrollUp(0, 3, 2, .blank, 0); // offset = 2
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

    _ = s.scrollUp(0, 3, 3, .blank, 0); // offset = 3, so logical 1..3 wrap around
    for (0..4) |y| paintRow(&s, y, @intCast('p' + y));

    _ = s.clearRows(1, 2, .blank, 0);
    try testing.expectEqualStrings("ppp", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("sss", rowStr(&s, 3, &buf));
}

test "a rotated screen scrolled by its full height is still all blank" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    _ = s.scrollUp(0, 3, 2, .blank, 0);
    _ = s.scrollUp(0, 3, 4, .blank, 0); // n >= height
    for (0..4) |y| try testing.expectEqualStrings("   ", rowStr(&s, y, &buf));
}

test "whole-screen scroll by more than one line rotates by exactly that many" {
    // The fast path rotates by `n`, and a version that rotated by a fixed
    // one line would still pass every single-line test above.
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var buf: [8]u8 = undefined;

    _ = s.scrollUp(0, 3, 2, .blank, 0);
    try testing.expectEqualStrings("222", rowStr(&s, 0, &buf));
    try testing.expectEqualStrings("333", rowStr(&s, 1, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 2, &buf));
    try testing.expectEqualStrings("   ", rowStr(&s, 3, &buf));

    var d = try mkScreen(3, 4);
    defer d.deinit(testing.allocator);
    _ = d.scrollDown(0, 3, 2, .blank, 0);
    try testing.expectEqualStrings("   ", rowStr(&d, 0, &buf));
    try testing.expectEqualStrings("   ", rowStr(&d, 1, &buf));
    try testing.expectEqualStrings("000", rowStr(&d, 2, &buf));
    try testing.expectEqualStrings("111", rowStr(&d, 3, &buf));
}

// -- row metadata ---------------------------------------------------------
//
// `meta` is indexed physically, exactly as `cells` is, so the whole-screen
// fast path carries it for free and the region path has to carry it by hand.
// The tests below mirror the ring tests above one for one, because the way
// this goes wrong is not "ids are missing" -- it is "ids are on the wrong
// rows once the ring has turned", which no assertion on cells can see.

/// The mint-and-advance discipline `terminal.zig` uses, so these tests
/// exercise the same contract rather than a made-up one.
const Ids = struct {
    next: u64,

    /// Starting after the ids `Screen.init` already stamped, exactly as
    /// `Terminal.init` does -- two rows sharing a number is the bug these
    /// tests exist to catch, so the harness must not create one itself.
    fn after(s: *const Screen) Ids {
        return .{ .next = 1 + s.rows };
    }

    fn up(self: *Ids, s: *Screen, top: usize, bot: usize, n: usize) void {
        self.next += s.scrollUp(top, bot, n, .blank, self.next);
    }
    fn down(self: *Ids, s: *Screen, top: usize, bot: usize, n: usize) void {
        self.next += s.scrollDown(top, bot, n, .blank, self.next);
    }
    fn clear(self: *Ids, s: *Screen, top: usize, bot: usize) void {
        self.next += s.clearRows(top, bot, .blank, self.next);
    }
};

/// Every live row id, in logical order.
fn ids(s: *const Screen, buf: []u64) []const u64 {
    for (0..s.rows) |y| buf[y] = s.rowMeta(y).id;
    return buf[0..s.rows];
}

fn allDistinct(xs: []const u64) bool {
    for (xs, 0..) |a, i| for (xs[i + 1 ..]) |b| {
        if (a == b) return false;
    };
    return true;
}

test "ids and wrap flags survive forty ring rotations" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var counter: Ids = .after(&s);

    // Ten full rotations of a four-row screen, marking every other incoming
    // row as wrapped. If the metadata does not rotate with the cells, the
    // flags come back on the wrong rows and the ids come back permuted.
    for (0..40) |i| {
        counter.up(&s, 0, 3, 1);
        paintRow(&s, 3, @intCast('a' + (i % 26)));
        s.rowMeta(3).flags.wrapped = (i % 2 == 0);
    }

    var buf: [8]u64 = undefined;
    const live = ids(&s, &buf);
    try testing.expect(allDistinct(live));
    // Strictly increasing down the screen: the newest row is the bottom one.
    for (1..live.len) |y| try testing.expect(live[y] > live[y - 1]);
    // 40 scrolls, one row each, from a screen that started at ids 1-4.
    try testing.expectEqual(@as(u64, 41), live[0]);
    try testing.expectEqual(@as(u64, 44), live[3]);

    // i = 36..39 produced logical rows 0..3; even `i` set the flag.
    for (0..4) |y| {
        try testing.expectEqual((36 + y) % 2 == 0, s.rowMeta(y).flags.wrapped);
    }
}

test "a region scroll after rotation moves metadata with its cells" {
    // The dangerous interaction, and the reason the region branch needs code
    // the fast path does not: with offset == 0 a metadata bug here is
    // invisible, so rotate first and only then scroll a region.
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var counter: Ids = .after(&s);

    counter.up(&s, 0, 3, 3); // offset is now 3
    for (0..4) |y| {
        paintRow(&s, y, @intCast('w' + y));
        s.rowMeta(y).flags.wrapped = (y == 2);
    }
    var before: [8]u64 = undefined;
    const was = ids(&s, &before);
    const row2_id = was[2];
    const row0_id = was[0];
    const row3_id = was[3];

    counter.up(&s, 1, 2, 1); // logical row 2 moves up to row 1

    var buf: [8]u64 = undefined;
    const now = ids(&s, &buf);
    try testing.expectEqual(row0_id, now[0]); // above the region: untouched
    try testing.expectEqual(row2_id, now[1]); // moved up, id came with it
    try testing.expect(now[2] != row2_id); // fresh blank line
    try testing.expectEqual(row3_id, now[3]); // below the region: untouched
    try testing.expect(allDistinct(now));

    try testing.expect(s.rowMeta(1).flags.wrapped); // the flag moved too
    try testing.expect(!s.rowMeta(2).flags.wrapped); // and a blank row has none
}

test "scrollDown's region branch moves metadata too" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var counter: Ids = .after(&s);

    counter.up(&s, 0, 3, 2); // rotate, so memory order != logical order
    var before: [8]u64 = undefined;
    const was = ids(&s, &before);
    const row1_id = was[1];

    counter.down(&s, 1, 2, 1); // logical row 1 moves down to row 2
    var buf: [8]u64 = undefined;
    const now = ids(&s, &buf);
    try testing.expectEqual(row1_id, now[2]);
    try testing.expect(allDistinct(now));
}

test "clearRows across the wrap point stamps exactly its range" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var counter: Ids = .after(&s);

    counter.up(&s, 0, 3, 3); // offset = 3, so logical 1..3 wrap around
    for (0..4) |y| s.rowMeta(y).flags.wrapped = true;
    var before: [8]u64 = undefined;
    const was = ids(&s, &before);
    const kept0 = was[0];
    const kept3 = was[3];

    counter.clear(&s, 1, 2);
    var buf: [8]u64 = undefined;
    const now = ids(&s, &buf);
    try testing.expectEqual(kept0, now[0]);
    try testing.expectEqual(kept3, now[3]);
    try testing.expect(now[1] != was[1] and now[2] != was[2]);
    try testing.expectEqual(now[1] + 1, now[2]); // consecutive, in logical order
    try testing.expect(allDistinct(now));

    // A cleared row is a new line, not the old one emptied.
    try testing.expect(s.rowMeta(0).flags.wrapped);
    try testing.expect(!s.rowMeta(1).flags.wrapped);
    try testing.expect(!s.rowMeta(2).flags.wrapped);
    try testing.expect(s.rowMeta(3).flags.wrapped);
}

test "scrolling by more than the region height mints one id per row, not per line" {
    // The trap: `n >= height` delegates to `clearRows` for the *whole*
    // region, so it stamps `height` rows. A caller that advanced its counter
    // by `n` would hand two rows the same id the next time round, and
    // nothing would notice until a selection resolved onto the wrong one.
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), s.scrollUp(0, 3, 99, .blank, 100));
    try testing.expectEqual(@as(usize, 4), s.scrollDown(0, 3, 99, .blank, 200));
    // And a partial region: rows 1..2 is two rows, whatever `n` says.
    try testing.expectEqual(@as(usize, 2), s.scrollUp(1, 2, 9, .blank, 300));
    // A no-op consumes nothing.
    try testing.expectEqual(@as(usize, 0), s.scrollUp(0, 3, 0, .blank, 400));
    try testing.expectEqual(@as(usize, 0), s.scrollUp(3, 1, 1, .blank, 400));

    // Driven through the counter, ids stay distinct across both branches.
    var t = try mkScreen(3, 4);
    defer t.deinit(testing.allocator);
    var counter: Ids = .after(&t);
    for (0..12) |i| counter.up(&t, 0, 3, if (i % 3 == 0) 9 else 1);
    var buf: [8]u64 = undefined;
    try testing.expect(allDistinct(ids(&t, &buf)));
}

test "fill relabels every row and clears every flag" {
    var s = try mkScreen(3, 4);
    defer s.deinit(testing.allocator);
    var counter: Ids = .after(&s);
    counter.up(&s, 0, 3, 2);
    for (0..4) |y| s.rowMeta(y).flags.wrapped = true;

    try testing.expectEqual(@as(usize, 4), s.fill(.blank, 900));
    var buf: [8]u64 = undefined;
    const now = ids(&s, &buf);
    try testing.expectEqualSlices(u64, &.{ 900, 901, 902, 903 }, now);
    for (0..4) |y| try testing.expect(!s.rowMeta(y).flags.wrapped);
}

test "scrollback carries a line's metadata into the same slot as its cells" {
    var sb = try Scrollback.init(testing.allocator, 2, 3);
    defer sb.deinit(testing.allocator);

    for ("abcde", 0..) |ch, i| {
        const line = [_]Cell{ .{ .cp = ch }, .{ .cp = ch } };
        sb.push(&line, .{ .id = 100 + i, .flags = .{ .wrapped = i % 2 == 0 } });
    }

    // Capacity 3, so c, d and e survive -- newest first, and each one's
    // metadata has to be the metadata of the line beside it.
    try testing.expectEqual(@as(u21, 'e'), sb.back(0).?[0].cp);
    try testing.expectEqual(@as(u64, 104), sb.backMeta(0).?.id);
    try testing.expect(sb.backMeta(0).?.flags.wrapped); // i = 4
    try testing.expectEqual(@as(u64, 103), sb.backMeta(1).?.id);
    try testing.expect(!sb.backMeta(1).?.flags.wrapped); // i = 3
    try testing.expectEqual(@as(u64, 102), sb.backMeta(2).?.id);
    try testing.expectEqual(@as(?RowMeta, null), sb.backMeta(3));

    // `back` and `backMeta` must agree about which slot is which, so walk
    // the pair together rather than trusting them separately.
    for (0..sb.len) |i| {
        const cp = sb.back(i).?[0].cp;
        try testing.expectEqual(@as(u64, 100 + (cp - 'a')), sb.backMeta(i).?.id);
    }
}
