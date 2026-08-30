//! Command-line options.
//!
//! Pure: this file imports nothing but `std`, which is the point of it
//! existing. `main.zig` pulls in the renderer and therefore SDL, so it has
//! no place in the unit-test root -- and an unchecked `--size` accordingly
//! reached `Renderer.init` and overflowed the window width. Anything that
//! turns an argument into a number the renderer will use belongs here,
//! where it can be tested without a window.

const std = @import("std");

pub const default_font_size = 14;
pub const default_cols = 100;
pub const default_rows = 30;

/// Bounds on every argument that reaches the renderer as a dimension.
///
/// The font range is the one `Cmd +`/`Cmd -` already enforces, so the flag
/// cannot ask for a size the keyboard refuses. The grid bound keeps
/// `cols * cell_w + padding` inside an `i32` for any font size in that
/// range, which is the multiplication that overflowed.
pub const min_font_size = 6;
pub const max_font_size = 72;
pub const max_dim = 1000;
/// `--scale` bounds. 1 and 2 are the real displays; the range exists so a
/// gallery capture can ask for a density the machine it runs on does not
/// have, which is the only way 2x captures are reproducible on a CI runner.
pub const min_scale = 0.5;
pub const max_scale = 4.0;

/// The density to rasterize at and to convert pointer coordinates with: the
/// display's, unless `--scale` overrode it.
///
/// It lives here rather than in `render.zig` because it is a rule about the
/// flag, and because `render.zig` `@cImport`s SDL and cannot be unit-tested at
/// all. The rule has to hold **after** `init` as well: a window dragged to a
/// display of a different density re-measures the density, and every mouse
/// coordinate is converted with this number, so a renderer that keeps the one
/// it started with maps clicks to the wrong cells for the rest of the session.
/// Re-measuring must not discard the override, or a gallery capture told to
/// pretend it is on a 2x display would stop pretending the first time the
/// window was measured.
pub fn effectiveScale(override: ?f32, density: f32) f32 {
    return override orelse density;
}

/// How long a recording is kept unless told otherwise. Days, not forever;
/// 0 means forever. Mirrors `rec.default_retain_days`, which this file
/// cannot import without importing libc into the pure-`std` unit.
pub const default_retain_days = 14;

pub const Options = struct {
    font_size: u32 = default_font_size,
    shell: ?[:0]const u8 = null,
    frame_stats: bool = false,
    screenshot: ?[:0]const u8 = null,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
    /// Pretend the display has this pixel density. Null means ask it.
    scale: ?f32 = null,

    // -- selection ------------------------------------------------------

    /// Copy to the clipboard the moment a drag ends, X11-style. Off by
    /// default: it makes every drag overwrite whatever was on the clipboard,
    /// which is a surprise on a Mac. A flag rather than a config key because
    /// there is no config yet; [K0](../docs/roadmap/config.md) absorbs it.
    copy_on_select: bool = false,
    /// `--select R,C,R,C`: select from row R column C to row R column C in
    /// **viewport** coordinates, zero-based, before the screenshot is taken.
    /// It exists so the gallery can photograph a highlight -- there is no
    /// other way to get a selection into a headless capture.
    select: ?Select = null,
    /// `--select-rect`: make `--select` a rectangle, the way `Option`-drag
    /// does. A separate flag rather than a fifth field so the spec keeps its
    /// shape, and order-independent of `--select`.
    select_rect: bool = false,

    // -- recording ------------------------------------------------------
    //
    // On by default, which is only defensible because it is visible: the
    // title says `● rec` for as long as it is happening. See
    // docs/roadmap/record.md and S6 of docs/roadmap/security.md.

    /// Record this session's output. `--no-record` turns it off.
    record: bool = true,
    /// Record nothing at all, and say so in the title. `--incognito`.
    incognito: bool = false,
    /// Record keystrokes too. **Never on unless asked**, because keystrokes
    /// contain passwords and the stream a program printed usually does not.
    record_input: bool = false,
    /// Where recordings go. Null is the platform's data directory.
    record_dir: ?[:0]const u8 = null,
    /// Days to keep a recording. 0 keeps them forever.
    record_retain_days: u32 = default_retain_days,

    // -- seeking --------------------------------------------------------

    /// `--seek N`: before the screenshot, seek to N seconds into the
    /// session's own recording. It exists for the same reason `--select`
    /// does: there is no other way to get a seeked frame into a headless
    /// capture, and a feature the gallery cannot photograph is a feature
    /// nothing is watching.
    seek: ?f64 = null,
    /// `--seek-span N`: seek to the last frame of the Nth alternate-screen
    /// span, counting from the end. 1 is the most recent, which is what
    /// `Cmd ⇧ ↑` does.
    seek_span: ?u32 = null,

    /// Hidden, and not in `--help`: `--seek-status <wall_s>,<behind_s>,<pct>`
    /// composes the status row from fixed times instead of the seek's own.
    ///
    /// A gallery capture is compared pixel for pixel against a committed
    /// PNG, and **every time value in this row is unreproducible**: the clock
    /// is the real time of day, and the bar and the "behind live" figure are
    /// fractions of a session whose length is dominated by however long the
    /// shell took to start -- measured at 5-90 ms of jitter on this machine,
    /// which is more than a bar cell is wide. A capture that differs on every
    /// run is how a gallery stops being read.
    ///
    /// So the three numbers are pinned and nothing else is. The row is still
    /// composed by `seek.statusText`, painted by `seek.paintStatus`, and
    /// drawn as the bottom grid row through the same atlas as every other
    /// row; the title in it is the child's own at that moment, and the frame
    /// under it is the real restored checkpoint. Stated here and in the
    /// sprint record rather than left for the picture to imply.
    seek_status: ?SeekStatus = null,

    /// Hidden, and not in `--help`: after the index is built, seek to N
    /// evenly spaced moments in the session and print the distribution of
    /// what each one cost, end to end.
    ///
    /// The gate says "seek p95 ≤ 150 ms". A p95 needs a sample, and a person
    /// pressing a key ninety-five times is not a measurement. This is the
    /// instrument that produces it, over a real recording, through the same
    /// `seekTo` a key press calls. See the L1 sprint record for the numbers.
    seek_sweep: u32 = 0,

    /// Hidden, and not in `--help`: spawn N threads that do nothing but
    /// parse in a loop.
    ///
    /// L0's record found that an extra busy thread makes the main thread
    /// likelier to be descheduled while it holds the terminal mutex, which is
    /// the one thing the `lock` column exists to watch. L1 adds a worker
    /// thread, so that claim had to be measured rather than assumed -- and
    /// measuring it needs a way to put a busy thread in this process on
    /// purpose. It is a measurement instrument, so it is undocumented rather
    /// than absent: see the L1 sprint record for the numbers it produced.
    busy_threads: u32 = 0,

    /// What the title should say about this session, given the flags. The
    /// runtime state (`Cmd ⇧ R`) can move `record_input` after this.
    pub fn recordState(self: Options) RecordState {
        if (self.incognito) return .incognito;
        if (!self.record) return .off;
        return if (self.record_input) .output_and_input else .output;
    }
};

