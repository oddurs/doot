//! Checkpoints: a terminal serialised, and the in-memory index of them that
//! makes a seek cost a decode instead of a whole session's replay.
//!
//! L1 of [record.md](../docs/roadmap/record.md). L0 made the session a log;
//! this makes any moment in that log reachable.
//!
//! ## Where a checkpoint comes from, and where it does not
//!
//! **Never from the live terminal.** Three reasons, each fatal on its own:
//!
//! 1. The live `Terminal` holds *unredacted* bytes -- `redact.scrub` runs over
//!    a copy on its way into the recording, never over what reaches the screen
//!    -- so serialising the live terminal would put back into a file every
//!    secret L0 takes out of it.
//! 2. Scrubbing the checkpoint instead would make it unequal to the live
//!    model, so the arbiter would go red on exactly the sessions that contain
//!    a secret: the checkpoint would be *wrong* in a way no test could accept
//!    and no user could act on.
//! 3. Copying tens of megabytes under the terminal mutex moves the `lock`
//!    column by two orders of magnitude, which is the one thing sprint 1 and
//!    L0 both exist to prevent.
//!
//! So a checkpoint is **derived from the log**, on a worker thread that never
//! takes the terminal mutex: it opens the session's `.trec` read-only, parses
//! it, replays it into its own `Terminal`, and encodes a checkpoint every
//! `interval` bytes of cumulative output payload. The result is an index in
//! **memory only**. Nothing here writes a byte to disk, record type 9 stays
//! reserved and unwritten, and `rm` is still the whole of deleting a session.
//!
//! ## What is in one
//!
//! Exactly what `check.checksum` hashes, plus the three things it deliberately
//! does not hash and a seek must nonetheless restore:
//!
//! - **`next_line_id`**, or ids minted after a seek collide with ids already
//!   in the log and E1's selection resolves onto the wrong row;
//! - **`title`**, because the window says what the child called itself and a
//!   seek that forgot it would relabel history;
//! - **`scrollback.pushes` / `.epoch`**, which is how `scrollback_unchanged`
//!   is decided.
//!
//! Left out, because they are properties of the window rather than of the
//! stream -- the same line `check.zig` draws: `view_offset`, `selection`,
//! `dirty`, `bell`, `replies`. And two that are properties of a
//! *representation* rather than of a model: `Screen.offset` and
//! `Scrollback.head`. Both are canonicalised on decode -- screens are written
//! through `row(y)` in logical order and read back at offset 0, scrollback is
//! written oldest-first and read back by pushing in that order -- because ring
//! position is not something a seek should be able to get wrong.
//!
//! There is deliberately **no charset field**. `record.md`'s risk list names
//! one, and `terminal.zig` has no charset state at all: `escDispatch` returns
//! early on any intermediate, so `ESC ( B` changes nothing there is to save.
//!
//! ## Full copies, not a delta chain
//!
//! Every checkpoint is self-contained, with exactly one exception, and the
//! exception is an identity claim rather than a delta: `scrollback_unchanged`
//! says "this checkpoint's history is byte for byte the previous one's", which
//! is true whenever no line was pushed and no barrier (`fullReset`, a
//! width-changing `resize`) intervened. The index then points both entries at
//! one blob. That single bit is what makes a checkpoint taken while `vim` is
//! on the alt screen cost two screens instead of a ring -- and an agent TUI is
//! the case this sprint is for.
//!
//! `screen_only` is reserved beside it, for the two-tier fallback the sprint's
//! own measurement was allowed to force. It was not needed; see the sprint
//! record.
//!
//! std only, so this runs in the bench, on the CI runner, and eventually (M4)
//! in a browser.

const std = @import("std");
const grid = @import("grid.zig");
const vt = @import("vt.zig");
const rec = @import("rec.zig");
const replay = @import("replay.zig");
const term_mod = @import("terminal.zig");
const Terminal = term_mod.Terminal;

pub const Error = error{
    /// The bytes ran out before the structure did.
    TruncatedCheckpoint,
    /// A field held a value no encoder here produces.
    BadCheckpoint,
    /// A checkpoint claiming `scrollback_unchanged` was decoded without the
    /// blob it is claiming. The index never does this; a test does.
    MissingScrollback,
};

pub const magic_head: [4]u8 = .{ 'D', 'C', 'K', '1' };
pub const magic_sb: [4]u8 = .{ 'D', 'C', 'K', 'S' };
pub const version: u16 = 1;

/// Bit 0: this checkpoint's scrollback is the previous one's, verbatim.
pub const flag_scrollback_unchanged: u16 = 1 << 0;
/// Bit 1: reserved. Screens only, no history -- the second tier of the
/// fallback the sprint's measurement was allowed to force, and did not.
pub const flag_screen_only: u16 = 1 << 1;

/// Where in the log a checkpoint sits.
///
/// `event_index` is the number of events **already applied**, so replaying
/// `[event_index, target)` from this state reaches `target`. That is the only
/// definition under which "seek to now" and "the live terminal" are the same
/// thing.
pub const Meta = struct {
    event_index: u64 = 0,
    at_us: u64 = 0,
    /// Cumulative bytes of `output` payload applied before this point. The
    /// spacing between checkpoints is measured in these.
    byte_pos: u64 = 0,
};

// ---------------------------------------------------------------------------
// Varints
// ---------------------------------------------------------------------------
//
// LEB128, unsigned, with zigzag for the one signed field (a row id delta).
// The reader refuses a truncated stream and a run of continuation bytes long
// enough to overflow, because "the last checkpoint in a corrupt index decodes
// into a terminal made of whatever followed it" is not a failure mode worth
// having.

fn putVarint(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: u64) !void {
    var v = value;
    while (true) {
        const byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            try out.append(alloc, byte);
            return;
        }
        try out.append(alloc, byte | 0x80);
    }
}

fn zigzag(v: i64) u64 {
    return @bitCast((v << 1) ^ (v >> 63));
}

