# Contributing

Thanks for looking. terminator is a from-scratch terminal emulator, so most
changes touch code with a spec behind it. That shapes how this repo works.

## Getting set up

```sh
brew install zig sdl3 freetype pkg-config
git clone https://github.com/oddurs/terminator
cd terminator
zig build
zig build test
```

Zig 0.16 exactly — `build.zig.zon` pins it as the minimum, and the language
still moves enough between releases that an older compiler will not build this.

Day to day:

```sh
zig build run -- --font-size 16   # run it
zig build test                    # unit + end-to-end
zig build bench                   # performance, always ReleaseFast
zig fmt build.zig src/            # before every commit
```

`zig build bench` needs neither SDL nor a window — `vt`, `grid` and
`terminal` import nothing but `std`. The corpora under `bench/corpus/` are
committed files so a number from today is comparable with one from a year
ago; regenerate them only to add or deliberately change one, since doing so
voids every baseline that came before. `bench/baseline.txt` is the number to
beat.

## What the code expects of you

**Cite the spec.** The VT parser follows Paul Williams' DEC ANSI state
machine; the escape sequences follow xterm's `ctlseqs` and ECMA-48. If you
change how a sequence is handled, say in the PR which document says so. "It
matches what iTerm does" is evidence, not an argument — other terminals have
bugs too.

**Test at the right layer.** The suite is split deliberately:

| where | for what |
|---|---|
| `src/unit_tests.zig` | Pure logic: parser transitions, grid arithmetic, key encoding, atlas packing. Fast, no I/O. |
| `src/tests.zig` | End-to-end: a real shell on a real PTY, asserting on the resulting grid. No window is opened. |

A parser fix belongs in the unit tests. A "this program renders wrong" fix
usually belongs in the e2e tests, driven by the bytes that program emits.
Adding a module? Add it to `unit_tests.zig` too — Zig only analyzes imports
something references, so tests in an unreferenced module silently never run.

**Keep the layers apart.** `vt.zig` knows nothing about screens. `terminal.zig`
does no I/O. `grid.zig` holds no policy. The seams are the reason the thing is
testable without a window, and they are worth defending.

**Match the surrounding style.** Four spaces, `zig fmt` clean, comments that
explain why rather than what. The existing comments are the reference.

## Pull requests

- Branch off `main`, one concern per PR.
- Make sure `zig build test` and `zig fmt --check build.zig src/` pass — CI
  runs both on macOS 14 and 15, in Debug and ReleaseFast.
- Fill in the PR template. The "how it was verified" section is the part
  reviewers actually read first.
- A test that fails without your change is the most persuasive thing you can
  include.

## Good places to start

Two lists, depending on what you enjoy.

For **features**, the README's "Not done yet" list is roughly ordered by how
much people miss them. Selection and copy is the biggest gap; combining marks
and ligatures are the deepest.

For **performance**, [ROADMAP.md](ROADMAP.md) sequences six sprints against
bottlenecks located in the source, and says why they are in that order. Start
with the numbers from `zig build bench` — a perf PR without a before-and-after
is hard to review and easy to get wrong.

Before starting something large, open an issue and say what you plan to do —
it is a small project and it would be a shame to duplicate work.

## Reporting bugs

Escape-sequence bugs are far easier to fix when the report is bytes rather
than prose. If you can reduce it to a `printf '\e[...'` that misbehaves, that
alone usually locates the fix.
