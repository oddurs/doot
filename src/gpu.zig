//! Metal, from Zig's side of the C ABI.
//!
//! A thin wrapper over `src/platform/gpu.h`: types, `int` -> error mapping,
//! and the comptime assertions that keep the vertex layout in step across
//! three languages. No policy lives here -- `render.zig` decides what to
//! draw, `gpu.m` decides how Metal is told about it, and this file is the
//! word for word translation between them.

const std = @import("std");

pub const c = @cImport({
    @cInclude("gpu.h");
});

/// The shader, embedded rather than read at run time so the binary carries
/// its own renderer. `gpu.m` compiles it with `newLibraryWithSource:`.
pub const shader_source = @embedFile("platform/shader.metal");

/// How the fragment shader turns a vertex into a colour. Mirrors gpu.h.
pub const Mode = enum(u32) {
    /// The vertex colour, with no texture read at all.
    solid = c.GPU_MODE_SOLID,
    /// The vertex colour, masked by the atlas's alpha. Glyph bitmaps.
    mask = c.GPU_MODE_MASK,
    /// The atlas texel itself, premultiplied and untinted. D2's colour
    /// bitmaps; nothing emits it yet.
    color = c.GPU_MODE_COLOR,
};

/// One corner of a quad, in the layout the shader reads.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    u: f32,
    v: f32,
    mode: Mode,
};

// Three places declare this layout -- here, `gpu.h`, and `shader.metal` --
// and only two of them can be checked by a compiler. `_Static_assert` covers
// the C side; the Metal side is kept honest by declaring scalar fields, since
// a `float2` there would repack silently. This is the third check.
comptime {
    std.debug.assert(@sizeOf(Vertex) == 36);
    std.debug.assert(@sizeOf(Vertex) == @sizeOf(c.GpuVertex));
    std.debug.assert(@offsetOf(Vertex, "x") == 0);
    std.debug.assert(@offsetOf(Vertex, "y") == 4);
    std.debug.assert(@offsetOf(Vertex, "r") == 8);
    std.debug.assert(@offsetOf(Vertex, "a") == 20);
    std.debug.assert(@offsetOf(Vertex, "u") == 24);
    std.debug.assert(@offsetOf(Vertex, "v") == 28);
    std.debug.assert(@offsetOf(Vertex, "mode") == 32);
}

pub const Error = error{
    /// No Metal device, no unified memory, or a shader that would not
    /// compile. The only failure that comes with a sentence explaining it.
    GpuCreateFailed,
    GpuResizeFailed,
    GpuDrawFailed,
    GpuReadFailed,
    GpuPresentFailed,
};

/// Whatever `create` wrote into its error buffer, as a slice.
pub fn message(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

pub const Context = struct {
    handle: *c.GpuContext,

    /// `layer` is a `CAMetalLayer *`, or null for headless. On failure a
    /// sentence is written into `err`; read it with `message`.
    pub fn create(
        layer: ?*anyopaque,
        width: u32,
        height: u32,
        atlas_size: u32,
        err: []u8,
    ) Error!Context {
        if (err.len > 0) err[0] = 0;
        const handle = c.gpu_create(
            layer,
            width,
            height,
            atlas_size,
            shader_source.ptr,
            shader_source.len,
            err.ptr,
            err.len,
        ) orelse return Error.GpuCreateFailed;
        return .{ .handle = handle };
    }

    pub fn destroy(self: *Context) void {
        c.gpu_destroy(self.handle);
    }

    pub fn resize(self: *Context, width: u32, height: u32) Error!void {
        if (c.gpu_resize(self.handle, width, height) != 0) return Error.GpuResizeFailed;
    }

    /// `pixels` is RGBA8, `bytes_per_row` bytes to a row.
    pub fn uploadAtlas(
        self: *Context,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        pixels: [*]const u8,
        bytes_per_row: u32,
    ) void {
        c.gpu_upload_atlas(self.handle, x, y, w, h, pixels, bytes_per_row);
    }

    /// Clear to `clear` and draw the frame. One command buffer, one pass,
    /// one indexed draw.
    pub fn draw(
        self: *Context,
        clear: [3]f32,
        verts: []const Vertex,
        indices: []const u32,
    ) Error!void {
        const rc = c.gpu_draw(
            self.handle,
            clear[0],
            clear[1],
            clear[2],
            @ptrCast(verts.ptr),
            @intCast(verts.len),
            indices.ptr,
            @intCast(indices.len),
        );
        if (rc != 0) return Error.GpuDrawFailed;
    }

    /// Read the frame back as **BGRA** -- the render target's own format.
    /// The swizzle to RGBA belongs to the caller; this layer does not know
    /// what a PNG is.
    pub fn readPixels(
        self: *Context,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
        dst: []u8,
        dst_bytes_per_row: u32,
    ) Error!void {
        const rc = c.gpu_read_pixels(self.handle, x, y, w, h, dst.ptr, dst_bytes_per_row);
        if (rc != 0) return Error.GpuReadFailed;
    }

    /// Blit the frame to the window's next drawable. A no-op, and a success,
    /// when there is no window.
    pub fn present(self: *Context) Error!void {
        if (c.gpu_present(self.handle) != 0) return Error.GpuPresentFailed;
    }
};
