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
    /// Any of the xterm mouse-reporting modes is on.
    mouse: bool = false,
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

    pub fn init(alloc: std.mem.Allocator, cols: usize, rows: usize) !Terminal {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        var primary = try Screen.init(alloc, c, r);
        errdefer primary.deinit(alloc);
        var alt = try Screen.init(alloc, c, r);
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

    // -- geometry -----------------------------------------------------------

    pub fn resize(self: *Terminal, cols: usize, rows: usize) !void {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        if (c == self.cols and r == self.rows) return;

        // Reflow is a genuinely hard problem (it interacts with wrapped-line
        // tracking and scrollback rewriting). For now we preserve content by
        // top-left anchoring, which is what most terminals did for years.
        var new_primary = try Screen.init(self.alloc, c, r);
        var new_alt = try Screen.init(self.alloc, c, r);
        const copy_rows = @min(r, self.rows);
        const copy_cols = @min(c, self.cols);
        for (0..copy_rows) |y| {
            @memcpy(new_primary.row(y)[0..copy_cols], self.primary.row(y)[0..copy_cols]);
            @memcpy(new_alt.row(y)[0..copy_cols], self.alt.row(y)[0..copy_cols]);
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
            self.lineFeed();
        }
        self.pending_wrap = false;

        if (self.cursor.x + w > self.cols) {
            if (!self.modes.wrap) {
                self.cursor.x = self.cols - w;
            } else {
                self.cursor.x = 0;
                self.lineFeed();
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
                self.lineFeed();
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
                self.lineFeed();
                self.markDirty();
            },
            0x0d => { // CR
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
            'D' => self.lineFeed(), // IND
            'E' => { // NEL
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
                self.screen().deleteCells(self.cursor.x, self.cursor.y, csi.get(0, 1), self.blankCell());
            },
            '@' => { // ICH
                self.screen().insertCells(self.cursor.x, self.cursor.y, csi.get(0, 1), self.blankCell());
            },
            'X' => self.eraseChars(csi.get(0, 1)), // ECH
            'S' => self.screen().scrollUp(self.scroll_top, self.scroll_bot, csi.get(0, 1), self.blankCell()),
            'T' => self.screen().scrollDown(self.scroll_top, self.scroll_bot, csi.get(0, 1), self.blankCell()),
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
            // full-screen apps, which manage their own repaint.
            if (!self.on_alt and self.scroll_top == 0) {
                self.scrollback.push(self.primary.row(0));
            }
            self.screen().scrollUp(self.scroll_top, self.scroll_bot, 1, self.blankCell());
        } else if (self.cursor.y + 1 < self.rows) {
            self.cursor.y += 1;
        }
        self.pending_wrap = false;
    }

    fn reverseIndex(self: *Terminal) void {
        if (self.cursor.y == self.scroll_top) {
            self.screen().scrollDown(self.scroll_top, self.scroll_bot, 1, self.blankCell());
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
        const s = self.screen();
        const blank = self.blankCell();
        switch (mode) {
            0 => { // cursor to end
                @memset(s.row(self.cursor.y)[self.cursor.x..], blank);
                if (self.cursor.y + 1 < self.rows) s.clearRows(self.cursor.y + 1, self.rows - 1, blank);
            },
            1 => { // start to cursor
                if (self.cursor.y > 0) s.clearRows(0, self.cursor.y - 1, blank);
                @memset(s.row(self.cursor.y)[0 .. self.cursor.x + 1], blank);
            },
            2 => s.fill(blank),
            3 => { // xterm: also clear scrollback
                s.fill(blank);
                self.scrollback.clear();
                self.view_offset = 0;
            },
            else => {},
        }
    }

    fn eraseLine(self: *Terminal, mode: u16) void {
        const r = self.screen().row(self.cursor.y);
        const blank = self.blankCell();
        switch (mode) {
            0 => @memset(r[self.cursor.x..], blank),
            1 => @memset(r[0 .. self.cursor.x + 1], blank),
            2 => @memset(r, blank),
            else => {},
        }
    }

    fn eraseChars(self: *Terminal, n: u16) void {
        const r = self.screen().row(self.cursor.y);
        const end = @min(self.cursor.x + n, self.cols);
        @memset(r[self.cursor.x..end], self.blankCell());
    }

    fn insertLines(self: *Terminal, n: u16) void {
        if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bot) return;
        self.screen().scrollDown(self.cursor.y, self.scroll_bot, n, self.blankCell());
    }

    fn deleteLines(self: *Terminal, n: u16) void {
        if (self.cursor.y < self.scroll_top or self.cursor.y > self.scroll_bot) return;
        self.screen().scrollUp(self.cursor.y, self.scroll_bot, n, self.blankCell());
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
            1000, 1002, 1003, 1006, 1015 => self.modes.mouse = on,
            47, 1047, 1049 => self.setAltScreen(on, p == 1049),
            2004 => self.modes.bracketed_paste = on,
            else => {},
        };
    }

    fn setAltScreen(self: *Terminal, on: bool, save_cursor: bool) void {
        if (on == self.on_alt) return;
        if (on) {
            if (save_cursor) self.saved_cursor = self.cursor;
            self.alt.fill(.blank);
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
        self.primary.fill(.blank);
        self.alt.fill(.blank);
        self.scrollback.clear();
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
    for (0..a.rows) |y| {
        try testing.expectEqualSlices(Cell, a.screen().row(y), b.screen().row(y));
    }
    var i: usize = 0;
    while (a.scrollback.back(i)) |line_a| : (i += 1) {
        try testing.expectEqualSlices(Cell, line_a, b.scrollback.back(i).?);
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
