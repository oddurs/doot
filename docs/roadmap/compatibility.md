# Compatibility roadmap

Other machines, and other programs. Linux, Windows and the browser on
one side; shells, multiplexers, editors and agents on the other. Sized
for one person at 8–12 focused hours a week. Sprint prefix: **M**.

Arbiter: **the CI matrix and the compatibility matrix.** A platform is
supported when its row in CI is green on every PR; a program is
supported when its recording in the replay suite ([T2](testing.md))
has a golden that passes. Neither is a claim anyone makes by hand.

The [priorities](priorities.md) say *macOS first, finished, then
elsewhere*, and that holds. What this page adds is that "elsewhere" is
designed for now — the seams that make the port a second implementation
rather than a rewrite are the seams [D4](dependencies.md) is already
drawing — and that the core is proven portable today, in CI, so the
port never has to start by discovering what was accidentally
mac-specific.

## Where we are

Measured on 2026-08-28: `zig test --test-no-exec` builds the unit-test
binaries of `vt`, `grid`, `terminal`, `input` and `theme` for
`x86_64-linux-gnu`, `x86_64-windows-gnu` and `wasm32-wasi`, from this
Mac, with no changes. The core is portable now; only the edges are not.

| | Today | Where |
|---|---|---|
| The core (`vt`, `grid`, `terminal`, `input`, `theme`, `stats`, `bench`) | `std` only. **Builds for Linux, Windows and wasm today.** Runs on the Ubuntu runner every PR, as the bench | `build.zig` bench job |
| PTY | `forkpty` from `util.h` — macOS and the BSDs. Linux has the same call in `pty.h`; Windows has ConPTY, a different shape | `pty.zig` |
| Fonts | Hard-coded `/System/Library/Fonts` paths; FreeType | `font.zig` `font_candidates` |
| Window, input, GPU | SDL3 — portable, and being replaced by AppKit and Metal ([D4](dependencies.md)) behind a `Platform` interface | `main.zig`, `render.zig` |
| Windows | Named as "a different program" in [platform.md](platform.md). **Revised here:** the core is the same program; the platform layer is different, which is what the platform layer is for | — |
| Linux | Gated in [P5](platform.md) on the Mac experience being complete. Still true; this page is the plan for when the gate opens | — |
| Programs | Verified by use: zsh, `vim`, `less`, `htop`, `tmux`. No matrix, no recordings | — |
| Terminfo | `xterm-256color`; `TERM_PROGRAM=terminator` | `pty.zig` |

## What "platform" means on each OS

The [ownership rule](dependencies.md) — link only the platform — needs
a definition per platform, written down before anyone links a
convenience.

| | Window and input | GPU | PTY | Fonts | Notify |
|---|---|---|---|---|---|
| macOS | AppKit | Metal | `forkpty` (libc) | scan `/System/Library/Fonts`, `~/Library/Fonts` | UserNotifications |
| Linux | `libwayland-client`, `libxkbcommon`; XWayland covers X11 | OpenGL via EGL — Mesa is the platform's GL; Vulkan only if a number asks | `forkpty` (glibc/musl) | scan the XDG font dirs, `~/.fonts` — no fontconfig, we parse `name` tables ourselves | D-Bus `org.freedesktop.Notifications`, via a subprocess to `notify-send` first |
| Windows | Win32 (`user32`), IMM32 for IME | Direct3D 11, HLSL compiled at runtime by `d3dcompiler_47` — no build tool | ConPTY (`CreatePseudoConsole`) | scan `C:\Windows\Fonts` | `FlashWindowEx`; toasts later |
| Browser | a 200-line JS harness | `<canvas>` | none — a scripted source | the browser's | none |

Everything in the table is shipped by the OS or its display stack.
Nothing is fetched, vendored or built from a third party.

## The sprints

### M0 — Prove the core is portable, on every PR (half a week)

