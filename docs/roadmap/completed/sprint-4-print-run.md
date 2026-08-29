# Sprint 4 — Printable-run fast path in the parser

**Done.** Closed [#9](https://github.com/oddurs/terminator/issues/9).

Numbered 4, landed third. It was promoted past Sprint 3 after
[Sprint 0](sprint-0-benchmarks.md) showed it was the only parse-side win
left with evidence behind it.

## What was proposed

`vt.Parser.feed` was `for (bytes) |b| self.advance(handler, b)` — a
per-byte double switch — and `Terminal.print` recomputed `charWidth`, the
pending-wrap check and the column bound for every character. The proposal:
in the ground state, scan forward for a run of `0x20–0x7E` and hand the whole
slice to a new `printRun`, which does one wrap check per row segment and
fills cells in a tight loop.

The evidence was the inversion Sprint R exposed: once scrolling stopped
dominating, `cjk` (three bytes per `print`) outran `ascii` (one byte per
`print`) despite having more newlines. Only per-character print cost
explains that.

## The change

Two functions and one early return.

`Parser.feed` looks for a printable run whenever it is in the ground state
with no UTF-8 sequence in flight, and calls `handler.printRun(slice)`. The
run stops at anything outside `0x20–0x7E`, so ESC, controls, DEL and UTF-8
lead bytes still go through `advance` exactly as before. `advance` itself is
untouched — which matters below.

`Terminal.printRun` loops over row segments: honour a pending wrap, take
`min(cols - x, remaining)` bytes, stamp them into the row with one cell
template, advance the cursor, set the pending wrap if the segment reached
the margin. With DECAWM off it falls back to `print` per byte; overprinting
the last column is rare and `print` already gets it right.

`charWidth` returns 1 for anything below U+0300 before consulting the range
tables. Nothing below that is combining or wide, and it covers all of Latin.

## Result

`zig build bench`, same machine, same session:

| corpus | before | after | |
|---|---|---|---|
| ascii | 111.0 | **480.7** MiB/s | **4.33×** |
| altscreen | 118.7 | 385.5 | 3.25× |
| scroll | 96.3 | 272.9 | 2.83× |
| sgr | 169.9 | 367.2 | 2.16× |
| region | 69.0 | 137.8 | 2.00× |
| cjk | 184.7 | 177.0 | 0.96× |

The done-when asked for a multiple on `ascii`, not a percentage. `cjk` is
the control: it is almost entirely three-byte codepoints, which never enter
the fast path, and it did not move. Every corpus with ASCII in it did.

End to end, through the real PTY with `--frame-stats --shell bench/dump.sh`:

| | before | after |
|---|---|---|
| PTY drained at | 46–49 MiB/s | **66–67 MiB/s** |

[Sprint 1](sprint-1-vsync-lock.md) predicted this: with the vblank wait out
of the lock, the reader thread's serial read-then-parse cadence was the
ceiling, so a parse win would show up in the app number and not only the
bench. It did. The remaining gap to `script(1)`'s ~89 MiB/s is the read
half of that cadence.

## Correctness

The split point is arbitrary — the parser hands over whatever run a read
boundary happened to produce — so the fast path has to be indistinguishable
from `print` once per byte. Two things make that checkable:

- `Parser.advance` was left alone and never produces a run, so a terminal
  driven one byte at a time through `advance` **is** the old path. A
  differential test feeds seven inputs (wraps, exact-width lines, CR after a
  pending wrap, SGR mid-run, a scroll region, DECAWM off, cursor movement
  between runs) both ways and compares every cell, the cursor, the pending
  wrap and the scrollback.
- A 43-byte line is fed whole and then split at **every** cut point into a
  7-column terminal, so a boundary lands on the wrap and on the pending-wrap
  column, and each split is compared to the whole.

Plus a parser-level test that a run cut across three `feed` calls with an
escape in the middle records the same as one, and one that a run stops at a
UTF-8 lead byte and resumes after the codepoint.

The tests were then **mutation-tested**, as the Sprint R record recommends.
Six deliberate breakages: wrap eagerly instead of deferring; pending wrap
without the line feed; attributes dropped from the cell template; the
DECAWM-off fallback removed; an off-by-one past the margin; `markDirty`
dropped. **Five were caught. One survived** — dropping `markDirty`, which
would have left a scrolled-back viewport where it was when new output
arrived. A test for that was added and the mutant re-run; it is now caught.
Same pattern as Sprint R: the first pass of tests is never quite enough.

## What it did not do

`print` for non-ASCII is unchanged, and so is `cjk`. A run path for
multi-byte UTF-8 would need width per codepoint and is not obviously worth
it — `cjk` was already the fastest corpus before this sprint and is now the
second slowest, which says more about how far the others moved than about
it.
