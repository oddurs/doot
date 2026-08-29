//! Drawing the grid.
//!
//! Two passes: background runs, then glyphs. Every quad -- backgrounds, glyph
//! bitmaps, underlines, the cursor -- goes into one vertex buffer with its
//! colour and a draw mode on the vertices, sampling one atlas texture, and
//! the whole frame is submitted to Metal as a single indexed draw. A solid
//! fill carries mode `solid` and reads no texture at all; a glyph carries
//! mode `mask` and takes its coverage from the atlas's alpha.
//!
//! The GPU is ours as of D0: `src/gpu.zig` over `src/platform/gpu.m`. SDL
//! still supplies the window, the event pump and the input, which D4 takes.
//! Nothing in this file issues an SDL *drawing* call.
//!
//! Every frame is rendered into an offscreen texture, and the window -- when
//! there is one -- is a consumer of the result rather than the render target.
//! That is what lets the gallery run with no window server at all.
//!
//! A frame is drawn in two steps that run under different locking rules.
//! `snapshot` copies the visible cells out of the terminal and must be called
//! with the terminal mutex held; `draw` renders that copy and presents it, and
//! must be called with the mutex released. The wait for the GPU and for a
//! drawable lives inside present, and while it sat inside the lock the reader
//! thread could not feed a byte for the whole of every frame -- bulk output
//! was throttled to a few KiB per refresh. The copy costs microseconds; the
//! wait costs milliseconds.

const std = @import("std");
const grid = @import("grid.zig");
const font = @import("font.zig");
const gpu = @import("gpu.zig");
const theme = @import("theme.zig");
const stats = @import("stats.zig");
const png = @import("png.zig");
const sel = @import("sel.zig");
const cli = @import("cli.zig");
const Terminal = @import("terminal.zig").Terminal;

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const Error = error{
    SdlInit,
    WindowFailed,
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
    /// The selected columns of each row, already **resolved**: one entry per
    /// row, half-open, `x0 == x1` where nothing is selected.
    ///
    /// A resolved span rather than the selection itself, because a selection
    /// is a pair of line ids and resolving one needs the scrollback -- which
    /// `draw` cannot touch, since it runs after the terminal mutex has been
    /// released. Resolving here costs one `contains` test per row, inside a
    /// lock that is already memcpying twelve thousand cells.
    sel: []sel.Span = &.{},

    fn row(self: *const Frame, y: usize) []const grid.Cell {
        return self.cells[y * self.cols ..][0..self.cols];
    }
};

/// A colour on the vertices: straight alpha, 0..1 per channel. The shader
/// premultiplies.
const Color = struct { r: f32, g: f32, b: f32, a: f32 };

/// Texture coordinate of the centre of the atlas's reserved white texel.
///
/// Solid fills used to sample it, which is what let them share the glyph
/// draw call under SDL. The `solid` vertex mode reads no texture now, so
/// this is only the coordinate those quads carry -- pointing it somewhere
/// meaningful rather than at (0, 0) keeps the fallback honest for whoever
/// adds the next mode. The texel itself still lives in `font.zig`.
const white_uv: f32 = 0.5 / @as(f32, font.atlas_size);

