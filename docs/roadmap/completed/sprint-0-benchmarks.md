# Sprint 0 — Baseline and bench harness

**Done.** Shipped in [#3](https://github.com/oddurs/doot/pull/3).

## What was proposed

`zig build bench`: a headless harness feeding recorded byte streams through
`vt.Parser` into `Terminal`, so that every later sprint could be judged
against a number instead of an argument.

The stated risk was "a harness that measures itself". The stated value was
that it would let the plan *retire* work, not only order it.

## What was built

Six committed corpora under `bench/corpus/`, each 256 KiB:

| corpus | what it is |
|---|---|
| `ascii` | plain source dump, no escapes |
| `sgr` | colourised build log, dense SGR |
| `scroll` | short lines, scrolls every line |
| `altscreen` | full-screen app redraw, absolute cursor addressing |
| `cjk` | wide and multibyte text |
| `region` | DECSTBM region + status line — added later, see Sprint R |

Three measurements: parse throughput per corpus, a scroll-sensitivity
experiment (same corpus against a taller and taller screen), and a full-grid
scan standing in for the repaint walk.

Design decisions worth keeping:

- **Corpora are committed files, not generated at run time.** A number from
  today stays comparable with one from a year from now.
- **Each corpus is seeded independently**, so adding a seventh will not shift
  the bytes of the first six. This was tested when `region` was added — the
  other five stayed byte-identical.
- **Always ReleaseFast**, regardless of `-Doptimize`. A benchmark that
  silently reports a Debug number is worse than no benchmark.
- **Headless.** `vt`, `grid` and `terminal` import nothing but `std`, so this
  needs neither SDL nor a window and runs on a cheap Linux CI runner.
- **Best-of and median both reported.** A median far from best means the run
  was noisy and should not be trusted.

## What it found immediately

Parse throughput tracked **newline density, not escape density** — Pearson
r = 0.99 against bytes-per-line:

| corpus | MiB/s | bytes/line |
|---|---|---|
| altscreen | 127.8 | ∞ (no newlines) |
| sgr | 105.6 | 138 |
| ascii | 50.2 | 47 |
| cjk | 47.3 | 32 |
| scroll | 25.1 | 17 |

The scroll-sensitivity experiment settled the mechanism. Same bytes, taller
screen:

| geometry | MiB/s | vs 80×24 |
|---|---|---|
| 80×24 | 50.3 | 1.00× |
| 80×48 | 33.2 | 0.66× |
| 80×100 | 18.6 | 0.37× |
| 80×200 | 10.1 | **0.20×** |

8.3× taller, 5× slower. That is `Screen.scrollUp` memmoving `(rows-1) × cols`
cells per line feed — and it was not among the seven findings the roadmap was
built on. See [Sprint R](sprint-r-screen-ring.md).

It also found that the **full-grid scan is free**: a flat ~0.70 ns/cell from
30 KiB to 625 KiB, so a 200×60 repaint reads the whole grid in 8.5 µs, or
0.05% of a 60 Hz frame. That rescoped Sprint 3 and killed
[Sprint 5](sprint-5-cell-size.md).

## What it cannot see

**The render path.** The harness is headless by design, so the mutex is never
contended and no draw call is ever issued. The two findings still labelled
Critical — the vsync-blocked present inside the mutex, and the per-glyph
colour-mod state change — are **unmeasured code reading**, which is exactly
the evidentiary status of the assumption this sprint falsified.

Measuring them needs a frame timer in the real app. That is part of Sprint 1.

## The lesson

The plan that commissioned this harness was wrong about its own top item. One
afternoon of benchmarking found a 3.8× win nobody had proposed and retired a
three-week sprint nobody needed. Do not propose performance work here from
code reading alone.