pub const Size = struct { cols: u32, rows: u32 };

/// A viewport-coordinate selection, zero-based and inclusive at both ends --
/// the same convention `sel.Point` uses.
pub const Select = struct { r0: u32, c0: u32, r1: u32, c1: u32 };

/// `"R,C,R,C"`, or null when it is not that shape.
///
/// Declined whole rather than in part, for the reason `parseSize` is: three
/// of four numbers is not a selection anyone meant.
pub fn parseSelect(spec: []const u8) ?Select {
    var it = std.mem.splitScalar(u8, spec, ',');
    var n: [4]u32 = undefined;
    for (&n) |*v| {
        const field = it.next() orelse return null;
        v.* = std.fmt.parseInt(u32, field, 10) catch return null;
    }
    if (it.next() != null) return null;
    return .{ .r0 = n[0], .c0 = n[1], .r1 = n[2], .c1 = n[3] };
}

fn clampDim(n: u32) u32 {
    return std.math.clamp(n, 1, max_dim);
}

/// `"COLSxROWS"` as a clamped pair, or null when it is not that shape.
///
/// A malformed spec leaves *both* defaults alone rather than applying the
/// half it could read: `--size 80xwide` meaning "80 columns and whatever
/// number of rows you like" would be a worse guess than declining.
pub fn parseSize(spec: []const u8) ?Size {
    const x = std.mem.indexOfScalar(u8, spec, 'x') orelse return null;
    const cols = std.fmt.parseInt(u32, spec[0..x], 10) catch return null;
    const rows = std.fmt.parseInt(u32, spec[x + 1 ..], 10) catch return null;
    return .{ .cols = clampDim(cols), .rows = clampDim(rows) };
}

pub fn parseScale(spec: []const u8) ?f32 {
    const n = std.fmt.parseFloat(f32, spec) catch return null;
    if (std.math.isNan(n)) return null;
    return std.math.clamp(n, min_scale, max_scale);
}

pub fn parseFontSize(spec: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, spec, 10) catch return null;
    return std.math.clamp(n, min_font_size, max_font_size);
}

/// A bound on the measurement instrument, for the reason `--size` has one:
/// a flag that reaches a resource allocator needs a number it cannot exceed,
/// however unlikely anybody is to type it.
pub const max_busy_threads = 16;
/// And on the seek sweep, for the same reason: it allocates nothing, but a
/// flag that drives a loop should not be able to ask for four billion of it.
pub const max_seek_sweep = 10_000;

