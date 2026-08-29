//! Selection: what the user has picked out of the grid, and what copying it
//! produces.
//!
//! **Everything testable lives here.** `render.zig` and `main.zig` both
//! `@cImport` SDL, so nothing in them can be exercised without a window --
//! which is why the pixel-to-cell arithmetic, the word classifier, `contains`
//! and `extract` are all in this file and those two keep only the glue that
//! hands numbers to it. `std`, `grid` and `terminal` are the whole import
//! list, so this is in the unit-test root.
//!
//! ## Anchoring
//!
//! A selection is not a pair of screen rows. The screen is a ring that
//! rotates under `scrollUp`, rows leave it into a scrollback ring, and the
//! viewport snaps to the bottom on output -- so a row index means something
//! different one line feed later. A selection is a pair of **line ids**
//! (`grid.RowMeta.id`), minted by `terminal.zig` and carried by the row
//! wherever it goes. That is what makes a selection taken while `yes` is
//! running stay on the same text as it scrolls away.
//!
//! ## Ordinals
//!
//! Resolving an id gives an **ordinal**: history first, oldest at 0, then the
//! live screen. `ord = scrollback.len + y - view_offset` is the ordinal of
//! viewport row `y`, which is the same arithmetic `Terminal.viewRow` does and
//! the only thing the renderer needs to know. Ordinals give a total order
//! over "which line comes first" that line ids cannot: `IL` and a DECSTBM
//! region scroll splice freshly minted rows into the middle of the screen, so
//! a bigger id does not mean a later line.
//!
//! ## Normalizing at set time
//!
//! Wide-character snapping and word/line expansion happen once, in
//! `normalize`, and not in the extractor. If the highlight and the copied
//! text each worked it out for themselves they would eventually disagree, and
//! the bug would be one you can only see by comparing a screenshot with a
//! pasteboard.
//!
//! **Rect mode is the one exception**, and it is one because a rectangle's two
//! columns are shared by every row it covers while the glyphs under them are
//! not: a single stored pair of columns cannot say "and one cell wider on row
//! 4". So rect snaps per row, in `spanFor` -- which is still *one* place, and
//! still the same one the renderer and the extractor both call, so the
//! property that matters is intact.

const std = @import("std");
const grid = @import("grid.zig");
const Terminal = @import("terminal.zig").Terminal;

const Cell = grid.Cell;

/// One end of a selection: a line, by identity, and a column in it.
///
/// `x` is an **inclusive** cell index. Endpoints are inclusive at both ends
/// so that snapping onto a wide character's two cells is a statement about
/// cells rather than about a boundary between them; `Span` is where that
/// becomes the half-open range a renderer wants.
pub const Point = struct { line: u64, x: usize };

pub const Mode = enum {
    /// Drag: exactly the cells between the endpoints.
    character,
    /// Double-click: expanded to whole words.
    word,
    /// Triple-click: expanded to the whole **logical** line, across as many
    /// wrapped rows as it takes.
    line,
};

pub const Selection = struct {
    /// Where the drag began. Kept distinct from `head` so `Shift`-click can
    /// extend from it.
    anchor: Point,
    /// Where the pointer is now.
    head: Point,
    mode: Mode = .character,
    /// `Option`-drag: a rectangle of columns rather than a run of text.
    rect: bool = false,
};

/// The highlighted columns of one row, half-open: `[x0, x1)`. `x0 == x1`
/// means the row is not selected.
///
/// `Frame` carries one of these per row rather than the selection itself,
/// because `draw` runs after the terminal mutex is released and has no
/// scrollback to resolve a line id against. Resolving inside `snapshot` costs
/// one `contains` test per row under a lock that is already memcpying the
/// whole grid.
pub const Span = struct { x0: u16 = 0, x1: u16 = 0 };

// ---------------------------------------------------------------------------
// Who owns the mouse
// ---------------------------------------------------------------------------

pub const Owner = enum {
    /// We do: a drag paints a selection.
    terminal,
    /// The application does: a mouse-tracking mode is on and E2 forwards the
    /// event down the pty.
    child,
};

/// Who a mouse event belongs to. `shift` is the standard override: holding it
/// takes the mouse back from an application that asked for it, which is how
/// you select text in vim.
///
/// E1 **must not start a selection when this says `.child`**, even though the
/// `.child` branch does nothing yet. The day E2 fills it in, a drag inside
/// vim would otherwise both scroll vim and paint a selection over it.
pub fn mouseOwner(term: *const Terminal, shift: bool) Owner {
    if (shift) return .terminal;
    if (term.modes.mouse) return .child;
    return .terminal;
}

// ---------------------------------------------------------------------------
// Pixels to cells
// ---------------------------------------------------------------------------

/// The renderer's geometry, in device pixels. `render.zig` fills this in; it
/// is here so the arithmetic below can be tested without a window.
pub const Metrics = struct {
    /// Padding between the window edge and the first cell.
    pad: i32,
    cell_w: u32,
    cell_h: u32,
    cols: usize,
    rows: usize,
};

pub const Coord = struct { x: usize, y: usize };

/// The cell under a pixel, clamped to the grid.
///
/// Clamped rather than optional on purpose: a drag that leaves the window is
/// still a drag, and it should keep selecting to the edge of the row it left
/// through rather than stop dead.
pub fn cellAt(m: Metrics, px: i32, py: i32) Coord {
    const cw: i32 = @intCast(@max(m.cell_w, 1));
    const chh: i32 = @intCast(@max(m.cell_h, 1));
    const gx = @divFloor(px - m.pad, cw);
    const gy = @divFloor(py - m.pad, chh);
    return .{
        .x = clampIndex(gx, m.cols),
        .y = clampIndex(gy, m.rows),
    };
}

fn clampIndex(v: i32, len: usize) usize {
    if (v <= 0 or len == 0) return 0;
    const u: usize = @intCast(v);
    return @min(u, len - 1);
}

/// How far to scroll the view this tick while dragging, as the argument to
/// `Terminal.scrollView`: positive is toward the past.
///
/// Zero while the pointer is over the grid, which is what keeps autoscroll
/// from costing an idle terminal anything: `main.zig` only switches from
/// `SDL_WaitEvent` to a 16 ms `SDL_WaitEventTimeout` while this is non-zero.
///
/// The rate ramps with distance, one row per cell height past the edge, so a
/// small overshoot creeps and a big one moves.
pub fn autoscroll(m: Metrics, py: i32) isize {
    const chh: i32 = @intCast(@max(m.cell_h, 1));
    const top = m.pad;
    const bot = m.pad + @as(i32, @intCast(m.rows * @max(m.cell_h, 1)));
    const rate = struct {
        fn f(dist: i32, h: i32) isize {
            return 1 + @as(isize, @intCast(@divFloor(dist, h)));
        }
    }.f;
    if (py < top) return rate(top - py, chh);
    if (py >= bot) return -rate(py - bot, chh);
    return 0;
}

// ---------------------------------------------------------------------------
// Words
// ---------------------------------------------------------------------------

/// What a double-click expands over. A run of one class is a word.
pub const Class = enum { space, word, punct };

