//! Turning keystrokes into the bytes a Unix program expects.
//!
//! Deliberately independent of SDL: this takes an abstract key and produces
//! bytes, so the encoding rules -- which are fiddly, ancient, and the source
//! of most "why doesn't Ctrl-Left work in tmux" bugs -- can be unit tested
//! without opening a window.

const std = @import("std");

pub const Key = union(enum) {
    up,
    down,
    right,
    left,
    home,
    end,
    page_up,
    page_down,
    insert,
    delete,
    backspace,
    tab,
    enter,
    escape,
    /// Function key, 1-based.
    f: u8,
    /// A printable character, already resolved for shift/layout.
    char: u21,
};

pub const Mods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    fn any(self: Mods) bool {
        return self.ctrl or self.alt or self.shift;
    }

    /// xterm's modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
    fn param(self: Mods) u8 {
        var v: u8 = 1;
        if (self.shift) v += 1;
        if (self.alt) v += 2;
        if (self.ctrl) v += 4;
        return v;
    }
};

/// Encode `key` into `buf`, returning the slice to send to the PTY, or null
/// if the key produces nothing.
pub fn encode(buf: []u8, key: Key, mods: Mods, app_cursor: bool) ?[]const u8 {
    return switch (key) {
        .up => cursorKey(buf, 'A', mods, app_cursor),
        .down => cursorKey(buf, 'B', mods, app_cursor),
        .right => cursorKey(buf, 'C', mods, app_cursor),
        .left => cursorKey(buf, 'D', mods, app_cursor),
        .home => cursorKey(buf, 'H', mods, app_cursor),
        .end => cursorKey(buf, 'F', mods, app_cursor),
        .insert => tildeKey(buf, 2, mods),
        .delete => tildeKey(buf, 3, mods),
        .page_up => tildeKey(buf, 5, mods),
        .page_down => tildeKey(buf, 6, mods),
        .enter => alted(buf, "\r", mods),
        .escape => alted(buf, "\x1b", mods),
        .tab => if (mods.shift) copy(buf, "\x1b[Z") else alted(buf, "\t", mods),
        // Terminals send DEL (0x7f) for backspace; BS (0x08) is what most
        // shells map to "delete previous word" via Ctrl.
        .backspace => alted(buf, if (mods.ctrl) "\x08" else "\x7f", mods),
        .f => |n| functionKey(buf, n, mods),
        .char => |cp| character(buf, cp, mods),
    };
}

fn copy(buf: []u8, bytes: []const u8) ?[]const u8 {
    if (bytes.len > buf.len) return null;
    @memcpy(buf[0..bytes.len], bytes);
    return buf[0..bytes.len];
}

/// Prefix with ESC when Alt is held -- the traditional "meta sends escape".
fn alted(buf: []u8, bytes: []const u8, mods: Mods) ?[]const u8 {
    if (!mods.alt) return copy(buf, bytes);
    if (bytes.len + 1 > buf.len) return null;
    buf[0] = 0x1b;
    @memcpy(buf[1 .. 1 + bytes.len], bytes);
    return buf[0 .. 1 + bytes.len];
}

fn cursorKey(buf: []u8, final: u8, mods: Mods, app_cursor: bool) ?[]const u8 {
    if (mods.any()) {
        // Modified cursor keys always use the CSI form with a parameter,
        // even in application mode.
        return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mods.param(), final }) catch null;
    }
    // Application cursor mode swaps CSI for SS3; readline and vim care.
    const intro: u8 = if (app_cursor) 'O' else '[';
    return std.fmt.bufPrint(buf, "\x1b{c}{c}", .{ intro, final }) catch null;
}

fn tildeKey(buf: []u8, n: u8, mods: Mods) ?[]const u8 {
    if (mods.any()) {
        return std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, mods.param() }) catch null;
    }
    return std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch null;
}

fn functionKey(buf: []u8, n: u8, mods: Mods) ?[]const u8 {
    // F1-F4 are SS3; F5 and up use CSI with historical, non-contiguous
    // numbers (there is no 16, 22 -- that's just how DEC numbered them).
    const tilde_codes = [_]u8{ 15, 17, 18, 19, 20, 21, 23, 24 };
    if (n >= 1 and n <= 4) {
        const final: u8 = "PQRS"[n - 1];
        if (mods.any()) {
            return std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ mods.param(), final }) catch null;
        }
        return std.fmt.bufPrint(buf, "\x1bO{c}", .{final}) catch null;
    }
    if (n >= 5 and n <= 12) return tildeKey(buf, tilde_codes[n - 5], mods);
    return null;
}

