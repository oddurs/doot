# Correctness roadmap

Conformance and trust. A terminal that is right is invisible; one that is
subtly wrong is a bug in every program you run. Sized for one person at
8–12 focused hours a week. Sprint prefix: **C**.

Arbiter: **esctest, vttest and the fuzzer**, run from C0 on. A sequence is
handled when a test citing `ctlseqs` or ECMA-48 says so, which is the rule
CONTRIBUTING.md already sets for patches.

## Where we are

The parser is Paul Williams' state machine and the terminal implements
the CSI set a shell, `vim`, `less`, `htop` and `tmux` exercise. 61 unit
tests across six modules and 8 end-to-end tests on a real PTY. Sprint R's
ring was mutation-tested and differentially fuzzed by hand. None of that
runs automatically against an external conformance suite.

| | Today | Where |
|---|---|---|
| Charset designation (`ESC ( 0`, DEC Special Graphics) | **Ignored.** ncurses draws box borders as `lqqqk` in `dialog`, `mc` and older TUIs on this `TERM` | `escDispatch`: `if (intermediates.len > 0) return` |
| IRM (insert mode, `CSI 4 h`) | Not implemented, noted | `setMode` |
| DECSTR (soft reset, `CSI ! p`) | Not implemented | intermediates dropped |
| DECALN (`ESC # 8`) | Not implemented; vttest's first screen | intermediates dropped |
| DECRQM, DA2, XTVERSION | Not answered | — |
| XTWINOPS 14 / 18 (pixel and cell size), 22 / 23 (title stack) | Not answered; `vim` pushes the title and cannot pop it | — |
| CPR under DECOM | Reports absolute coordinates; should be region-relative | `deviceStatusReport` |
| DA1 | Claims selective erase (`6`) without DECSCA / DECSED | `deviceAttributes` |
| REP (`CSI b`), SU/SD edge cases, ECH/ICH across a wide pair | Unverified | `insertCells`, `deleteCells` |
| Combining marks | **Dropped** — width 0 returns before the cell is written | `print`: `if (w == 0) return` |
| Width tables | Hand-written: 13 combining ranges, 16 wide ranges; no emoji presentation, no ZWJ, no Unicode version pinned | `charWidth`, `isWide`, `isCombining` |
| OSC size | 4 KiB; an OSC 52 clipboard payload past that is truncated silently | `vt.zig` `max_osc` |
| Replies | Written to the PTY **under the terminal mutex**; a child that stops reading stalls the main thread with the lock held | `main.zig` main loop, `writeAll` after `lock()` |
| Reply and title allocation failure | `catch {}` — a dropped CPR leaves a program waiting forever | `Terminal.reply`, `oscDispatch` |
| Font load failure | `try` at startup — exits with a Zig error trace, no message | `main.zig` `Renderer.init` |
| e2e on Linux | The e2e module links SDL3 although `tests.zig` imports only `vt`, `grid`, `terminal` and `pty` | `build.zig` `e2e_mod` |

## The sprints

### C0 — The conformance harness (one to two weeks)

- **`terminator --headless`** — or a separate small binary — that attaches
  the parser and terminal to a PTY with no window, answers queries, and
  can dump its grid. The e2e tests already do most of this in-process; this
  is the same thing as a program another program can drive. It is also the
  server half of [A6](agentic.md) if that gate ever opens.
