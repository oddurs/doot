//! Terminal state: the thing the parser drives and the renderer reads.
//!
//! This implements the actual semantics -- cursor movement, scroll regions,
//! erase, insert/delete, SGR styling, alternate screen. It is deliberately
//! free of any I/O: it never touches the PTY or the GPU, it just owns a grid
//! and mutates it. Anything it needs to send back to the child process (a
//! cursor-position report, a device attributes answer) lands in `replies` for
//! the caller to drain.

const std = @import("std");
const grid = @import("grid.zig");
const vt = @import("vt.zig");
const sel = @import("sel.zig");

const Cell = grid.Cell;
const Color = grid.Color;
const Attrs = grid.Attrs;
const Screen = grid.Screen;

pub const scrollback_lines = 10_000;

pub const Cursor = struct {
    x: usize = 0,
    y: usize = 0,
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},
};

pub const Modes = struct {
    /// DECAWM -- wrap at the right margin instead of overprinting.
    wrap: bool = true,
    /// DECTCEM -- is the cursor drawn.
    cursor_visible: bool = true,
    /// DECCKM -- arrow keys send SS3 A instead of CSI A.
    app_cursor: bool = false,
    /// DECOM -- cursor addressing is relative to the scroll region.
    origin: bool = false,
    /// Application keypad (ESC =).
    app_keypad: bool = false,
    /// Bracketed paste (2004) -- pasted text is wrapped in markers so the
    /// shell can tell it apart from typing.
    bracketed_paste: bool = false,
    /// A mouse *tracking* mode is on: 1000 (click), 1002 (button-event) or
    /// 1003 (any-event). The application owns the pointer while this is set,
    /// which is what `sel.mouseOwner` consults.
    mouse: bool = false,
    /// The SGR (1006) or urxvt (1015) *encoding* is selected. An encoding is
    /// not a tracking mode: these two used to be folded into `mouse`, so an
    /// application that sent `ESC[?1006h` on its own -- which many do, before
    /// or without ever asking for tracking -- silently took the mouse away
    /// from the user and disabled selection. E2 reads this to pick the wire
    /// format; nothing else should branch on it.
    mouse_sgr: bool = false,
};