/// The pinned time values of `--seek-status`. See `Options.seek_status`.
pub const SeekStatus = struct { wall_s: i64, behind_s: u64, percent: u8 };

/// `<wall_s>,<behind_s>,<percent>`. All three or none: a partially pinned row
/// would be reproducible in some columns and not others, which is the worst
/// of both.
pub fn parseSeekStatus(spec: []const u8) ?SeekStatus {
    var it = std.mem.splitScalar(u8, spec, ',');
    const wall = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const behind = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const pct = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    if (pct > 100) return null;
    return .{ .wall_s = wall, .behind_s = behind, .percent = pct };
}

/// `--seek N`, in seconds. Negative counts back from the end of the session,
/// which is how "show me the last ten seconds" is spelled without knowing how
/// long the session was.
pub fn parseSeconds(spec: []const u8) ?f64 {
    const n = std.fmt.parseFloat(f64, spec) catch return null;
    if (std.math.isNan(n) or std.math.isInf(n)) return null;
    return n;
}

// ---------------------------------------------------------------------------
// The recording indicator
// ---------------------------------------------------------------------------

/// What a session is recording, as far as the window title is concerned.
pub const RecordState = enum {
    /// `--no-record`. Nothing is written, and the title says nothing: the
    /// user asked for it off and does not need to be told about it again.
    off,
    /// `--incognito`. Nothing is written, and the title says so, because a
    /// tab that is deliberately not recording is worth being able to see.
    incognito,
    /// The default. Output only.
    output,
    /// Output and keystrokes.
    output_and_input,
};

/// The window title: the child's title with the recording state appended.
///
/// Recording is on by default, and the objection to any on-by-default
/// recorder is that it is invisible. There is no chrome in this terminal yet
/// -- no tab strip, no status line, nothing to hang an indicator on -- and
/// the window title is the one surface that exists today. So the indicator
/// lives here, and `Cmd ⇧ R` moves it in the same frame, which is what makes
/// it an indicator rather than a decoration.
///
/// Pure, and here rather than in `main.zig`, for the reason at the top of
/// this file: `main.zig` pulls in SDL, so nothing in it can be tested without
/// a window. `main.zig` keeps the `setTitle` call, which is glue.
///
/// The result is written into `buf` and never exceeds it. When `base` is too
/// long, the base is what gets cut -- the indicator is the part that must not
/// be lost -- and the cut lands on a UTF-8 boundary, because half a
/// codepoint in a title bar is a visible mistake.
/// While seeking, the indicator is the *seek marker* rather than `● rec`:
/// the window is not showing the live session, and saying "rec" over a
/// historical frame would be describing the wrong thing. The one state that
/// survives is `● rec+input`, because S6 requires the keystroke indicator to
/// be visible whenever keystrokes are being recorded, and seeking does not
/// stop that.
pub fn windowTitle(
    buf: []u8,
    base: []const u8,
    state: RecordState,
    seek_marker: ?[]const u8,
) []const u8 {
    var suffix_buf: [64]u8 = undefined;
    const suffix = if (seek_marker) |m| blk: {
        if (state != .output_and_input) break :blk m;
        break :blk std.fmt.bufPrint(&suffix_buf, "● rec+input -- {s}", .{m}) catch m;
    } else switch (state) {
        .off => "",
        .incognito => "incognito",
        .output => "● rec",
        .output_and_input => "● rec+input",
    };
    if (suffix.len == 0) {
        const n = @min(base.len, buf.len);
        const cut = utf8Floor(base, n);
        @memcpy(buf[0..cut], base[0..cut]);
        return buf[0..cut];
    }

    const sep = " -- ";
    // No child title yet -- a freshly opened window, before the shell has
    // said anything. Leading separator with nothing before it reads as a
    // mistake, so the indicator stands alone.
    if (base.len == 0) return copyFloor(buf, suffix);

    const tail = sep.len + suffix.len;
    // Not even room for the separator and the indicator: the indicator is
    // what matters, so it takes the whole buffer.
    if (buf.len <= tail) return copyFloor(buf, suffix);

    const room = buf.len - tail;
    const cut = utf8Floor(base, @min(base.len, room));
    @memcpy(buf[0..cut], base[0..cut]);
    @memcpy(buf[cut..][0..sep.len], sep);
    @memcpy(buf[cut + sep.len ..][0..suffix.len], suffix);
    return buf[0 .. cut + tail];
}

