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
    /// **Linear light**, not sRGB -- see `srgb_to_linear`.
    float4 color;
    float2 uv;
    // Integer varyings must be flat; there is nothing to interpolate
    // between three corners that all carry the same mode.
    uint mode [[flat]];
};

// The sRGB electro-optical transfer function, 0..1 in, linear light out.
//
// The colour attachment is `BGRA8Unorm_sRGB`, so the hardware decodes the
// destination, blends in linear light, and **encodes whatever this shader
// writes** on the way back out. Vertex colours arrive as sRGB bytes over
// 255 -- that is what a theme entry and an SGR truecolour triple are -- so
// without this they would be handed to the encoder as if they were already
// linear and stored far too light: 0x80 would land near 188, and every
// solid colour on screen would go pale.
//
// Alpha is deliberately not converted, here or anywhere. It is glyph
// coverage, and coverage is a linear quantity already. Converting it is
// the classic way to make gamma-correct text merely *differently* wrong.
static inline float3 srgb_to_linear(float3 c)
{
    // select(a, b, cond) is b where cond holds. The low branch's base is
    // >= 0.052 for any c >= 0, so `pow` never sees a negative base even
    // though both sides are evaluated.
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}

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
    // Once per vertex rather than once per fragment: all four corners of a
    // quad carry the same colour, so the interpolator sees three equal
    // values and reproduces them, and a `pow` per pixel of a full-screen
    // grid is work with nothing to show for it.
    out.color = float4(srgb_to_linear(float3(in.r, in.g, in.b)), in.a);
    out.uv = float2(in.u, in.v);
    out.mode = in.mode;
    return out;
}

// Output is premultiplied **linear** light, which is what the pipeline's
// One / OneMinusSourceAlpha blend against an `_sRGB` attachment expects: the
// hardware decodes the destination, adds, and encodes the result.
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
    //
    // Nothing emits this mode yet. When D2's `sbix` PNGs do, their texels
    // will be sRGB-encoded *and* premultiplied, and this line will be
    // wrong: decoding premultiplied values needs the alpha divided out
    // first, or the atlas needs to hold linear premultiplied data and be
    // an `RGBA8Unorm_sRGB` texture with a straight-alpha upload. Left as
    // it is rather than guessed at, because there is no caller to test
    // either choice against. See D2.
    return texel * in.color.a;
}
