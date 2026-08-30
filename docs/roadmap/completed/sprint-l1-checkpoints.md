# Sprint L1 — Checkpoints and seek

**Done.** The second sprint of [record.md](../record.md), and the one
[priorities.md](../priorities.md) says the whole roadmap stands or falls on:
*"scroll back into a closed `vim`. The moment the concept is visible; if it is
not, L retires here."*

L0 made the session a log. L1 makes any moment in that log reachable in the
time it takes to decode one checkpoint, and puts the last frame of every
full-screen program the session ran behind one key.

**Interrupted once.** The machine slept partway through the first session's
verification, which is why the branch carried a `wip:` commit for a day. The
codec, the worker, the replay bounds and the keys were written then; the
arbiter, the end-to-end test, the gallery capture, the lock experiment, the
mutation pass, the gate and this record were written after. Where the second
half found the first half wrong — the index was being built on the *main*
thread — it is said below rather than quietly fixed.

## What was proposed

> Every 4 MiB of output, or every minute, a checkpoint: the `Frame` copy plus
> the terminal's mode state, appended to a side index. Materializing time *T*
> is loading the nearest earlier checkpoint and replaying forward. A scrubber
> — `Cmd ⇧ ←/→` and a timeline drawn in the padding — moves the view through
> the session's history, including every frame of every alt-screen program it
> ran.

*Done when:* seeking to any second of an hour-long recorded session
materializes in under 50 ms at 200×60; the "scroll back into a closed vim"
demo works; the golden checksum test passes at every checkpoint boundary.

*Risk:* medium. Mode state that is not in the `Frame` — scroll region, saved
cursor, tab stops, charset — must be in the checkpoint or replay diverges.

## What was measured first

Two numbers, before the design was allowed to depend on either.

### Parse at 200×60, which nothing had ever measured

Every budget on the record roadmap is stated at 200×60. `zig build bench`
measured 80×24. The whole "under 40 ms" argument for a 4 MiB interval rests on
the page's claim that *"the bench parses every corpus at over 100 MiB/s"* —
true at 80×24, and not the geometry the budget is about.

A second parse table now runs the same corpora at 200×60:

| corpus | MiB/s | vs 80×24 | 1 MiB in ms |
|---|---|---|---|
| ascii | 254.4 | 0.54× | 3.9 |
| sgr | 305.2 | 0.85× | 3.3 |
| scroll | 114.1 | 0.43× | 8.8 |
| altscreen | 242.8 | 0.63× | 4.1 |
| cjk | 127.8 | 0.64× | 7.8 |
| **region** | **70.7** | **0.55×** | **14.1** |
| agent-claude | 240.3 | 0.72× | 4.2 |
| agent-stream | 259.0 | 0.62× | 3.9 |

Widening the grid costs between 15% and 57% of the parse rate, and the worst
corpus — `region`, which is what `vim`, `less` and `tmux` produce — runs at
**70.7 MiB/s**, not "over 100". So the page's arithmetic:

- **4 MiB at 200×60 is 56.6 ms of replay on `region`**, plus a 1.9 ms decode.
  The budget is 50 ms. The proposed interval is *over* the sprint's own
  target on the workload the sprint is for, not comfortably inside it.
- **1 MiB is 14.1 ms**, worst corpus, worst geometry. That is the interval
  `ckpt.Options.interval` ships with, and it is chosen from this row rather
  than from an estimate.

The estimate was not wildly wrong — it was wrong by exactly the factor between
80×24 and 200×60, which is the factor nobody had measured.

### What a checkpoint costs, and the rule it had to beat

The sprint plan carried a rule: *if a 200×60 full-history checkpoint exceeds
about 2 MB or about 20 ms to encode, the full-scrollback checkpoint is dead
and the design falls back to two tiers* — screens now, history on demand.
Whether that rule fires is the most important number in the sprint, so a
`checkpoint` table was added to the bench before the fallback was designed.

