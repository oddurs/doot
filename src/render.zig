//! Drawing the grid.
//!
//! Two passes: background runs, then glyphs. Every quad -- backgrounds, glyph
//! bitmaps, underlines, the cursor -- goes into one vertex buffer with its
//! colour on the vertices, sampling one atlas texture, and the whole frame is
//! submitted with a single `SDL_RenderGeometryRaw`. Solid fills sample a
//! white texel reserved in the atlas, which is what keeps them in the same
//! call as the glyphs.
//!
//! A frame is drawn in two steps that run under different locking rules.
//! `snapshot` copies the visible cells out of the terminal and must be called
//! with the terminal mutex held; `draw` renders that copy and presents it, and
//! must be called with the mutex released. The wait for vblank lives inside
//! present, and while it sat inside the lock the reader thread could not feed
//! a byte for the whole of every frame -- bulk output was throttled to a few
//! KiB per refresh. The copy costs microseconds; the wait costs milliseconds.

const std = @import("std");
const grid = @import("grid.zig");
const font = @import("font.zig");
const theme = @import("theme.zig");
const stats = @import("stats.zig");
const png = @import("png.zig");
const Terminal = @import("terminal.zig").Terminal;

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Error = error{
    SdlInit,
    WindowFailed,
    RendererFailed,
    TextureFailed,
};

/// Padding between the window edge and the first cell, in logical pixels.
const pad = 6;

/// What one frame draws: a copy of the visible cells plus where the cursor
/// is, owned by the renderer. Taken under the terminal lock and drawn after
/// it is released, so it must not alias terminal state -- every field here
/// is a value, and `cells` is renderer-owned memory the terminal never sees.
pub const Frame = struct {
    cells: []grid.Cell = &.{},
    cols: usize = 0,
    rows: usize = 0,
    /// Where the block cursor goes, or null when it is hidden, scrolled out
    /// of view, or off the grid. The covered cell is redrawn in the cursor's
    /// contrast colour, so it travels with the position.
    cursor: ?struct { x: usize, y: usize, cell: grid.Cell } = null,

    fn row(self: *const Frame, y: usize) []const grid.Cell {
        return self.cells[y * self.cols ..][0..self.cols];
    }
};

/// One corner of a quad, laid out so a single array feeds all three of
/// `SDL_RenderGeometryRaw`'s attribute pointers at one stride.
const Vertex = extern struct {
    x: f32,
    y: f32,
    color: c.SDL_FColor,
    u: f32,
    v: f32,
};

/// Texture coordinate of the centre of the atlas's reserved white texel.
/// Solid fills sample it, which is what lets backgrounds, underlines and the
/// cursor share the glyph draw call instead of breaking it up.
const white_uv: f32 = 0.5 / @as(f32, font.atlas_size);

