# Product priorities

What terminator is for, in the order that decides a tie.

1. **Beautiful.** Text that is right at every size, motion that is tied to
   the display, chrome that gets out of the way. This is the veto: a sprint
   that ships ugly is not done, whichever roadmap it came from.
2. **Agentic.** The person at the keyboard is increasingly supervising
   several long-running agents rather than typing at one shell. Attention
   routing, navigable output and speaking the protocols agent CLIs use are
   the product thesis — what makes this terminal worth opening instead of
   the one that came with the machine.
3. **Fast.** The foundation, and the roadmap with the most history. Bulk
   output no longer waits for the display, the frame is one draw call,
   and printable runs go to the terminal as one slice; every sprint on
   that roadmap is done or retired by its gate. It reopens only with a
   corpus and a number, and it is never allowed to regress: `zig build
   bench` and `--frame-stats` are the arbiters on every PR.
4. **Well-rounded.** Selection, mouse, search, reflow, a config file. The
   floor every terminal must clear, done properly rather than first.

And one constraint that cuts across all four, pursued aggressively:

**Ours.** The parser, the grid, the atlas, the rasterizer, the renderer and
the window are written here. The only things linked into the binary are
libc and the operating system's own frameworks. Everything else is a test
oracle the binary never loads. [dependencies.md](dependencies.md) is the
plan; the README's "nothing else is borrowed" is the claim it makes true.

Each priority has its own roadmap and its own arbiter — the thing that
decides whether a sprint is done. A claim without one is labelled a guess.

| Roadmap | What it covers | Arbiter | Prefix |
|---|---|---|---|
| [experience.md](experience.md) | Typography, glyph coverage, cursor and motion, colour, native chrome | The screenshot gallery, 1× and 2× | X |
| [agentic.md](agentic.md) | Attention, modern-TUI protocol, semantic prompts, links, tabs, remote control | Recorded agent sessions and the protocol audit table | A |
| [performance.md](performance.md) | Parse throughput, lock hold, frame build | `zig build bench`, `--frame-stats` | 0–5, R |
| [essentials.md](essentials.md) | Selection, mouse, search, reflow, config, keys, scrollback | End-to-end tests on a real PTY | E |
| [correctness.md](correctness.md) | VT conformance, Unicode, identity, robustness, the test infrastructure | esctest, vttest, the fuzzer | C |
| [platform.md](platform.md) | App bundle, signing, distribution, updates, diagnostics | A fresh Mac, downloaded and opened | P |
| [dependencies.md](dependencies.md) | Own the GPU path, the rasterizer, the shaper, the window; one binary | `otool -L` and the gallery | D |
| [releases.md](releases.md) | What a version promises, the release train, milestones, notes, support | The tag | V |
| [website.md](website.md) | The marketing site on GitHub Pages, rendered from what the repository produces | A fresh visitor and Lighthouse | W |
| [security.md](security.md) | The threat model, the reply policy, paste guard, memory safety in release, the build you can check | The policy table and the fuzzer | S |
| [testing.md](testing.md) | The layers, the differential model, fuzzing, replay, gating the bench, CI hygiene | CI under five minutes with every arbiter in it | T |
| [compatibility.md](compatibility.md) | Linux, Windows, the browser; what "platform" means on each; the program matrix | The CI matrix and the compatibility matrix | M |

## The one rule, generalised

The performance roadmap was written once from reading the source, and its
largest bottleneck was not on it ([sprint 0](completed/sprint-0-benchmarks.md)).
That is why each roadmap above opens by building its arbiter before it
builds anything else: X0 is a gallery, A0 is a corpus, C0 is a harness, D0
is a pixel-identical swap the gallery must confirm. The first sprint on
every roadmap exists to make the rest of it falsifiable.

Sprints carry **gates** where the case for them rests on an assumption. A
gate that fails retires the sprint — the cheapest outcome on any plan, and
one this repository has already had twice
([sprint 5](completed/sprint-5-cell-size.md), and sprint 3 after it).

## How the roadmaps depend on each other

```
 X0 gallery ──► D0 Metal ──► D1 rasterizer ──► D2 emoji ──► X1 type ──► D3 shaping (gated)
                   │              │                            │
                   │              └──► X2 coverage             └──► X6 decorations
                   ▼
 A1 attention ──► D4 AppKit ──► D5 one binary ──► P0 bundle ──► P1 sign ──► P2 ──► P3
     ▲               │
     │               └──► X3 motion, X4 theme, X5 chrome (mechanism)
 A0 corpus ──► A2 protocol ──► A3 prompts ──► A5 tabs ──► A6 remote (gated)
                    ▲              │           ▲
                 E2 mouse ──────► A4 links     │
                                   ▲           │
 E1 selection ─── wrapped flag ────┴──► E4 reflow (gated)
     │
     └──► E3 search          E5 config ──► X4 theme, E6 keys

 C0 harness ──► C1 sequences, C2 unicode ──► C3 terminfo
```

Three primitives are shared by several sprints and are called out in each
place they are needed, so the first sprint to arrive builds them and the
rest reuse them:

- **A per-row `wrapped` flag** — set when a line feed came from wrapping,
  not from `LF`. Selection joins wrapped lines without a newline (E1),
  reflow re-wraps by it (E4), and path detection spans it (A4).