| terminal | geometry | bytes | encode µs | decode µs | ring |
|---|---|---|---|---|---|
| ascii | 80×24 | 279,330 | 1,221 | 595 | 5,617 |
| ascii | 200×60 | 279,124 | 1,705 | 1,070 | 5,513 |
| cjk | 80×24 | 612,711 | 1,765 | 988 | 8,073 |
| cjk | 200×60 | 612,836 | 2,629 | 1,610 | 8,037 |
| agent-claude | 200×60 | 2,369 | 40 | 17 | 0 |
| **+ full ring** | **80×24** | **610,026** | **2,517** | **1,306** | **10,000** |
| **+ full ring** | **200×60** | **612,347** | **3,463** | **1,939** | **10,000** |
| + unchanged | 80×24 | 1,568 | — | — | reused |
| + unchanged | 200×60 | 3,889 | — | — | reused |

**The rule does not fire.** The worst case the rule was written about — a
10,000-line scrollback filled to capacity with varied, coloured content, at
200×60 — is **0.58 MB and 3.5 ms**, against thresholds of 2 MB and 20 ms.
Three and a half times inside on size, nearly six times inside on time. The
two-tier fallback was designed for and is not needed; `flag_screen_only` is
reserved in the format and unused, and the sprint record says why rather than
leaving a reader to wonder what the spare bit was for.

The two rows that make the agent case cheap are the last two. A checkpoint
taken while a full-screen program is running is **3,889 bytes** at 200×60,
because the history has not moved and `scrollback_unchanged` points the entry
at the previous blob. That is what makes checkpointing *through* a `vim`
session affordable rather than the thing that makes the index too big to keep.

The style table is why the numbers are what they are: a row is runs of
(style, count, codepoints), so a screen of ordinary shell output costs about a
byte a character, and a 10,000-line ring of coloured text at 200 columns —
32 MB of `Cell` in memory — encodes to 0.58 MB.

## The change

| file | what it is |
|---|---|
| `ckpt.zig` | The checkpoint codec, the in-memory index, and the builder that derives one from a `.trec`. |
| `seek.zig` | The worker, the state machine, the second `Terminal`, and the status row. std only, no SDL. |
| `replay.zig` | `applyEvent` and `materializeInto`: replay into a terminal the caller owns, from event *a* to event *b*. |
| `rec.zig` | `parseFrom` (records from an offset, so a refresh reads the tail) and `flushForSeek`. |
| `check.zig` | `field_cases` exported, so the codec's round-trip test iterates the arbiter's own table. |
| `grid.zig` | `Scrollback.pushes` and `.epoch` — the identity `scrollback_unchanged` rests on. |
| `render.zig` | `setStatus`: the status row replaces the bottom row of the snapshot, as cells. |
| `main.zig` | The thread, the keys, and the one place the recorder mutex is taken. |

**A checkpoint is derived from the log, never from the live terminal.** The
reason is in "what the sprint text got wrong" below, and it is the decision
everything else follows from.

**Nothing is written to disk.** Record types 8 and 9 stay reserved and
unwritten. The index lives in memory for as long as the window does, and `rm`
is still the whole of deleting a session — the property L0's privacy record
asked L1 to protect.

