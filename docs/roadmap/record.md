# The record

The terminal is not a screen. It is a log — an append-only, time-indexed
record of every byte in and out of every session — and the screen is a
view of it. Sized for one person at 8–12 focused hours a week. Sprint
prefix: **L**.

Arbiter: **materialization.** Any screen at any moment is reproduced
from the log, bit-identical to what was drawn, and the test that says so
is the golden checksum the bench already prints. If a view cannot be
derived from the record, it is not a view; it is a bug.

## The concept

Every terminal since the VT100 implements one idea: a grid that a byte
stream paints, watched by a human in real time. Scrollback bolted the
paper back on as memory; tabs, GPUs and semantic prompts all live inside
that idea. Its hidden assumption is that the human is present when the
pixels are painted — anything not on screen now is either gone (the alt
screen: every `vim`, every agent TUI, vanishes on exit) or flattened
into a log with no time in it.

Agents break the assumption. Several processes act on their own and the
person samples them hours apart, asking *what happened, what is it
doing, what does it need*. A screen shows the current frame and cannot
answer any of those.

So the inversion: **the primary object is the record, and the grid is a
materialized view.** The byte stream is appended, never applied and
discarded; a grid at time *T* is derived by replaying from the nearest
checkpoint. The emulator does not change — same parser, same semantics,
same programs, same escape sequences. What changes is what is kept and
what is derived.

What follows from that one decision, each a sprint below:

- replay and time travel are seeking in the log — the alt screen stops
  being a black hole;
- search is over the log, and a result is a moment, not a line;
- a structured transcript is annotation on the log: prompt marks are
  positions, commands are spans, exit codes and hosts are attributes;
- a session is a file, and a file plays back anywhere the core runs —
  including a browser;
- persistence stops being "a multiplexer": if the log is the object and
  the window is a view, the process that owns the PTYs and the log is
  the terminal, and windows attach to it;
- detectors improve retroactively — a better diff or secret detector
  next year re-annotates last year's sessions, because the original
  bytes were never thrown away.

The pragmatic strength over every other attempt to reinvent the
terminal: Warp needs its shell and Jupyter needs kernels, because each
makes *structure* the primary object. Here the primary object is bytes,
structure is layered on, and every existing program works on day one.

## Why this codebase

The pieces exist, planned as testing tools. Under this concept they are
the product.

| Precondition | Where it already is |
|---|---|
| The core is a pure function of the byte stream | `vt`, `grid`, `terminal` import only `std`; `bench/baseline.txt` ends with a checksum of the grid after every corpus — replay is bit-identical, and [T0](testing.md) asserts it |
| The frame is already a view | `Renderer.snapshot` copies the grid into a `Frame` and draws from the copy ([sprint 1](completed/sprint-1-vsync-lock.md)). A checkpoint is that copy — ~48 KB at 100×30 |
| Replay is fast enough to be invisible | The bench parses every corpus at over 100 MiB/s. With a checkpoint every 4 MiB, a seek replays at most 4 MiB: under 40 ms. An hour of heavy agent output replays end to end in about a second |
| The recording format | [A0](agentic.md)'s corpora: bytes plus timestamps |
| A headless reader | [C0](correctness.md) / [M1](compatibility.md) |
| A reader in the browser | [M4](compatibility.md): the core builds for `wasm32` today |
| Replay as a test | [T2](testing.md) |

## Privacy is the design

A terminal that records everything must be one the user can see into
and switch off, or the concept is not acceptable. These are not
settings to add later; they are the shape of L0.

- **Output is recorded by default. Input is not.** Keystrokes contain
  passwords; the stream the program printed does not, usually. Input
  recording is a per-tab opt-in with a visible indicator.
- **An incognito tab** records nothing and says so in its title.
- **The recording indicator** is always visible when a tab is recording
  input, and visible on hover otherwise. Until there is any chrome to hang
  it on, the window title is the surface: `<child title> — ● rec`, and
  `● rec+input` when keystrokes are being recorded. `Cmd ⇧ R` toggles that
  at runtime and the title moves with it, which is what makes the indicator
  mean something rather than decorate something.
- **Files are 0600** under `~/Library/Application Support/doot/
  sessions/`, one per session, retained per a config key with a default
  measured in days, not forever. (L0 does not compress: no compression, no
  `fsync` and no per-record CRC, because each of them is either a stall on
  the thread draining the pty or a cost with no reader yet.)
- **Nothing leaves the machine.** Sharing is the user sending a file
  (L4), after redaction, on purpose.
- **Deletion is real.** Delete a session and the file is gone; there is
  no index that remembers it.

[S6](security.md) holds these as policy with tests.

## The sprints

### L0 — Record every session (two weeks) — the proof