pub const Renderer = struct {
    window: *c.SDL_Window,
    /// SDL's `CAMetalLayer`-bearing view, or null when there is no window
    /// server. Null is the *only* signal that we are headless: the layer is
    /// then null too, and `gpu_present` returns without doing anything.
    metal_view: c.SDL_MetalView,
    gpu: gpu.Context,
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
    verts: std.ArrayList(gpu.Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    /// Submission calls made by the frame being built, for `--frame-stats`.
    calls: u64 = 0,
    /// `--screenshot`: save the first frame drawn after this instant, then
    /// forget the path. Read back before present, so no OS permission is
    /// needed to check what the renderer actually produced.
    screenshot_path: ?[:0]const u8 = null,
    screenshot_after_ns: u64 = 0,

    /// Backing-store pixels per logical pixel (2.0 on a Retina display).
    /// Refreshed by `updateSize`, so it follows the window between displays.
    scale: f32,
    /// `--scale`, kept so the refresh cannot overwrite it.
    scale_override: ?f32,
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

        // A view whose backing layer is a `CAMetalLayer`, which is all we
        // want from SDL here. It fails under the dummy video driver -- there
        // is no window server to make a layer in -- and that failure is the
        // headless path, not an error: `gpu.m` renders offscreen either way.
        const metal_view = c.SDL_Metal_CreateView(window);
        errdefer if (metal_view != null) c.SDL_Metal_DestroyView(metal_view);
        const layer: ?*anyopaque = if (metal_view != null)
            c.SDL_Metal_GetLayer(metal_view)
        else blk: {
            // Expected headless, and the gallery depends on it. But on a
            // machine that does have a window server this means a window
            // nothing will ever be presented to, and a blank window with
            // no explanation is the worst way to learn that -- so say so
            // once, on stderr, rather than leave it silent.
            std.debug.print(
                "terminator: no Metal layer ({s}); rendering offscreen, nothing will be shown\n",
                .{c.SDL_GetError()},
            );
            break :blk null;
        };

        // The display's density, and the density we draw at. They differ
        // only when --scale asks for one the display does not have, which
        // is how a 2x gallery capture is reproducible on a 1x CI runner.
        const density = c.SDL_GetWindowPixelDensity(window);
        const scale = cli.effectiveScale(scale_override, density);
        // Rasterize at device resolution: a 14pt font on a 2x display is a
        // 28px face, not a 14px face scaled up and blurry.
        const px_size: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(font_size_pt)) * scale));
        var f = try font.Font.init(px_size, null);
        errdefer f.deinit();

        var atlas = try font.Atlas.init(alloc);
        errdefer atlas.deinit();

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

        var px_w: c_int = 0;
        var px_h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(window, &px_w, &px_h);

        // The one place a Metal failure is reported by name. A machine with
        // no GPU -- CI's macos-14 runner is one -- has to say so rather than
        // trap somewhere inside the first frame.
        var gpu_err: [256]u8 = undefined;
        var ctx = gpu.Context.create(
            layer,
            @intCast(px_w),
            @intCast(px_h),
            font.atlas_size,
            &gpu_err,
        ) catch |err| {
            std.debug.print(
                "terminator: could not start the GPU renderer: {s}\n",
                .{gpu.message(&gpu_err)},
            );
            return err;
        };
        errdefer ctx.destroy();

        // The atlas starts empty except for its white texel, and the texture
        // has to carry that from the first frame. Uploading the whole thing
        // also gives the rest of it defined contents.
        try ctx.uploadAtlas(0, 0, font.atlas_size, font.atlas_size, atlas.pixels.ptr, font.atlas_size * 4);

        var self = Renderer{
            .window = window,
            .metal_view = metal_view,
            .gpu = ctx,
            .font = f,
            .atlas = atlas,
            .theme = theme.default,
            .scale = scale,
            .scale_override = scale_override,
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
        self.atlas.alloc.free(self.frame.sel);
        self.gpu.destroy();
        self.atlas.deinit();
        self.font.deinit();
        if (self.metal_view != null) c.SDL_Metal_DestroyView(self.metal_view);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }

    /// Re-measure the window and point the render target at the new size.
    ///
    /// `SDL_GetWindowSizeInPixels` rather than the `SDL_GetRenderOutputSize`
    /// this used to call: both were measured to agree exactly, headless and
    /// windowed, at 1x and 2x, and only the first survives D4.
    pub fn updateSize(self: *Renderer) void {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.window, &w, &h);
        self.px_w = @intCast(w);
        self.px_h = @intCast(h);
        // `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED` arrives here, so this is
        // where the density has to be re-read: `toPixels` converts every mouse
        // coordinate with it, and a window dragged from a 2x display to a 1x
        // one would otherwise keep halving clicks for the rest of the session.
        // `--scale` still wins -- see `cli.effectiveScale`.
        self.scale = cli.effectiveScale(self.scale_override, c.SDL_GetWindowPixelDensity(self.window));
        // A failed resize leaves the old target in place: the next frame is
        // drawn at the stale size rather than not drawn at all.
        self.gpu.resize(@intCast(w), @intCast(h)) catch {};
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
        try self.gpu.uploadAtlas(
            0,
            0,
            font.atlas_size,
            font.atlas_size,
            self.atlas.pixels.ptr,
            font.atlas_size * 4,
        );
    }

    pub fn setTitle(self: *Renderer, title: [:0]const u8) void {
        _ = c.SDL_SetWindowTitle(self.window, title.ptr);
    }

    /// The effective colors for a cell, after reverse video, dim and bold.
    ///
    /// `selected` suppresses reverse video. A selected cell is drawn on the
    /// selection colour whatever its own background was, so leaving the swap
    /// in would paint a reverse-video run -- a `less` status line, a shell's
    /// highlighted completion -- in the theme's dark background on top of the
    /// dark selection, and the text would disappear while it was selected.
    fn cellColors(self: *const Renderer, cell: grid.Cell, selected: bool) struct { fg: grid.Rgb, bg: grid.Rgb } {
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
        if (cell.attrs.reverse and !selected) std.mem.swap(grid.Rgb, &fg, &bg);
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
        if (self.frame.sel.len != rows) {
            const spans = try self.atlas.alloc.alloc(sel.Span, rows);
            self.atlas.alloc.free(self.frame.sel);
            self.frame.sel = spans;
        }
        self.frame.cols = cols;
        self.frame.rows = rows;
        // The selection is resolved once, here, and turned into a span per
        // row. `draw` has no scrollback to resolve a line id against, and by
        // the time it runs the mutex is gone.
        const resolved: ?sel.Resolved = if (term.selection) |s| sel.resolve(term, s) else null;
        for (0..rows) |y| {
            @memcpy(self.frame.cells[y * cols ..][0..cols], term.viewRow(y));
            self.frame.sel[y] = if (resolved) |r|
                sel.spanFor(r, sel.viewOrd(term, y), term.viewRow(y)) orelse .{}
            else
                .{};
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
        self.calls = 0;
        self.verts.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();

        const cw: f32 = @floatFromInt(self.font.metrics.cell_w);
        const ch: f32 = @floatFromInt(self.font.metrics.cell_h);
        const ox: f32 = @floatFromInt(self.pad_px);
        const oy: f32 = @floatFromInt(self.pad_px);
        const frame = &self.frame;

        // -- pass 1: background runs ---------------------------------------
        //
        // A selected row is drawn in three pieces: the columns before the
        // selection, the selection itself, and the columns after it. The two
        // outer pieces batch into runs exactly as an unselected row does; the
        // selection is **one** rect whatever is under it, so a highlight over
        // a rainbow costs the same as one over blank space.
        for (0..frame.rows) |y| {
            const row = frame.row(y);
            const ry = oy + @as(f32, @floatFromInt(y)) * ch;
            const span = frame.sel[y];
            if (span.x0 >= span.x1) {
                self.bgRuns(row, 0, ox, ry, cw, ch);
                continue;
            }
            const x0: usize = @min(span.x0, row.len);
            const x1: usize = @min(span.x1, row.len);
            self.bgRuns(row[0..x0], 0, ox, ry, cw, ch);
            self.rect(
                ox + @as(f32, @floatFromInt(x0)) * cw,
                ry,
                cw * @as(f32, @floatFromInt(x1 - x0)),
                ch,
                self.theme.selection,
            );
            self.bgRuns(row[x1..], x1, ox, ry, cw, ch);
        }

        // -- pass 2: glyphs ------------------------------------------------
        for (0..frame.rows) |y| {
            const row = frame.row(y);
            const ry = oy + @as(f32, @floatFromInt(y)) * ch;
            const span = frame.sel[y];
            for (row, 0..) |cell, cx| {
                if (cell.wide == .spacer) continue; // drawn by its wide partner
                if (cell.cp == ' ' or cell.cp == 0) {
                    if (!cell.attrs.underline and !cell.attrs.strike) continue;
                }
                const selected = cx >= span.x0 and cx < span.x1;
                const colors = self.cellColors(cell, selected);
                const px = ox + @as(f32, @floatFromInt(cx)) * cw;
                self.glyph(cell, px, ry, colors.fg);
            }
        }

        self.cursorQuads(ox, oy, cw, ch);

        // -- submit --------------------------------------------------------
        // One call: the clear is the render pass's load action rather than a
        // draw of its own, which is why this reads 1 where SDL's path read 2.
        const bg = fcolor(self.theme.bg);
        if (self.gpu.draw(
            .{ bg.r, bg.g, bg.b },
            self.verts.items,
            self.indices.items,
        )) {
            // Counted, not asserted. `--frame-stats` documents this column
            // as the way to notice a frame that fragmented into more than
            // one submission; hard-coding it to 1 would make that untrue.
            self.calls += 1;
        } else |_| {}

        const t1 = stats.nowNs();
        if (self.screenshot_path) |path| {
            if (t1 >= self.screenshot_after_ns) {
                self.screenshot_path = null;
                self.saveScreenshot(path);
            }
        }
        // Headless, this returns immediately: there is no layer to present
        // to, and the frame already exists in the offscreen texture.
        self.gpu.present() catch {};
        return .{ .build = t1 - t0, .drawable = stats.nowNs() - t1, .calls = self.calls };
    }

    /// Background runs for one slice of a row, starting at column `x_off`.
    ///
    /// Adjacent cells with the same background become one rect, which is what
    /// keeps a full-width coloured line to a single quad. Cells matching the
    /// theme's own background draw nothing at all.
    fn bgRuns(self: *Renderer, cells: []const grid.Cell, x_off: usize, ox: f32, ry: f32, cw: f32, ch: f32) void {
        if (cells.len == 0) return;
        var x: usize = 0;
        var bg = self.cellColors(cells[0], false).bg;
        while (x < cells.len) {
            var run: usize = 1;
            var next = bg;
            while (x + run < cells.len) : (run += 1) {
                next = self.cellColors(cells[x + run], false).bg;
                if (!std.meta.eql(next, bg)) break;
            }
            if (!std.meta.eql(bg, self.theme.bg)) {
                self.rect(
                    ox + @as(f32, @floatFromInt(x_off + x)) * cw,
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

    /// The grid's geometry in device pixels, for `sel.cellAt`. Glue: the
    /// arithmetic that uses it is in `sel.zig`, where it can be tested
    /// without a window.
    pub fn cellMetrics(self: *const Renderer, cols: usize, rows: usize) sel.Metrics {
        return .{
            .pad = self.pad_px,
            .cell_w = self.font.metrics.cell_w,
            .cell_h = self.font.metrics.cell_h,
            .cols = cols,
            .rows = rows,
        };
    }

    /// A window-space pointer position in device pixels. SDL reports the
    /// mouse in logical units; everything above is measured in pixels.
    pub fn toPixels(self: *const Renderer, x: f32, y: f32) struct { x: i32, y: i32 } {
        return .{
            .x = @intFromFloat(@round(x * self.scale)),
            .y = @intFromFloat(@round(y * self.scale)),
        };
    }

    /// Append one quad: two triangles over `x0..x1` by `y0..y1`, sampling
    /// atlas `ua..ub` by `va..vb`, in one flat colour, drawn with `mode`.
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
        color: Color,
        mode: gpu.Mode,
    ) void {
        const alloc = self.atlas.alloc;
        const base: u32 = @intCast(self.verts.items.len);
        const v = struct {
            fn make(x: f32, y: f32, u: f32, vv: f32, col: Color, m: gpu.Mode) gpu.Vertex {
                return .{
                    .x = x,
                    .y = y,
                    .r = col.r,
                    .g = col.g,
                    .b = col.b,
                    .a = col.a,
                    .u = u,
                    .v = vv,
                    .mode = m,
                };
            }
        }.make;
        // An out-of-memory frame is drawn without this quad rather than not
        // at all; the next frame gets another go.
        self.verts.appendSlice(alloc, &.{
            v(x0, y0, ua, va, color, mode),
            v(x1, y0, ub, va, color, mode),
            v(x1, y1, ub, vb, color, mode),
            v(x0, y1, ua, vb, color, mode),
        }) catch return;
        self.indices.appendSlice(alloc, &.{
            base, base + 1, base + 2,
            base, base + 2, base + 3,
        }) catch {
            self.verts.items.len -= 4;
        };
    }

    /// A solid rectangle. It carries the white texel's coordinate, but the
    /// `solid` mode reads no texture at all -- multiplying by an exactly-1.0
    /// texel was a no-op, so this is the same output with one fewer
    /// dependent read.
    fn rect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: grid.Rgb) void {
        self.quad(x, y, x + w, y + h, white_uv, white_uv, white_uv, white_uv, fcolor(color), .solid);
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
                    // The atlas carries coverage in alpha; the colour is on
                    // the vertices.
                    .mask,
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
    /// Read out of the offscreen target rather than captured from the
    /// screen, so this needs no screen-recording permission, returns exactly
    /// what the renderer produced, and works with no window at all -- which
    /// is what makes it an acceptance test rather than a photograph.
    fn saveScreenshot(self: *Renderer, path: [:0]const u8) void {
        // Crop to the size the grid asked for. Setting the window size is
        // done in logical units, so on a 2x display an odd pixel height
        // rounds up by one and the same capture differs by a row between
        // machines. Cropping makes a reference reproducible anywhere.
        const full_w: u32 = @intCast(@max(self.px_w, 0));
        const full_h: u32 = @intCast(@max(self.px_h, 0));
        const w = if (self.capture_w > 0) @min(self.capture_w, full_w) else full_w;
        const h = if (self.capture_h > 0) @min(self.capture_h, full_h) else full_h;
        if (w == 0 or h == 0) return;

        const alloc = self.atlas.alloc;
        const pixels = alloc.alloc(u8, w * h * 4) catch return;
        defer alloc.free(pixels);
        self.gpu.readPixels(0, 0, w, h, pixels, w * 4) catch return;

        // The render target is BGRA, because that is the format a drawable
        // wants. Turning that into the encoder's RGBA is this side's job:
        // the platform layer does not know what a PNG is.
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            std.mem.swap(u8, &pixels[i], &pixels[i + 2]);
        }

        const bytes = png.encode(alloc, .{ .w = w, .h = h, .pixels = pixels }) catch return;
        defer alloc.free(bytes);

        const file = std.c.fopen(path.ptr, "wb") orelse return;
        defer _ = std.c.fclose(file);
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, file);
    }

    /// A region the packer produced is always inside the atlas, so a
    /// failure here is a bug rather than a condition -- but dropping the
    /// glyph is better than dropping the frame, and the next frame retries.
    fn uploadAtlasRegion(self: *Renderer, r: font.Rect) void {
        const offset = (@as(usize, r.y) * font.atlas_size + r.x) * 4;
        self.gpu.uploadAtlas(
            r.x,
            r.y,
            r.w,
            r.h,
            self.atlas.pixels.ptr + offset,
            font.atlas_size * 4,
        ) catch {};
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

fn fcolor(rgb: grid.Rgb) Color {
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
