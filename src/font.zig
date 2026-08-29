//! Glyph rasterization and the texture atlas.
//!
//! Every distinct (codepoint, bold, italic) gets rasterized by FreeType once,
//! packed into one big texture, and thereafter drawn as a textured quad. One
//! texture for the whole screen is what lets the GPU batch a full repaint into
//! a handful of draw calls instead of thousands.

const std = @import("std");

const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftsynth.h");
});

pub const Error = error{
    FreeTypeInit,
    NoFontFound,
    SetSizeFailed,
    AtlasFull,
};

/// Candidate faces, best first. SF Mono is the system monospace on modern
/// macOS; Menlo is the reliable fallback that has shipped forever.
const font_candidates = [_][:0]const u8{
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Supplemental/Andale Mono.ttf",
    "/System/Library/Fonts/Courier.ttc",
};

pub const Metrics = struct {
    /// Advance width of one cell, in pixels.
    cell_w: u32,
    /// Baseline-to-baseline distance, in pixels.
    cell_h: u32,
    /// Baseline offset from the top of the cell, in pixels.
    ascent: i32,
    /// Thickness and position for underline/strikethrough.
    underline_pos: i32,
    underline_thickness: u32,
};

pub const Font = struct {
    lib: c.FT_Library,
    face: c.FT_Face,
    metrics: Metrics,
    path: [:0]const u8,

    pub fn init(size_px: u32, path_override: ?[:0]const u8) !Font {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return Error.FreeTypeInit;
        errdefer _ = c.FT_Done_FreeType(lib);

        var face: c.FT_Face = null;
        var chosen: [:0]const u8 = undefined;
        if (path_override) |p| {
            if (c.FT_New_Face(lib, p.ptr, 0, &face) != 0) return Error.NoFontFound;
            chosen = p;
        } else {
            for (font_candidates) |cand| {
                if (c.FT_New_Face(lib, cand.ptr, 0, &face) == 0) {
                    chosen = cand;
                    break;
                }
            } else return Error.NoFontFound;
        }
        errdefer _ = c.FT_Done_Face(face);

        if (c.FT_Set_Pixel_Sizes(face, 0, size_px) != 0) return Error.SetSizeFailed;

        // FreeType metrics are 26.6 fixed point, hence the >> 6.
        const size_metrics = face.*.size.*.metrics;
        const ascent: i32 = @intCast(size_metrics.ascender >> 6);
        const descent: i32 = @intCast(-(size_metrics.descender >> 6));
        var line_h: u32 = @intCast(@max(size_metrics.height >> 6, 1));
        // Some faces report a height tighter than ascent+descent, which
        // clips descenders. Trust the sum when it's larger.
        line_h = @max(line_h, @as(u32, @intCast(ascent + descent)));

        // For a monospace face every advance is the same; 'M' is a safe probe.
        var cell_w: u32 = @intCast(@max(size_metrics.max_advance >> 6, 1));
        if (c.FT_Load_Char(face, 'M', c.FT_LOAD_DEFAULT) == 0) {
            const adv: i64 = face.*.glyph.*.advance.x >> 6;
            if (adv > 0) cell_w = @intCast(adv);
        }

        return .{
            .lib = lib,
            .face = face,
            .path = chosen,
            .metrics = .{
                .cell_w = cell_w,
                .cell_h = line_h,
                .ascent = ascent,
                .underline_pos = @max(1, @divTrunc(descent, 3)),
                .underline_thickness = @max(1, size_px / 14),
            },
        };
    }

    pub fn deinit(self: *Font) void {
        _ = c.FT_Done_Face(self.face);
        _ = c.FT_Done_FreeType(self.lib);
        self.* = undefined;
    }

    pub fn hasGlyph(self: *const Font, cp: u21) bool {
        return c.FT_Get_Char_Index(self.face, cp) != 0;
    }

    /// Rasterize into FreeType's own glyph slot. The bitmap stays valid until
    /// the next call, so the caller must copy it out before rasterizing again.
    fn rasterize(self: *Font, cp: u21, bold: bool, italic: bool) ?*c.FT_GlyphSlotRec {
        if (c.FT_Load_Char(self.face, cp, c.FT_LOAD_DEFAULT) != 0) return null;
        const slot = self.face.*.glyph;
        // Synthetic bold/italic from a single face. A real bold face would
        // look better, but this keeps us to one file and covers every glyph.
        if (bold) c.FT_GlyphSlot_Embolden(slot);
        if (italic) c.FT_GlyphSlot_Oblique(slot);
        if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_NORMAL) != 0) return null;
        return slot;
    }
};