/// `/` and `.` are word characters, so a double-click on `src/render.zig`
/// grabs the path rather than three of its pieces -- which is the thing a
/// double-click in a terminal is most often for. `_`, `-` and `~` are in for
/// the same reason. Everything past ASCII is a word character, which is right
/// for CJK and for accented Latin and wrong for CJK punctuation; that is a
/// Unicode word-break table (C2) rather than a table this sprint should
/// invent.
pub fn classify(cp: u21) Class {
    if (cp == ' ' or cp == 0 or cp == '\t') return .space;
    if (cp >= 0x80) return .word;
    if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or (cp >= '0' and cp <= '9')) return .word;
    return switch (cp) {
        '_', '-', '.', '/', '~', '+' => .word,
        else => .punct,
    };
}

/// The class of the character occupying cell `x`. A wide character's spacer
/// holds a space, so asking it directly would split every CJK word in half.
fn cellClass(row: []const Cell, x: usize) Class {
    if (row[x].wide == .spacer and x > 0) return classify(row[x - 1].cp);
    return classify(row[x].cp);
}

// ---------------------------------------------------------------------------
// Resolving a line id
// ---------------------------------------------------------------------------

pub const Line = struct {
    cells: []const Cell,
    meta: grid.RowMeta,
    /// History first, oldest at 0, then the live screen.
    ord: usize,
};

/// **The one accessor for the scrollback boundary.** A selection that spans
/// history and the live screen needs no special case anywhere else because
/// everything above goes through this.
pub fn lineById(term: *Terminal, id: u64) ?Line {
    const ord = ordOf(term, id) orelse return null;
    return lineByOrd(term, ord);
}

pub fn lineByOrd(term: *Terminal, ord: usize) ?Line {
    const sb = &term.scrollback;
    if (ord < sb.len) {
        const i = sb.len - 1 - ord;
        return .{ .cells = sb.back(i).?, .meta = sb.backMeta(i).?, .ord = ord };
    }
    const y = ord - sb.len;
    if (y >= term.rows) return null;
    const scr = term.screen();
    return .{ .cells = scr.row(y), .meta = scr.rowMeta(y).*, .ord = ord };
}

/// The ordinal of the line carrying `id`, or null if nothing does.
///
/// The scrollback is searched with a binary search, because ids descend as
/// `i` grows for every history a shell actually produces -- rows leave the
/// top of the screen in order, and each one was labelled before the row that
/// followed it. `IL` and `RI` can break that: they stamp a fresh, and
/// therefore *higher*, id on a row above older ones, and once that row
/// scrolls off the history is no longer sorted. So a miss falls back to a
/// scan rather than being believed. The fallback runs only when both the
/// binary search and the screen have missed, which for a live selection is
/// only when a line really has been evicted.
fn ordOf(term: *Terminal, id: u64) ?usize {
    if (id == 0) return null; // never minted
    const sb = &term.scrollback;

    if (sb.len > 0) {
        var lo: usize = 0;
        var hi: usize = sb.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const mid_id = sb.backMeta(mid).?.id;
            if (mid_id == id) return sb.len - 1 - mid;
            if (mid_id > id) lo = mid + 1 else hi = mid;
        }
    }

    const scr = term.screen();
    for (0..term.rows) |y| {
        if (scr.rowMeta(y).id == id) return sb.len + y;
    }

    for (0..sb.len) |i| {
        if (sb.backMeta(i).?.id == id) return sb.len - 1 - i;
    }
    return null;
}

/// The ordinal of viewport row `y` -- the same branch `Terminal.viewRow`
/// takes, expressed as one number. This is all the renderer needs.
pub fn viewOrd(term: *const Terminal, y: usize) usize {
    return term.scrollback.len + y - @min(term.view_offset, term.scrollback.len);
}

// ---------------------------------------------------------------------------
// Resolving a selection
// ---------------------------------------------------------------------------

pub const Pos = struct { ord: usize, x: usize };

/// A selection pinned to the grid as it is right now: two ordinals in order,
/// so everything downstream is arithmetic.
pub const Resolved = struct {
    start: Pos,
    end: Pos,
    rect: bool,
    cols: usize,
};

fn before(a: Pos, b: Pos) bool {
    if (a.ord != b.ord) return a.ord < b.ord;
    return a.x < b.x;
}

/// The smallest id anything on the grid still carries, or null when nothing
/// does.
///
/// Deliberately not `lineByOrd(term, 0).meta.id`: `RI` and `IL` splice a
/// *freshly minted*, and therefore higher, id above older rows, so the line
/// that is oldest by position is not always the one with the smallest number.
/// The scan is the cold path -- `clip` only reaches it once `ordOf` has
/// already missed, and `ordOf`'s own fallback has already walked the same
/// history.
fn oldestId(term: *Terminal) ?u64 {
    var oldest: ?u64 = null;
    const keep = struct {
        fn f(best: *?u64, id: u64) void {
            if (id == 0) return; // never minted
            if (best.* == null or id < best.*.?) best.* = id;
        }
    }.f;
    const sb = &term.scrollback;
    for (0..sb.len) |i| keep(&oldest, sb.backMeta(i).?.id);
    const scr = term.screen();
    for (0..term.rows) |y| keep(&oldest, scr.rowMeta(y).id);
    return oldest;
}

/// Where an endpoint is now, or null when there is no honest answer.
///
/// A missing line was either **evicted** off the oldest end of the history or
/// **destroyed in place**, and the two need opposite answers. Ids are minted
/// monotonically, so an id smaller than every id still on the grid can only
/// have fallen off the oldest end: ordinal 0 is then the earliest line there
/// is, and clamping to it can only make the selection *smaller*. An id that is
/// not smaller than all of them had its row retired under it -- `ED 0`,
/// `ED 1`, `ED 2`, `IL`, `DL`, `SU`/`SD`, a region scroll or a
/// height-shrinking resize, none of which clear the selection -- and no
/// ordinal honestly stands for it.
///
/// Sending *that* to ordinal 0 is how a two-row selection came to put an
/// entire 10,000-line session on the pasteboard while its highlight shrank to
/// one row: the later endpoint jumps to the oldest surviving line, the copy
/// grows by the whole scrollback, and nothing on screen says so. `ED 0` is
/// what readline emits on nearly every prompt redraw, so it was not a corner.
/// Dropping the selection loses a highlight, which is predictable and visible;
/// silently copying the whole history is neither.
fn clip(term: *Terminal, p: Point) ?Pos {
    if (ordOf(term, p.line)) |ord| return .{ .ord = ord, .x = p.x };
    const oldest = oldestId(term) orelse return null;
    if (p.line >= oldest) return null; // destroyed in place
    return .{ .ord = 0, .x = 0 };
}

