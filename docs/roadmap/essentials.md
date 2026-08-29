# Essentials roadmap

Well-rounded: the things every terminal must do, done properly rather
than first. Sized for one person at 8–12 focused hours a week. Sprint
prefix: **E**.

Arbiter: **the end-to-end suite** in `src/tests.zig` — a real shell on a
real PTY, asserting on the grid. Each sprint here lands with a test that
drives the feature through the PTY and fails without it.

The README's "Not done yet" list is the source; this page sequences it and
says what "done" means for each item.

## Where we are

| | Today | Where |
|---|---|---|
| ~~Selection~~ | **Done ([E1](completed/sprint-e1-selection.md)).** Drag, word, logical line, shift-extend, block; `Cmd C` and copy-on-select | `sel.zig`, `Frame.sel`, `main.zig`'s mouse handlers |
| Mouse reporting | Tracking modes and the encoding are separate now, but events are still not forwarded | `Modes.mouse` / `Modes.mouse_sgr`; `sel.mouseOwner`'s `.child` branch is empty |
| Search | None | — |
| Reflow | Top-left anchored. **Scrollback is discarded whenever the width changes** | `Terminal.resize`: `if (c != self.cols)` re-creates the ring |
| Config | CLI flags only: `--font-size`, `--shell`, `--size`, `--frame-stats` | `parseArgs` |
| Keybindings | Fixed. `Cmd + - 0 V K` | `handleKey` |
| Application keypad | Tracked, **never consulted by the encoder** | `Modes.app_keypad`; no reader outside `terminal.zig` |
| Scroll position | **Any output snaps the view to the bottom**, so a log cannot be read while it grows | `markDirty` resets `view_offset` |
| Scroll indicator | None. No way to see how far back the view is | — |
| ~~Wrapped-line tracking~~ | **Done ([E1](completed/sprint-e1-selection.md)).** Per row, in the checksum, and carried into scrollback | `grid.RowMeta.Flags.wrapped` |
| ~~Line identity~~ | **Done ([E1](completed/sprint-e1-selection.md)).** One counter for both screens and the history, stored per row | `grid.RowMeta.id`, `Terminal.next_line_id` |

## The sprints

### E1 — Selection and copy (two weeks) — **done**

Shipped: [the sprint record](completed/sprint-e1-selection.md). Both
primitives landed with it, and the `wrapped` flag is in the grid checksum
while the line id and the selection deliberately are not — one is a property
of the byte stream, the others are properties of history and of the view.

Two things came out differently from the plan below, and both are worth
knowing before E3 or E4 starts:

- **The `Frame` carries a resolved per-row span, not the selection range.**
  `draw` runs after the terminal mutex is released and has no scrollback, so
  it cannot resolve a line id at all. `snapshot` resolves once and fills
  `Frame.sel: []Span` in the row loop it already had.
- **`Modes.mouse` was one bool over 1000/1002/1003/1006/1015**, so an
  application sending `ESC[?1006h` alone disabled selection. Tracking and
  encoding are separate fields now, which is most of what E2 needed from
  this file.

The plan as written:

The biggest gap. Click-drag, double-click for a word, triple-click for a
line, `Shift`-click to extend, `Option`-drag for a block. `Cmd C` copies;
copy-on-select is a config key, off by default. Wide characters select as
a pair; trailing blanks are trimmed; selected text is UTF-8 with the
cell's codepoints and nothing else.

Two primitives land here and are reused by three other sprints:

- **A `wrapped` flag per row**, set in `print` when the line feed came
  from the right margin and cleared by an explicit `LF`. Selection joins
  wrapped rows without a newline. Reflow (E4) re-wraps by it; path
  detection ([A4](agentic.md)) spans it.
- **A stable line identity.** The screen ring rotates and scrollback
  pushes, so a row index is not an anchor. A monotonically increasing line
  counter on the terminal, with each screen and scrollback row knowing
  its number, is. Selection anchors to it and survives output scrolling
  under it; search (E3) and semantic prompts ([A3](agentic.md)) point at
  it.