pub const Renderer = struct {
    window: *c.SDL_Window,
    sdl: *c.SDL_Renderer,
    atlas_tex: *c.SDL_Texture,
    font: font.Font,
    atlas: font.Atlas,
    theme: theme.Theme,
    frame: Frame = .{},
    /// The pixel size a capture is cropped to: exactly the grid plus its
    /// padding. The window itself can end up a pixel larger, because its
    /// size is set in logical units and the host display's density decides
    /// how those round -- and a capture that changes with the machine it
    /// was taken on is not a reference.
    capture_w: u32 = 0,
    capture_h: u32 = 0,
    /// The frame's geometry, rebuilt every draw and submitted in one call.
    verts: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(i32) = .empty,
    /// Submission calls made by the frame being built, for `--frame-stats`.
    calls: u64 = 0,
    /// `--screenshot`: save the first frame drawn after this instant, then
    /// forget the path. Read back before present, so no OS permission is
    /// needed to check what the renderer actually produced.
    screenshot_path: ?[:0]const u8 = null,
    screenshot_after_ns: u64 = 0,

    /// Backing-store pixels per logical pixel (2.0 on a Retina display).
    scale: f32,
    px_w: i32,
    px_h: i32,
    pad_px: i32,
    focused: bool = true,

    pub fn init(
        alloc: std.mem.Allocator,
        title: [:0]const u8,
        font_size_pt: u32,
        init_cols: u32,
        init_rows: u32,
        scale_override: ?f32,
    ) !Renderer {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return Error.SdlInit;
        errdefer c.SDL_Quit();

        // We need the display scale before we know how big to make the
        // window, so measure a provisional font at 1x and scale from there.
        var probe = try font.Font.init(font_size_pt, null);
        const logical_w: i32 = @intCast(init_cols * probe.metrics.cell_w + pad * 2);
        const logical_h: i32 = @intCast(init_rows * probe.metrics.cell_h + pad * 2);
        probe.deinit();

        const window = c.SDL_CreateWindow(
            title.ptr,
            logical_w,
            logical_h,
            c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY,
        ) orelse return Error.WindowFailed;
        errdefer c.SDL_DestroyWindow(window);

        const sdl = c.SDL_CreateRenderer(window, null) orelse return Error.RendererFailed;
        errdefer c.SDL_DestroyRenderer(sdl);

        // VSync keeps us from burning the GPU redrawing faster than the
        // display can show, which matters a lot for battery life.
        _ = c.SDL_SetRenderVSync(sdl, 1);

        // The display's density, and the density we draw at. They differ
        // only when --scale asks for one the display does not have, which
        // is how a 2x gallery capture is reproducible on a 1x CI runner.
        const density = c.SDL_GetWindowPixelDensity(window);
        const scale = scale_override orelse density;
        // Rasterize at device resolution: a 14pt font on a 2x display is a
        // 28px face, not a 14px face scaled up and blurry.
        const px_size: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(font_size_pt)) * scale));
        var f = try font.Font.init(px_size, null);
        errdefer f.deinit();

        var atlas = try font.Atlas.init(alloc);
        errdefer atlas.deinit();

        const tex = c.SDL_CreateTexture(
            sdl,
            c.SDL_PIXELFORMAT_RGBA32,
            c.SDL_TEXTUREACCESS_STATIC,
            font.atlas_size,
            font.atlas_size,
        ) orelse return Error.TextureFailed;
        _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
        // Glyphs are tiny; nearest sampling keeps their edges crisp since we
        // always draw them at 1:1 scale anyway.
        _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_NEAREST);
        // The atlas starts empty except for its white texel, and the texture
        // has to carry that from the first frame.
        _ = c.SDL_UpdateTexture(tex, null, atlas.pixels.ptr, font.atlas_size * 4);

        // Size the window so its *pixel* size fits the grid at this scale.
        // Without this a forced scale would render 2x glyphs into a 1x
        // window and show half the columns.
        const pad_px_i: u32 = @intFromFloat(@round(pad * scale));
        const want_w: u32 = init_cols * f.metrics.cell_w + pad_px_i * 2;
        const want_h: u32 = init_rows * f.metrics.cell_h + pad_px_i * 2;
        _ = c.SDL_SetWindowSize(
            window,
            @intFromFloat(@round(@as(f32, @floatFromInt(want_w)) / density)),
            @intFromFloat(@round(@as(f32, @floatFromInt(want_h)) / density)),
        );

        var self = Renderer{
            .window = window,
            .sdl = sdl,
            .atlas_tex = tex,
            .font = f,
            .atlas = atlas,
            .theme = theme.default,
            .scale = scale,
            .px_w = 0,
            .px_h = 0,
            .pad_px = @intCast(pad_px_i),
            .capture_w = want_w,
            .capture_h = want_h,
        };
        self.updateSize();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.verts.deinit(self.atlas.alloc);
        self.indices.deinit(self.atlas.alloc);
        self.atlas.alloc.free(self.frame.cells);
        c.SDL_DestroyTexture(self.atlas_tex);
        self.atlas.deinit();
        self.font.deinit();
        c.SDL_DestroyRenderer(self.sdl);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    pub fn updateSize(self: *Renderer) void {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetRenderOutputSize(self.sdl, &w, &h);
        self.px_w = @intCast(w);
        self.px_h = @intCast(h);
    }

    /// How many cells fit in the current window.
    pub fn gridSize(self: *const Renderer) struct { cols: u32, rows: u32 } {
        const usable_w = @max(self.px_w - self.pad_px * 2, 0);
        const usable_h = @max(self.px_h - self.pad_px * 2, 0);
        return .{
            .cols = @max(1, @as(u32, @intCast(usable_w)) / self.font.metrics.cell_w),
            .rows = @max(1, @as(u32, @intCast(usable_h)) / self.font.metrics.cell_h),
        };
    }

    /// Rebuild the face and atlas at a new point size. Every cached glyph is
    /// the wrong size now, so the atlas is thrown away and refilled lazily.
    pub fn setFontSize(self: *Renderer, font_size_pt: u32) !void {
        const px_size: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(font_size_pt)) * self.scale));
        var new_font = try font.Font.init(px_size, null);
        errdefer new_font.deinit();
        var new_atlas = try font.Atlas.init(self.atlas.alloc);
        errdefer new_atlas.deinit();

        self.font.deinit();
        self.atlas.deinit();
        self.font = new_font;
        self.atlas = new_atlas;

        // Re-upload the (empty) atlas so stale glyphs can't bleed through the
        // gaps between newly packed ones, and so the white texel survives.
        _ = c.SDL_UpdateTexture(self.atlas_tex, null, self.atlas.pixels.ptr, font.atlas_size * 4);
    }

    pub fn setTitle(self: *Renderer, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
    }

    fn setDrawColor(self: *Renderer, color: grid.Rgb) void {
        _ = c.SDL_SetRenderDrawColor(self.sdl, color.r, color.g, color.b, 255);
    }

    /// The effective colors for a cell, after reverse video, dim and bold.
    fn cellColors(self: *const Renderer, cell: grid.Cell) struct { fg: grid.Rgb, bg: grid.Rgb } {
        var fg_slot = cell.fg;
        const bg_slot = cell.bg;

        // Bold brightens the 8 base ANSI colors, the way xterm has since
        // forever. Truecolor and the 256-color cube are left alone.
        if (cell.attrs.bold) {
            if (fg_slot == .indexed and fg_slot.indexed < 8) {
                fg_slot = .{ .indexed = fg_slot.indexed + 8 };
            }
        }

        var fg = self.theme.resolve(fg_slot, .fg);
        var bg = self.theme.resolve(bg_slot, .bg);
        if (cell.attrs.reverse) std.mem.swap(grid.Rgb, &fg, &bg);
        if (cell.attrs.dim) fg = blend(bg, fg, 0.55);
        if (cell.attrs.hidden) fg = bg;
        return .{ .fg = fg, .bg = bg };
    }

    /// Copy what the next frame will show out of the terminal. Call with the
    /// terminal mutex held; this is the only part of a frame that needs it.
    ///
    /// On allocation failure the previous frame is kept, so a redraw can be
    /// skipped but never drawn from a half-copied grid.
    pub fn snapshot(self: *Renderer, term: *Terminal) !void {
        const rows = @min(term.rows, self.gridSize().rows);
        const cols = term.cols;
        if (self.frame.cells.len != rows * cols) {
            const cells = try self.atlas.alloc.alloc(grid.Cell, rows * cols);
            self.atlas.alloc.free(self.frame.cells);
            self.frame.cells = cells;
        }
        self.frame.cols = cols;
        self.frame.rows = rows;
        for (0..rows) |y| {
            @memcpy(self.frame.cells[y * cols ..][0..cols], term.viewRow(y));
        }

        self.frame.cursor = null;
        if (!term.modes.cursor_visible) return;
        // Scrolled back into history, the cursor isn't where you're looking.
        if (term.view_offset != 0) return;
        if (term.cursor.y >= rows or term.cursor.x >= cols) return;
        self.frame.cursor = .{
            .x = term.cursor.x,
            .y = term.cursor.y,
            .cell = term.screen().at(term.cursor.x, term.cursor.y).*,
        };
    }

    /// Render the last snapshot and present it. Call with the terminal mutex
    /// released: this is where the frame waits for vblank, and nothing in it
    /// touches the terminal.
    ///
    /// The whole frame is one vertex buffer and one draw call. Backgrounds go
    /// in first, then glyphs, then the cursor: triangles rasterize in index
    /// order, so later quads blend over earlier ones exactly as separate
    /// calls would have.
    pub fn draw(self: *Renderer) stats.FrameTimes {
        const t0 = stats.nowNs();
        self.calls = 1;
        self.setDrawColor(self.theme.bg);
        _ = c.SDL_RenderClear(self.sdl);
        self.verts.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();

        const cw: f32 = @floatFromInt(self.font.metrics.cell_w);
        const ch: f32 = @floatFromInt(self.font.metrics.cell_h);
        const ox: f32 = @floatFromInt(self.pad_px);
        const oy: f32 = @floatFromInt(self.pad_px);
        const frame = &self.frame;

        // -- pass 1: background runs ---------------------------------------
        for (0..frame.rows) |y| {
            const row = frame.row(y);
            const ry = oy + @as(f32, @floatFromInt(y)) * ch;
            var x: usize = 0;
            var bg = self.cellColors(row[0]).bg;
            while (x < row.len) {
                var run: usize = 1;
                var next = bg;
                while (x + run < row.len) : (run += 1) {
                    next = self.cellColors(row[x + run]).bg;
                    if (!std.meta.eql(next, bg)) break;
                }
                if (!std.meta.eql(bg, self.theme.bg)) {
                    self.rect(
                        ox + @as(f32, @floatFromInt(x)) * cw,
                        ry,
                        cw * @as(f32, @floatFromInt(run)),
                        ch,
                        bg,
                    );
                }
                x += run;
                bg = next;
            }
        }

        // -- pass 2: glyphs ------------------------------------------------
        for (0..frame.rows) |y| {
            const row = frame.row(y);
            const ry = oy + @as(f32, @floatFromInt(y)) * ch;
            for (row, 0..) |cell, cx| {
                if (cell.wide == .spacer) continue; // drawn by its wide partner
                if (cell.cp == ' ' or cell.cp == 0) {
                    if (!cell.attrs.underline and !cell.attrs.strike) continue;
                }
                const colors = self.cellColors(cell);
                const px = ox + @as(f32, @floatFromInt(cx)) * cw;
                self.glyph(cell, px, ry, colors.fg);
            }
        }

        self.cursorQuads(ox, oy, cw, ch);

        // -- submit --------------------------------------------------------
        if (self.verts.items.len > 0) {
            const v = self.verts.items;
            const stride = @sizeOf(Vertex);
            _ = c.SDL_RenderGeometryRaw(
                self.sdl,
                self.atlas_tex,
                &v[0].x,
                stride,
                &v[0].color,
                stride,
                &v[0].u,
                stride,
                @intCast(v.len),
                self.indices.items.ptr,
                @intCast(self.indices.items.len),
                @sizeOf(i32),
            );
            self.calls += 1;
        }

        const t1 = stats.nowNs();
        if (self.screenshot_path) |path| {
            if (t1 >= self.screenshot_after_ns) {
                self.screenshot_path = null;
                self.saveScreenshot(path);
            }
        }
        _ = c.SDL_RenderPresent(self.sdl);
        return .{ .build = t1 - t0, .present = stats.nowNs() - t1, .calls = self.calls };
    }

    /// Append one textured quad: two triangles over `x0..x1` by `y0..y1`,
    /// sampling atlas `ua..ub` by `va..vb`, in one flat colour.
    fn quad(
        self: *Renderer,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        ua: f32,
        va: f32,
        ub: f32,
        vb: f32,
        color: c.SDL_FColor,
    ) void {
        const alloc = self.atlas.alloc;
        const base: i32 = @intCast(self.verts.items.len);
        // An out-of-memory frame is drawn without this quad rather than not
        // at all; the next frame gets another go.
        self.verts.appendSlice(alloc, &.{
            .{ .x = x0, .y = y0, .color = color, .u = ua, .v = va },
            .{ .x = x1, .y = y0, .color = color, .u = ub, .v = va },
            .{ .x = x1, .y = y1, .color = color, .u = ub, .v = vb },
            .{ .x = x0, .y = y1, .color = color, .u = ua, .v = vb },
        }) catch return;
        self.indices.appendSlice(alloc, &.{
            base, base + 1, base + 2,
            base, base + 2, base + 3,
        }) catch {
            self.verts.items.len -= 4;
        };
    }

    /// A solid rectangle: a quad over the atlas's white texel.
    fn rect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: grid.Rgb) void {
        self.quad(x, y, x + w, y + h, white_uv, white_uv, white_uv, white_uv, fcolor(color));
    }

    /// The glyph for `cell` at cell origin (`px`, `py`), plus its underline
    /// and strikethrough, in `fg`.
    fn glyph(self: *Renderer, cell: grid.Cell, px: f32, py: f32, fg: grid.Rgb) void {
        const m = self.font.metrics;

        if (cell.cp != ' ' and cell.cp != 0 and !cell.attrs.hidden) {
            const found = self.atlas.get(
                &self.font,
                cell.cp,
                cell.attrs.bold,
                cell.attrs.italic,
            ) catch return;

            if (found.added) |r| self.uploadAtlasRegion(r);
            const g = found.glyph;
            if (g.w > 0 and g.h > 0) {
                const x0 = px + @as(f32, @floatFromInt(g.left));
                const y0 = py + @as(f32, @floatFromInt(m.ascent - g.top));
                const ua: f32 = @as(f32, @floatFromInt(g.x)) / font.atlas_size;
                const va: f32 = @as(f32, @floatFromInt(g.y)) / font.atlas_size;
                const ub: f32 = @as(f32, @floatFromInt(g.x + g.w)) / font.atlas_size;
                const vb: f32 = @as(f32, @floatFromInt(g.y + g.h)) / font.atlas_size;
                self.quad(
                    x0,
                    y0,
                    x0 + @as(f32, @floatFromInt(g.w)),
                    y0 + @as(f32, @floatFromInt(g.h)),
                    ua,
                    va,
                    ub,
                    vb,
                    fcolor(fg),
                );
            }
        }

        const cw: f32 = @floatFromInt(m.cell_w);
        const thick: f32 = @floatFromInt(m.underline_thickness);
        if (cell.attrs.underline) {
            self.rect(px, py + @as(f32, @floatFromInt(m.ascent + m.underline_pos)), cw, thick, fg);
        }
        if (cell.attrs.strike) {
            self.rect(px, py + @as(f32, @floatFromInt(m.ascent)) * 0.65, cw, thick, fg);
        }
    }

    /// Read the frame back and write it as a PNG.
    ///
    /// Read back before present rather than captured from the screen, so
    /// this needs no screen-recording permission and returns exactly what
    /// the renderer produced -- which is what makes it an acceptance test
    /// rather than a photograph.
    fn saveScreenshot(self: *Renderer, path: [:0]const u8) void {
        const raw = c.SDL_RenderReadPixels(self.sdl, null) orelse return;
        defer c.SDL_DestroySurface(raw);
        // The renderer's own format varies by backend; normalise so the
        // encoder only ever sees one layout.
        const surface = c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_RGBA32) orelse return;
        defer c.SDL_DestroySurface(surface);

        // Crop to the size the grid asked for. Setting the window size is
        // done in logical units, so on a 2x display an odd pixel height
        // rounds up by one and the same capture differs by a row between
        // machines. Cropping makes a reference reproducible anywhere.
        const full_w: u32 = @intCast(surface.*.w);
        const full_h: u32 = @intCast(surface.*.h);
        const w = if (self.capture_w > 0) @min(self.capture_w, full_w) else full_w;
        const h = if (self.capture_h > 0) @min(self.capture_h, full_h) else full_h;
        const pitch: usize = @intCast(surface.*.pitch);
        const src: [*]const u8 = @ptrCast(surface.*.pixels orelse return);

        const alloc = self.atlas.alloc;
        const pixels = alloc.alloc(u8, w * h * 4) catch return;
        defer alloc.free(pixels);
        // Rows are padded to the pitch, so copy row by row rather than
        // treating the surface as one block.
        for (0..h) |y| {
            @memcpy(pixels[y * w * 4 ..][0 .. w * 4], src[y * pitch ..][0 .. w * 4]);
        }

        const bytes = png.encode(alloc, .{ .w = w, .h = h, .pixels = pixels }) catch return;
        defer alloc.free(bytes);

        const file = std.c.fopen(path.ptr, "wb") orelse return;
        defer _ = std.c.fclose(file);
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    }

    fn uploadAtlasRegion(self: *Renderer, r: font.Rect) void {
        const sdl_rect = c.SDL_Rect{
            .x = @intCast(r.x),
            .y = @intCast(r.y),
            .w = @intCast(r.w),
            .h = @intCast(r.h),
        };
        const offset = (@as(usize, r.y) * font.atlas_size + r.x) * 4;
        _ = c.SDL_UpdateTexture(
            self.atlas_tex,
            &sdl_rect,
            self.atlas.pixels.ptr + offset,
            font.atlas_size * 4,
        );
    }

    fn cursorQuads(self: *Renderer, ox: f32, oy: f32, cw: f32, ch: f32) void {
        const cursor = self.frame.cursor orelse return;

        const px = ox + @as(f32, @floatFromInt(cursor.x)) * cw;
        const py = oy + @as(f32, @floatFromInt(cursor.y)) * ch;

        if (!self.focused) {
            // Unfocused windows get a hollow box, so you can tell at a glance
            // which terminal will receive your keystrokes.
            const t = @max(1, @round(self.scale));
            self.rect(px, py, cw, t, self.theme.cursor);
            self.rect(px, py + ch - t, cw, t, self.theme.cursor);
            self.rect(px, py, t, ch, self.theme.cursor);
            self.rect(px + cw - t, py, t, ch, self.theme.cursor);
            return;
        }

        self.rect(px, py, cw, ch, self.theme.cursor);

        // Redraw the covered character in the cursor's contrast color.
        const cell = cursor.cell;
        if (cell.cp != ' ' and cell.cp != 0) {
            self.glyph(
                .{ .cp = cell.cp, .attrs = cell.attrs },
                px,
                py,
                self.theme.cursor_text,
            );
        }
    }
};

fn fcolor(rgb: grid.Rgb) c.SDL_FColor {
    return .{
        .r = @as(f32, @floatFromInt(rgb.r)) / 255.0,
        .g = @as(f32, @floatFromInt(rgb.g)) / 255.0,
        .b = @as(f32, @floatFromInt(rgb.b)) / 255.0,
        .a = 1.0,
    };
}

fn blend(a: grid.Rgb, b: grid.Rgb, t: f32) grid.Rgb {
    const mix = struct {
        fn f(x: u8, y: u8, amt: f32) u8 {
            const fx: f32 = @floatFromInt(x);
            const fy: f32 = @floatFromInt(y);
            return @intFromFloat(std.math.clamp(fx + (fy - fx) * amt, 0, 255));
        }
    }.f;
    return .{ .r = mix(a.r, b.r, t), .g = mix(a.g, b.g, t), .b = mix(a.b, b.b, t) };
}
