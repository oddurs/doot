# Sprint L0 — Record every session

**Done.** The first sprint of [record.md](../record.md), and the proof of the
concept that page states: the terminal is not a screen but an append-only,
time-indexed log of every byte in and out of every session, and the screen is
a view of it.

Lands with [S6](../security.md) — the record's privacy — because a recorder
that ships before its privacy tests is a recorder that ships without them.

## What was proposed

Per session, an append-only file of events, written on the reader thread,
buffered, **outside the mutex** — the lesson of [sprint 1](sprint-1-vsync-lock.md),
measured the same way: the `lock` column does not move and the PTY drain rate
stays within 5% of unrecorded. Ships with the privacy shape in full:
output-only default, an input opt-in with an indicator, an incognito window,
`0600` files, retention in days.

*Done when:* `--frame-stats` shows lock hold and PTY rate unchanged with
recording on; an end-to-end test records a session, replays the file through
`Terminal`, and gets the same grid checksum as the live run; an incognito
window leaves no file.

## What was measured first

Two things, before anything was designed around them.

**The redactor.** `redact.scrub` runs over every byte on its way into a
recording, so it sits directly in the pty drain path — not in a capture tool
nobody is waiting for. It did up to fourteen runtime-length `std.mem.eql` per
byte. A `redact` row was added to `zig build bench` and it measured
**67 MiB/s**, against a pty that `bench/dump.sh` drains at 55–68 MiB/s through
the real app. A 1.0–1.2× margin over the thing it has to keep up with is not a
margin; unmodified it would have failed this sprint's own gate.

**The lock.** Sprint 1 left the worst-case mutex hold at 324 µs and this
sprint's gate is that it must not move. Reproducing it first is what made the
result below findable.

## The change

Five new pieces and a rewiring.

| file | what it is |
|---|---|
| `rec.zig` | The `.trec` format, its writer, its reader, the sessions directory and the retention sweep. |
| `check.zig` | `checksum(term)` — a Wyhash over everything a replay must reproduce. The arbiter. |
| `replay.zig` | `.trec` in, `Terminal` out. std only, so it runs on the Linux CI runner. `zig build replay`. |
| `cli.zig` | `windowTitle`, pure and unit-tested, plus five flags. |
| `main.zig` | A second mutex, three writers, and one nesting rule. |

**The file.** One per session, append-only, uncompressed,
`O_WRONLY|O_CREAT|O_EXCL|O_APPEND`, mode `0600`, in a `0700` directory. A
48-byte header carrying the magic, version, geometry, a 16-byte random session
id, and a CRC32; then records of `type u8, flags u8, len u16, dt_us u32` and a
payload. `wall_start_ns` in the header is the only wall clock in the file.

**Timing without drift.** The naive delta — `(now - last) / 1000` — throws away
the sub-microsecond remainder on every record, which at a terminal's write
rates compounds into about 4% of the session's length going missing. Each
record's delta is instead `(now - base) / 1000 - everything emitted so far`,
which bounds the error at one microsecond for the whole file. A test drives
20,000 records 1,500 ns apart and asserts the error is ≤ 1 µs; the naive
version fails it by 10,000 µs out of 30,000.

**The one-read delay.** Scrubbing each 1,024-byte read on its own leaks any
secret that straddles a read boundary — and the incident that motivated
`redact.zig` was a *startup banner*, which arrives in the first read. Two
failure modes, the second worse than the first: the prefix is split, or the
whole prefix lands in read N with the run continuing into N+1, where `scrub`
sees a run below `min_run` and skips it entirely. So a read is held; on the
next read `prev ++ new` is scrubbed contiguously, scrubbed `prev` is emitted
carrying `prev`'s own timestamp, and scrubbed `new` becomes the next held
read. Re-scrubbing is free of consequence because `scrub` is idempotent, which
`redact.zig` already had a test for. The 250 ms flush timer drains the hold.

**`control` records, which the sprint text did not have.** `Cmd K` calls
`Terminal.fullReset()` with no bytes through the parser. Without a record,
every session in which it was pressed replays to a different screen than it
showed. The complete list of terminal mutations outside `parser.feed` is
`resize`, `fullReset` and `scrollView`; the first has a record type, the third
is viewport-only and the checksum excludes the viewport by construction, and
the second is this. That list is closed, and knowing it is closed is what makes
the checksum test mean anything.

