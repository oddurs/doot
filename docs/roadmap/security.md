# Security roadmap

A terminal parses hostile bytes for a living. Anything that writes to it —
`cat` on a downloaded file, a compromised host over `ssh`, an agent
printing whatever a web page told it to — controls the input to the
parser, and the parser's job is to make sure that input can paint the
screen and nothing else. Sized for one person at 8–12 focused hours a
week. Sprint prefix: **S**.

Arbiter: **the policy table and the fuzzer.** Every sequence that could
carry bytes *out* of the terminal — a reply, a clipboard write, a link, a
paste — has a row in the table below saying what is allowed, and a test
that proves the forbidden case emits nothing. Every parser of untrusted
input has a fuzz target that runs in CI.

## The threat model and the policy

Both live in [docs/security.md](../security.md) — the permanent home S0
gave them, with a test named beside every row. The one-sentence rule:
**the terminal never sends the child bytes derived from screen content,
the title, the clipboard, or another tab.**

## Where we are

| | Today | Where |
|---|---|---|
| Release build | **ReleaseFast** — bounds and overflow checks off in the code that parses hostile bytes | `release.yml`, `ci.yml` matrix has no ReleaseSafe row |
| Replies to the child | DA1 and DSR 5/6 only. **Nothing echoes screen, title or clipboard content back.** The property to keep | `deviceStatusReport`, `deviceAttributes` |
| Title query (XTWINOPS 21) | Not implemented — correct; it is the classic injection vector | — |
| OSC 52 clipboard | Not implemented. [A2](agentic.md) adds write, and read only behind a config key | `oscDispatch` `else` |
| Paste | Bracketed when the app asks. **Otherwise raw**: a clipboard containing `\n` executes on paste; one containing `\x1b` is parsed as typed | `handleKey` `Cmd V` → `sendToPty` |
| Hyperlinks, path open | Not implemented; [A4](agentic.md) needs a policy before it exists | — |
| DCS, APC, SOS, PM | Swallowed to ST, never answered | `vt.zig` `string_ignore` |
| Notification text | Not implemented; [A1](agentic.md) will put child-controlled text in a system notification | — |
| Child environment | Inherits the parent's; sets `TERM`, `COLORTERM`, `TERM_PROGRAM`, unsets `LINES`/`COLUMNS` | `pty.zig` |
| Network | **None.** [P3](platform.md) adds one request, behind a key | — |
| Font files | Parsed by FreeType; ours after D1 | `font.zig` |
| Fuzzing | None | — |
| Actions | Pinned by major tag (`@v5`), not SHA; Dependabot keeps them current (its first PR is open) | `.github/workflows/`, `dependabot.yml` |
| Build inputs | Zig pinned to 0.16.0; SDL3 and FreeType at whatever Homebrew has that day | `release.yml` |
| Reproducibility | Not checked | — |
| Signing | None ([P1](platform.md)) | — |
| Disclosure | `SECURITY.md`: private advisories, a week to acknowledge, scope stated | `SECURITY.md` |

The strongest line in that table is the third one, and it is there by
accident of not having implemented the queries yet. S0 makes it a rule.

## The sprints

### S0 — The threat model and the table, made binding (two days)

Move the two sections above into `docs/security.md` (the roadmap keeps
the sprints; the policy needs a permanent home) and give every row a
test: for each forbidden reply, a unit test feeds the sequence and
asserts `replies` is empty; for each allowed one, asserts the reply
contains no byte from the screen. `SECURITY.md` links the policy and
says the rule in one sentence.

*Why here:* before [A2](agentic.md) and [C1](correctness.md) add the
first batch of new replies. A policy written after the queries exist is
a list of exceptions.

*Done when:* the table has a test per row, and `SECURITY.md`'s scope
section cites it.

*Risk:* none.

