# Sprint D0 — Own the GPU path (first half)

**Half done.** The renderer is ours; the sRGB flip is a separate change.

[D0](../dependencies.md#d0--own-the-gpu-path-one-to-two-weeks) was always two
commits: one that replaces SDL's 2D renderer with Metal and is *pixel-identical*
to what it replaced, and one that flips the drawable to `BGRA8Unorm_sRGB` and
makes the hardware blend in linear light. This record covers the first. Doing
the second in the same change would have meant a gallery diff nobody could
attribute, which is the entire reason the sprint was written as two.

## What was proposed

`gpu.m` exposing `gpu_init(layer)`, `gpu_upload_atlas`, `gpu_draw`,
`gpu_present` and `gpu_read_pixels`; a 30-line pass-through shader with an
orthographic projection and a per-vertex mode; the vertex format `render.zig`
already builds. SDL keeps the window.

## What the gate checks had already changed

Two things were measured before any of it was written, and both are recorded
in the roadmap rather than here.

**SDL's dummy video driver cannot make a Metal window**, so the gallery — the
sprint's own arbiter — could not have taken the `SDL_Metal_CreateView` path at
all. **Metal itself needs no window**: device, offscreen target, render pass
and `getBytes` readback all work with no window server. So the design became
*render offscreen always, present to a layer only if there is one*, with
`gpu_read_pixels` as the primary path rather than a `--screenshot` afterthought.

**CI's `macos-14` runner has no Metal device at all.** That makes
`gpu_create` failing by name, rather than trapping, load-bearing rather than
tidy.

## What it actually needed

**R5, checked first, because everything rested on it.** `updateSize` called
`SDL_GetRenderOutputSize`, which dies with the SDL renderer. A throwaway probe
compared it against `SDL_GetWindowSizeInPixels` in all six configurations that
matter — headless and windowed, at `--scale` auto, 1 and 2, before and after an
explicit resize. Identical in every one. Had they differed, the sprint stopped
there.

**The design held.** One `MTLRenderPipelineState`, colour attachment
`BGRA8Unorm`, premultiplied blending, one nearest/clamp sampler, an
`RGBA8Unorm` atlas, `MTLStorageModeShared` unconditionally, one command buffer
per frame, one `drawIndexedPrimitives`. `gpu.m` came to 396 lines against the
400-line glue rule — nine to spare, which is close enough that the rule earned
its keep rather than merely being satisfied.

**Three things were harder or different than the sprint text implied.**

*The vertex struct is a three-language ABI.* `gpu.h`, `gpu.zig` and
`shader.metal` all declare it, and only two of those can be checked by a
compiler. The Metal side is the dangerous one: declaring `float2 pos` instead
of `float x; float y;` would carry 8-byte alignment, silently repack the
36-byte struct, and show up as garbage geometry rather than as an error. So
the MSL struct is scalar fields only, with a comment saying why, and
`_Static_assert` plus a `comptime` block guard the other two.

*The `calls` column had to change meaning.* It reads 1 now, not 2, because the
clear is the render pass's `loadAction` rather than a submission of its own.
That is an accounting change and not a win — Sprint 2 already took this from
850–2,350 to 2, and there was never a third call to remove.

*Where the frame ends is a correctness question, not a timing one.* See below.

## The bug the frame timer found

The first draft waited for the previous frame's command buffer at the *top* of
`gpu_draw`. One frame in flight, by the arithmetic. `--frame-stats` then read:

| | 100×30 | 200×60 |
|---|---|---|
| `build` (avg) under SDL | 39–41 µs | 66–71 µs |
| `build` (avg), first draft | **350–381 µs** | **460–526 µs** |

A 9× regression in the column [sprint 2](sprint-2-one-draw-call.md) exists to
protect. The sum `build + drawable` was unchanged at one refresh interval, so
nothing had got slower — the wait for the previous frame's vblank had simply
moved from the end of one frame to the start of the next, and landed inside
`build`.

Chasing that turned up a real race behind it. The caller uploads newly
rasterized glyphs into the atlas *while building the next frame's vertices* —
which is before that wait. Windowed, the outstanding command buffer is the
previous present, a blit that does not read the atlas, so it was safe by
accident. **Headless, present returned immediately and the outstanding buffer
was the previous render pass, which samples the atlas.** A `replaceRegion:`
into a texture the GPU is still reading, with no fence, in exactly the path
the gallery runs.

The fix is one line of intent: the frame ends inside `gpu_present`, which
waits before returning, on both paths. Nothing is ever in flight when the
caller has control, the atlas upload needs no fence, and `build` measures
vertex generation again. The comment in `gpu.m` says all of that, because the
next person to read it will see two waits and want to delete one.

This is the sprint's argument for its own instrumentation: the race was not
found by testing, it was found by a timing column looking wrong.

## Result

**Claim A — pixel identity against the binary it replaces.** Both binaries run
**windowed**, so both go through Metal, over all eleven gallery scenes at their
gallery geometries:

**0 differing pixels. Every scene. Not a tolerance — zero.**

That is the real claim of this change, and it is stronger than the sprint asked
for. The projection matches SDL's to the bit (`x*2/w - 1`, `1 - y*2/h`, no
half-pixel offset), and premultiplied-in-shader blending against
`One`/`OneMinusSourceAlpha` produces the same bytes as SDL's straight-alpha
output against `SourceAlpha`/`OneMinusSourceAlpha`, which was the one thing
that could plausibly have differed by an ULP and did not.

**Claim B — the gallery, whose references came from SDL's *software*
renderer.** Exact identity is impossible here: software blends 8-bit integers
with truncation, GPUs round to nearest, and no `MTLBlendFactor` reproduces
truncation.

