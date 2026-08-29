# Performance roadmap

Sprints against bottlenecks located in the source and then confirmed — or
refuted — by measurement. Sized for one person at 8–12 focused hours a week.

`zig build bench` is the arbiter — see [benchmarking](../benchmarking.md).
`bench/baseline.txt` is the number to beat.

Finished and retired sprints keep their own records under
[completed/](completed/): what was proposed, what was measured, and what it
changed about this plan.

## Status

| | Sprint | State |
|---|---|---|
| 0 | Baseline and bench harness | **Done** |
| R | Screen row ring | **Done** — 1.7–3.8×, and it was not on the original plan |
| 1 | Get the vsync wait out of the lock | **Done** — ~150× on bulk output, measured end to end |
| 2 | One draw call for the glyphs | **Done** — 2 calls per frame, worst-case build ~40× better |
| 4 | Printable-run fast path | **Done** — 4.3× on `ascii`, 2–3× on everything else with ASCII in it |
| 3 | Row-level damage tracking | Last one open. Rescoped and **gated** — build is ~70 µs at 200×60 |
| 5 | Shrink the cell to 8 bytes | **Gate failed** — dropped as a speed sprint |

## What measurement changed

The original plan was written by reading the source. Three of its
assumptions did not survive contact with the benchmark, which is the entire
reason Sprint 0 came first.

**The biggest win was not on the plan.** Parse throughput tracked newline
density almost exactly (r = 0.99), not escape density. `Screen.scrollUp`
memmoved `(rows-1) × cols` cells per line feed — ~28 KiB per 47 bytes of
input at 80×24 — and the same corpus against a screen 8.3× taller ran 5×
slower. The scrollback had always been a ring; the screen was not. Making it
one bought 1.7–3.8× across every corpus that contains a newline, and flattened
the height curve from 0.20× to 1.00×. Nothing in the original seven findings
pointed at it.

**The full-grid scan is free.** A flat ~0.70 ns/cell from 30 KiB to 625 KiB —
not memory-bandwidth-bound at any realistic size. A 200×60 repaint reads the
whole grid in 8.5 µs, which is 0.05% of a 60 Hz frame. So damage tracking
saves *draw-call submission*, not grid reads, and its value is entirely
downstream of Sprint 2.

**Sprint 5's gate failed.** It was gated on scans being bandwidth-bound. They
are not. Shrinking `Cell` from 16 to 8 bytes would still halve the scrollback
footprint (~30 MB → ~15 MB at 10,000 lines), but that is a memory argument,
not a speed one, and it does not justify the widest-blast-radius refactor on
the plan. It is no longer a sprint.

**Sprint 4 was revalidated, and promoted.** Once scrolling stopped dominating,
the newline correlation collapsed from r = 0.99 to r = 0.62 — and `cjk`
(32 bytes per line) now outruns `ascii` (47 bytes per line), an inversion that
is impossible if scrolling still governs. What separates them is bytes per
`print()` call: CJK is three bytes per codepoint, ASCII is one. Per-character
print cost is now the parse bottleneck, which is exactly what Sprint 4
targets — it went from an assumption to a measured conclusion.

## Where the time goes now

From `bench/baseline.txt`, after Sprint 4:

| corpus | MiB/s | what it is |
|---|---|---|
| ascii | 490.2 | plain source dump |
| altscreen | 394.2 | full-screen app redraw |
| sgr | 372.2 | colourised build log |
| scroll | 282.2 | short lines, scrolls every line |
| cjk | 181.9 | wide and multibyte text |
| region | 141.5 | DECSTBM region + status line |

