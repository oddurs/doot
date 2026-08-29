# Benchmarking

```sh
zig build bench                    # run them
zig build bench > bench/baseline.txt   # re-record the baseline
```

Needs neither SDL nor a window: `vt`, `grid` and `terminal` import nothing but
`std`. Always builds ReleaseFast regardless of `-Doptimize`, because a
benchmark that silently reports a Debug number is worse than no benchmark.

## What it measures

**`parse`** — bytes from a PTY through `vt.Parser` into `Terminal`. The whole
stack below the renderer, which is where a terminal spends its time when
something dumps output at it.

**`scroll`** — the same corpus against a taller and taller screen. A controlled
experiment rather than a measurement: it is what identified the scroll memmove
as the parse bottleneck, and it now stands as the regression test for the fix.
**These rows should read flat.** If the curve slopes again, the fast path in
`Screen.scrollUp` has stopped firing.

**`scan`** — a full-grid read, the walk `render.draw` performs every frame.

## What it cannot measure

Anything above the renderer. The harness is headless, so the mutex is never
contended and no draw call is ever issued — the vsync-inside-the-lock and
per-glyph-state-change findings are invisible to it. Those need the frame
timer in the real app, below.

## The frame timer

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/doot --frame-stats --shell bench/dump.sh
```

`--frame-stats` prints one line a second to stderr, and a totals line at exit:

```
frame-stats   120 fps  lock  1/5   build  44/78   drawable  7767/9596 us  calls  1/1  pty  68.72 MiB/s
frame-stats  total: 636 frames in 5.32 s, 257368610 bytes from the pty at 46.18 MiB/s, worst lock hold 324 us
```

Each column is average/worst over the second, in microseconds:

**`lock`** — how long the main thread held the terminal mutex. The reader
cannot feed a byte while this is non-zero, so it decides bulk-output
throughput. Should read in single-digit microseconds; it is one memcpy of the
viewport.

**`build`** — from releasing the lock to submitting the frame: vertex
generation and draw calls. What Sprints 2 and 3 move.

**`drawable`** — the wait for the GPU to finish the frame plus the wait for a
drawable to present it to. Roughly one refresh interval, and it should never
appear inside `lock` again. It was called `present` until D0, when the wait
stopped being SDL's and became ours.

**`calls`** — GPU submission calls per frame. One: the frame is a single
indexed draw, and the clear is the render pass's load action rather than a
call of its own. (It read two under SDL, where the clear was a call.) If this
grows with the screen, the vertex path has been bypassed somewhere.

**`pty`** — how fast the reader is draining the PTY.

`bench/dump.sh` cats the six corpora at the terminal and exits, so pointing
`--shell` at it makes the app an end-to-end benchmark: real PTY, real parser,
real frames. `PASSES` sets how many times each corpus is written (default 16,
which is 24 MiB). A window opens for the duration. `--size 200x60` picks the
initial grid, for the large-window case.

`--screenshot PATH` saves the frame drawn one second in as a PNG, read back
out of the offscreen render target — so what the renderer produced can be
checked from a script, with no screen-capture permission involved, and with
no window at all.

For scale, `script -q /dev/null bench/dump.sh > /dev/null` drains the same
bytes through a PTY with no terminal attached — the cost of `cat` and the
kernel's tty layer alone — at roughly 89 MiB/s on an M-series laptop.

## Reading the numbers

Best-of and median are both reported. Best-of is the honest figure for "how
fast can this go" — the run least polluted by whatever else the machine was
doing. **A median far from best means the run was noisy and should not be
trusted.**

Run-to-run variance on a quiet machine is 3–5%. Treat anything under 5% as
noise; a real win is visible without squinting.

`bench/baseline.txt` is the number to beat. CI also runs the benchmarks on
every PR and writes them to the job summary and the log, but that job is
**non-gating** — a shared runner is far too noisy to decide a regression.

## The corpora

Eight files under `bench/corpus/`. The first six are 256 KiB and generated;
the last two are **recordings** of real sessions, made with
`zig build record` — see [A0](roadmap/completed/sprint-a0-agent-corpus.md).

| corpus | what it is |
|---|---|
| `ascii` | plain source dump, no escapes |
| `sgr` | colourised build log, dense SGR |
| `scroll` | short lines, scrolls every line |
| `altscreen` | full-screen app redraw, absolute cursor addressing |
| `cjk` | wide and multibyte text |
| `region` | DECSTBM region + status line, as vim/less/tmux set |
| `agent-claude` | a recorded agent CLI session, TUI and all |
| `agent-stream` | a recorded colourised diff streaming at full speed |

They are **committed files, not generated at run time**, so a number from today
stays comparable with one from a year from now. Regenerate them only to add a
corpus or deliberately change one — doing so voids every baseline that came
before.

## Recordings carry whatever was on the screen

A recorded corpus is a real program's output, and a real program prints
banners, paths and session identifiers. `zig build record` redacts known
secret shapes as it writes, and `zig build check-corpora` — which CI runs,
and which **gates**, unlike the bench and the gallery — fails if a committed
corpus contains one. Both use `src/redact.zig`, so the guard at the door and
the check on the shelf cannot drift apart.

Replacements are the same length as what they replace, because each `.bin`
has a `.timing` sidecar recording how many bytes arrived in each read.

It is a guard, not a guarantee: it knows the shapes it knows. Read a
recording before committing it.

## Adding a corpus

Add a generator to `bench/gen_corpus.py`, append it to the tuple in `main()`,
then:

```sh
python3 bench/gen_corpus.py
```

Each corpus is seeded independently, so a new one does not shift the bytes of
the existing ones — verify that with `shasum -a 256 bench/corpus/*.bin` before
and after. Then register it in the `corpora` array in `src/bench.zig` and in
`corpus_names` in `build.zig`.

`region` was added this way after the fact, and the other five stayed
byte-identical.

## Proposing performance work

Bring a corpus and a number, not an argument. The roadmap was written once from
reading the source, and the largest bottleneck in the program was not on it —
see [the Sprint 0 record](roadmap/completed/sprint-0-benchmarks.md).
