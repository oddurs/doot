# Roadmap

## Live plans

[priorities.md](priorities.md) ranks the product priorities, says which
roadmap owns what, draws the dependencies between them, and proposes the
order of the next twelve sprints. Each roadmap has its own arbiter — the
thing that decides whether a sprint is done — and opens by building it.

- [performance.md](performance.md) — the performance sprints. Six planned,
  five done, two retired by measurement, none open.
- [experience.md](experience.md) — beautiful by default: typography, glyph
  coverage, cursor and motion, colour, native chrome. Judged by screenshots.
- [agentic.md](agentic.md) — a terminal for working with agents: attention,
  the modern-TUI protocol, semantic prompts, links, tabs. Judged against
  recorded agent sessions.
- [essentials.md](essentials.md) — selection, mouse, search, reflow, config,
  keys, scrollback. Judged by the end-to-end suite.
- [correctness.md](correctness.md) — VT conformance, Unicode, identity,
  robustness. Judged by esctest, vttest and the fuzzer.
- [platform.md](platform.md) — app bundle, signing, distribution, updates,
  diagnostics. Judged on a fresh Mac.
- [dependencies.md](dependencies.md) — own the GPU path, the rasterizer,
  the shaper and the window, until the binary links only libc and the
  system frameworks. Judged by `otool -L` and the gallery.
- [releases.md](releases.md) — what a version promises, the release
  train, milestones, notes, support. Judged by the tag.
- [website.md](website.md) — the marketing site on GitHub Pages, rendered
  from what the repository already produces. Judged by a fresh visitor
  and Lighthouse.
- [security.md](security.md) — the threat model and the reply policy,
  paste guard, memory safety in the release build, a build you can
  check. Judged by the policy table and the fuzzer.
- [testing.md](testing.md) — the layers, the differential model, fuzzing,
  replay of real programs, gating the bench. Judged by CI under five
  minutes with every other arbiter in it.
- [compatibility.md](compatibility.md) — Linux, Windows and the browser,
  what "platform" means on each, and the program matrix. Judged by the
  CI matrix.
- [record.md](record.md) — the concept under the rest: the terminal is a
  log and the screen is a view of it. Recording, checkpoints and seek,
  search over time, the transcript, sessions as files, the window as a
  client. Judged by materialization — any screen reproduced from the
  log, bit-identical.

## Completed and retired

Each record says what was proposed, what was measured, and what it changed
about the plan. The two retired ones are the most useful of the seven.

| Record | Outcome |
|---|---|
| [Sprint 0 — benchmarks](completed/sprint-0-benchmarks.md) | Built the harness. Immediately falsified the plan that commissioned it. |
| [Sprint R — screen row ring](completed/sprint-r-screen-ring.md) | 1.7–3.8×. Was not on the roadmap at all. |
| [Sprint 1 — vsync out of the lock](completed/sprint-1-vsync-lock.md) | ~150× on bulk output. Brought the frame timer the bench could not. |
| [Sprint 2 — one draw call](completed/sprint-2-one-draw-call.md) | 2 calls per frame; worst-case build ~40× better. Premise was partly wrong. |
| [Sprint 4 — printable-run fast path](completed/sprint-4-print-run.md) | 4.3× on `ascii`. One mutant survived the first tests and got its own. |
| [Sprint 3 — damage tracking](completed/sprint-3-damage-tracking.md) | **Retired.** Gate failed: a keystroke costs ~0.4 ms of build. |
| [Sprint 5 — shrink the cell](completed/sprint-5-cell-size.md) | **Retired.** Gate failed; three weeks of work never started. |

## Tracking

Open sprints live as GitHub issues under the
[Performance sprints](https://github.com/oddurs/terminator/milestone/1)
milestone. The issues carry the current detail; this directory carries the
reasoning and the history.

## How a sprint gets added

A sprint needs a corpus and a number, not an argument. Add a generator to
`bench/gen_corpus.py`, regenerate — the per-corpus seeding keeps existing
corpora byte-identical when you add one — and show the before and after.

A sprint may also carry a **gate**: a condition that must hold for the work to
be worth starting. Gates are how a plan retires work instead of only
accumulating it. Sprint 5's gate failed, and that was the cheapest outcome on
the whole plan.