fn character(buf: []u8, cp: u21, mods: Mods) ?[]const u8 {
    if (mods.ctrl) {
        if (controlByte(cp)) |b| return alted(buf, &[_]u8{b}, mods);
        // Ctrl with a key that has no control code: send it unmodified
        // rather than swallowing it.
    }
    var utf8: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &utf8) catch return null;
    return alted(buf, utf8[0..n], mods);
}

/// The ASCII control code for Ctrl+<key>, if one exists.
fn controlByte(cp: u21) ?u8 {
    return switch (cp) {
        'a'...'z' => @intCast(cp - 'a' + 1),
        'A'...'Z' => @intCast(cp - 'A' + 1),
        ' ', '@' => 0, // Ctrl-Space and Ctrl-@ both send NUL
        '[' => 0x1b,
        '\\' => 0x1c,
        ']' => 0x1d,
        '^' => 0x1e,
        '_', '/' => 0x1f,
        '?' => 0x7f,
        else => null,
    };
}

/// Wrap pasted text in bracketed-paste markers so the shell can tell it from
/// typing and won't execute a multi-line paste line by line.
pub fn bracketPaste(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ "\x1b[200~", text, "\x1b[201~" });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectKey(expected: []const u8, key: Key, mods: Mods, app_cursor: bool) !void {
    var buf: [32]u8 = undefined;
    const got = encode(&buf, key, mods, app_cursor) orelse return error.NothingEncoded;
    try testing.expectEqualStrings(expected, got);
}

test "plain characters pass through as UTF-8" {
    try expectKey("a", .{ .char = 'a' }, .{}, false);
    try expectKey("\u{e9}", .{ .char = 0xe9 }, .{}, false);
}

test "control characters" {
    try expectKey("\x03", .{ .char = 'c' }, .{ .ctrl = true }, false); // Ctrl-C
    try expectKey("\x03", .{ .char = 'C' }, .{ .ctrl = true }, false); // case-insensitive
    try expectKey("\x00", .{ .char = ' ' }, .{ .ctrl = true }, false); // Ctrl-Space
    try expectKey("\x1c", .{ .char = '\\' }, .{ .ctrl = true }, false); // Ctrl-\ quits
    try expectKey("\x1a", .{ .char = 'z' }, .{ .ctrl = true }, false); // Ctrl-Z suspends
}

test "alt prefixes with escape" {
    try expectKey("\x1bb", .{ .char = 'b' }, .{ .alt = true }, false); // Alt-B: back word
    try expectKey("\x1b\x7f", .backspace, .{ .alt = true }, false);
}

test "arrow keys switch form in application cursor mode" {
    try expectKey("\x1b[A", .up, .{}, false);
    try expectKey("\x1bOA", .up, .{}, true);
    // ...but a modified arrow is always CSI, even in application mode.
    try expectKey("\x1b[1;5A", .up, .{ .ctrl = true }, true);
}

test "xterm modifier parameters" {
    try expectKey("\x1b[1;2D", .left, .{ .shift = true }, false); // 1+1
    try expectKey("\x1b[1;3D", .left, .{ .alt = true }, false); // 1+2
    try expectKey("\x1b[1;5D", .left, .{ .ctrl = true }, false); // 1+4
    try expectKey("\x1b[1;8D", .left, .{ .ctrl = true, .alt = true, .shift = true }, false);
}

test "navigation and editing keys" {
    try expectKey("\x1b[5~", .page_up, .{}, false);
    try expectKey("\x1b[6~", .page_down, .{}, false);
    try expectKey("\x1b[3~", .delete, .{}, false);
    try expectKey("\x1b[H", .home, .{}, false);
    try expectKey("\x1b[F", .end, .{}, false);
    try expectKey("\x1b[3;5~", .delete, .{ .ctrl = true }, false);
}

test "backspace sends DEL, tab and shift-tab" {
    try expectKey("\x7f", .backspace, .{}, false);
    try expectKey("\x08", .backspace, .{ .ctrl = true }, false);
    try expectKey("\t", .tab, .{}, false);
    try expectKey("\x1b[Z", .tab, .{ .shift = true }, false);
}

test "function keys use SS3 below F5 and CSI above" {
    try expectKey("\x1bOP", .{ .f = 1 }, .{}, false);
    try expectKey("\x1bOS", .{ .f = 4 }, .{}, false);
    try expectKey("\x1b[15~", .{ .f = 5 }, .{}, false);
    try expectKey("\x1b[24~", .{ .f = 12 }, .{}, false);
    try expectKey("\x1b[1;5P", .{ .f = 1 }, .{ .ctrl = true }, false);
}

test "enter and escape" {
    try expectKey("\r", .enter, .{}, false);
    try expectKey("\x1b", .escape, .{}, false);
}

test "bracketed paste wraps the payload" {
    const out = try bracketPaste(testing.allocator, "ls -la\nrm -rf /");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\x1b[200~ls -la\nrm -rf /\x1b[201~", out);
}