/// As much of `s` as fits in `buf`, cut on a codepoint boundary.
fn copyFloor(buf: []u8, s: []const u8) []const u8 {
    const n = utf8Floor(s, @min(s.len, buf.len));
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// The largest length no greater than `n` that does not split a codepoint.
fn utf8Floor(s: []const u8, n: usize) usize {
    var i = @min(n, s.len);
    // Continuation bytes are 0b10xxxxxx; back up over any of them.
    while (i > 0 and (s[i - 1] & 0xc0) == 0x80) i -= 1;
    if (i == 0) return 0;
    // And over the lead byte itself, if the sequence it starts is not whole.
    const lead = s[i - 1];
    const need: usize = if (lead < 0x80) 1 else if (lead >= 0xf0) 4 else if (lead >= 0xe0) 3 else if (lead >= 0xc0) 2 else 1;
    const have = @min(n, s.len) - (i - 1);
    return if (have >= need) @min(n, s.len) else i - 1;
}

pub const help =
    \\doot -- a terminal emulator
    \\
    \\  --font-size N   point size, {d}-{d} (default {d})
    \\  --size CxR      initial grid, e.g. 200x60 (default {d}x{d}, max {d})
    \\  --shell PATH    shell to run (default $SHELL)
    \\  --frame-stats   print frame timing to stderr once a second
    \\  --scale N       pretend the display has this pixel density (1, 2)
    \\  --screenshot F  save the frame drawn one second in as a PNG
    \\  --copy-on-select  copy to the clipboard as soon as a drag ends
    \\  --select R,C,R,C  select these viewport cells (0-based, inclusive);
    \\                  for taking a picture of a highlight
    \\  --select-rect   make --select a rectangle, as Option-drag does
    \\  -V, --version   print the version and the commit it was built from
    \\  -h, --help      this message
    \\
    \\Recording (the session's output is recorded by default, and the title
    \\says so for as long as it is happening):
    \\  --no-record            do not record this session
    \\  --incognito            record nothing, and say so in the title
    \\  --record-input         record keystrokes too (off unless asked)
    \\  --record-dir PATH      where recordings go
    \\  --record-retain-days N delete recordings older than this (default {d},
    \\                         0 keeps them forever)
    \\
    \\Seeking (the window shows a moment in the session's own recording; the
    \\live terminal keeps running behind it and the child never notices):
    \\  --seek N               seek N seconds in before the screenshot;
    \\                         negative counts back from the end
    \\  --seek-span N          seek to the last frame of the Nth most recent
    \\                         full-screen program (1 is the latest)
    \\
    \\Keys:
    \\  Cmd +/-/0       font size
    \\  Cmd C           copy the selection
    \\  Cmd V           paste
    \\  Cmd K           clear
    \\  Cmd Shift R     start/stop recording keystrokes
    \\  Cmd Shift Up    the last frame of the previous full-screen program
    \\  Cmd Shift Down  the next one
    \\  Cmd Shift Left/Right   step 1 second (10 with Option)
    \\  Esc             back to live -- as does typing anything printable
    \\  Wheel           scroll history
    \\
    \\Mouse:
    \\  Drag            select; double-click a word, triple-click a line
    \\  Shift-click     extend the selection
    \\  Option-drag     select a rectangle
    \\
;

/// What the arguments asked for. `--help` and `--version` are returned
/// rather than acted on, so that this file never calls `std.process.exit`
/// -- which would take the tests with it.
pub const Action = union(enum) {
    run: Options,
    help,
    version,
};

pub fn parseArgs(argv: []const [*:0]const u8) Action {
    // A first pass, so that these two really do win over everything else.
    // The main loop below consumes the token after a value-taking flag, so
    // `--shell --version` would otherwise take "--version" as the shell
    // path and go on to open a window and try to exec it. Asking a program
    // what it is should never open a window.
    if (argv.len > 1) for (argv[1..]) |raw| {
        const arg = std.mem.span(raw);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return .version;
    };

    var opts = Options{};
    var i: usize = 1; // skip argv[0]

    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--font-size")) {
            i += 1;
            if (i >= argv.len) break;
            opts.font_size = parseFontSize(std.mem.span(argv[i])) orelse opts.font_size;
        } else if (std.mem.eql(u8, arg, "--shell")) {
            i += 1;
            if (i >= argv.len) break;
            opts.shell = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--frame-stats")) {
            opts.frame_stats = true;
        } else if (std.mem.eql(u8, arg, "--screenshot")) {
            i += 1;
            if (i >= argv.len) break;
            opts.screenshot = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--scale")) {
            i += 1;
            if (i >= argv.len) break;
            opts.scale = parseScale(std.mem.span(argv[i])) orelse opts.scale;
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= argv.len) break;
            if (parseSize(std.mem.span(argv[i]))) |size| {
                opts.cols = size.cols;
                opts.rows = size.rows;
            }
        } else if (std.mem.eql(u8, arg, "--copy-on-select")) {
            opts.copy_on_select = true;
        } else if (std.mem.eql(u8, arg, "--select")) {
            i += 1;
            if (i >= argv.len) break;
            opts.select = parseSelect(std.mem.span(argv[i])) orelse opts.select;
        } else if (std.mem.eql(u8, arg, "--select-rect")) {
            opts.select_rect = true;
        } else if (std.mem.eql(u8, arg, "--no-record")) {
            opts.record = false;
        } else if (std.mem.eql(u8, arg, "--incognito")) {
            // Both, so that nothing downstream has to remember that
            // incognito implies not recording.
            opts.incognito = true;
            opts.record = false;
        } else if (std.mem.eql(u8, arg, "--record-input")) {
            opts.record_input = true;
        } else if (std.mem.eql(u8, arg, "--record-dir")) {
            i += 1;
            if (i >= argv.len) break;
            opts.record_dir = std.mem.span(argv[i]);
        } else if (std.mem.eql(u8, arg, "--record-retain-days")) {
            i += 1;
            if (i >= argv.len) break;
            opts.record_retain_days = std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch
                opts.record_retain_days;
        } else if (std.mem.eql(u8, arg, "--seek")) {
            i += 1;
            if (i >= argv.len) break;
            opts.seek = parseSeconds(std.mem.span(argv[i])) orelse opts.seek;
        } else if (std.mem.eql(u8, arg, "--seek-span")) {
            i += 1;
            if (i >= argv.len) break;
            opts.seek_span = std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch
                opts.seek_span;
        } else if (std.mem.eql(u8, arg, "--seek-status")) {
            i += 1;
            if (i >= argv.len) break;
            opts.seek_status = parseSeekStatus(std.mem.span(argv[i])) orelse opts.seek_status;
        } else if (std.mem.eql(u8, arg, "--seek-sweep")) {
            i += 1;
            if (i >= argv.len) break;
            opts.seek_sweep = @min(
                std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch 0,
                max_seek_sweep,
            );
        } else if (std.mem.eql(u8, arg, "--busy-threads")) {
            i += 1;
            if (i >= argv.len) break;
            opts.busy_threads = @min(
                std.fmt.parseInt(u32, std.mem.span(argv[i]), 10) catch 0,
                max_busy_threads,
            );
        }
    }

    // `--record-input --incognito`, in either order, records nothing.
    // Recording input into a session that is not being recorded is not a
    // state anything downstream should have to reason about.
    if (!opts.record) opts.record_input = false;
    return .{ .run = opts };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a size spec parses into a grid" {
    const got = parseSize("200x60").?;
    try testing.expectEqual(@as(u32, 200), got.cols);
    try testing.expectEqual(@as(u32, 60), got.rows);
}