**What is in a checkpoint**: everything `check.checksum` hashes, plus three
things it deliberately does not and a seek must nonetheless restore —
`next_line_id` (or ids minted after a seek collide with ids already in the log
and [E1](sprint-e1-selection.md)'s selection resolves onto the wrong row), the
title (the window says what the child called itself), and
`scrollback.pushes`/`.epoch` (which is how `scrollback_unchanged` is decided).
Left out: `view_offset`, `selection`, `dirty`, `bell`, `replies` — the same
line `check.zig` draws — and two properties of a *representation* rather than
of a model, `Screen.offset` and `Scrollback.head`, both canonicalised on
decode.

**Trimming is by exact `Cell.blank` equality, not `Cell.isBlank()`.** The
latter ignores the foreground and the attributes, because it exists to decide
whether a cell is worth *drawing*. A red underlined trailing space is
`isBlank()` and is not blank, and a codec that trimmed by it decodes to a
different checksum. It is a planted mutant, and the end-to-end test prints
`\033[31;4mCOLOURTAIL   ` through a real shell for the same reason.

**One extra checkpoint, on one extra trigger**: the pty read that leaves the
alternate screen, taken *before* the event is applied, so the state saved is
the last frame the full-screen program drew. That entry is marked `forced` and
decimation may never drop it. `Cmd ⇧ ↑` is then a decode and **zero events of
forward replay**, which the end-to-end test asserts as
`expectEqual(0, st.last_replayed)`.

### The design fix the second half found

`seek.zig` shipped its first half with the worker reading the file and the
**main thread** replaying it into an index, on the argument that a refresh has
its events split across two buffers. That argument is true and the conclusion
was wrong: the replay is 383–946 ms on a 50–100 MB session, and putting it on
the frame loop is a visible freeze on the first `Cmd ⇧ ↑`.

The worker now does all of it. It is handed the events an earlier build
produced as a borrowed slice, and that is safe for exactly one reason worth
naming: `State.events` is appended to only in `absorb`, `absorb` runs on the
main thread after `done` is set, and every key press that arrives while a
build is in flight is *queued* rather than acted on. Two mutants pin it — one
that leaves the index unbuilt by the worker, one that indexes the tail alone.

Moving it surfaced a second bug on the way. `absorb` freed the previous index
with `if (self.index) |*i| { self.index = null; i.deinit(); }` — and clearing
the optional invalidates the pointer into its payload, so `deinit` ran over a
zeroed struct and leaked the whole index. The leak-checking allocator in the
new refresh test is what caught it.

## Result

### The gate

Eight **interleaved** cycles — unrecorded, recorded, recorded with a busy
thread, repeated — ReleaseFast, at the default 100×30, on the maintainer's
machine with nothing else running. `PASSES=64`, so each run drains 98 MiB
through a real window. As with L0, this gate cannot run in CI: `--frame-stats`
needs a window.

```
PASSES=64 ./zig-out/bin/doot --frame-stats --no-record                      --shell bench/dump.sh
PASSES=64 ./zig-out/bin/doot --frame-stats --record-dir /tmp/rec            --shell bench/dump.sh
PASSES=64 ./zig-out/bin/doot --frame-stats --record-dir /tmp/rec --busy-threads 1 --shell bench/dump.sh
```

| | pty MiB/s (median of 8) | worst lock hold (range over 8) |
|---|---|---|
| unrecorded | **68.86** | 9–14 µs |
| recorded | **65.39** | 9–24 µs |
| recorded + a busy thread | **59.24** | 10–14 µs |

**The lock does not move.** Not between the three arms, and not in a
direction: the single worst hold in the whole set — 24 µs — is in the
*recorded* arm with no extra thread, and the arm with a thread spinning
flat out for the entire run has the tightest range of the three. Against the
gate's "≤ 10 µs" the honest answer is that this machine-day reads 9–24 µs
across every arm including the unrecorded one, so the threshold is not met in
absolute terms and **nothing L1 added is why**. L0 measured 5–8 µs recorded
against 10–13 unrecorded; the number moves with the machine, and the claim
that survives re-measurement is the *comparison*, not the constant.

**Recording costs 5.0% of throughput today** (68.86 → 65.39), which is at the
edge of the 5% L0's gate allows rather than inside it. That is L0's cost
re-measured, not something L1 added — L1 puts nothing on the pty path — and
L0's own record already says the figure is a range (it measured −2.3% on a
quiet machine and −4.9% on a busy one) and that a future run should quote what
it gets. This one gets −5.0%.

### The busy-thread experiment

L0's record explains its lock shift as *"the reader thread simply having more
work to do, making the main thread likelier to be descheduled while holding
the mutex."* L1 adds a thread, so that had to be measured rather than
inherited. `--busy-threads N` (hidden; a measurement instrument, like
`--select` is a capture instrument) spawns threads that do nothing but parse a
generated corpus in a loop, forever. It is deliberately *worse* than the seek
worker it stands in for: the worker reads a file and replays a session once,
in a few hundred milliseconds; this never stops.

