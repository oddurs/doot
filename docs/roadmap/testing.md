# Testing roadmap

How we know it works. Every roadmap in this directory names an arbiter —
a bench, a gallery, a corpus, a harness — and this page is where those
arbiters are built, kept fast, and made to run on every PR. Sized for
one person at 8–12 focused hours a week. Sprint prefix: **T**.

Arbiter: **CI, under five minutes, on every PR,** with every other
roadmap's arbiter reporting in it. A test that only runs on the
maintainer's machine is a test that runs when the maintainer remembers.

## The layers

The suite is split by what each layer can see, and the split is
deliberate — CONTRIBUTING.md already says which layer a fix belongs
in. This page adds what each layer is *for*.

| Layer | Sees | Catches | Speed |
|---|---|---|---|
| Unit (`test` blocks in each module) | One module, no I/O | Parser transitions, grid arithmetic, key encoding | seconds |
| Differential | `Terminal` against a naive reference model | Anything the ring, the run fast path or reflow gets wrong that a hand-written test did not think of | seconds |
| Golden | A corpus through `Terminal`, the final grid hashed | Any change to terminal semantics, intended or not | seconds |
| End-to-end (`tests.zig`) | A real shell on a real PTY | Everything below the renderer, as a program would experience it | tens of seconds |
| Gallery ([X0](experience.md)) | Rendered frames at 1× and 2× | Anything visual | a minute |
| Conformance ([C0](correctness.md)) | esctest against the headless terminal | The spec | a minute |
| Fuzz | Random bytes into every parser of untrusted input | Crashes, hangs, invariant violations | a minute in CI, hours locally |
| Bench | Throughput and frame timing | Regressions in speed | a minute |

## Where we are

| | Today | Where |
|---|---|---|
| Unit tests | 61 across six modules, in-module `test` blocks | `vt` 12, `terminal` 20, `grid` 13, `input` 10, `font` 4, `theme` 2 |
| End-to-end | 8, on a real shell and PTY. **macOS only**, because the module links SDL3 although `tests.zig` imports only `vt`, `grid`, `terminal` and `pty` | `build.zig` `e2e_mod` |
| Bench | Six corpora, headless, ReleaseFast, on the Linux runner; **non-gating** because a shared runner is too noisy | `ci.yml` bench job |
| A checksum | `zig build bench` already prints a checksum of the final grid state across every corpus — **a golden test nobody asserts on** | `bench/baseline.txt` last line |
| Differential model | Built in review for Sprint R (400 seeds × 200 ops against a naive reference), **not committed** | [sprint R record](completed/sprint-r-screen-ring.md) |
| Mutation testing | Done by hand once, seven mutants, one survived until a test was added; **not repeatable** | same |
| Fuzzing | None | — |
| Gallery, conformance | Not yet ([X0](experience.md), [C0](correctness.md)) | — |
| CI matrix | `zig fmt`; Debug and ReleaseFast on macOS 14 and 15; bench on Ubuntu. No ReleaseSafe, no Linux tests, no Windows | `ci.yml` |
| CI time | ~2 m 20 s for the slowest job | recent runs |
| Coverage | None | — |
| Flake policy | None needed yet; none written | — |

Two of the most valuable tests this project has ever run — the
differential model and the mutants — exist only in a markdown record.
T0 is about that.

## The sprints

### T0 — Commit what already proved things (one week)