fn unzigzag(v: u64) i64 {
    return @as(i64, @bitCast(v >> 1)) ^ -@as(i64, @intCast(v & 1));
}

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn byte(self: *Reader) Error!u8 {
        if (self.i >= self.b.len) return Error.TruncatedCheckpoint;
        defer self.i += 1;
        return self.b[self.i];
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.b.len - self.i < n) return Error.TruncatedCheckpoint;
        defer self.i += n;
        return self.b[self.i..][0..n];
    }

    fn u16le(self: *Reader) Error!u16 {
        const s = try self.take(2);
        return std.mem.readInt(u16, s[0..2], .little);
    }

    fn varint(self: *Reader) Error!u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const c = try self.byte();
            v |= @as(u64, c & 0x7f) << shift;
            if (c & 0x80 == 0) return v;
            // Ten groups of seven bits is more than a u64 holds. Anything
            // longer is not a number this encoder wrote.
            if (shift >= 63) return Error.BadCheckpoint;
            shift += 7;
        }
    }

    fn usizeAt(self: *Reader, limit: usize) Error!usize {
        const v = try self.varint();
        if (v > limit) return Error.BadCheckpoint;
        return @intCast(v);
    }
};

// ---------------------------------------------------------------------------
// The style table
// ---------------------------------------------------------------------------
//
// Everything about a cell except its codepoint. A row is then runs of
// (style, count, codepoints), which is what makes a screen of shell output --
// long stretches of one style -- cost about a byte a character.

const Style = struct {
    fg: grid.Color,
    bg: grid.Color,
    attrs: grid.Attrs,
    wide: grid.Wide,

    fn of(c: grid.Cell) Style {
        return .{ .fg = c.fg, .bg = c.bg, .attrs = c.attrs, .wide = c.wide };
    }

    fn eqlCell(self: Style, c: grid.Cell) bool {
        return @as(u8, @bitCast(self.attrs)) == @as(u8, @bitCast(c.attrs)) and
            self.wide == c.wide and self.fg.eql(c.fg) and self.bg.eql(c.bg);
    }

    /// A style packed into 62 bits, so the dedupe map can be an
    /// `AutoHashMap(u64, u32)` rather than depend on `autoHash` doing
    /// something sensible with a tagged union.
    fn key(self: Style) u64 {
        return colorKey(self.fg) |
            (colorKey(self.bg) << 26) |
            (@as(u64, @as(u8, @bitCast(self.attrs))) << 52) |
            (@as(u64, @intFromEnum(self.wide)) << 60);
    }

    fn colorKey(c: grid.Color) u64 {
        return switch (c) {
            .default => 0,
            .indexed => |i| (1 << 24) | @as(u64, i),
            .rgb => |v| (2 << 24) |
                (@as(u64, v.r) << 16) | (@as(u64, v.g) << 8) | @as(u64, v.b),
        };
    }
};

fn putColor(out: *std.ArrayList(u8), alloc: std.mem.Allocator, c: grid.Color) !void {
    switch (c) {
        .default => try out.append(alloc, 0),
        .indexed => |i| try out.appendSlice(alloc, &[_]u8{ 1, i }),
        .rgb => |v| try out.appendSlice(alloc, &[_]u8{ 2, v.r, v.g, v.b }),
    }
}

fn getColor(r: *Reader) Error!grid.Color {
    return switch (try r.byte()) {
        0 => .default,
        1 => .{ .indexed = try r.byte() },
        2 => .{ .rgb = .{ .r = try r.byte(), .g = try r.byte(), .b = try r.byte() } },
        else => Error.BadCheckpoint,
    };
}

/// Whether a cell is *exactly* blank, so trailing ones can be trimmed.
///
/// **Not `Cell.isBlank()`**, which asks a different question -- it ignores
/// the foreground and the attributes, because it exists to decide whether a
/// cell is worth drawing. Trimming by it would drop a red-on-default trailing
/// space, and a checkpoint that drops it decodes to a terminal whose checksum
/// differs from the one it was taken from. That is a mutant this file's tests
/// plant on purpose.
fn isExactlyBlank(c: grid.Cell) bool {
    const b = grid.Cell.blank;
    return c.cp == b.cp and c.wide == b.wide and
        @as(u8, @bitCast(c.attrs)) == @as(u8, @bitCast(b.attrs)) and
        c.fg.eql(b.fg) and c.bg.eql(b.bg);
}

/// Encoder state: the body being built, and the style table being built with
/// it, so one pass over the cells does both.
const Enc = struct {
    alloc: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    styles: std.ArrayList(Style) = .empty,
    map: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn deinit(self: *Enc) void {
        self.body.deinit(self.alloc);
        self.styles.deinit(self.alloc);
        self.map.deinit(self.alloc);
    }

    fn styleIndex(self: *Enc, s: Style) !u32 {
        const gop = try self.map.getOrPut(self.alloc, s.key());
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(self.styles.items.len);
            try self.styles.append(self.alloc, s);
        }
        return gop.value_ptr.*;
    }

    fn v(self: *Enc, value: u64) !void {
        try putVarint(&self.body, self.alloc, value);
    }

    /// One row, in **logical** order. The caller is responsible for that:
    /// `cells` must come from `row(y)` or `back(i)`, never from a slice of
    /// `Screen.cells`, or a rotated screen encodes as a rotated screen.
    fn row(self: *Enc, cells: []const grid.Cell, meta: grid.RowMeta, prev_id: *u64) !void {
        const delta = @as(i64, @bitCast(meta.id)) -% @as(i64, @bitCast(prev_id.*));
        try self.v(zigzag(delta));
        prev_id.* = meta.id;
        try self.body.append(self.alloc, @bitCast(meta.flags));

        var used = cells.len;
        while (used > 0 and isExactlyBlank(cells[used - 1])) used -= 1;
        try self.v(used);

        var x: usize = 0;
        while (x < used) {
            const s = Style.of(cells[x]);
            const idx = try self.styleIndex(s);
            var n: usize = 1;
            while (x + n < used and s.eqlCell(cells[x + n])) n += 1;
            try self.v(idx);
            try self.v(n);
            for (cells[x..][0..n]) |c| try self.v(c.cp);
            x += n;
        }
    }

    /// Emit the style table, then the body, into `out`.
    fn finish(self: *Enc, out: *std.ArrayList(u8)) !void {
        try putVarint(out, self.alloc, self.styles.items.len);
        for (self.styles.items) |s| {
            try putColor(out, self.alloc, s.fg);
            try putColor(out, self.alloc, s.bg);
            try out.append(self.alloc, @bitCast(s.attrs));
            try out.append(self.alloc, @intFromEnum(s.wide));
        }
        try out.appendSlice(self.alloc, self.body.items);
    }
};

