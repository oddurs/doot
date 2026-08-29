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

**Rect mode is the one exception**, and the review below is why: a rectangle's
two columns are shared by every row it covers while the glyphs under them are
not, so a single stored pair of columns cannot say *"and one cell wider on row
4"*. Rect therefore snaps per row, in `spanFor` — which is still one place,
and still the one both the renderer and the extractor call, so the property
that mattered is intact.

**A missing endpoint is resolved by monotonicity, not by a guess.** Ids are
minted monotonically, so an id smaller than every id still on the grid can
only have fallen off the oldest end of the history: it clamps to ordinal 0,
where it can only make the selection smaller. An id that is *not* smaller than
all of them had its row retired under it, and the selection is dropped. See
the review section — the first version guessed, and the guess was expensive.

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

Every committed grid checksum changed, because `wrapped` is now in them —
`bench/baseline.txt` carries the new ones, and the whole-run `checksum` moved
from `102380897115` to `102382673301`. That file had been left stale on the
first pass while the sentence above claimed otherwise; the review caught it,
and CLAUDE.md names that file as the arbiter.

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

That was not enough. The adversarial review below planted seven more that
these ten did not cover, and the reason is the one CLAUDE.md names: the ten
were chosen by the author, from the same mental model that wrote the code.
Every one of the seven now dies.

**Gallery.** `--select R,C,R,C` applies a selection in viewport coordinates
before the screenshot — there is no mouse under `SDL_VIDEODRIVER=dummy`, so it
is the only way to photograph a highlight. Three captures over one scene: the
first cuts across a coloured background, a wrapped line and a reverse-video
run at once, so the background override, the run-batch split and the reverse
foreground fix are all in one picture; the second lands both edges on a wide
character, so the highlight is six cells over a four-cell request; the third
(`--select-rect`, added by the review) is the same columns as a rectangle over
three rows, of which only the last carries the wide pair — its block is one
cell wider on that row and exactly as asked on the other two, which is the
picture of per-row snapping. All eleven pre-existing captures are
**pixel-identical**, which is what says the render refactor changed nothing it
was not meant to, and all thirteen stayed identical through the review's
fixes.

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

## What the adversarial review found

CLAUDE.md says to have the change reviewed adversarially before merging, and
that every sprint here has had a review find something the author's own
testing missed. This one found seven, and the first is the worst bug the
sprint produced.

**1. A selection silently expanded to cover the entire scrollback.** `clip`
sent *any* unresolvable endpoint to ordinal 0, on the reasoning that "eviction
only ever removes the oldest lines, so a missing endpoint is the earlier one."
That is false. `clearRows` and `fill` retire ids in the middle and at the end
of the screen, and **none** of `ED 0`, `ED 1`, `ED 2`, `IL`, `DL`, `SU`/`SD`,
a region scroll or a height-shrinking resize clears the selection. On an 8×5
grid with 56 lines of history, a four-row selection extracting 24 bytes became
ordinals 0..56 and **383 bytes** beginning `HIST0\nHIST1\n…` the moment a
`DL 1` landed on its head row — and `ESC[J` reproduced it identically, which
is what readline emits on nearly every prompt redraw. At a real 10,000-line
scrollback that is the whole session on the pasteboard while the highlight
*shrinks to one row*, so there is no visual warning at all.

The fix uses monotonicity instead of a guess, as described above. Losing a
highlight is a correct and predictable outcome; silently copying the history
is not. The comparison is against the **smallest** surviving id rather than
the id at ordinal 0, because `RI` and `IL` splice a freshly minted — and
therefore higher — id above older rows, so oldest-by-position is not
oldest-by-number. On the way past: `sel.zig:303` was byte-identical to the
line above it, and both `orelse return null` in `resolve` were dead because
`Terminal.init` forces `rows >= 1`. They are live now, and that is the point.

**2. `viewOrd` was untested at non-zero `view_offset`.** It positions every
highlight, and E3 will reuse it for search. Replacing its body with
`return term.scrollback.len + y;` — which misplaces every highlight by
`view_offset` rows whenever the user has scrolled back — passed all 361 tests
and all 13 gallery captures, because every test and every capture ran at
offset zero. Two property tests now sweep **every** offset from 0 to
`scrollback.len`: `lineByOrd(viewOrd(y))` is `viewRow(y)`/`viewRowMeta(y)` by
identity *and* by pointer, and exactly the selected row is highlighted. The
mutant dies at the first non-zero offset.