The result is the third row above, and it splits in two:

- **The `lock` column does not move.** 10–14 µs with the thread, against 9–14
  unrecorded and 9–24 recorded. So the plan's contingency — *"if the lock
  column moves, the index must be built lazily and paused while the pty is
  busy"* — **does not fire**, and the index is built eagerly on the key press.
- **Throughput does move: −9.4%** against the recorded arm (65.39 → 59.24).
  That is not what the contingency was written about and it is real: a second
  CPU-bound thread in this process costs the pty drain about a tenth of its
  rate for as long as it runs. For the seek worker that is a few hundred
  milliseconds, once, on a key the user just pressed, and the alternative — a
  lazy build — trades it for a slower first seek. Stated rather than hidden:
  if a session ever drives the worker for seconds rather than
  milliseconds, this is the number that would justify pausing it.

### Seek latency

`--seek-sweep N` (hidden, same reason) seeks to N evenly spaced moments
through the whole session and reports the distribution, through the same
`State.seekTo` a key press calls. Over the 98 MiB `bench/dump.sh` session
recorded above, at **200×60**:

```
seek: index 50 entries, 0 spans, 367 KiB, 100909 events, worker 946 ms (18 ms read)
seek-sweep: 200 seeks over 100909 events, 9.1 ms median, 19.2 ms p95,
            21.4 ms worst, 0.5 ms best; 995 events replayed on average, 2027 worst
```

| the gate asks | measured |
|---|---|
| seek p95 ≤ 150 ms end to end | **19.2 ms** — 7.8× inside |
| materialize ≤ 50 ms at 200×60 | **21.4 ms** worst of 200 |

The `946 ms (18 ms read)` split is the number that decided where the index is
built: **98% of the worker is replay, 2% is I/O**. A worker that only read the
file — which is what the first half of this sprint shipped — would have
parallelised the 2% and left the 98% on the frame loop.

98 MiB is roughly an hour of heavy agent output, which is the "hour-long
recorded session" the sprint text asks about; a real hour of *interactive*
shell use is far less.

### Memory

`/usr/bin/time -l`, 200×60, over a 49 MiB session chosen to fill the
10,000-line scrollback ring (so the index holds the expensive kind of
checkpoint), with and without a seek:

| | maximum resident set size |
|---|---|
| recorded, never sought | 122.4 MiB |
| recorded, index built and 200 seeks | 225.8 MiB |
| | **+103.4 MiB** |

Of which, at 200×60:

| | |
|---|---|
| the index itself | **16.2 MiB** (reported by `--frame-stats`; capped at 32 MiB by `Options.max_bytes`) |
| the `.trec`, held in memory | 49 MiB — see the known limits |
| the view `Terminal` | 30.9 MiB: a 10,000-line ring at 200 columns is 30.5 MiB of `Cell` on its own |
| the worker's `Terminal` | 30.9 MiB, **transient** |

**The worker's `Terminal` is freed after the build**, and the arithmetic above
is the measurement that says so: the four lines sum to 96.5 MiB against a
measured peak of 103.4 MiB (the difference is the event array, the temporary
merged event slice and allocator overhead), whereas a worker that kept its
terminal would have peaked around 127 MiB. `ckpt.build` frees it with a
`defer`, and every test that calls `build` runs under `std.testing.allocator`,
which would report a 30 MB leak if it did not.

### The arbiter

L0's arbiter is one comparison: the live grid against a replay of the whole
log. L1's is a family of them, because a seek is *two readings of the same
log* and they have to agree everywhere they could disagree.

For a hand-built fixture `.trec` and for **every bench corpus wrapped into a
synthetic one** — through the real `rec.Writer`, in 1,024-byte reads, so the
events have the shape a real session produces — the test builds an index and,
for every checkpoint in it and six targets after each, asserts that

