# Sprint 2 — One draw call for the glyphs

**Done.** Closed [#8](https://github.com/oddurs/terminator/issues/8).

## What was proposed

`drawGlyph` issued `SDL_SetTextureColorMod` then `SDL_RenderTexture` for
every visible cell, with `SDL_RenderFillRect` for each background run,
underline and strikethrough. The roadmap read that as a render-state change
between every glyph — ~24,000 state-changing calls per frame at 200×60 —
and proposed a vertex buffer through `SDL_RenderGeometryRaw`: per-vertex
colour, one atlas texture, one draw call for everything.

## What was measured first

`--frame-stats` gained a `calls` column — SDL submission calls per frame —
and `--size` so the 200×60 case could be run. Same corpus dump as Sprint 1:

| | 100×30 | 200×60 |
|---|---|---|
| calls per frame (avg / max) | 850 / 1,300 | 1,150 / 2,350 |
| frame build (avg) | 135–340 µs | 100–170 µs |
| frame build (worst) | **8.2–9.5 ms** | 0.2–8.6 ms |

Two things did not match the proposal.

First, the premise was partly wrong. SDL3's batcher folds colour-mod into
the vertex data it generates for `SDL_RenderTexture`, so a colour change
between glyphs does *not* split the batch. What did split it was the
alternation between untextured rects and textured glyphs on every row —
tens of flushes per frame, not thousands — and the rest of the cost was
per-call overhead in SDL itself, at roughly 150–300 ns a call.

Second, the worst-case build was a whole frame. Every few hundred frames the
build took 8–9 ms — half the 120 Hz budget, spent inside the lock-free part
of the loop but stalling the display all the same.

## The change

Every quad the frame draws — background runs, glyph bitmaps, underlines,
strikethroughs, the cursor block and the glyph redrawn over it — is appended
to one vertex buffer with its colour on the vertices, and the frame is
submitted with a single `SDL_RenderGeometryRaw` against the atlas texture.

Solid fills get into the same call by sampling a **white texel reserved at
atlas (0, 0)**. The shelf packer has always started at (1, 1), so nothing is
ever packed over it; `Atlas.init` paints it and a test proves it survives a
full ASCII fill. That is what keeps rectangles and glyphs from breaking each
other's batch, which was the roadmap's stated risk.

Draw order is index order: backgrounds for every row first, then glyphs,
then the cursor. Later triangles blend over earlier ones exactly as separate
calls would have.

Atlas uploads for newly seen glyphs still happen during the build, but now
before the one submission rather than between hundreds of queued texture
draws.

## Result

| | 100×30 before | after | 200×60 before | after |
|---|---|---|---|---|
| calls per frame | 850–1,300 | **2** | 1,150–2,350 | **2** |
| frame build (avg) | 135–340 µs | **43–46 µs** | 100–170 µs | **70 µs** |
| frame build (worst) | 8.2–9.5 ms | **0.18–0.23 ms** | up to 8.6 ms | **0.12–0.26 ms** |

The two calls are `SDL_RenderClear` and the geometry submission. Draw calls
are O(1) in the number of cells, which was the done-when.

The average build dropped 3–7×. The **worst case dropped ~40×**, and that is
the more useful number: those 8 ms spikes were `SDL_UpdateTexture` landing
on the atlas while hundreds of queued `RenderTexture` commands still
referenced it, forcing SDL to flush and wait. With one submission after all
uploads there is nothing queued to wait for. The Sprint 1 record flagged
those spikes as "glyph rasterization"; they were mostly the flush.

Frame build at 200×60 is now ~70 µs against an 8.3 ms budget at 120 Hz —
under 1%. That is the headroom Sprint 3 has to justify itself against.

## Verified visually

`--screenshot PATH` was added alongside: it reads the frame back through
`SDL_RenderReadPixels` before present and writes a BMP, so the renderer's
output can be checked from a script with no OS screen-capture permission.
Bold, italic, underline, strikethrough, dim, reverse, indexed and truecolor
backgrounds, box drawing, descenders and the cursor were all checked
against the new path.

CJK and emoji cells come out blank — SF Mono has no glyphs for them and
there is no fallback face. That predates this sprint, is unchanged by it,
and is a feature gap rather than a render bug.

## Follow-up: two defects in the instrumentation, not the optimization

Code review of the merged sprints found both of this sprint's additions
broken in ways the sprint's own testing would not have found, because the
measuring apparatus was held to a lower standard than the code it measures.

The `calls` column added to `--frame-stats` divided by the frame count with
no zero guard, while `avgUs` beside it had one. A reporting window can
elapse with no frame drawn at all — a mouse move over an idle window wakes
the event loop without dirtying the screen — and the second such window
panics. It aborts in Debug and ReleaseSafe; on aarch64 ReleaseFast it
silently yields zero, and on x86_64 it raises `SIGFPE`.

`--size` passed its argument to `Renderer.init` unchecked, where
`init_cols * cell_w + pad * 2` overflowed: `--size 4000000000x30` panicked
before drawing anything.

Both are fixed, and option parsing moved to a pure `cli.zig` so the bounds
have tests — `main.zig` cannot be unit-tested because it pulls in SDL, which
is exactly how an unchecked flag reached the renderer. The lesson worth
keeping: instrumentation that every claim in these records rests on deserves
the same tests as the code it measures.

## What this changes about Sprint 3

Sprint 3's value was already rescoped to "draw-call submission, not grid
reads". Submission is now one call and the whole build is ~45–70 µs. What
damage tracking can still save is the per-glyph atlas lookup and vertex
generation for unchanged rows — real, but measured in tens of microseconds
per frame. The sprint should carry a gate: land it only if the frame timer
shows build time that a user could notice, and it does not today.