fn readStyles(alloc: std.mem.Allocator, r: *Reader) ![]Style {
    // Bounded before it allocates: a length field with nothing behind it is
    // four bytes of allocation request, which is the shape of the bug L0
    // found in its own `resize` payload.
    const n = try r.varint();
    if (n > r.b.len) return Error.BadCheckpoint;
    const out = try alloc.alloc(Style, @intCast(n));
    errdefer alloc.free(out);
    for (out) |*s| {
        s.fg = try getColor(r);
        s.bg = try getColor(r);
        s.attrs = @bitCast(try r.byte());
        s.wide = switch (try r.byte()) {
            0 => .narrow,
            1 => .wide,
            2 => .spacer,
            else => return Error.BadCheckpoint,
        };
    }
    return out;
}

fn readRow(
    r: *Reader,
    styles: []const Style,
    cells: []grid.Cell,
    meta: *grid.RowMeta,
    prev_id: *u64,
) Error!void {
    const id = prev_id.* +% @as(u64, @bitCast(unzigzag(try r.varint())));
    meta.* = .{ .id = id, .flags = @bitCast(try r.byte()) };
    prev_id.* = id;

    const used = try r.usizeAt(cells.len);
    @memset(cells, .blank);

    var x: usize = 0;
    while (x < used) {
        const si = try r.varint();
        if (si >= styles.len) return Error.BadCheckpoint;
        const n = try r.usizeAt(used - x);
        if (n == 0) return Error.BadCheckpoint;
        const s = styles[@intCast(si)];
        for (cells[x..][0..n]) |*c| {
            const cp = try r.varint();
            if (cp > 0x10ffff) return Error.BadCheckpoint;
            c.* = .{
                .cp = @intCast(cp),
                .fg = s.fg,
                .bg = s.bg,
                .attrs = s.attrs,
                .wide = s.wide,
            };
        }
        x += n;
    }
}

// ---------------------------------------------------------------------------
// The modes bitfield
// ---------------------------------------------------------------------------
//
// In `check.zig`'s order, which is `Modes`' declaration order. The comptime
// guard at the bottom of this file is what stops the two drifting.

fn modesBits(m: term_mod.Modes) u16 {
    var v: u16 = 0;
    inline for (@typeInfo(term_mod.Modes).@"struct".fields, 0..) |f, i| {
        if (@field(m, f.name)) v |= @as(u16, 1) << @intCast(i);
    }
    return v;
}