> restore the checkpoint + replay forward == replay from the start

It compares the checksum **and the three things the checksum is deliberately
blind to**: `next_line_id`, the title, and every row id on both screens and
through the whole ring. That last one has teeth: a seek that minted ids
colliding with ids already in the log would make E1's selection resolve onto
the wrong row, and no checksum in this repository would notice.

The fixture is run twice, the second time with a budget small enough to force
decimation, because a decimated index is a different index and the claim has
to hold over it too. The corpora are the only inputs that put a checkpoint
boundary somewhere nobody chose — mid-redraw, mid-wrap, between two halves of
a CJK codepoint.

It is written as one forward walk plus one seek per target rather than a
replay per target, so the reference is O(events) instead of O(events ×
targets); that is what makes eight corpora affordable in a Debug build.

### The demo, as an assertion

`src/tests.zig`, on a real pty with a real `/bin/sh`: print past the ring into
history, print a coloured trailing space, enter the alt screen, print
`ALT-SENTINEL-8823`, leave, print more, exit. Then build the index the way the
worker builds it, and:

- **exactly one** alt-screen span (not "at least one" — a builder that opened
  a span per read would pass that);
- `prevSpan()` lands on its exit, `on_alt` is true, the sentinel is on the
  active screen and the text printed *after* the program is not;
- `last_replayed == 0` — a decode and no forward replay;
- the whole fingerprint equals a replay-from-scratch to that event;
- `toEnd()` equals the live terminal's checksum, which is the identity that
  makes "seek to now" mean anything;
- and `toLive()` keeps the index and the view terminal, so the next seek is a
  decode rather than a rebuild.

**One thing this test taught, and it is in the shipped code as a caveat.**
Written as one shell command — `printf '\033[?1049h'; printf 'SENTINEL\n';
printf '\033[?1049l'` — it failed about one run in three. The index can only
force a checkpoint at a whole pty read, so when a program's final repaint and
its `?1049l` arrive in the same read, the checkpoint lands one read early and
the frame you get is the one before the interesting one. The test now pumps
for the sentinel before sending the exit; the gallery scene sleeps 200 ms for
the same reason, and two runs of it without the sleep differed by exactly the
last line of the frame. It is a real limit of the feature, it is written on
`ckpt.build`, and it is below.

### The picture

`bench/gallery/seek.sh` draws an agent TUI on the alternate screen and exits
it, and `seek-span-14pt-1x` photographs the frame with `--seek-span 1` — the
frame the live screen no longer has, with the seek status row painted as the
bottom grid row underneath it.

The status row is **cells, not an overlay**: `seek.zig` builds one row of
`grid.Cell` and the renderer swaps it for the bottom row of the snapshot, so
it goes through the same background runs, the same atlas and the same single
draw call as every other row. An overlay would have been a second text
renderer, and a second text renderer is a second thing that can disagree with
the first about what a cell looks like.

**Three values in that row are pinned, and it should be said out loud.** The
clock is the real time of day and the bar and the "behind live" figure are
fractions of a session whose length is dominated by shell startup jitter —
measured at 5–90 ms, which is wider than a bar cell. None of the three can be
reproduced, and a capture that differs on every run is how a gallery stops
being read. `--seek-status <wall_s>,<behind_s>,<pct>` pins exactly those three
and nothing else; the row's text, its reverse video, its place in the grid and
the restored frame above it are all real. Three consecutive `zig build
gallery` runs report it identical.

## Test the tests

Eighteen mutants, applied to the merged implementation and run against the
whole suite. **Two survived the first pass.**

