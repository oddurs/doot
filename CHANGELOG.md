# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with the usual
0.x caveat that the interface may still move under you.

## [Unreleased]

### Changed

- **Renamed to doot.** The project was `terminator`, which is also the name
  of a well-known GNOME terminal. The binary, bundle id, `TERM_PROGRAM`,
  the recordings directory and the repository are all `doot` now; GitHub
  redirects the old repository name. See
  [the record](docs/roadmap/completed/sprint-n-rename-doot.md).

### Security

- **The reply policy.** The terminal never sends the child bytes derived
  from screen content, the title, the clipboard, or another tab. Written
  down in [docs/security.md](docs/security.md) with a test per row: title
  reports, screen checksums, DECRQSS, XTGETTCAP and OSC 52 reads are never
  answered; DA1, DSR and CPR are the only replies, and they are constants
  or cursor coordinates.

### Added

- **Selection and copy.** Drag to select, double-click for a word,
  triple-click for a whole logical line across however many rows it wrapped
  onto, `Shift`-click to extend, `Option`-drag for a rectangle. `Cmd C`
  copies; `--copy-on-select` copies as soon as a drag ends. Wide characters
  select as a pair, trailing blanks are trimmed, a wrapped line comes back as
  one line with no newline the shell never sent, and the text is the cells'
  codepoints and nothing else.
- **A selection is anchored to lines, not to rows**, so one made while output
  is scrolling stays on the same text as it scrolls away and into the
  scrollback. An end-to-end test selects a marker, pushes a hundred more lines
  through a real shell, and asserts the copied bytes are identical.
- **Two primitives three other sprints were waiting on**: a per-row `wrapped`
  flag, set when a line feed came from the right margin rather than from `LF`,
  and a stable per-line id that survives the screen ring rotating and the
  scrollback pushing. Reflow will re-wrap by the first; search and semantic
  prompts will point at the second.
- `--select R,C,R,C` applies a selection in viewport coordinates before
  `--screenshot` fires, so the gallery can photograph a highlight.

- **Every session is recorded to disk, and it is on by default.** One
  append-only `.trec` file per session under `~/Library/Application Support/
  doot/sessions/`, holding every byte the session printed with the time
  it arrived. `zig build replay -- SESSION.trec` rebuilds the terminal that
  file ends at; an end-to-end test asserts the rebuilt grid hashes the same as
  the live one, which is the claim the whole feature rests on.
- **It is visible, because on-by-default is only defensible if it is.** The
  window title reads `● rec` for as long as a session is being recorded, and
  `● rec+input` when keystrokes are.
- **Keystrokes are never recorded unless you ask.** `--record-input` or
  `Cmd ⇧ R` turns it on per window and the title moves in the same frame.
  Output is what a program printed; keystrokes are what you typed, and those
  contain passwords.
- Secrets in the output — API keys, tokens, session ids — are replaced as the
  file is written, including ones split across two reads off the pty.
- `--no-record` (off), `--incognito` (off, and the title says so),
  `--record-dir PATH`, and `--record-retain-days N` (default 14; 0 keeps them
  forever, swept at startup). Files are `0600` in a `0700` directory, nothing
  leaves the machine, and `rm` is the whole of deleting a session.
- `--frame-stats` gained a `record:` line: bytes, records, redactions, flushes
  and the worst single flush.

### Fixed

