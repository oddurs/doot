# Sprint E1 — Selection and copy

**Done.** First sprint on [essentials.md](../essentials.md), and the first
one whose point was less the feature than the two primitives underneath it.

Selection is what the README called the biggest gap. It is also where the
**per-row `wrapped` flag** and the **stable line identity** had to be built,
because E1 is the first sprint that needs either — and E3 (search), E4
(reflow), A3 (semantic prompts) and A4 (path detection) all need them after
it. So the design of the primitives mattered more than the design of the
feature, and most of this record is about them.

## The two primitives

### `RowMeta`, a parallel array indexed *physically*

```zig
pub const RowMeta = struct {
    id: u64 = 0,
    flags: Flags = .{},
    pub const Flags = packed struct(u8) { wrapped: bool = false, _pad: u7 = 0 };
};
```

`Screen.meta` has one entry per row, and `rowMeta(y)` goes through the **same
`physical(y)`** that `row(y)` does. That is the whole trick:
[sprint R](sprint-r-screen-ring.md) made the screen a ring, so rotating
`offset` now rotates the metadata with the cells for free and `scrollUp`'s
whole-screen fast path — the hot path for every line of shell output — needed
no new code at all.

[priorities.md](../priorities.md) names the trap for this primitive in
advance: *"a mark that does not rotate with its row is a mark on the wrong
row."* Going through `physical()` is what makes that unreachable rather than
merely avoided, and the first mutant below is exactly that bug.

Four places did need explicit work, and each is a mutant:

- `scrollUp`/`scrollDown`'s **region** branch moves rows by hand, so it has to
  move the metadata beside each `@memcpy`.
- `clearRows` and `fill` reset the flags and stamp fresh ids — a cleared row
  is a new line, not the old one emptied.
- `Scrollback.push` carries the metadata into the same slot as the cells, or a
  selection stops resolving the instant its line scrolls off the screen, which
  is precisely the case this sprint exists for.

`Cell` stays 16 bytes; [sprint 5](sprint-5-cell-size.md)'s retirement stands.
The cost is one 16-byte `RowMeta` per row against `cols * 16` bytes of cells:
**+1.25% at 80 columns, +0.5% at 200**, on both the screen and the 10,000-line
scrollback.

### One id counter, on the `Terminal`

`grid.zig` holds no policy, so it only *stores* ids. `Terminal.next_line_id`
mints them, starting at 1 — `id == 0` means "no line" and is never minted.
**One counter for both screens and the scrollback**, so every id is disjoint
from every other and a selection anchor can never resolve onto an alt-screen
row that happens to share a number with the primary row it came from.
`fullReset` deliberately does not reset it.

Ids are **stored, never derived from a base**. `IL`, `DL` and a DECSTBM region
scroll splice freshly minted rows into the middle of the screen, so anything
computed as "base plus offset" silently relabels every row below the splice.

The trap the plan called out is real: `scrollUp`'s `n >= height` branch
delegates to `clearRows` for the **whole region**, so it stamps `height` rows
and not `n`. A caller that minted `n` hands two rows the same id, and nothing
notices until a selection resolves onto the wrong one. Rather than encode that
rule in two places, every mutator **returns how many ids it used** and the
terminal advances its counter by the return. The bug is then unwriteable at
the call site, and the mutation test plants it in the return value instead.

## The model: `src/sel.zig`

`std`, `grid` and `terminal` are the whole import list, so all of it is in the
unit-test root. `render.zig` and `main.zig` both `@cImport` SDL and cannot be
unit-tested at all, so they keep only glue that hands numbers to this file:
the pixel-to-cell arithmetic, the word classifier, `contains`, the
wide-character snapping and `extract` are all here.

**Ordinals.** Resolving an id gives an ordinal — history first, oldest at 0,
then the live screen — and `ord = scrollback.len + y - view_offset` is the
ordinal of viewport row `y`, the same branch `Terminal.viewRow` takes. Ids
alone cannot order two lines, because `IL` and `RI` mint fresh, higher ids for
rows *above* older ones; ordinals can. `lineById` is the single accessor for
the scrollback boundary, so a selection spanning history and the live screen
needs no special case anywhere else. It binary-searches the history (ids
descend with `i` for every history a shell actually produces) and falls back
to a scan rather than believing the search, because `IL` can un-sort it.

