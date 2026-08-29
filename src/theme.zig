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

/// The sRGB electro-optical transfer function: an sRGB-encoded channel in
/// 0..1, linear light out.
///
/// Every colour in this file is an sRGB byte triple, which is what a theme
/// entry, an xterm palette index and an SGR truecolour escape all are. The
/// render target is `BGRA8Unorm_sRGB`, so the hardware encodes whatever the
/// pipeline writes and every colour reaching it has to be linear first.
/// Vertex colours get this in `shader.metal`; the clear colour does not
/// pass through a shader at all -- it goes straight into `MTLClearColor` --
/// so `render.zig` applies it here instead.
///
/// It lives beside the palette rather than in the renderer because it is a
/// property of the colour space those bytes are written in, not of how they
/// are drawn, and because here it can be tested without a window.
pub fn srgbToLinear(x: f32) f32 {
    // The piecewise curve, not the 2.2 power approximation: the linear
    // segment near black is what keeps a dark theme's background from
    // shifting, and it is one branch.
    if (x <= 0.04045) return x / 12.92;
    return std.math.pow(f32, (x + 0.055) / 1.055, 2.4);
}

const testing = std.testing;

test "srgbToLinear matches the sRGB curve at its landmarks" {
    // The endpoints are exact by construction, and a transfer function that
    // moves either of them would wash out or crush the whole image.
    try testing.expectEqual(@as(f32, 0.0), srgbToLinear(0.0));
    try testing.expectApproxEqAbs(@as(f32, 1.0), srgbToLinear(1.0), 1e-6);

    // The knee: both branches must agree where they meet, or there is a
    // visible step in the darkest few codes.
    try testing.expectApproxEqAbs(@as(f32, 0.0031308), srgbToLinear(0.04045), 1e-6);

    // Points along the curved branch, from the definition. The knee value
    // above does *not* pin these down: move the knee up and every one of
    // them silently takes the straight branch instead, which is the one
    // mutant a landmarks-only test let through.
    try testing.expectApproxEqAbs(@as(f32, 0.0100228), srgbToLinear(0.10), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0508761), srgbToLinear(0.25), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.2140411), srgbToLinear(0.50), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5225216), srgbToLinear(0.75), 1e-5);

    // Mid grey. 0x80/255 is 0.50196 encoded and ~0.2158 linear -- the
    // number that makes gamma-correct blending look different at all, and
    // the one a 2.2-power approximation would get wrong in the third digit.
    try testing.expectApproxEqAbs(@as(f32, 0.21586), srgbToLinear(128.0 / 255.0), 1e-4);

    // Below the knee it is a straight line, so doubling the input doubles
    // the output exactly. An accidental `pow` on this branch would not.
    try testing.expectApproxEqAbs(
        2 * srgbToLinear(0.01),
        srgbToLinear(0.02),
        1e-7,
    );

    // Monotonic and continuous across the whole range, including across the
    // knee. Not monotonic is a banding artefact waiting to happen, and it
    // is what a sign error produces; not continuous is a visible step, and
    // it is what a misplaced knee produces. The curve's steepest slope is
    // ~2.28 at white, so one code apart is ~0.009 apart at most -- 0.02
    // leaves room for that and none for a step.
    var prev: f32 = -1.0;
    for (0..256) |i| {
        const v = srgbToLinear(@as(f32, @floatFromInt(i)) / 255.0);
        try testing.expect(v > prev);
        try testing.expect(v <= 1.0);
        if (i > 0) try testing.expect(v - prev < 0.02);
        // Linear light is never *brighter* than the code that encodes it.
        try testing.expect(v <= @as(f32, @floatFromInt(i)) / 255.0 + 1e-6);
        prev = v;
    }
}

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
