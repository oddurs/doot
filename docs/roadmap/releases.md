# Releases roadmap

What a version number promises, when one ships, and what is written next
to it. [platform.md](platform.md) covers the mechanics — bundle, signing,
DMG, cask; this covers the process those mechanics serve. Sized for one
person at 8–12 focused hours a week. Sprint prefix: **V**.

Arbiter: **the tag.** A release exists when `git tag` says so, the
changelog has a section for it, `--version` prints it, and the release
page carries an artifact a fresh Mac can open. Anything less is a draft.

## Where we are

| | Today | Where |
|---|---|---|
| Tagged releases | **None.** `git tag` is empty; `gh release list` is empty | — |
| The changelog | Records a `0.1.0` dated 2026-08-28 and links to `v0.1.0`, **which does not exist** | `CHANGELOG.md` |
| The version | `"0.1.0"`, a constant in `pty.zig` because that is where `TERM_PROGRAM_VERSION` is set. No `--version` flag | `pty.zig` `version`; `parseArgs` |
| Release workflow | Runs on a `v*` tag: builds, tars a bare binary, publishes with `--generate-notes` — a second set of notes, generated from PR titles, beside the hand-written changelog | `.github/workflows/release.yml` |
| Merge style | Squash, one PR per concern, prefixed titles (`perf:`, `docs:`, `ci:`, `bench:`) | `git log` |
| CI on `main` | `zig fmt`, Debug and ReleaseFast on macOS 14 and 15, bench (non-gating) | `.github/workflows/ci.yml` |
| Nightly or pre-release | None | — |
| Milestones | One, for the performance sprints, now closed | GitHub |
| Support statement | `SECURITY.md` says how to report; nothing says which versions get a fix | `SECURITY.md` |

The bones are right: squash merges with prefixed titles are exactly what
release notes want, and the workflow fires on a tag. What is missing is
the tag, one source of truth for the number, and a reason to cut one.

## The sprints

### V0 — Make 0.1.0 true (one day)

- **One source of truth.** The version moves to `build.zig.zon`'s
  `.version` and is threaded through a build option into `--version`,
  `TERM_PROGRAM_VERSION`, `--doctor` ([P4](platform.md)) and the
  bundle's `Info.plist` ([P0](platform.md)). `pty.zig` stops owning it.
- **`--version`** prints `terminator 0.1.0 (e0a3191)` — the tag and the
  commit, so a bug report says which build.
- **Tag it.** `v0.1.0` on the commit the changelog describes, or the
  changelog's date and link corrected to the commit that gets tagged.
  Either is honest; a changelog entry for a release that never happened
  is not.
- **The workflow checks the changelog.** `release.yml` fails if
  `CHANGELOG.md` has no section for the tag being built. The hand-written
  section becomes the release body; `--generate-notes` output goes under
  an "All changes" heading beneath it rather than replacing it.

*Done when:* `gh release list` shows `v0.1.0`, `terminator --version`
prints it, and the changelog's links resolve.

*Risk:* none. This is a day of making the repository agree with itself.

### V1 — The release train (one week)

Releases are **sprint-driven, with a monthly floor.** A tagged release
ships when a roadmap sprint lands that a user can feel; if a month
passes with merges and no sprint, a release ships anyway. Time-based
releases ship nothing; sprint-based ones ship something with a name.

- **Nightly.** Every merge to `main` builds a pre-release artifact and
  updates a rolling `nightly` GitHub pre-release. `--version` on it
  prints `0.2.0-dev+<sha>`. Until [P1](platform.md) has signing, the
  nightly is an Actions artifact, not a download link — an unsigned
  nightly is a Gatekeeper dialog, and nobody should meet the project
  through one of those.
- **The checklist**, in `docs/releasing.md`, run by the maintainer from
  `main` and nowhere else:
  1. `zig build test` green on both macOS runners.
  2. `zig build bench` against `bench/baseline.txt`: no corpus more than
     5% slower; re-record the baseline if anything is faster.
  3. The [gallery](experience.md) diff reviewed and intentional.
  4. The esctest pass count ([C0](correctness.md)) not lower than the
     last release.
  5. The changelog section written — see V3 for what goes in it.
  6. Tag, push, watch the workflow, open the artifact on a fresh Mac.
- **Stable is a nightly the maintainer has used for a week.** No
  separate beta channel; the person cutting the release is the beta.
- **Rollback** is the previous release staying downloadable — the last
  three are always on the releases page and the site
  ([W3](website.md)) links them.

*Why here:* after V0 has made the number real and before the first
sprint on the [priorities](priorities.md) order lands — X0 and A0 are
one week each, and the first release that follows them should be cut
by a process, not by hand.