**Normalizing at set time, not in the extractor.** Wide-character snapping — a
start on a `.spacer` snaps left onto its `.wide` partner, an end on a `.wide`
extends over its spacer — and word and line expansion all happen once, in
`normalize`. If the highlight and the copied text each worked it out
separately they would eventually disagree, and that is a bug you can only see
by comparing a screenshot against a pasteboard.

**Triple-click takes the logical line**, expanding across as many rows as
`wrapped` says belong to it. Selecting one screen row would have left
`wrapped` unused by two of the three granularities on the day it shipped.

**Extraction:** skip `.spacer` and emit the wide cell's codepoint once; trim
trailing spaces from any row the selection covers to the last column,
regardless of background; a row that is `wrapped` **and** covered to the last
column joins the next with no separator and no trim; `rect` never joins,
always trims, always separates with `\n`; codepoints only, no SGR; a 16 MiB
cap that truncates at a **row boundary**; NUL-terminated, because
`SDL_SetClipboardText` takes a C string and a selection is user-controlled
length.

## Rendering: a resolved span, not a range

The sprint text said the `Frame` carries the selection range. That is wrong,
and the reason is worth writing down: `draw` runs **after** the terminal mutex
is released and has no scrollback, so it cannot resolve a line id. `Frame.sel`
is therefore `[]Span` — one resolved half-open `[x0, x1)` per row, filled
inside `snapshot`'s existing row loop, one `contains` test per row under a
lock that is already memcpying twelve thousand cells.

`draw`'s background pass splits each row at the span into `[0, x0)`,
`[x0, x1)` and `[x1, cols)`. The outer two batch into runs exactly as before;
the selection is **one** rect whatever is under it, so a highlight over a
rainbow costs the same as one over blank space. A selected cell with
`attrs.reverse` is drawn with the **unreversed** foreground — otherwise a
`less` status line paints the theme's dark background on top of the dark
selection and the text disappears the moment you select it. Both are in the
gallery.

## Events

`SDL_EVENT_MOUSE_BUTTON_DOWN`/`UP`/`MOTION`. Click counts come from
`ev.button.clicks`, which SDL3 already tracks — no hand-rolled timestamp
window. Modifiers come from `SDL_GetModState()`, because `SDL_MouseButtonEvent`
carries no modifier field. Shift-click extends from the existing anchor;
Option-drag sets `rect`; a click with no drag clears the selection rather than
making a one-cell one; copy-on-select (`--copy-on-select`) does **not** clear
the selection; `Cmd C` with no selection does nothing at all.

`sel.mouseOwner(term, shift)` returns `.terminal` or `.child`, with the
`.child` branch empty for [E2](../essentials.md) to fill. E1 **refuses to
start a selection** when it returns `.child`, which is the only part of that
function that matters today: the day E2 forwards a drag inside vim, a version
without this would both scroll vim and paint a highlight over it.

Autoscroll takes `SDL_WaitEventTimeout(&ev, 16)` **only** while a button is
held outside the grid. Measured over ten idle seconds, headless:

| | wall | user | sys | voluntary ctx switches |
|---|---|---|---|---|
| `main` | 10.34 s | 0.05 | 0.10 | 14 |
| this branch | 10.18 s | 0.04 | 0.10 | 8 |

An idle terminal still wakes as rarely as it did. A 16 ms poll would have
shown ~625 wakes.

## Two things fixed on the way past

**`Modes.mouse` was one bool covering 1000, 1002, 1003, 1006 and 1015.** 1006
and 1015 are *encodings*, not tracking modes, so an application sending
`ESC[?1006h` on its own — which many do, before or without ever asking for
tracking — silently took the mouse away from the user and disabled selection.
Now `1000, 1002, 1003 => modes.mouse` and `1006, 1015 => modes.mouse_sgr`, and
both are hashed. Three lines, and a bug nobody would have found by looking at
selection.

**`rec.zig`'s `Control` comment claimed a closed list** of the ways `main.zig`
mutates the terminal outside `parser.feed`. E1 adds `setSelection`; the
comment now says so and says why it is excluded, for the same reason
`scrollView` is — both move only what the window shows, and `check.zig`
excludes both by construction.

## What the checksum does and does not cover

`check.zig` gains **`wrapped`** and deliberately gains neither the line id nor
the selection.

