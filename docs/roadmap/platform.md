# Platform roadmap

Shipping: install, update, trust. The experience roadmap decides how the
terminal looks once open; this one decides how it gets onto the machine.
Sized for one person at 8–12 focused hours a week. Sprint prefix: **P**.

Arbiter: **a fresh Mac.** Download, open, type. Every sprint here is done
when that works one step further with nothing the user did not expect.

## Where we are

| | Today | Where |
|---|---|---|
| Release artifact | A bare binary in a tarball | `.github/workflows/release.yml` |
| Runtime dependencies | **Dynamically linked to Homebrew's SDL3 and FreeType.** The tarball runs only on a machine that has run `brew install sdl3 freetype` | `build.zig` `linkSystemLibrary` |
| App bundle | None. No icon, no Dock presence beyond SDL's default, no `Info.plist` | — |
| Signing, notarization | None. Gatekeeper refuses it on first open | — |
| Architectures | Apple Silicon only, because the build depends on the runner's brew kegs | `release.yml` matrix comment |
| Homebrew | No formula, no cask | — |
| Updates | None | — |
| Version | `pty.zig` `version = "0.1.0"`, exported to children as `TERM_PROGRAM_VERSION`; no `--version` flag | `pty.zig`, `parseArgs` |
| Diagnostics | `--frame-stats`. Nothing that says which font, renderer, scale or config was loaded | `stats.zig` |
| Issue templates | Exist; do not ask for anything the app can print | `.github/ISSUE_TEMPLATE/` |

The release workflow is good scaffolding and it produces something only a
developer can run. That is the gap.

## The sprints

### P0 — The bundle, and owning the build (one to two weeks)

- **No dylibs to ship.** [D5](dependencies.md) leaves the link line at
  libc and system frameworks, so there is nothing to bundle in
  `Contents/Frameworks` and nothing for Homebrew to have installed. If
  P0 is pulled ahead of D1 and D4 — a second user appears early — the
  interim answer is bundling the two dylibs with `install_name_tool`,
  written so it can be deleted, not made good.
- **`terminator.app`.** `Info.plist` with a bundle id
  (`com.oddurs.terminator` — the name is shared with a well-known GNOME
  terminal, so the id and the cask name have to disambiguate),
  high-resolution capable, minimum system version, the document types
  none. A `zig build bundle` step that produces it, used by the release
  workflow.
- **The icon.** Designed, in the [experience](experience.md) sense; it
  lands here because this is where it is first seen.
- **`--version`**, from one source of truth that `build.zig` stamps into
  both the binary and the plist.

*Why here:* the moment a second person should try it. The
[priorities](priorities.md) order puts this eighth and says it moves to
first the day that person appears.

*Done when:* a fresh Mac with no Homebrew downloads the zip, drags the app
to Applications, and it opens. Gatekeeper will still complain until P1;
that is the one remaining click.

*Risk:* low once D5 has landed; medium if pulled ahead of it, because
then it is a dylib-bundling exercise that D5 later deletes.

### P1 — Sign and notarize (one week)

Developer ID certificate in the repository secrets, `codesign` with the
hardened runtime, `notarytool submit --wait`, staple. No entitlements
beyond the defaults — a PTY needs none. The release workflow does all of
it on a tag.

*Done when:* the fresh Mac opens the app with no right-click, no System
Settings visit, no dialog.

*Risk:* low, and mostly Apple's paperwork.

### P2 — Distribution (one week)

- **A DMG** with a drag-to-Applications background, from the release
  workflow.
- **A Homebrew cask.** The name question from P0 settles here.
- **Release notes and versioning** are [releases.md](releases.md)'s:
  the changelog section is the release body (V3), and what a minor or
  patch means, and what 1.0 requires, is written there (V2).

*Done when:* `brew install --cask <name>` produces the same app as the
DMG, and the release page carries notes a user can read.

*Risk:* low.

### P3 — Updates (one week, then gated)

First, the minimal version: on launch, at most once a day, fetch the
latest release tag from GitHub and, if it is newer, show one line in the
grid — *terminator 0.4 is available* — with the release page a click
away. No download, no install, no code that runs anything. Off by a
config key.

Sparkle — in-app download and install — is the industry answer and needs
an Objective-C shim, an appcast and an EdDSA key. **Gated** on users
asking for it; the one-line check covers most of the value at none of the
surface.

*Done when:* a machine running the previous release sees the line within
a day of a tag, and a machine with the key set never makes the request.

*Risk:* low. The request is the only network call the app makes, and the
config key is documented as such.

### P4 — Diagnostics (one week)

- **`terminator --doctor`** prints the font found and its path, the SDL
  renderer and driver, display scale and refresh rate, `TERM` and
  `TERM_PROGRAM`, the config path and every parse error in it, the
  Unicode and terminfo versions from [C3](correctness.md), and the app
  version. Plain text, one screen.
- **The issue template asks for it**, and for a gallery capture when the
  report is visual.
- **dSYMs** are kept per release so a crash log from a user symbolicates.
- **The panic corpus** from [C4](correctness.md) is mentioned in the
  template as the thing to attach for a crash.

*Done when:* a bug report filed through the template contains enough to
reproduce a font, scale or config problem without a follow-up question.

*Risk:* low.

### P5 — Intel and Linux (two weeks each) — **gated**

- **x86_64 macOS** is a `-Dtarget` flag after [D5](dependencies.md) —
  frameworks come from the SDK, not from a keg — and `lipo` in the
  workflow makes the universal binary. It lands with D5, not here.
- **Linux, and Windows after it,** are planned in full on
  [compatibility.md](compatibility.md) — M2 and M3, each a second
  implementation of the `Platform` and `Pty` seams
  [D4](dependencies.md) defines, with what "platform" means on each OS
  written down there. This entry keeps only the gate.

*Gate:* not before the Mac experience is complete — every sprint labelled
"next" on [experience.md](experience.md) landed — and not before someone
on that platform asks. The [priorities](priorities.md) non-goals say
macOS first, finished, then elsewhere.

*Risk:* medium for Linux, mostly in the parts SDL does not cover.

## Why this order

- **P0 before anything**, because a bare binary that needs Homebrew is not
  a release.
- **P1 immediately after**, because the first-open dialog is the first
  impression.
- **P3's minimal form early and Sparkle gated**: most of the value, none
  of the surface.
- **P5 last and gated**, per the non-goals.

## Not on this plan

- **Telemetry.** None, ever. P3's version check is the only network
  request the app makes and is documented as such; P4 is a flag the user
  runs and a file the user attaches.
- **A Mac App Store build.** Sandboxing and a terminal are at odds; the
  DMG and the cask are the channels.
- **Windows, from here.** ConPTY is a different shape from `forkpty`,
  and the input model is different too — but the core is the same
  program, and [compatibility.md](compatibility.md)'s M3 plans the port
  as a second platform layer, gated behind Linux.
