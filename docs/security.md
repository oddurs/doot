# Security: the threat model and the reply policy

A terminal parses hostile bytes for a living. Anything that writes to it —
`cat` on a downloaded file, a compromised host over `ssh`, an agent
printing whatever a web page told it to — controls the input to the
parser, and the parser's job is to make sure that input can paint the
screen and nothing else.

This page is the policy. The sprints that enforce it are on
[roadmap/security.md](roadmap/security.md); the reporting process is in
[SECURITY.md](../SECURITY.md). Every row of the table below names the
test that holds it, so a change that breaks a row fails `zig build test`
before it reaches a review.

## The one rule

**The terminal never sends the child bytes derived from screen content,
the title, the clipboard, or another tab.** A reply carries only what the
child could already know — modes, capabilities, the cursor position.

A terminal that reports its title back can be made to type: set the
title to a command, ask for it back, and the reply lands on the shell's
input as if it had been typed. Every other forbidden row is the same
attack through a different door.

## The threat model

Five attackers, in the order they matter.

1. **A program writing to the terminal.** It wants to run a command as
   the user (inject bytes into the shell's input), read something (the
   clipboard, the screen, the title), or spoof the display (hide what
   was really run). This is the one `SECURITY.md` describes and the one
   the policy table serves.
2. **A file the user opens.** A font in `~/Library/Fonts`, a config
   file, a corpus, a PNG inside an emoji font. After
   [D1](roadmap/dependencies.md) and [D2](roadmap/dependencies.md) those
   parsers are ours, and ours to fuzz.
3. **A local process.** Once [A6](roadmap/agentic.md)'s socket exists,
   another user's process on the same machine must not be able to type
   into a tab.
4. **The build.** What lands in the release binary and how anyone could
   check.
5. **Whoever reads the disk.** [L0](roadmap/record.md) records sessions,
   so the record is an asset: what was printed, and — if the user opted
   in — what was typed. Its protection is
   [S6](roadmap/security.md).

Not an attacker: the user at the keyboard. `--shell`, `--screenshot`
and `--font` take what they are given; if you can pass arguments you
can already run anything.

## The policy table

Status is what the code does today. A row's test is in `src/terminal.zig`
unless it says otherwise.

| Sequence | Direction | Policy | Status | Test |
|---|---|---|---|---|
| DA1 (`CSI c`), DSR 5, DSR 6 (`CSI 6 n`), DECXCPR (`CSI ? 6 n`) | reply | Allowed: capabilities, a health check, the cursor position. | answered | `the replies that are allowed carry nothing from the screen` |
| DA2, XTVERSION, DECRQM, XTWINOPS 14 / 16 / 18 | reply | Allowed when implemented: identity, modes, geometry. | ignored, no reply ([A2](roadmap/agentic.md), [C1](roadmap/correctness.md)) | — |
| XTWINOPS 21 (report title), 20 (report icon) | reply | **Never.** The title is child-controlled; reporting it is an injection channel. | ignored | `the title is never reported back to the child` |
| DECRQCRA (checksum of a screen rectangle) | reply | **Never.** It reads the screen. | ignored | `screen-reading queries are never answered` |
| DECRQSS, XTGETTCAP | reply | Refused until a program is found that needs one. | swallowed with the DCS | `screen-reading queries are never answered` |
| OSC 52 read (`OSC 52 ; c ; ?`) | reply | **Off by default.** A config key enables it; the docs say what that means. | ignored | `the clipboard is never read back to the child by default` |
| OSC 52 write | out to clipboard | Allowed by default; capped at 1 MiB; config key to disable. | ignored ([A2](roadmap/agentic.md)) | — |
| A CSI with a private marker (`CSI > 4 m`, `CSI < u`, …) | — | Its own sequence, never the unprefixed one. Ignored until its private form is implemented. | ignored | `a private-marker CSI is not the unprefixed sequence (#28)` |
| A CSI with intermediates (`CSI $ r`, `CSI SP q`, `CSI ! p`) | — | Its own sequence, never the plain-final one. | ignored | `a CSI with intermediates is ignored rather than dispatched on its final` |
| OSC 8 link | on click only | Schemes `http`, `https`, `mailto`; `file` with a confirm; anything else shown and not opened. The URI is displayed before opening. | not implemented ([A4](roadmap/agentic.md)) | — |
| Path open | subprocess | The editor is invoked with `--` and an absolute path; never through a shell. | not implemented ([A4](roadmap/agentic.md)) | — |
| OSC 0 / 2 title, OSC 9 / 777 notification text | to the OS | C0 and C1 stripped; length-capped; never interpreted. | title set raw ([S1](roadmap/security.md)) | — |
| Paste, bracketed mode off | into the PTY | Guarded: `\n`, `\r`, `\x1b` or any C0 prompts once and shows what will be sent. | raw ([S1](roadmap/security.md)) | — |
| Paste, bracketed mode on | into the PTY | Inside the markers; a `\x1b[201~` in the payload is stripped so a paste cannot close its own bracket. | not stripped ([S1](roadmap/security.md)) | — |
| DCS, APC, SOS, PM | — | Swallowed to ST. Stays that way. | swallowed | `DCS payloads are swallowed, not printed` (`src/vt.zig`) |
| The remote-control socket | in | Token, 0600, per user. | not implemented ([S4](roadmap/security.md)) | — |

Rows marked *not implemented* have their policy written before their
feature, on purpose: the feature is built against the row, not the other
way round. When one lands, its status changes and its test is named.

## What "allowed" replies may contain

The DA1 string is a constant. DSR 5 is a constant. CPR and DECXCPR are
two integers that the program set itself. Nothing else is sent to the child unasked,
and nothing that is sent is derived from cell contents, the title, the
clipboard, or any other tab. The test for that row prints a marker on
the screen, asks all four questions, and asserts the marker is absent
from every answer — and that the answers are exactly the strings above.