**Done.** See [the sprint record](completed/sprint-l0-record.md). The pty
drains at a median 66.09 MiB/s recorded against 67.66 unrecorded — **−2.3%**,
inside the 5% the gate allowed, over three interleaved runs each — and the
worst mutex hold does not move: 5 µs recorded against 7–40 µs unrecorded. It
moved *down* from where sprint 1 left it: reproducing that sprint's 324 µs, as
the gate required rather than trusting it, found `SDL_SetWindowTitle` inside
the terminal mutex, and taking that one call out leaves the worst hold in
single digits.

The most useful new figure is the worst single flush: **1,002–2,760 µs** for
64 KiB, on the reader thread. It is not on the terminal mutex — a reserved
tail of the write buffer means a `resize` or a `Cmd K` can never trigger one —
but it is four times what the first pass at this page claimed, and the number
here is measured rather than remembered.

The redactor now sits in the pty drain path, so it was measured first: 67
MiB/s, which would have halved the pty rate on its own. A comptime first-byte
table and a vectorised two-byte scan take it to 3,289–7,385 MiB/s.

Per session, an append-only file of events: `(t, output, bytes)`,
`(t, input, bytes)` when enabled, `(t, resize, cols, rows)`,
`(t, focus, bool)`, `(t, mark, kind, data)` for the OSC 133/7 marks
[A3](agentic.md) will produce. The append happens on the reader thread,
buffered, **outside the mutex** — the lesson of sprint 1, measured the
same way: the `lock` column does not move and the PTY drain rate stays
within 5% of unrecorded.

Ships with the privacy shape above in full: output-only default, the
input opt-in and indicator, the incognito tab, 0600, rotation, the
retention key.

*Why here:* gated on nothing, two weeks, and it is the proof of the
concept. If replaying a closed `vim` session (L1) does not feel as
different as this page claims, the page retires itself cheaply.

*Done when:* `--frame-stats` shows lock hold and PTY rate unchanged with
recording on; an e2e test records a session, replays the file through
`Terminal`, and gets the same grid checksum as the live run; an
incognito tab leaves no file.

*Risk:* low in code, entirely in the privacy defaults — which is why
they are specified here rather than left to the implementation.

*What it shipped:* `src/rec.zig` (the `.trec` format, writer and reader),
`src/check.zig` (the grid checksum this page calls the arbiter),
`src/replay.zig` and `zig build replay`, the `● rec` title indicator,
`Cmd ⇧ R`, and `--no-record` / `--incognito` / `--record-input` /
`--record-dir` / `--record-retain-days`. One thing the sprint text did not
have and needed: a `control` record, because `Cmd K` mutates the terminal
with no bytes through the parser and every session containing one would
otherwise fail its own checksum.

### L1 — Checkpoints and seek (two weeks)

**Done.** See [the sprint record](completed/sprint-l1-checkpoints.md).
Seeking to any moment of a 98 MiB session at 200×60 costs a **19.2 ms p95**
against the 150 ms the gate allows and the 50 ms this page asked for, over
200 seeks; the "scroll back into a closed vim" demo is `Cmd ⇧ ↑`, one chord,
and it is a decode of one checkpoint with **zero** events of forward replay.
The arbiter is a family of comparisons rather than one: for every checkpoint
in a fixture and in all eight bench corpora, and six targets after each,
restore-plus-replay-forward equals replay-from-the-start — checksum,
`next_line_id`, title and every row id.

Five things this section had wrong, each written up in the record:

- **A `Frame` is not a checkpoint and could not be one.** It is the visible
  viewport and a cursor: no history, no parked alternate screen, no modes, no
  tab stops, no line ids, no title — and its cells come from `viewRow`, so
  one taken while the user is scrolled back is not even the live screen.
- **4 MiB was the wrong interval.** The "under 40 ms" arithmetic came from a
  parse rate measured at 80×24. Measured at 200×60 — the geometry the budget
  is stated at — the worst corpus runs at **70.7 MiB/s**, so 4 MiB is 56.6 ms
  of replay against a 50 ms budget. It ships at **1 MiB**, which is 14.1 ms.
- **"Or every minute" is the wrong second trigger**: a minute of an idle
  session is zero bytes, and what makes a seek expensive is bytes to replay.
  The one other trigger that ships is the read that *leaves* the alternate
  screen, which is the frame the sprint exists for.
- **"A side index" would have broken the deletion promise** above.
  L1 writes **no bytes to disk**: record types 8 and 9 stay reserved and
  unwritten, the index is in memory, and `rm` is still the whole of deleting
  a session.
- **Charset is a phantom.** `terminal.zig` has no charset state — `escDispatch`
  returns early on any intermediate — so there was nothing to put in the
  checkpoint.

And one thing this page did not have at all, which decided the whole design:
**redaction**. `redact.scrub` runs over a copy on the way into the recording
and never over the bytes that reach the screen, so the live `Terminal` holds
the unredacted form of every secret the `.trec` had taken out. Checkpointing
it would put them back; scrubbing the checkpoint would make it unequal to the
terminal it claims to be. So a checkpoint is **derived from the log**, on a
worker thread, and everything else — the second `Terminal` a seek
materializes into, the flush on entering seek mode, "seek to now is the live
screen" as an identity that has to be proved — follows from that.