- **Cross-compile in CI.** The Ubuntu job builds the unit tests for
  `x86_64-linux`, `aarch64-linux`, `x86_64-windows` and `wasm32-wasi`,
  and runs the Linux ones natively. The Windows ones run on a
  `windows-latest` row. None of this needs a display or a PTY.
- **End-to-end on Linux.** [T0](testing.md) drops SDL from the e2e
  module and switches `pty.zig` to `pty.h` under Linux; the Ubuntu row
  gains the e2e suite.
- **A `Platform` and a `Pty` seam, named.** Not implemented for a new
  OS — just the two interfaces D4 is defining, with a comment on each
  saying what a second implementation may assume. The seam exists so
  M2 and M3 are second implementations.

*Why here:* half a week, and it turns "the core is portable" from a
sentence into a check. After it, nothing mac-specific can creep into
`vt`, `grid`, `terminal` or `input` without a red row.

*Done when:* the CI matrix has Ubuntu and Windows rows for the core,
and a deliberate `@cImport("util.h")` in `terminal.zig` fails them.

*Risk:* none.

### M1 — The headless platform (half a week, with C0)

A third implementation of `Platform`, `platform/headless.zig`: no
window, no GPU, a fake clipboard, events from a script. It is what
[C0](correctness.md)'s conformance harness, [T2](testing.md)'s replay
mode, [A6](agentic.md)'s `--headless` and the browser build all drive.
The renderer's vertex buffer still gets built — the gallery's diff
needs it — and `gpu_read_pixels` returns a CPU rasterization of the
quads, which is a few dozen lines since every quad is an axis-aligned
rectangle over one texture.

*Done when:* `zig build test` runs the e2e suite and the gallery
against the headless platform on Linux with no display.

*Risk:* low.

### M2 — Linux (three to four weeks) — **gated**

Wayland-native, with XWayland for the X11 case rather than a second
backend; a from-scratch X11 client is a second sprint's worth of code
for a shrinking audience.

- `platform/wayland.c`: `xdg-shell` for the window, `wl_seat` keyboard
  through `xkbcommon` for keymaps, `text-input-v3` for IME,
  `fractional-scale-v1` and `viewporter` for the 1.5× case,
  `wl_data_device` for the clipboard, `cursor-shape-v1` for the I-beam.
  The protocol XML is committed and the C bindings generated at build
  by `wayland-scanner`, which is a tool, not a link.
- `platform/gpu_gl.c`: the same six functions as `gpu.m`, over EGL and
  OpenGL 3.3 core. The shader is GLSL compiled at runtime from a string
  — the same choice D0 made for Metal, for the same reason: no shader
  compiler in the build.
- Fonts: [D1](dependencies.md)'s discovery scans
  `/usr/share/fonts`, `/usr/local/share/fonts`, `~/.local/share/fonts`
  and `~/.fonts`; the default family list is DejaVu Sans Mono,
  Liberation Mono, Noto Sans Mono, Cascadia Code — all `glyf`.
- Notifications through `notify-send` as a subprocess; a hand-written
  D-Bus client is on the list only if that proves inadequate.
- Packaging: a tarball and an AppImage from the release workflow;
  Flatpak when someone asks; distro packages never from here.

*Gate:* every sprint labelled "next" on [experience.md](experience.md)
landed, and someone on Linux has asked in an issue. Both.

*Done when:* the e2e suite, the gallery and the replay suite are green
on the Ubuntu row *with* the Wayland platform under a headless
compositor; a Linux user has run it for a week and filed what they
found.

*Risk:* medium to high. IME under `text-input-v3` and fractional
scaling are the two places Wayland clients go wrong; both have a
gallery capture or an e2e test waiting for them.

### M3 — Windows (four to six weeks) — **gated**

The largest port, because the PTY is a different shape and the input
model is too.

- `pty_win.zig`: `CreatePseudoConsole` with a pair of pipes,
  `ResizePseudoConsole`, `ClosePseudoConsole`; the child is started
  with the pseudo-console attribute on its `STARTUPINFOEX`. ConPTY
  speaks VT on both sides, so `vt.Parser` and `input.zig` are
  unchanged — which is the point of ConPTY.
