# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) — with the usual
0.x caveat that the interface may still move under you.

## [Unreleased]

Nothing yet.

## [0.1.0] — 2026-08-28

First public release. A working terminal emulator for macOS: VT parser, cell
grid with scrollback, glyph atlas, and a Metal-backed renderer, all written
from scratch on top of SDL3 and FreeType.

### Added

- DEC ANSI state machine parser (`vt.zig`) covering CSI, OSC, and escape
  dispatch.
- Cell grid with a fixed-capacity scrollback ring, alternate screen, scroll
  regions, erase and SGR handling.
- FreeType glyph rasterization into a shelf-packed atlas, with two-pass
  rendering: background runs, then glyphs.
- Key encoding with application cursor mode and xterm modifier parameters.
- 16 ANSI colors plus the generated xterm 256-color cube and grayscale ramp.
- Font size binding (`Cmd` `+`/`-`/`0`), paste with bracketed-paste support
  (`Cmd V`), clear (`Cmd K`), and wheel scrollback.
- `--font-size` and `--shell` flags.

### Known gaps

Selection and copy, reflow on resize, combining marks, Sixel/DCS rendering,
mouse reporting, ligatures, real bold/italic faces, and per-row damage
tracking. See the README.

[Unreleased]: https://github.com/oddurs/terminator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/oddurs/terminator/releases/tag/v0.1.0