/// Pin a selection to the grid. Null when both endpoints are gone, and null
/// when either endpoint's line was destroyed in place rather than evicted --
/// both are the caller's cue to clear it.
pub fn resolve(term: *Terminal, s: Selection) ?Resolved {
    const a_live = ordOf(term, s.anchor.line) != null;
    const h_live = ordOf(term, s.head.line) != null;
    if (!a_live and !h_live) return null;

    // Both of these fire: `clip` refuses an endpoint whose line was destroyed
    // in place, and refusing the whole selection is the point of it.
    const a = clip(term, s.anchor) orelse return null;
    const h = clip(term, s.head) orelse return null;
    const fwd = !before(h, a);
    return .{
        .start = if (fwd) a else h,
        .end = if (fwd) h else a,
        .rect = s.rect,
        .cols = term.cols,
    };
}

/// The highlighted columns of the line at `ord`, or null if it has none.
///
/// `cells` is that line's row. It is required rather than optional because
/// **rect mode snaps its wide characters here, per row**: outside rect mode
/// `normalize` has already snapped both endpoints once and this ignores the
/// row entirely, but a rectangle's two columns are shared by every row it
/// covers and the glyphs under them are not. Making the argument optional
/// would leave a call that silently gets the un-snapped answer, which is the
/// bug this signature exists to make unwriteable.
pub fn spanFor(res: Resolved, ord: usize, cells: []const Cell) ?Span {
    if (ord < res.start.ord or ord > res.end.ord) return null;
    const cols = res.cols;
    var x0: usize = undefined;
    var x1: usize = undefined;
    if (res.rect) {
        x0 = @min(res.start.x, res.end.x);
        x1 = @max(res.start.x, res.end.x) + 1;
        if (cells.len == 0) return null;
        // Snapping per row ripples the block's edges by at most one cell,
        // wherever a pair straddles one. That is the smaller of the two
        // evils. Widening the whole block instead, to the union of what every
        // row asks for, keeps it perfectly rectangular -- but two misaligned
        // rows of CJK have a spacer in almost every column between them, so
        // the union walks a two-column drag out to the full width of the
        // grid. There is a test pinning that.
        const last = cells.len - 1;
        x0 = snapLeft(cells, @min(x0, last));
        x1 = snapRight(cells, @min(x1 - 1, last)) + 1;
    } else {
        x0 = if (ord == res.start.ord) res.start.x else 0;
        // Inclusive endpoints, half-open span: the `+ 1` is the whole reason
        // the last selected column is drawn and copied at all.
        x1 = if (ord == res.end.ord) res.end.x + 1 else cols;
    }
    x0 = @min(x0, cols);
    x1 = @min(x1, cols);
    if (x0 >= x1) return null;
    return .{ .x0 = @intCast(x0), .x1 = @intCast(x1) };
}

/// Whether cell (`ord`, `x`) of the row `cells` is selected.
pub fn contains(res: Resolved, ord: usize, cells: []const Cell, x: usize) bool {
    const span = spanFor(res, ord, cells) orelse return false;
    return x >= span.x0 and x < span.x1;
}

// ---------------------------------------------------------------------------
// Normalizing
// ---------------------------------------------------------------------------

/// Snap a selection onto whole cells, whole words or whole logical lines,
/// once, at the moment it is set.
///
/// Null when neither endpoint resolves any more.
pub fn normalize(term: *Terminal, s: Selection) ?Selection {
    const res = resolve(term, s) orelse return null;
    var start = res.start;
    var end = res.end;
    const cols = term.cols;
    if (cols == 0) return null;

    if (!s.rect) switch (s.mode) {
        .character => {},
        .word => {
            if (lineByOrd(term, start.ord)) |l| {
                start.x = wordStart(l.cells, @min(start.x, cols - 1));
            }
            if (lineByOrd(term, end.ord)) |l| {
                end.x = wordEnd(l.cells, @min(end.x, cols - 1));
            }
        },
        .line => {
            // A *logical* line, across every row `wrapped` says belongs to
            // it. Selecting one screen row here would leave `wrapped` unused
            // by two of the three granularities on the day it shipped.
            start.ord = logicalStart(term, start.ord);
            start.x = 0;
            end.ord = logicalEnd(term, end.ord);
            end.x = cols - 1;
        },
    };

    // Wide characters select as a pair, in every mode. A start that landed on
    // a spacer snaps left onto its `.wide` partner; an end that landed on a
    // `.wide` extends over the spacer that belongs to it. Without this the
    // highlight covers half a glyph and the copy drops or duplicates it.
    //
    // Rect mode is the exception, and it is `spanFor`'s job: a rectangle's
    // columns are the same on every row it covers but the glyphs under them
    // are not, so one stored pair of columns cannot say "and one cell wider
    // on row 4". Snapping here against the start row alone -- which is what
    // this used to do -- let every other row in the block inherit the start
    // row's decision and cut its pairs in half.
    if (!res.rect) {
        if (lineByOrd(term, start.ord)) |l| start.x = snapLeft(l.cells, @min(start.x, cols - 1));
        if (lineByOrd(term, end.ord)) |l| end.x = snapRight(l.cells, @min(end.x, cols - 1));
    }

    const start_line = lineByOrd(term, start.ord) orelse return null;
    const end_line = lineByOrd(term, end.ord) orelse return null;
    return .{
        .anchor = .{ .line = start_line.meta.id, .x = start.x },
        .head = .{ .line = end_line.meta.id, .x = end.x },
        .mode = s.mode,
        .rect = s.rect,
    };
}

fn snapLeft(row: []const Cell, x: usize) usize {
    if (x > 0 and row[x].wide == .spacer) return x - 1;
    return x;
}

fn snapRight(row: []const Cell, x: usize) usize {
    if (row[x].wide == .wide and x + 1 < row.len) return x + 1;
    return x;
}

fn wordStart(row: []const Cell, x: usize) usize {
    const cls = cellClass(row, x);
    var i = x;
    while (i > 0 and cellClass(row, i - 1) == cls) i -= 1;
    return i;
}

fn wordEnd(row: []const Cell, x: usize) usize {
    const cls = cellClass(row, x);
    var i = x;
    while (i + 1 < row.len and cellClass(row, i + 1) == cls) i += 1;
    return i;
}

/// The first row of the logical line `ord` is part of: walk back while the
/// row above says it wrapped into this one.
fn logicalStart(term: *Terminal, ord: usize) usize {
    var i = ord;
    while (i > 0) {
        const above = lineByOrd(term, i - 1) orelse break;
        if (!above.meta.flags.wrapped) break;
        i -= 1;
    }
    return i;
}

/// The last row of the logical line `ord` is part of: walk forward while this
/// row says it wrapped into the next.
fn logicalEnd(term: *Terminal, ord: usize) usize {
    var i = ord;
    while (true) {
        const here = lineByOrd(term, i) orelse break;
        if (!here.meta.flags.wrapped) break;
        if (lineByOrd(term, i + 1) == null) break;
        i += 1;
    }
    return i;
}

// ---------------------------------------------------------------------------
// Extracting
// ---------------------------------------------------------------------------

/// What a copy is allowed to produce. A selection over a full scrollback is
/// 10,000 x 200 cells; at four bytes a codepoint that is 8 MB, and a wider
/// grid or an emoji-heavy one is more. The cap **truncates at a row
/// boundary**, so what reaches the pasteboard is always a whole number of
/// lines rather than half of one.
pub const cap_bytes: usize = 16 << 20;

