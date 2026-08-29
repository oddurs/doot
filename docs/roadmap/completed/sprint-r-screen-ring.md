# Sprint R — Screen row ring

**Done.** Shipped in [#5](https://github.com/oddurs/doot/pull/5).

Lettered rather than numbered because it was never on the plan.
[Sprint 0](sprint-0-benchmarks.md) found it.

## The problem

`Screen.scrollUp` memmoved `(rows-1) × cols` cells on every line feed — about
**28 KiB of traffic per 47 bytes of input** at 80×24, a write amplification
of roughly 600×.

The scrollback had always been a ring, with a head index and no data movement.
The screen was a flat array that got shifted wholesale.

## The change

The screen carries a row offset too. A whole-screen scroll — every line feed
with no scroll region set — rotates that offset and clears only the rows that
scrolled in: **O(n × cols) instead of O(rows × cols)**.

Rows stay individually contiguous, so `row()` still returns a plain slice and
nothing above `grid.zig` knows the ring exists. `Screen.cells` was only ever
touched inside `grid.zig`, which is what made this containable.

## Result

| corpus | before | after | |
|---|---|---|---|
| ascii | 50.2 | 109.2 MiB/s | 2.18× |
| sgr | 105.6 | 171.0 MiB/s | 1.62× |
| scroll | 25.1 | 96.5 MiB/s | **3.84×** |
| cjk | 47.3 | 178.9 MiB/s | **3.78×** |
| region | 53.7 | 72.6 MiB/s | 1.33× |
| altscreen | 127.8 | 129.1 MiB/s | 1.01× |

`altscreen` is the control — it contains no newlines, so it never scrolls and
was never expected to move. It didn't.

The height dependence is gone outright, and this is now a regression test:

| geometry | before | after |
|---|---|---|
| 80×24 | 1.00× | 1.00× |
| 80×48 | 0.66× | 1.00× |
| 80×100 | 0.37× | 0.97× |
| 80×200 | **0.20×** | 0.98× |

Reproduced independently on the x86_64 Linux CI runner: 1.00/0.75/0.49/0.29
became 1.00/0.99/1.00/0.99. If that curve ever slopes again, the fast path in
`Screen.scrollUp` has stopped firing.

## The counter-intuitive part

A partial `DECSTBM` scroll region — `ESC[1;23r`, which vim, less and tmux all
set to keep a status line — misses the whole-screen fast path and takes
`height - n` per-row `@memcpy`s where it used to take one slab copy.

Review flagged that as a probable regression. Measured, it is **1.33× faster**:
the old slab copy went through `std.mem.copyForwards`, which is a scalar
element loop deprecated in favour of `@memmove`, while each `@memcpy` lowers
to a vectorised copy. Twenty-two vectorised memcpys beat one scalar loop over
1,760 cells.

The `region` corpus was added to cover this, and the fast-path gap is tracked
as [#12](https://github.com/oddurs/doot/issues/12).

## Correctness

Six ring-specific tests plus a multi-line case, on top of the existing suite.

The tests were **mutation-tested** rather than trusted for being green: the
implementation was deliberately broken seven ways (fast path skipping the
clear, region path walking memory order, `clearRows` reverting to a contiguous
slab, `at()` ignoring the offset, wrong rotation direction, rotation by a
fixed one line). The first pass **left one alive** — rotating by a fixed one
line passed every single-line test — so a multi-line assertion was added. All
seven are now caught.

Review independently ran a differential fuzz (400 seeds × 200 random ops
against a naive reference model) and a bit-identical state comparison between
old and new `grid.zig` across every corpus, seven geometries and a synthetic
DECSTBM/IL/DL/SU/SD/RI/ED/EL/ICH/DCH stress. No mismatches.

## Traps for anyone touching `grid.zig` now

- Logical rows are **no longer adjacent in memory**. Slicing
  `cells[y * cols ..]` directly is what this file used to do and is now a bug.
  Go through `row()`.
- `physical()` asserts `y < rows`. Before the ring an out-of-range row sliced
  past the end and tripped a bounds check; now it would fold onto a live row
  and silently scribble on it.
- `fill()` resets the offset, so a reset leaves the screen canonical.