Rendering: the `Frame` carries the selection range, the background pass
overrides `bg` with `theme.selection` inside it, and the glyph pass is
untouched. No new draw call.

*Why here:* first, because it is the most-missed feature and because it
builds what three others need.

*Done when:* an e2e test selects across a scroll boundary, across a wide
character and across a wrapped line, and the extracted text is exactly
what the shell printed. A selection made while `yes` runs stays on the
same text as it scrolls up.

*Risk:* medium. The line identity has to be threaded through
`grid.Scrollback.push` and the ring's rotation, and both are hot paths
with benchmarks watching them — `scroll` must read flat afterwards.

### E2 — Mouse reporting (one week)

Forward what the modes ask for: X10 (1000), button-event (1002),
any-event (1003), with SGR encoding (1006) and the legacy form as the
fallback. **[E1](completed/sprint-e1-selection.md) already split the tracking
modes from the encoding** (`Modes.mouse` and `Modes.mouse_sgr`) and left
`sel.mouseOwner`'s `.child` branch empty for this sprint to fill; E1 refuses
to start a selection when it returns `.child`, so forwarding a drag will not
also paint a highlight. `Shift` already overrides. The pointer is an I-beam over the
grid and an arrow over chrome.

*Why here:* small, unblocks [A4](agentic.md), and every TUI an agent runs
expects it.

*Done when:* a unit test encodes press, drag, release and wheel in each
mode against `ctlseqs`; an e2e test runs a shell script that enables 1006
and asserts the bytes a click produces. The wheel on the alt screen keeps
sending arrows when no mouse mode is set.

*Risk:* low.

### E3 — Search (one to two weeks)

*Reuses from E1:* `sel.lineById` for the scrollback boundary, `RowMeta.id` to
point at a match, and the highlight path. Note that `Frame.sel` is one span
per row on purpose — search wants a list, and generalising it was
deliberately left to this sprint rather than guessed at in E1.


`Cmd F` opens a one-line bar drawn in the grid area; typing searches the
scrollback and screen incrementally, case-folded; `⏎` and `⇧⏎` step
through matches; `Esc` closes. Matches are highlighted through the same
frame mechanism as selection, and the current match scrolls into view.
Regex is a later flag, not the default.

*Why here:* after E1, whose highlight path and line identity it reuses.
This is search over the live view; [L2](record.md) extends the same bar
and the same highlight path over every session and every moment.

*Done when:* a search over 10,000 lines × 200 columns returns its first
match in under 10 ms — the full-grid scan is ~0.7 ns/cell, so 2 M cells
is 1.4 ms to walk and the string search should not be an order worse — and
an e2e test finds a string that was pushed into scrollback.

*Risk:* low.

### E4 — Reflow on resize (three weeks) — **gated**

Re-wrap the primary screen and scrollback on a width change, using the
`wrapped` flag from E1. The alt screen does not reflow; the app redraws.
The cursor stays on the same logical character.

This is the widest blast radius on this roadmap. The scrollback is a
fixed-capacity ring of `cols`-wide rows, which is what makes resize
discard it today; reflow means either re-wrapping into a new ring of the
new width — O(lines × cols) on every drag — or a variable-width
representation that is a different data structure with different scan
properties.

*Gate:* first fix the discard — a width change must re-wrap or at least
copy scrollback, never drop it. That is a one-week fix and it is worth
doing on its own. Then note what [L1](record.md) changes: once
scrollback is a view of the record, reflow is re-materializing that
view at a new width from the log, which needs no new data structure at
all — the re-wrap cost is the replay cost, already measured. If L1
lands first, this sprint shrinks to the discard fix plus a view. Then measure re-wrapping 10,000 lines at 200 columns.
If it fits in one frame at 120 Hz (8 ms), the simple approach ships and
the data-structure change is retired. If it does not, reflow becomes
incremental — visible rows first — and the structure question reopens
alongside [sprint 5](completed/sprint-5-cell-size.md)'s footprint
argument.

