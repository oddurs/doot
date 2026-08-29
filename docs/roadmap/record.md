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
  input, and visible on hover otherwise.
- **Files are 0600** under `~/Library/Application Support/terminator/
  sessions/`, one per session, rotated and compressed on close,
  retained per a config key with a default measured in days, not
  forever.
- **Nothing leaves the machine.** Sharing is the user sending a file
  (L4), after redaction, on purpose.
- **Deletion is real.** Delete a session and the file is gone; there is
  no index that remembers it.

[S6](security.md) holds these as policy with tests.

## The sprints

### L0 — Record every session (two weeks) — the proof

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

### L1 — Checkpoints and seek (two weeks)

Every 4 MiB of output, or every minute, a checkpoint: the `Frame` copy
plus the terminal's mode state, appended to a side index. Materializing
time *T* is loading the nearest earlier checkpoint and replaying
forward. A scrubber — `Cmd ⇧ ←/→` and a timeline drawn in the padding
— moves the view through the session's history, including every frame
of every alt-screen program it ran.

Scrollback stops being a data structure and becomes a query: the rows
that scrolled off the primary screen, in order. [E7](essentials.md)'s
scroll position and [E4](essentials.md)'s reflow become properties of
a view, which is simpler than what they were.

*Done when:* seeking to any second of an hour-long recorded session
materializes in under 50 ms at 200×60; the "scroll back into a closed
vim" demo works; the golden checksum test passes at every checkpoint
boundary.

*Risk:* medium. Mode state that is not in the `Frame` — scroll region,
saved cursor, tab stops, charset — must be in the checkpoint or replay
diverges. The differential model ([T0](testing.md)) is the check.

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
- **`terminator log`** — the same spans as a query:
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
findings replaced, input stripped unless asked. `terminator open file`
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
- **A query language of its own.** `terminator log` takes flags and
  emits JSON; `jq` is the language.
- **Recording input by default.** Ever.