fn modesFrom(v: u16) term_mod.Modes {
    var m: term_mod.Modes = .{};
    inline for (@typeInfo(term_mod.Modes).@"struct".fields, 0..) |f, i| {
        @field(m, f.name) = (v & (@as(u16, 1) << @intCast(i))) != 0;
    }
    return m;
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

/// What one checkpoint is, as bytes.
///
/// Two blobs rather than one, because that is what makes
/// `scrollback_unchanged` free: when the history has not moved, `scrollback`
/// is null and the index points this entry at the previous entry's blob.
pub const Encoded = struct {
    head: []u8,
    scrollback: ?[]u8,

    pub fn deinit(self: *Encoded, alloc: std.mem.Allocator) void {
        alloc.free(self.head);
        if (self.scrollback) |s| alloc.free(s);
        self.* = undefined;
    }

    pub fn bytes(self: Encoded) usize {
        return self.head.len + if (self.scrollback) |s| s.len else 0;
    }
};

fn putCursor(out: *std.ArrayList(u8), alloc: std.mem.Allocator, c: term_mod.Cursor) !void {
    try putVarint(out, alloc, c.x);
    try putVarint(out, alloc, c.y);
    try putColor(out, alloc, c.fg);
    try putColor(out, alloc, c.bg);
    try out.append(alloc, @bitCast(c.attrs));
}

fn getCursor(r: *Reader, cols: usize, rows: usize) Error!term_mod.Cursor {
    return .{
        .x = try r.usizeAt(if (cols == 0) 0 else cols - 1),
        .y = try r.usizeAt(if (rows == 0) 0 else rows - 1),
        .fg = try getColor(r),
        .bg = try getColor(r),
        .attrs = @bitCast(try r.byte()),
    };
}

/// Serialise `term`. The caller owns the result.
///
/// `scrollback_unchanged` is the caller's claim, not this function's guess:
/// only the index knows what the previous checkpoint held. Passing it wrongly
/// is a mutant the tests plant.
pub fn encode(
    alloc: std.mem.Allocator,
    term: *Terminal,
    meta: Meta,
    scrollback_unchanged: bool,
) !Encoded {
    var head: std.ArrayList(u8) = .empty;
    errdefer head.deinit(alloc);

    try head.appendSlice(alloc, &magic_head);
    var vbuf: [2]u8 = undefined;
    std.mem.writeInt(u16, &vbuf, version, .little);
    try head.appendSlice(alloc, &vbuf);
    std.mem.writeInt(u16, &vbuf, if (scrollback_unchanged) flag_scrollback_unchanged else 0, .little);
    try head.appendSlice(alloc, &vbuf);

    try putVarint(&head, alloc, term.cols);
    try putVarint(&head, alloc, term.rows);
    try putVarint(&head, alloc, meta.event_index);
    try putVarint(&head, alloc, meta.at_us);
    try putVarint(&head, alloc, meta.byte_pos);

    try putCursor(&head, alloc, term.cursor);
    try putCursor(&head, alloc, term.saved_cursor);
    try head.append(alloc, @intFromBool(term.pending_wrap));
    try head.append(alloc, @intFromBool(term.on_alt));
    try putVarint(&head, alloc, term.scroll_top);
    try putVarint(&head, alloc, term.scroll_bot);

    std.mem.writeInt(u16, &vbuf, modesBits(term.modes), .little);
    try head.appendSlice(alloc, &vbuf);

    try putVarint(&head, alloc, term.tabstops.len);
    {
        var bits: u8 = 0;
        for (term.tabstops, 0..) |t, i| {
            if (t) bits |= @as(u8, 1) << @intCast(i % 8);
            if (i % 8 == 7) {
                try head.append(alloc, bits);
                bits = 0;
            }
        }
        if (term.tabstops.len % 8 != 0) try head.append(alloc, bits);
    }

    try putVarint(&head, alloc, term.next_line_id);
    try putVarint(&head, alloc, term.scrollback.pushes);
    try putVarint(&head, alloc, term.scrollback.epoch);
    try putVarint(&head, alloc, term.title.items.len);
    try head.appendSlice(alloc, term.title.items);

    var enc = Enc{ .alloc = alloc };
    defer enc.deinit();
    // Both screens, each through `row(y)` in logical order. The inactive one
    // matters: an alt-screen program that exits leaves the primary behind it,
    // and `check.zig` hashes both for the same reason.
    for ([_]*const grid.Screen{ &term.primary, &term.alt }) |s| {
        var prev_id: u64 = 0;
        for (0..s.rows) |y| try enc.row(s.row(y), s.rowMeta(y).*, &prev_id);
    }
    try enc.finish(&head);

    var sb: ?[]u8 = null;
    if (!scrollback_unchanged) {
        var sbuf: std.ArrayList(u8) = .empty;
        errdefer sbuf.deinit(alloc);
        try sbuf.appendSlice(alloc, &magic_sb);
        try putVarint(&sbuf, alloc, term.scrollback.len);

        var senc = Enc{ .alloc = alloc };
        defer senc.deinit();
        var prev_id: u64 = 0;
        // **Oldest first**, which is `back(len - 1 - i)`. Newest-first would
        // decode into a reversed history that no checksum over `back(i)`
        // could confuse with the real one -- which is the point: the ring's
        // head is not a property of the model, so the wire order has to be
        // the one `push` will reproduce.
        var i: usize = term.scrollback.len;
        while (i > 0) {
            i -= 1;
            const line = term.scrollback.back(i) orelse return Error.BadCheckpoint;
            const m = term.scrollback.backMeta(i) orelse return Error.BadCheckpoint;
            try senc.row(line, m, &prev_id);
        }
        try senc.finish(&sbuf);
        sb = try sbuf.toOwnedSlice(alloc);
    }
    errdefer if (sb) |s| alloc.free(s);

    return .{ .head = try head.toOwnedSlice(alloc), .scrollback = sb };
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// Restore `term` from a checkpoint. `sb` is the scrollback blob this
/// checkpoint refers to -- its own, or (when `scrollback_unchanged` is set)
/// the one an earlier checkpoint produced.
///
/// The terminal is reshaped to the checkpoint's geometry if it does not
/// already match, so the caller may hand in any terminal it owns.
pub fn decode(
    alloc: std.mem.Allocator,
    head: []const u8,
    sb: ?[]const u8,
    term: *Terminal,
) !Meta {
    var r = Reader{ .b = head };
    if (!std.mem.eql(u8, try r.take(4), &magic_head)) return Error.BadCheckpoint;
    if (try r.u16le() != version) return Error.BadCheckpoint;
    const flags = try r.u16le();

    const cols = try r.usizeAt(rec.max_dim);
    const rows = try r.usizeAt(rec.max_dim);
    if (cols == 0 or rows == 0) return Error.BadCheckpoint;
    if (cols != term.cols or rows != term.rows) try term.resize(cols, rows);

    const meta = Meta{
        .event_index = try r.varint(),
        .at_us = try r.varint(),
        .byte_pos = try r.varint(),
    };

    const cursor = try getCursor(&r, cols, rows);
    const saved = try getCursor(&r, cols, rows);
    const pending_wrap = (try r.byte()) != 0;
    const on_alt = (try r.byte()) != 0;
    const scroll_top = try r.usizeAt(rows - 1);
    const scroll_bot = try r.usizeAt(rows - 1);
    if (scroll_top > scroll_bot) return Error.BadCheckpoint;
    const modes = modesFrom(try r.u16le());

    const tabs = try r.usizeAt(cols);
    if (tabs != cols) return Error.BadCheckpoint;
    const tab_bytes = try r.take((tabs + 7) / 8);

    const next_line_id = try r.varint();
    const pushes = try r.varint();
    const epoch = try r.varint();
    const title_len = try r.usizeAt(head.len);
    const title = try r.take(title_len);

    const styles = try readStyles(alloc, &r);
    defer alloc.free(styles);

    // Everything that can fail on the wire has been read before a single
    // field of `term` is touched, except the screens themselves -- which are
    // written into place. A half-decoded terminal is still a terminal a
    // seek can show; a half-decoded one that also lost its cursor is not.
    for ([_]*grid.Screen{ &term.primary, &term.alt }) |s| {
        // Canonical: ring position is not a property of the model, so a
        // decode always produces offset 0 and the encoder always wrote
        // logical order. Preserving the offset instead would round-trip and
        // still be wrong, because two terminals showing the same screen would
        // decode to different memory.
        s.offset = 0;
        var prev_id: u64 = 0;
        for (0..s.rows) |y| try readRow(&r, styles, s.row(y), s.rowMeta(y), &prev_id);
    }

    term.scrollback.clear();
    if (flags & flag_scrollback_unchanged != 0 and sb == null) return Error.MissingScrollback;
    if (sb) |blob| {
        var sr = Reader{ .b = blob };
        if (!std.mem.eql(u8, try sr.take(4), &magic_sb)) return Error.BadCheckpoint;
        const count = try sr.usizeAt(term.scrollback.capacity);
        const sstyles = try readStyles(alloc, &sr);
        defer alloc.free(sstyles);

        const line = try alloc.alloc(grid.Cell, cols);
        defer alloc.free(line);
        var prev_id: u64 = 0;
        var m: grid.RowMeta = .none;
        // Oldest first, pushed in that order, so `head` lands exactly where a
        // live session would have left it.
        for (0..count) |_| {
            try readRow(&sr, sstyles, line, &m, &prev_id);
            term.scrollback.push(line, m);
        }
    }

    term.cursor = cursor;
    term.saved_cursor = saved;
    term.pending_wrap = pending_wrap;
    term.on_alt = on_alt;
    term.scroll_top = scroll_top;
    term.scroll_bot = scroll_bot;
    term.modes = modes;
    for (term.tabstops, 0..) |*t, i| {
        t.* = (tab_bytes[i / 8] & (@as(u8, 1) << @intCast(i % 8))) != 0;
    }
    term.next_line_id = next_line_id;
    term.scrollback.pushes = pushes;
    term.scrollback.epoch = epoch;
    term.title.clearRetainingCapacity();
    try term.title.appendSlice(term.alloc, title);

    // Window state, not stream state: a decoded terminal is looking at the
    // live bottom of its own history with nothing selected.
    term.view_offset = 0;
    term.selection = null;
    term.replies.clearRetainingCapacity();
    term.bell = false;
    term.dirty = true;
    return meta;
}

// ---------------------------------------------------------------------------
// Keeping this file and check.zig in step, by mechanism
// ---------------------------------------------------------------------------
//
// A field added to `Terminal`, `Modes` or `Cell` and not added here is a seek
// that silently loses it. Nothing about writing the field is checkable by a
// compiler, but *noticing* is: these counts fail the build, and the message
// names both files.

comptime {
    const t_fields = @typeInfo(Terminal).@"struct".fields.len;
    if (t_fields != 21) @compileError(
        "Terminal gained or lost a field. Decide whether a checkpoint must " ++
            "carry it (src/ckpt.zig) and whether the arbiter must hash it " ++
            "(src/check.zig), then update this count.",
    );
    const m_fields = @typeInfo(term_mod.Modes).@"struct".fields.len;
    if (m_fields != 8) @compileError(
        "Modes gained or lost a field. `modesBits` in src/ckpt.zig packs them " ++
            "positionally and src/check.zig hashes them by name; update both, " ++
            "then this count.",
    );
    const sb_fields = @typeInfo(grid.Scrollback).@"struct".fields.len;
    if (sb_fields != 8) @compileError(
        "Scrollback gained or lost a field. `pushes` and `epoch` are what " ++
            "src/ckpt.zig's `scrollback_unchanged` claim rests on; if the ring " ++
            "grew another piece of identity, decide whether the claim still " ++
            "holds, then update this count.",
    );
    const c_fields = @typeInfo(grid.Cell).@"struct".fields.len;
    if (c_fields != 5) @compileError(
        "Cell gained or lost a field. src/ckpt.zig's style table carries " ++
            "everything but `cp`; src/check.zig hashes all of it. Update both, " ++
            "then this count.",
    );
}

// ---------------------------------------------------------------------------
// The index
// ---------------------------------------------------------------------------

/// A stretch of the session spent on the alternate screen.
///
/// `exit_event` is the event that *left* it, so the state at `exit_event` is
/// the last frame the full-screen program drew. An index entry is forced at
/// exactly that boundary, which is why `Cmd ⇧ ↑` is a decode and no replay.
///
/// **These live in the index, not in the file.** Record type 8 (`mark`) stays
/// reserved and unwritten: L1 adds no bytes to a `.trec`.
pub const Span = struct {
    enter_event: usize,
    exit_event: usize,
    at_us: u64,
};

pub const Entry = struct {
    /// Events already applied. Replaying `[event_index, target)` reaches
    /// `target`.
    event_index: usize,
    at_us: u64,
    byte_pos: u64,
    head: []u8,
    /// Which blob in `Index.blobs` holds this entry's scrollback.
    sb: usize,
    /// The history this entry was taken over, so the *next* one can decide
    /// whether it may point at the same blob.
    sb_pushes: u64,
    sb_epoch: u64,
    /// Forced at an alt-screen exit boundary. Never dropped by decimation:
    /// it is the entry the demo exists for.
    forced: bool = false,
};

const Blob = struct { bytes: []u8, refs: usize };

pub const Options = struct {
    /// Bytes of cumulative `output` payload between checkpoints.
    ///
    /// 1 MiB, not the 4 MiB `record.md` proposed. The page's own arithmetic
    /// assumed >100 MiB/s and got "under 40 ms"; the measured parse rate at
    /// **200x60** -- the geometry the 50 ms budget is stated at, and which
    /// nothing measured before this sprint -- puts 4 MiB at the edge of the
    /// budget rather than comfortably inside it. See the sprint record.
    interval: u64 = 1 << 20,
    /// The index is a cache in RAM. This is what it may cost.
    max_bytes: u64 = 32 << 20,
    min_entries: usize = 8,
    max_entries: usize = 64,
};

pub const Index = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    entries: std.ArrayList(Entry) = .empty,
    blobs: std.ArrayList(Blob) = .empty,
    spans: std.ArrayList(Span) = .empty,

    /// The spacing actually in force. Doubles each time the budget is hit.
    interval: u64,
    /// How many entries fit in the budget, from the largest checkpoint seen.
    budget: usize,
    /// Everything the index knows about the session it was built from.
    events: usize = 0,
    duration_us: u64 = 0,
    output_bytes: u64 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    /// Bytes held, for `--frame-stats` and for the sprint's memory claim.
    bytes: u64 = 0,
    /// Entries that were taken and later dropped by decimation.
    decimations: usize = 0,

    pub fn init(alloc: std.mem.Allocator, opts: Options) Index {
        return .{
            .alloc = alloc,
            .opts = opts,
            .interval = opts.interval,
            .budget = opts.max_entries,
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |e| self.alloc.free(e.head);
        for (self.blobs.items) |b| {
            if (b.refs > 0) self.alloc.free(b.bytes);
        }
        self.entries.deinit(self.alloc);
        self.blobs.deinit(self.alloc);
        self.spans.deinit(self.alloc);
        self.* = undefined;
    }

    /// Take a checkpoint of `term` at this boundary.
    pub fn take(self: *Index, term: *Terminal, meta: Meta, forced: bool) !void {
        // The identity claim: same pushes, same epoch, therefore the same
        // history, therefore the previous entry's blob verbatim.
        var reuse: ?usize = null;
        if (self.entries.items.len > 0) {
            const prev = self.entries.items[self.entries.items.len - 1];
            if (prev.sb_pushes == term.scrollback.pushes and
                prev.sb_epoch == term.scrollback.epoch)
            {
                reuse = prev.sb;
            }
        }

        // Room reserved before anything is moved into it, so the failure path
        // frees exactly the encoding and nothing that is already owned.
        try self.entries.ensureUnusedCapacity(self.alloc, 1);
        if (reuse == null) try self.blobs.ensureUnusedCapacity(self.alloc, 1);

        var enc = try encode(self.alloc, term, meta, reuse != null);
        errdefer enc.deinit(self.alloc);

        const sb_slot = if (reuse) |s| blk: {
            self.blobs.items[s].refs += 1;
            break :blk s;
        } else blk: {
            self.blobs.appendAssumeCapacity(.{ .bytes = enc.scrollback.?, .refs = 1 });
            self.bytes += enc.scrollback.?.len;
            break :blk self.blobs.items.len - 1;
        };

        self.entries.appendAssumeCapacity(.{
            .event_index = @intCast(meta.event_index),
            .at_us = meta.at_us,
            .byte_pos = meta.byte_pos,
            .head = enc.head,
            .sb = sb_slot,
            .sb_pushes = term.scrollback.pushes,
            .sb_epoch = term.scrollback.epoch,
            .forced = forced,
        });
        self.bytes += enc.head.len;
        enc = .{ .head = &.{}, .scrollback = null }; // the index owns it now

        // `clamp(32 MiB / checkpoint_size, 8, 64)`, sized from the largest
        // whole checkpoint seen rather than an average: the budget has to hold
        // when the next one is as big as the worst one so far.
        const size = @max(
            self.entries.items[self.entries.items.len - 1].head.len +
                self.blobs.items[sb_slot].bytes.len,
            1,
        );
        self.budget = std.math.clamp(
            @as(usize, @intCast(self.opts.max_bytes / size)),
            self.opts.min_entries,
            self.opts.max_entries,
        );
        if (self.entries.items.len > self.budget) self.decimate();
    }

    /// Drop every other entry and double the spacing.
    ///
    /// The first entry stays -- it is the only one that can serve a target
    /// before the second -- and so does every forced alt-exit entry, because
    /// those are the ones `Cmd ⇧ ↑` exists to land on. Dropping one would
    /// turn the sprint's whole demo into a forward replay, which is a mutant
    /// the tests plant.
    fn decimate(self: *Index) void {
        var write: usize = 0;
        for (self.entries.items, 0..) |e, i| {
            const keep = i == 0 or e.forced or i % 2 == 0;
            if (keep) {
                self.entries.items[write] = e;
                write += 1;
            } else {
                self.release(e);
                self.decimations += 1;
            }
        }
        self.entries.shrinkRetainingCapacity(write);
        self.interval *|= 2;
    }

    fn release(self: *Index, e: Entry) void {
        self.bytes -= e.head.len;
        self.alloc.free(e.head);
        const b = &self.blobs.items[e.sb];
        b.refs -= 1;
        if (b.refs == 0) {
            self.bytes -= b.bytes.len;
            self.alloc.free(b.bytes);
            b.bytes = &.{};
        }
    }

    /// The greatest entry whose `event_index <= target`, or null when the
    /// index is empty.
    pub fn before(self: *const Index, target: usize) ?usize {
        if (self.entries.items.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.entries.items[mid].event_index <= target) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) null else lo - 1;
    }

    /// Decode entry `i` into `term`.
    pub fn restore(self: *const Index, i: usize, term: *Terminal) !Meta {
        const e = self.entries.items[i];
        return decode(self.alloc, e.head, self.blobs.items[e.sb].bytes, term);
    }
};

/// The first event at or after `at_us`, as an event index. Events carry
/// non-decreasing timestamps by construction, so this is a plain bisection.
pub fn eventAtTime(events: []const rec.Event, at_us: u64) usize {
    var lo: usize = 0;
    var hi: usize = events.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (events[mid].at_us < at_us) lo = mid + 1 else hi = mid;
    }
    return lo;
}