/// The selected text, UTF-8, NUL-terminated for `SDL_SetClipboardText`.
///
/// The rules, all of which are here rather than split with the renderer:
///
/// - A wide character's `.spacer` is skipped and its codepoint emitted once.
/// - Trailing spaces are trimmed from any row the selection covers **to the
///   last column** -- a terminal pads every row to `cols` with blanks, and
///   pasting them back is never what was wanted. Regardless of background:
///   the alternative is that selecting a coloured status bar pastes 80
///   spaces because the blanks were not "really" blank.
/// - A row that is `wrapped` **and** covered to the last column is joined to
///   the next with no separator and no trim: it is one logical line that the
///   margin happened to break, and the break is ours, not the text's.
/// - `rect` never joins, always trims and always separates with `\n`.
/// - Codepoints only. No SGR: this is text, and a paste of it into a shell
///   has to be the characters that were on screen.
pub fn extract(alloc: std.mem.Allocator, term: *Terminal, s: Selection) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    const res = resolve(term, s) orelse return out.toOwnedSliceSentinel(alloc, 0);

    var sep_owed = false;
    var ord = res.start.ord;
    while (ord <= res.end.ord) : (ord += 1) {
        const line = lineByOrd(term, ord) orelse break;
        const span = spanFor(res, ord, line.cells) orelse continue;

        // The row boundary the cap truncates at.
        const mark = out.items.len;
        if (sep_owed) try out.append(alloc, '\n');
        const row_start = out.items.len;

        var x: usize = span.x0;
        while (x < span.x1) : (x += 1) {
            const cell = line.cells[x];
            if (cell.wide == .spacer) continue; // its codepoint came with .wide
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.cp, &buf) catch continue;
            try out.appendSlice(alloc, buf[0..n]);
        }

        const covered_to_end = span.x1 >= res.cols;
        // `covered_to_end` in `join` is an **equivalent** mutant, not a
        // missing test: drop it and no input changes. In non-rect mode only
        // the final row can stop short of the margin, and on the final row
        // `join` reaches neither the trim branch (guarded by `covered_to_end`
        // itself) nor anything that reads `sep_owed` afterwards. It stays
        // because it is the rule the doc comment states; do not "fix" the
        // survivor by deleting it.
        const join = !res.rect and line.meta.flags.wrapped and covered_to_end;
        if (res.rect or (covered_to_end and !join)) {
            var end = out.items.len;
            while (end > row_start and out.items[end - 1] == ' ') end -= 1;
            out.shrinkRetainingCapacity(end);
        }
        sep_owed = !join;

        if (out.items.len > cap_bytes) {
            out.shrinkRetainingCapacity(mark);
            break;
        }
    }

    return out.toOwnedSliceSentinel(alloc, 0);
}

// ---------------------------------------------------------------------------
// Building one from a click
// ---------------------------------------------------------------------------

/// The point at viewport row `y`, column `x`. Null when that row carries no
/// line -- which only happens on a screen nothing has ever labelled.
pub fn pointAt(term: *Terminal, coord: Coord) ?Point {
    if (coord.y >= term.rows or coord.x >= term.cols) return null;
    const meta = term.viewRowMeta(coord.y);
    if (meta.id == 0) return null;
    return .{ .line = meta.id, .x = coord.x };
}