- **A CSI with a private marker or intermediates is no longer dispatched
  as the unprefixed sequence.** `CSI > 4 m` (modifyOtherKeys) used to turn
  underline on, and `CSI < u` (kitty keyboard pop) used to move the cursor
  to the saved position; both fired four times per recorded agent session.
  `CSI $ r` (DECCARA) would have set a scroll region. (#28)

- **`ESC[?1006h` no longer disables selection.** 1006 and 1015 are mouse
  *encodings*, not tracking modes, and folding them into one `mouse` bool with
  1000/1002/1003 meant an application that asked only for SGR encoding — many
  do, before or without ever asking for tracking — silently took the mouse
  away from the user.
- A selected cell with reverse video is drawn with its **unreversed**
  foreground, so a `less` status line no longer disappears the moment it is
  selected.

### Changed

- **The renderer is ours.** SDL's 2D renderer is replaced by 396 lines
  of Objective-C over Metal (`src/platform/gpu.m`, `src/platform/shader.metal`)
  behind a hand-written C ABI, with SDL still supplying the window and input.
  `render.zig` issues no SDL drawing call. Windowed output is **pixel-identical**
  to the SDL build across all eleven gallery scenes.
- Every frame is rendered into an offscreen texture and then presented to the
  window's drawable, rather than drawn into the drawable directly. The
  renderer now works with no window server at all, which is more than the SDL
  path could claim — `--screenshot` reads that texture back.
- `--frame-stats`' `present` column is now `drawable`: the wait for the GPU to
  finish plus the wait for a drawable. Its `calls` column reads **1** rather
  than 2, because the clear is the render pass's load action rather than a
  call of its own — an accounting change, not a new optimization.
- The gallery references were re-recorded. `colors` is byte-identical at both
  1× and 2×; the nine scenes containing text moved by 1.8–5.9% of pixels at a
  worst channel delta of 4, entirely on antialiased glyph edges — software
  rounding replaced by GPU rounding.

### Added

- A `colors-14pt-2x` gallery capture, so 2× has the same
  geometry/projection/clear/channel-order oracle 1× has.

## [0.1.0] — 2026-08-28

First tagged release. A working terminal emulator for macOS: VT parser, cell
grid with scrollback, glyph atlas, and a Metal-backed renderer, all written
from scratch on top of SDL3 and FreeType.

### Added

- DEC ANSI state machine parser (`vt.zig`) covering CSI, OSC, and escape
  dispatch.
- Cell grid with a fixed-capacity scrollback ring, alternate screen, scroll
  regions, erase and SGR handling.
- FreeType glyph rasterization into a shelf-packed atlas, with the whole
  frame submitted as one draw call.
- Key encoding with application cursor mode and xterm modifier parameters.
- 16 ANSI colors plus the generated xterm 256-color cube and grayscale ramp.
- Font size binding (`Cmd` `+`/`-`/`0`), paste with bracketed-paste support
  (`Cmd V`), clear (`Cmd K`), and wheel scrollback.
- `--font-size`, `--size`, `--shell` and `--version` flags, plus
  `--frame-stats` and `--screenshot` for measuring and capturing frames.

### Performance

Every claim below was measured before the change that produced it, and each
sprint has a record under [docs/roadmap/completed/](docs/roadmap/completed/).
`zig build bench` and `--frame-stats` are the arbiters.

- The screen is a row ring, so a line feed rotates an offset instead of
  moving the grid — 1.7–3.8× on every corpus containing a newline.
- The wait for vblank moved out of the terminal mutex. Bulk output through a
  real PTY went from 0.26–0.40 MiB/s to 41–51 MiB/s, and the lock is held
  2 µs per frame rather than roughly 8 ms.
- The frame is one `SDL_RenderGeometryRaw` call rather than 850–2,350 SDL
  calls, which took the worst-case frame build from 8–9 ms to about 0.2 ms.
- Runs of printable ASCII reach the terminal as one slice: the `ascii`
  corpus went from 111 to 481 MiB/s, and end-to-end throughput to 66 MiB/s.

Two planned sprints were retired by their own gates without being built:
shrinking the cell to 8 bytes, and per-row damage tracking.

### Known gaps

Selection and copy, reflow on resize, combining marks, Sixel/DCS rendering,
mouse reporting, ligatures, and real bold/italic faces. See the README.

[Unreleased]: https://github.com/oddurs/doot/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/oddurs/doot/releases/tag/v0.1.0