pub const Terminal = struct {
    alloc: std.mem.Allocator,

    cols: usize,
    rows: usize,

    primary: Screen,
    alt: Screen,
    on_alt: bool = false,

    scrollback: grid.Scrollback,
    /// How many lines back from the live screen the viewport is scrolled.
    view_offset: usize = 0,

    cursor: Cursor = .{},
    saved_cursor: Cursor = .{},
    /// The cursor sits past the last column, waiting to wrap on the next
    /// printable character. VT terminals defer the wrap so that printing
    /// exactly `cols` characters doesn't scroll the screen.
    pending_wrap: bool = false,

    scroll_top: usize = 0,
    scroll_bot: usize,

    modes: Modes = .{},
    tabstops: []bool,

    title: std.ArrayList(u8) = .empty,
    replies: std.ArrayList(u8) = .empty,

    /// Set whenever anything visible changed. The renderer clears it.
    /// A full repaint of even a large window is a few thousand quads, which
    /// Metal eats for breakfast, so per-row damage tracking isn't worth its
    /// complexity yet.
    dirty: bool = true,
    bell: bool = false,

    // The two E1 fields are **last on purpose**. Everything above is what the
    // parse path touches on every byte, and putting a counter and a
    // forty-byte optional in front of `cursor` and `modes` moved them across
    // a cache line: 25% of the `ascii` corpus and 35% of `scroll`, measured,
    // for two fields the hot path never reads.

    /// The next line id to hand out. **One counter for both screens and the
    /// scrollback**, so every id in the terminal is disjoint from every other
    /// and a selection anchor can never resolve onto an alt-screen row that
    /// happens to share a number with the primary row it was taken from.
    ///
    /// Ids are *stored*, never derived from a base: `IL`, `DL` and a DECSTBM
    /// region scroll splice rows into the middle of the screen, so anything
    /// computed as "base plus offset" silently relabels every row below the
    /// splice. It starts at 1 because `RowMeta.id == 0` means "no line".
    ///
    /// Never reset -- `fullReset` deliberately leaves it alone. Reusing a
    /// number after a reset is the one way a stale anchor could resolve onto
    /// a live row.
    next_line_id: u64 = 1,

    /// What the user has selected, or null. Anchored to line ids, so it
    /// survives the ring rotating, a scrollback push and the viewport
    /// snapping back to the bottom. See `src/sel.zig`; the policy for when it
    /// is cleared is in `setSelection`'s callers and `clearSelection` below.
    selection: ?sel.Selection = null,

    pub fn init(alloc: std.mem.Allocator, cols: usize, rows: usize) !Terminal {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        // Disjoint id ranges from the first row onwards: primary 1..r, alt
        // r+1..2r, and the counter carries on from there.
        var primary = try Screen.init(alloc, c, r, 1);
        errdefer primary.deinit(alloc);
        var alt = try Screen.init(alloc, c, r, 1 + r);
        errdefer alt.deinit(alloc);
        var sb = try grid.Scrollback.init(alloc, c, scrollback_lines);
        errdefer sb.deinit(alloc);
        const tabs = try alloc.alloc(bool, c);

        var self = Terminal{
            .alloc = alloc,
            .cols = c,
            .rows = r,
            .primary = primary,
            .alt = alt,
            .scrollback = sb,
            .scroll_bot = r - 1,
            .tabstops = tabs,
            .next_line_id = 1 + 2 * r,
        };
        self.resetTabstops();
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.primary.deinit(self.alloc);
        self.alt.deinit(self.alloc);
        self.scrollback.deinit(self.alloc);
        self.alloc.free(self.tabstops);
        self.title.deinit(self.alloc);
        self.replies.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn screen(self: *Terminal) *Screen {
        return if (self.on_alt) &self.alt else &self.primary;
    }

    /// A blank cell carrying the cursor's current background, so that erasing
    /// while a background color is set paints that color (as xterm does).
    fn blankCell(self: *const Terminal) Cell {
        return .{ .bg = self.cursor.bg };
    }

    fn resetTabstops(self: *Terminal) void {
        for (self.tabstops, 0..) |*t, i| t.* = (i % 8 == 0 and i != 0);
    }

    // -- line identity ------------------------------------------------------
    //
    // `grid.zig` stores ids and stamps the ones it is given; the policy of
    // where they come from is here, because grid holds none.
    //
    // Every mutator takes the first id to stamp and **returns how many it
    // used**, and the counter is advanced by that return rather than by a
    // number predicted at the call site. That is deliberate:
    // `Screen.scrollUp`'s `n >= height` branch clears the whole region and so
    // stamps `height` rows, not `n`, and a call site that guessed `n` would
    // hand two rows the same id -- invisible until a selection anchored to
    // one of them resolved onto the other.
    //
    // **The four wrappers below are `inline`, and that is load-bearing.**
    // `lineFeed` calls `scrollUp` with a literal `n = 1`, and LLVM specializes
    // the whole of `Screen.scrollUp` on it -- the `n >= height` branch folds
    // away and the clear becomes a single row. Behind an ordinary function
    // `n` is a runtime parameter and all of that is lost: measured, these
    // four one-line wrappers cost **26% of `ascii` and 36% of `scroll`**
    // before the `inline` went on. Nothing about the ids was responsible; the
    // benchmark found it and the profile did not, which is why the rule is to
    // measure before and after.

    /// Reserve `n` ids and return the first.
    fn mint(self: *Terminal, n: usize) u64 {
        const first = self.next_line_id;
        self.next_line_id += n;
        return first;
    }

    inline fn scrollScreenUp(self: *Terminal, top: usize, bot: usize, n: usize) void {
        const first = self.next_line_id;
        self.next_line_id += self.screen().scrollUp(top, bot, n, self.blankCell(), first);
    }

    inline fn scrollScreenDown(self: *Terminal, top: usize, bot: usize, n: usize) void {
        const first = self.next_line_id;
        self.next_line_id += self.screen().scrollDown(top, bot, n, self.blankCell(), first);
    }

    inline fn clearScreenRows(self: *Terminal, top: usize, bot: usize) void {
        const first = self.next_line_id;
        self.next_line_id += self.screen().clearRows(top, bot, self.blankCell(), first);
    }

    inline fn fillScreen(self: *Terminal, s: *Screen, cell: Cell) void {
        const first = self.next_line_id;
        self.next_line_id += s.fill(cell, first);
    }

    /// The row the cursor is on, as the selection and reflow see it.
    fn cursorMeta(self: *Terminal) *grid.RowMeta {
        return self.screen().rowMeta(self.cursor.y);
    }

    // -- geometry -----------------------------------------------------------

    pub fn resize(self: *Terminal, cols: usize, rows: usize) !void {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        if (c == self.cols and r == self.rows) return;

        // Reflow is a genuinely hard problem (it interacts with wrapped-line
        // tracking and scrollback rewriting). For now we preserve content by
        // top-left anchoring, which is what most terminals did for years.
        var new_primary = try Screen.init(self.alloc, c, r, self.mint(r));
        var new_alt = try Screen.init(self.alloc, c, r, self.mint(r));
        const copy_rows = @min(r, self.rows);
        const copy_cols = @min(c, self.cols);
        for (0..copy_rows) |y| {
            @memcpy(new_primary.row(y)[0..copy_cols], self.primary.row(y)[0..copy_cols]);
            @memcpy(new_alt.row(y)[0..copy_cols], self.alt.row(y)[0..copy_cols]);
            // A row that survives the resize keeps its identity, so a
            // selection survives a height change. The fresh ids stamped by
            // `Screen.init` stand for the rows that did not survive.
            new_primary.rowMeta(y).* = self.primary.rowMeta(y).*;
            new_alt.rowMeta(y).* = self.alt.rowMeta(y).*;
        }
        self.primary.deinit(self.alloc);
        self.alt.deinit(self.alloc);
        self.primary = new_primary;
        self.alt = new_alt;

        if (c != self.cols) {
            const sb = try grid.Scrollback.init(self.alloc, c, scrollback_lines);
            self.scrollback.deinit(self.alloc);
            self.scrollback = sb;
            self.alloc.free(self.tabstops);
            self.tabstops = try self.alloc.alloc(bool, c);
            // The history the selection may have been anchored in has just
            // been thrown away, and every surviving row has been truncated
            // to a new width -- so the columns the selection named no longer
            // mean what they meant. Reflow (E4) is what makes this
            // survivable; until then, clearing is the honest answer.
            self.selection = null;
        }

        self.cols = c;
        self.rows = r;
        self.resetTabstops();
        self.scroll_top = 0;
        self.scroll_bot = r - 1;
        self.cursor.x = @min(self.cursor.x, c - 1);
        self.cursor.y = @min(self.cursor.y, r - 1);
        self.pending_wrap = false;
        self.view_offset = 0;
        self.dirty = true;
    }

    // -- parser handler interface -------------------------------------------

    pub fn print(self: *Terminal, cp: u21) void {
        const w = charWidth(cp);
        if (w == 0) return; // combining marks aren't attached to a base yet

        if (self.pending_wrap and self.modes.wrap) {
            self.cursor.x = 0;
            self.wrapLineFeed();
        }
        self.pending_wrap = false;

        if (self.cursor.x + w > self.cols) {
            if (!self.modes.wrap) {
                self.cursor.x = self.cols - w;
            } else {
                // A wide character that does not fit in the last column
                // wraps too, and the row it leaves is just as wrapped as one
                // that ran off the margin a character at a time.
                self.cursor.x = 0;
                self.wrapLineFeed();
            }
        }

        const s = self.screen();
        const cell = Cell{
            .cp = cp,
            .fg = self.cursor.fg,
            .bg = self.cursor.bg,
            .attrs = self.cursor.attrs,
            .wide = if (w == 2) .wide else .narrow,
        };
        s.at(self.cursor.x, self.cursor.y).* = cell;
        if (w == 2 and self.cursor.x + 1 < self.cols) {
            s.at(self.cursor.x + 1, self.cursor.y).* = .{
                .cp = ' ',
                .fg = self.cursor.fg,
                .bg = self.cursor.bg,
                .attrs = self.cursor.attrs,
                .wide = .spacer,
            };
        }

        self.cursor.x += w;
        if (self.cursor.x >= self.cols) {
            self.cursor.x = self.cols - 1;
            self.pending_wrap = true;
        }
        self.markDirty();
    }

    /// A run of printable ASCII, every byte one cell wide. Must leave the
    /// terminal in exactly the state `print` called once per byte would --
    /// the parser hands over whatever run a read boundary happened to
    /// produce, so the split point is arbitrary and must not show.
    ///
    /// The saving is per row segment rather than per character: one wrap
    /// check, one row lookup, one cell template, then a straight fill.
    pub fn printRun(self: *Terminal, run: []const u8) void {
        if (!self.modes.wrap) {
            // With DECAWM off every byte past the margin overprints the last
            // column. Rare, and `print` already gets it right.
            for (run) |b| self.print(b);
            return;
        }

        var rest = run;
        while (rest.len > 0) {
            if (self.pending_wrap) {
                self.cursor.x = 0;
                self.wrapLineFeed();
            }
            const row = self.screen().row(self.cursor.y);
            const n = @min(self.cols - self.cursor.x, rest.len);
            var cell = Cell{
                .fg = self.cursor.fg,
                .bg = self.cursor.bg,
                .attrs = self.cursor.attrs,
            };
            for (row[self.cursor.x..][0..n], rest[0..n]) |*dst, b| {
                cell.cp = b;
                dst.* = cell;
            }
            rest = rest[n..];
            self.cursor.x += n;
            if (self.cursor.x >= self.cols) {
                self.cursor.x = self.cols - 1;
                self.pending_wrap = true;
            }
        }
        self.markDirty();
    }

    pub fn execute(self: *Terminal, b: u8) void {
        switch (b) {
            0x07 => self.bell = true,
            0x08 => { // BS
                if (self.pending_wrap) {
                    self.pending_wrap = false;
                } else if (self.cursor.x > 0) {
                    self.cursor.x -= 1;
                }
                self.markDirty();
            },
            0x09 => self.tabForward(1), // HT
            0x0a, 0x0b, 0x0c => { // LF, VT, FF
                // An explicit line feed ends the line, so whatever wrapped
                // the row before is no longer true of it. Clearing here and
                // not in `lineFeed` is the point: `lineFeed` is also how a
                // *wrap* moves to the next row, and clearing there would
                // undo the flag `wrapLineFeed` had just set.
                self.endLine();
                self.lineFeed();
                self.markDirty();
            },
            0x0d => { // CR
                // Deliberately does *not* clear `wrapped`: a carriage return
                // moves within the line, it does not end it. `printf 'a\rb'`
                // on a wrapped row must still join to the row below.
                self.cursor.x = 0;
                self.pending_wrap = false;
                self.markDirty();
            },
            else => {},
        }
    }

    pub fn escDispatch(self: *Terminal, intermediates: []const u8, final: u8) void {
        // Charset designators (ESC ( B and friends) -- we're UTF-8 only.
        if (intermediates.len > 0) return;
        switch (final) {
            'D' => { // IND
                self.endLine();
                self.lineFeed();
            },
            'E' => { // NEL
                self.endLine();
                self.cursor.x = 0;
                self.lineFeed();
            },
            'M' => self.reverseIndex(), // RI
            'H' => if (self.cursor.x < self.cols) { // HTS
                self.tabstops[self.cursor.x] = true;
            },
            '7' => self.saved_cursor = self.cursor, // DECSC
            '8' => { // DECRC
                self.cursor = self.saved_cursor;
                self.clampCursor();
            },
            '=' => self.modes.app_keypad = true,
            '>' => self.modes.app_keypad = false,
            'c' => self.fullReset(), // RIS
            else => {},
        }
        self.markDirty();
    }

    pub fn oscDispatch(self: *Terminal, data: []const u8) void {
        // OSC 0 (icon + title), 1 (icon), 2 (title): "N;text"
        const semi = std.mem.indexOfScalar(u8, data, ';') orelse return;
        const code = std.fmt.parseInt(u16, data[0..semi], 10) catch return;
        const text = data[semi + 1 ..];
        switch (code) {
            0, 2 => {
                self.title.clearRetainingCapacity();
                self.title.appendSlice(self.alloc, text) catch {};
            },
            else => {},
        }
    }

    pub fn csiDispatch(self: *Terminal, csi: vt.Csi) void {
        defer self.markDirty();
        // Intermediates mean a sequence we don't implement (DECSCUSR is the
        // notable one, via ' q'); ignoring is the correct fallback.
        switch (csi.final) {
            'A' => self.moveUp(csi.get(0, 1)),
            'B' => self.moveDown(csi.get(0, 1)),
            'C' => self.moveRight(csi.get(0, 1)),
            'D' => self.moveLeft(csi.get(0, 1)),
            'E' => { // CNL
                self.cursor.x = 0;
                self.moveDown(csi.get(0, 1));
            },
            'F' => { // CPL
                self.cursor.x = 0;
                self.moveUp(csi.get(0, 1));
            },
            'G', '`' => self.setCol(csi.get(0, 1) - 1), // CHA / HPA
            'd' => self.setRow(csi.get(0, 1) - 1), // VPA
            'H', 'f' => { // CUP / HVP
                self.setRow(csi.get(0, 1) - 1);
                self.setCol(csi.get(1, 1) - 1);
            },
            'I' => self.tabForward(csi.get(0, 1)), // CHT
            'Z' => self.tabBackward(csi.get(0, 1)), // CBT
            'J' => self.eraseDisplay(csi.raw(0, 0)),
            'K' => self.eraseLine(csi.raw(0, 0)),
            'L' => self.insertLines(csi.get(0, 1)),
            'M' => self.deleteLines(csi.get(0, 1)),
            'P' => { // DCH
                // Shifting left always blanks the tail, so the character at
                // the margin is gone and this row no longer runs into the
                // next. `ICH` below is the opposite case and stays.
                self.endLine();
                self.screen().deleteCells(self.cursor.x, self.cursor.y, csi.get(0, 1), self.blankCell());
            },
            '@' => { // ICH
                self.screen().insertCells(self.cursor.x, self.cursor.y, csi.get(0, 1), self.blankCell());
            },
            'X' => self.eraseChars(csi.get(0, 1)), // ECH
            'S' => self.scrollScreenUp(self.scroll_top, self.scroll_bot, csi.get(0, 1)),
            'T' => self.scrollScreenDown(self.scroll_top, self.scroll_bot, csi.get(0, 1)),
            'm' => self.selectGraphicRendition(csi),
            'r' => self.setScrollRegion(csi),
            'h' => self.setMode(csi, true),
            'l' => self.setMode(csi, false),
            'n' => self.deviceStatusReport(csi),
            'c' => self.deviceAttributes(csi),
            's' => self.saved_cursor = self.cursor,
            'u' => {
                self.cursor = self.saved_cursor;
                self.clampCursor();
            },
            'g' => self.clearTabstops(csi.raw(0, 0)), // TBC
            else => {},
        }
    }

    // -- cursor -------------------------------------------------------------

    fn clampCursor(self: *Terminal) void {
        self.cursor.x = @min(self.cursor.x, self.cols - 1);
        self.cursor.y = @min(self.cursor.y, self.rows - 1);
    }

    fn moveUp(self: *Terminal, n: u16) void {
        // Movement stops at the scroll region edge when the cursor is inside it.
        const limit = if (self.cursor.y >= self.scroll_top) self.scroll_top else 0;
        self.cursor.y -= @min(self.cursor.y - limit, n);
        self.pending_wrap = false;
    }

    fn moveDown(self: *Terminal, n: u16) void {
        const limit = if (self.cursor.y <= self.scroll_bot) self.scroll_bot else self.rows - 1;
        self.cursor.y += @min(limit - self.cursor.y, n);
        self.pending_wrap = false;
    }

    fn moveLeft(self: *Terminal, n: u16) void {
        self.cursor.x -= @min(self.cursor.x, n);
        self.pending_wrap = false;
    }

    fn moveRight(self: *Terminal, n: u16) void {
        self.cursor.x += @min(self.cols - 1 - self.cursor.x, n);
        self.pending_wrap = false;
    }

    fn setCol(self: *Terminal, x: usize) void {
        self.cursor.x = @min(x, self.cols - 1);
        self.pending_wrap = false;
    }

    fn setRow(self: *Terminal, y: usize) void {
        // Origin mode makes row 1 mean the top of the scroll region.
        const target = if (self.modes.origin) self.scroll_top + y else y;
        const limit = if (self.modes.origin) self.scroll_bot else self.rows - 1;
        self.cursor.y = @min(target, limit);
        self.pending_wrap = false;
    }

    fn lineFeed(self: *Terminal) void {
        if (self.cursor.y == self.scroll_bot) {
            // Only the primary screen has history; the alt screen is for
            // full-screen apps, which manage their own repaint. The row's
            // metadata goes with its cells, or a selection anchored to a line
            // stops resolving the instant that line scrolls off -- which is
            // the case E1 exists for.
            if (!self.on_alt and self.scroll_top == 0) {
                self.scrollback.push(self.primary.row(0), self.primary.rowMeta(0).*);
            }
            self.scrollScreenUp(self.scroll_top, self.scroll_bot, 1);
        } else if (self.cursor.y + 1 < self.rows) {
            self.cursor.y += 1;
        }
        self.pending_wrap = false;
    }

    /// The line feed a *wrap* performs: the row being left behind ends
    /// because the text ran off the right margin, so it is marked before it
    /// is left. Marking it after would mark the row arriving underneath --
    /// and on a full screen `lineFeed` scrolls, so "the current row" is not
    /// even the same row on the way out.
    fn wrapLineFeed(self: *Terminal) void {
        self.cursorMeta().flags.wrapped = true;
        self.lineFeed();
    }

    /// This row ends here, whatever put the cursor on it.
    ///
    /// `wrapped` means one thing: *the character at the right margin ran on
    /// into the row below*. So the rule is the cell at the right margin, and
    /// nothing wider: `LF`, `IND` and `NEL` end the line outright, `EL 0`,
    /// `EL 2`, `ED 0` and `ED 2` blank the margin, `ECH` ends it only when it
    /// reaches the margin, and `DCH` always does because shifting left blanks
    /// the tail. `EL 1`, `ED 1` and `CR` leave the margin alone and so leave
    /// the flag alone.
    ///
    /// `ICH` is the one deliberate exception: it shifts text *into* the
    /// margin rather than blanking it, so the row still runs to the edge. A
    /// shell editing a long wrapped command line inserts and then reprints the
    /// remainder, and clearing the flag under it would split one logical line
    /// in two for triple-click, copy and E4's reflow.
    fn endLine(self: *Terminal) void {
        self.cursorMeta().flags.wrapped = false;
    }

    fn reverseIndex(self: *Terminal) void {
        if (self.cursor.y == self.scroll_top) {
            self.scrollScreenDown(self.scroll_top, self.scroll_bot, 1);
        } else if (self.cursor.y > 0) {
            self.cursor.y -= 1;
        }
        self.pending_wrap = false;
    }

    // -- tabs ---------------------------------------------------------------

    fn tabForward(self: *Terminal, n: u16) void {
        var count = n;
        while (count > 0) : (count -= 1) {
            var x = self.cursor.x + 1;
            while (x < self.cols and !self.tabstops[x]) x += 1;
            self.cursor.x = @min(x, self.cols - 1);
        }
        self.pending_wrap = false;
        self.markDirty();
    }

    fn tabBackward(self: *Terminal, n: u16) void {
        var count = n;
        while (count > 0) : (count -= 1) {
            if (self.cursor.x == 0) break;
            var x = self.cursor.x - 1;
            while (x > 0 and !self.tabstops[x]) x -= 1;
            self.cursor.x = x;
        }
        self.pending_wrap = false;
    }

    fn clearTabstops(self: *Terminal, mode: u16) void {
        switch (mode) {
            0 => if (self.cursor.x < self.cols) {
                self.tabstops[self.cursor.x] = false;
            },
            3 => @memset(self.tabstops, false),
            else => {},
        }
    }

    // -- erase --------------------------------------------------------------

    fn eraseDisplay(self: *Terminal, mode: u16) void {
        const blank = self.blankCell();
        switch (mode) {
            0 => { // cursor to end
                // The tail of this row is gone, so it no longer runs into the
                // row below; the rows below are new lines outright.
                self.endLine();
                @memset(self.screen().row(self.cursor.y)[self.cursor.x..], blank);
                if (self.cursor.y + 1 < self.rows) self.clearScreenRows(self.cursor.y + 1, self.rows - 1);
            },
            1 => { // start to cursor
                // The *tail* survives, so this row's wrap into the next is
                // still true and the flag stays. Same reasoning as EL 1.
                if (self.cursor.y > 0) self.clearScreenRows(0, self.cursor.y - 1);
                @memset(self.screen().row(self.cursor.y)[0 .. self.cursor.x + 1], blank);
            },
            2 => self.fillScreen(self.screen(), blank),
            3 => { // xterm: also clear scrollback
                self.fillScreen(self.screen(), blank);
                self.scrollback.clear();
                self.view_offset = 0;
                // Every line the selection could have been anchored to is
                // gone, including the history half of one that spanned the
                // boundary.
                self.selection = null;
            },
            else => {},
        }
    }

    fn eraseLine(self: *Terminal, mode: u16) void {
        const r = self.screen().row(self.cursor.y);
        const blank = self.blankCell();
        switch (mode) {
            // 0 and 2 blank the row's tail, so whatever ran off the right
            // margin is not there any more and the row no longer joins the
            // one below it. 1 erases only up to the cursor and leaves the
            // tail -- and the wrap -- intact.
            0 => {
                self.endLine();
                @memset(r[self.cursor.x..], blank);
            },
            1 => @memset(r[0 .. self.cursor.x + 1], blank),
            2 => {
                self.endLine();
                @memset(r, blank);
            },
            else => {},
        }
    }

    fn eraseChars(self: *Terminal, n: u16) void {
        const r = self.screen().row(self.cursor.y);
        const end = @min(self.cursor.x + n, self.cols);
        // Only when it reaches the margin: an ECH in the middle of a row
        // leaves the character that wrapped exactly where it was.
        if (end >= self.cols) self.endLine();
        @memset(r[self.cursor.x..end], self.blankCell());
    }

    fn insertLines(self: *Terminal, n: u16) void {
        if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bot) return;
        self.scrollScreenDown(self.cursor.y, self.scroll_bot, n);
    }

    fn deleteLines(self: *Terminal, n: u16) void {
        if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bot) return;
        self.scrollScreenUp(self.cursor.y, self.scroll_bot, n);
    }

    fn setScrollRegion(self: *Terminal, csi: vt.Csi) void {
        const top = csi.get(0, 1) - 1;
        const bot = csi.get(1, @intCast(self.rows)) - 1;
        if (top >= bot or bot >= self.rows) return;
        self.scroll_top = top;
        self.scroll_bot = bot;
        // DECSTBM homes the cursor.
        self.cursor.x = 0;
        self.cursor.y = if (self.modes.origin) self.scroll_top else 0;
        self.pending_wrap = false;
    }

    // -- styling ------------------------------------------------------------

    fn selectGraphicRendition(self: *Terminal, csi: vt.Csi) void {
        const params = csi.params;
        if (params.len == 0) {
            self.cursor.fg = .default;
            self.cursor.bg = .default;
            self.cursor.attrs = .{};
            return;
        }
        var i: usize = 0;
        while (i < params.len) : (i += 1) {
            switch (params[i]) {
                0 => {
                    self.cursor.fg = .default;
                    self.cursor.bg = .default;
                    self.cursor.attrs = .{};
                },
                1 => self.cursor.attrs.bold = true,
                2 => self.cursor.attrs.dim = true,
                3 => self.cursor.attrs.italic = true,
                4 => self.cursor.attrs.underline = true,
                5, 6 => self.cursor.attrs.blink = true,
                7 => self.cursor.attrs.reverse = true,
                8 => self.cursor.attrs.hidden = true,
                9 => self.cursor.attrs.strike = true,
                21, 22 => {
                    self.cursor.attrs.bold = false;
                    self.cursor.attrs.dim = false;
                },
                23 => self.cursor.attrs.italic = false,
                24 => self.cursor.attrs.underline = false,
                25 => self.cursor.attrs.blink = false,
                27 => self.cursor.attrs.reverse = false,
                28 => self.cursor.attrs.hidden = false,
                29 => self.cursor.attrs.strike = false,
                30...37 => self.cursor.fg = .{ .indexed = @intCast(params[i] - 30) },
                38 => self.cursor.fg = parseExtendedColor(csi, &i) orelse self.cursor.fg,
                39 => self.cursor.fg = .default,
                40...47 => self.cursor.bg = .{ .indexed = @intCast(params[i] - 40) },
                48 => self.cursor.bg = parseExtendedColor(csi, &i) orelse self.cursor.bg,
                49 => self.cursor.bg = .default,
                90...97 => self.cursor.fg = .{ .indexed = @intCast(params[i] - 90 + 8) },
                100...107 => self.cursor.bg = .{ .indexed = @intCast(params[i] - 100 + 8) },
                else => {},
            }
        }
    }

    /// Extended color after SGR 38/48. Two forms are in the wild:
    ///
    ///   38;5;N            palette index
    ///   38;2;R;G;B        truecolor, legacy xterm form
    ///   38:2:CS:R:G:B     truecolor, ITU T.416 form -- note the colorspace
    ///                     field, which the legacy form does not have
    ///
    /// Telling them apart needs the separator, which is why the parser keeps
    /// track of it. Advances `i` past the arguments consumed.
    fn parseExtendedColor(csi: vt.Csi, i: *usize) ?Color {
        const params = csi.params;
        if (i.* + 1 >= params.len) return null;
        switch (params[i.* + 1]) {
            5 => {
                if (i.* + 2 >= params.len) return null;
                i.* += 2;
                return .{ .indexed = @truncate(params[i.*]) };
            },
            2 => {
                // The colon form interposes a colorspace id we ignore.
                const off: usize = if (csi.isSub(i.* + 1)) 3 else 2;
                if (i.* + off + 2 >= params.len) return null;
                const r: u8 = @truncate(params[i.* + off]);
                const g: u8 = @truncate(params[i.* + off + 1]);
                const b: u8 = @truncate(params[i.* + off + 2]);
                i.* += off + 2;
                return .{ .rgb = .{ .r = r, .g = g, .b = b } };
            },
            else => return null,
        }
    }

    // -- modes and reports --------------------------------------------------

    fn setMode(self: *Terminal, csi: vt.Csi, on: bool) void {
        if (csi.private != '?') {
            for (csi.params) |p| switch (p) {
                4 => {}, // IRM insert mode: not implemented
                else => {},
            };
            return;
        }
        for (csi.params) |p| switch (p) {
            1 => self.modes.app_cursor = on,
            6 => { // DECOM
                self.modes.origin = on;
                self.cursor.x = 0;
                self.cursor.y = if (on) self.scroll_top else 0;
            },
            7 => self.modes.wrap = on,
            25 => self.modes.cursor_visible = on,
            // Tracking modes and encodings are different questions. 1006
            // and 1015 only say how an event is spelled on the wire.
            1000, 1002, 1003 => self.modes.mouse = on,
            1006, 1015 => self.modes.mouse_sgr = on,
            47, 1047, 1049 => self.setAltScreen(on, p == 1049),
            2004 => self.modes.bracketed_paste = on,
            else => {},
        };
    }

    fn setAltScreen(self: *Terminal, on: bool, save_cursor: bool) void {
        if (on == self.on_alt) return;
        // The alt screen is a different set of lines, and the primary
        // underneath is about to be hidden or revealed wholesale. Keeping the
        // selection across the switch would leave a highlight over text that
        // is no longer the text it was taken from.
        self.selection = null;
        if (on) {
            if (save_cursor) self.saved_cursor = self.cursor;
            self.fillScreen(&self.alt, .blank);
            self.on_alt = true;
            self.cursor.x = 0;
            self.cursor.y = 0;
        } else {
            self.on_alt = false;
            if (save_cursor) {
                self.cursor = self.saved_cursor;
                self.clampCursor();
            }
        }
        self.view_offset = 0;
        self.pending_wrap = false;
    }

    fn deviceStatusReport(self: *Terminal, csi: vt.Csi) void {
        switch (csi.raw(0, 0)) {
            5 => self.reply("\x1b[0n"), // "I'm fine"
            6 => { // CPR -- cursor position
                var buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    self.cursor.y + 1,
                    self.cursor.x + 1,
                }) catch return;
                self.reply(s);
            },
            else => {},
        }
    }

    fn deviceAttributes(self: *Terminal, csi: vt.Csi) void {
        if (csi.private != 0) return;
        // "VT220 with 132 columns, selective erase, ANSI color" -- the answer
        // ncurses and friends expect from a modern terminal.
        self.reply("\x1b[?62;1;6;22c");
    }

    fn reply(self: *Terminal, bytes: []const u8) void {
        self.replies.appendSlice(self.alloc, bytes) catch {};
    }

    pub fn fullReset(self: *Terminal) void {
        // `next_line_id` is deliberately *not* reset. Ids have to stay
        // globally disjoint for the life of the terminal, or a stale anchor
        // taken before the reset resolves onto a live row after it.
        self.fillScreen(&self.primary, .blank);
        self.fillScreen(&self.alt, .blank);
        self.scrollback.clear();
        self.selection = null;
        self.cursor = .{};
        self.saved_cursor = .{};
        self.modes = .{};
        self.on_alt = false;
        self.scroll_top = 0;
        self.scroll_bot = self.rows - 1;
        self.pending_wrap = false;
        self.view_offset = 0;
        self.resetTabstops();
        self.dirty = true;
    }

    // -- viewport -----------------------------------------------------------

    /// Scroll the viewport back through history. Positive scrolls toward the
    /// past. No-op on the alt screen, where there is no history to see.
    pub fn scrollView(self: *Terminal, delta: isize) void {
        if (self.on_alt) return;
        const max_back = self.scrollback.len;
        const cur: isize = @intCast(self.view_offset);
        const want = std.math.clamp(cur + delta, 0, @as(isize, @intCast(max_back)));
        const new: usize = @intCast(want);
        if (new != self.view_offset) {
            self.view_offset = new;
            self.dirty = true;
        }
    }

    fn markDirty(self: *Terminal) void {
        self.dirty = true;
        // Any new output snaps the viewport back to the live screen, which is
        // what you want when you're scrolled up and then hit Enter.
        if (self.view_offset != 0) self.view_offset = 0;
    }

    /// The cells visible at viewport row `y`, reading from scrollback when the
    /// view is scrolled back past the top of the live screen.
    pub fn viewRow(self: *Terminal, y: usize) []const Cell {
        if (self.view_offset == 0 or self.on_alt) return self.screen().row(y);
        if (y < self.view_offset) {
            // Rows above the live screen come from history, newest last.
            const back_index = self.view_offset - y - 1;
            if (self.scrollback.back(back_index)) |hist| return hist;
            return self.screen().row(0);
        }
        return self.screen().row(y - self.view_offset);
    }

    /// The metadata of the row `viewRow(y)` returns. Same branch, same
    /// fallback: the two must never disagree about which line row `y` is, or
    /// the highlight lands on a different row than the text it copies.
    pub fn viewRowMeta(self: *Terminal, y: usize) grid.RowMeta {
        if (self.view_offset == 0 or self.on_alt) return self.screen().rowMeta(y).*;
        if (y < self.view_offset) {
            const back_index = self.view_offset - y - 1;
            if (self.scrollback.backMeta(back_index)) |m| return m;
            return self.screen().rowMeta(0).*;
        }
        return self.screen().rowMeta(y - self.view_offset).*;
    }

    // -- selection ----------------------------------------------------------
    //
    // The model is in `src/sel.zig`, which imports nothing but `std`, `grid`
    // and this file, so all of it is unit-tested. What lives here is the one
    // field and the two calls that move it.

    /// Replace the selection, normalized against the grid as it is now.
    ///
    /// Normalizing at set time rather than in the extractor is what keeps the
    /// highlight and the copied text describing the same cells: wide-character
    /// snapping and word/line expansion happen once, here, and everything
    /// downstream reads the same endpoints.
    ///
    /// A selection whose endpoints no longer resolve -- both evicted from
    /// scrollback, or taken on a screen that is no longer showing -- becomes
    /// null rather than a range pointing at nothing.
    pub fn setSelection(self: *Terminal, s: ?sel.Selection) void {
        const next = if (s) |v| sel.normalize(self, v) else null;
        const changed = (next == null) != (self.selection == null) or
            (next != null and !std.meta.eql(next.?, self.selection.?));
        self.selection = next;
        if (changed) self.dirty = true;
    }

    pub fn clearSelection(self: *Terminal) void {
        if (self.selection == null) return;
        self.selection = null;
        self.dirty = true;
    }
};