*Result:* done. [docs/security.md](../security.md) holds the threat
model and the table; six tests in `src/terminal.zig` hold the rows that
have a status today; `SECURITY.md` states the rule and links the page.
On the way, [#28](https://github.com/oddurs/doot/issues/28) closed:
`csiDispatch` now ignores any CSI with a private marker or intermediates
it does not implement instead of dispatching it on the bare final —
`CSI > 4 m` no longer turns underline on and `CSI < u` no longer moves
the cursor. `zig build audit` went from two mis-handled sequences to
none. See [the record](completed/sprint-s0-reply-policy.md).

### S1 — Safe defaults for untrusted output (one week)

- **The paste guard.** When bracketed paste is off and the clipboard
  holds a newline, a carriage return, an escape or any other C0, show
  one line in the grid — *paste contains 3 lines and 1 control
  character; ⏎ to send, Esc to cancel* — and send only on confirm. A
  config key disables it. kitty, iTerm2 and WezTerm all ship a version
  of this; the attack it stops is a web page that puts
  `innocuous\ncurl … | sh\n` on the clipboard.
- **Bracket integrity.** Strip `\x1b[201~` from a bracketed payload.
- **Title and notification hygiene.** Strip C0/C1, cap at 1 KiB, before
  `setTitle` or [A1](agentic.md)'s notification call.
- **The OSC 52 keys**, the OSC 8 scheme list and the confirm, landing
  with [A2](agentic.md) and [A4](agentic.md) rather than after them —
  this sprint owns the policy; those own the feature.

*Done when:* an e2e test pastes a two-line clipboard with bracketed
mode off and asserts nothing reached the PTY until confirm; a unit test
proves a bracketed payload cannot close its own bracket.

*Risk:* low. The guard is a UI decision more than a security one, and
the config key is for the people who disagree.

### S2 — Memory safety in the release build (one week) — **gated on a number**

Build with `ReleaseSafe` and run the bench and `--frame-stats`. Zig's
safety checks — bounds, overflow, unreachable — turn a hostile-bytes bug
from silent corruption into a panic, which for a terminal is the right
failure. The cost is unknown until measured, and the plan says so.

*Gate:* if `ReleaseSafe` is within **10%** of `ReleaseFast` on every
corpus, the release build becomes `ReleaseSafe` and the matrix gains
the row. If it is not, find where — almost certainly the printable-run
loop [Sprint 4](completed/sprint-4-print-run.md) built — and mark that
one block `@setRuntimeSafety(false)` with a comment naming the fuzz
target that covers it. Everything else ships safe.

Either way, this sprint adds `ReleaseSafe` to CI, and hands
[testing.md](testing.md)'s T1 its list of fuzz targets: `vt.Parser`,
`Terminal` operations, the config parser ([K0](config.md)), the
font parser ([D1](dependencies.md)), the PNG decoder
([D2](dependencies.md)), the GSUB reader ([D3](dependencies.md)), and
the remote-control protocol ([A6](agentic.md)). Every parser of bytes
the user did not type.

*Done when:* the bench numbers for both modes are in this file; the
release workflow builds whichever the gate chose; the CI matrix has
three optimize rows.

*Risk:* low. The worst case is a documented 10% and a fuzzed hot loop.

### S3 — The build you can check (half a week)

- **Pin Actions by SHA.** Dependabot already groups and bumps them; it
  bumps SHAs too. The open Dependabot PR is the proof it works.
- **Pin what Homebrew installs** in `release.yml` — formula versions,
  not "latest" — until [D5](dependencies.md) removes the question.
- **Reproducible release.** The release workflow builds twice, in two
  jobs, and fails if the SHA-256 differs. Zig is deterministic for the
  same toolchain and inputs; assert it rather than assume it.
- **Least privilege in workflows.** `permissions:` blocks exist in
  both; make CI's read-only and release's `contents: write` the only
  grant.
- **The signing key** ([P1](platform.md)) lives in a GitHub environment
  with a required reviewer — the maintainer — so a workflow change
  cannot silently sign.
- **An SBOM that fits on one line**: after D5, the link line from
  `otool -L` and the Zig version, printed in the release notes.

*Done when:* `grep uses: .github/workflows/*.yml` shows only SHAs; a
release run shows two matching checksums.

*Risk:* none.

### S4 — The remote-control boundary (half a week, with A6) — **gated on A6**

The socket is a way for a process to type into the terminal, so it is
held to the same rule as everything else on this page.

- A per-user directory, mode 0700, socket 0600.
- A random token, generated at start, passed to children in the
  environment and required on every connection. A process that did not
  start under this terminal does not have it.
- A size cap per message and a rate cap per connection.
- `--no-remote` disables it; `--headless` binds nothing unless asked.
- `send` into a tab is subject to the paste guard's rules — a control
  character from the socket is a control character.

*Done when:* an e2e test connects without the token and is refused;
with it, is accepted; a second user on the machine cannot connect at
all.

*Risk:* low in code. The design is the whole thing, and it is above.

### S5 — Least privilege in the app (half a week, with P1)

- Entitlements: none beyond the hardened runtime's defaults. A PTY
  needs nothing. After [D5](dependencies.md) there are no dylibs, so no
  library-validation exception.
- `Info.plist` usage descriptions: absent, because nothing is used.
- The one network call ([P3](platform.md)) is documented in
  `SECURITY.md` as the one network call, with its config key.
- `--screenshot` and the panic corpus ([C4](correctness.md)) write only
  where told, and the panic corpus only when asked.

*Done when:* `codesign -d --entitlements -` on the release prints the
minimal set, and the release notes quote it.

*Risk:* none.

### S6 — The record's privacy (with L0, then per sprint)

**Landed with [L0](completed/sprint-l0-record.md).** Every row below except
the last three — which are gated on sprints that do not exist yet — has a
test in `src/rec.zig` or `src/tests.zig`, and they run in CI.

[record.md](record.md) specifies the privacy shape; S6 holds it as
policy with a test per line, landing with L0 and re-run by every L
sprint.

| Rule | Test |
|---|---|
| Output recorded by default; **input never by default** | a fresh config records a session; the file contains no `input` event |
| Input recording is per-tab, opt-in, indicated | enabling it flips the indicator in the same frame; disabling stops the events in the same frame |
| An incognito tab writes nothing | the sessions directory is unchanged after an incognito session |
| Files are 0600 in a 0700 directory | `stat` in the e2e test |
| Retention is a config key with a default in days | a session older than the default is gone after the next launch |
| Deletion is real | after delete, no file and no index entry contains the session id |
| Export redacts | every fixture secret — tokens, keys, the `Authorization:` header shapes — is replaced in the exported file |
| Nothing leaves the machine | the app makes no network request other than [P3](platform.md)'s, asserted the same way |
| The remote socket reads the record under the same token | [S4](security.md)'s test extended to `follow` and `log` |

Encryption at rest is deliberately not here: FileVault is the platform's
answer, and a second key the user must manage is a way to lose the
record, not protect it. The docs say so.

Two of those tests are worth their reasoning. Input is asserted absent by
**scanning the whole file** for a typed passphrase and for any type-2 record,
not by reading a flag back: a flag says what the writer believed, and the
question is what is on the disk. And retention sweeps by **mtime**, not by the
header's start time, because mtime is self-protecting — an open session's
writes keep it inside the window, so a second instance's startup sweep cannot
delete a file the first one still has open. That last one is only true because
an idle session emits a `tick` a minute; as first written it buffered nothing,
wrote nothing, and its mtime froze, so the sweep would have deleted a file its
own writer still held open.

The `0700` on the directory is enforced rather than requested: `makeDir`
passes the mode to `mkdir`, and `chmod`s the directory to `0700` when it
already exists. Treating `EEXIST` as success without checking the mode left a
`chmod 0777`ed sessions directory world-listable — start times, session-id
prefixes, sizes and counts — which is the whole of what the directory mode is
for.

*Done when:* the table's tests run in CI; `SECURITY.md` links the
record's privacy section. — **done**: [SECURITY.md](../../SECURITY.md) has a
"Session recording" section linking [record.md's privacy
section](record.md#privacy-is-the-design) and this one, and saying which
recorder failures are worth a private report.

*Risk:* none in code. The risk is a default drifting in a later sprint,
which is what the tests are for.

## Why this order

- **S0 before A2 and C1**, so the first new replies are written against
  a policy instead of becoming one.
- **S6 with L0**, not after it. A recorder that ships before its
  privacy tests is a recorder that ships without them.
- **S1 early** because the paste guard closes the one attack a user can
  meet today, and it is a week.
- **S2 gated on a number** the bench can give in an afternoon.
- **S3 whenever**; it is configuration.
- **S4 and S5 ride their sprints.**

## Not on this plan

- **Sandboxing the terminal.** A terminal exists to run a shell with
  the user's privileges; a sandbox that allowed that would not be one.
- **Filtering what programs may print.** The parser is the filter. A
  sequence is either handled, ignored, or swallowed; there is no
  allowlist of programs.
- **Auditing SDL3 or FreeType.** They are being removed
  ([dependencies.md](dependencies.md)); the time goes to fuzzing what
  replaces them.
- **A bug bounty.** `SECURITY.md` promises a straight answer within a
  week, which is what a personal project can honestly offer.