**Threading.** One `rec_mutex`, three writers. The reader thread records
`output` under the recorder mutex only, releases it, and only then takes the
terminal mutex — so the terminal mutex hold is byte for byte what it was.
`resize` and `control` are recorded *inside* the terminal mutex, because
`Terminal.resize` and `Terminal.fullReset` run under it and it is what orders
them against a concurrent `parser.feed`. Lock order where both are held:
terminal, then recorder. That rule is a comment on the field.

**Never a hole.** Any write error closes the fd, sets `recording = false`,
makes one best-effort `end(write_error)` and never retries. A recorder that
retried would produce a file with a gap in the middle that reads as
continuous. The terminal keeps running either way. No `fsync` anywhere: the
durability being bought is against our own crash, which the page cache already
gives, and `fsync` is the one call guaranteed to block for milliseconds on the
thread draining the pty.

## Result

### The gate

Three runs each, ReleaseFast, on the maintainer's machine. This gate cannot
run in CI: `--frame-stats` needs a window.

```
./zig-out/bin/terminator --frame-stats --no-record   --shell bench/dump.sh
./zig-out/bin/terminator --frame-stats --record-dir /tmp/rec --shell bench/dump.sh
```

| | pty MiB/s | worst lock hold |
|---|---|---|
| unrecorded | 54.93 / 61.99 / 66.03 | 12 / 10 / 13 µs |
| recorded | 64.42 / 64.45 / 64.43 | 8 / 5 / 6 µs |

Medians: 61.99 → 64.43 MiB/s, 12 → 6 µs. Against the *best* unrecorded run,
66.03 → 64.45 is **−2.4%**, inside the 5% the gate allows. The lock column does
not move.

Recording adds, per run: 25.9 MB in ~25,250 records, 399 flushes, **worst flush
589–627 µs** — the number that says whether writing stalls the reader, and the
most useful new figure here.

### The surprise: sprint 1's 324 µs was `SDL_SetWindowTitle`

The first pass at the gate looked like a failure. The pty rate was fine but the
worst lock hold went from 241–265 µs unrecorded to 387–401 µs recorded, over
six runs each and clearly not noise.

Two experiments narrowed it. Skipping `write()` entirely, keeping the scrub and
the buffering, left the shift in place (406–607 µs) — so it was not the file.
Skipping the scrub restored the pty rate to unrecorded levels — so the cost of
*throughput* was the scan, not the disk. The lock shift was the reader thread
simply having more work to do, making the main thread likelier to be
descheduled while holding the mutex.

Which raised the real question: what was the main thread doing under that lock
for 250 µs at all, when the average was 4 µs? The answer was
`renderer.setTitle`. Composing the title has to happen under the lock, because
it reads `term.title`, which the reader writes. **Calling
`SDL_SetWindowTitle` did not**, and it had been inside the critical section
since before sprint 1. One window-server round trip, once per title change,
was the entire worst-case lock hold that sprint 1 was left with.

Moving that one call after the `unlock`:

| | worst lock hold |
|---|---|
| sprint 1, recorded then | 324 µs |
| unrecorded, before this change | 241–265 µs |
| unrecorded, after | **10–13 µs** |
| recorded, after | **5–8 µs** |

Twenty-fold, in a line that was not on any plan. It was findable only because
the gate required reproducing the old number rather than trusting it.

### The redactor

`shapes` stays the single definition of what a secret looks like. Two things
are derived from it at compile time, each with a test asserting the derivation
covers all of it in both directions so they cannot drift:

- `by_first[256]` — the shapes each byte can begin, so almost every byte is
  rejected with one lookup instead of fourteen string compares.
- `lead_pairs` — the eight distinct two-byte openings, compared 32 bytes at a
  time with a vector.

