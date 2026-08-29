//  gpu.m -- Metal, and nothing above it.
//
//  Glue only, in the sense docs/roadmap/dependencies.md means it: nothing
//  here knows what a cell, a glyph, a theme or a PNG is. It is handed a
//  viewport, an atlas rectangle, vertices and indices; it hands back pixels.
//  Everything in this file would have to exist for a hypothetical Linux port
//  with Metal swapped for Vulkan, which is the test for whether it belongs.
//
//  Two design decisions worth stating up front, because both look like
//  omissions:
//
//  **Rendering always goes to an offscreen texture.** The layer, when there
//  is one, is a consumer of the result rather than the render target. SDL's
//  headless video driver cannot make a Metal window at all, so a design that
//  drew straight into a drawable would have no arbiter on CI. This one is
//  testable with no window server, which is more than the SDL path could
//  claim.
//
//  **Exactly one frame is in flight, deliberately, and it ends inside
//  `gpu_present`.** Present waits for the GPU before it returns, so control
//  never goes back to the caller with work outstanding. That is what makes
//  the `replaceRegion:` in `gpu_upload_atlas` -- which the caller issues
//  while building the *next* frame's vertices -- safe with no fence, and it
//  is the same blocking shape `SDL_RenderPresent` had. `gpu_draw` and
//  `gpu_read_pixels` wait too, so the invariant holds even for a caller
//  that never presents. Pipelining this would need an atlas fence and a
//  triple-buffered vertex ring; do not "optimise" it into existence by
//  accident.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <stdio.h>
#include <string.h>

#include "gpu.h"

// The layout the shader reads. If this ever fires, `shader.metal`'s Vertex
// struct and `gpu.zig`'s comptime asserts are wrong too.
_Static_assert(sizeof(GpuVertex) == 36, "GpuVertex must stay 36 packed bytes");
_Static_assert(offsetof(GpuVertex, mode) == 32, "GpuVertex.mode must sit last");

/// Everything Metal hands us. An Objective-C object rather than a C struct
/// so ARC owns every reference outright; the C side only ever sees the
/// opaque pointer `CFBridgingRetain` produces.
@interface GpuState : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) id<MTLSamplerState> sampler;
/// The frame is drawn here, always, window or no window.
@property(nonatomic, strong) id<MTLTexture> target;
@property(nonatomic, strong) id<MTLTexture> atlas;
@property(nonatomic, strong) id<MTLBuffer> vbuf;
@property(nonatomic, strong) id<MTLBuffer> ibuf;
/// The one command buffer in flight, or nil. See the header comment.
@property(nonatomic, strong) id<MTLCommandBuffer> pending;
/// nil when headless. Not owned by us -- SDL's view holds it.
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic) uint32_t width;
@property(nonatomic) uint32_t height;
@end

@implementation GpuState
@end

static GpuState *state(GpuContext *ctx) {
    return (__bridge GpuState *)ctx;
}

static void set_err(char *err, size_t err_len, const char *msg) {
    if (err == NULL || err_len == 0) return;
    snprintf(err, err_len, "%s", msg);
}

/// Wait for the frame in flight, then forget it. Idempotent.
static void wait_for_pending(GpuState *s) {
    id<MTLCommandBuffer> pending = s.pending;
    if (pending != nil) {
        [pending waitUntilCompleted];
        s.pending = nil;
    }
}

/// (Re)make the offscreen render target. Shared storage so `getBytes:` can
/// read it back with no blit and no `synchronizeTexture:`; see the unified
/// memory check in `gpu_create`.
static int make_target(GpuState *s, uint32_t width, uint32_t height) {
    if (width == 0) width = 1;
    if (height == 0) height = 1;
    if (s.target != nil && s.width == width && s.height == height) return 0;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;

    id<MTLTexture> t = [s.device newTextureWithDescriptor:td];
    if (t == nil) return -1;

    s.target = t;
    s.width = width;
    s.height = height;
    return 0;
}

/// A Shared buffer at least `need` bytes long, reusing `buf` when it already
/// is. Grows by powers of two so a resizing window is not reallocating every
/// frame.
static id<MTLBuffer> grow_buffer(id<MTLDevice> device, id<MTLBuffer> buf, size_t need) {
    if (buf != nil && buf.length >= need) return buf;
    size_t cap = 4096;
    while (cap < need) cap *= 2;
    return [device newBufferWithLength:cap options:MTLResourceStorageModeShared];
}

