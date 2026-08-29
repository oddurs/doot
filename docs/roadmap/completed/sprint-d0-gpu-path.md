# Sprint D0 — Own the GPU path

**Done, in two commits.** The renderer is ours, and it blends in linear light.

[D0](../dependencies.md#d0--own-the-gpu-path-one-to-two-weeks) was always two
commits: one that replaces SDL's 2D renderer with Metal and is *pixel-identical*
to what it replaced, and one that flips the drawable to `BGRA8Unorm_sRGB` and
makes the hardware blend in linear light. Doing them together would have meant
a gallery diff nobody could attribute, which is the entire reason the sprint
was written as two. The first commit is everything down to
[what it set up](#what-this-sets-up); the second starts at
[the sRGB flip](#the-second-commit--the-srgb-flip).

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

**CI's `macos-14` runner has no Metal device at all** -- measured directly
by a probe job on that runner, which reported `device=NONE` while the same
probe on `macos-15` reported `Apple Paravirtual device` with unified memory.
The two runners differ; a green gallery job proves only what `macos-15` can
do, because that is where the gallery runs. That makes
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

The second commit was written down here as "one enum":
`MTLPixelFormatBGRA8Unorm` becomes `MTLPixelFormatBGRA8Unorm_sRGB` on the
target and the layer, the hardware starts blending in linear light, and
[X1](../experience.md)'s gamma-correct text arrives with a gallery diff that
shows exactly what moved and nothing else. Because this commit is
pixel-identical, that diff is attributable in full — which is what the
two-commit split was for.

**"One enum" was wrong**, and the next section is what it actually took.

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
  or is tested on *and that has a Metal device at all* reports unified
  memory -- CI's `macos-15` paravirtual device included, while `macos-14`
  has no device and never constructs a `Renderer`. So
  it would be code no test could reach. `gpu_create` fails by name instead.
  Revisit only if [D5](../dependencies.md#d5--one-binary) adds an x86_64 row.
- **Do not declare the MSL vertex struct with vector types.** Scalars only.
  The repack is silent.
- **Headlessness is `SDL_Metal_CreateView` returning null**, and nothing else.
  Never ask SDL which video driver is running.
- `gpu_read_pixels` returns **BGRA**. The swizzle lives in `render.zig`, where
  something already knows what a PNG is.

## What it costs at startup

`newLibraryWithSource:` compiles the shader on every launch: **27.5 ms** on
the first call in a process, 0.3 ms once the in-process cache is warm. SDL
shipped a precompiled `metallib` and paid none of it, so this is real
latency the swap added, and it is not on the frame path where
`--frame-stats` would have caught it.

It is the price of not making full Xcode a build dependency -- `xcrun metal`
is not in the Command Line Tools. If it ever matters, caching the compiled
library under `~/Library/Caches` is a self-contained change behind the same
ABI. Recorded here so the next person finds a number rather than rediscovers
the cost.

---

# The second commit — the sRGB flip

## It was not one enum, and shipping it as one would have been a regression

Both the sprint text and the section above call this "one enum". That is
wrong, and the mistake is worth writing down because it is the kind that
looks finished and is not.

An `_sRGB` colour attachment does two things, not one. It decodes the
destination before blending -- the half everybody means -- and it **encodes
whatever the pipeline writes** on the way back out. Today's vertex colours
are sRGB bytes over 255 handed through unchanged, which is exactly right for
a plain `Unorm` target and exactly wrong for an `_sRGB` one: they would be
treated as linear and re-encoded, so `0x80` would be stored as about 188 and
every solid colour on screen would go pale. The measurement is in
["what the mutants say"](#what-the-mutants-say) below: flip only the format
and `colors-14pt-1x` moves **39.96%** of its pixels, interiors included.

So three changes, together, and none of them optional:

1. `MTLPixelFormatBGRA8Unorm` -> `MTLPixelFormatBGRA8Unorm_sRGB` on the
   offscreen target, the pipeline's colour attachment and the `CAMetalLayer`.
   They are one `kTargetFormat` constant in `gpu.m` now, because Metal
   validates the pipeline against the attachment and a layer that disagreed
   would make the *window* wrong while the gallery stayed green -- the one
   failure this project's arbiter structurally cannot see.
2. **The shader linearises vertex colours**, once per vertex rather than once
   per fragment: all four corners of a quad carry the same colour, so the
   interpolator has three equal values to reproduce, and a `pow` per pixel of
   a full-screen grid buys nothing.
3. **`render.zig` linearises the clear colour** separately, because it never
   passes through a shader -- it goes straight into `MTLClearColor`. It is
   the theme background over most of the screen, so getting this one wrong is
   the most visible failure available.

**Alpha is never converted, anywhere.** Glyph coverage is a linear quantity
already; running it through a transfer function is the classic way to make
gamma-correct text merely *differently* wrong. This is structural rather than
careful: vertex alpha is always 1.0, and coverage arrives from an
`RGBA8Unorm` atlas that the hardware does not decode.

The transfer function itself lives in `theme.zig` as `srgbToLinear`, beside
the palette rather than in the renderer -- it is a property of the colour
space those bytes are written in, not of how they are drawn, and there it is
in a module the unit tests already build with no window.

## Result: the gallery

`colors` is the oracle, exactly as the first commit set it up to be. Solid
fills round-trip decode->encode, so a zero there says the linearisation is
right on both paths and a non-zero would have named which one was missed.

| capture | differing | % | worst | direction |
|---|---|---|---|---|
| `colors-14pt-1x` | **0** | 0.00% | **0** | — |
| `colors-14pt-2x` | **0** | 0.00% | **0** | — |
| `selection-14pt-1x` | 3,726 | 7.36% | 46 | all lighter |
| `typography-10pt-1x` | 4,238 | 6.00% | 46 | all lighter |
| `typography-14pt-1x` | 7,085 | 5.25% | 46 | all lighter |
| `tui-14pt-1x` | 5,153 | 4.97% | 46 | all lighter |
| `typography-20pt-1x` | 11,913 | 4.61% | 46 | all lighter |
| `attributes-14pt-1x` | 2,979 | 4.53% | 53 | all lighter |
| `selection-wide-14pt-2x` | 7,978 | 4.17% | 46 | all lighter |
| `selection-rect-14pt-2x` | 7,978 | 4.17% | 46 | all lighter |
| `cursor-14pt-1x` | 1,100 | 3.10% | 46 | all lighter |
| `typography-14pt-2x` | 15,026 | 2.94% | 46 | all lighter |
| `attributes-14pt-2x` | 6,137 | 2.47% | 53 | all lighter |
| `cursor-14pt-2x` | 2,479 | 1.84% | 46 | all lighter |

Not "at or near zero" for `colors` -- **zero**, at both scales, on the nose.
The hardware's decode and encode are exact inverses at 8 bits for every one
of the theme's colours, the 256-colour cube and the truecolour ramp, so no
tolerance was needed and none was granted.

Three things were checked about the 84,000 pixels that did move, because a
count and a percentage cannot tell a correction from a different mistake:

- **Not one solid-fill interior moved**, in any capture, at either scale.
- **Every differing pixel got lighter.** Not most: all 84,000.
- **The new value is what an independent linear-light blend predicts.** A
  throwaway script recovered each edge pixel's coverage from the *old* value,
  blended the same coverage in linear light in Python and re-encoded: over
  `typography-14pt-1x` and `-2x`, 22,111 edge pixels, worst
  |predicted − actual| = **3 codes**, and that residual is the quantisation
  of the recovered coverage rather than a disagreement about the maths.

Alpha is 255 everywhere in both, as it has been since the first commit.

## Does it actually look better

Yes, and it is worth being specific about why, because "correct" and "better"
are different claims and only one of them was guaranteed going in.

The honest risk was that linear-light blending makes thin strokes thinner, and
that a dark theme with light text would come out correct and uglier. **The
measurement says the opposite, and so does the sprint's own premise.** Under
sRGB-space blending a partially covered pixel at coverage α over a near-black
background lands at roughly `fg·α`; in linear light it lands at
`fg·α^(1/2.4)`, which is *brighter*. Light-on-dark antialiased edges get
lighter, so the strokes get heavier, not thinner — which is the direction the
sprint text wanted and the opposite of what it predicted.

Quantified, as total linear-light ink over each `typography` capture — the
coverage integral the rasterizer actually produced, against what reached the
screen:

| capture | ink before / ink after |
|---|---|
| `typography-10pt-1x` | **0.705** |
| `typography-14pt-1x` | 0.807 |
| `typography-20pt-1x` | 0.843 |
| `typography-14pt-2x` | 0.885 |

The old renderer was putting down **70–89% of the glyph's real coverage**, and
worst exactly where it hurts most: small type at 1×. That is the whole of why
light-on-dark text looked thinner here than in a native app, and it is now
gone rather than compensated for.

Looked at, not just counted, at 6–7× nearest-neighbour zoom, before over
after: at 14pt 1× the difference is obvious and good — stems have weight,
the greyness is gone, bold reads as bold. At 10pt 1× it is larger still and
still an improvement; the text was spindly and is now legible, at the cost of
slightly tighter counters in `e` and `a`. At 14pt 2× it is subtle, as
expected: most coverage values at 2× are already near 0 or 1, so there is
less for the transfer function to move. `tui`'s box-drawing rules and green
check marks gain the most per pixel, and text over the selection highlight —
previously the weakest thing in the gallery — is the single clearest win.

**The cost, stated plainly.** The correction is not symmetric, and reverse
video pays for it. Dark text on a light run gets *lighter*, which is to say
thinner: over the `reverse` block in `attributes-14pt-1x` the dark ink drops
from 382.6 to 349.1 in linear light, about 9%. That is the true coverage too
— the old value was 10% too heavy — but "true" and "preferred" are not the
same word, and a `less` status line is now a shade weaker than it was. It is
the smaller effect by some margin and it is on the rarer case, so the trade is
clearly worth taking; it is recorded because nothing else will notice it.

The remaining gap is stem darkening, which is what a native renderer adds on
top of correct blending rather than instead of it. That is
[X1](../experience.md)'s, and X1 now starts from a renderer that is right
rather than one that is compensating.

## What was deliberately left alone

**`dim`.** `cellColors` computes it as a lerp between background and
foreground **in sRGB byte space**, and that has not changed. The dim colour
is byte-for-byte what it was — `#757b82` appears in both the old and new
`attributes` captures — and only its glyph edges moved, exactly like every
other glyph's. What *is* now inconsistent is that the lerp producing it is
the last colour arithmetic in the program still done in sRGB while everything
around it blends in linear light. Retuning it is [X1](../experience.md)'s
job, and doing it here would have put an unattributable change inside the one
commit whose whole value is that its diff is attributable.

**The colour-bitmap vertex mode.** `GPU_MODE_COLOR` still returns the atlas
texel unconverted. Nothing emits it. When
[D2](../dependencies.md#d2--colour-glyphs-and-atlas-pages-one-week)'s `sbix`
PNGs do, their texels will be sRGB-encoded *and* premultiplied, and that line
will be wrong — decoding premultiplied values needs the alpha divided out
first, or the atlas needs to hold linear premultiplied data. Guessing between
the two with no caller to test either against would have been writing
untestable code, so the choice is left to D2 with a comment saying so.

## What the mutants say

Green tests prove nothing until they have been watched failing, and that
applies twice over here: the whole change is three lines of arithmetic in
three languages, and two of the three have no test framework at all.

`srgbToLinear` has a unit test. The first version of it passed **ten** of
eleven deliberate breakages and let one through: moving the knee from 0.04045
to 0.4045 keeps every landmark the test checked, because the landmark *is*
the knee and both branches agree there by construction. Four reference points
along the curved branch and a continuity bound across the 256 codes close it.
Eleven of eleven now — exponent 2.2, inverted transfer, multiply for divide,
the sign of the 0.055 offset, the knee an order of magnitude either way, the
straight branch as identity, the straight branch deleted, 1.055 dropped,
12.92 mistyped.

The other two sites have no unit test and cannot have one, so they were
mutated against the gallery instead — the point of which is not that a
mistake is caught but *how it looks* when it is:

| mutant | `colors-14pt-1x` | `typography-14pt-1x` |
|---|---|---|
| clear colour left sRGB-encoded | 59.12% differ, interiors move | 99.28% differ, all lighter |
| shader leaves vertex colours sRGB | 39.96% differ, interiors move | 5.88% differ, 375 interiors |
| format flipped, nothing linearised | 99.08% differ, interiors move | 100.00% differ, all **darker** |
| glyph coverage linearised too | **0**, identical | 5.26% differ, all **darker** |

The last row is the one to remember. Linearising coverage as if it were
colour leaves `colors` at zero and moves the same edge pixels by a similar
count — it is indistinguishable from the correct change if you read only the
gallery's two columns. What separates them is the **direction**: the
correction makes every edge pixel lighter, the mistake makes every one
darker. That is why the table above carries a direction column, and why this
paragraph exists.

A fifth mutant, linearising the vertex *alpha*, changes nothing at all: vertex
alpha is always 1.0 and `srgbToLinear(1) = 1`. That is a fact about the
current renderer rather than a safety property, and it stops being true the
moment a vertex carries a real alpha.

## Frame timing

`bench/dump.sh` at `PASSES=200`, windowed, average/worst µs per frame, before
and after on the same machine in the same session:

| | before, 100×30 | after, 100×30 | before, 200×60 | after, 200×60 |
|---|---|---|---|---|
| `lock` | 2 / 4–10 | 2 / 5–8 | 4–5 / 7–42 | 4–5 / 7–19 |
| `build` | 51 / 76–103 | 48–51 / 80–134 | 69–75 / 105–184 | 68–78 / 104–141 |
| `drawable` | 8001–8172 / 8584–8669 | 8104–8169 / 9089–9359 | 7669–7970 / 8567–8772 | 7929–8009 / 8604–8820 |
| `calls` | 1 | **1** | 1 | **1** |
| fps | 119–120 | 119–120 | 119–120 | 119 |
| pty MiB/s | 63.6–66.1 | 61.9–64.9 | 50.6–53.3 | 47.4–53.6 |

Within noise on every column, which is what was expected: the conversion is
three `pow` calls per *vertex*, and the frame is pinned to vblank regardless.
`calls` still reads 1. First-second rows are excluded from the ranges above
in both runs; they carry start-up.

`zig build bench` is unchanged and links neither SDL nor the renderer.
`zig build audit`, `check-corpora`, `zig fmt --check` and the 376 tests —
including the L0 replay checksum test — all pass.

## `--screenshot`

Unchanged, and `png.zig` needed no edit. `getBytes:` hands back the texture's
stored bytes, and an `_sRGB` texture stores sRGB-encoded bytes — the format
governs how the *hardware* reads and writes the texture, not what is in it.
Checked rather than assumed, headless and windowed: the theme background
reads back as exactly `10141a`, the foreground `c8d0d8`, the cursor
`7fd6c1`, indexed red `e06c75`, alpha 255. A PNG has carried sRGB bytes all
along and still does.

## Traps this commit adds

- **The three pixel formats are one constant on purpose.** A layer that
  disagreed with the target would make the window wrong while every gallery
  capture stayed green, because the gallery reads the offscreen texture and
  never touches a drawable. That failure mode has no arbiter; the constant
  is the arbiter.
- **Never linearise alpha.** Not the vertex alpha, not `texel.a`. It is
  coverage. The gallery *will* catch it, but only if you read the direction
  of the change and not just the count — see the mutant table.
- **A new colour that reaches Metal without passing through the shader needs
  `theme.srgbToLinear` applied by hand.** Today that is exactly one: the
  clear colour. `MTLClearColor` is the trap because it looks like data rather
  than like a draw.
- **`dim` is still computed in sRGB byte space** and is now the odd one out.
  It is not an oversight; see above.

## One number in this record was already wrong

It says `gpu.m` "came to 396 lines against the 400-line glue rule -- nine to
spare". The file on `main` before this commit is **414 lines**, and `git log`
shows only the one commit ever touching it, so the 396 was never true of what
landed. This commit adds 14 more, for 428.

Said out loud rather than quietly left, because the 400-line rule exists to be
checked and a record that reports a passing number for a failing file is worse
than no number. Nothing here is load-bearing enough to justify deleting
somebody else's rationale to get under the line, so the overage is flagged
rather than papered over: it wants its own change, and the honest options are
to split the pipeline setup out of `gpu_create` or to move the file's 36-line
header essay into this record where the rest of the reasoning already lives.