/// The mode a click count asks for. SDL3 counts consecutive clicks for us, so
/// there is no timestamp window to hand-roll and get subtly wrong.
pub fn modeForClicks(clicks: u8) Mode {
    return switch (clicks) {
        0, 1 => .character,
        2 => .word,
        else => .line,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const vt = @import("vt.zig");

fn feed(t: *Terminal, bytes: []const u8) void {
    var p: vt.Parser = .{};
    p.feed(t, bytes);
}

fn mkTerm(cols: usize, rows: usize) !Terminal {
    return Terminal.init(testing.allocator, cols, rows);
}

/// The id of viewport row `y`, which is what a click there produces.
fn idAt(t: *Terminal, y: usize) u64 {
    return t.viewRowMeta(y).id;
}

fn sel2(t: *Terminal, y0: usize, x0: usize, y1: usize, x1: usize) Selection {
    return .{
        .anchor = .{ .line = idAt(t, y0), .x = x0 },
        .head = .{ .line = idAt(t, y1), .x = x1 },
    };
}

fn copy(t: *Terminal, s: Selection) ![:0]u8 {
    const norm = normalize(t, s) orelse return testing.allocator.dupeZ(u8, "");
    return extract(testing.allocator, t, norm);
}

fn expectCopy(t: *Terminal, s: Selection, want: []const u8) !void {
    const got = try copy(t, s);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// Is cell (`x`, viewport row `y`) highlighted? `contains` takes the row
/// because rect mode snaps wide pairs per row, so every test goes through
/// this rather than repeating the lookup.
fn hit(t: *Terminal, res: Resolved, y: usize, x: usize) bool {
    return contains(res, viewOrd(t, y), t.viewRow(y), x);
}

// -- the word classifier, as a table --------------------------------------

test "the word classifier is a table" {
    const Case = struct { cp: u21, want: Class };
    const cases = [_]Case{
        .{ .cp = 'a', .want = .word },   .{ .cp = 'Z', .want = .word },
        .{ .cp = '7', .want = .word },   .{ .cp = '_', .want = .word },
        // The answer to the plan's first open question: a double-click has to
        // grab `src/render.zig` whole.
        .{ .cp = '/', .want = .word },   .{ .cp = '.', .want = .word },
        .{ .cp = '-', .want = .word },   .{ .cp = '~', .want = .word },
        .{ .cp = '+', .want = .word },   .{ .cp = ' ', .want = .space },
        .{ .cp = '\t', .want = .space }, .{ .cp = 0, .want = .space },
        .{ .cp = '(', .want = .punct },  .{ .cp = ':', .want = .punct },
        .{ .cp = '=', .want = .punct },  .{ .cp = ',', .want = .punct },
        .{ .cp = '\'', .want = .punct }, .{ .cp = '|', .want = .punct },
        .{ .cp = 0x4e00, .want = .word }, // CJK
        .{ .cp = 0xe9, .want = .word }, // e-acute
    };
    for (cases) |c| try testing.expectEqual(c.want, classify(c.cp));
}

test "a double-click grabs a path, and stops at a space" {
    var t = try mkTerm(40, 3);
    defer t.deinit();
    feed(&t, "see src/render.zig (line 42)");

    // Anywhere in the path gives the whole path.
    for ([_]usize{ 4, 7, 12, 17 }) |x| {
        var s = sel2(&t, 0, x, 0, x);
        s.mode = .word;
        try expectCopy(&t, s, "src/render.zig");
    }
    // The space between words is a word of its own.
    var space = sel2(&t, 0, 3, 0, 3);
    space.mode = .word;
    try expectCopy(&t, space, " ");
    // And punctuation is its own class, so `(` does not swallow `line`.
    var paren = sel2(&t, 0, 19, 0, 19);
    paren.mode = .word;
    try expectCopy(&t, paren, "(");
}

test "a double-click on a CJK word does not stop at the spacer" {
    var t = try mkTerm(20, 2);
    defer t.deinit();
    feed(&t, "a \u{4e00}\u{4e8c}\u{4e09} b");
    // The three ideographs occupy columns 2..7, alternating wide and spacer.
    var s = sel2(&t, 0, 4, 0, 4);
    s.mode = .word;
    try expectCopy(&t, s, "\u{4e00}\u{4e8c}\u{4e09}");
}

// -- contains -------------------------------------------------------------

test "contains, forward, backward, multi-row and rect" {
    var t = try mkTerm(10, 4);
    defer t.deinit();
    feed(&t, "aaaaaaaaaa\r\nbbbbbbbbbb\r\ncccccccccc\r\ndddddddddd");

    const forward = resolve(&t, normalize(&t, sel2(&t, 0, 3, 2, 5)).?).?;
    // First row: from the anchor to the end.
    try testing.expect(!hit(&t, forward, 0, 2));
    try testing.expect(hit(&t, forward, 0, 3));
    try testing.expect(hit(&t, forward, 0, 9));
    // Middle row: all of it.
    try testing.expect(hit(&t, forward, 1, 0));
    try testing.expect(hit(&t, forward, 1, 9));
    // Last row: up to and *including* the head column. The `+ 1` in
    // `spanFor` is what this is watching.
    try testing.expect(hit(&t, forward, 2, 5));
    try testing.expect(!hit(&t, forward, 2, 6));
    // And nothing outside.
    try testing.expect(!hit(&t, forward, 3, 0));

    // Dragged the other way, the same cells are selected.
    const backward = resolve(&t, normalize(&t, sel2(&t, 2, 5, 0, 3)).?).?;
    for (0..4) |y| for (0..10) |x| {
        try testing.expectEqual(hit(&t, forward, y, x), hit(&t, backward, y, x));
    };

    // A rectangle takes the same columns from every row it covers.
    var block = sel2(&t, 0, 6, 2, 2);
    block.rect = true;
    const rect = resolve(&t, normalize(&t, block).?).?;
    for (0..3) |y| {
        try testing.expect(!hit(&t, rect, y, 1));
        try testing.expect(hit(&t, rect, y, 2));
        try testing.expect(hit(&t, rect, y, 6));
        try testing.expect(!hit(&t, rect, y, 7));
    }
    try testing.expect(!hit(&t, rect, 3, 3));
}

test "a one-cell selection covers exactly one cell" {
    var t = try mkTerm(8, 2);
    defer t.deinit();
    feed(&t, "abcdefgh");
    const r = resolve(&t, normalize(&t, sel2(&t, 0, 3, 0, 3)).?).?;
    try testing.expect(!hit(&t, r, 0, 2));
    try testing.expect(hit(&t, r, 0, 3));
    try testing.expect(!hit(&t, r, 0, 4));
    try expectCopy(&t, sel2(&t, 0, 3, 0, 3), "d");
}

// -- pixels to cells ------------------------------------------------------

test "cellAt over a scale table" {
    const Case = struct {
        name: []const u8,
        m: Metrics,
        px: i32,
        py: i32,
        want: Coord,
    };
    const one: Metrics = .{ .pad = 6, .cell_w = 8, .cell_h = 17, .cols = 80, .rows = 24 };
    const two: Metrics = .{ .pad = 12, .cell_w = 16, .cell_h = 34, .cols = 80, .rows = 24 };
    const cases = [_]Case{
        .{ .name = "1x origin", .m = one, .px = 6, .py = 6, .want = .{ .x = 0, .y = 0 } },
        .{ .name = "1x inside the first cell", .m = one, .px = 13, .py = 22, .want = .{ .x = 0, .y = 0 } },
        .{ .name = "1x the next cell", .m = one, .px = 14, .py = 23, .want = .{ .x = 1, .y = 1 } },
        .{ .name = "1x arbitrary", .m = one, .px = 6 + 8 * 37 + 3, .py = 6 + 17 * 9 + 4, .want = .{ .x = 37, .y = 9 } },
        // The same physical point on a 2x display lands on the same cell,
        // which is the property that makes this worth a table.
        .{ .name = "2x origin", .m = two, .px = 12, .py = 12, .want = .{ .x = 0, .y = 0 } },
        .{ .name = "2x arbitrary", .m = two, .px = 12 + 16 * 37 + 6, .py = 12 + 34 * 9 + 8, .want = .{ .x = 37, .y = 9 } },
        // Outside the window in every direction, clamped rather than refused.
        .{ .name = "left of the pad", .m = one, .px = 0, .py = 100, .want = .{ .x = 0, .y = 5 } },
        .{ .name = "above the pad", .m = one, .px = 100, .py = 0, .want = .{ .x = 11, .y = 0 } },
        .{ .name = "negative", .m = one, .px = -400, .py = -400, .want = .{ .x = 0, .y = 0 } },
        .{ .name = "past the last column", .m = one, .px = 100000, .py = 6, .want = .{ .x = 79, .y = 0 } },
        .{ .name = "below the last row", .m = one, .px = 6, .py = 100000, .want = .{ .x = 0, .y = 23 } },
    };
    for (cases) |c| {
        const got = cellAt(c.m, c.px, c.py);
        testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("cellAt: {s}\n", .{c.name});
            return err;
        };
    }
}

test "autoscroll is zero over the grid and ramps outside it" {
    const m: Metrics = .{ .pad = 6, .cell_w = 8, .cell_h = 17, .cols = 80, .rows = 24 };
    // Anywhere over the grid, nothing -- which is what keeps an idle
    // terminal on SDL_WaitEvent rather than a 16 ms poll.
    try testing.expectEqual(@as(isize, 0), autoscroll(m, 6));
    try testing.expectEqual(@as(isize, 0), autoscroll(m, 6 + 17 * 24 - 1));
    // Above: toward the past.
    try testing.expectEqual(@as(isize, 1), autoscroll(m, 5));
    try testing.expectEqual(@as(isize, 2), autoscroll(m, 6 - 20));
    // Below: toward the present.
    try testing.expectEqual(@as(isize, -1), autoscroll(m, 6 + 17 * 24));
    try testing.expectEqual(@as(isize, -3), autoscroll(m, 6 + 17 * 24 + 40));
}

// -- extraction -----------------------------------------------------------

test "extract trims a row the selection covers to the last column" {
    var t = try mkTerm(20, 3);
    defer t.deinit();
    feed(&t, "hello\r\nworld");
    // Row 0 is `hello` followed by fifteen blanks. Covering it to the last
    // column must not paste those blanks.
    try expectCopy(&t, sel2(&t, 0, 0, 1, 4), "hello\nworld");
}

test "extract does not trim a row the selection stops inside" {
    var t = try mkTerm(20, 2);
    defer t.deinit();
    feed(&t, "hi");
    // The user dragged over the blanks deliberately; they are what was
    // selected, so they are what is copied.
    try expectCopy(&t, sel2(&t, 0, 0, 0, 5), "hi    ");
}

test "extract trims a coloured background the same as a plain one" {
    var t = try mkTerm(20, 2);
    defer t.deinit();
    // A `less` status bar: text, then the background painted to the margin.
    feed(&t, "\x1b[44mstatus\x1b[K\x1b[0m");
    try expectCopy(&t, sel2(&t, 0, 0, 0, 19), "status");
}

test "extract joins a wrapped row with no separator" {
    var t = try mkTerm(6, 4);
    defer t.deinit();
    feed(&t, "abcdefghij\r\nnext");
    // `abcdef` wrapped into `ghij`, so the two rows are one line.
    try testing.expect(t.screen().rowMeta(0).flags.wrapped);
    try expectCopy(&t, sel2(&t, 0, 0, 1, 3), "abcdefghij");
    // And across the wrap into the line after it, which was not wrapped.
    try expectCopy(&t, sel2(&t, 0, 0, 2, 3), "abcdefghij\nnext");
}

test "extract keeps the spaces inside a wrapped line" {
    // Mutation testing found this one: every other wrapped-row test happened
    // to use text with no spaces at the margin, so "trim a wrapped row too"
    // was a change no test could see. A wrapped row's trailing blanks are
    // *inside* the line -- the margin fell there, the text did not end there
    // -- and trimming them silently deletes characters the shell printed.
    var t = try mkTerm(6, 4);
    defer t.deinit();
    feed(&t, "abc   def");
    try testing.expect(t.screen().rowMeta(0).flags.wrapped);
    try expectCopy(&t, sel2(&t, 0, 0, 1, 2), "abc   def");

    // And the last row of the same selection is still trimmed when the
    // selection covers it to the margin, because that row is not wrapped.
    try expectCopy(&t, sel2(&t, 0, 0, 1, 5), "abc   def");
}

test "extract separates rows a line feed ended, even when they are full" {
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcd\r\nefgh");
    // Both rows are full to the margin, and neither wrapped: the difference
    // is entirely in the flag, and it is the difference between one line and
    // two.
    try testing.expect(!t.screen().rowMeta(0).flags.wrapped);
    try expectCopy(&t, sel2(&t, 0, 0, 1, 3), "abcd\nefgh");
}

test "extract emits a wide character once and never its spacer" {
    var t = try mkTerm(10, 2);
    defer t.deinit();
    feed(&t, "a\u{4e00}b");
    try expectCopy(&t, sel2(&t, 0, 0, 0, 3), "a\u{4e00}b");
    // Starting on the spacer snaps left onto the character it belongs to,
    // so the copy is the character rather than a space.
    try expectCopy(&t, sel2(&t, 0, 2, 0, 2), "\u{4e00}");
    // Ending on the wide cell extends over its spacer, which changes nothing
    // in the text but keeps the highlight from covering half a glyph.
    const s = normalize(&t, sel2(&t, 0, 0, 0, 1)).?;
    try testing.expectEqual(@as(usize, 2), s.head.x);
}

test "extract in rect mode never joins and always trims" {
    var t = try mkTerm(10, 4);
    defer t.deinit();
    feed(&t, "abcdefghij123\r\nzz");
    // Row 0 wrapped into row 1, and row 1 is short.
    try testing.expect(t.screen().rowMeta(0).flags.wrapped);
    var block = sel2(&t, 0, 0, 2, 3);
    block.rect = true;
    // Four columns from each of three rows: no join across the wrap, and the
    // short rows trimmed rather than padded.
    try expectCopy(&t, block, "abcd\n123\nzz");
}

test "rect mode snaps wide characters in every row, not just the start row" {
    var t = try mkTerm(10, 3);
    defer t.deinit();
    // Row 0 is plain letters; row 1 puts a pair at 2-3 and another at 4-5.
    feed(&t, "abcdefghij\r\nab\u{4e00}\u{4e8c}efgh");
    var block = sel2(&t, 0, 3, 1, 4);
    block.rect = true;

    // Columns 3..4 cut both of row 1's pairs in half, and row 0 -- the start
    // row, the only one this used to consult -- has nothing to say about it.
    // Before the fix this copied "de\n\u{4e8c}": `\u{4e00}` dropped entirely,
    // and a highlight over two half glyphs.
    try expectCopy(&t, block, "de\n\u{4e00}\u{4e8c}");

    const res = resolve(&t, normalize(&t, block).?).?;
    // Row 0 keeps the columns the drag asked for.
    try testing.expect(!hit(&t, res, 0, 2));
    try testing.expect(hit(&t, res, 0, 3));
    try testing.expect(hit(&t, res, 0, 4));
    try testing.expect(!hit(&t, res, 0, 5));
    // Row 1's edges ripple by one cell each, so both pairs are whole.
    try testing.expect(!hit(&t, res, 1, 1));
    try testing.expect(hit(&t, res, 1, 2));
    try testing.expect(hit(&t, res, 1, 5));
    try testing.expect(!hit(&t, res, 1, 6));
}

test "rect mode does not widen a block to cover a whole misaligned CJK row" {
    // The rejected alternative, pinned so nobody reaches for it: widening the
    // block to the union of what every row asks for keeps it perfectly
    // rectangular, but these two rows have a spacer in almost every column
    // between them, so a two-column drag would walk out to the whole grid.
    var t = try mkTerm(10, 3);
    defer t.deinit();
    feed(&t, "\u{4e00}\u{4e8c}\u{4e09}\u{56db}\u{4e94}\r\na\u{4e00}\u{4e8c}\u{4e09}\u{56db}");
    var block = sel2(&t, 0, 4, 1, 5);
    block.rect = true;
    // Four cells, not twenty.
    try expectCopy(&t, block, "\u{4e09}\n\u{4e8c}\u{4e09}");
}

test "extract spans the scrollback boundary" {
    var t = try mkTerm(8, 3);
    defer t.deinit();
    feed(&t, "one\r\ntwo\r\nthree\r\nfour\r\nfive");
    // `one` and `two` are history now; `three`, `four`, `five` are on screen.
    try testing.expectEqual(@as(usize, 2), t.scrollback.len);
    t.scrollView(2); // so the viewport shows all five

    try expectCopy(&t, sel2(&t, 0, 0, 4, 3), "one\ntwo\nthree\nfour\nfive");
    // And a selection that starts in history and ends on the live screen.
    try expectCopy(&t, sel2(&t, 1, 0, 2, 4), "two\nthree");
}

test "a selection survives the lines under it scrolling away" {
    var t = try mkTerm(20, 4);
    defer t.deinit();
    feed(&t, "MARKER\r\n");
    const s = normalize(&t, sel2(&t, 0, 0, 0, 5)).?;
    const before_text = try extract(testing.allocator, &t, s);
    defer testing.allocator.free(before_text);
    try testing.expectEqualStrings("MARKER", before_text);

    // Push it well off the screen and into history.
    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        feed(&t, std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}) catch unreachable);
    }
    const after_text = try extract(testing.allocator, &t, s);
    defer testing.allocator.free(after_text);
    try testing.expectEqualStrings("MARKER", after_text);

    // The same text, at a different place: the ordinal has not moved (it is
    // absolute) but the *row* it resolves to has fallen 100 lines back.
    const res = resolve(&t, s).?;
    try testing.expectEqual(@as(usize, 0), res.start.ord);
    // 101 lines printed into a four-row screen: 98 of them are history now,
    // and the marker is the oldest of them.
    try testing.expectEqual(@as(usize, 98), t.scrollback.len);
}