test "a size spec is clamped at both ends" {
    // The regression: `init_cols * cell_w + pad * 2` is computed as a u32
    // and cast to i32, so a large enough column count panicked on overflow
    // inside Renderer.init before it could draw anything.
    const huge = parseSize("4000000000x30").?;
    try testing.expectEqual(@as(u32, max_dim), huge.cols);
    try testing.expectEqual(@as(u32, 30), huge.rows);

    const zero = parseSize("0x0").?;
    try testing.expectEqual(@as(u32, 1), zero.cols);
    try testing.expectEqual(@as(u32, 1), zero.rows);

    // Past what a u32 can hold at all, so parseInt itself refuses.
    try testing.expectEqual(@as(?Size, null), parseSize("99999999999x30"));
}

test "a malformed size spec is declined whole" {
    try testing.expectEqual(@as(?Size, null), parseSize("80"));
    try testing.expectEqual(@as(?Size, null), parseSize("80xwide"));
    try testing.expectEqual(@as(?Size, null), parseSize("widex24"));
    try testing.expectEqual(@as(?Size, null), parseSize(""));
    try testing.expectEqual(@as(?Size, null), parseSize("x"));
    try testing.expectEqual(@as(?Size, null), parseSize("-5x10"));
}

test "font size is held to the range the keyboard enforces" {
    try testing.expectEqual(@as(?u32, 18), parseFontSize("18"));
    try testing.expectEqual(@as(?u32, max_font_size), parseFontSize("100000"));
    try testing.expectEqual(@as(?u32, min_font_size), parseFontSize("1"));
    try testing.expectEqual(@as(?u32, null), parseFontSize("big"));
}

test "scale is parsed and bounded" {
    try testing.expectEqual(@as(?f32, 2.0), parseScale("2"));
    try testing.expectEqual(@as(?f32, 1.5), parseScale("1.5"));
    try testing.expectEqual(@as(?f32, max_scale), parseScale("99"));
    try testing.expectEqual(@as(?f32, min_scale), parseScale("0.01"));
    try testing.expectEqual(@as(?f32, null), parseScale("big"));
    try testing.expectEqual(@as(?f32, null), parseScale("nan"));
    // Unset means "ask the display", which is not the same as 1.
    const bare = [_][*:0]const u8{"doot"};
    try testing.expectEqual(@as(?f32, null), parseArgs(&bare).run.scale);
    const given = [_][*:0]const u8{ "doot", "--scale", "2" };
    try testing.expectEqual(@as(?f32, 2.0), parseArgs(&given).run.scale);
}