| # | mutant | first pass |
|---|---|---|
| 1 | `next_line_id` omitted from the checkpoint | died — the arbiter's explicit id assertion |
| 2 | `used_cols` trimmed via `Cell.isBlank()` instead of exact `Cell.blank` | died — a coloured trailing space |
| 3 | screen encoded in memory order (`cells[y*cols..]`) instead of `row(y)` | died — a rotated fixture |
| 4 | `RowMeta.id` dropped | died — the id assertion |
| 5 | the inactive screen not encoded | died — a checkpoint taken while `on_alt` |
| 6 | scrollback restored newest-first | died |
| 7 | a partially filled ring restored with `head == 0` | died |
| 8 | `pending_wrap` dropped from the decode | **survived** — see below |
| 9 | tabstops dropped | died |
| 10 | `saved_cursor` dropped | died |
| 11 | `RowMeta.flags.wrapped` dropped | died |
| 12 | `Screen.offset` preserved rather than canonicalised to 0 | died — `offset == 0` asserted after decode |
| 13 | the varint decoder accepts a truncated stream | died — every prefix of a valid checkpoint |
| 14 | `scrollback_unchanged` set after a push | died |
| 15 | decimation drops the target checkpoint | died — `nearest()` returns the greatest `pos <= target` |
| 16 | decimation drops the **forced** alt-exit entry | **survived** — see below |
| 17 | the forced alt-exit checkpoint never taken | died — the e2e span test |
| 18 | `title` not restored | died — the arbiter's title assertion |

*This table was reconstructed after the implementing agent was interrupted
mid-record, from its own summary — eighteen planted, two survived — and from
the tests it added. The two survivors' killers were re-verified by hand
before merge; the sixteen first-pass deaths are the agent's report.*

### The two survivors, and what killed them

**`pending_wrap` dropped from the decode.** `check.zig` hashes it and has a
test that it moves the checksum on its own — and every case in the shared
`field_cases` table left the cursor somewhere other than past the last column.
The "wrapped row" case prints 36 characters into a 20-column terminal, which
wraps and lands at column 17 with the flag *clear*. Killed by a new case that
prints exactly twenty: `a deferred wrap at the right margin`. Because the
table is shared, adding it there exercises it in both files at once, which is
the whole reason it is shared.

**Decimation dropping the forced entry.** This one is instructive, because the
arbiter *cannot* catch it: an index that has thrown away the alt-exit
checkpoint still seeks correctly, it just replays further to get there. Every
checksum stays equal. What it destroys is the sprint's entire demo — `Cmd ⇧ ↑`
becomes a replay of everything since the last surviving checkpoint. Killed by
a test that asserts *which* entry serves the target (`entry.forced`), that
reaching it costs zero events (`entry.event_index == exit_event`), and that
decimation actually ran (`idx.decimations > 0`) — over five different session
shapes, because whether a dropped entry happens to land on an even index and
survive by luck depends on where in the sequence it fell.

"The checksum covers it" was not an argument for either of them, and it is the
second time on this roadmap that a mutant has survived precisely because the
checksum did its job. L0's record makes the same point about `control`
records.

## The retirement gate

L1 is the sprint the record roadmap is allowed to die on, so the gate is
written down as five criteria rather than left as a feeling.

| # | criterion | how it is decided | result |
|---|---|---|---|
| 1 | **Latency.** A seek is a key press, not a job. | `--seek-sweep` over a 98 MiB session at 200×60: p95 ≤ 150 ms, materialize ≤ 50 ms. | **met** — 19.2 ms p95, 21.4 ms worst |
| 2 | **Fidelity.** The frame you seek to is the frame that was drawn. | The arbiter: for every checkpoint and six targets after it, restore + replay-forward equals replay-from-start — checksum, `next_line_id`, title and every row id, over a fixture and eight corpora. | **met** |
| 3 | **Reach.** The demo is three keystrokes or fewer. | `Cmd ⇧ ↑` is one chord, from anywhere, with no mode to enter first. | **met** |
| 4 | **Cost.** Nothing L1 added moves what L0 and sprint 1 protect. | The interleaved gate, with a thread spinning that is strictly worse than the seek worker. | **met for the lock**, which is the claim: 10–14 µs against 9–24 µs across the other arms. The 5% throughput line is L0's cost re-measured at −5.0%, and a busy thread costs a further −9.4% while it runs. |
| 5 | **Use.** The maintainer reaches for it on a real session within seven days. | **Not measurable here.** Nothing in this repository can tell whether a feature got used. | **the maintainer's to report** |

