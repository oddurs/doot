# Roadmap

## Live plans

- [performance.md](performance.md) — the performance sprints. Six planned,
  three done, one retired by measurement, three open.

Feature gaps (selection, reflow, ligatures, mouse reporting) are tracked in
the README's "Not done yet" list rather than here; they need design more than
they need sequencing.

## Completed and retired

Each record says what was proposed, what was measured, and what it changed
about the plan. The retired one is the most useful of the four.

| Record | Outcome |
|---|---|
| [Sprint 0 — benchmarks](completed/sprint-0-benchmarks.md) | Built the harness. Immediately falsified the plan that commissioned it. |
| [Sprint R — screen row ring](completed/sprint-r-screen-ring.md) | 1.7–3.8×. Was not on the roadmap at all. |
| [Sprint 1 — vsync out of the lock](completed/sprint-1-vsync-lock.md) | ~150× on bulk output. Brought the frame timer the bench could not. |
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
