// The whole shader. Compiled at runtime by `newLibraryWithSource:`, because
// `xcrun metal` is not in the Command Line Tools and a build that needs Xcode
// is a dependency by another name.

#include <metal_stdlib>
using namespace metal;

// Scalar fields only, to match gpu.h's GpuVertex byte for byte. A `float2`
// or `float4` here would carry 8- or 16-byte alignment and silently repack
// the struct, which reads as garbage geometry rather than as an error.
struct Vertex {
    float x;
    float y;
    float r;
    float g;
    float b;
    float a;
    float u;
    float v;
    uint mode;
};

struct Varying {
    float4 position [[position]];
    float4 color;
    float2 uv;
    // Integer varyings must be flat; there is nothing to interpolate
    // between three corners that all carry the same mode.
    uint mode [[flat]];
};

// Positions arrive as framebuffer pixels, origin top-left, y down. No
// half-pixel offset: the quads are already on integer pixel boundaries, and
// adding one would shift every glyph half a pixel against the reference.
vertex Varying vertex_main(uint vid [[vertex_id]],
                           device const Vertex *v [[buffer(0)]],
                           constant float2 &viewport [[buffer(1)]])
{
    device const Vertex &in = v[vid];
    Varying out;
    out.position = float4(in.x * 2.0 / viewport.x - 1.0,
                          1.0 - in.y * 2.0 / viewport.y,
                          0.0,
                          1.0);
    out.color = float4(in.r, in.g, in.b, in.a);
    out.uv = float2(in.u, in.v);
    out.mode = in.mode;
    return out;
}

// Output is premultiplied, which is what the pipeline's One /
// OneMinusSourceAlpha blend expects.
fragment float4 fragment_main(Varying in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]],
                              sampler samp [[sampler(0)]])
{
    // A solid fill reads no texture. The atlas still reserves a white texel
    // and multiplying by an exactly-1.0 texel would be a no-op, so this is
    // the same output with one fewer dependent read.
    if (in.mode == 0u) {
        return float4(in.color.rgb * in.color.a, in.color.a);
    }

    float4 texel = atlas.sample(samp, in.uv);

    if (in.mode == 1u) {
        // A glyph: the atlas carries coverage in alpha, the vertex carries
        // the colour.
        float a = in.color.a * texel.a;
        return float4(in.color.rgb * a, a);
    }

    // A colour bitmap, already premultiplied in the atlas; the vertex only
    // fades it.
    return texel * in.color.a;
}
