# Sprint V0 — Make 0.1.0 true

**Done.** Shipped in [#24](https://github.com/oddurs/terminator/pull/24), with
[#25](https://github.com/oddurs/terminator/pull/25) and
[#26](https://github.com/oddurs/terminator/pull/26) fixing what it exposed.

Written late: V0 shipped without a record while every other sprint got one,
which is its own small lesson about doing the cheap sprint quickly and
skipping the part that outlives it.

## What was proposed

The repository described a release that had not happened. `CHANGELOG.md`
carried a `0.1.0` section linking to a `v0.1.0` tag; `git tag` was empty and
`gh release list` was empty. The version was a string constant in `pty.zig`,
because that is where `TERM_PROGRAM_VERSION` is set, and there was no
`--version` flag.

Four things: one source of truth for the number, a `--version` that prints
it with the commit, a tag, and a workflow that refuses to publish a tag the
changelog does not describe.

*Stated risk: none. "This is a day of making the repository agree with
itself."*

## What shipped

`build.zig.zon`'s `.version` is the source of truth. `build.zig` imports the
zon, reads it, and hands it to `src/version.zig` as a build option along
with the short commit from `git rev-parse`. `pty.zig` imports it rather than
keeping a copy, so `TERM_PROGRAM_VERSION` and `--version` cannot disagree.

`scripts/changelog-section.sh` extracts a version's section and fails when
there is none, so `release.yml` refuses a tag the changelog does not
describe, and the hand-written section becomes the release body with the
generated PR list beneath it rather than instead of it.

## The interesting part: tagging ran code that had never run

The stated risk was "none". That was wrong in a way worth recording,
because the reason generalises.

**`release.yml` had never once executed.** It fires on a `v*` tag and no tag
had ever been pushed. The very first release build failed:

```
src/pty.zig:13:11: error: C import failed
cimport.h:1:10: error: 'util.h' not found
```

It passed `-Dtarget=aarch64-macos`, which stops Zig using the macOS SDK's
header search paths, so `@cImport` of `<util.h>` — where `forkpty` lives —
could not resolve. CI's own test job builds without `-Dtarget` and had
always passed. A cross-compile was never possible here anyway, as the
matrix comment in the same file already said.

**Then the published checksum could not verify itself.** The `.sha256`
recorded the path the file had on the runner:

```
40b3347e…  dist/terminator-v0.1.0-aarch64-macos.tar.gz
```

Both assets land side by side wherever they are downloaded, so
`shasum -a 256 -c` went looking for a `dist/` directory that does not
exist. Found by downloading the release and checking it the way a user
would, which is the only way it could have been found.

**A CI path that has never executed is not tested, however green the badge
is.** That is the sentence worth keeping. Two of this repository's
workflows had a job that had never run: the release build, and — later —
the release's own artifact verification. Both were wrong.

## What review found

Seven defects, all fixed before merge. Two mattered:

**Nothing coupled the tag to the compiled version.** The gate checked the
changelog and nothing checked `build.zig.zon`, so a `v0.2.0` tag could have
shipped a binary reporting `0.1.0` — precisely the drift that having one
source of truth exists to remove. `scripts/zon-version.sh` and a comparison
in `release.yml` close it, and the release build now also runs `--version`
on the built binary and fails if it disagrees with the tag.

**A `## ` line inside a fenced code block truncated the release body, and
exited 0 while doing it.** A gate that fails open is worse than no gate.
Fences are tracked now.

Also: `--version` wrote to **stderr**, so `v=$(terminator --version)` was
empty — the one machine-readable thing the sprint added could not be
captured. `gitCommit` reported an *enclosing* repository's HEAD, because
`rev-parse` walks up out of the build root, so a source tarball unpacked
inside someone's working tree was stamped with their commit. `--short=7`
was asserted as exactly seven characters, which git documents as a minimum.

The gates are shell, so `zig build test` cannot see them, and they decide
what ships — `scripts/test-changelog-section.sh` gives them 17 assertions
and CI a step to run them.

## Done when

> `gh release list` shows `v0.1.0`, `terminator --version` prints it, and
> the changelog's links resolve.

All three, verified by downloading the published artifact: it extracts, runs,
and reports `terminator 0.1.0 (02c68ec)` — the exact tagged commit. Both
changelog links return 200.

## The lesson for the next V sprint

The sprint that makes a repository agree with itself is the one that
executes code nobody has executed. Budget for what it finds rather than for
what it does: the day of work was a day; the two CI bugs it uncovered were
the reason the day was worth spending.