- **esctest** (Dickey's `esctest2`) run against it in CI, with a
  checked-in list of known failures. Known failures are listed, never
  hidden; the list is the backlog for C1 and shrinks with each PR.
- **vttest** run by hand once per release, with the screens captured into
  the [gallery](experience.md).
- **A parser fuzzer** using `std.testing.fuzz`: random bytes through
  `Parser` into `Terminal` with the invariants *never panics, cursor is
  always in bounds, every `.wide` cell is followed by a `.spacer`, every
  `.spacer` follows a `.wide`, `pending_wrap` implies the cursor is on the
  last column*. One minute in CI, longer locally. The same harness takes
  a second target when [D1](dependencies.md) lands: a font file is
  untrusted input too.
- **Drop SDL from the e2e module** if the link is incidental, so the suite
  runs on the Linux runner too.

*Why here:* every sprint below is a list of sequences; this is what turns
the list into a pass/fail count.

*Done when:* CI shows an esctest pass count and a fuzz run on every PR;
the known-failure file exists and every entry names the sequence.

*Risk:* low. esctest wants a few responses (DA, CPR, DECRQM) to work at
all; those are the first entries on C1.

### C1 — The missing sequences (two weeks)

Batched from C0's failure list, each with a test citing the spec:

- **Charsets.** G0/G1 designation with `ESC ( 0`, `SI`/`SO`, and the DEC
  Special Graphics map. This is the one on the list a user hits without
  knowing why.
- **DECSTR, DECALN, IRM, REP.** Small, well specified, needed by vttest.
- **DECRQM, DA2, XTVERSION** — shared with [A2](agentic.md); land here if
  C0 comes first.
- **XTWINOPS 14, 16, 18, 22, 23.** Sizes and the title stack. The rest of
  XTWINOPS (move, resize, iconify) is refused, deliberately.
- **CPR under DECOM.** Region-relative, as the spec says.
- **DA1 honesty.** Either implement DECSCA/DECSED or stop advertising `6`.
- **Wide-pair integrity** in ICH, DCH, ECH and at the right margin: a
  split pair blanks both halves. Fuzzer invariant plus explicit tests.
- **DECSCUSR** — parsed here, rendered in [X3](experience.md).
- **OSC size.** Raise `max_osc` for OSC 52 or stream it; either way,
  overflow is reported, not silent.

*Done when:* the esctest known-failure file loses every entry this sprint
names, and `dialog --msgbox` draws a box.

*Risk:* low to medium. Charsets touch the print path, which
[Sprint 4](completed/sprint-4-print-run.md) split into a per-character
`print` and a whole-slice run handler. The G0/G1 map has to apply inside
the run path — a designated line-drawing set turns a printable-ASCII run
into non-ASCII glyphs — not around it, or `ascii` gives back its 4.3×.
The bench is the check.

### C2 — Unicode (two to three weeks)

- **Generated width tables.** A `gen_unicode.py` beside `gen_corpus.py`
  reads the UCD at a pinned version and emits `unicode_tables.zig`:
  East Asian Width, general category for zero-width, emoji presentation,
  extended pictographic. The pinned version is in the file and in
  `--version`.
- **Grapheme clusters.** Combining marks attach to the base cell instead
  of vanishing. A `Cell` holds one codepoint; a cluster needs more. The
  cheap design is an out-of-line cluster table indexed from the cell —
  the same shape as the style table [sprint 5](completed/sprint-5-cell-size.md)
  proposed, with the same eviction concern, but for the rare case rather
  than every cell. `Cell` stays 16 bytes.
- **Emoji.** VS15/VS16 presentation selectors change width; ZWJ sequences
  are one cluster and, once [D2](dependencies.md) can draw colour glyphs,
  one glyph. Regional-indicator pairs are one cluster of width 2.
- **Mode 2027** — announce grapheme-cluster width handling so apps that
  ask can stop guessing.

*Why here:* after C0 has a fuzzer to keep the pair invariants honest, and
alongside X2, which is what makes a correctly-sized cluster visible.

*Done when:* a table of hard cases — the `unicode-width` and Ghostty test
strings — occupies the same number of cells here as in Ghostty and kitty,
asserted by a unit test; `e\u{301}` renders as `é` in one cell.

*Risk:* medium to high. The cluster table touches `grid`, `terminal`,
`render` and the atlas key. The fuzzer and the gallery are the safety
net; land nothing here without both.

### C3 — Terminfo and identity (one week)

`TERM=xterm-256color` with `COLORTERM=truecolor` is the right answer
today: it is what every host has, and `ssh` to a machine without our
terminfo is the classic failure. `TERM_PROGRAM=terminator` is already set
and is what shell integration and agents should key off.

Ship a `terminator` terminfo entry only when C1 has made its claims true —
then it can advertise `Tc`, `Smulx`, `Sync` and the kitty keyboard
protocol honestly — and install it with the app, still defaulting to
`xterm-256color` unless the entry is present on the host. `--version`
prints the Unicode version, the terminfo version and the protocol levels.

*Gate:* not before C1.

*Done when:* `infocmp terminator` on a machine with the app installed
lists every capability C1 and [A2](agentic.md) implement, and nothing
they do not.

*Risk:* low.

### C4 — Robustness (one to two weeks)

- **Replies out of the lock.** Copy `replies` out under the mutex, write
  after — the same shape as the frame snapshot, for the same reason.
- **Allocation failure is a message, not a shrug.** A dropped reply or
  title logs once; a failed frame keeps the previous one (it does).
- **Startup errors are sentences.** No font, no SDL, no PTY: say which and
  exit 1.
- **Child exit.** The window shows the exit status and waits for a key, or
  closes, per config; today it closes.
- **Resize storms** coalesce to one `Terminal.resize` per frame, and a
  zero-size window keeps a 1×1 grid (it does).
- **A panic handler** that writes the last 64 KiB of PTY input to a file
  and says where — opt-in by flag, because the bytes are the user's — so
  a crash arrives with its corpus. Ties to "bring a corpus, not an
  argument".

*Done when:* `yes | head -c 100M` with the child's stdin closed does not
stall the frame; each startup error path has a test asserting its
message.

*Risk:* low.

### C5 — The test infrastructure (ongoing, half a day a sprint)

- Coverage reported per module, non-gating.
- Every completed sprint record's manual mutation test becomes a script
  under `bench/mutants/` that applies the mutation and expects the suite
  to fail. Sprint R listed seven; they are the first seven.
- Bench, gallery and esctest numbers on every PR summary, all
  non-gating, all visible.

*Done when:* a contributor can run `zig build test bench gallery
conformance` and see every arbiter on this plan in one go.

## Why this order

- **C0 first**, as with every roadmap: a harness before a list.
- **C1 with the bench open**, because charsets sit inside the run fast
  path Sprint 4 built, and the `ascii` number is what proves they did not
  undo it.
- **C2 with X2**, because a cluster you cannot draw is not a fix anyone can
  see.
- **C3 gated** on C1; advertising capabilities is a promise.
- **C4 whenever a week is free**; the reply-lock fix should not wait.

## Not on this plan

- **Sixel, ReGIS, DECDLD** — graphics and downloadable fonts. Parsed and
  discarded; that is conformant.
- **8-bit C1 controls.** UTF-8 only; a byte in 0x80–0x9F is a UTF-8 lead
  or a replacement character, never a control.
- **VT52 mode, DECANM.** Nobody has needed it since the programs that did
  stopped running.
- **Bidirectional text.** Real, hard, and best done once the cluster
  table exists; revisit after C2.