GpuContext *gpu_create(void *layer, uint32_t width, uint32_t height, uint32_t atlas_size,
                       const char *shader_src, size_t shader_len, char *err, size_t err_len) {
    @autoreleasepool {
        GpuState *s = [GpuState new];

        s.device = MTLCreateSystemDefaultDevice();
        if (s.device == nil) {
            set_err(err, err_len, "no Metal device on this machine");
            return NULL;
        }
        // Deliberately a hard boundary rather than a MTLStorageModeManaged
        // fallback: every machine this ships to or is tested on reports
        // unified memory, including CI's paravirtual device, so the other
        // branch would be code no test could ever reach.
        if (!s.device.hasUnifiedMemory) {
            set_err(err, err_len, "this Metal device has no unified memory, which the renderer requires");
            return NULL;
        }

        s.queue = [s.device newCommandQueue];
        if (s.queue == nil) {
            set_err(err, err_len, "could not create a Metal command queue");
            return NULL;
        }

        NSString *source = [[NSString alloc] initWithBytes:shader_src
                                                    length:shader_len
                                                  encoding:NSUTF8StringEncoding];
        NSError *nserr = nil;
        id<MTLLibrary> library = [s.device newLibraryWithSource:source options:nil error:&nserr];
        if (library == nil) {
            set_err(err, err_len,
                    nserr != nil ? nserr.localizedDescription.UTF8String : "the shader would not compile");
            return NULL;
        }

        id<MTLFunction> vertex_fn = [library newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fragment_fn = [library newFunctionWithName:@"fragment_main"];
        if (vertex_fn == nil || fragment_fn == nil) {
            set_err(err, err_len, "the shader has no vertex_main or no fragment_main");
            return NULL;
        }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vertex_fn;
        pd.fragmentFunction = fragment_fn;

        MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[0];
        ca.pixelFormat = MTLPixelFormatBGRA8Unorm;
        // Premultiplied: the fragment shader has already multiplied colour by
        // alpha, so the source factor is One rather than SourceAlpha.
        ca.blendingEnabled = YES;
        ca.rgbBlendOperation = MTLBlendOperationAdd;
        ca.alphaBlendOperation = MTLBlendOperationAdd;
        ca.sourceRGBBlendFactor = MTLBlendFactorOne;
        ca.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ca.sourceAlphaBlendFactor = MTLBlendFactorOne;
        ca.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        s.pipeline = [s.device newRenderPipelineStateWithDescriptor:pd error:&nserr];
        if (s.pipeline == nil) {
            set_err(err, err_len,
                    nserr != nil ? nserr.localizedDescription.UTF8String : "could not build the render pipeline");
            return NULL;
        }

        // Glyphs are always drawn at 1:1, so nearest keeps their edges
        // exactly as the rasterizer produced them.
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = MTLSamplerMinMagFilterNearest;
        sd.magFilter = MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        s.sampler = [s.device newSamplerStateWithDescriptor:sd];
        if (s.sampler == nil) {
            set_err(err, err_len, "could not create the atlas sampler");
            return NULL;
        }

        MTLTextureDescriptor *ad =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:atlas_size
                                                              height:atlas_size
                                                           mipmapped:NO];
        ad.usage = MTLTextureUsageShaderRead;
        ad.storageMode = MTLStorageModeShared;
        s.atlas = [s.device newTextureWithDescriptor:ad];
        if (s.atlas == nil) {
            set_err(err, err_len, "could not allocate the glyph atlas texture");
            return NULL;
        }

        if (make_target(s, width, height) != 0) {
            set_err(err, err_len, "could not allocate the offscreen render target");
            return NULL;
        }

        // NULL means headless, and that is the *only* thing that decides it.
        // Asking SDL which video driver is running would be asking the wrong
        // library a question this layer can answer itself.
        if (layer != NULL) {
            CAMetalLayer *l = (__bridge CAMetalLayer *)layer;
            l.device = s.device;
            l.pixelFormat = MTLPixelFormatBGRA8Unorm;
            // A drawable that is only ever a render target cannot be the
            // destination of a blit, and a blit is exactly how the offscreen
            // texture reaches it.
            l.framebufferOnly = NO;
            s.layer = l;
        }

        return (GpuContext *)CFBridgingRetain(s);
    }
}

void gpu_destroy(GpuContext *ctx) {
    if (ctx == NULL) return;
    @autoreleasepool {
        GpuState *s = state(ctx);
        wait_for_pending(s);
        CFBridgingRelease(ctx);
    }
}

int gpu_resize(GpuContext *ctx, uint32_t width, uint32_t height) {
    if (ctx == NULL) return -1;
    @autoreleasepool {
        GpuState *s = state(ctx);
        // The target the pending frame drew into is about to be replaced.
        wait_for_pending(s);
        return make_target(s, width, height);
    }
}

void gpu_upload_atlas(GpuContext *ctx, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                      const void *pixels, uint32_t bytes_per_row) {
    if (ctx == NULL || pixels == NULL || w == 0 || h == 0) return;
    GpuState *s = state(ctx);
    // Safe mid-frame with no fence only because one frame is in flight and
    // the previous one has already been waited on. See the header comment.
    [s.atlas replaceRegion:MTLRegionMake2D(x, y, w, h)
               mipmapLevel:0
                 withBytes:pixels
               bytesPerRow:bytes_per_row];
}

