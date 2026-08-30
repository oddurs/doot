# Dependencies roadmap

What is borrowed, what is built, and the sprints that move the line. The
goal is aggressive and stated plainly: **the only things linked into the
binary are libc and the operating system's own frameworks.** Sized for one
person at 8–12 focused hours a week. Sprint prefix: **D**.

Arbiter: **`otool -L` and the gallery.** A dependency is gone when the
binary no longer loads it, and a replacement is correct when the
[gallery](experience.md) cannot tell the difference — or can, and the
difference was the point.

## The ownership rule

A library may be linked into the build only if it *is* the platform —
libc, AppKit, Metal, QuartzCore, UserNotifications. Anything else is
allowed as a **test oracle**: a tool the test suite compares against and
the binary never loads. CoreText is an oracle for glyph weight, HarfBuzz
for shaping fixtures, FreeType for the differential test that retires it,
esctest for conformance. The README's line — "nothing else is borrowed" —
becomes literally true and stays that way.

## Where we are

Two libraries, both used through a narrow seam, both replaceable behind
it. Nine of twelve modules already import nothing but `std`.

| Borrowed | What it provides here | Surface | Replaced by |
|---|---|---|---|
| **SDL3** | Window and Retina scale; the event pump; keyboard, text input, IME, dead keys; wheel; clipboard; a `CAMetalLayer` for the window; a mutex | ~50 symbols; the 11 left in `render.zig` are all window and init calls, none of which draw | ~~D0 (renderer)~~ **done**; D4 (everything else) |
| **FreeType** | Font file parsing, `cmap` lookup, outline rasterization, synthetic bold and oblique. About 5% of the library | 16 symbols in `font.zig` | D1, D2 |
| **libc** | `forkpty`, `ioctl`, `poll`, `execvp` | 12 symbols in `pty.zig` | Never. It is the kernel's interface |

Two facts about the target make this cheaper than it sounds, both checked
against the files on disk:

- **Every system face is TrueType `glyf`.** SF Mono is `glyf` + `fvar`/
  `gvar` (a variable font), Menlo is `glyf` + `morx`, Apple Color Emoji is
  `glyf` + `sbix`. No CFF anywhere, which removes the expensive half of a
  font parser. Emoji are PNG blobs, and `std.compress.flate` already
  inflates them.
- **Zig's clang compiles Objective-C.** `zig cc -fobjc-arc -framework
  Foundation` built and ran an `.m` file on this machine with no Xcode
  project. The platform layer can be written in the platform's language,
  compiled by our own toolchain, behind a C ABI.

And one about the code: the renderer already speaks in a single vertex
buffer and a single atlas texture
([sprint 2](completed/sprint-2-one-draw-call.md)), and `main.zig` is the
only file that knows what an SDL event is. The seams the swap needs are
the seams the code already has. [D0](completed/sprint-d0-gpu-path.md) has
since taken the drawing, and it took the seams as it found them: the vertex
buffer went to Metal unchanged.

## The shape of the platform layer

`src/platform/` holds Objective-C files compiled by `build.zig`, each
exposing a handful of C functions and callbacks to Zig. The rule for
that directory: **glue only, no logic.** No file branches on terminal
state; every file stays under 400 lines; the Zig side never sees an
`NSObject`. The test for whether something belongs there is whether it
would need to exist for a hypothetical Linux port — if yes, it is glue;
if no, it is logic and lives in Zig.

```
 Zig                                  Objective-C (glue)
 ─────────────────────────────────    ────────────────────────────────
 render.zig  vertices, atlas ───────► gpu.m      Metal: layer, pipeline,
                                                 buffers, present, readback
 main.zig    event loop, wake ──────► window.m   AppKit: NSWindow, NSView,
 input.zig   key → bytes      ◄────── input.m    NSTextInputClient, IME,
                                                 keys, scroll, clipboard
 (A1, X4, X5)                 ◄────── shell.m    menus, notifications,
                                                 appearance, blur