/// Display width of a codepoint, in cells. A pragmatic wcwidth: zero for
/// combining marks and controls, two for the CJK and emoji blocks, one
/// otherwise. Good enough that box-drawing, CJK and emoji line up.
pub fn charWidth(cp: u21) u8 {
    if (cp < 0x20) return 0;
    if (cp >= 0x7f and cp < 0xa0) return 0;
    // Nothing below U+0300 is combining or wide, and that covers all of
    // Latin, so most text skips the range tables entirely.
    if (cp < 0x300) return 1;
    if (isCombining(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

fn inAny(cp: u21, comptime ranges: []const [2]u21) bool {
    for (ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

fn isCombining(cp: u21) bool {
    return inAny(cp, &.{
        .{ 0x0300, 0x036f },   .{ 0x0483, 0x0489 }, .{ 0x0591, 0x05bd },
        .{ 0x0610, 0x061a },   .{ 0x064b, 0x065f }, .{ 0x0670, 0x0670 },
        .{ 0x1ab0, 0x1aff },   .{ 0x1dc0, 0x1dff }, .{ 0x200b, 0x200f },
        .{ 0x20d0, 0x20f0 },   .{ 0xfe00, 0xfe0f }, .{ 0xfe20, 0xfe2f },
        .{ 0xe0100, 0xe01ef },
    });
}

fn isWide(cp: u21) bool {
    return inAny(cp, &.{
        .{ 0x1100, 0x115f },   .{ 0x2e80, 0x303e },   .{ 0x3041, 0x33ff },
        .{ 0x3400, 0x4dbf },   .{ 0x4e00, 0x9fff },   .{ 0xa000, 0xa4cf },
        .{ 0xac00, 0xd7a3 },   .{ 0xf900, 0xfaff },   .{ 0xfe10, 0xfe19 },
        .{ 0xfe30, 0xfe6f },   .{ 0xff00, 0xff60 },   .{ 0xffe0, 0xffe6 },
        .{ 0x1f300, 0x1f64f }, .{ 0x1f900, 0x1f9ff }, .{ 0x20000, 0x2fffd },
        .{ 0x30000, 0x3fffd },
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Drive a terminal with raw bytes, exactly as the PTY would.
fn feed(t: *Terminal, bytes: []const u8) void {
    var p = vt.Parser{};
    p.feed(t, bytes);
}

fn line(t: *Terminal, y: usize, buf: []u8) []const u8 {
    var n: usize = 0;
    for (t.screen().row(y)) |c| {
        n += std.unicode.utf8Encode(c.cp, buf[n..]) catch 0;
    }
    return std.mem.trimEnd(u8, buf[0..n], " ");
}

fn mkTerm(cols: usize, rows: usize) !Terminal {
    return Terminal.init(testing.allocator, cols, rows);
}

test "printing and wrapping at the right margin" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcdef");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abcd", line(&t, 0, &buf));
    try testing.expectEqualStrings("ef", line(&t, 1, &buf));
}

test "printing exactly cols characters does not wrap early" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcd");
    // The cursor parks on the last column with a wrap pending, so the line
    // below must still be empty.
    try testing.expect(t.pending_wrap);
    try testing.expectEqual(@as(usize, 0), t.cursor.y);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", line(&t, 1, &buf));
}

test "cursor addressing is 1-based" {
    var t = try mkTerm(10, 5);
    defer t.deinit();
    feed(&t, "\x1b[3;5Hx");
    try testing.expectEqual(@as(usize, 2), t.cursor.y);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("    x", line(&t, 2, &buf));
}

test "scrolling off the bottom pushes lines into scrollback" {
    var t = try mkTerm(8, 2);
    defer t.deinit();
    feed(&t, "one\r\ntwo\r\nthree");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("two", line(&t, 0, &buf));
    try testing.expectEqualStrings("three", line(&t, 1, &buf));
    try testing.expectEqual(@as(usize, 1), t.scrollback.len);
    try testing.expectEqual(@as(u21, 'o'), t.scrollback.back(0).?[0].cp);
}

test "SGR sets colors and attributes, and 0 resets them" {
    var t = try mkTerm(10, 2);
    defer t.deinit();
    feed(&t, "\x1b[1;31mR\x1b[0mn");
    const red = t.screen().at(0, 0);
    try testing.expect(red.attrs.bold);
    try testing.expect(red.fg.eql(.{ .indexed = 1 }));
    const norm = t.screen().at(1, 0);
    try testing.expect(!norm.attrs.bold);
    try testing.expect(norm.fg.eql(.default));
}

test "SGR truecolor, both semicolon and colon forms" {
    var t = try mkTerm(10, 2);
    defer t.deinit();
    feed(&t, "\x1b[38;2;10;20;30mA\x1b[38:2::40:50:60mB");
    try testing.expect(t.screen().at(0, 0).fg.eql(.{ .rgb = .{ .r = 10, .g = 20, .b = 30 } }));
    try testing.expect(t.screen().at(1, 0).fg.eql(.{ .rgb = .{ .r = 40, .g = 50, .b = 60 } }));
}

test "erase in display, from cursor to end" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "aaaa\r\nbbbb\r\ncccc");
    feed(&t, "\x1b[2;3H\x1b[0J");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aaaa", line(&t, 0, &buf));
    try testing.expectEqualStrings("bb", line(&t, 1, &buf));
    try testing.expectEqualStrings("", line(&t, 2, &buf));
}

test "scroll region confines scrolling" {
    var t = try mkTerm(4, 4);
    defer t.deinit();
    feed(&t, "aaaa\r\nbbbb\r\ncccc\r\ndddd");
    // Region is rows 2-3; put the cursor at its bottom and line-feed.
    feed(&t, "\x1b[2;3r\x1b[3;1H\n");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aaaa", line(&t, 0, &buf)); // untouched
    try testing.expectEqualStrings("cccc", line(&t, 1, &buf)); // scrolled up
    try testing.expectEqualStrings("", line(&t, 2, &buf)); // new blank line
    try testing.expectEqualStrings("dddd", line(&t, 3, &buf)); // untouched
}

test "alternate screen preserves the primary underneath" {
    var t = try mkTerm(8, 2);
    defer t.deinit();
    feed(&t, "primary");
    feed(&t, "\x1b[?1049h");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", line(&t, 0, &buf)); // alt starts blank
    feed(&t, "alt");
    try testing.expectEqualStrings("alt", line(&t, 0, &buf));
    feed(&t, "\x1b[?1049l");
    try testing.expectEqualStrings("primary", line(&t, 0, &buf));
}

test "cursor position report answers on the reply channel" {
    var t = try mkTerm(20, 10);
    defer t.deinit();
    feed(&t, "\x1b[5;7H\x1b[6n");
    try testing.expectEqualStrings("\x1b[5;7R", t.replies.items);
}

test "insert and delete lines respect the scroll region bottom" {
    var t = try mkTerm(4, 4);
    defer t.deinit();
    feed(&t, "aaaa\r\nbbbb\r\ncccc\r\ndddd");
    feed(&t, "\x1b[2;1H\x1b[1M"); // delete line 2
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("aaaa", line(&t, 0, &buf));
    try testing.expectEqualStrings("cccc", line(&t, 1, &buf));
    try testing.expectEqualStrings("dddd", line(&t, 2, &buf));
    try testing.expectEqualStrings("", line(&t, 3, &buf));
}

test "backspace, tab and carriage return" {
    var t = try mkTerm(20, 2);
    defer t.deinit();
    feed(&t, "ab\x08c"); // backspace overwrites 'b'
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ac", line(&t, 0, &buf));
    feed(&t, "\r\tx"); // CR home, then tab to column 8
    try testing.expectEqual(@as(usize, 9), t.cursor.x);
}

test "wide characters occupy two cells with a spacer" {
    var t = try mkTerm(6, 2);
    defer t.deinit();
    feed(&t, "\u{4e00}a"); // CJK ideograph then ASCII
    try testing.expectEqual(grid.Wide.wide, t.screen().at(0, 0).wide);
    try testing.expectEqual(grid.Wide.spacer, t.screen().at(1, 0).wide);
    try testing.expectEqual(@as(u21, 'a'), t.screen().at(2, 0).cp);
}

test "OSC 2 sets the window title" {
    var t = try mkTerm(10, 2);
    defer t.deinit();
    feed(&t, "\x1b]2;hello world\x07");
    try testing.expectEqualStrings("hello world", t.title.items);
}

// -- printable-run fast path -----------------------------------------------
//
// `Parser.feed` hands runs of printable ASCII to `printRun`; `Parser.advance`
// never does, so a terminal driven one byte at a time through `advance` is
// the per-character reference the fast path has to match exactly.

fn feedByteWise(t: *Terminal, bytes: []const u8) void {
    var p = vt.Parser{};
    for (bytes) |b| p.advance(t, b);
}

fn expectSameTerminal(a: *Terminal, b: *Terminal) !void {
    try testing.expectEqual(a.cursor, b.cursor);
    try testing.expectEqual(a.pending_wrap, b.pending_wrap);
    try testing.expectEqual(a.scrollback.len, b.scrollback.len);
    // Row metadata, not just cells. Both terminals started from a fresh
    // `Terminal.init`, so their id counters ran in lockstep and the ids
    // themselves are comparable -- which makes this differential test cover
    // `printRun`'s wrap site for free, both the flag it sets and the ids the
    // scrolls underneath it mint.
    try testing.expectEqual(a.next_line_id, b.next_line_id);
    for (0..a.rows) |y| {
        try testing.expectEqualSlices(Cell, a.screen().row(y), b.screen().row(y));
        try testing.expectEqual(a.screen().rowMeta(y).*, b.screen().rowMeta(y).*);
    }
    var i: usize = 0;
    while (a.scrollback.back(i)) |line_a| : (i += 1) {
        try testing.expectEqualSlices(Cell, line_a, b.scrollback.back(i).?);
        try testing.expectEqual(a.scrollback.backMeta(i).?, b.scrollback.backMeta(i).?);
    }
}

test "a printable run matches print called once per byte" {
    const inputs = [_][]const u8{
        "abcdefghijkl", // wraps twice and scrolls
        "abcd", // exactly the width: wrap must stay pending
        "abcd\r\nef", // pending wrap cancelled by CR
        "abcdefgh\x1b[1;31mijklmnop\x1b[0mq", // SGR change mid-run
        "\x1b[2;3r\x1b[3;1Habcdefghijklmnop", // scroll region, run scrolls it
        "\x1b[?7labcdefghij", // DECAWM off: overprint the last column
        "ab\x1b[2Ccd\x1b[3;2Hxyz", // cursor movement between runs
    };
    for (inputs) |input| {
        var fast = try mkTerm(4, 3);
        defer fast.deinit();
        var slow = try mkTerm(4, 3);
        defer slow.deinit();
        feed(&fast, input);
        feedByteWise(&slow, input);
        try expectSameTerminal(&fast, &slow);
    }
}

test "a printable run split across feed calls behaves like one run" {
    const text = "the quick brown fox jumps over the lazy dog";
    var whole = try mkTerm(7, 4);
    defer whole.deinit();
    feed(&whole, text);

    // Every split point, so the wrap and the pending-wrap column are both
    // hit by a boundary at some point.
    for (1..text.len) |cut| {
        var split = try mkTerm(7, 4);
        defer split.deinit();
        var p = vt.Parser{};
        p.feed(&split, text[0..cut]);
        p.feed(&split, text[cut..]);
        try expectSameTerminal(&whole, &split);
    }
}

test "a long printable run wraps and scrolls" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcdefghijklmnop");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ijkl", line(&t, 1, &buf));
    try testing.expectEqualStrings("mnop", line(&t, 2, &buf));
    try testing.expect(t.pending_wrap);
    try testing.expectEqual(@as(usize, 3), t.cursor.x);
    try testing.expectEqual(@as(usize, 2), t.cursor.y);
    try testing.expectEqual(@as(usize, 1), t.scrollback.len);
}

test "a printable run carries the cursor's colours and attributes" {
    var t = try mkTerm(8, 2);
    defer t.deinit();
    feed(&t, "\x1b[4;32mrun");
    for (0..3) |x| {
        const cell = t.screen().at(x, 0);
        try testing.expect(cell.attrs.underline);
        try testing.expect(cell.fg.eql(.{ .indexed = 2 }));
    }
    try testing.expect(!t.screen().at(3, 0).attrs.underline);
}

test "a printable run marks the terminal dirty and snaps the view back" {
    var t = try mkTerm(4, 2);
    defer t.deinit();
    feed(&t, "a\r\nb\r\nc\r\nd"); // two lines into scrollback
    t.scrollView(2);
    try testing.expectEqual(@as(usize, 2), t.view_offset);
    t.dirty = false;

    feed(&t, "run");
    // New output while scrolled back returns you to the live screen, the
    // same as a single printed character does.
    try testing.expect(t.dirty);
    try testing.expectEqual(@as(usize, 0), t.view_offset);
}

test "a printable run with wrap off overprints the last column" {
    var t = try mkTerm(4, 2);
    defer t.deinit();
    feed(&t, "\x1b[?7labcdefgh");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abch", line(&t, 0, &buf));
    try testing.expectEqualStrings("", line(&t, 1, &buf));
}

test "reverse index scrolls down at the top of the region" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "aaaa\r\nbbbb\r\ncccc");
    feed(&t, "\x1b[1;1H\x1bM");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", line(&t, 0, &buf));
    try testing.expectEqualStrings("aaaa", line(&t, 1, &buf));
}