- `wrapped` is a property of the byte stream. A replay that got wrapping wrong
  *is* wrong, and this is the only thing that tells two screens with identical
  cells apart when one was reached by wrapping at the margin and the other by
  a line feed. There is a test that does exactly that: same cells, same
  cursor, different flag, different checksum.
- The id is a property of *this terminal's history* — two terminals fed the
  same bytes from different starting points hold the same screen with
  different numbers on it. The selection is view state, like `view_offset`.
  Hashing either manufactures divergences that say nothing about the
  recording, which is the failure mode that file exists to avoid. There is a
  test that bumps `next_line_id` by 5,000, sets a selection and relabels every
  row on the screen, and asserts the checksum does not move.

Every committed grid checksum changed, because `wrapped` is now in them.

## The performance story, which was not the one expected

The primitives were expected to cost something on `lineFeed`, the hottest path
in the program. Measured before and after, they cost **nothing** — and a
four-line refactor beside them cost **26%**.

The first run after the change:

| corpus | before | after | |
|---|---|---|---|
| ascii | 491.2 | 361.0 MiB/s | **0.74×** |
| scroll | 291.6 | 184.7 | **0.63×** |
| region | 141.3 | 130.1 | 0.92× |
| altscreen | 394.4 | 403.3 | 1.02× |

`altscreen` is the control — it contains no newlines, so it never scrolls —
and it did not move, which said the cost was per line feed. Ten probes
followed, each removing one suspect and re-measuring: the `RowMeta` writes in
`clearRows`, the metadata write in `Scrollback.push`, the `wrapped` flag
writes, the id counter, the struct field order, the allocation order, the
extra call layer in `printRun`, and the circular `sel.zig` import. **Every one
of them was free.** Copying the new `grid.zig` onto `main` alone measured
490 MiB/s, so the whole of the metadata array cost nothing at all.

The culprit was this:

```zig
fn scrollScreenUp(self: *Terminal, top: usize, bot: usize, n: usize) void {
    const first = self.next_line_id;
    self.next_line_id += self.screen().scrollUp(top, bot, n, self.blankCell(), first);
}
```

`lineFeed` calls it with a literal `n = 1`, and LLVM had been specializing the
whole of `Screen.scrollUp` on that constant — the `n >= height` branch folds
away, the clear becomes a single row. Behind an ordinary function `n` is a
runtime parameter and all of it is lost. The four wrappers are now `inline`,
with a comment saying why, and the numbers came back:

| corpus | `main` | this branch | |
|---|---|---|---|
| ascii | 491.2 | 489.5 MiB/s | 1.00× |
| sgr | 378.2 | 393.5 | 1.04× |
| scroll | 291.6 | 285.4 | 0.98× |
| altscreen | 394.4 | 397.9 | 1.01× |
| cjk | 190.5 | 214.1 | 1.12× |
| region | 141.3 | 138.7 | 0.98× |

And the geometry table — the committed regression test that the ring's fast
path still fires — is unchanged:

| geometry | before | after |
|---|---|---|
| 80×24 | 1.00× | 1.00× |
| 80×48 | 0.97× | 0.97× |
| 80×100 | 0.93× | 0.93× |
| 80×200 | 0.93× | 0.93× |

`scroll` is 2% down and `cjk` 12% up, both reproduced across two runs; the
`cjk` gain is a side effect of the same `inline`, since `print`'s wrap path
now inlines too. `scan` and `redact` are byte-identical to the baseline, which
is what says the machine was not the variable.

The lesson is the repository's own rule, and it only worked because the
measurement came first: the profile-free guess about what would be expensive
was wrong in both directions.

## Correctness

**Unit tests.** Ids and `wrapped` survive forty ring rotations, mirroring
`grid.zig`'s five existing rotation tests; a region scroll after rotation moves
metadata with its cells, in both directions; `clearRows` across the wrap point
stamps exactly its range; `fill` relabels everything; `push`/`backMeta` are
walked as a pair so they cannot disagree about which slot is which. `wrapped`
is set by a margin wrap, by a wide character that will not fit, and by
`printRun`'s own wrap site; a fourteen-case table covers what clears it (`LF`,
`VT`, `FF`, `IND`, `NEL`, `EL 0`, `EL 2`, `ED 0`, `ED 2`) and what leaves it
alone (`CR`, `EL 1`, `ED 1`, cursor movement, backspace). `sel.zig` has
`contains` forward, backward, multi-row and rect; the word classifier as a
table; `cellAt` over a scale table at 1× and 2× including every way out of the
window; `extract` for wide-plus-spacer, trim, the wrapped join, rect, spanning
the scrollback boundary and an evicted anchor.