```

## The sprints

### D0 — Own the GPU path (one to two weeks) — **done**

Replace SDL's 2D renderer with Metal, behind SDL's window. SDL3 hands us
a `CAMetalLayer` for any window (`SDL_Metal_CreateView`,
`SDL_Metal_GetLayer`), so no windowing code changes. `gpu.m` exposes
`gpu_init(layer)`, `gpu_upload_atlas(rect, pixels)`,
`gpu_draw(vertices, indices, n)`, `gpu_present()`, and
`gpu_read_pixels()` for `--screenshot`. The vertex format is the one
`render.zig` already builds; the shader is a 30-line pass-through with an
orthographic projection, sampling one texture, with a per-vertex mode:
solid, alpha mask tinted by the vertex colour, or colour bitmap
(premultiplied, untinted — D2 needs it).

Vsync is `nextDrawable` pacing; `--frame-stats`' `present` column becomes
the wait for a drawable and is relabelled honestly. The `calls` column
reads 1.

**Do it in two commits.** The first is pixel-identical to SDL's output —
same non-sRGB drawable format, same blend — and the gallery proves it.
The second flips the drawable to `BGRA8Unorm_sRGB`, which makes the
hardware blend in linear light: that is [X1](experience.md)'s
gamma-correct text, ~~obtained by changing one enum~~, with the gallery diff
showing exactly what moved.

*Correction, measured:* **it is not one enum.** An `_sRGB` attachment also
*encodes* everything the pipeline writes, so the vertex colours must be
linearised in the shader and the clear colour on the Zig side, or every
solid colour on screen goes pale — `colors-14pt-1x` moves 39.96% of its
pixels if only the format is flipped. Three changes, and the sprint record
has the mutants that say so.

*Why here:* the smallest swap on this page with the largest downstream
effect. X1 needs a shader SDL cannot give us; D4 needs the layer to be
ours already. And it is the first Objective-C in the tree, so it sets
the glue-only convention with the simplest possible file.

*Done when:* the gallery is identical before the format flip; `build`
and `present` are within noise of the SDL numbers at 100×30 and 200×60;
`--screenshot` still works; `render.zig` contains no `SDL_` symbol.

*Risk:* low to medium. The only unknown is how much of Metal's object
soup ends up in `gpu.m`; the 400-line rule is the check.

*Result, first commit:* SDL's 2D renderer is gone; `render.zig` issues no
SDL drawing call. Windowed output is pixel-identical to the SDL build across
all eleven gallery scenes — **0 differing pixels**, not a tolerance. `gpu.m`
came to 396 lines, nine under the 400-line rule, which is close enough that
the rule earned its keep. `build` and `drawable` are within noise of
the SDL numbers at both geometries and `calls` reads 1.
See [the record](completed/sprint-d0-gpu-path.md).

*Result, second commit:* the drawable, the offscreen target and the
pipeline's colour attachment are `BGRA8Unorm_sRGB`, the shader linearises
vertex colours and `render.zig` linearises the clear colour, and the
hardware blends in linear light. Both `colors` captures stayed at **0
differing pixels** — solid fills round-trip decode→encode exactly — while
every capture containing text moved by 1.8–7.4% of pixels at a worst channel
delta of 46–53, entirely on antialiased edges, every one of them *lighter*.
Measured as linear-light ink, the renderer had been laying down **70–89% of
the coverage the rasterizer produced**, worst at 10pt 1×; it now lays down
all of it, which is why light-on-dark text looked thinner here than in a
native app. Reverse video pays about 9% the other way, and `dim` is
deliberately not retuned — it is still a lerp in sRGB byte space, and that
is [X1](experience.md)'s. `build`, `drawable` and `calls` are unmoved.

*Gate check, measured before starting:* the risk was mis-stated, and the
plan above needs one change.

**SDL's headless driver cannot make a Metal window at all.** The gallery
— which this sprint is verified by, and whose *done when* says "the
gallery is identical before the format flip" — runs under
`SDL_VIDEODRIVER=dummy`, and there:

```
window FAILED: Metal support is either not configured in SDL or not
available in current SDL video driver (dummy) or platform
```

So `SDL_Metal_CreateView` is not a path CI can take, and D0 as written
would land with its own arbiter switched off.

**Metal itself needs no window.** `MTLCreateSystemDefaultDevice`, an
offscreen `MTLTexture` render target, a render pass and `getBytes`
readback all work with no window server and no drawable — verified on an
M4 Pro, correct pixels back.

That settles the design rather than blocking it. `gpu.m` should render
into an offscreen texture *always*, and then either present it to the
layer's drawable when there is a window, or simply read it back when
there is not. `gpu_read_pixels` becomes the primary path rather than an
afterthought for `--screenshot`, and the renderer becomes testable with
no window server at all — which is more than the SDL path can claim.

*CI probe, run before writing any of it:* after D0 there is no software
fallback, so whether a GitHub runner has a GPU decides whether the gallery
survives the sprint. Measured on both runners in the matrix, with a
throwaway job compiling an Objective-C probe through `zig cc`:

| | macos-15 | macos-14 |
|---|---|---|
| Metal device | `Apple Paravirtual device` | **none** |
| unified memory | yes | — |
| runtime shader compile | ok | — |
| offscreen render + readback | correct | — |

Three conclusions.

**The gallery is safe**, because its job runs on `macos-15`. Runtime shader
compilation works there too, so `newLibraryWithSource:` is viable and D0
needs no Metal toolchain at build time — which matters, since `xcrun metal`
is not in the Command Line Tools.

**`macos-14` must never run the renderer.** It has no GPU. Today it only
compiles and runs the test suite, neither of which constructs a `Renderer`,
so nothing changes — but `gpu_create` failing by name rather than crashing
is what keeps that a clear message instead of a mystery.

**The non-unified-memory readback path should not be written.** Every
machine this ships to or tests on reports unified memory, including the
paravirtual device. A `MTLStorageModeManaged` branch with a
`synchronizeTexture:` would be code that cannot be exercised anywhere,
and untested code that looks correct is worse than an explicit boundary:
require unified memory and say so if it is ever absent. Revisit only if
[D5](#d5--one-binary-one-week) adds an x86_64 row, which would make it testable.

The sprint's second unknown is separate: its *done when* asks that
"`render.zig` contains no `SDL_` symbol", which cannot hold inside D0's
own scope. `render.zig` owns `SDL_Init`, `SDL_CreateWindow`,
`SDL_SetWindowTitle` and `SDL_GetWindowPixelDensity`, and this sprint
explicitly runs "behind SDL's window", deferring the window to D4. The
honest condition for D0 is that `render.zig` issues no SDL *drawing*
call — no `SDL_Render*`, no `SDL_Texture` — with windowing left to D4.

### D1 — Own the rasterizer (two to three weeks)

Replace FreeType with a TrueType parser and a rasterizer in Zig.

Tables: `head`, `maxp`, `hhea`, `hmtx`, `loca`, `glyf` (simple and
composite outlines — accented characters are composites), `cmap` formats
4 and 12 (12 for emoji and CJK beyond the BMP), `OS/2` (typographic
ascender, descender, line gap, and the `USE_TYPO_METRICS` bit), `name`
(family and subfamily, for picking the bold and italic faces out of a
`.ttc` and for `--font`). Variable fonts render the default instance, so
`gvar` is not needed; FreeType renders the same instance, which is what
makes the two comparable.

Rasterizer: flatten quadratics adaptively, accumulate signed area per
pixel, resolve to 8-bit coverage. The font-rs algorithm — about 400 lines,
exact, no hinting. macOS does not hint either, so "none, by
construction" is the answer X1 was going to reach anyway. Synthetic bold
is a coverage dilation, synthetic oblique is a shear of the outline;
both are fallbacks, since the `.ttc` index gives us real faces.

Font discovery: parse `name` tables from `/System/Library/Fonts`,
`/Library/Fonts` and `~/Library/Fonts` once at startup, index by family.
A font file is untrusted input — a corrupt one in `~/Library/Fonts` must
not crash the terminal — so the parser gets a fuzz target alongside the
VT parser's ([C0](correctness.md)).

**Retire FreeType by differential test, not by faith.** Before removal,
a test rasterizes every ASCII glyph, the box-drawing range and a CJK
sample through both and reports the mean absolute coverage difference
per glyph. Set the tolerance after seeing the number, write it into the
test with the reason, and only then delete the link line.

*Why here:* after D0, so the new coverage bitmaps go straight into an
atlas we control, and before [X2](experience.md), whose fallback chain
is a list of faces this parser loads.

*Done when:* `build.zig` links no FreeType; the differential test passes
at its stated tolerance; every face in the discovery index loads; the
fuzzer runs a minute clean; the gallery's typography page at three sizes
shows the difference the tolerance allows and nothing else.

*Risk:* medium. Composite glyphs and `cmap` 12 are the two things a
first draft forgets, and both show up as missing glyphs — which the
gallery's typography page exists to catch.

### D2 — Colour glyphs and atlas pages (one week)

`sbix` strikes are PNGs at fixed pixel sizes; pick the nearest strike at
or above the cell height and box-filter it down. A PNG decoder for the
one flavour Apple ships — 8-bit RGBA, non-interlaced, five filter types
over `std.compress.flate` — is about 150 lines and fails loudly on
anything else. Premultiply, upload, draw with D0's colour-bitmap vertex
mode across both cells of the wide pair.

Atlas pages land here too: a second 1024² page when the first fills, and
a generation counter so a page can be dropped and refilled. Today a full
atlas re-rasterizes the glyph every frame and never draws it; with CJK at
2× that is about 1,200 glyphs away.

*Done when:* the gallery's emoji line renders in colour; the CJK corpus
at 200×60 runs with `build` flat after the first page fills; an
interlaced or 16-bit PNG produces a logged error and an empty glyph, not
a crash.

*Risk:* low.

### D3 — Shaping for ligatures (two weeks) — **gated**

A GSUB reader for the monospace case, replacing the HarfBuzz
[X7](experience.md) was going to link. Lookup types 1 (single), 4
(ligature), 6 (chained context, all three formats — Fira Code uses the
coverage-based one) and the type 7 extension wrapper; features `calt`
and `liga`; script `DFLT`/`latn`. No GPOS — a monospace font has no
kerning to apply. Shape per run of identical style on a row, cache by
(text, style), map glyphs back to cells so the cursor and selection stay
per cell.

Menlo's `morx` is AAT, not GSUB, and is deliberately unsupported: nobody
wants Menlo's ligatures.

*Gate:* a font with a `GSUB` table the user has installed and asked for
(`ligatures = true`). The system faces do not need this sprint.

**HarfBuzz is the oracle.** Fixtures are `hb-shape` output for a set of
strings in Fira Code and JetBrains Mono, checked in; the test compares
glyph ids and cluster maps. The binary never loads HarfBuzz.

*Done when:* `->`, `!=`, `===` and `<=>` shape identically to the
fixtures; `build` at 200×60 with shaping on is within 20% of off.

*Risk:* medium. Chained contexts are where GSUB readers go wrong; the
fixtures are the whole safety net, so make the set large.

### D4 — Own the window (three to four weeks)

Replace SDL with AppKit, all at once, behind an interface defined first.

**Step one, a day:** write `Platform` — the Zig interface `main.zig`
talks to: create window, run loop, post wake, set title, clipboard get
and set, and the callbacks: key, text, scroll, resize, scale change,
focus, close. Port the SDL code to sit behind it. Nothing else changes.

**Step two, the sprint:** `window.m`, `input.m`, `shell.m` implement the
same interface with AppKit.

- `NSApplication` and its delegate: activation, `Cmd Q`, reopen.
- `NSWindow` with a full-size content view and a transparent titlebar —
  [X5](experience.md)'s chrome is now a property, not a shim.
- A custom `NSView` that adopts `NSTextInputClient`. This is the one hard
  part and the reason the sprint is not two weeks: `insertText`,
  `setMarkedText` (IME composition), `doCommandBySelector` (the keys that
  are commands), `keyDown` and `flagsChanged` to `input.zig`. Dead keys
  and Japanese input are the acceptance test.
- `scrollWheel` with `hasPreciseScrollingDeltas` and `momentumPhase` —
  [X3](experience.md)'s trackpad scrolling comes from here for free.
- The layer is D0's `CAMetalLayer`; `viewDidChangeBackingProperties`
  re-rasterizes on a scale change, which closes the 1×/2× bug.
- The reader thread's wake becomes an `NSEvent` of type
  `applicationDefined`, posted to the queue — the same shape as
  `SDL_PushEvent`, so the snapshot-under-lock structure survives
  untouched. The mutex becomes `std.Thread.Mutex`.
- `shell.m`: `NSMenu` for the menu bar, `UNUserNotificationCenter` for
  [A1](agentic.md), `effectiveAppearance` for [X4](experience.md),
  `NSVisualEffectView` for blur, the reduce-motion accessibility query.

Both implementations stay selectable by `-Dplatform=sdl|appkit` for one
release, then SDL is deleted. That is not "halfway": it is two complete
implementations behind one interface, with a switch. Halfway would be
AppKit calls inside the SDL path, and that never happens.

*Why here:* after D0 owns the layer, and after [A1](agentic.md) has put
the first `shell.m` function in the tree and shown the C-ABI convention
works. It replaces the Cocoa shim A1, X4 and X5 were each going to grow;
one layer instead of three shims.

*Done when:* `build.zig` links no SDL; the e2e suite, the gallery and
`--frame-stats` are unchanged; typing `é` via a dead key and a Japanese
word via IME produce the right bytes; `Cmd Q`, `Cmd W`, the menu bar and
trackpad momentum work; dragging between a 1× and a 2× display re-renders
sharp; idle wake-ups are still zero.

*Risk:* high — the largest sprint on any roadmap. Mitigated by the
interface-first step, the two-implementation switch, and the fact that
every behaviour it must preserve already has a test or a picture.

### D5 — One binary (one week)

After D1 and D4, the link line is libc and frameworks: Foundation,
AppKit, Metal, QuartzCore, UserNotifications. `zig build
-Dtarget=x86_64-macos` cross-compiles against the SDK on the same
runner; `lipo` makes the universal binary. [P0](platform.md)'s
static-link question is retired unasked, and [P5](platform.md)'s Intel
build is a flag.

*Done when:* `otool -L zig-out/bin/doot` lists only `/usr/lib` and
`/System`; the release app opens on a Mac with no Homebrew; the release
workflow's matrix has a comment explaining why it no longer needs one row
per architecture.

*Risk:* low.

## Why this order

- **D0 first** because it is small, because X1 cannot start without it,
  and because it establishes the glue-only convention on the easiest
  file.
- **D1 before X2.** The fallback chain is a list of faces; the parser is
  what loads them.
- **D2 is a week** once D0's vertex mode and D1's tables exist.
- **D3 gated** on a font that needs it; the system faces never will.
- **D4 after A1** has proven the C-ABI shim on one function, and after
  enough of X5's design questions are answered that the AppKit code is
  written once.
- **D5 is a consequence**, not a sprint of its own in any real sense.

## What stays borrowed, and why

- **libc and the kernel.** `forkpty` is not a dependency; it is the
  thing a terminal is.
- **The OS frameworks.** AppKit, Metal, UserNotifications. There is no
  from-scratch window.
- **Test oracles** — CoreText, HarfBuzz, FreeType, esctest, vttest, the
  UCD files. Never linked; always compared against.

## Not on this plan

- **A from-scratch PNG encoder, zlib, or PTY.** `std` has the inflater;
  the screenshot writer can stay BMP; the PTY is the kernel's.
- **Hinting.** The platform does not, and the gallery will show whether
  anyone can tell.
- **CFF and variable-instance rendering.** No system face needs either.
  A user font that does gets an error message naming the table, and a
  sprint if anyone asks.
- **Reimplementing IME.** `NSTextInputClient` is the platform's
  interface to it, not a library.