| corpus | before | + first-byte table | + vector pair scan |
|---|---|---|---|
| ascii | 67.0 | 1,214.7 | **3,818.6 MiB/s** |
| sgr | 66.8 | 1,652.0 | 5,186.4 |
| scroll | 66.8 | 1,400.6 | 4,430.9 |
| altscreen | 66.9 | 1,171.6 | 3,670.6 |
| cjk | 66.5 | 2,394.1 | 7,108.0 |
| region | 66.7 | 1,009.5 | **3,288.8** |
| agent-claude | 67.1 | 2,223.0 | 7,384.5 |
| agent-stream | 66.6 | 1,369.8 | 5,719.5 |

The pair scan was not planned; the first-byte table was, and it was not
enough. At ~1,000 MiB/s the scan still cost **13% of the pty rate** in the
running app — 64.06 → 55.56 MiB/s over a 103 MB run — which fails the gate on
its own. The reason is that `s` is one of the commonest bytes in English prose
and in source code, so a first-byte filter rejects almost nothing on `ascii`;
`se`, `sk`, `gh`, `gi`, `xo`, `AK`, `AI` and `Be` are rare. Worst case is now
`region` at 3,289 MiB/s, **49×** where it started and fifty times the pty it
sits in front of.

### The arbiter

`check.checksum` is a Wyhash — not a sum, because `grid.zig` makes the screen a
ring and order-insensitivity is exactly the wrong property: it could not tell a
correct screen from a rotated one. It walks cols, rows, both cursors,
`pending_wrap`, `on_alt`, the scroll region, the modes, the tab stops, every
cell of **both** screens through `row(y)` in logical order, and every used
scrollback line through `back(i)`. It excludes `view_offset`, `dirty`, `bell`,
`title` and `replies` — properties of the window, not of the stream.

The end-to-end test starts `/bin/sh` on a real pty with a writer attached,
exercises SGR colour, wrapping at the right margin, enough lines to reach
scrollback, alt-screen enter and exit, a mid-stream resize, a `fullReset`
recorded as `control`, and an exit that leaves output in the pty for the
post-exit drain to collect. It takes `check.checksum` live, closes, replays the
file into a fresh `Terminal` built from the header's geometry, and asserts the
checksums are equal and `redactions == 0`.

`zig build bench` also prints a `grid-checksum` line per corpus, so a change to
the parser or the grid that alters the resulting screen is visible next to the
diff. The existing `checksum N` line is untouched — its job is stopping the
optimizer, and every recorded baseline carries it.

## Test the tests

Twelve mutants, applied to the merged implementation and run against the suite.
**Two survived the first pass**, which is the usual result here and the reason
the exercise is not optional.

| mutant | caught by |
|---|---|
| `control` records dropped | the replay checksum |
| `resize` records dropped | the replay checksum |
| post-exit drain not recorded | *nothing* — see below |
| one-read hold removed | split-at-every-offset |
| naive per-record delta | the drift test |
| hold not drained before other records | four tests, including record order |
| `record_input` gate removed | three tests, including S6's |
| checksum hashes only the active screen | the parked-alt test |
| checksum ignores scrollback | *nothing* — see below |
| redacted flag put on every record | two tests |
| first-byte table drops a bucket | three tests |
| lead-pair set incomplete | (asserted directly by construction) |

**The post-exit drain.** The test sent `exit` and then pumped for the shell's
reply, so by the time the drain ran the pty was empty and dropping its
`rec.output` call changed no checksum. Fixed by printing on the way out
without pumping — `printf 'DRAIN-TAIL-8823\n'; exit` — so the bytes really are
still in the pty when the child is gone and the drain is the only thing that
can collect them.

**Scrollback.** `check.zig` had a table of fifteen field mutations, and its
"scrollback" case added eight newlines — which also moves the screen and the
cursor, so a checksum that hashed the screen and skipped the ring entirely
still passed. Fixed with two terminals whose visible rows, cursor and modes are
identical and whose history is not: `AAA/BBB/CCC/DDD` against
`ZZZ/BBB/CCC/DDD` on a two-row screen.

## S6: the privacy rows