*Done when:* an e2e test prints a long line, narrows the terminal, widens
it, and asserts the line is back on one row; `resize` is a bench entry
and `scroll` still reads flat.

*Risk:* high. Sprint R's ring made rows non-adjacent in memory; reflow is
the first thing since to want to walk them all at once.

### E5 — Configuration — **moved**

This became its own roadmap, [config.md](config.md): the one-struct
source of truth (K0), error reporting and `+show-config` (K1), `Cmd ,`
opening the file in a tab (K2), and themes and keybinds as config (K3,
K4). The sprints here that wanted a key — E6, E7 — get it from K0.

### E6 — Keybindings and input completeness (one to two weeks)

- **An action table** — `new_tab`, `copy`, `paste`, `font_bigger`,
  `search`, `scroll_page_up`, `text:` — with the current defaults as
  the shipped set. The binding syntax and `+list-keybinds` are
  [K4](config.md); this sprint owns the actions and what they do.
- **`Option` as Meta or as composition**, per side, configurable — the
  question every Mac terminal has to answer. Verify what happens today
  when `Option B` produces both a `TEXT_INPUT` of `∫` and an `ESC b` from
  the key path; the test decides whether that is one bug or none.
- **Application keypad** consulted by the encoder, since the mode is
  already tracked. `Cmd ←/→` as Home/End, `Option ←/→` as word jumps
  (`ESC b` / `ESC f`), `Fn` keys 13–20, and the `Home`/`End` variants
  apps disagree about.
- **The kitty keyboard protocol** from [A2](agentic.md) shares the
  encoder; this sprint is where the legacy and the protocol paths are
  reconciled in one table.

*Done when:* a key-encoding conformance table — key × modifier × mode
against xterm's output — is fully green in `input.zig`'s unit tests, and
a rebinding in the config takes effect on reload.

*Risk:* low to medium. `input.zig` is the best-tested file in the tree;
keep it that way.

### E7 — Scrollback quality of life (one week)

- **Stop snapping on output.** `markDirty` resets `view_offset`; typing
  already snaps in `sendToPty`. Remove the first, keep the second, and a
  log can be read while it grows — the behaviour every other terminal has.
- **A scroll indicator** — a thin bar in the right padding that appears
  when scrolled back and fades after a second.
- `Cmd Home` / `Cmd End`, `Shift PageUp` / `PageDown` through history, a
  configurable scrollback size, and `Cmd K` that clears the screen and
  history versus `clear` that clears the screen.
- **Save scrollback to a file**, plain text and with escapes, from the
  menu ([X5](experience.md)).

*Why here:* small fixes with an outsized effect on daily use; the first
item is a one-line change to a real bug.

*Done when:* an e2e test scrolls back, pushes output, and asserts the
view offset is unchanged; the indicator is in the gallery.

*Risk:* low.

## Why this order

- **E1 first** because it is most missed and because the `wrapped` flag
  and line identity unblock E3, E4 and two agentic sprints. Done; both
  primitives are in `grid.RowMeta`.
- **E2 is a week** and unblocks [A4](agentic.md).
- **K0 ([config.md](config.md)) before E6, X3 and X4**, so none of them
  invent a config format.
- **E4 gated and late.** The discard bug is fixed first and alone; the
  full reflow waits for a number.
- **E7 whenever a week is free.** The snap fix should not wait for its
  sprint; it is one line.

## Not on this plan

- **Splits.** After tabs ([A5](agentic.md)), and gated on them.
- **A tmux replacement**, an SSH client, a file manager. Programs, not
  terminal features.
- **Linux.** SDL3, FreeType and `forkpty` were chosen with it in mind;
  the mac-specific code is the font paths and `util.h`. It waits for the
  Mac experience to be finished ([P5](platform.md)).
- **Regex search by default.** Literal, case-folded, fast. Regex behind a
  toggle once someone asks.