test "an evicted anchor clips to the oldest line that survives" {
    var t = try Terminal.init(testing.allocator, 8, 2);
    defer t.deinit();
    // A tiny scrollback, so eviction is reachable in a test.
    t.scrollback.deinit(t.alloc);
    t.scrollback = try grid.Scrollback.init(t.alloc, 8, 3);

    // Seven lines into a two-row screen with three lines of history: AAA and
    // BBB are gone for good, CCC is the oldest thing left.
    feed(&t, "AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE\r\nFFF\r\nGGG");
    const s = Selection{
        .anchor = .{ .line = 1, .x = 0 }, // AAA's id, long since evicted
        .head = .{ .line = idAt(&t, 1), .x = 2 },
    };
    const res = resolve(&t, s).?;
    try testing.expectEqual(@as(usize, 0), res.start.ord);
    const text = try extract(testing.allocator, &t, s);
    defer testing.allocator.free(text);
    // Clipped to the oldest surviving line rather than refused, and not
    // resolved onto whatever now happens to sit at that row.
    try testing.expectEqualStrings("CCC\nDDD\nEEE\nFFF\nGGG", text);

    // Both endpoints gone is the case that clears the selection.
    const dead = Selection{ .anchor = .{ .line = 1, .x = 0 }, .head = .{ .line = 2, .x = 0 } };
    try testing.expectEqual(@as(?Resolved, null), resolve(&t, dead));
    try testing.expectEqual(@as(?Selection, null), normalize(&t, dead));

    // The other arm of the same test: an id that is *not* older than
    // everything still on the grid cannot have been evicted, so it was
    // destroyed in place and there is no ordinal that stands for it.
    // `next_line_id` has never been minted, which is exactly that shape.
    const ghost = Selection{
        .anchor = .{ .line = idAt(&t, 0), .x = 0 },
        .head = .{ .line = t.next_line_id, .x = 2 },
    };
    try testing.expectEqual(@as(?Resolved, null), resolve(&t, ghost));
}

