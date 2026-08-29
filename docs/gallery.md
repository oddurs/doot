# The gallery

```sh
zig build gallery                 # render and diff against the references
zig build gallery -- --update     # accept the current renders
```

The arbiter for the [experience roadmap](roadmap/experience.md), the way
`zig build bench` is for the [performance](roadmap/performance.md) one. The
performance rule is that a claim carries a number or it is a guess; nothing
above the renderer has a number, so visual work is judged by pictures
instead.

Eleven captures render one canonical screen each through the real parser,
grid and renderer, and are compared pixel by pixel against a committed PNG.

## What it measures

Per capture: the rendered size, how many pixels differ from the reference,
and the worst single-channel delta.

```
  capture                       size    differing     worst  result
  ---------------------- ----------- ------------ ---------  ----------------
  typography-14pt-1x         678x199            0         0  identical
  cursor-14pt-1x              444x80           17       194  0.05% of pixels
```

`worst` separates the two kinds of change that matter. A handful of pixels
at a large delta is a shape moving — a glyph, a rule, the cursor. Many
pixels at a delta of 1 or 2 is a colour or blending change. The example
above is the cursor drawn one pixel narrower.

**It never fails the build.** Like the bench, it reports and CI posts the
result; a diff is usually an intended visual change and the reviewer is the
one who decides. Renders land in `bench/gallery/current/`, which is not
committed.

## How it runs headless

**We always render offscreen; a window is an optional consumer.** Every frame
is drawn into a `MTLTexture` that no display owns, and only then blitted to
the window's drawable — if there is a window. `--screenshot` reads that
texture back directly. So a capture is exactly what the renderer produced, it
needs no screen-recording permission, and it does not need a window server.

`SDL_VIDEODRIVER=dummy` — put into the child's environment by `gallery.zig`
itself — is what removes the window: under it `SDL_Metal_CreateView` returns
null, there is no layer, and present becomes a no-op. Metal itself needs none
of this; `MTLCreateSystemDefaultDevice` and an offscreen render target work
with no window server at all. (The `offscreen` driver does not work either;
it fails to create a window.)

`--scale N` tells the app to pretend the display has that pixel density
rather than asking it. That is the only way a 2× capture is reproducible on
a 1× machine, and it is why the gallery can assert Retina rendering from CI.

Captures are cropped to the grid's own pixel size. A window's size is set in
logical units, so on a 2× display an odd pixel height rounds up by one and
the same capture would differ by a row depending on the machine that took
it. A reference has to be reproducible anywhere or it is not a reference.

PNGs are written by `src/png.zig`, about a hundred lines over
`std.compress.flate` — 8-bit RGBA, no interlacing, filter 0. The project
links libc and the system's own frameworks and nothing else
([dependencies.md](roadmap/dependencies.md)), and a picture format is not a
good reason to break that.

## The scenes

`bench/gallery/*.sh`, each printing a fixed byte stream:

| scene | what it covers |
|---|---|
| `typography` | printable ASCII, descenders and ascenders, box drawing, blocks, braille, CJK, emoji |
| `attributes` | every SGR attribute, alone and combined |
| `colors` | the 16 ANSI slots, the 256-colour cube, a truecolour ramp |
| `tui` | a scroll region, a framed panel and a status line — the shape an agent TUI draws |
| `cursor` | the cursor, in a scene whose only interesting feature is the cursor |

`typography` is captured at 10, 14 and 20 pt, and at 1× and 2×, because
baseline placement and cell rounding are what change between sizes.

**The scenes are scripts, not programs.** Not `vim`, not `htop`: their
output varies with version, terminal size, locale and whatever files are
lying around, and a pixel diff cannot tell that apart from a regression.
The bench corpora are committed files for the same reason. Real-program
screens want recorded byte streams, which is what
[A0](roadmap/agentic.md) will produce.

## Adding a scene

Write `bench/gallery/<name>.sh` so that it prints and exits — the capture is
taken from the final frame, so nothing needs to sleep. Add a row to
`captures` in `src/gallery.zig`, run `zig build gallery -- --update`, and
commit the PNG along with the change that made it necessary.

Keep captures small. They are committed and they stay in the history: the
eleven here are 172 KB in total.

## When the references need regenerating

Any intended visual change. Run with `--update`, look at every image that
moved, and say in the PR why each one did. An `--update` that nobody looked
at is worse than no gallery, because it launders a regression into the
reference.

The references are rendered on a maintainer's Mac. A CI runner whose system
font differs by a version shows a delta that is not a regression — read the
uploaded renders rather than the percentages.

How large a delta: on the first CI run every capture's *size* matched, the
`colors` scene (rectangles, no glyphs) was byte-identical, and the nine
scenes containing text differed by 1.1–2.6% of pixels. So the cross-machine
difference is entirely glyph rasterization, and nothing else in the
renderer. [D1](roadmap/dependencies.md) should take those nine to zero.

[D0](roadmap/completed/sprint-d0-gpu-path.md) re-recorded the references
against our own Metal renderer, and the same shape held on one machine: both
`colors` captures stayed at **0 differing pixels** — which is why `colors` is
now captured at 2× as well, so both scales have that oracle — while the nine
scenes containing text moved by 1.8–5.9% of pixels at a worst channel delta
of 4. Every one of those differing pixels is an antialiased glyph edge; no
solid-fill interior moved. The references now carry GPU rounding rather than
SDL's software renderer's integer truncation, which is what a user with a
window open was seeing all along.
