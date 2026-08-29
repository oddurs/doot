/* The renderer's whole view of Metal.
 *
 * Hand-written rather than generated: this is the ABI, and it is short
 * enough to read in one sitting. `src/gpu.zig` @cImports it and asserts the
 * vertex layout at comptime; `gpu.m` implements it; nothing else includes it.
 *
 * The contract: nothing allocated on the Objective-C side crosses this
 * boundary except the opaque `GpuContext *`. Every `int` is 0 for success
 * and -1 for failure, and only `gpu_create` produces a message.
 */
#ifndef TERMINATOR_GPU_H
#define TERMINATOR_GPU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* How the fragment shader turns a vertex into a colour.
 *
 *   SOLID  the vertex colour, no texture read at all
 *   MASK   the vertex colour, with the atlas's alpha as coverage -- glyphs
 *   COLOR  the atlas texel itself, premultiplied and untinted -- D2's
 *          colour bitmaps. Wired up here; nothing emits it yet.
 */
enum {
    GPU_MODE_SOLID = 0,
    GPU_MODE_MASK = 1,
    GPU_MODE_COLOR = 2
};

/* One corner of a quad. Positions are framebuffer pixels, origin top-left,
 * y down -- the shader does the projection. Colour is straight (not
 * premultiplied) alpha; the shader premultiplies.
 *
 * Packed scalars on purpose. The Metal side declares the matching struct
 * with scalar fields too: a `float2` there would carry 8-byte alignment and
 * silently repack the 36 bytes written here. */
typedef struct GpuVertex {
    float x, y;
    float r, g, b, a;
    float u, v;
    uint32_t mode;
} GpuVertex;

typedef struct GpuContext GpuContext;

/* Create a device, a queue, the pipeline and the offscreen target.
 *
 * `layer` is a `CAMetalLayer *`, or NULL for headless -- which is the only
 * thing that distinguishes the two. Rendering always goes to an offscreen
 * texture; the layer is an optional consumer of the result.
 *
 * Returns NULL on failure, having written a sentence into `err`. That is
 * the whole reason this function has an error string and the others do not:
 * a machine with no Metal device (CI's macos-14 runner) must say so rather
 * than crash. */
GpuContext *gpu_create(void *layer, uint32_t width, uint32_t height, uint32_t atlas_size,
                       const char *shader_src, size_t shader_len, char *err, size_t err_len);

void gpu_destroy(GpuContext *ctx);

/* Point the offscreen target at a new size. A no-op when nothing changed. */
int gpu_resize(GpuContext *ctx, uint32_t width, uint32_t height);

/* Copy RGBA8 pixels into a rectangle of the atlas texture. */
void gpu_upload_atlas(GpuContext *ctx, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                      const void *pixels, uint32_t bytes_per_row);

/* Clear the offscreen target and draw the whole frame into it: one command
 * buffer, one render pass, one indexed draw. */
int gpu_draw(GpuContext *ctx, float clear_r, float clear_g, float clear_b,
             const GpuVertex *verts, uint32_t vert_count,
             const uint32_t *indices, uint32_t index_count);

/* Read a rectangle of the offscreen target back, as **BGRA** -- the
 * target's own format. Swizzling to RGBA is the caller's job; this layer
 * does not know what a PNG is. */
int gpu_read_pixels(GpuContext *ctx, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                    void *dst, uint32_t dst_bytes_per_row);

/* Blit the offscreen target to the layer's next drawable and present it.
 * Returns 0 immediately when there is no layer. */
int gpu_present(GpuContext *ctx);

#ifdef __cplusplus
}
#endif

#endif /* TERMINATOR_GPU_H */