[Sprint 4](sprint-4-print-run.md)'s `expectSameTerminal` now compares row
metadata and the id counter as well as cells, so the existing differential
test — one printable run against `print` called once per byte, at every split
point of a 43-byte line — covers `printRun`'s wrap site for free.

**End to end**, on a real pty: a marker line is selected, a hundred and one
more lines are pushed through the shell, and the extracted text is
**byte-identical** while the resolved viewport row has moved by exactly the
number of lines that entered history — that is the line-id primitive proven,
and it is what the sprint's `yes` clause actually means. Plus a selection
across a wrapped line, across a wide character (including an edge landing on
its spacer), across the scrollback boundary, and one cleared by a program
taking the alt screen.

**Mutation-tested**, and as CLAUDE.md warns, the first pass left one alive.
Ten deliberate breakages: metadata indexed logically instead of physically;
`wrapped` set on the arriving row instead of the departing one; `wrapped` not
cleared by `LF`; the region scroll not moving metadata; `push` dropping the
id; extraction joining wrapped rows with `\n`; a spacer emitted as a space;
trim applied to a wrapped row; `contains` off by one at the end column; and
`scrollUp`'s `n >= height` branch minting `n` ids instead of `height`.

Nine died. **One survived** — trimming a wrapped row — because every wrapped
row in every test happened to use text with no spaces at the margin, so
deleting them changed nothing visible. A wrapped row's trailing blanks are
*inside* the line: the margin fell there, the text did not end there, and
trimming them silently deletes characters the shell printed. A test for
`"abc   def"` wrapped at six columns was added and the mutant re-run. All ten
are now caught.

**Gallery.** `--select R,C,R,C` applies a selection in viewport coordinates
before the screenshot — there is no mouse under `SDL_VIDEODRIVER=dummy`, so it
is the only way to photograph a highlight. Two captures over one scene: the
first cuts across a coloured background, a wrapped line and a reverse-video
run at once, so the background override, the run-batch split and the reverse
foreground fix are all in one picture; the second lands both edges on a wide
character, so the highlight is six cells over a four-cell request. All eleven
pre-existing captures are **pixel-identical**, which is what says the render
refactor changed nothing it was not meant to.

## Hand checks

The plan asks for four. Two were done and two could not be:

- **Idle CPU** — measured, in the table above. Unchanged from `main`.
- **Double-click boundaries** — exercised as a table in `sel.zig` rather than
  by hand: `src/render.zig` is grabbed whole from any column inside it, a
  space is a word of its own, `(` does not swallow the word beside it, and a
  CJK run does not stop at a spacer.
- **The clipboard actually reaching the pasteboard** and **the feel of
  autoscroll** need a person at a real window, and this branch was built
  headless. The code path is one `SDL_SetClipboardText` call on a
  NUL-terminated buffer whose sentinel is asserted in a test, and autoscroll's
  rate curve is unit-tested — but neither is the same as having tried it.
  **They should be tried before this merges.**

## Traps for whoever touches this next

- `Screen.meta` is indexed **physically**. `meta[y]` is the bug; `rowMeta(y)`
  is the accessor.
- The id mutators return how many ids they used. Advance the counter by the
  return, never by a number worked out at the call site.
- `scrollScreenUp` and its three siblings are `inline` **for performance, not
  style**. Removing the keyword costs a quarter of the `ascii` corpus.
- The selection is cleared by a width-changing resize, `fullReset`, `ED 3` and
  an alt-screen switch. It deliberately survives `markDirty`'s view snap —
  that is the point of the ids, and `markDirty` is [E7](../essentials.md)'s to
  change, not this sprint's.
- `check.zig` hashes `wrapped` and must not gain the id or the selection.

## Out of scope, and still is

No reflow ([E4](../essentials.md) — the width-resize scrollback discard is
exactly as it was), no search ([E3](../essentials.md) — `Frame.sel` is
deliberately one span per row and not a list), no mouse reporting
([E2](../essentials.md) — `mouseOwner`'s `.child` branch is empty), no OSC 52,
no `Cmd A`, and `markDirty` untouched.