*Done when:* a merge to `main` produces a nightly artifact within
fifteen minutes; `docs/releasing.md` exists; the first sprint-driven
release ships through the checklist with nothing skipped.

*Risk:* low. The workflow exists; this adds a trigger, a check and a
document.

### V2 — Versions and milestones (half a week)

What the number means while it starts with `0`:

- **Minor** (`0.2` → `0.3`): a roadmap sprint landed that a user can
  feel. Named after it.
- **Patch** (`0.2.0` → `0.2.1`): fixes only. A regression in a release
  is a patch within the week, out of the train.
- **Nothing is removed in a minor.** Escape sequences are added, never
  taken away; a config key is renamed only with the old name still
  accepted for one minor.

The [priorities](priorities.md) order maps onto milestones, each a
GitHub milestone with the sprint issues attached:

| Version | Name | Sprints | What a user notices |
|---|---|---|---|
| 0.2 | the gallery and the corpus | X0, A0, D0 | The renderer is ours; text blends in linear light. |
| 0.3 | selection | E1, D1 | You can copy. FreeType is gone. |
| 0.4 | agents see themselves | A2, D2 + X2, A1 | Agent TUIs stop flickering, emoji appear, the bell reaches you. |
| 0.5 | our window | D4, D5 + P0 | SDL is gone; one binary; an app anyone can install. **The first release worth telling people about.** |
| 0.6 | prompts | A3, E2 | The terminal knows what each command did. |
| 0.7 | tabs | A5, E5, X1 | Several agents, one window. |
| 0.8 | the record | L0, L1, L2 | Every session is recorded; scroll back into a closed `vim`; search a moment. |
| 0.9 | the transcript | L3, X9, A7, L4 | Commands as objects; the supervisor view; a session as a file you can send. |

**1.0 is a set of conditions, not a date:**

- Every item on the README's "Not done yet" list is done or explicitly
  declined on a roadmap.
- Signed and notarized; one binary; installable by cask and DMG.
- The esctest known-failure list is short enough to print in the
  release notes, and printed there.
- Someone who is not the author has used it as their daily terminal for
  a month and said so in an issue.
- The config file format is declared stable.

*Done when:* the milestones exist with their issues, `CHANGELOG.md`'s
"Unreleased" section is grouped under the next version's name, and this
table is linked from the README.

*Risk:* none, except the temptation to let the table become a schedule.
It is a map.

### V3 — Release notes people read (half a week, then per release)

The changelog section is the release body, and it has a fixed shape:

1. **What you will notice** — two to five items, each one sentence,
   the first with a gallery capture. Written for a user, not a
   contributor.
2. **Numbers** — the bench delta against the previous release and the
   `--frame-stats` figures that moved, in a table. A release that moved
   no number says so.
3. **Fixed** — regressions and bugs, each linking the issue.
4. **Known gaps** — the README's list, so nobody discovers it after
   installing.
5. **All changes** — the generated PR list, grouped by prefix.

Each item that closed a sprint links the sprint's record under
[completed/](completed/); those records are the best writing in the
repository and the notes are where people find them.

*Done when:* the next release's notes follow the shape, and the site
([W3](website.md)) renders them from the same file.

*Risk:* low.

### V4 — Support and security (half a week)

- **Supported versions:** the latest release, and nothing older, while
  the version starts with `0`. `SECURITY.md` says so.
- **A security fix** is a patch release within seven days of
  confirmation, out of the train, with a GitHub security advisory and a
  changelog line that says what was fixed once the fix is out.
- **Labels** that mean something: `bug`, `regression`,
  `release-blocker` join the existing `perf`, `sprint`, `measured`,
  `good first issue`. A `regression` is a patch-release candidate by
  definition; a `release-blocker` stops the train until it is closed.
- **The bug template asks for `--version` and `--doctor`**
  ([P4](platform.md)) before anything else.

*Done when:* `SECURITY.md` states the policy; the labels exist; the
template asks for the two flags.

*Risk:* none.

## Why this order

- **V0 first** because the repository currently describes a release that
  did not happen, and every later step assumes the number is real.
- **V1 before the first product sprint lands**, so it ships through a
  process on the first try.
- **V2 and V3 together**, since the milestone names are the release
  names and the notes are written under them.
- **V4 whenever a half-day is free**; it matters the day the first
  outside user appears, which [P0](platform.md) is timed for.

## Not on this plan

- **A beta channel.** The nightly and a week of the maintainer's use
  are the beta.
- **Long-term support branches.** Latest only, until 1.0 and probably
  after.
- **Automated version bumps from commit prefixes.** The number is a
  decision made in the changelog, not a side effect of a merge.
- **Release-day marketing.** That is [website.md](website.md)'s W4, and
  it is gated on a release worth marketing.