- **The differential model.** A `RefTerminal` in `src/test/ref.zig`: a
  plain 2-D array of cells with the obvious implementation of every
  operation — scroll by copying, insert by shifting, no ring, no fast
  path. A test drives `Terminal` and `RefTerminal` with the same random
  operation stream (seeded, so a failure is a seed number) and compares
  grids after every step. This is the test that would have caught a
  wrong ring rotation before Sprint R's reviewer had to build it, and it
  is the test every future data-structure sprint — reflow
  ([E4](essentials.md)), the cluster table ([C2](correctness.md)), the
  region ring ([#12](https://github.com/oddurs/terminator/issues/12)) —
  gets for free.
- **The golden checksum.** The number `zig build bench` prints becomes
  `test "corpora produce the recorded grid state"`, with the expected
  value in the test. An intentional semantic change updates it in the
  same PR, with the reason; an unintentional one fails.
- **The mutants, as a script.** `bench/mutants/` holds one patch per
  mutation from the Sprint R record; `zig build mutants` applies each,
  runs the suite, and fails if any mutant *passes*. Seven to start.
- **End-to-end on Linux.** Drop the SDL link from `e2e_mod`, switch
  `pty.zig`'s include to `pty.h` under Linux, and add the Ubuntu row.
  The bench already proves the core runs there; the e2e suite proves the
  PTY layer does.

*Why here:* the highest-value tests on any roadmap, and the only ones
that already exist.

*Done when:* `zig build test` runs the differential model for 1,000
seeds in under five seconds; the checksum is asserted; `zig build
mutants` kills all seven; e2e is green on Ubuntu.

*Risk:* low. The reference model is deliberately naive; the risk is
making it clever.

### T1 — Fuzzing in CI (one week)

`zig build fuzz` with `std.testing.fuzz`, one target per parser of
bytes the user did not type — the list [S2](security.md) owns:
`vt.Parser` into `Terminal`, the config parser, the font parser, the
PNG decoder, the GSUB reader, the remote-control protocol, each added
the sprint its parser lands.

Invariants, checked after every input: no panic; cursor in bounds;
every `.wide` followed by a `.spacer` and every `.spacer` preceded by a
`.wide`; `pending_wrap` implies the last column; `view_offset ≤
scrollback.len`; the differential model agrees. Seeds are the bench
corpora and the agent recordings, so the fuzzer starts from real input
rather than noise.

**A crash becomes a test.** The fuzzer writes its reproducer to
`src/test/fuzz-regressions/<hash>.bin`, and a test replays every file
in that directory. A bug found by fuzzing can never come back unnoticed.

One minute per target in CI; the maintainer's machine runs longer.

*Done when:* CI shows a fuzz job per target; the regression directory
exists with at least one file in it (there will be one).

*Risk:* low.

### T2 — Replay: real programs, headless (one to two weeks)

A `replay` mode of the headless terminal ([C0](correctness.md)):
feed a recording at its recorded timing, or as fast as possible, and
dump the grid at the end or at marks. Two uses:

- **TUI smoke tests.** Recordings of `vim`, `less`, `htop`, `tmux` and
  the agent CLIs from [A0](agentic.md) doing a fixed task, each with a
  golden final grid. When a sequence's handling changes, every program
  that uses it says so at once. The recordings are also the bench's
  seventh-through-twelfth corpora.
- **The compatibility matrix** ([M5](compatibility.md)) derives its
  rows from this suite instead of from memory.

*Why here:* after C0 has the headless binary, and after A0 has the
first recordings.

*Done when:* ten recordings with goldens run in under thirty seconds;
a deliberately broken `DECSTBM` fails the `vim` and `tmux` rows and no
others.

*Risk:* low to medium. Timing-dependent programs need the "as fast as
possible" mode to be deterministic; if one is not, it is recorded
without timing.

### T3 — Gating the bench (half a week)

The bench is non-gating because a shared runner's absolute numbers are
noise. Ratios are not: the job builds **both** the PR and its merge
base, runs them alternately in the same process lifetime, and compares.
The noise cancels; a 10% regression on any corpus fails the check, and
a 10% improvement posts a comment asking whether the baseline should
be re-recorded.

`--frame-stats` stays local — a runner with no display cannot measure
present — but `build` can be measured headless once
[D0](dependencies.md) can render to an offscreen texture, and joins the
ratio check then.

*Done when:* a PR that adds a `std.mem.copyForwards` back into
`scrollUp` fails CI.

*Risk:* low. If the ratio approach is still noisy, the threshold moves
before the idea is abandoned.

### T4 — Hygiene (ongoing, half a day a sprint)

- **A time budget**, enforced: unit under 5 s, e2e under 30 s, the
  whole CI under 5 minutes. A test that breaks the budget is optimised
  or moved to a nightly job, never tolerated.
- **A flake policy**, written before the first flake: a flaky test is a
  bug with a one-week deadline, CI has no retry, and a test may be
  skipped only with an issue number in the skip.
- **Coverage** on Linux via `kcov` over the test binaries — Zig emits
  the DWARF it needs — reported per module, non-gating, so an untested
  path is at least visible.
- **Every roadmap arbiter in one summary.** The PR summary shows: tests,
  bench ratio, gallery diffs, esctest count, fuzz status. One place to
  look.

*Done when:* the PR summary is that one place.

## Why this order

- **T0 first**, because the tests are already designed and the review
  that designed them is the most careful work in the repository.
- **T1 with S2**, since the fuzz list is the security roadmap's.
- **T2 after C0 and A0** provide the binary and the recordings.
- **T3 as soon as one perf PR would have benefited** — which, given the
  history, is the next one.
- **T4 is a habit**, not a sprint.

## Not on this plan

- **A mocking framework.** The seams are real: the parser takes any
  handler, the terminal does no I/O, the renderer draws a copy.
  Nothing needs mocking.
- **Property-based testing beyond the differential model.** The model
  *is* the property; a second framework would be a second way to say
  it.
- **UI automation on the real window.** The gallery renders frames
  headless; the e2e suite drives the PTY. What is left — clicking on a
  menu — is [D4](dependencies.md)'s acceptance checklist, by hand.
- **100% coverage.** The number is reported so gaps are visible, not so
  they are filled for their own sake.
