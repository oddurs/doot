# Performance roadmap

Six sprints to make terminator measurably faster, ordered so each one lands on
ground the previous sprint prepared. Sized for one person at 8–12 focused hours
a week: roughly twelve weeks.

The findings below were read out of the source, not guessed. **None of them are
measured yet** — that is what Sprint 0 is for, and every expected win here is a
hypothesis with a mechanism behind it rather than a number.

## What is actually slow

| Weight | What | Where | Why it costs |
|---|---|---|---|
| Critical | Vsync-blocked present runs inside the mutex | `main.zig:212`, `render.zig:75,242` | The reader thread waits on the lock for up to a full refresh interval every frame, so bulk output drains at roughly 60 batches/sec no matter how large the read buffer is. |
| Critical | One colour-mod state change per glyph | `render.zig:271-272` | `SDL_SetTextureColorMod` between every `SDL_RenderTexture` splits SDL's batch. A 200×60 window can issue ~24,000 state-changing calls per frame. |
| High | Every dirty frame repaints the whole grid | `render.zig:203` | Typing one character rebuilds all 24 rows. No damage tracking exists at any granularity. |
| High | Parser dispatches one byte at a time | `vt.zig:56` | `for (bytes) \|b\| self.advance(...)` — a 64 KiB read becomes 65,536 double-switch dispatches with no fast path for printable runs. |
| High | Per-character wrap and width work | `terminal.zig:178` | `charWidth`, the pending-wrap check and the column bound are recomputed for every character printed. |
| Medium | `Cell` is 16 bytes | `grid.zig:43` | 187 KiB for a 200×60 screen; ~30 MB for 10,000 scrollback lines at 200 columns. |
| Minor | `cellColors` recomputed during run detection | `render.zig:209-221` | Roughly twice per cell, then again in the glyph pass. A rounding error next to the two criticals. |

## The sprints

### Sprint 0 — Baseline and bench harness (weeks 1–2)

Add `zig build bench`: a headless harness that feeds recorded byte streams
through `Parser` and `Terminal` and reports throughput. Corpora are committed
files, not generated at run time.

*Why here:* every sprint below claims a win, and without a baseline none of them
can be defended — nor can Sprint 5 be justified as worth starting.

*Done when:* `zig build bench` prints a table, the numbers are committed as
`bench/baseline.txt`, and CI posts them on every PR.

*Risk:* low. The one trap is a harness that measures itself.

### Sprint 1 — Get the vsync wait out of the lock (weeks 3–4)

Build the frame into a display list under the lock, release the mutex, then
submit and present. Coalesce reader wake-ups so several read batches arriving
between vblanks produce one frame rather than several.

*Why here:* smallest diff on the plan with the largest structural effect, and it
must precede the render sprints — while present blocks inside the lock, parse
time and render time are entangled and no later win can be attributed to its
cause.

*Done when:* bulk-output throughput is no longer pinned to the refresh rate.

*Risk:* medium. The display list must not alias terminal state after unlock.

### Sprint 2 — One draw call for the glyphs (weeks 5–6)

Replace per-glyph `SDL_SetTextureColorMod` + `SDL_RenderTexture` with a vertex
buffer submitted through `SDL_RenderGeometryRaw`: per-vertex colour, one atlas
texture, one draw call for every glyph on screen. Fold background runs into the
same buffer.

*Why here:* largest single render win, and it defines the submission path Sprint
3 has to feed.

*Done when:* draw calls per frame are O(1) rather than O(cells).

*Risk:* medium. Wide glyphs, underline/strike rects and the cursor must all move
into the same vertex path or they reintroduce the state changes.

### Sprint 3 — Row-level damage tracking (weeks 7–8)

Per-row dirty flags set by every mutation path — print, erase, scroll, SGR-only
rewrites, alt-screen switch, cursor movement. `draw()` rebuilds vertices only
for dirty rows.

*Why here:* composes with Sprint 2's buffer instead of being thrown away by it.

*Done when:* typing one character in an 80×24 window rebuilds one row, not 24.

*Risk:* **high — this is where correctness bugs hide.** Scroll regions and the
alt screen are the traps. Every mutation path in terminal.zig needs an audit and
a test that fails when its flag is missing.

### Sprint 4 — Printable-run fast path in the parser (weeks 9–10)

In the `.ground` state, scan forward for a run of `0x20–0x7E` and hand the whole
slice to a new `printRun` handler, which does one wrap check per row segment
instead of re-deriving `charWidth` per character.

*Why here:* self-contained — it touches only vt.zig and terminal.zig. That makes
it the sprint to pull forward if Sprint 3 stalls.

*Done when:* the plain-ASCII corpus improves by a multiple, not a percentage,
and a test proves a run split across two `feed()` calls behaves identically.

*Risk:* low to medium. The run must break correctly at the wrap point, the
scroll-region edge and the last column.

### Sprint 5 — Shrink the cell to 8 bytes (weeks 11–13, gated)

Replace the two inline colour unions with a `u16` index into an interned style
table, leaving `cp:u21 + wide:u2 + style:u16` in 8 bytes.

*Why last:* widest blast radius on the plan and the least certain payoff.

*Gate:* **only start this if Sprint 0's numbers still show scans are
bandwidth-bound once Sprints 1–3 have landed.** If damage tracking means the
full grid is rarely scanned, most of the win evaporates and this should be
dropped rather than done.

*Risk:* high. The style table needs an eviction story or it grows without bound
on RGB-heavy output.

## Why this order

- **0 → everything.** Measurement first, or every sprint after it is a guess
  dressed as a result. It is also the only sprint that can *retire* work.
- **1 → 2, 3.** The lock entangles parse and render timing. Until the vsync wait
  is outside it, the bench cannot attribute a win to either side.
- **2 → 3.** Damage tracking must produce whatever the submission path consumes.
  Build the vertex path first and damage tracking extends it; build it second
  and the damage logic gets rewritten.
- **4 is loose.** It depends on nothing but Sprint 0, and is the natural thing to
  swap forward if Sprint 3's correctness work runs long — which at this cadence
  is the likeliest way the plan slips.

## Not on this plan

- **Cell-level damage tracking.** Row granularity suits a flat row-major grid,
  and scrolling invalidates whole rows anyway.
- **A dedicated sprint for `cellColors`.** Fold it into Sprint 2, which rewrites
  that loop regardless.
- **Parallelising the parser.** One reader thread is not the constraint — the
  mutex is. More threads would add contention to a problem made of contention.
- **Feature work.** Selection, reflow and ligatures are absent by design.
  Ligatures in particular will interact with Sprint 2's vertex path, so that
  sprint is worth landing before shaping is designed.