Criteria 1–4 are engineering claims and are settled above. Criterion 5 is the
one the sprint exists for: an index that is fast, faithful, one key away and
free is still worth nothing if nobody scrolls back into a closed program. It
is stated here so that it is a criterion rather than an afterthought, and it
is deliberately **not** claimed by this document.

## What the sprint text got wrong

**The `Frame` is not a checkpoint, and could not be one.** The record page's
"why this codebase" table says *"the frame is already a view —
`Renderer.snapshot` copies the grid into a `Frame` and draws from the copy. A
checkpoint is that copy — ~48 KB at 100×30."* It is not. `Frame` holds the
visible viewport and a cursor: no scrollback, no parked alternate screen, no
modes, no tab stops, no saved cursor, no scroll region, no line ids, no title.
Worse, its cells come from `viewRow`, so a `Frame` taken while the user is
scrolled back is not even a copy of the live screen. Restoring a terminal from
one is not a matter of adding "the terminal's mode state" to it — it is a
different object, and `ckpt.zig` writes that object instead.

**The 4 MiB / 40 ms arithmetic is at the edge at 200×60, not inside it.** See
"what was measured first". The estimate was off by exactly the factor between
80×24 and 200×60, which is the factor nobody had measured. 1 MiB ships.

**"Or every minute" is the wrong second trigger.** A minute of an idle session
is zero bytes of output, so a time-based trigger mints identical checkpoints
of an unchanged terminal — cost with no benefit — and it does not bound the
thing that makes a seek expensive, which is bytes to replay, not time to wait.
The byte interval is the whole of it, and the one other trigger that ships is
the read that leaves the alternate screen, because that frame is the point.

**"Appended to a side index" contradicts `rec.zig` and S6.** Record type 9 is
reserved in the format for checkpoints and type 8 for marks, and L0's privacy
record makes a promise that depends on neither being written: *"L0 builds no
index. The file is the only artifact, so `rm` is the delete. That is a
property to protect in L1."* L1 protects it. Nothing here writes a byte to
disk, both types stay reserved and unwritten, and the index is a cache. Caches
are not records.

**Charset is a phantom.** The risk list names "scroll region, saved cursor,
tab stops, charset". The first three are real and are in the checkpoint. The
fourth does not exist: `terminal.zig`'s `escDispatch` returns early on any
intermediate byte, so `ESC ( B` changes nothing there is to save. A checkpoint
field for it would have been a field that is always the same value. Written
down so the next reader of that risk list does not go looking either.

**"Scrollback stops being a data structure and becomes a query" did not
happen, and should not have been on this sprint.** Making every viewport row a
replay is the opposite of a 50 ms materialize budget, and neither
[E7](../essentials.md)'s scroll position nor [E4](../essentials.md)'s reflow
is unblocked by anything L1 shipped. The scrollback is still `grid.Scrollback`
and a checkpoint serialises it. If that inversion is worth doing it is its own
sprint with its own gate.

**The unmentioned problem, and the one that decided the design: redaction.**
The sprint text says to checkpoint the terminal. The terminal cannot be
checkpointed. `redact.scrub` runs over a *copy* of every read on its way into
the recording and never over the bytes that reach the screen — that is L0's
rule, and it is the right one — so the live `Terminal` holds the unredacted
form of every secret the `.trec` had taken out. Serialising it would put those
secrets back: into memory S6 exists to keep them out of, and (in L4, when a
session becomes a file) into something a user sends to a colleague.

Scrubbing the checkpoint instead is worse, not better: the scrubbed checkpoint
would no longer equal the live terminal, so the arbiter would go red on
exactly the sessions that contain a secret. The checkpoint would be wrong in a
way no test could accept and no user could act on.