The ranking has inverted again. `cjk` was the fastest corpus before Sprint
4 and did not move, because three-byte codepoints never enter the printable
run; everything else did. `region` is still last — a partial scroll region
misses the whole-screen rotation, so vim, less and tmux get per-row copies
rather than a pointer bump. That is [#12](https://github.com/oddurs/terminator/issues/12),
and it is not obvious a region can be rotated without moving the rows
around it.

Above the parser, `--frame-stats` puts the frame at 2 µs of lock hold and
~45–70 µs of build against an 8.3 ms budget at 120 Hz, and the PTY drains
at 66–67 MiB/s end to end against a ~89 MiB/s ceiling for the kernel's tty
layer alone.

## The sprints

### Sprint 0 — Baseline and bench harness — **done**

Add `zig build bench`: a headless harness that feeds recorded byte streams
through `Parser` and `Terminal` and reports throughput. Corpora are committed
files, not generated at run time.

*Why here:* every sprint below claims a win, and without a baseline none of them
can be defended — nor can Sprint 5 be justified as worth starting.

Six committed corpora, headless (the parse stack imports nothing but `std`),
always ReleaseFast. CI posts the numbers on every PR, non-gating — a shared
runner is far too noisy to decide a regression.

It paid for itself immediately: see "What measurement changed" above.

### Sprint 1 — Get the vsync wait out of the lock — **done**

Build the frame into a display list under the lock, release the mutex, then
submit and present. Coalesce reader wake-ups so several read batches arriving
between vblanks produce one frame rather than several.

*Why here:* smallest diff on the plan with the largest structural effect, and it
must precede the render sprints — while present blocks inside the lock, parse
time and render time are entangled and no later win can be attributed to its
cause.

*Done when:* bulk-output throughput is no longer pinned to the refresh rate.

*Risk:* medium. The display list must not alias terminal state after unlock.

*Result:* the mutex was held ~8 ms per frame on a 120 Hz display and the
PTY drained at 0.26–0.40 MiB/s. It is now held 2 µs per frame and drains at
41–51 MiB/s — about 150×. The `--frame-stats` timer and `bench/dump.sh`
were added to measure it. See
[the record](completed/sprint-1-vsync-lock.md).

### Sprint 2 — One draw call for the glyphs — **done**

Replace per-glyph `SDL_SetTextureColorMod` + `SDL_RenderTexture` with a vertex
buffer submitted through `SDL_RenderGeometryRaw`: per-vertex colour, one atlas
texture, one draw call for every glyph on screen. Fold background runs into the
same buffer.

*Why here:* largest single render win, and it defines the submission path Sprint
3 has to feed.

*Done when:* draw calls per frame are O(1) rather than O(cells).

*Risk:* medium. Wide glyphs, underline/strike rects and the cursor must all move
into the same vertex path or they reintroduce the state changes.

*Result:* 850–2,350 calls per frame became 2. Average build dropped 3–7×;
the worst case dropped ~40×, from 8–9 ms spikes to ~0.2 ms, because those
spikes were atlas uploads forcing a flush of queued texture draws. The
premise was partly wrong — SDL3 folds colour-mod into its batch already —
and the record says so. See
[the record](completed/sprint-2-one-draw-call.md).

### Sprint 3 — Row-level damage tracking (weeks 7–8)

Per-row dirty flags set by every mutation path — print, erase, scroll, SGR-only
rewrites, alt-screen switch, cursor movement. `draw()` rebuilds vertices only
for dirty rows.

*Why here:* composes with Sprint 2's buffer instead of being thrown away by it.

*Gate:* Sprint 2 left the whole frame build at ~45 µs (100×30) to ~70 µs
(200×60) against an 8.3 ms budget at 120 Hz. What damage tracking can still
save is the atlas lookup and vertex generation for unchanged rows — tens of
microseconds. Start this only if `--frame-stats` shows a build time a user
could notice, or if idle-frame CPU becomes a battery complaint.

*Done when:* typing one character in an 80×24 window rebuilds one row, not 24.

*Risk:* **high — this is where correctness bugs hide.** Scroll regions and the
alt screen are the traps. Every mutation path in terminal.zig needs an audit and
a test that fails when its flag is missing.

### Sprint 4 — Printable-run fast path in the parser — **done**

In the `.ground` state, scan forward for a run of `0x20–0x7E` and hand the whole
slice to a new `printRun` handler, which does one wrap check per row segment
instead of re-deriving `charWidth` per character.

*Why here:* self-contained — it touches only vt.zig and terminal.zig. That makes
it the sprint to pull forward if Sprint 3 stalls.

*Done when:* the plain-ASCII corpus improves by a multiple, not a percentage,
and a test proves a run split across two `feed()` calls behaves identically.

*Risk:* low to medium. The run must break correctly at the wrap point, the
scroll-region edge and the last column.

*Result:* `ascii` 111 → 481 MiB/s (4.3×); `altscreen` 3.3×, `scroll` 2.8×,
`sgr` 2.2×, `region` 2.0×; `cjk` unchanged, as the control should be. End
to end the PTY drains at 66–67 MiB/s, up from 46–49. The tests were
mutation-tested; one of six mutants survived the first pass and got its
own test. See [the record](completed/sprint-4-print-run.md).

### Sprint 5 — Shrink the cell to 8 bytes — **gate failed, dropped**

Replace the two inline colour unions with a `u16` index into an interned style
table, leaving `cp:u21 + wide:u2 + style:u16` in 8 bytes.

*Why last:* widest blast radius on the plan and the least certain payoff.

*Gate result:* **failed.** The gate was "only start this if scans are
bandwidth-bound". They are not — a flat ~0.70 ns/cell from 30 KiB to 625 KiB.
The remaining case is footprint (~30 MB → ~15 MB of scrollback at 10,000 lines
× 200 columns), which does not justify the widest-blast-radius refactor on the
plan. Revisit only if scrollback memory becomes a real complaint.

This is what a gate is for. It cost one afternoon of benchmarking to retire a
three-week sprint.

## Why this order

Revised after Sprint 0. The order is now **1 → 2 → 4 → 3**, with 5 dropped.

- **0 → everything.** Measurement first, or every sprint after it is a guess
  dressed as a result. It is also the only sprint that can *retire* work, and
  it retired one immediately.
- **1 → 2, 3.** Unchanged, and the bench could not settle it: the vsync wait
  sat inside the mutex, and no headless harness can see that. It needed a
  frame timer in the real app, which shipped with the sprint as
  `--frame-stats`. Done.
- **2 → 3.** Strengthened. The grid scan turned out to be free, so damage
  tracking saves nothing *except* draw-call submission — which means it has no
  measurable value at all until Sprint 2 defines what gets submitted. Doing 3
  first would now be close to pointless, not merely wasteful. Sprint 2 is
  done, and it left Sprint 3 with a gate: the whole build is ~70 µs.
- **4 moved ahead of 3.** It is self-contained, it is the only remaining
  parse-side win, and it is now backed by evidence rather than assumption.
  Sprint 3 is the riskiest work on the plan and the least certain payoff;
  Sprint 4 is neither. Done, and it paid: 4.3× on the corpus it targeted.
- **5 is gone.** Its gate failed. See above.

## Adding a sprint

Anything proposed here needs a corpus and a number, not an argument. Add a
generator to `bench/gen_corpus.py`, regenerate (the per-corpus seeding keeps
existing corpora byte-identical), and show the before-and-after. The screen
ring exists because a benchmark contradicted a plausible-sounding plan; the
next one may too.

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
