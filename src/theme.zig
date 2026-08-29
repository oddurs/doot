//! Colors. The 16 ANSI slots are a hand-picked dark scheme; 16-255 are the
//! standard xterm cube and grayscale ramp, which are generated rather than
//! typed out because they're defined by formula.

const std = @import("std");
const grid = @import("grid.zig");

pub const Rgb = grid.Rgb;

pub const Theme = struct {
    fg: Rgb,
    bg: Rgb,
    cursor: Rgb,
    /// Foreground drawn under the block cursor.
    cursor_text: Rgb,
    selection: Rgb,
    palette: [256]Rgb,

    pub fn resolve(self: *const Theme, color: grid.Color, role: enum { fg, bg }) Rgb {
        return switch (color) {
            .default => switch (role) {
                .fg => self.fg,
                .bg => self.bg,
            },
            .indexed => |i| self.palette[i],
            .rgb => |c| c,
        };
    }
};

fn rgb(hex: u24) Rgb {
    return .{
        .r = @truncate(hex >> 16),
        .g = @truncate(hex >> 8),
        .b = @truncate(hex),
    };
}

/// xterm's 256-color palette: 16 named colors, then a 6x6x6 RGB cube, then a
/// 24-step grayscale ramp.
fn buildPalette(ansi: [16]Rgb) [256]Rgb {
    var p: [256]Rgb = undefined;
    @memcpy(p[0..16], &ansi);

    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    var i: usize = 16;
    for (levels) |r| for (levels) |g| for (levels) |b| {
        p[i] = .{ .r = r, .g = g, .b = b };
        i += 1;
    };

    var gray: u8 = 8;
    while (i < 256) : (i += 1) {
        p[i] = .{ .r = gray, .g = gray, .b = gray };
        gray +|= 10;
    }
    return p;
}

pub const default: Theme = .{
    .fg = rgb(0xc8d0d8),
    .bg = rgb(0x10141a),
    .cursor = rgb(0x7fd6c1),
    .cursor_text = rgb(0x10141a),
    .selection = rgb(0x2c3a4a),
    .palette = buildPalette(.{
        rgb(0x1c2028), // 0  black
        rgb(0xe06c75), // 1  red
        rgb(0x8fbf7f), // 2  green
        rgb(0xe5c07b), // 3  yellow
        rgb(0x61afef), // 4  blue
        rgb(0xc678dd), // 5  magenta
        rgb(0x56b6c2), // 6  cyan
        rgb(0xc8d0d8), // 7  white
        rgb(0x3a4250), // 8  bright black
        rgb(0xff7b86), // 9  bright red
        rgb(0xa5d894), // 10 bright green
        rgb(0xffd68a), // 11 bright yellow
        rgb(0x79c0ff), // 12 bright blue
        rgb(0xd899ea), // 13 bright magenta
        rgb(0x6fd0dc), // 14 bright cyan
        rgb(0xf0f4f8), // 15 bright white
    }),
};

const testing = std.testing;

test "palette cube and ramp land on the xterm values" {
    const p = default.palette;
    // 16 is the cube origin (black), 231 its far corner (white).
    try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, p[16]);
    try testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, p[231]);
    // 232 starts the grayscale ramp at 8.
    try testing.expectEqual(Rgb{ .r = 8, .g = 8, .b = 8 }, p[232]);
    // Cube index 16 + 36r + 6g + b; r=1,g=0,b=0 -> 95,0,0.
    try testing.expectEqual(Rgb{ .r = 95, .g = 0, .b = 0 }, p[16 + 36]);
}

test "default and indexed colors resolve by role" {
    try testing.expectEqual(default.fg, default.resolve(.default, .fg));
    try testing.expectEqual(default.bg, default.resolve(.default, .bg));
    try testing.expectEqual(default.palette[1], default.resolve(.{ .indexed = 1 }, .fg));
    const c = Rgb{ .r = 1, .g = 2, .b = 3 };
    try testing.expectEqual(c, default.resolve(.{ .rgb = c }, .fg));
}