| capture | differing | % | worst |
|---|---|---|---|
| `colors-14pt-1x` | **0** | 0.00% | **0** |
| `colors-14pt-2x` | **0** | 0.00% | **0** |
| `typography-10pt-1x` | 4,188 | 5.93% | 4 |
| `typography-14pt-1x` | 7,076 | 5.24% | 4 |
| `tui-14pt-1x` | 5,152 | 4.97% | 2 |
| `typography-20pt-1x` | 11,927 | 4.62% | 4 |
| `attributes-14pt-1x` | 2,947 | 4.48% | 2 |
| `cursor-14pt-1x` | 1,102 | 3.10% | 2 |
| `typography-14pt-2x` | 14,974 | 2.93% | 3 |
| `attributes-14pt-2x` | 6,117 | 2.46% | 2 |
| `cursor-14pt-2x` | 2,477 | 1.84% | 2 |

`colors` draws rectangles and no glyphs, which makes it the oracle for
geometry, projection, the clear colour and channel order — the four things a
renderer swap gets wrong. It is byte-identical, and **a `colors-14pt-2x`
capture was added** so 2× has the same oracle. Its reference was checked
against the old binary before being committed: also 0.

The nine scenes containing text sit inside the pre-measured envelope of ≤6% of
pixels at a worst channel delta of 4. A throwaway script then checked
something stronger than the sprint asked: **every one of the 56,000 differing
pixels lies on an antialiased glyph edge. Not one solid-fill interior moved,
in any scene, at either scale.**

One correction to the sprint text. It asked that "every fully opaque pixel in
the other nine must match". That criterion is unsatisfiable as stated and
always was: the render target clears to alpha 1 and premultiplied blending
keeps it there, so *every* pixel in *every* capture is fully opaque, in both
the old references and the new ones. Checked, rather than assumed — one
distinct alpha value, 255, across the lot. The edge-versus-interior test above
is what the criterion was reaching for, and it passes.

The references now carry GPU rounding instead of a software renderer's integer
truncation — which is to say they have moved *toward* what anyone with a
window open has been looking at the whole time. The previous references were
the outlier.

**Frame timing**, `bench/dump.sh` at `PASSES=200`, average/worst µs per frame:

| | SDL, 100×30 | Metal, 100×30 | SDL, 200×60 | Metal, 200×60 |
|---|---|---|---|---|
| `lock` | 1–4 / 4–275 | 1–4 / 3–285 | 4–7 / 6–266 | 4 / 7–9 |
| `build` | 39–65 / 85–1301 | **44–62 / 75–808** | 66–92 / 121–2676 | **68–70 / 104–115** |
| `present` → `drawable` | 7988–8177 / 8889–8931 | **7680–7809 / 9573–9616** | 7415–7695 / 8589–8880 | **7136–7303 / 8816–8929** |
| `calls` | 2 | **1** | 2 | **1** |
| fps | 118–120 | 118–120 | 119–121 | 119–120 |
| pty MiB/s | 67.0–69.9 | 66.9–69.0 | 54.1–55.3 | 53.5–54.2 |

Within noise on every column that is meant to be, which was the *done when*.
The worst-case `build` is the one number that moved for the better — 1.3 ms
and 2.7 ms spikes are gone — but that is a one-run observation on a laptop and
not a claim anyone should plan against.

`zig build bench` is unchanged and was expected to be: it links neither SDL nor
the renderer. Reported for completeness, not as evidence.

## What this sets up

The second commit is one enum. `MTLPixelFormatBGRA8Unorm` becomes
`MTLPixelFormatBGRA8Unorm_sRGB` on the target and the layer, the hardware
starts blending in linear light, and [X1](../experience.md)'s gamma-correct
text arrives with a gallery diff that shows exactly what moved and nothing
else. Because this commit is pixel-identical, that diff is attributable in
full — which is what the two-commit split was for.

`GPU_MODE_COLOR` is wired through the ABI, the shader and `gpu.Mode` and
nothing emits it. [D2](../dependencies.md#d2--colour-glyphs-and-atlas-pages-one-week)'s
`sbix` bitmaps are its first caller.

[D4](../dependencies.md#d4--own-the-window-three-to-four-weeks) inherits a
layer that is already ours. `render.zig` keeps 11 SDL symbols, all of them
window and init calls — `SDL_Init`, `SDL_CreateWindow`, `SDL_SetWindowSize`,
`SDL_SetWindowTitle`, `SDL_GetWindowPixelDensity`, `SDL_GetWindowSizeInPixels`,
the three `SDL_Metal_*` calls, `SDL_DestroyWindow`, `SDL_Quit` — and not one
of them draws. The sprint's original *done when* asked for no `SDL_` symbol at
all in `render.zig`, which the roadmap's own gate check had already corrected
to "no SDL *drawing* call", since D0 runs behind SDL's window by construction.

## Traps for anyone touching this

- **Do not add a second frame in flight.** The atlas is written with
  `replaceRegion:` and no fence, and that is only safe because `gpu_present`
  drains the GPU before it returns. Pipelining needs a fence and a
  triple-buffered vertex ring first.
- **Do not add a `MTLStorageModeManaged` branch.** Every machine this ships to
  or is tested on reports unified memory, CI's paravirtual device included, so
  it would be code no test could reach. `gpu_create` fails by name instead.
  Revisit only if [D5](../dependencies.md#d5--one-binary) adds an x86_64 row.
- **Do not declare the MSL vertex struct with vector types.** Scalars only.
  The repack is silent.
- **Headlessness is `SDL_Metal_CreateView` returning null**, and nothing else.
  Never ask SDL which video driver is running.
- `gpu_read_pixels` returns **BGRA**. The swizzle lives in `render.zig`, where
  something already knows what a PNG is.