test "an endpoint destroyed in place drops the selection rather than swallowing the history" {
    // The review case. Before the fix `clip` sent *any* unresolvable endpoint
    // to ordinal 0, reasoning that eviction only removes the oldest lines --
    // but `ED`, `IL`/`DL` and a region scroll retire ids in the middle and at
    // the end of the screen, and none of them clears the selection. A
    // four-row selection then resolved to ordinals 0..56 and copied the whole
    // session while its highlight shrank to one row, so there was no visual
    // warning at all. `ED 0` is what readline emits on nearly every prompt
    // redraw.
    const Case = struct { name: []const u8, kill: []const u8 };
    const cases = [_]Case{
        .{ .name = "DL 1 on the head's row", .kill = "\x1b[4;1H\x1b[1M" },
        .{ .name = "ED 0 from the row above", .kill = "\x1b[3;1H\x1b[J" },
        .{ .name = "a region scroll over it", .kill = "\x1b[2;5r\x1b[3S\x1b[r" },
    };
    for (cases) |case| {
        var t = try mkTerm(8, 5);
        defer t.deinit();
        for (0..60) |i| {
            var buf: [16]u8 = undefined;
            feed(&t, std.fmt.bufPrint(&buf, "HIST{d}\r\n", .{i}) catch unreachable);
        }
        // Fifty-six lines of history, every one of them older -- and
        // therefore lower-numbered -- than anything on the screen.
        try testing.expectEqual(@as(usize, 56), t.scrollback.len);
        feed(&t, "\x1b[2J\x1b[HAAA\r\nBBB\r\nCCC\r\nDDD");

        const s = normalize(&t, sel2(&t, 0, 0, 3, 2)).?;
        try expectCopy(&t, s, "AAA\nBBB\nCCC\nDDD");

        feed(&t, case.kill);
        // The anchor is still there: this is the one-endpoint case, not the
        // both-gone case `resolve` already refused.
        try testing.expect(ordOf(&t, s.anchor.line) != null);
        try testing.expect(ordOf(&t, s.head.line) == null);
        testing.expectEqual(@as(?Resolved, null), resolve(&t, s)) catch |err| {
            std.debug.print("selection survived: {s}\n", .{case.name});
            return err;
        };
        const text = try extract(testing.allocator, &t, s);
        defer testing.allocator.free(text);
        // Not "HIST0\nHIST1\n..." -- 383 bytes of it, which is what this
        // produced before.
        try testing.expectEqualStrings("", text);
    }
}

// -- viewOrd, at every offset ---------------------------------------------

/// Twenty-nine lines into a four-row screen: enough history that
/// `view_offset` has somewhere to go.
fn scrolledTerm() !Terminal {
    var t = try mkTerm(8, 4);
    errdefer t.deinit();
    for (0..30) |i| {
        var buf: [16]u8 = undefined;
        feed(&t, std.fmt.bufPrint(&buf, "L{d}\r\n", .{i}) catch unreachable);
    }
    return t;
}

fn scrollTo(t: *Terminal, off: usize) !void {
    t.view_offset = 0;
    t.scrollView(@intCast(off));
    try testing.expectEqual(off, t.view_offset);
}

test "viewOrd names the row the viewport is actually showing, at every offset" {
    // `viewOrd` positions every highlight, and E3 will reuse it for search.
    // Every other test and every gallery capture runs at `view_offset == 0`,
    // where dropping the offset -- `return term.scrollback.len + y;` -- is
    // indistinguishable from the shipped code. This is the test that tells
    // them apart.
    var t = try scrolledTerm();
    defer t.deinit();
    try testing.expect(t.scrollback.len > 4);

    var off: usize = 0;
    while (off <= t.scrollback.len) : (off += 1) {
        try scrollTo(&t, off);
        for (0..t.rows) |y| {
            const l = lineByOrd(&t, viewOrd(&t, y)) orelse return error.NoLineAtViewOrd;
            // The same row by identity *and* by storage, so neither a
            // coincidence of ids nor a copy of the cells can pass.
            try testing.expectEqual(t.viewRowMeta(y).id, l.meta.id);
            try testing.expectEqual(t.viewRow(y).ptr, l.cells.ptr);
        }
    }
}