The measurement that mattered most: a full-history checkpoint at 200×60 with
the 10,000-line ring at capacity is **0.58 MB and 3.5 ms** to encode, against
a design rule that said 2 MB or 20 ms would force a two-tier fallback. It does
not fire. A checkpoint taken *while* a full-screen program is running is
**3,889 bytes**, because the history has not moved.

Scrollback did **not** stop being a data structure. Making every viewport row
a replay is the opposite of a 50 ms materialize budget, and neither
[E7](essentials.md)'s scroll position nor [E4](essentials.md)'s reflow is
unblocked by anything L1 shipped. If that inversion is worth doing it is its
own sprint with its own gate.

*What it shipped:* `src/ckpt.zig` (the checkpoint codec and the in-memory
index), `src/seek.zig` (the worker, the state and the status row),
`replay.materializeInto`, `rec.parseFrom` and `rec.flushForSeek`, the
`Cmd ⇧ ↑/↓/←/→` keys, `Esc` back to live, the seek status row as the bottom
grid row, and `--seek` / `--seek-span` so the gallery can photograph a frame
the live screen no longer has.

### L2 — Search over the record (one to two weeks)

[E3](essentials.md) searches the live view. L2 searches every session,
live or closed, and a result is a moment: the session, the time, the
screen as it was, one click away. Incremental, case-folded, across the
current tab by default and all sessions on request. The index is
rebuilt from the log — it is a cache, and can be deleted.

*Done when:* a string printed an hour ago in a closed tab is found and
its screen shown in under 200 ms.

*Risk:* low.

### L3 — Annotations and the transcript (two to three weeks)

Marks from [A3](agentic.md) become positions in the log; the span
between a command-start and command-end mark is a **command** with
attributes — cwd, host (OSC 7), exit status, duration, bytes of output.
Detectors run as annotation passes over spans: unified diffs, paths,
URLs, tables, secrets. Every annotation is derived and recomputable;
none is stored as truth.

Two consumers:

- **The transcript view** — a tab rendered as its commands: each folded
  to one line (`make · exit 2 · 4.2 s · 2,314 lines`) that expands to
  its output, with diffs rendered as diffs ([X9](experience.md)).
- **`doot log`** — the same spans as a query:
  `--failed --since 1h --host build-box`, output as text or JSON.

*Done when:* an agent session from the A0 corpus renders as a transcript
whose command count and exit codes match the recording; a query for
failed commands returns them in under 100 ms over a day of sessions.

*Risk:* medium. Programs that do not emit marks (most, today) produce
one span per session; the transcript degrades to the plain view, and
must do so gracefully.

### L4 — Sessions as files (one week)

Export a session — a time range, or a command span — as a single
self-contained file, with redaction applied: the secret detector's
findings replaced, input stripped unless asked. `doot open file`
plays it back; so does the browser player, which is [M4](compatibility.md)
promoted from a demo to a reader of the record. An agent's transcript
becomes something you can send to a colleague at full fidelity — every
style, every TUI frame — in a few hundred kilobytes, searchable.

*Done when:* an exported session plays back in the browser with the
same grid at every checkpoint as the app shows; the redaction test
suite strips every fixture secret.

*Risk:* low.

### L5 — The log outlives the window (three weeks) — **gated**

The process that owns the PTYs and the logs is the terminal; a window is
a client that attaches. Closing the window closes a view; the agent
keeps running; reopening shows it. [A6](agentic.md)'s socket and the
window use the same attach interface — a human's window and an agent's
socket are two readers of one log.

This is not a multiplexer. Nothing is tiled, nothing is a pane; the
claim is only that the record is the object and the window is
ephemeral, which is the claim this whole page makes.

*Gate:* L0 and L1 shipped and the maintainer wants it after a month of
using them. The daemon is a real cost — a second process, a lifecycle,
crash semantics for both halves — and it should be paid for by an
experienced want, not a predicted one.

*Done when:* close the window during a build, reopen, see the build
finish; the daemon's crash loses nothing already on disk; `--no-daemon`
runs the old single-process shape.

*Risk:* high. Two processes where there was one.

## Why this order

- **L0 first**, as the proof, before any view is built on it.
- **L1 immediately after**, because seek is what makes the concept
  visible.
- **L2 and L4 are small** once L1 exists.
- **L3 waits for A3's marks**, and the transcript is what A3 was for.
- **L5 gated** on a month of the maintainer's own use.

## Not on this plan

- **Recording to a cloud, a sync, an account.** Files on this disk.
- **Making programs emit structure.** OSC 133 is enough to start; a
  typed-output sequence is a later spec, designed once the transcript
  shows what it needs.
- **A query language of its own.** `doot log` takes flags and
  emits JSON; `jq` is the language.
- **Recording input by default.** Ever.
