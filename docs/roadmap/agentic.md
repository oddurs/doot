# Agentic roadmap

A terminal for working with agents. The person at the keyboard is running
Claude Code, Codex, aider or the next one — usually several at once, each
for minutes to hours, each occasionally needing a human. Sized for one
person at 8–12 focused hours a week. Sprint prefix: **A**.

Arbiter: **recorded agent sessions and the protocol audit table** that A0
builds. A claim about what agents need carries a sequence from a recording
or it is labelled a guess.

## What is different about an agent session

Four things, and each one is a product decision this terminal can make
that a shell-era terminal did not have to.

1. **It runs for a long time and then needs you.** The terminal's most
   valuable moment is telling you *which* of five tabs wants an answer, and
   doing it while you are in another app. Attention routing is the product.
2. **It emits a great deal of structured-ish output** — tool calls, diffs,
   file paths, URLs, exit codes — that you navigate rather than read
   linearly. Command boundaries, clickable paths and "jump to the last
   prompt" matter more than raw scrollback.
3. **It is a modern TUI.** Ink, Ratatui, Bubble Tea and prompt_toolkit
   reach for protocol features the VT220 never had: synchronized output,
   the kitty keyboard protocol, focus events, colour queries, cursor shape,
   OSC 8 links, OSC 52 clipboard. Miss one and the symptom is flicker, a
   key that does nothing, or a light theme drawn on a dark background.
4. **There are several of them.** One window, one PTY is the wrong shape.

## What the recordings measured

A0 is done: `bench/corpus/agent-*.bin` are real recordings, `zig build
audit` classifies every sequence in them, and this section is its output
rather than a reading of the source. The table below it survives as the
feature list; this is the measured part.

**Two sequences are executed as something else.** Not missing — *wrong*.
Both come from the same cause: `csiDispatch` switches on the final byte
without looking at the private marker, so a keyboard-protocol request
reaches the arm for an unrelated sequence.

| Sequence | Emitted | What it means | What doot does |
|---|---|---|---|
| `CSI > 4 m` | 4× per session | xterm modifyOtherKeys | **runs SGR 4 — turns underline on** |
| `CSI < u` | 4× per session | kitty keyboard pop | **runs restore-cursor — the cursor teleports** |
| `CSI > 0 q` | 1× per session | XTVERSION query | ignored, no reply; the agent waits out its timeout |

