# terminator

[![CI](https://github.com/oddurs/terminator/actions/workflows/ci.yml/badge.svg)](https://github.com/oddurs/terminator/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16-f7a41d.svg)](https://ziglang.org/)

A terminal emulator for macOS, written in Zig.

The VT parser, the cell grid, the scrollback, and the glyph atlas are written
here from scratch. SDL3 supplies the window, input, and a Metal-backed 2D
renderer; FreeType rasterizes glyphs. Nothing else is borrowed.

## Build

Needs Zig 0.16, SDL3 and FreeType:

```sh
brew install zig sdl3 freetype
zig build -Doptimize=ReleaseFast
./zig-out/bin/terminator
```

`zig build test` runs the suite: unit tests for the parser, grid, key encoding
and atlas, plus end-to-end tests that drive a real shell on a real PTY and
assert on the resulting screen.

## Keys

| | |
|---|---|
| `Cmd` `+` / `-` / `0` | font size |
| `Cmd V` | paste (bracketed when the app asks for it) |
| `Cmd K` | clear |
| wheel | scroll history, or arrow keys on the alternate screen |

Flags: `--font-size N`, `--size COLSxROWS`, `--shell PATH`, `--frame-stats`
(frame timing to stderr, once a second), `--screenshot PATH` (save the frame
drawn one second in, as a BMP).

## How it fits together

```
PTY ──► vt.Parser ──► Terminal ──► Renderer ──► SDL3 ──► Metal
        state          grid +       glyph
        machine        scrollback   atlas
```

| file | what it does |
|---|---|
| `vt.zig` | Paul Williams' DEC ANSI state machine. Bytes in, callbacks out. Knows nothing about screens. |
| `grid.zig` | Cells, screens, and a fixed-capacity scrollback ring. Flat arrays, no row pointers. |
| `terminal.zig` | The semantics: cursor, scroll regions, erase, SGR, alternate screen. No I/O. |
| `pty.zig` | `forkpty`, window-size signalling, non-blocking reads. |
| `font.zig` | FreeType faces and the shelf-packed glyph atlas. |
| `render.zig` | Snapshot under the lock, then one vertex buffer and one draw call for the frame. |
| `input.zig` | Keys to bytes. Application cursor mode, xterm modifier params, the lot. |
| `theme.zig` | 16 ANSI colors plus the generated xterm cube and grayscale ramp. |
| `main.zig` | Reader thread, event loop, the mutex between them. |
| `stats.zig` | The `--frame-stats` timer: lock hold, build and present per frame. |

Two threads: one reads the PTY and feeds the parser, the main thread draws.
One mutex between them, held by the main thread only long enough to copy the
viewport out — drawing and the vblank wait happen after it lets go. The reader
wakes the main thread with an SDL event rather than having it poll, so an idle
terminal uses no CPU.

## Not done yet

- **Selection and copy.** You can paste but not select. The biggest gap.
- **Reflow on resize.** Content is preserved top-left anchored; lines don't
  re-wrap when the window widens.
- **Combining marks** are dropped rather than composed onto a base character.
- **Sixel and DCS** payloads are parsed and discarded.
- **Mouse reporting** modes are tracked but events aren't forwarded.
- **Ligatures.** One glyph per cell; no HarfBuzz shaping yet.
- **Bold and italic** are synthesized from the regular face rather than loaded
  from real bold/italic faces.
- **Damage tracking.** Every frame rebuilds the whole grid into one draw
  call. Measured at ~0.2–0.4 ms per keystroke, which is why it stays that
  way — see [the retired sprint](docs/roadmap/completed/sprint-3-damage-tracking.md).

## Contributing

Bug reports and patches are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers
the build, how the test suite is split, and what a reviewable change looks
like here — the short version is that escape-sequence changes should cite the
spec, and a test that fails without your fix is worth more than a paragraph
explaining it.

The "Not done yet" list above is the feature roadmap — selection and copy is
the biggest gap. For performance work, [docs/roadmap/](docs/roadmap/) tracks
the sprints, what shipped, and what measurement retired, with `zig build bench`
as the arbiter.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). To
report a security issue, see [SECURITY.md](SECURITY.md) — please do not open a
public issue for one.

## License

[MIT](LICENSE) © Oddur Sigurdsson
