# Working on doot

Read by every Claude Code session in this repository. These are not style
preferences; each one is here because its absence cost something.

## Never work in the shared checkout

Two agent sessions in one working copy will switch branches under each
other. This has already put a finished commit on the wrong branch, and made
a session read a file it believed was `main` and draw a wrong conclusion
about the repository. Neither is visible from inside the session it happens
to.

```sh
scripts/worktree.sh new perf/my-change   # prints the directory; work there
scripts/worktree.sh list
scripts/worktree.sh done perf/my-change
```

It always branches from `origin/main`, never from whatever happens to be
checked out. Check `git branch --show-current` before every commit anyway.

## Committing and merging

- **One PR per concern**, title prefixed: `perf:`, `fix:`, `docs:`, `ci:`,
  `bench:`, `gallery:`, `audit:`, `release:`, `guard:`.
- **Stage explicit paths.** Never `git add -A`: another session's
  uncommitted work may be sitting in the tree.
- Squash merge, delete the branch. The commit body says *why*, and states
  what was measured.
- A PR closing a sprint issue says `Closes #N`.
- A change to `.github/workflows/` needs the `gh` token to carry the
  `workflow` scope — a squash merge is a commit that modifies a workflow
  file, and GitHub refuses that from an OAuth token without it, whatever
  protocol the branch was pushed over. Check with `gh auth status`; add
  it once with `gh auth refresh -h github.com -s workflow`. The token on
  this machine has it as of 2026-08-29, so Dependabot's workflow bumps
  merge like any other PR.

## A claim carries a number, or a picture, or it is labelled a guess

The performance roadmap was written once from reading the source, and the
largest bottleneck in the program was not on it. So:

| what you changed | what decides whether it worked |
|---|---|
| parser, grid, terminal | `zig build bench` against `bench/baseline.txt` |
| anything above the renderer | `--frame-stats` in the real app |
| anything visible | `zig build gallery` |
| escape-sequence handling | `zig build audit` |

Measure **before** the change as well as after. Several sprints here were
retired by their own gate — that is the cheapest outcome available, and it
only happens if the measurement comes first.

## Test the tests

Green tests prove nothing until you have watched them fail. Deliberately
break the implementation several ways and confirm each break is caught.
Every time this has been done here, the first pass left a mutant alive.

**Instrumentation gets the same standard as what it measures.** A frame
timer with two trivial tests shipped a division by zero that crashed the
app; the code it measured had none. The tool every claim rests on is the
worst place to relax.

## Recordings

`bench/corpus/*.bin` are recordings of real programs, and a real program
prints whatever it prints. One reached a public repository carrying live
session links because it was *scanned* for the problems someone thought of
rather than made incapable of carrying any.

`zig build record` redacts as it writes and `zig build check-corpora` gates
CI. Both use `src/redact.zig`. It is a guard, not a guarantee: read a
recording before committing it.

## Before opening a PR

```sh
zig fmt --check build.zig src/
zig build test
zig build bench          # if you touched the parse path
zig build gallery        # if you touched anything visible
zig build check-corpora
```

Then have the change reviewed adversarially before merging. Every sprint
here has had a review find something the author's own testing missed, and
the reason is always the same: the author exercised it one way and
generalised.

## Operational traps

- **Never run `./zig-out/bin/doot` bare.** It opens a window and
  blocks forever. Use `--version`, `--help`, or `--shell <script that
  exits>`. `SDL_VIDEODRIVER=dummy` runs it headless.
- Rebuild before you test a claim about the binary. Running a stale
  `zig-out/bin/` binary has produced two wrong conclusions here.
- Zig 0.16 moved things: `std.Io.Dir.cwd()` (takes an `io`), not
  `std.fs.cwd()`; `main(init: std.process.Init.Minimal)` with
  `init.args.vector`, not `std.process.argsAlloc`; `std.c.write`, not
  `std.posix.write`; `dir.iterate()` then `it.next(io)`.

## Layers

`vt.zig` knows nothing about screens. `terminal.zig` does no I/O.
`grid.zig` holds no policy. `src/platform/` is glue: a C ABI, no file over
400 lines, nothing that branches on terminal state. The seams are why this
is testable without a window, and they are worth defending.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the human version, and
[docs/roadmap/](docs/roadmap/) for what is planned and what measurement
has already retired.
