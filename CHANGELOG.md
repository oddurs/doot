# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with the usual
0.x caveat that the interface may still move under you.

## [Unreleased]

### Added

- **Every session is recorded to disk, and it is on by default.** One
  append-only `.trec` file per session under `~/Library/Application Support/
  terminator/sessions/`, holding every byte the session printed with the time
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

[Unreleased]: https://github.com/oddurs/terminator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/oddurs/terminator/releases/tag/v0.1.0
