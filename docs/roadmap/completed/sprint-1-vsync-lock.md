# Sprint 1 — Get the vsync wait out of the lock

**Done.** Closed [#7](https://github.com/oddurs/terminator/issues/7).

## What was proposed

`main.zig` called `renderer.draw()` with the terminal mutex held, and `draw()`
ended in `SDL_RenderPresent` with vsync on. The wait for the next vblank
therefore happened *inside* the critical section: the reader thread could not
feed a byte to the parser while the main thread was parked waiting for the
display. Bulk output was predicted to be capped near the refresh rate.

The roadmap called this the smallest diff with the largest structural effect,
and noted that the headless bench could not see it — the sprint would have to
bring its own instrumentation.

## What was measured first

`--frame-stats` prints, once a second, how long the main thread held the mutex
per frame, how long the frame took to build, how long `SDL_RenderPresent`
waited, and how fast the reader drained the PTY. `bench/dump.sh` cats the six
corpora at the terminal and exits, so

```sh
./zig-out/bin/terminator --frame-stats --shell bench/dump.sh
```

is an end-to-end benchmark: real PTY, real parser, real grid, real frames.

Before the change, on a 120 Hz display:

| | per frame |
|---|---|
| mutex held | **~8,000 µs** avg, 31,678 µs worst |
| of which present | ~7,700 µs |
| frame build | ~300 µs |
| PTY drained at | **0.26–0.40 MiB/s** |

24 MiB of output took between 61 and 95 seconds. The reader got the lock for
one small PTY chunk per refresh — a few KiB — and then lost it again for the
whole of the next frame. The prediction was right, and it was worse than
"near the refresh rate": the parser can do 100+ MiB/s, and the display was
letting it use a third of one percent of that.

## The change

`Renderer.draw(term)` became two calls with different locking rules:

- `snapshot(term)` — with the mutex held — copies the visible rows and the
  cursor into a renderer-owned `Frame`. A memcpy of the viewport: ~48 KiB at
  100×30, tens of microseconds.
- `draw()` — with the mutex released — renders that copy and presents it.
  Nothing in it touches the terminal.

The `Frame` holds values only. That is the property the roadmap flagged as
the specific bug to guard against: a display list that aliases terminal
state after the unlock would draw a grid the reader is halfway through
rewriting.

Wake-up coalescing needed no new code. The reader already queues at most one
wake event; everything it parses while a frame is presenting lands in the
next snapshot. Frames pace themselves at the refresh rate because present
still blocks — just not while holding anything.

## Result

Same machine, same script, three runs each:

| | before | after |
|---|---|---|
| mutex held per frame (avg) | ~8,000 µs | **2 µs** |
| mutex held per frame (worst) | 31,678 µs | 324 µs |
| present per frame | ~7,700 µs, inside the lock | ~7,900 µs, outside it |
| 24 MiB dump | 61–95 s | **0.5–0.6 s** |
| PTY drained at | 0.26–0.40 MiB/s | **41–51 MiB/s** |

Roughly **150×**. The lock column is now the copy and nothing else.

## Where the ceiling is now

`script(1)` draining the same 240 MiB into `/dev/null` takes 2.7 s, which is
about 89 MiB/s — the cost of `cat` and the kernel's tty layer with no
terminal attached at all. Parsing 240 MiB takes about 2 s at the bench's
~120 MiB/s blended rate. The reader thread does those two things one after
the other — read a chunk, parse it, read the next — so they add rather than
overlap, and 2.7 + 2 ≈ 5 s is exactly what the runs show.

So the end-to-end number is now bounded by the reader's parse speed, which
means [Sprint 4](../performance.md) — the printable-run fast path — will
show up directly in this measurement, not only in the headless bench. That
is the attribution the roadmap said this sprint had to make possible.

## What the timer sees that the bench does not

The `build` column occasionally spikes to ~8 ms in the first second of a run
and then settles at ~65–270 µs. That is glyph rasterization and atlas upload
on first sight of each character — a one-off per glyph, but a whole frame
each time it happens. Not on the plan; noted here so that the number is not
mistaken for a Sprint 2 regression when the vertex path lands.