test "the effective scale follows the display, and --scale outranks it" {
    // `Renderer.scale` converts every mouse coordinate, and `updateSize` is
    // where a window that moved between displays re-measures. Unset, the
    // answer has to *move* with the display -- keeping the density measured
    // at startup maps clicks to the wrong cells for the rest of the session.
    try testing.expectEqual(@as(f32, 1.0), effectiveScale(null, 1.0));
    try testing.expectEqual(@as(f32, 2.0), effectiveScale(null, 2.0));
    // Given, it must not move, however often the density is re-measured, or
    // the gallery's 2x captures would stop pretending on a 1x runner.
    for ([_]f32{ 1.0, 2.0, 1.0, 3.0 }) |density| {
        try testing.expectEqual(@as(f32, 2.0), effectiveScale(2.0, density));
    }
}

test "argv is parsed into options" {
    const argv = [_][*:0]const u8{
        "doot",    "--size",  "200x60", "--font-size", "18", "--frame-stats",
        "--shell", "/bin/sh",
    };
    const opts = parseArgs(&argv).run;
    try testing.expectEqual(@as(u32, 200), opts.cols);
    try testing.expectEqual(@as(u32, 60), opts.rows);
    try testing.expectEqual(@as(u32, 18), opts.font_size);
    try testing.expect(opts.frame_stats);
    try testing.expectEqualStrings("/bin/sh", opts.shell.?);
    try testing.expectEqual(@as(?[:0]const u8, null), opts.screenshot);
}

test "a flag missing its value stops rather than reading past the end" {
    const argv = [_][*:0]const u8{ "doot", "--size" };
    const opts = parseArgs(&argv).run;
    try testing.expectEqual(@as(u32, default_cols), opts.cols);
    try testing.expectEqual(@as(u32, default_rows), opts.rows);
}

test "unknown arguments are ignored" {
    const unknown = [_][*:0]const u8{ "doot", "--nonsense", "--frame-stats" };
    try testing.expect(parseArgs(&unknown).run.frame_stats);
}

test "--help and --version are reported rather than acted on" {
    // Both win over anything else on the line: someone asking what this
    // is should not have a window opened at them.
    const help_short = [_][*:0]const u8{ "doot", "-h" };
    try testing.expectEqual(Action.help, parseArgs(&help_short));
    const help_long = [_][*:0]const u8{ "doot", "--help", "--size", "10x10" };
    try testing.expectEqual(Action.help, parseArgs(&help_long));

    const ver_short = [_][*:0]const u8{ "doot", "-V" };
    try testing.expectEqual(Action.version, parseArgs(&ver_short));
    const ver_long = [_][*:0]const u8{ "doot", "--version" };
    try testing.expectEqual(Action.version, parseArgs(&ver_long));
}

test "--help and --version win even after a flag that takes a value" {
    // The regression this guards: the main loop consumes the token after
    // `--shell`, so these used to be swallowed as a shell path or a size,
    // and the program opened a window and tried to exec `--version`.
    const shell = [_][*:0]const u8{ "doot", "--shell", "--version" };
    try testing.expectEqual(Action.version, parseArgs(&shell));
    const size = [_][*:0]const u8{ "doot", "--size", "--help" };
    try testing.expectEqual(Action.help, parseArgs(&size));
    const shot = [_][*:0]const u8{ "doot", "--screenshot", "-h" };
    try testing.expectEqual(Action.help, parseArgs(&shot));
    const font = [_][*:0]const u8{ "doot", "--font-size", "-V" };
    try testing.expectEqual(Action.version, parseArgs(&font));
}

// -- recording flags and the indicator ------------------------------------

test "recording is on, and output-only, with no flags at all" {
    // The default the whole privacy shape rests on: output yes, keystrokes
    // no. If this test ever has to be changed, S6 of the security roadmap
    // has been changed with it.
    const bare = [_][*:0]const u8{"doot"};
    const opts = parseArgs(&bare).run;
    try testing.expect(opts.record);
    try testing.expect(!opts.record_input);
    try testing.expect(!opts.incognito);
    try testing.expectEqual(RecordState.output, opts.recordState());
    try testing.expectEqual(@as(u32, default_retain_days), opts.record_retain_days);
}

