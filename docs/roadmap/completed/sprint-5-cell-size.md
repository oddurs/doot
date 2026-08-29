# Sprint 5 — Shrink the cell to 8 bytes

**Retired. Never started.** Closed as not planned:
[#11](https://github.com/oddurs/doot/issues/11).

This is the most useful record in this directory, because it is the one where
the plan removed work from itself.

## What was proposed

`Cell` is 16 bytes (`grid.zig`) — 187 KiB for a 200×60 screen, and roughly
30 MB for 10,000 scrollback lines at 200 columns. The proposal was to replace
the two inline colour unions with a `u16` index into an interned style table,
leaving `cp:u21 + wide:u2 + style:u16` in 8 bytes.

That halves memory traffic on every full-grid scan and halves the scrollback
footprint. Ghostty and Alacritty both do something along these lines.

Estimated at two to three weeks — the widest blast radius on the plan, since
it touches `grid`, `terminal` and `render` together.

## The gate

It was written into the plan with an explicit condition:

> Only start this if Sprint 0's numbers still show scans are bandwidth-bound
> once Sprints 1–3 have landed.

## The gate failed

[Sprint 0](sprint-0-benchmarks.md) measured the full-grid scan at a flat
**~0.70 ns/cell**:

| geometry | µs/scan | ns/cell | working set |
|---|---|---|---|
| 80×24 | 1.4 | 0.70 | 30 KiB |
| 120×40 | 3.4 | 0.70 | 75 KiB |
| 200×60 | 8.5 | 0.71 | 187 KiB |
| 400×100 | 28.5 | 0.71 | 625 KiB |

A **20× range in working-set size with no measurable change in per-cell cost**.
Nothing there is waiting on memory. Halving the cell would halve the bytes and
buy approximately nothing in time.

For scale: a 200×60 repaint reads the entire grid in 8.5 µs, which is 0.05% of
a 60 Hz frame.

## What survives

A footprint argument only: ~30 MB → ~15 MB of scrollback at 10,000 lines by
200 columns. Real, but it does not justify the widest refactor on the plan,
and the style table would need an eviction story or it grows without bound on
RGB-heavy output.

## Reopen if

- Scrollback memory becomes an actual complaint, or
- A future benchmark shows scans going bandwidth-bound at sizes people really
  use — which would most likely mean much larger terminals than 400×100.

## Why this record exists

The gate cost one afternoon of benchmarking and retired a three-week sprint.
Plans that only accumulate work are easy to write; the gate is what let this
one shrink. Write gates into future sprints.