So a checkpoint is **derived from the log**. Everything else about the
sprint's shape follows from that one forced move — the worker thread, the
second `Terminal` a seek materializes into, "seek to now is the live screen"
as an identity that has to be *proved* rather than assumed, and the
`flushForSeek` that makes it true. None of it is in the sprint text, because
the sprint text did not have the problem that forces it.

## Declined: L0's sequence number

L0's record leaves this on the table:

> A resize or a `Cmd K` during heavy output has a narrow ordering window. […]
> The window is nanoseconds wide and the failure mode is a replay whose
> checksum differs, not lost data. **A sequence number per mutation is the
> fix, and it belongs with L1's checkpoints.**

It does not belong here, and taking it would have been the wrong sprint.

That window is a divergence between **the log and the live terminal**: the
reader records a read, releases the recorder mutex, and only then takes the
terminal mutex, so a main-thread `resize` that wins the terminal mutex in that
gap is *applied* before the read and *recorded* after it. Detecting it needs
an ordering written into the file and checked against the running terminal —
which is L0's arbiter's job, and which needs a new record field, and L1's
first rule is that it writes no new bytes.

L1's arbiter compares **two readings of the same log**: a checkpoint restored
and replayed forward, against a replay from the start. Both readings see the
same file in the same order, so they agree whether or not that order matches
what the terminal did. L1's arbiter is *blind to that bug by construction* —
which is precisely why it would be a bad place to put the fix: the test that
would justify the sequence number cannot be written here.

It belongs with the next sprint that changes the recorder, where a format
version, a new field and L0's live-versus-replay checksum are all in scope
together.

## Known limits, stated rather than hidden

- **The forced alt-exit checkpoint is a pty read late when a program's final
  repaint and its `?1049l` arrive together.** The boundary the index can
  checkpoint at is a whole read, and the parser is not at ground mid-sequence
  anyway. The frame you get is then the one before the last one. It cost this
  sprint an intermittently failing test and a `sleep 0.2` in a gallery scene
  before it was understood. Fixing it means checkpointing at a byte offset
  inside a read, which means carrying parser state in a checkpoint, which is a
  different format.
- **The whole `.trec` is held in memory once you seek, and stays there.**
  Event payloads point into the file buffers, and forward replay from a
  checkpoint needs them, so `State.buffers` keeps every one for the window's
  life. A 98 MiB session costs 98 MiB of RSS after the first `Cmd ⇧ ↑`;
  `rec.readFile` refuses anything over 1 GiB, which is the only bound. Reading
  ranges back from the file on demand is the fix and it is a sprint.
- **A refresh re-replays the whole session.** The index cannot be extended in
  place, because a decimation may have thrown away the entry a refresh would
  want to continue from. Seeking again after ten more minutes of output costs
  another full build — 946 ms for 98 MiB, on the worker.
- **A second CPU-bound thread costs about 9% of pty throughput** while it
  runs. The seek worker is that thread for a few hundred milliseconds after a
  key press. Measured, not fixed.
- **`--frame-stats` reports the seek, and there is no other instrumentation.**
  `--seek-sweep` and `--busy-threads` are measurement instruments, hidden from
  `--help` on purpose; `--seek-status` is a capture instrument in the same
  spirit as `--select`.
- **The scrubber is keys, not a timeline in the padding.** `Cmd ⇧ ←/→` steps a
  second (ten with Option), `Cmd ⇧ ↑/↓` walks full-screen spans, `Esc` or any
  printable key returns to live. The drawn timeline the sprint text asks for
  is not here; the status row's bar is the twelve-character version of it.
- **Seeking does not scroll.** The wheel is inert while the window shows
  history: scrolling the live terminal's viewport under a historical frame
  would move something the user cannot see. Scrolling a seeked view's own
  history is [E7](../essentials.md)'s job.
- **`flushForSeek` can cost a 64 KiB `write(2)`** — 2,616–6,190 µs on this
  machine-day — on the main thread, once per entry into seek mode, outside the
  terminal mutex. Without it the log stops short of the present and "seek to
  now == live" is false.
- **The gate cannot run in CI.** `--frame-stats` needs a window.
