# Sprint X0 — The gallery

**Done.** First sprint on the [experience roadmap](../experience.md), and
row 1 of the [priorities](../priorities.md) order.

## What was proposed

Turn `--screenshot` into an acceptance test: scripts under `bench/gallery/`
each rendering one canonical screen, captured at 1× and 2×, committed as
PNGs, with `zig build gallery` re-rendering and reporting per-image pixel
deltas and CI posting them non-gating.

Risk was called **low** — "the flag exists; this is scripting around it".
That was wrong in an interesting way, and the two things it missed are the
sprint.

## What it actually needed

**Rendering with no display.** `--screenshot` existed but nothing had ever
run the app without a window. `SDL_VIDEODRIVER=dummy` gives SDL a backend
with no display and `SDL_RenderReadPixels` still returns a correct frame, so
a capture works on a CI runner. The `offscreen` driver, which sounds like
the right one, fails to create a window at all.

**A pixel density that does not depend on the machine.** A 2× capture was
impossible on a 1× runner, because the renderer asked the display how dense
it was. `--scale N` tells it to pretend instead, and `Renderer.init` now
sizes the window so its *pixel* size fits the grid at that scale — without
that, forcing 2× rendered double-size glyphs into a single-size window and
showed half the columns.

**A PNG codec.** The flag wrote BMP via SDL, and 152 KB of committed
captures would have been about a megabyte. `src/png.zig` is roughly a
hundred lines over `std.compress.flate` — 8-bit RGBA, no interlacing, filter
0, encode and decode. The project links libc and the system's own frameworks
and nothing else ([dependencies.md](../dependencies.md)); a picture format is
not a good reason to break that. Its own tests found the first bug: the
decoder accepted a file with no `IEND` chunk, so a truncated capture came
back as a shorter picture rather than an error.

## Two bugs found by building it

**The app could lose the tail of a program's output.** The event loop ends
when `pty.exited()` notices the child is gone, which can happen while bytes
it already wrote are still in the PTY buffer. Interactively you would never
see it; a gallery scene that prints and exits in milliseconds hits it every
time. The exit path now stops the reader, joins it, and drains what is left
before the final frame.

**`--screenshot` could not capture a short-lived program at all.** It fired
one second in, and every scene here is gone before that. The last frame is
now captured on the way out if the timer never fired, which also makes the
capture deterministic rather than "whatever was on screen at one second".

## The captures

Ten, 152 KB in total:

| scene | what it covers |
|---|---|
| `typography` | printable ASCII, descenders, box drawing, blocks, braille, CJK, emoji |
| `attributes` | every SGR attribute, alone and combined |
| `colors` | 16 ANSI slots, the 256-colour cube, a truecolour ramp |
| `tui` | a scroll region, a framed panel, a status line |
| `cursor` | a scene whose only interesting feature is the cursor |

`typography` at 10, 14 and 20 pt and at 1× and 2×, because baseline
placement and cell rounding are what change between sizes.

The scenes are scripts printing fixed bytes, **not `vim` and `htop`** as the
sprint text suggested. Their output varies with version, terminal size,
locale and the files lying around, and a pixel diff cannot tell that apart
from a regression — the bench corpora are committed files for exactly this
reason. Real-program screens want recorded byte streams, which
[A0](../agentic.md) produces.

## Done when

> the gallery runs headless on the macOS CI runner and a one-pixel change in
> the cursor shows up as a diff in the PR summary

Both. Headless locally and as a CI job that uploads the renders and writes
the table to the job summary. The cursor condition was demonstrated by
breaking it two ways:

| mutation | 1× | 2× | worst delta |
|---|---|---|---|
| cursor block one pixel narrower | 17 pixels | 34 pixels | 194 |
| cursor colour +1 in one channel | 153 pixels | 578 pixels | 1 |

The `worst` column is what separates the two: a few pixels at a large delta
is a shape moving, many pixels at a delta of 1 is a colour change.

## What the first gallery shows

The typography page has **empty cells** where braille, CJK and emoji should
be, and the box-drawing row is partial. That is not a regression; it is the
"missing glyphs are drawn as nothing" row of the experience roadmap's
where-we-are table, which until now was a sentence. It is [X2](../experience.md)'s
job, and the gallery is how anyone will be able to tell it worked.

## What review found

Five defects, all fixed before merge. Two of them mattered enough to change
what the sprint means.

**The gallery was not headless.** `std.process.spawn` with no environment
map hands the child an *empty* environment, so the `SDL_VIDEODRIVER=dummy`
the build step set never reached the app. Every reference in the first draft
was rendered through the real Cocoa and Metal backend at the maintainer's
display density, while the documentation, the build comment and the CI job
all said otherwise. Running it genuinely headless made all ten fail — five
of them on size alone, which skips the pixel diff entirely, so the arbiter
would have been blind for half its captures. `gallery.zig` now builds the
child's environment itself, which also means `zig build gallery` is headless
however it was invoked.

**A capture depended on the machine that took it.** The window size is set
in logical units, so `want_px / density` rounds: on a 2× display an odd
pixel height became an even one, and the same capture differed by a row
between machines — the exact dependency `--scale` exists to remove.
Screenshots are now cropped to the grid's own pixel size.

Also fixed: `png.decode` multiplied header fields in `u32` before bounding
them, so a 70-byte file claiming 0x40000000 × 1 panicked in a safe build and
returned a bogus image in a fast one; and one unreadable reference aborted
the whole run rather than reporting that capture and continuing.

**And a regression this sprint introduced.** The drain added above waited
for the PTY to go quiet — which a live child never allows. Closing the
window while a command was producing output hung the app until it was
killed. The drain now runs only when the child has actually exited, and
under a deadline.

## Not gating, deliberately

Like the bench. A visual diff is usually an intended change and the reviewer
decides. The references are also rendered on a maintainer's Mac, so a runner
with a different system font version reads as a whole-image delta that is
not a regression — the job says so, and uploads the renders so a person can
look rather than trust a percentage.