/// Where a glyph lives in the atlas, and how to place it in a cell.
pub const Glyph = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// Offset from the cell's pen position to the bitmap's top-left.
    left: i16,
    top: i16,
};

pub const Rect = struct { x: u16, y: u16, w: u16, h: u16 };

pub const atlas_size = 1024;

pub const Atlas = struct {
    /// RGBA8, white with the coverage in alpha, so a single texture can be
    /// tinted to any foreground color at draw time.
    pixels: []u8,
    cache: std.AutoHashMapUnmanaged(u32, Glyph) = .empty,
    alloc: std.mem.Allocator,

    // Shelf packer: fill a row left to right, then start a new row above the
    // tallest glyph so far. Simple, and glyphs are all about the same height.
    pen_x: u16 = 1,
    pen_y: u16 = 1,
    shelf_h: u16 = 0,

    pub fn init(alloc: std.mem.Allocator) !Atlas {
        const px = try alloc.alloc(u8, atlas_size * atlas_size * 4);
        @memset(px, 0);
        // Texel (0, 0) is opaque white and never packed over: the shelf
        // packer starts at (1, 1). Solid fills sample it, so that the
        // renderer can put rectangles and glyphs in the same draw call.
        @memset(px[0..4], 255);
        return .{ .pixels = px, .alloc = alloc };
    }

    pub fn deinit(self: *Atlas) void {
        self.cache.deinit(self.alloc);
        self.alloc.free(self.pixels);
        self.* = undefined;
    }

    fn key(cp: u21, bold: bool, italic: bool) u32 {
        return (@as(u32, cp) << 2) | (@as(u32, @intFromBool(bold)) << 1) |
            @intFromBool(italic);
    }

    pub const Lookup = struct {
        glyph: Glyph,
        /// Region newly written this call, for the renderer to upload.
        added: ?Rect,
    };

    pub fn get(self: *Atlas, font: *Font, cp: u21, bold: bool, italic: bool) !Lookup {
        const k = key(cp, bold, italic);
        if (self.cache.get(k)) |g| return .{ .glyph = g, .added = null };

        const slot = font.rasterize(cp, bold, italic) orelse {
            // No glyph: cache an empty box so we don't retry every frame.
            const empty = Glyph{ .x = 0, .y = 0, .w = 0, .h = 0, .left = 0, .top = 0 };
            try self.cache.put(self.alloc, k, empty);
            return .{ .glyph = empty, .added = null };
        };

        const bmp = slot.*.bitmap;
        const w: u16 = @intCast(bmp.width);
        const h: u16 = @intCast(bmp.rows);

        var glyph = Glyph{
            .x = 0,
            .y = 0,
            .w = w,
            .h = h,
            .left = @intCast(slot.*.bitmap_left),
            .top = @intCast(slot.*.bitmap_top),
        };

        var added: ?Rect = null;
        if (w > 0 and h > 0) {
            const pos = try self.alloc_rect(w, h);
            glyph.x = pos.x;
            glyph.y = pos.y;
            self.blit(pos, bmp);
            added = pos;
        }

        try self.cache.put(self.alloc, k, glyph);
        return .{ .glyph = glyph, .added = added };
    }

    fn alloc_rect(self: *Atlas, w: u16, h: u16) !Rect {
        if (w + 2 > atlas_size) return Error.AtlasFull;
        if (self.pen_x + w + 1 > atlas_size) {
            self.pen_x = 1;
            self.pen_y += self.shelf_h + 1;
            self.shelf_h = 0;
        }
        if (self.pen_y + h + 1 > atlas_size) return Error.AtlasFull;
        const r = Rect{ .x = self.pen_x, .y = self.pen_y, .w = w, .h = h };
        self.pen_x += w + 1;
        self.shelf_h = @max(self.shelf_h, h);
        return r;
    }

    /// Copy an 8-bit coverage bitmap into the RGBA atlas as white + alpha.
    fn blit(self: *Atlas, r: Rect, bmp: c.FT_Bitmap) void {
        const src: [*]const u8 = @ptrCast(bmp.buffer);
        // FreeType rows can be padded, and a negative pitch means bottom-up.
        const pitch: isize = bmp.pitch;
        for (0..r.h) |row| {
            const src_off: isize = @as(isize, @intCast(row)) * pitch;
            const dst_base = ((@as(usize, r.y) + row) * atlas_size + r.x) * 4;
            for (0..r.w) |col| {
                const coverage = src[@intCast(src_off + @as(isize, @intCast(col)))];
                const d = dst_base + col * 4;
                self.pixels[d + 0] = 255;
                self.pixels[d + 1] = 255;
                self.pixels[d + 2] = 255;
                self.pixels[d + 3] = coverage;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "loads a system font and reports sane cell metrics" {
    var f = Font.init(16, null) catch |err| switch (err) {
        Error.NoFontFound => return error.SkipZigTest,
        else => return err,
    };
    defer f.deinit();

    try testing.expect(f.metrics.cell_w > 0);
    try testing.expect(f.metrics.cell_h > 0);
    // A 16px monospace face should be taller than it is wide, and in the
    // right ballpark rather than wildly off.
    try testing.expect(f.metrics.cell_h > f.metrics.cell_w);
    try testing.expect(f.metrics.cell_h < 40);
    try testing.expect(f.metrics.ascent > 0);
}

test "atlas rasterizes, caches, and packs without overlapping" {
    var f = Font.init(16, null) catch |err| switch (err) {
        Error.NoFontFound => return error.SkipZigTest,
        else => return err,
    };
    defer f.deinit();
    var atlas = try Atlas.init(testing.allocator);
    defer atlas.deinit();

    const a1 = try atlas.get(&f, 'A', false, false);
    try testing.expect(a1.added != null); // first time: newly rasterized
    try testing.expect(a1.glyph.w > 0 and a1.glyph.h > 0);

    const a2 = try atlas.get(&f, 'A', false, false);
    try testing.expect(a2.added == null); // second time: cache hit
    try testing.expectEqual(a1.glyph.x, a2.glyph.x);

    // Bold is a different cache entry occupying different atlas space.
    const b = try atlas.get(&f, 'A', true, false);
    try testing.expect(b.added != null);
    try testing.expect(b.glyph.x != a1.glyph.x or b.glyph.y != a1.glyph.y);

    // A space is blank; asking for it must not crash the packer.
    _ = try atlas.get(&f, ' ', false, false);
}

test "the white texel is reserved and never packed over" {
    var f = Font.init(14, null) catch |err| switch (err) {
        Error.NoFontFound => return error.SkipZigTest,
        else => return err,
    };
    defer f.deinit();
    var atlas = try Atlas.init(testing.allocator);
    defer atlas.deinit();

    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, atlas.pixels[0..4]);
    var cp: u21 = 0x21;
    while (cp < 0x7f) : (cp += 1) {
        const got = try atlas.get(&f, cp, false, false);
        try testing.expect(got.glyph.x >= 1 and got.glyph.y >= 1);
    }
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, atlas.pixels[0..4]);
}

test "atlas survives many distinct glyphs" {
    var f = Font.init(14, null) catch |err| switch (err) {
        Error.NoFontFound => return error.SkipZigTest,
        else => return err,
    };
    defer f.deinit();
    var atlas = try Atlas.init(testing.allocator);
    defer atlas.deinit();

    // Every printable ASCII in all four style combinations.
    for (0..4) |style| {
        var cp: u21 = 0x21;
        while (cp < 0x7f) : (cp += 1) {
            _ = try atlas.get(&f, cp, style & 1 != 0, style & 2 != 0);
        }
    }
    try testing.expectEqual(@as(u32, 4 * (0x7f - 0x21)), atlas.cache.count());
}