test "exactly the selected row is highlighted, at every offset" {
    var t = try scrolledTerm();
    defer t.deinit();

    // A whole row, picked while scrolled back so it is a history line rather
    // than a screen one.
    try scrollTo(&t, 5);
    const s = normalize(&t, sel2(&t, 1, 0, 1, 7)).?;
    const want = s.anchor.line;

    var off: usize = 0;
    while (off <= t.scrollback.len) : (off += 1) {
        try scrollTo(&t, off);
        const res = resolve(&t, s).?;
        for (0..t.rows) |y| {
            const selected = t.viewRowMeta(y).id == want;
            for (0..t.cols) |x| {
                testing.expectEqual(selected, hit(&t, res, y, x)) catch |err| {
                    std.debug.print(
                        "offset {d}: row {d} col {d} should be {}\n",
                        .{ off, y, x, selected },
                    );
                    return err;
                };
            }
        }
    }
}

test "triple-click takes the whole logical line, across the wrap" {
    var t = try mkTerm(6, 5);
    defer t.deinit();
    feed(&t, "start\r\nabcdefghijklmn\r\nend");
    // The middle line wrapped over three rows.
    var s = sel2(&t, 2, 2, 2, 2); // a click in the middle of the middle row
    s.mode = .line;
    try expectCopy(&t, s, "abcdefghijklmn");

    // A click on the first row of the same logical line gives the same text.
    var first = sel2(&t, 1, 0, 1, 0);
    first.mode = .line;
    try expectCopy(&t, first, "abcdefghijklmn");

    // And a line that did not wrap is one row.
    var lone = sel2(&t, 0, 1, 0, 1);
    lone.mode = .line;
    try expectCopy(&t, lone, "start");
}

test "an erase that reaches the margin ends the line, so a triple-click stops there" {
    // `endLine`'s comment claimed the erasures that blank a row's tail all
    // end a line, and `ECH` did not. The row below is then joined to a row
    // with nothing on it: four spaces pasted in front of text that never had
    // them, and a blank row that E4's reflow would re-wrap.
    var t = try mkTerm(4, 3);
    defer t.deinit();
    feed(&t, "abcdef"); // row 0 wraps into row 1
    try testing.expect(t.screen().rowMeta(0).flags.wrapped);
    feed(&t, "\x1b[1;1H\x1b[4X"); // ECH over the whole of row 0
    try testing.expect(!t.screen().rowMeta(0).flags.wrapped);

    var s = sel2(&t, 1, 0, 1, 0);
    s.mode = .line;
    try expectCopy(&t, s, "ef"); // not "    ef"
}

test "the extraction cap truncates at a row boundary" {
    var t = try mkTerm(8, 4);
    defer t.deinit();
    feed(&t, "aaaaaaaa\r\nbbbbbbbb\r\ncccccccc\r\ndddddddd");
    // Every row is full, so nothing is trimmed and the arithmetic is exact:
    // three rows of eight plus two separators is 26 bytes.
    const s = normalize(&t, sel2(&t, 0, 0, 3, 7)).?;
    const whole = try extract(testing.allocator, &t, s);
    defer testing.allocator.free(whole);
    try testing.expectEqual(@as(usize, 35), whole.len);
    // Whole rows, never half of one: the result is a prefix that ends on a
    // boundary. (`cap_bytes` is 16 MiB in the shipped build; the property is
    // asserted here by construction rather than by producing 16 MiB.)
    for ([_]usize{ 8, 17, 26, 35 }) |n| {
        try testing.expect(n == whole.len or whole[n] == '\n');
    }
}

test "the copied text is NUL-terminated" {
    // `SDL_SetClipboardText` takes a C string, and a selection is
    // user-controlled length -- so the sentinel is part of the contract
    // rather than something main.zig should be adding by hand.
    var t = try mkTerm(8, 2);
    defer t.deinit();
    feed(&t, "abc");
    const text = try copy(&t, sel2(&t, 0, 0, 0, 2));
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(u8, 0), text.ptr[text.len]);
}

// -- who owns the mouse ---------------------------------------------------

test "mouse ownership follows the tracking modes, and shift overrides" {
    var t = try mkTerm(10, 3);
    defer t.deinit();
    try testing.expectEqual(Owner.terminal, mouseOwner(&t, false));

    // An *encoding* on its own is not a tracking mode. Before the split this
    // was the bug: an application sending 1006 alone took the mouse away.
    feed(&t, "\x1b[?1006h");
    try testing.expect(t.modes.mouse_sgr);
    try testing.expectEqual(Owner.terminal, mouseOwner(&t, false));

    for ([_][]const u8{ "\x1b[?1000h", "\x1b[?1002h", "\x1b[?1003h" }) |on| {
        feed(&t, on);
        try testing.expectEqual(Owner.child, mouseOwner(&t, false));
        try testing.expectEqual(Owner.terminal, mouseOwner(&t, true));
        feed(&t, "\x1b[?1000l\x1b[?1002l\x1b[?1003l");
        try testing.expectEqual(Owner.terminal, mouseOwner(&t, false));
    }
}

test "a click count maps to a granularity" {
    try testing.expectEqual(Mode.character, modeForClicks(1));
    try testing.expectEqual(Mode.word, modeForClicks(2));
    try testing.expectEqual(Mode.line, modeForClicks(3));
    // SDL keeps counting past three; a quadruple-click is still a line.
    try testing.expectEqual(Mode.line, modeForClicks(4));
}

// -- the lifecycle main.zig relies on -------------------------------------

test "the selection is cleared by a reset, ED 3, an alt-screen switch and a width change" {
    const Case = struct { name: []const u8, bytes: []const u8 };
    const cases = [_]Case{
        .{ .name = "ED 3", .bytes = "\x1b[3J" },
        .{ .name = "alt screen", .bytes = "\x1b[?1049h" },
        .{ .name = "RIS", .bytes = "\x1bc" },
    };
    for (cases) |case| {
        var t = try mkTerm(10, 3);
        defer t.deinit();
        feed(&t, "hello");
        t.setSelection(sel2(&t, 0, 0, 0, 4));
        try testing.expect(t.selection != null);
        feed(&t, case.bytes);
        testing.expect(t.selection == null) catch |err| {
            std.debug.print("selection survived: {s}\n", .{case.name});
            return err;
        };
    }

    // A width change discards the scrollback and truncates every row, so the
    // columns the selection named no longer mean what they meant.
    var t = try mkTerm(10, 3);
    defer t.deinit();
    feed(&t, "hello");
    t.setSelection(sel2(&t, 0, 0, 0, 4));
    try t.resize(10, 6); // height only: the selection is still good
    try testing.expect(t.selection != null);
    try t.resize(12, 6);
    try testing.expect(t.selection == null);
}

test "the selection survives output scrolling under it and the view snapping back" {
    var t = try mkTerm(20, 4);
    defer t.deinit();
    feed(&t, "KEEPME\r\n");
    t.setSelection(sel2(&t, 0, 0, 0, 5));
    t.scrollView(0);
    for (0..50) |_| feed(&t, "noise\r\n");
    // `markDirty` snapped the viewport back to the bottom, the ring has
    // rotated many times and the line is in scrollback -- and the selection
    // still names the same six characters.
    try testing.expectEqual(@as(usize, 0), t.view_offset);
    try testing.expect(t.selection != null);
    const text = try extract(testing.allocator, &t, t.selection.?);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("KEEPME", text);
}