// -- the wrapped flag ------------------------------------------------------
//
// E1's first shared primitive. Selection joins wrapped rows without a
// separator (E1), reflow re-wraps by it (E4) and path detection spans it
// (A4), so what sets and clears it is worth its own table rather than being
// covered incidentally by a selection test.

fn wrapped(t: *Terminal, y: usize) bool {
    return t.screen().rowMeta(y).flags.wrapped;
}

test "wrapping at the right margin marks the row that was left, not the one arrived at" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcdef");
    // Row 0 ran off the margin into row 1. Row 1 has not, yet.
    try testing.expect(wrapped(&t, 0));
    try testing.expect(!wrapped(&t, 1));
}

test "a wide character that will not fit in the last column wraps the row too" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    // Three narrow characters then a wide one: it cannot start in column 3,
    // so it wraps -- through the second of `print`'s two wrap sites.
    feed(&t, "abc\u{4e00}");
    try testing.expect(wrapped(&t, 0));
    try testing.expectEqual(grid.Wide.wide, t.screen().at(0, 1).wide);
}

test "a printable run wraps rows the same way one character at a time does" {
    // `printRun` has its own wrap site, and it is the one nearly every byte
    // of real output goes through. The differential test above compares the
    // two paths' metadata, so this only has to state the expected answer.
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcdefghij");
    try testing.expect(wrapped(&t, 0));
    try testing.expect(wrapped(&t, 1));
    try testing.expect(!wrapped(&t, 2));
}