int gpu_draw(GpuContext *ctx, float clear_r, float clear_g, float clear_b,
             const GpuVertex *verts, uint32_t vert_count,
             const uint32_t *indices, uint32_t index_count) {
    if (ctx == NULL) return -1;
    @autoreleasepool {
        GpuState *s = state(ctx);
        if (s.target == nil) return -1;
        wait_for_pending(s);

        const BOOL has_geometry = (vert_count > 0 && index_count > 0);
        if (has_geometry) {
            size_t vbytes = (size_t)vert_count * sizeof(GpuVertex);
            size_t ibytes = (size_t)index_count * sizeof(uint32_t);
            s.vbuf = grow_buffer(s.device, s.vbuf, vbytes);
            s.ibuf = grow_buffer(s.device, s.ibuf, ibytes);
            if (s.vbuf == nil || s.ibuf == nil) return -1;
            memcpy(s.vbuf.contents, verts, vbytes);
            memcpy(s.ibuf.contents, indices, ibytes);
        }

        // The clear is the pass's load action rather than a draw of its own,
        // which is why `--frame-stats` reports one submission call and not
        // two.
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = s.target;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(clear_r, clear_g, clear_b, 1.0);

        id<MTLCommandBuffer> cb = [s.queue commandBuffer];
        if (cb == nil) return -1;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        if (enc == nil) return -1;

        if (has_geometry) {
            float viewport[2] = {(float)s.width, (float)s.height};
            [enc setRenderPipelineState:s.pipeline];
            [enc setVertexBuffer:s.vbuf offset:0 atIndex:0];
            [enc setVertexBytes:viewport length:sizeof(viewport) atIndex:1];
            [enc setFragmentTexture:s.atlas atIndex:0];
            [enc setFragmentSamplerState:s.sampler atIndex:0];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:index_count
                             indexType:MTLIndexTypeUInt32
                           indexBuffer:s.ibuf
                     indexBufferOffset:0];
        }

        [enc endEncoding];
        [cb commit];
        s.pending = cb;
        return 0;
    }
}

int gpu_read_pixels(GpuContext *ctx, uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                    void *dst, uint32_t dst_bytes_per_row) {
    if (ctx == NULL || dst == NULL || w == 0 || h == 0) return -1;
    @autoreleasepool {
        GpuState *s = state(ctx);
        if (s.target == nil) return -1;
        if (x + w > s.width || y + h > s.height) return -1;
        wait_for_pending(s);
        [s.target getBytes:dst
               bytesPerRow:dst_bytes_per_row
                fromRegion:MTLRegionMake2D(x, y, w, h)
               mipmapLevel:0];
        return 0;
    }
}

int gpu_present(GpuContext *ctx) {
    if (ctx == NULL) return -1;
    @autoreleasepool {
        GpuState *s = state(ctx);
        if (s.layer == nil) {
            // Headless: the offscreen texture already is the frame. Wait
            // anyway, so this function leaves nothing in flight whichever
            // path it took -- see the note below.
            wait_for_pending(s);
            return 0;
        }
        wait_for_pending(s);

        id<CAMetalDrawable> drawable = [s.layer nextDrawable];
        if (drawable == nil) return -1;
        id<MTLTexture> dst = drawable.texture;

        // Clamp to the smaller of the two in each dimension. A window
        // resized between gpu_resize and nextDrawable -- which is every
        // other frame while a corner is being dragged -- otherwise trips
        // Metal validation and aborts.
        uint32_t w = (uint32_t)dst.width < s.width ? (uint32_t)dst.width : s.width;
        uint32_t h = (uint32_t)dst.height < s.height ? (uint32_t)dst.height : s.height;
        if (w == 0 || h == 0) return -1;

        id<MTLCommandBuffer> cb = [s.queue commandBuffer];
        if (cb == nil) return -1;
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (blit == nil) return -1;
        [blit copyFromTexture:s.target
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(w, h, 1)
                    toTexture:dst
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];
        s.pending = cb;

        // The frame ends here, not at the top of the next one.
        //
        // Waiting at the *start* of the next gpu_draw would be one frame in
        // flight by the same arithmetic, but it would not be safe: the
        // caller uploads newly rasterized glyphs into the atlas while it is
        // building the next frame's vertices, which is before that wait.
        // With no window that upload would land on an atlas the previous
        // render pass was still sampling -- a race with no fence to stop it,
        // in exactly the headless path the gallery runs. Ending the frame
        // here means nothing is ever in flight when the caller has control,
        // and it keeps `--frame-stats`' `build` column measuring vertex
        // generation rather than the previous frame's vblank.
        wait_for_pending(s);
        return 0;
    }
}
