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

pub const Options = struct {
    font_size: u32 = default_font_size,
    shell: ?[:0]const u8 = null,
    frame_stats: bool = false,
    screenshot: ?[:0]const u8 = null,
    cols: u32 = default_cols,
    rows: u32 = default_rows,
};

pub const Size = struct { cols: u32, rows: u32 };

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

pub fn parseFontSize(spec: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, spec, 10) catch return null;
    return std.math.clamp(n, min_font_size, max_font_size);
}

pub const help =
    \\terminator -- a terminal emulator
    \\
    \\  --font-size N   point size, {d}-{d} (default {d})
    \\  --size CxR      initial grid, e.g. 200x60 (default {d}x{d}, max {d})
    \\  --shell PATH    shell to run (default $SHELL)
    \\  --frame-stats   print frame timing to stderr once a second
    \\  --screenshot F  save the frame drawn one second in as a BMP
    \\  -V, --version   print the version and the commit it was built from
    \\  -h, --help      this message
    \\
    \\Keys:
    \\  Cmd +/-/0       font size
    \\  Cmd V           paste
    \\  Cmd K           clear
    \\  Wheel           scroll history
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
        } else if (std.mem.eql(u8, arg, "--size")) {
            i += 1;
            if (i >= argv.len) break;
            if (parseSize(std.mem.span(argv[i]))) |size| {
                opts.cols = size.cols;
                opts.rows = size.rows;
            }
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        }
    }
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

test "argv is parsed into options" {
    const argv = [_][*:0]const u8{
        "terminator", "--size",  "200x60", "--font-size", "18", "--frame-stats",
        "--shell",    "/bin/sh",
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
    const argv = [_][*:0]const u8{ "terminator", "--size" };
    const opts = parseArgs(&argv).run;
    try testing.expectEqual(@as(u32, default_cols), opts.cols);
    try testing.expectEqual(@as(u32, default_rows), opts.rows);
}

test "unknown arguments are ignored" {
    const unknown = [_][*:0]const u8{ "terminator", "--nonsense", "--frame-stats" };
    try testing.expect(parseArgs(&unknown).run.frame_stats);
}

test "--help and --version are reported rather than acted on" {
    // Both win over anything else on the line: someone asking what this
    // is should not have a window opened at them.
    const help_short = [_][*:0]const u8{ "terminator", "-h" };
    try testing.expectEqual(Action.help, parseArgs(&help_short));
    const help_long = [_][*:0]const u8{ "terminator", "--help", "--size", "10x10" };
    try testing.expectEqual(Action.help, parseArgs(&help_long));

    const ver_short = [_][*:0]const u8{ "terminator", "-V" };
    try testing.expectEqual(Action.version, parseArgs(&ver_short));
    const ver_long = [_][*:0]const u8{ "terminator", "--version" };
    try testing.expectEqual(Action.version, parseArgs(&ver_long));
}