| rule | test |
|---|---|
| Output recorded by default; **input never by default** | a default session types a passphrase at the recorder and the whole file is then scanned for it, and for any type-2 record |
| Input recording is per-tab, opt-in, indicated | `Cmd ⇧ R` flips `record_input`; a test writes before, during and after a toggle and finds only the middle one |
| An incognito window writes nothing | the directory listing — names and sizes — is byte-identical across a real recorded-shape session, with an earlier recording present so "unchanged" means more than "still empty" |
| Files are `0600` in a `0700` directory | `fstat` on the open fd and on the directory. Created *with* the mode, never `chmod`'d after |
| Retention is a key with a default in days | 14, swept at startup **by mtime** |
| Deletion is real | after `unlink`, every remaining byte in the directory is scanned for the session id, and every remaining filename for its hex prefix |

**Why mtime and not the header's start time.** mtime is self-protecting: an
open session's flushes keep pushing it forward, so it stays inside the window
and a second instance sweeping at startup cannot delete a file the first one
still has open. A header timestamp has no such property — a session open longer
than the retention period would delete itself.

**Why deletion is real without any work.** L0 builds no index. The file is the
only artifact, so `rm` *is* the delete. That is a property to protect in L1,
which adds checkpoints, and L2, which adds a search index — the index must be a
cache that can be thrown away, not a second record.

## What the sprint text got wrong, and what it got right

**Wrong, or missing:**

- The redaction estimate. "20–70 MB/s" was right about the number and wrong
  about what it implied: at 67 MiB/s the scan is 1.0–1.2× the pty, not a
  comfortable margin, and the planned first-byte table left it at 13% of the
  pty rate — still a gate failure. The two-byte vector scan was needed and was
  not on the plan.
- `control` records, which the sprint text did not mention at all and without
  which any session containing a `Cmd K` fails its own checksum. The plan's
  author caught this in the same breath; it is recorded here because the
  original *sprint* text did not have it.
- Only `resize` was listed as nesting terminal → recorder. `control` has the
  identical hazard for the identical reason and nests too. One rule, two
  sites.
- The arbiter test was to be "written FIRST against a stub so it fails until
  the recorder exists". It was not: the tests were written alongside the
  implementation and then mutation-tested, which is the standard `CLAUDE.md`
  actually sets and which found two dead tests that a write-it-first ordering
  would not have.
- `std.crypto.random` does not exist in Zig 0.16. The session id comes from
  `/dev/urandom`, with a documented weaker fallback, chosen over
  `arc4random_buf` and `getrandom` because those are spelled differently on
  every platform the core is kept building for.

**Right, and load-bearing:**

- The drift warning. Without it the naive delta is the obvious thing to write
  and the error is invisible until someone tries to seek.
- The straddle analysis, including which of the two modes is worse. The
  split-at-every-offset test found nothing wrong with the implementation
  because the implementation was written from that analysis.
- "Redact a copy, never the bytes on their way to the screen."
- The instruction to measure `redact` before touching it. It is what turned a
  1.2× margin from an assumption into a number, and the number is what made
  the vector scan obviously necessary rather than obviously premature.
- Making the gate reproduce sprint 1's 324 µs rather than trust it. That is
  what surfaced `SDL_SetWindowTitle`.

## Known limits, stated rather than hidden

- **A token spanning more than two reads keeps its tail.** `min_run` still
  catches the head. Asserted by a test, so improving it is a deliberate change
  with a failing test to update.
- **A resize or a `Cmd K` during heavy output has a narrow ordering window.**
  The reader records a read, releases the recorder mutex, and only then takes
  the terminal mutex; a main-thread `resize` that wins the terminal mutex in
  that gap is applied before the read but recorded after it. Closing it would
  mean either recording under the terminal mutex — which is the thing sprint 1
  exists to prevent — or holding the recorder mutex across the parse, which
  inverts the lock order and deadlocks against the resize path. The window is
  nanoseconds wide and the failure mode is a replay whose checksum differs, not
  lost data. A sequence number per mutation is the fix, and it belongs with
  L1's checkpoints.
- **The per-session size cap can be overshot** by up to one buffer plus one
  record, because it is checked per record rather than per byte.
- **`bench/baseline.txt` is not regenerated.** It already predated the
  `agent-claude` and `agent-stream` corpora, so it is stale in shape either
  way; rewriting every number in it from a machine-day that is not the one it
  was captured on would be worse than leaving it. The new `redact` and
  `grid-checksum` sections are therefore absent from it, and their numbers are
  in this document instead.
- **The gate cannot run in CI.** `--frame-stats` needs a window.