Every agent CLI that speaks the kitty keyboard protocol turns on underline
in this terminal on startup, and moves the cursor on exit. Tracked as
[#28](https://github.com/oddurs/doot/issues/28); fixing it belongs to
[A2](#a2--the-modern-tui-protocol-two-weeks), which is where the private
forms get implemented properly rather than merely stopped from firing.

Everything else the recordings contain — `CUP`, `EL`, `SGR`, `ED`, `CHA`,
`DECSTBM`, `DEC` set/reset mode, `DA`, OSC 0 — is handled. There were no
unlisted sequences, which is the other thing the audit is for: a new agent
version emitting something new shows up as a question rather than as
silence.

The same blindness has a second family. `csiDispatch` reads the
*intermediates* no more than it reads the private marker, so `CSI SP @`
(SL, scroll left) runs ICH and `CSI SP A` (SR, scroll right) runs CUU.
Neither appears in today's recordings, so both are listed rather than
counted — but they are the same bug as `CSI > 4 m` and #28 covers them.

## The shape of agent output

From the committed `.timing` sidecars, which record one line per read —
a read boundary being what the terminal is actually handed at once.

| | bytes | writes | over | per write | writes/s | busiest 100 ms |
|---|---|---|---|---|---|---|
| an agent working | 8,492 | 97 | 41.3 s | 87 B | 2.3 | 2,075 B |
| an agent dumping a diff | 266,688 | 1,687 | ~0 s | 158 B | 84,621 | all of it |

Two things follow, and neither was obvious from reading the source.

**The terminal never receives more than 1,024 bytes per read.** Not 87, not
158 — the *maximum* read in either recording is exactly 1,024, whatever the
program wrote, because that is the kernel's pty output queue. The 64 KiB
read buffer in `main.zig` can never fill. Whatever the parser is optimised
for, it is optimised for kilobyte-sized handoffs.

**An agent thinking is not a performance problem; an agent dumping is.**
2.3 writes a second at 87 bytes is nothing — the interesting load is the
diff, four orders of magnitude denser. The two cases want opposite things
(latency versus throughput), and the corpora now name both.

## Where we are

Read from the source, and marked as such — the section above is the
measured version.

| Capability | Status | Where |
|---|---|---|
| BEL | Sets `Terminal.bell`. **Nothing reads it.** | `terminal.zig` `execute`; no reader anywhere in `src/` |
| Mouse reporting (1000/1002/1003/1006) | Mode tracked as one bool; events never forwarded | `Modes.mouse`; `main.zig` `handleWheel` only |
| Synchronized output (DEC 2026) | Not handled. A frame can be snapshotted between a TUI's erase and its redraw | `Renderer.snapshot` runs whenever `dirty` |
| Focus events (1004) | Not handled; `renderer.focused` is tracked for the cursor only | `main.zig` |
| kitty keyboard protocol (`CSI > u`, `CSI = u`, `CSI ? u`) | Ignored, correctly, since [S0](security.md) — before it, `'u'` restored the cursor regardless of the private marker ([#28](https://github.com/oddurs/doot/issues/28)) | `csiDispatch`, the private-marker guard |
| DECSCUSR (cursor shape) | Ignored, by design, with a comment saying so | `csiDispatch` intermediates note |
| OSC 0 / 2 (title) | Handled | `oscDispatch` |
| OSC 7 (cwd), 8 (links), 9 / 99 / 777 (notify), 10 / 11 / 12 (colour query), 52 (clipboard), 133 (semantic prompts) | Parsed to a string, then dropped | `oscDispatch` `else => {}` |
| DA1 | Answers as a VT220 | `deviceAttributes` |
| DA2, XTVERSION, DECRQM | Not answered; a TUI probing for capabilities times out | — |
| Bracketed paste | Handled | `Modes.bracketed_paste`, `Cmd V` |
| Tabs, multiple PTYs | One `App`, one `Terminal`, one `Pty` | `main.zig` |
| Shift+Enter / Option+Enter | Indistinguishable from Enter | `input.zig` `.enter` |

Nothing here is a criticism of a from-scratch terminal that is a few months
old. It is the list.

## The sprints

### A0 — Agent corpus and protocol audit (one week) — **done**

Record real sessions: an agent given a task in this repository, captured
byte-for-byte with `script(1)` on the PTY, one file per agent CLI, plus a
scripted "worst case" — an agent streaming a long diff while a build runs
in a second pane. Commit them under `bench/corpus/agent-*.bin` with the
same seeding and byte-identity rules as the existing six.

From the recordings, produce two things and put them in this file:

- **The audit table** — every distinct CSI, OSC, DCS and mode each agent
  emits or queries, with a column for what doot does today:
  handled, ignored, mis-handled. This replaces the "where we are" table
  above with a measured one.
- **The shape of agent output** — bytes per write, writes per second,
  cursor-up-and-redraw cycles per second, longest burst. This is what the
  render path is being asked to do, and it is not what `bench/dump.sh`
  does. It is also [L0](record.md)'s storage estimate: bytes per busy
  hour is the number the retention default is set from.
- **Whether agents emit images.** Kitty graphics, sixel, iTerm2 inline
  images — a browsing agent pasting a screenshot is the case. Today all
  three are parsed and discarded; the recordings decide whether that
  moves onto [experience.md](experience.md).

*Why here:* every sprint below claims agents need something. This is where
the claim gets a source. It is also the cheapest sprint on any roadmap and
the only one that can retire another.

*Done when:* the corpora are committed, `zig build bench` reports them
alongside the six, and the audit table exists with a status for every row.

*Risk:* low. The risk is in what it finds — expect at least one row of
"mis-handled" that is not in the table above.

*Result:* done, and the risk paid out — two mis-handled rows, both from
the same cause, both firing on every agent session. See
[the record](completed/sprint-a0-agent-corpus.md). The recordings needed a
recorder (`zig build record`) rather than `script(1)`: capturing a TUI
means being able to *type* at it, and `claude -p` emits one escape byte per
kilobyte because it is not drawing anything.

### A1 — Attention (one week)

Make the bell mean something. When the window is unfocused and a child
rings BEL, or sends an OSC 9 / 99 / 777 notification with a message:

- post a macOS notification (a thin Cocoa shim; SDL3 has no notification
  API), carrying the message if there was one and the tab title if not,
  and focus the window when clicked;
- badge the tab (once A5 exists) and bounce the dock icon once
  (`requestUserAttention`);
- when focused, a brief visual bell — a one-frame flash of the frame's
  edge, not the whole grid.

Agent CLIs that notify by BEL (Claude Code's `terminal_bell` channel is one)
get this for free; the OSC forms cover the rest.

*Why here:* the field already exists, the focus state already exists, and
this is the first moment the terminal does something for an agent's user
that Terminal.app does not.

*Done when:* an e2e test drives BEL through the PTY and asserts the
notification hook was called with the right title; a manual check on an
unfocused window produces a notification whose click focuses it. Idle CPU
is unchanged — the check happens in the existing event loop, not on a
timer.

*Risk:* low. The notification call is the first function in
`src/platform/shell.m` — glue only, behind a C ABI, per the convention
[D0](dependencies.md) establishes — and it is the proof
[D4](dependencies.md) wants that the pattern works before the window
moves behind it.

### A2 — The modern-TUI protocol (two weeks)

Everything a current TUI framework probes for, in one sprint, because each
item is small and the audit will show they travel together.

**Output side**

- **DEC 2026 synchronized output.** While set, `snapshot` is skipped; on
  reset, or after a 100 ms safety timeout, the next frame is taken. The
  architecture makes this nearly free — the frame is already a copy taken
  at a moment of our choosing. Measure it: count frames presented between a
  TUI's erase and redraw, before and after, from the A0 recordings.
- **DECSCUSR** — block, underline, bar, each steady or blinking. The
  renderer half is in [X3](experience.md); this sprint parses and stores
  the shape.
- **OSC 10 / 11 / 12 queries** — foreground, background and cursor colour,
  answered in the `rgb:rrrr/gggg/bbbb` form. This is how a TUI decides
  whether it is on a dark or a light theme. Sets are accepted too, and
  reset by [X4](experience.md)'s theme machinery.
- **DA2, XTVERSION, DECRQM** — identity and mode queries. DECRQM is what
  lets an app ask "do you support 2026?" instead of guessing.
- **Focus events (1004)** — `CSI I` / `CSI O` on focus change, from the
  events `main.zig` already receives.

**Input side**

- **Fix `CSI u`.** A private marker means it is not SCORC.
- **kitty keyboard protocol, level 1** — the disambiguate-escape-codes
  flag, pushed and popped with the alt screen. This is what makes
  Shift+Enter and Option+Enter distinct from Enter, which is what the
  newer CLIs reach for when they need a multi-line input box. Higher
  levels (event types, alternate keys) wait for evidence from A0.
- **OSC 52** — clipboard write from the child, gated by a config setting
  that defaults to on for write and off for read. Agents inside `ssh` and
  `tmux` copy through this.

*Why here:* after A0 has said which of these the agents actually use, and
before A3, whose value depends on the TUIs being drawn correctly.

*Done when:* every row of the audit table that this sprint covers reads
"handled", and a unit test exists per sequence citing `ctlseqs` or the
kitty specification. The 2026 measurement shows zero mid-redraw frames on
the recordings.

*Risk:* medium. Keyboard protocol levels interact with `input.zig`'s
legacy encoding and with the alt-screen stack; the `esctest` harness from
[C0](correctness.md) is the safety net, and this sprint is a reason to
build it first.

### A3 — Semantic prompts (two weeks)

OSC 133 A / B / C / D — prompt start, command start, output start, command
end with exit status — plus OSC 7 for the working directory. Ship the
shell-integration snippets for zsh, bash and fish under
`shell-integration/`, sourced automatically when the shell is ours to
start and offered as a one-liner otherwise.

The marks live in a per-row side array that **rotates with the screen ring
and pushes with scrollback** — the shared primitive from
[priorities.md](priorities.md), and the trap named there.

What the marks buy, in order of how much they matter to an agent's user:

- **Running state.** Between C and D the tab is "busy"; at A it is "at a
  prompt". An agent that stops at a prompt while the window is unfocused
  is an agent that needs you, whether or not it rang the bell. This is
  the signal A1's notification and A5's rail are really built on.
- **Jump between commands** — `Cmd ↑` / `Cmd ↓` scroll the viewport to the
  previous or next prompt mark. Long agent output becomes navigable.
- **Exit status in the gutter** — a two-pixel bar in the padding, red on
  non-zero. The padding exists; it is unused.
- **Select a command's output** — triple-click in the gutter selects from
  C to D. Needs [E1](essentials.md).
- **Working directory** — the title falls back to the cwd's last component
  when the child sets none, and a new tab (A5) opens where the current one
  is.

*Why here:* the keystone. A1 without A3 knows only about bells; A5 without
A3 is a tab strip. With it, the terminal knows what each tab is doing.

*Done when:* an e2e test runs a real shell with the integration sourced,
executes a failing command, and asserts the row marks and the exit status;
`Cmd ↑` on a 10,000-line scrollback lands on the right row in one frame.

*Risk:* medium. The ring. Every path that moves rows — `scrollUp`,
`scrollDown`, `insertLines`, `deleteLines`, resize, alt-screen switch —
must move marks with them, and each needs a test that fails when it does
not. Sprint R's mutation-testing approach applies.

### A4 — Links and paths (one to two weeks)

- **OSC 8 hyperlinks** — an id and a URI per cell, stored out of line in an
  interned table with an index in the cell's spare bits; underlined on
  hover; opened on `Cmd`-click.
- **Path and URL detection** — a scan of the hovered row (and its wrapped
  neighbours, via the `wrapped` flag from [E1](essentials.md)) for
  `path:line[:col]` and URL shapes. Agents print `src/render.zig:283`
  constantly; `Cmd`-click opens it in `$EDITOR` or the configured
  handler, with `code -g` and the like as presets.

*Why here:* needs mouse plumbing from [E2](essentials.md) and the wrapped
flag from E1. Small once both exist.

*Done when:* a unit test extracts the right span and line number from a
row containing a path with a trailing colon, a wrapped path, and a URL
with a query string; the hover underline costs no frame when the mouse is
still.

*Risk:* low. The interned URI table needs an eviction story or an
agent printing a thousand links grows it without bound — the same
concern that shaped [sprint 5](completed/sprint-5-cell-size.md)'s verdict.

### A5 — Tabs and the attention rail (three weeks)

More than one PTY in a window. `App` becomes a list of sessions, each with
its own `Terminal`, `Parser`, `Pty`, reader thread and mutex; the main
thread snapshots the visible one. The tab strip is drawn into the same
vertex buffer as the grid — quads and glyphs from the same atlas, no new
draw calls, so [sprint 2](completed/sprint-2-one-draw-call.md)'s invariant
holds.

The strip is not decoration. Each tab shows the state A3 derives — running,
at a prompt, exited with status — and the A1 badge. `Cmd ⇧ A` jumps to the
next tab that needs attention; the window title carries a count when any
do. This is the multi-agent supervision view, and it is the reason the
tabs exist.

Keys: `Cmd T` new tab in the current cwd (A3's OSC 7), `Cmd W` close,
`Cmd 1–9` and `Cmd ⇧ [ ]` to switch, drag to reorder.

*Why here:* after A1 and A3 give a tab something to say, and after
[X5](experience.md) has decided whether the strip lives in the titlebar.
The first version draws it in the grid area; the titlebar version is X5's.

*Done when:* five tabs each running `bench/dump.sh` keep every reader
thread's lock hold in single-digit microseconds — the per-tab mutex is
the point — and `--frame-stats` shows the frame cost is that of one grid,
not five. A background tab that rings BEL badges without stealing focus.

*Risk:* medium to high. Every `app.term` in `main.zig` becomes
`app.current().term`, and the resize, title and reply paths each assume
one of everything. Splits are deliberately not here: tabs first, and only
once the attention rail has proved the model.

### A6 — Remote control (two weeks) — **gated**

A Unix socket in `$TMPDIR`, mode 0600, and a `doot` CLI that speaks
to it: `open [--cwd DIR] [-- cmd]`, `send TAB TEXT`, `screen TAB`,
`wait TAB` (returns when the tab reaches a prompt mark), `list`, and —
because the tab is a log ([record.md](record.md)) — `follow TAB`, which
streams the record from a point in time, and `log TAB` with L3's query
flags. The shape kitty's remote control and iTerm2's API settled on,
reduced to what an agent driving a terminal actually does: start a
subtask in a fresh tab, read what it printed, wait for it to finish.
`--headless` runs the same server with no window, so a TUI can be
tested by a script.

The design principle is *programs as peers*: a human's window and an
agent's socket are two readers of the same record and two writers to
the same input path, under the same policy ([S4](security.md)). The
terminal coordinates agents without being one.

*Gate:* start this only when there is a concrete script that wants it —
the maintainer's or a user's. It is cheap to defer and, once shipped, an
API to maintain.

*Why here:* it needs A3 (`wait` is meaningless without prompt marks) and A5
(tabs to open). Security is the whole design — the socket is opt-in, per
user, and the token is passed to children in the environment so only
programs the terminal started can reach it — and it is written down as
[S4](security.md), which lands with this sprint.

*Done when:* an e2e test opens a tab over the socket, runs a command, waits
for the prompt and reads the screen back; a stranger's process on the same
machine cannot connect.

*Risk:* medium. The API surface is the risk, not the code.

### A7 — The supervisor view and the approval inbox (three weeks)

Attention is the scarce resource. In the teletype era the machine
waited for the human; now the human is the bottleneck and several
machines wait. A5's tab strip shows state; A7 is the view built for
that state.

- **Cards, not tabs.** Every session as a card: running / at a prompt /
  exited with status, *since when*, the last few lines it printed, and
  — from [L3](record.md) — what files its last command touched. Sorted
  by need: a prompt waited on longest first.
- **The question, in the notification.** When an agent stops at a
  prompt, [A1](agentic.md)'s notification carries the screen region
  after the prompt mark — the actual question — and a `y`/`n`/reply
  field. The answer goes down the PTY without switching context.
- **Ranking.** Interruptions ranked by what is needed × how long it has
  waited × whether the window is focused. A bell from a focused tab is
  a flash; a prompt in an unfocused tab after two minutes is a
  notification; the same after ten minutes bounces the dock.
- **Broadcast.** Type into *N* selected sessions at once, with the
  paste guard ([S1](security.md)) applied to each.

*Why here:* after A3 gives a session a state and L3 gives it a history.
A card with neither is a tab.

*Done when:* five recorded agent sessions replayed at once produce the
right card order at every second, asserted from the recordings; a `y`
typed into a notification reaches the right PTY and no other.

*Risk:* medium. The ranking is a taste call with a measurement behind
it — the recordings say how long real prompts wait — and it must never
be so clever that a user cannot predict it.

### A8 — Host awareness (one week)

Agents run on other machines. OSC 7 carries the hostname; use it.

- Tabs tinted by host, from a hash of the name, stable across sessions.
- `Cmd T` opens the new tab **on the same host**, in the same directory,
  over the same `ssh` — by re-running the session's original command
  with the cwd from the mark.
- A clicked path on a remote host ([A4](agentic.md)) opens in the local
  editor over `ssh`, via the editor's remote support or an `scp` to a
  temp file, per config.
- The record ([L3](record.md)) attributes every command to its host, so
  `doot log --host build-box` is a real query.

*Done when:* an e2e test through a local `sshd` records the host on
each mark, and a new tab from a remote session lands on the remote
prompt.

*Risk:* low. The `ssh` re-run needs the original command; a session
started from a tab, not from the CLI, has it.

## Why this order

- **A0 first.** Every other sprint on this page is a guess about agents
  until it has a recording behind it.
- **A2 before A3.** A TUI that flickers or mis-keys is the first thing a
  user sees; prompt marks are the second.
- **A1 is early because it is small** and because it is the first visible
  agentic feature. It grows sharper when A3 lands and sharper again with
  A5, without being rewritten.
- **A5 late**, because its value is the state A1 and A3 give a tab to show.
  A tab strip with nothing on it is a tab strip.
- **A6 gated.** An API nobody has asked for is an API nobody has tested.
- **A7 after A3 and L3**, because its cards are made of their state.
- **A8 is a week** and can go anywhere after A3.

## Not on this plan

- **An assistant in the terminal.** See [priorities.md](priorities.md).
  doot hosts agents; it is not one.
- **Session persistence, as a multiplexer.** It is on the plan as
  [L5](record.md) — the log outliving the window — which is a
  consequence of the record, not a tmux. Gated on a month of using L0
  and L1.
- **Inline images** (sixel, kitty graphics). Parsed and discarded today;
  A0's audit says whether agents emit them. If they do, it belongs on
  [experience.md](experience.md).
- **Splits.** After tabs, and only if the attention rail proves that
  seeing two agents at once beats switching between them.