**3. Rect-mode wide snapping consulted only the start row**, so "wide
characters select as a pair, in every mode" was false. On ten columns,
`abcdefghij` over `ab一二efgh`, a rectangle from row 0 x=3 to row 1 x=4 copied
`"de\n二"`: `一` dropped entirely and two glyphs cut in half. Snapping moved
from `normalize` to `spanFor`, which is the only place that has the row.

The rejected alternative is worth recording, because it looks better than it
is: widening the block to the **union** of what every covered row asks for
keeps it perfectly rectangular. But two misaligned rows of CJK have a spacer
in almost every column between them, so the union walks a two-column drag out
to the full width of the grid. Per-row snapping ripples the edges by at most
one cell. There is a test pinning each.

**4. `endLine`'s documented rule contradicted the code.** It claimed "the
erasures that blank a row's tail all end a line", and `ECH`, `DCH` and `ICH`
never called it: on four columns, `abcdef` then `ESC[1;1H ESC[4X` left row 0
blank and still claiming to wrap, so a triple-click below it yielded
`"    ef"` and E4's reflow would re-wrap a blank row. `wrapped` is a primitive
four later sprints build on, so the rule is now stated precisely and the code
made to match it: **`wrapped` is a claim about the cell at the right margin.**
`ECH` ends the line when it reaches the margin and not before; `DCH` always
does, because shifting left blanks the tail; `ICH` deliberately does not,
because it shifts text *into* the margin rather than blanking it, and a shell
editing a long wrapped command line inserts and then reprints the remainder —
clearing the flag under it would split one logical line in two for
triple-click, copy and reflow alike. Four rows joined the fourteen-case table.

**5. `Renderer.scale` was assigned in `init` and never updated.** Every mouse
coordinate is converted with it, and `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED`
routes to `updateSize`, which refreshed `px_w`/`px_h` and the GPU target but
not the density — so a window dragged between displays of different density
mapped clicks to the wrong cells for the rest of the session. `updateSize` now
re-reads `SDL_GetWindowPixelDensity` through `cli.effectiveScale`, which keeps
`--scale` authoritative; without that the gallery's 2× captures would stop
pretending the first time the window was measured. The rule is unit-tested in
`cli.zig`; **that the call happens at all is not**, because `render.zig`
`@cImport`s SDL and is in neither test root. All 13 pre-existing captures are
still pixel-identical, which is the only evidence available that the override
survived.

**6. `bench/baseline.txt` had not been regenerated**, while this record and
the PR both claimed every committed checksum moved. It has been, twice, and
the two runs agree.

**7. One surviving mutant is equivalent.** Dropping `covered_to_end` from
`join` in `extract` changes no output for any input: in non-rect mode only the
final row can be short, and on the final row `join` reaches neither the trim
branch nor anything that reads `sep_owed`. There is now a comment in the
source saying so, so nobody "fixes" it later.

**Seven more mutants, all of which now die**: `clip` sending every missing
endpoint to ordinal 0; `viewOrd` dropping `view_offset`; rect mode not
snapping per row; `ECH` at the margin not ending the line; `DCH` not ending
it; `ICH` wrongly ending it; and `effectiveScale` forgetting the override.
Re-measured afterwards, the geometry table is unmoved — 80×24 is still
**1.00×**, which is the committed regression test that the ring's fast path
fires.

## Traps for whoever touches this next

- `Screen.meta` is indexed **physically**. `meta[y]` is the bug; `rowMeta(y)`
  is the accessor.
- The id mutators return how many ids they used. Advance the counter by the
  return, never by a number worked out at the call site.
- `scrollScreenUp` and its three siblings are `inline` **for performance, not
  style**. Removing the keyword costs a quarter of the `ascii` corpus.
- `wrapped` is a claim about the cell at the **right margin**, and nothing
  wider. Adding an operation that blanks or overwrites that cell means
  deciding whether it calls `endLine`; the fourteen-plus-four-case table is
  where that decision is written down.
- `spanFor` takes the row's cells because **rect mode snaps wide pairs per
  row**. The argument is required, not optional, so that a caller cannot
  silently get the un-snapped answer.
- A selection endpoint that no longer resolves is only clamped when its id is
  below every surviving id. Anything looser copies the whole scrollback.
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
