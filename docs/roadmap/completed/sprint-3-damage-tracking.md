# Sprint 3 — Row-level damage tracking

**Retired. Never started.** Closed as not planned:
[#10](https://github.com/oddurs/doot/issues/10).

The second sprint this plan removed from itself, and for the same reason as
[Sprint 5](sprint-5-cell-size.md): the gate was measured, and it failed.

## What was proposed

Per-row dirty flags set by every mutation path — print, erase, scroll,
SGR-only rewrites, alt-screen switch, cursor movement — so that `draw()`
rebuilds vertices only for rows that changed. The original justification
was avoiding full repaints; [Sprint 0](sprint-0-benchmarks.md) measured the
full-grid scan at ~0.70 ns/cell and rescoped it to "saves draw-call
submission, not grid reads", and it was moved behind Sprint 2, which
defines what gets submitted.

It was also the riskiest work on the plan: every mutation path across
`terminal.zig` would have needed an audit, and scroll regions and the alt
screen were named as the traps.

## The gate

Written in after [Sprint 2](sprint-2-one-draw-call.md) landed:

> Start this only if `--frame-stats` shows a build time a user could
> notice, or if idle-frame CPU becomes a battery complaint.

## The gate failed

Sprint 2 left submission at one call and the full-screen build at ~45–70 µs
under a streaming dump. The remaining thing damage tracking could save is
the atlas lookup and vertex generation for unchanged rows, which is only
visible when little changes per frame — so the measurement is a typing
scenario: a full screen of text, then one character every 40 ms.

| | 100×30 | 200×60 |
|---|---|---|
| frame build per keystroke (avg) | ~200–235 µs | ~360–420 µs |
| frame build per keystroke (worst) | ~400 µs | ~650 µs |
| share of an 8.3 ms frame at 120 Hz | 2.5–3% | 4–5% |

Higher than the streaming number — the core is cold and down-clocked
between sparse frames, and every cell is a glyph rather than a blank — but
still under half a millisecond of latency per keystroke, and about 30 ns per
cell, which is the hash lookup into the atlas. A person cannot notice
0.4 ms. At ten keystrokes a second it is 0.4% of one core.

Idle frames cost nothing already. The main thread blocks in `SDL_WaitEvent`
and draws only when the reader or the OS wakes it, so there is no per-frame
idle cost for damage tracking to remove.

Against that, the change touches every mutation path in a 1,000-line file,
and the Sprint R and Sprint 4 records both show that the first pass of
tests for this kind of change leaves a mutant alive. That is not a trade
worth making for 0.4 ms.

## What survives

The design is still the right one *if* the gate ever passes: Sprint 2's
vertex buffer is built row by row, so per-row slabs with a dirty flag drop
in without changing the submission. Nothing was built, so nothing has to
be maintained until then.

## Reopen if

- A typing-scenario `--frame-stats` build exceeds ~2 ms — most plausibly on
  a very large window (400×100 would extrapolate to ~1.5 ms cold), or on a
  much slower machine than an M-series laptop.
- A feature makes the app redraw continuously — cursor blink at 2 Hz does
  not qualify; smooth scrolling or any per-frame animation would.
- Glyph lookup gets more expensive — shaping, for instance — and pushes the
  per-cell cost up by an order of magnitude.

## Why this record exists

Two of the six sprints on this plan were retired by their gates without a
line of product code written. Both retirements cost an afternoon of
measurement; both would have cost weeks to build. The plan's original
ordering put this sprint third; measurement moved it to last, then removed
it. That is the harness doing its job.
