//! Drawing the grid.
//!
//! Two passes per row: fill background runs, then draw glyphs. Splitting them
//! means every background is a batch of solid rects and every glyph comes from
//! one texture, which is what keeps a full repaint down to a handful of draw
//! calls no matter how busy the screen is.
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

const atlas_bytes = font.atlas_size * font.atlas_size * 4;

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

pub const Renderer = struct {
    window: *c.SDL_Window,
    sdl: *c.SDL_Renderer,
    atlas_tex: *c.SDL_Texture,
    font: font.Font,
    atlas: font.Atlas,
    theme: theme.Theme,
    frame: Frame = .{},

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

        const scale = c.SDL_GetWindowPixelDensity(window);
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
            .pad_px = @intFromFloat(@round(pad * scale)),
        };
        self.updateSize();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
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

        // Clear the texture so stale glyphs can't bleed through the gaps
        // between newly packed ones.
        const blank = try self.atlas.alloc.alloc(u8, atlas_bytes);
        defer self.atlas.alloc.free(blank);
        @memset(blank, 0);
        _ = c.SDL_UpdateTexture(self.atlas_tex, null, blank.ptr, font.atlas_size * 4);
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
    pub fn draw(self: *Renderer) stats.FrameTimes {
        const t0 = stats.nowNs();
        self.setDrawColor(self.theme.bg);
        _ = c.SDL_RenderClear(self.sdl);

        const cw: f32 = @floatFromInt(self.font.metrics.cell_w);
        const ch: f32 = @floatFromInt(self.font.metrics.cell_h);
        const ox: f32 = @floatFromInt(self.pad_px);
        const oy: f32 = @floatFromInt(self.pad_px);
        const frame = &self.frame;

        for (0..frame.rows) |y| {
            const row = frame.row(y);
            const ry = oy + @as(f32, @floatFromInt(y)) * ch;

            // -- pass 1: background runs -------------------------------
            var x: usize = 0;
            while (x < row.len) {
                const colors = self.cellColors(row[x]);
                var run: usize = 1;
                while (x + run < row.len) : (run += 1) {
                    const next = self.cellColors(row[x + run]);
                    if (!std.meta.eql(next.bg, colors.bg)) break;
                }
                if (!std.meta.eql(colors.bg, self.theme.bg)) {
                    self.setDrawColor(colors.bg);
                    var r = c.SDL_FRect{
                        .x = ox + @as(f32, @floatFromInt(x)) * cw,
                        .y = ry,
                        .w = cw * @as(f32, @floatFromInt(run)),
                        .h = ch,
                    };
                    _ = c.SDL_RenderFillRect(self.sdl, &r);
                }
                x += run;
            }

            // -- pass 2: glyphs ----------------------------------------
            for (row, 0..) |cell, cx| {
                if (cell.wide == .spacer) continue; // drawn by its wide partner
                if (cell.cp == ' ' or cell.cp == 0) {
                    if (!cell.attrs.underline and !cell.attrs.strike) continue;
                }
                const colors = self.cellColors(cell);
                const px = ox + @as(f32, @floatFromInt(cx)) * cw;
                self.drawGlyph(cell, px, ry, colors.fg);
            }
        }

        self.drawCursor(ox, oy, cw, ch);
        const t1 = stats.nowNs();
        _ = c.SDL_RenderPresent(self.sdl);
        return .{ .build = t1 - t0, .present = stats.nowNs() - t1 };
    }

    fn drawGlyph(self: *Renderer, cell: grid.Cell, px: f32, py: f32, fg: grid.Rgb) void {
        const m = self.font.metrics;

        if (cell.cp != ' ' and cell.cp != 0 and !cell.attrs.hidden) {
            const found = self.atlas.get(
                &self.font,
                cell.cp,
                cell.attrs.bold,
                cell.attrs.italic,
            ) catch return;

            if (found.added) |rect| self.uploadAtlasRegion(rect);
            const g = found.glyph;
            if (g.w > 0 and g.h > 0) {
                const src = c.SDL_FRect{
                    .x = @floatFromInt(g.x),
                    .y = @floatFromInt(g.y),
                    .w = @floatFromInt(g.w),
                    .h = @floatFromInt(g.h),
                };
                const dst = c.SDL_FRect{
                    .x = px + @as(f32, @floatFromInt(g.left)),
                    .y = py + @as(f32, @floatFromInt(m.ascent - g.top)),
                    .w = @floatFromInt(g.w),
                    .h = @floatFromInt(g.h),
                };
                _ = c.SDL_SetTextureColorMod(self.atlas_tex, fg.r, fg.g, fg.b);
                _ = c.SDL_RenderTexture(self.sdl, self.atlas_tex, &src, &dst);
            }
        }

        const cw: f32 = @floatFromInt(m.cell_w);
        const thick: f32 = @floatFromInt(m.underline_thickness);
        if (cell.attrs.underline) {
            self.setDrawColor(fg);
            var r = c.SDL_FRect{
                .x = px,
                .y = py + @as(f32, @floatFromInt(m.ascent + m.underline_pos)),
                .w = cw,
                .h = thick,
            };
            _ = c.SDL_RenderFillRect(self.sdl, &r);
        }
        if (cell.attrs.strike) {
            self.setDrawColor(fg);
            var r = c.SDL_FRect{
                .x = px,
                .y = py + @as(f32, @floatFromInt(m.ascent)) * 0.65,
                .w = cw,
                .h = thick,
            };
            _ = c.SDL_RenderFillRect(self.sdl, &r);
        }
    }

    fn uploadAtlasRegion(self: *Renderer, rect: font.Rect) void {
        const r = c.SDL_Rect{
            .x = @intCast(rect.x),
            .y = @intCast(rect.y),
            .w = @intCast(rect.w),
            .h = @intCast(rect.h),
        };
        const offset = (@as(usize, rect.y) * font.atlas_size + rect.x) * 4;
        _ = c.SDL_UpdateTexture(
            self.atlas_tex,
            &r,
            self.atlas.pixels.ptr + offset,
            font.atlas_size * 4,
        );
    }

    fn drawCursor(self: *Renderer, ox: f32, oy: f32, cw: f32, ch: f32) void {
        const cursor = self.frame.cursor orelse return;

        const px = ox + @as(f32, @floatFromInt(cursor.x)) * cw;
        const py = oy + @as(f32, @floatFromInt(cursor.y)) * ch;
        var box = c.SDL_FRect{ .x = px, .y = py, .w = cw, .h = ch };

        if (!self.focused) {
            // Unfocused windows get a hollow box, so you can tell at a glance
            // which terminal will receive your keystrokes.
            self.setDrawColor(self.theme.cursor);
            _ = c.SDL_RenderRect(self.sdl, &box);
            return;
        }

        self.setDrawColor(self.theme.cursor);
        _ = c.SDL_RenderFillRect(self.sdl, &box);

        // Redraw the covered character in the cursor's contrast color.
        const cell = cursor.cell;
        if (cell.cp != ' ' and cell.cp != 0) {
            self.drawGlyph(
                .{ .cp = cell.cp, .attrs = cell.attrs },
                px,
                py,
                self.theme.cursor_text,
            );
        }
    }
};

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