// ---------------------------------------------------------------------------
// The builder
// ---------------------------------------------------------------------------

/// Does this payload complete a sequence that leaves the alternate screen?
///
/// A scan rather than a parse, run only while `on_alt` is already true, so it
/// costs nothing on the ordinary path. A false positive costs one extra
/// checkpoint and nothing else; a false negative -- the sequence split across
/// two reads -- loses the forced frame, and the parser is not at ground at
/// that boundary anyway, so it could not have been checkpointed there.
fn leavesAlt(payload: []const u8) bool {
    for ([_][]const u8{
        "\x1b[?1049l",
        "\x1b[?1047l",
        "\x1b[?47l",
        "\x1bc", // RIS clears `on_alt` too
    }) |needle| {
        if (std.mem.indexOf(u8, payload, needle) != null) return true;
    }
    return false;
}

/// Build an index over a parsed session.
///
/// The `Terminal` this replays into is local and is freed on the way out: the
/// index is the product, and holding a second full terminal for the window's
/// life would put another `cols * rows * 16 * 2` plus a 10,000-line ring on
/// the heap for nothing.
pub fn build(alloc: std.mem.Allocator, session: rec.Session, opts: Options) !Index {
    var idx = Index.init(alloc, opts);
    errdefer idx.deinit();
    idx.cols = session.header.cols;
    idx.rows = session.header.rows;
    idx.events = session.events.len;

    var term = try Terminal.init(alloc, session.header.cols, session.header.rows);
    defer term.deinit();
    var parser: vt.Parser = .{};

    // The empty terminal, so every target has an entry at or before it.
    try idx.take(&term, .{}, false);

    var out_bytes: u64 = 0;
    var last_at: u64 = 0;
    var alt_enter: ?usize = null;

    for (session.events, 0..) |e, i| {
        // Forced, *before* the event that leaves the alt screen, so the state
        // saved is the last frame the full-screen program drew.
        //
        // The honest caveat: the boundary is a whole pty read. If a program's
        // final repaint and its `?1049l` arrive in the same 1,024-byte read,
        // this lands one read earlier than the true last frame.
        if (term.on_alt and e.kind == .output and parser.atGround() and leavesAlt(e.payload)) {
            try idx.take(&term, .{ .event_index = i, .at_us = last_at, .byte_pos = out_bytes }, true);
        }

        const was_alt = term.on_alt;
        try replay.applyEvent(&term, &parser, e);
        if (e.kind == .output) out_bytes += e.payload.len;
        last_at = e.at_us;

        if (!was_alt and term.on_alt) alt_enter = i;
        if (was_alt and !term.on_alt) {
            try idx.spans.append(alloc, .{
                .enter_event = alt_enter orelse 0,
                .exit_event = i,
                .at_us = e.at_us,
            });
            alt_enter = null;
        }

        // Only at a ground boundary: a checkpoint carries no parser state, and
        // a seek replays forward with a fresh one.
        const last_pos = if (idx.entries.items.len == 0) 0 else idx.entries.items[idx.entries.items.len - 1].byte_pos;
        if (out_bytes -| last_pos >= idx.interval and parser.atGround()) {
            try idx.take(&term, .{
                .event_index = i + 1,
                .at_us = e.at_us,
                .byte_pos = out_bytes,
            }, false);
        }
    }

    idx.output_bytes = out_bytes;
    idx.duration_us = last_at;
    return idx;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const check = @import("check.zig");

fn feed(term: *Terminal, bytes: []const u8) void {
    var p: vt.Parser = .{};
    p.feed(term, bytes);
}

/// Everything a seek has to preserve: the checksum, plus the three things the
/// checksum is deliberately blind to.
const Fingerprint = struct {
    sum: u64,
    next_line_id: u64,
    title: []const u8,
    scrollback_len: usize,
    pushes: u64,
    epoch: u64,
    ids: [512]u64 = @splat(0),
    n_ids: usize = 0,

    fn of(term: *Terminal) Fingerprint {
        var f = Fingerprint{
            .sum = check.checksum(term),
            .next_line_id = term.next_line_id,
            .title = term.title.items,
            .scrollback_len = term.scrollback.len,
            .pushes = term.scrollback.pushes,
            .epoch = term.scrollback.epoch,
        };
        for (0..@min(term.rows, f.ids.len)) |y| {
            f.ids[y] = term.screen().rowMeta(y).id;
            f.n_ids = y + 1;
        }
        return f;
    }

    fn expectEqual(a: Fingerprint, b: Fingerprint) !void {
        try testing.expectEqual(a.sum, b.sum);
        try testing.expectEqual(a.next_line_id, b.next_line_id);
        try testing.expectEqualStrings(a.title, b.title);
        try testing.expectEqual(a.scrollback_len, b.scrollback_len);
        try testing.expectEqual(a.pushes, b.pushes);
        try testing.expectEqual(a.epoch, b.epoch);
        try testing.expectEqual(a.n_ids, b.n_ids);
        try testing.expectEqualSlices(u64, a.ids[0..a.n_ids], b.ids[0..b.n_ids]);
    }
};

fn roundTrip(alloc: std.mem.Allocator, src: *Terminal) !void {
    var enc = try encode(alloc, src, .{ .event_index = 7, .at_us = 1234, .byte_pos = 99 }, false);
    defer enc.deinit(alloc);

    // A *differently shaped* terminal on the way in, so the decode is doing
    // the reshaping rather than being handed a lucky match.
    var dst = try Terminal.init(alloc, 7, 3);
    defer dst.deinit();
    const meta = try decode(alloc, enc.head, enc.scrollback, &dst);
    try testing.expectEqual(@as(u64, 7), meta.event_index);
    try testing.expectEqual(@as(u64, 1234), meta.at_us);
    try testing.expectEqual(@as(u64, 99), meta.byte_pos);

    const want = Fingerprint.of(src);
    const got = Fingerprint.of(&dst);
    try want.expectEqual(got);
}

test "a checkpoint round-trips a plain screen" {
    var t = try Terminal.init(testing.allocator, 20, 5);
    defer t.deinit();
    feed(&t, "hello\r\n\x1b[31mred\x1b[0m\r\nthird line\r\n");
    try roundTrip(testing.allocator, &t);
}

test "a checkpoint round-trips every field check.zig claims to cover" {
    // The mechanism that keeps the two in step: this iterates `check.zig`'s
    // own table rather than a copy of it, so a case added there is a case
    // exercised here without anyone remembering to add it.
    for (check.field_cases) |case| {
        var t = try Terminal.init(testing.allocator, 20, 5);
        defer t.deinit();
        feed(&t, case.bytes);
        roundTrip(testing.allocator, &t) catch |err| {
            std.debug.print("checkpoint loses: {s}\n", .{case.name});
            return err;
        };
    }
}

test "a checkpoint round-trips a rotated screen and a partial ring" {
    // Two things at once, both about ring position: the screen's `offset` is
    // non-zero, and the scrollback's `head` has wrapped past the end. Neither
    // is a property of the model, and a decode that preserved either would
    // still round-trip -- so the assertion has to be that the *canonical*
    // form comes back.
    var t = try Terminal.init(testing.allocator, 8, 4);
    defer t.deinit();
    for (0..37) |i| {
        var buf: [16]u8 = undefined;
        feed(&t, std.fmt.bufPrint(&buf, "L{d}\r\n", .{i}) catch unreachable);
    }
    try testing.expect(t.screen().offset != 0);
    try testing.expect(t.scrollback.len > 0);
    try roundTrip(testing.allocator, &t);

    var enc = try encode(testing.allocator, &t, .{}, false);
    defer enc.deinit(testing.allocator);
    var dst = try Terminal.init(testing.allocator, 8, 4);
    defer dst.deinit();
    _ = try decode(testing.allocator, enc.head, enc.scrollback, &dst);
    try testing.expectEqual(@as(usize, 0), dst.primary.offset);
    try testing.expectEqual(@as(usize, 0), dst.alt.offset);
}

test "a full scrollback ring round-trips, head and all" {
    var t = try Terminal.init(testing.allocator, 12, 3);
    defer t.deinit();
    // Past the ring's capacity, so the oldest lines really have been evicted
    // and `head` has wrapped many times.
    for (0..term_mod.scrollback_lines + 40) |i| {
        var buf: [24]u8 = undefined;
        feed(&t, std.fmt.bufPrint(&buf, "R{d}\r\n", .{i}) catch unreachable);
    }
    try testing.expectEqual(term_mod.scrollback_lines, t.scrollback.len);
    try roundTrip(testing.allocator, &t);
}

test "a trailing space that carries a colour is not trimmed away" {
    // The trap `Cell.isBlank()` walks into: it ignores fg and attrs, because
    // it is asking "is this worth drawing", not "is this the blank cell". A
    // codec that trimmed by it would drop the last cell here and decode into
    // a terminal with a different checksum.
    var t = try Terminal.init(testing.allocator, 8, 2);
    defer t.deinit();
    feed(&t, "\x1b[31;4mab   ");
    // Column 4 is the last of three spaces printed *in red and underlined*;
    // columns 5..7 were never written and are the real blanks.
    const tail = t.screen().row(0)[4];
    try testing.expect(tail.isBlank()); // `isBlank` says yes ...
    try testing.expect(!isExactlyBlank(tail)); // ... and it is wrong to trim by
    try roundTrip(testing.allocator, &t);
}

test "both screens are carried, including the parked one" {
    var t = try Terminal.init(testing.allocator, 10, 3);
    defer t.deinit();
    feed(&t, "PRIMARY\x1b[?1049hALT-PARKED\x1b[?1049l");
    try testing.expect(!t.on_alt);
    try roundTrip(testing.allocator, &t);
}

test "the title, the line ids and the counters survive" {
    var t = try Terminal.init(testing.allocator, 16, 4);
    defer t.deinit();
    feed(&t, "\x1b]0;a child title\x07one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");
    try testing.expectEqualStrings("a child title", t.title.items);
    try testing.expect(t.next_line_id > 1);
    try testing.expect(t.scrollback.pushes > 0);
    try roundTrip(testing.allocator, &t);
}

test "a truncated checkpoint is refused rather than decoded" {
    var t = try Terminal.init(testing.allocator, 20, 6);
    defer t.deinit();
    feed(&t, "\x1b[33msome text\r\nmore text\r\n");
    var enc = try encode(testing.allocator, &t, .{}, false);
    defer enc.deinit(testing.allocator);

    var dst = try Terminal.init(testing.allocator, 20, 6);
    defer dst.deinit();
    // Every prefix. Not one arbitrary cut: a varint reader that accepted a
    // stream ending mid-number would only show up at particular offsets.
    var n: usize = 0;
    while (n < enc.head.len) : (n += 1) {
        try testing.expect(std.meta.isError(
            decode(testing.allocator, enc.head[0..n], enc.scrollback, &dst),
        ));
    }
    // And the whole thing still decodes, so the loop above is not passing
    // because everything fails.
    _ = try decode(testing.allocator, enc.head, enc.scrollback, &dst);
}

test "random bytes are refused, never trusted" {
    var dst = try Terminal.init(testing.allocator, 20, 6);
    defer dst.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..500) |_| {
        rnd.bytes(&buf);
        const n = 1 + rnd.uintLessThan(usize, buf.len);
        // Half of them wear the right magic, so the failure has to come from
        // the structure rather than from the first four bytes.
        if (rnd.boolean() and n >= 4) @memcpy(buf[0..4], &magic_head);
        _ = decode(testing.allocator, buf[0..n], null, &dst) catch continue;
    }
}