test "a line feed ends a line, and a carriage return does not" {
    const Case = struct { name: []const u8, bytes: []const u8, want: bool };
    const cases = [_]Case{
        // A wrapped row, then something that either ends the line or does not.
        .{ .name = "LF", .bytes = "\n", .want = false },
        .{ .name = "VT", .bytes = "\x0b", .want = false },
        .{ .name = "FF", .bytes = "\x0c", .want = false },
        .{ .name = "IND", .bytes = "\x1bD", .want = false },
        .{ .name = "NEL", .bytes = "\x1bE", .want = false },
        .{ .name = "EL 0", .bytes = "\x1b[K", .want = false },
        .{ .name = "EL 2", .bytes = "\x1b[2K", .want = false },
        .{ .name = "ED 0", .bytes = "\x1b[J", .want = false },
        .{ .name = "ED 2", .bytes = "\x1b[2J", .want = false },
        // A carriage return moves within the line; it does not end it, so
        // `printf 'a\rb'` on a wrapped row still joins to the row below.
        .{ .name = "CR", .bytes = "\r", .want = true },
        // EL 1 and ED 1 erase up to the cursor and leave the tail -- and the
        // wrap the tail ran into -- intact.
        .{ .name = "EL 1", .bytes = "\x1b[1K", .want = true },
        .{ .name = "ED 1", .bytes = "\x1b[1J", .want = true },
        // Cursor movement says nothing about where the line ends.
        .{ .name = "CUP", .bytes = "\x1b[1;2H", .want = true },
        .{ .name = "backspace", .bytes = "\x08", .want = true },
        // The cursor sits at column 2 of 4. `wrapped` is a claim about the
        // cell at the *right margin*, so an ECH that reaches it ends the line
        // and one that stops short does not. Before this, `ECH` left a row it
        // had blanked entirely still claiming to wrap, and a triple-click on
        // the row below pasted the blanks in front of it.
        .{ .name = "ECH to the margin", .bytes = "\x1b[2X", .want = false },
        .{ .name = "ECH short of it", .bytes = "\x1b[1X", .want = true },
        // DCH always reaches it: shifting left blanks the tail.
        .{ .name = "DCH", .bytes = "\x1b[P", .want = false },
        // ICH is the deliberate exception -- it shifts text *into* the margin
        // rather than blanking it, and a shell editing a long wrapped command
        // line does exactly that before reprinting the remainder.
        .{ .name = "ICH", .bytes = "\x1b[@", .want = true },
    };

    for (cases) |case| {
        var t = try mkTerm(4, 3);
        defer t.deinit();
        feed(&t, "abcdef"); // row 0 wraps into row 1
        feed(&t, "\x1b[1;3H"); // back onto row 0, mid-row
        try testing.expect(wrapped(&t, 0));
        feed(&t, case.bytes);
        testing.expectEqual(case.want, wrapped(&t, 0)) catch |err| {
            std.debug.print("wrapped after {s}: expected {}\n", .{ case.name, case.want });
            return err;
        };
    }
}

