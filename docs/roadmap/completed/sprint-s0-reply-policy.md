# Sprint S0 — The reply policy, made binding

**Done.** Closed [#28](https://github.com/oddurs/doot/issues/28) on the
way.

## What was proposed

The security roadmap opened with an observation: the strongest security
property the terminal had — no reply ever echoes screen, title or
clipboard content back to the child — was true by accident of not having
implemented the queries yet. [A2](../agentic.md) and
[C1](../correctness.md) were about to add the first batch of new replies.
S0's job was to write the rule down before they did, and to give every
row of the policy table a test, so that a reply which breaks the rule
fails `zig build test` rather than a review.

## The rule

**The terminal never sends the child bytes derived from screen content,
the title, the clipboard, or another tab.** A reply carries only what the
child could already know — modes, capabilities, the cursor position.

It now lives in [docs/security.md](../../security.md) with the threat
model and the full table; `SECURITY.md` states it in one paragraph and
says a reply that breaks it is a vulnerability.

## What was found on the way

Writing the private-marker row meant testing it, and the test failed:
`CSI > 4 m` — xterm's modifyOtherKeys, which every kitty-keyboard-speaking
agent CLI sends at startup — turned underline on, because `csiDispatch`
switched on the final byte without looking at `csi.private` and landed on
SGR 4. `CSI < u`, the kitty keyboard *pop* sent at exit, landed on
restore-cursor and moved it. [A0](sprint-a0-agent-corpus.md)'s audit had
already filed this as #28 and left it for A2; it turned out to be five
lines, and the same five lines fixed the intermediates case nobody had
filed — `CSI $ r` (DECCARA) was reaching DECSTBM and would have set a
scroll region from a rectangle.

The fix is a guard at the top of `csiDispatch`: a CSI with intermediates
is ignored outright; a CSI with a private marker reaches only the arms
that know their private forms and is otherwise ignored until A2
implements it.

Review found what the first draft of the guard broke: three private
forms had been *right by accident*. `CSI ? 2 J` (DECSED) and `CSI ? K`
(DECSEL) erase only unprotected cells, and with DECSCA unimplemented
every cell is unprotected — so falling through to ED and EL was the
correct behaviour, and ignoring them was a regression. `CSI ? 6 n`
(DECXCPR) had been answered with a plain CPR, which is the wrong shape;
it now replies `CSI ? r ; c R`. All three are implemented on purpose,
with the spec cited, and the #28 test asserts them. Review also caught
the first DECCARA test proving nothing — its parameters read as DECSTBM
made `top >= bot`, which DECSTBM rejects anyway — so the test now uses a
rectangle that the old dispatch turned into a real scroll region.

## Result

| | before | after |
|---|---|---|
| `zig build audit`, sequences mis-handled | 2 (`CSI > m`, `CSI < u`, 4× per recorded session each) | **0** |
| Audit rows declared MIS-HANDLED | 7 | 0 |
| Tests holding the policy | 0 | 6 |
| `zig build test` | 375 | 387, all green |

The six tests, one per row that has a status today:

- a private-marker CSI is not the unprefixed sequence (#28)
- a CSI with intermediates is ignored rather than dispatched on its final
- the title is never reported back to the child (XTWINOPS 21, 20)
- screen-reading queries are never answered (DECRQCRA, DECRQSS, XTGETTCAP)
- the clipboard is never read back to the child by default (OSC 52 `?`)
- the replies that are allowed carry nothing from the screen — prints a
  marker, asks DA1, DSR 5, CPR and DECXCPR, asserts the exact strings and
  that the marker is absent

## What changed about the plan

- The rows for OSC 8 links, path open, notification text, the paste guard
  and the remote socket have their policy written before their feature.
  When [A4](../agentic.md), [S1](../security.md) and [S4](../security.md)
  land, they change a status and name a test; they do not decide a
  policy.
- `src/audit.zig`'s rows are declared, not measured, and say so. Seven
  rows flipped from MIS-HANDLED to ignored with a note that says why.
  [T1](../testing.md)'s fuzzer is what will keep them honest without a
  human editing a table.

## Traps for anyone touching `csiDispatch` now

- A new private form goes *inside* the `if (csi.private != 0)` switch, not
  on the plain-final arm. The test for #28 fails if it lands wrong.
- A new sequence with intermediates needs the intermediates guard lifted
  for its final byte specifically. DECSCUSR ([X3](../experience.md)) and
  DECSTR ([C1](../correctness.md)) are the first two.
