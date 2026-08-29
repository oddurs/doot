# Sprint A0 — Agent corpus and protocol audit

**Done.** Row 2 of the [priorities](../priorities.md) order, and the arbiter
for the whole [agentic roadmap](../agentic.md).

## What was proposed

Record real agent sessions byte-for-byte, commit them as corpora, and from
them produce two things: an audit table of every sequence each agent emits
with what doot does about it, and a measurement of the *shape* of
agent output — bytes per write, writes per second, longest burst.

The stated risk: "low. The risk is in what it finds — expect at least one
row of mis-handled that is not in the table above."

## What it found

**Two mis-handled rows, from one cause.** `Terminal.csiDispatch` switches on
the final byte without consulting the private marker, so sequences agents
actually emit land on the arm for an unrelated one:

| Sequence | Per session | What it means | What we do |
|---|---|---|---|
| `CSI > 4 m` | 4× | xterm modifyOtherKeys | runs SGR 4 — **underline on** |
| `CSI < u` | 4× | kitty keyboard pop | runs restore-cursor — **the cursor teleports** |
| `CSI > 0 q` | 1× | XTVERSION query | ignored, no reply; the agent waits out its timeout |

Every agent CLI speaking the kitty keyboard protocol turns underline on in
this terminal at startup and moves the cursor on exit. That is not a missing
feature; the screen is wrong afterwards. Filed as
[#28](https://github.com/oddurs/doot/issues/28), left for
[A2](../agentic.md) to fix — A0's job was to find it, and the audit now
carries a `MIS-HANDLED` row that turns green when it is.

**The terminal never receives more than 1,024 bytes per read.** In both
recordings the maximum read is exactly 1,024, whatever the program wrote,
because that is the kernel's pty output queue. `main.zig`'s 64 KiB read
buffer can never fill. Everything below the parser is optimised for
kilobyte-sized handoffs whether it meant to be or not.

**An agent thinking and an agent dumping are different workloads.**

| | bytes | writes | over | per write | writes/s | busiest 100 ms |
|---|---|---|---|---|---|---|
| working | 8,492 | 97 | 41.3 s | 87 B | 2.3 | 2,075 B |
| dumping a diff | 266,688 | 1,687 | ~0 s | 158 B | 84,621 | all of it |

Four orders of magnitude apart, wanting opposite things — latency versus
throughput. The corpora now name both, and `zig build bench` reports them
beside the six generated ones.

## What it needed that the sprint did not anticipate

**A recorder, not `script(1)`.** The sprint said to capture with `script`.
Two problems. `script` on macOS records timing in a format nobody wants to
parse, and — the real one — **a non-interactive agent draws nothing**.
`claude -p` emits *one escape byte per kilobyte*: no spinner, no redraw, no
capability negotiation. Recording an agent TUI means being able to type at
it.

So `zig build record` runs a command on a pty, captures raw bytes plus a
`.timing` sidecar of one line per read, and can send scripted keystrokes:

```sh
zig build record -- out.bin --send "3000:\r" --send "7000:hello\r" \
    --stop-after 50000 -- claude
```

It reuses `pty.zig`, which grew an `openCommand` for an arbitrary argv.
About a hundred lines, and it is what made the two mis-handled rows visible
— they appear only in a session that *starts and exits*, in the capability
setup and teardown. The first long recording missed them entirely because it
was killed before the agent could tear down.

## The corpora

| corpus | what it is |
|---|---|
| `agent-claude` | a full session: start, trust prompt, a question, an answer, a clean exit |
| `agent-stream` | a colourised diff streaming at the pty's full rate |

Both are recordings, not generated. The `.timing` sidecar is committed
beside each, because the shape measurement is not reproducible from the
bytes alone.

## The audit is a tool, not a document

`zig build audit` feeds each corpus through the real parser and prints every
distinct sequence with its status. The status column is a **committed table**
in `src/audit.zig`, because nothing at run time can tell whether a `switch`
arm is the *right* arm — but anything a corpus contains that the table does
not mention prints as `unlisted`. A new agent version emitting something new
becomes a question rather than silence.

Today: 14 distinct CSI forms, 1 OSC, 2 mis-handled, 0 unlisted.

Review found the tool's own blind spot: it keyed only on the private marker
and the final byte, so an *intermediate*-bearing sequence — `CSI SP @` is SL,
not ICH — was reported as `handled` when the terminal runs the wrong arm for
it, the very defect the audit exists to surface. It keys on the intermediate
now, and SL, SR and DECSCUSR are in the table.

## Recordings are not safe to commit unread

Review also found what my own scan had not: both recordings embedded **live
`https://claude.ai/code/session_…` deep links**, along with the account's
plan tier and its MCP and plugin state. I had grepped for API keys, tokens,
emails and home paths and found nothing, and concluded the recordings were
clean — the wrong conclusion from a pattern list that did not include the
thing that was there.

The session identifiers are scrubbed with same-length placeholders, so every
`.timing` byte count still describes its `.bin` exactly and the bench and
audit numbers do not move. The lesson is the general one: a recording of a
real tool captures whatever that tool happened to print, and the only safe
review of one is to *read it*, not to search it for the problems you already
thought of.

## Done when

> the corpora are committed, `zig build bench` reports them alongside the
> six, and the audit table exists with a status for every row

All three. The audit table is in [agentic.md](../agentic.md), generated by
`zig build audit` rather than transcribed.