test "the recording flags parse" {
    const argv = [_][*:0]const u8{
        "doot",                 "--record-input", "--record-dir", "/tmp/rec",
        "--record-retain-days", "3",
    };
    const opts = parseArgs(&argv).run;
    try testing.expect(opts.record);
    try testing.expect(opts.record_input);
    try testing.expectEqualStrings("/tmp/rec", opts.record_dir.?);
    try testing.expectEqual(@as(u32, 3), opts.record_retain_days);
    try testing.expectEqual(RecordState.output_and_input, opts.recordState());

    const none = [_][*:0]const u8{ "doot", "--no-record" };
    try testing.expectEqual(RecordState.off, parseArgs(&none).run.recordState());

    const incog = [_][*:0]const u8{ "doot", "--incognito" };
    const i = parseArgs(&incog).run;
    try testing.expect(!i.record);
    try testing.expectEqual(RecordState.incognito, i.recordState());

    // Zero is a real value -- keep forever -- not a parse failure.
    const forever = [_][*:0]const u8{ "doot", "--record-retain-days", "0" };
    try testing.expectEqual(@as(u32, 0), parseArgs(&forever).run.record_retain_days);
    // And an unreadable one leaves the default rather than meaning zero.
    const junk = [_][*:0]const u8{ "doot", "--record-retain-days", "soon" };
    try testing.expectEqual(@as(u32, default_retain_days), parseArgs(&junk).run.record_retain_days);
}

test "asking to record input into a session that is not recorded records nothing" {
    // In either order. Two flags that contradict each other must resolve to
    // the private answer, not to whichever came last.
    const a = [_][*:0]const u8{ "doot", "--record-input", "--incognito" };
    const b = [_][*:0]const u8{ "doot", "--incognito", "--record-input" };
    const c = [_][*:0]const u8{ "doot", "--record-input", "--no-record" };
    for ([_][]const [*:0]const u8{ &a, &b, &c }) |argv| {
        const opts = parseArgs(argv).run;
        try testing.expect(!opts.record);
        try testing.expect(!opts.record_input);
    }
}

test "the title says what is being recorded, in every state" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("zsh", windowTitle(&buf, "zsh", .off, null));
    try testing.expectEqualStrings("zsh -- incognito", windowTitle(&buf, "zsh", .incognito, null));
    try testing.expectEqualStrings("zsh -- ● rec", windowTitle(&buf, "zsh", .output, null));
    try testing.expectEqualStrings("zsh -- ● rec+input", windowTitle(&buf, "zsh", .output_and_input, null));
}

test "the indicator stands alone before the child has set a title" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("", windowTitle(&buf, "", .off, null));
    try testing.expectEqualStrings("incognito", windowTitle(&buf, "", .incognito, null));
    try testing.expectEqualStrings("● rec", windowTitle(&buf, "", .output, null));
    try testing.expectEqualStrings("● rec+input", windowTitle(&buf, "", .output_and_input, null));
}

test "a long title is cut, and the indicator is not" {
    // The indicator is the part that must survive: a title bar that dropped
    // the "recording" half to fit a path would be worse than useless.
    var buf: [32]u8 = undefined;
    const long = "a very long child title indeed that goes on";
    const got = windowTitle(&buf, long, .output, null);
    try testing.expect(got.len <= buf.len);
    try testing.expect(std.mem.endsWith(u8, got, "● rec"));
    try testing.expect(std.mem.startsWith(u8, got, "a very long"));

    // And when there is no room for even the separator, the indicator wins.
    var tiny: [7]u8 = undefined; // exactly "● rec": the dot is three bytes
    try testing.expectEqualStrings("● rec", windowTitle(&tiny, long, .output, null));
    // And smaller still: whatever comes back is valid UTF-8, never half a
    // dot. A title bar showing a replacement glyph reads as our bug.
    var i: usize = 0;
    while (i <= 8) : (i += 1) {
        var tinier: [8]u8 = undefined;
        const squeezed = windowTitle(tinier[0..i], long, .output, null);
        try testing.expect(squeezed.len <= i);
        try testing.expect(std.unicode.utf8ValidateSlice(squeezed));
    }
}

test "cutting a long title never splits a codepoint" {
    // A title is child-controlled and can be any bytes at all. Half a
    // codepoint in a title bar renders as a replacement glyph, which reads
    // as a bug in the terminal rather than in the title.
    const emoji = "🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀";
    var i: usize = 1;
    while (i <= 64) : (i += 1) {
        var buf: [64]u8 = undefined;
        const got = windowTitle(buf[0..i], emoji, .output, null);
        try testing.expect(got.len <= i);
        try testing.expect(std.unicode.utf8ValidateSlice(got));
    }

    // Also with the indicator off, where the whole buffer is the title.
    i = 1;
    while (i <= 64) : (i += 1) {
        var buf: [64]u8 = undefined;
        const got = windowTitle(buf[0..i], emoji, .off, null);
        try testing.expect(std.unicode.utf8ValidateSlice(got));
    }
}

test "argv with no arguments at all is a plain run" {
    const bare = [_][*:0]const u8{"doot"};
    try testing.expectEqual(@as(u32, default_cols), parseArgs(&bare).run.cols);
    const empty: [0][*:0]const u8 = .{};
    try testing.expectEqual(@as(u32, default_cols), parseArgs(&empty).run.cols);
}