test "decimation never drops the frame the whole sprint is for" {
    // The index is a cache with a budget, and when it overflows it throws
    // every other entry away. The one entry it may never throw away is the
    // forced one at an alt-screen exit: that is the entry `Cmd ⇧ ↑` lands
    // on, and losing it turns the sprint's demo from a decode into a replay
    // of everything since the last surviving checkpoint.
    //
    // The checksum cannot see this. A decimated index still seeks correctly
    // -- it just replays further -- so the arbiter passes either way, and
    // the mutant that drops `e.forced` from the keep rule survived the whole
    // first pass. What catches it is asserting *which* entry serves the
    // target, and that reaching it costs zero events of replay.
    //
    // Five different amounts of leading output, because whether a dropped
    // forced entry happens to sit at an even index -- and so survive by luck
    // -- depends on where in the sequence it fell.
    for ([_]usize{ 40, 57, 73, 90, 111 }) |lead| {
        var events: std.ArrayList(rec.Event) = .empty;
        defer events.deinit(testing.allocator);
        var payloads: std.ArrayList([]u8) = .empty;
        defer {
            for (payloads.items) |p| testing.allocator.free(p);
            payloads.deinit(testing.allocator);
        }

        var at_us: u64 = 0;
        const add = struct {
            fn f(
                ev: *std.ArrayList(rec.Event),
                pl: *std.ArrayList([]u8),
                t: *u64,
                bytes: []const u8,
            ) !void {
                const owned = try testing.allocator.dupe(u8, bytes);
                errdefer testing.allocator.free(owned);
                try pl.append(testing.allocator, owned);
                t.* += 1000;
                try ev.append(testing.allocator, .{
                    .kind = .output,
                    .flags = 0,
                    .at_us = t.*,
                    .payload = owned,
                });
            }
        }.f;

        var buf: [128]u8 = undefined;
        for (0..lead) |i| {
            try add(&events, &payloads, &at_us, try std.fmt.bufPrint(
                &buf,
                "primary line {d:0>4} before anything took the screen\r\n",
                .{i},
            ));
        }
        try add(&events, &payloads, &at_us, "\x1b[?1049h");
        for (0..60) |i| {
            try add(&events, &payloads, &at_us, try std.fmt.bufPrint(
                &buf,
                "\x1b[{d};1H\x1b[3{d}mfull-screen redraw {d:0>4}\x1b[K",
                .{ (i % 8) + 1, i % 8, i },
            ));
        }
        // Its own read, so the builder's ground-state check has a boundary
        // to force a checkpoint at. See `ckpt.build`'s caveat.
        try add(&events, &payloads, &at_us, "\x1b[?1049l");
        for (0..lead) |i| {
            try add(&events, &payloads, &at_us, try std.fmt.bufPrint(
                &buf,
                "primary line {d:0>4} after it exited\r\n",
                .{i},
            ));
        }

        const session = rec.Session{
            .header = .{ .cols = 40, .rows = 8, .wall_start_ns = 0, .session_id = @splat(0) },
            .events = events.items,
        };
        // A budget of four entries against a session that wants dozens, so
        // decimation runs several times over.
        var idx = try build(testing.allocator, session, .{
            .interval = 256,
            .max_bytes = 1,
            .min_entries = 4,
            .max_entries = 8,
        });
        defer idx.deinit();

        // The test proves nothing unless the thing it is about happened.
        try testing.expect(idx.decimations > 0);
        try testing.expect(idx.entries.items.len <= 4);
        try testing.expectEqual(@as(usize, 1), idx.spans.items.len);

        const exit_event = idx.spans.items[0].exit_event;
        const at = idx.before(exit_event) orelse return error.NoCheckpointBefore;
        const entry = idx.entries.items[at];
        try testing.expect(entry.forced);
        // And the replay from it is empty: this is the claim that `Cmd ⇧ ↑`
        // is a decode and nothing else.
        try testing.expectEqual(exit_event, entry.event_index);

        // The frame really is the program's last one, not the shell's.
        var view = try Terminal.init(testing.allocator, 40, 8);
        defer view.deinit();
        _ = try idx.restore(at, &view);
        try testing.expect(view.on_alt);
    }
}

test "scrollback_unchanged decodes against the blob it names" {
    var t = try Terminal.init(testing.allocator, 10, 3);
    defer t.deinit();
    feed(&t, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n");

    var full = try encode(testing.allocator, &t, .{}, false);
    defer full.deinit(testing.allocator);
    try testing.expect(full.scrollback != null);

    // Nothing pushed since, so the claim holds.
    const pushes = t.scrollback.pushes;
    try testing.expect(pushes > 0);
    feed(&t, "\x1b[2;2Hx");
    try testing.expectEqual(pushes, t.scrollback.pushes);
    var reuse = try encode(testing.allocator, &t, .{}, true);
    defer reuse.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), reuse.scrollback);

    var dst = try Terminal.init(testing.allocator, 10, 3);
    defer dst.deinit();
    _ = try decode(testing.allocator, reuse.head, full.scrollback, &dst);
    try Fingerprint.of(&t).expectEqual(Fingerprint.of(&dst));

    // And a checkpoint that claims it without a blob is refused, rather than
    // decoding into a terminal with no history and a `scrollback.len` that
    // says otherwise.
    try testing.expectError(
        Error.MissingScrollback,
        decode(testing.allocator, reuse.head, null, &dst),
    );
}