- **A stable line identity** — a counter that survives the screen ring
  rotating and scrollback pushing. Selection anchors to it (E1), search
  results point at it (E3), semantic-prompt marks live on it (A3).
- **Per-row marks alongside the ring** — a small side array that rotates
  with `Screen.offset`. Semantic prompts (A3) and search highlights (E3)
  want one. The trap is the ring: a mark that does not rotate with its row
  is a mark on the wrong row.

And one convention: **`src/platform/` is glue, not logic.** Objective-C
compiled by Zig's clang, a C ABI, no file over 400 lines, nothing that
branches on terminal state. D0 establishes it; A1, X4 and X5 use it
instead of each growing a shim.

## The proposed order

One person at 8–12 focused hours a week, sprints of one to three weeks.
This is an order, not a schedule; the performance roadmap's own history
says it will change after each sprint lands, and that is the intent.

The performance roadmap is closed — every sprint done or retired — so
the next twelve are drawn from the other six. The dependency work is
front-loaded deliberately: it is the constraint being pursued
aggressively, each D sprint removes a shim another roadmap would
otherwise have to build, and D5 makes P0 trivial. The price is that the
agentic keystone (A3) and tabs (A5) land two to three sprints later than
they otherwise would; that trade is made here, on purpose, and can be
unmade by moving A3 up to row 5.

| # | Sprint | Why here |
|---|---|---|
| 1 | X0 — the gallery | One week. Every D sprint below is judged by it; D0 cannot start without it. |
| 2 | A0 — agent corpus and protocol audit | One week, parallel-safe with X0. Turns every agentic claim into a table entry, and hands the bench an `agent` corpus. |
| 3 | D0 — own the GPU path | The first `.m` file, the glue-only convention, and X1's shader — behind SDL's window, pixel-identical first. |
| 4 | E1 — selection and copy | The biggest gap in the README. Builds the `wrapped` flag and stable line ids three other sprints need. |
| 5 | D1 — own the rasterizer | FreeType out, by differential test. X2's fallback chain is a list of faces this loads. |
| 6 | A2 — the modern-TUI protocol | Synchronized output, cursor shape, colour queries, the `CSI u` fix. Agent TUIs flicker and mis-key without them. |
| 7 | D2 + X2 — colour glyphs, atlas pages, fallback, drawn box glyphs | Emoji and Nerd Font icons currently vanish. One sprint now that D1 exists. |
| 8 | A1 — attention | `bell` is set and never read. The first `shell.m` function, and the C-ABI proof D4 wants. |
| 9 | D4 — own the window | SDL out. Brings X5's titlebar and menu, X3's trackpad scrolling, X4's appearance and the 1×/2× fix as properties rather than shims. |
| 10 | D5 + P0 — one binary, the bundle | `otool -L` shows only `/System`. The moment a second person should try it. |
| 11 | A3 — semantic prompts | The agentic keystone: command boundaries, running state, "idle at a prompt while unfocused". |
| 12 | E2 — mouse reporting | A week. Tracked but never forwarded; unblocks A4 and every mouse-driven TUI. |

After that: X1 typography (the format flip already happened in D0; this
is faces and metrics), E5 config, A5 tabs, C1 sequences, P1 signing — in
whichever order the previous twelve have made most urgent.

Five roadmaps run beside the order rather than in it, each with one
sprint that should happen early because it is short and fences
everything after it:

- [V0](releases.md), a day, before row 1: the repository currently
  describes a `0.1.0` that was never tagged. V1 then puts a release
  train under the first sprint that lands.
- [S0](security.md), two days, before A2 and C1 add the first new
  replies: the rule that the terminal never sends the child bytes
  derived from the screen, the title or the clipboard, made binding by
  a test per row.
- [T0](testing.md), a week, whenever: the differential model and the
  mutants that Sprint R's review built by hand, committed; the golden
  checksum the bench already prints, asserted.
- [M0](compatibility.md), half a week: the core builds for Linux,
  Windows and wasm today; a CI row per target keeps it so.
- [W0](website.md), a week, any time after V0: the `--screenshot` flag
  means the site can carry a real frame today. W4, the launch, is gated
  on the 0.5 release.

## Non-goals

Stated so they do not have to be re-decided.

- **terminator does not ship an assistant.** It hosts them. Agents live in
  the shell; the terminal's job is to make watching, steering and being
  interrupted by them excellent. No chat panel, no model, no API key.
- **No telemetry.** Diagnostics are a flag the user runs and a file the user
  attaches.
- **macOS first, finished, then elsewhere.** The port-shaped decisions
  (`forkpty`, a platform interface with glue behind it) are already
  made, and the core is kept provably portable on every PR
  ([M0](compatibility.md)); the Linux and Windows ports themselves wait
  until the Mac experience is complete ([M2, M3](compatibility.md)).
- **Not a multiplexer.** Tabs and, later, splits — but sessions live and die
  with the window. Persistence is a daemon and a different program.
- **No from-scratch kernel interface, IME, or window system.** Owning the
  code stops at the platform's edge; see the ownership rule in
  [dependencies.md](dependencies.md).