- `platform/win32.c`: a window class, `WM_KEYDOWN`/`WM_CHAR` to
  `input.zig`, IMM32 composition for IME, per-monitor-v2 DPI
  awareness, the clipboard, `WM_MOUSEWHEEL` with precise deltas.
- `platform/gpu_d3d11.c`: the same six functions, over a swap chain,
  with the HLSL compiled at runtime.
- Fonts: scan `C:\Windows\Fonts`; defaults Cascadia Mono, Consolas —
  both `glyf`. Windows users expect ClearType's weight; D0's linear
  blending plus [X1](experience.md)'s measured darkening is the answer,
  and the gallery says whether it is enough.
- The shell: PowerShell by default, `cmd` and WSL by config. `TERM` is
  not a Windows convention; `TERM_PROGRAM` still is ours to set.
- Packaging: a zip and a `winget` manifest; MSIX if anyone asks.
  Authenticode signing costs money and is a decision for then.

*Gate:* M2 shipped, and someone on Windows has asked.

*Done when:* the same three suites are green on the Windows row; a
Windows user has run it for a week.

*Risk:* high. IMM32 and the ConPTY resize dance are the known traps.

### M4 — The core in a browser: the player (one week)

`vt`, `grid` and `terminal` compile to `wasm32` today. A 200-line JS
harness feeds a session file ([L4](record.md)) in, calls `feed` from
checkpoint to checkpoint, and paints the grid to a `<canvas>` from an
exported cell array, with a scrubber. This is **the player**: the
reader of the record that runs where nothing is installed — a colleague
opens the exported transcript in a tab. Typing into a live core is the
same page with a keyboard attached.

On the website ([W5](website.md)) it is a page of its own — the site's
no-script rule holds everywhere else.

It is also a portability proof with teeth: a `std` feature that does
not exist on `wasm32` fails the build.

*Why here:* no longer gated as a demo; it is L4's second reader and the
reason sessions-as-files are worth exporting. After L1, whose
checkpoint format it consumes.

*Done when:* an exported session plays in the browser with the same
grid at every checkpoint as the app shows, and the `altscreen` corpus
matches the golden.

*Risk:* low.

### M5 — The compatibility matrix (ongoing, derived)

`docs/compatibility.md`, generated — not written — from the replay
suite ([T2](testing.md)): one row per recording, one column per
platform, a cell that says *golden passes* or links the failing
sequence. Rows to record first:

- shells: zsh, bash, fish, nushell; PowerShell on Windows
- multiplexers: tmux, zellij, screen
- editors: vim, neovim, helix, `emacs -nw`
- TUIs: htop, btop, lazygit, k9s
- agents: the [A0](agentic.md) recordings
- transports: over `ssh`, over `mosh`, inside tmux over ssh

A row is added by adding a recording; a row goes green by fixing what
the golden shows. The page says when it was generated and from which
commit.

*Done when:* the page exists and is regenerated by CI on every merge.

*Risk:* none, as long as nobody edits it by hand.

## Why this order

- **M0 now**, because it is half a week and it fences the core.
- **M1 with C0**, because they are the same binary.
- **M2 and M3 gated**, per the priorities, and in that order — Linux is
  a second implementation of seams that exist; Windows also changes the
  PTY.
- **M4 after L1**, as the record's second reader.
- **M5 as soon as T2 has recordings**; it is a report, not a sprint.

## Not on this plan

- **GTK, Qt, or any toolkit.** The platform layer talks to the display
  server, as it talks to AppKit on the Mac.
- **A native X11 backend.** XWayland.
- **iOS, Android, the Apple TV.** No shell to run.
- **Supporting a program by special-casing it.** If `tmux` needs a
  sequence, the sequence is implemented per its spec and every program
  gets it; nothing checks `TERM_PROGRAM` of the child.
- **Distro packaging.** Tarball, AppImage, cask, zip. Package
  maintainers know their distributions better than this repository
  does.