test "a row scrolled into history carries its wrap flag and its id with it" {
    var t = try mkTerm(4, 2);
    defer t.deinit();
    const id0 = t.screen().rowMeta(0).id;
    feed(&t, "abcdefgh"); // two wrapped rows filling the screen
    try testing.expect(wrapped(&t, 0));
    feed(&t, "\r\nxy"); // push row 0 into scrollback

    try testing.expectEqual(@as(usize, 1), t.scrollback.len);
    try testing.expectEqual(id0, t.scrollback.backMeta(0).?.id);
    try testing.expect(t.scrollback.backMeta(0).?.flags.wrapped);
}

// -- line identity ---------------------------------------------------------

test "every live line has a distinct id, through every way of scrolling" {
    // The trap this is watching is `scrollUp`'s `n >= height` branch, which
    // clears the whole region and so stamps `height` rows rather than `n`.
    // Two rows sharing an id is invisible until a selection resolves onto
    // the wrong one, so assert it directly.
    var t = try mkTerm(8, 6);
    defer t.deinit();

    const churn = [_][]const u8{
        "line\r\n", // plain line feed
        "\x1b[2;5r", // a scroll region
        "\x1b[3;1H\x1b[2L", // IL inside it
        "\x1b[4;1H\x1b[3M", // DL inside it
        "\x1b[S", // SU
        "\x1b[9T", // SD by more than the region height
        "\x1b[r\x1b[99S", // whole screen, n >= height
        "\x1bM", // RI
        "\x1b[2J", // ED 2
        "wrapping text that runs off the right margin several times over",
    };
    for (churn) |bytes| feed(&t, bytes);

    var seen: [64]u64 = undefined;
    var n: usize = 0;
    for (0..t.rows) |y| {
        seen[n] = t.screen().rowMeta(y).id;
        n += 1;
    }
    for (0..t.scrollback.len) |i| {
        seen[n] = t.scrollback.backMeta(i).?.id;
        n += 1;
    }
    for (seen[0..n], 0..) |a, i| {
        try testing.expect(a != 0); // 0 means "no line" and is never minted
        for (seen[i + 1 .. n]) |b| try testing.expect(a != b);
    }
}

test "the primary and the alt screen never share an id" {
    // One counter for both, so an anchor taken on the primary cannot resolve
    // onto an alt row that happens to carry the same number.
    var t = try mkTerm(6, 4);
    defer t.deinit();
    feed(&t, "\x1b[?1049h");
    for (0..30) |_| feed(&t, "alt\r\n");
    feed(&t, "\x1b[?1049l");
    for (0..30) |_| feed(&t, "pri\r\n");

    for (0..t.rows) |y| {
        const pid = t.primary.rowMeta(y).id;
        for (0..t.rows) |z| try testing.expect(pid != t.alt.rowMeta(z).id);
    }
}

test "a reset does not reuse an id" {
    var t = try mkTerm(6, 3);
    defer t.deinit();
    feed(&t, "before\r\n");
    const before = t.primary.rowMeta(0).id;
    t.fullReset();
    for (0..t.rows) |y| try testing.expect(t.primary.rowMeta(y).id > before);
}

test "rows that survive a height change keep their identity" {
    var t = try mkTerm(10, 4);
    defer t.deinit();
    feed(&t, "keep me\r\n");
    const id = t.screen().rowMeta(0).id;
    try t.resize(10, 8);
    try testing.expectEqual(id, t.screen().rowMeta(0).id);
}