// -- selection flags ------------------------------------------------------

test "a select spec parses into four viewport coordinates" {
    const got = parseSelect("3,10,5,20").?;
    try testing.expectEqual(@as(u32, 3), got.r0);
    try testing.expectEqual(@as(u32, 10), got.c0);
    try testing.expectEqual(@as(u32, 5), got.r1);
    try testing.expectEqual(@as(u32, 20), got.c1);
    // Zero is a coordinate, not a failure.
    try testing.expectEqual(Select{ .r0 = 0, .c0 = 0, .r1 = 0, .c1 = 0 }, parseSelect("0,0,0,0").?);
}

test "a malformed select spec is declined whole" {
    for ([_][]const u8{ "", "3", "3,10", "3,10,5", "3,10,5,20,7", "a,b,c,d", "3,10,5,-1", "3,,5,20" }) |bad| {
        try testing.expectEqual(@as(?Select, null), parseSelect(bad));
    }
}

test "the selection flags parse, and default off" {
    const bare = [_][*:0]const u8{"doot"};
    const none = parseArgs(&bare).run;
    try testing.expect(!none.copy_on_select);
    try testing.expectEqual(@as(?Select, null), none.select);

    try testing.expect(!parseArgs(&[_][*:0]const u8{"doot"}).run.select_rect);
    const rect = [_][*:0]const u8{ "doot", "--select-rect", "--select", "1,2,3,4" };
    const rect_opts = parseArgs(&rect).run;
    // Order-independent of `--select`, which is why it is a flag of its own.
    try testing.expect(rect_opts.select_rect);
    try testing.expectEqual(@as(u32, 1), rect_opts.select.?.r0);

    const argv = [_][*:0]const u8{ "doot", "--copy-on-select", "--select", "1,2,3,4" };
    const opts = parseArgs(&argv).run;
    try testing.expect(opts.copy_on_select);
    try testing.expectEqual(@as(u32, 4), opts.select.?.c1);
}

test "the seek flags parse, and default off" {
    const bare = parseArgs(&[_][*:0]const u8{"doot"}).run;
    try testing.expectEqual(@as(?f64, null), bare.seek);
    try testing.expectEqual(@as(?u32, null), bare.seek_span);
    try testing.expectEqual(@as(?SeekStatus, null), bare.seek_status);
    try testing.expectEqual(@as(u32, 0), bare.busy_threads);

    const argv = [_][*:0]const u8{ "doot", "--seek", "-12.5", "--seek-span", "2" };
    const opts = parseArgs(&argv).run;
    // Negative counts back from the end, which is how "the last twelve
    // seconds" is spelled without knowing how long the session was.
    try testing.expectEqual(@as(f64, -12.5), opts.seek.?);
    try testing.expectEqual(@as(u32, 2), opts.seek_span.?);

    // A number that cannot be a position in time is declined rather than
    // turned into a seek to somewhere arbitrary.
    for ([_][]const u8{ "nan", "inf", "-inf", "later", "" }) |spec| {
        try testing.expectEqual(@as(?f64, null), parseSeconds(spec));
    }
    try testing.expectEqual(@as(f64, 0), parseSeconds("0").?);
}

test "the pinned status row takes all three values or none" {
    const ok = parseSeekStatus("43391,272,42").?;
    try testing.expectEqual(@as(i64, 43391), ok.wall_s);
    try testing.expectEqual(@as(u64, 272), ok.behind_s);
    try testing.expectEqual(@as(u8, 42), ok.percent);

    // Partly pinned would be reproducible in some columns of the capture and
    // not others, which is worse than either. So: all three or nothing.
    for ([_][]const u8{
        "43391",
        "43391,272",
        "43391,272,42,1",
        "43391,272,101",
        "43391,272,x",
        ",,",
        "",
    }) |spec| {
        try testing.expectEqual(@as(?SeekStatus, null), parseSeekStatus(spec));
    }

    const argv = [_][*:0]const u8{ "doot", "--seek-status", "1,2,3" };
    const opts = parseArgs(&argv).run;
    try testing.expectEqual(@as(u8, 3), opts.seek_status.?.percent);
}

test "the busy-thread instrument is bounded" {
    // It reaches a resource allocator, so it needs a number it cannot
    // exceed -- the same reason `--size` has one.
    const many = [_][*:0]const u8{ "doot", "--busy-threads", "100000" };
    try testing.expectEqual(max_busy_threads, parseArgs(&many).run.busy_threads);
    const junk = [_][*:0]const u8{ "doot", "--busy-threads", "lots" };
    try testing.expectEqual(@as(u32, 0), parseArgs(&junk).run.busy_threads);
}
