# Experience roadmap

Beautiful by default. The reason to open this terminal instead of the one
that came with the machine is how it looks in the first five seconds and
how it feels after five hours. Sized for one person at 8–12 focused hours
a week. Sprint prefix: **X**.

Beauty here means precision, not decoration: text that is correct at every
size, motion tied to the display, chrome that disappears. Every sprint on
this page is judged by a picture, the way every performance sprint is
judged by a number.

Arbiter: **the screenshot gallery**, built by X0 on the `--screenshot` flag
[sprint 2](completed/sprint-2-one-draw-call.md) added — `zig build gallery`,
documented in [docs/gallery.md](../gallery.md). Every visual change ships
with before-and-after captures at 1× and 2×, or it is not reviewed.

## Where we are

| | Today | Where |
|---|---|---|
| Faces | One regular face; bold and italic synthesised by FreeType | `font.zig` `rasterize`: `FT_GlyphSlot_Embolden`, `FT_GlyphSlot_Oblique` |
| Missing glyphs | Cached as an empty box and **drawn as nothing**. Emoji, Nerd Font icons and most symbols vanish silently | `Atlas.get`, the `orelse` arm |
| Atlas | One 1024² RGBA page. Full is an error the renderer swallows, so the glyph is re-rasterized **every frame** and never drawn | `alloc_rect` → `Error.AtlasFull`; `Renderer.glyph` `catch return` |
| Box drawing, blocks, braille, powerline | From the font, so seams appear at fractional scales and glyphs the face lacks are missing | — |
| Blending | Alpha blend in sRGB space via SDL; no gamma correction, no stem darkening | `SDL_BLENDMODE_BLEND` |
| Cursor | Block, no blink, hollow when unfocused; DECSCUSR ignored | `cursorQuads`; `csiDispatch` note |
| Blink attribute | Parsed into `Attrs.blink`, **never rendered** | no reader in `render.zig` |
| Underline | Single, one colour; no curly, double, dotted or coloured (SGR 4:x, 58) | `Renderer.glyph` |
| Theme | One hard-coded dark scheme; `selection` colour declared, never used; no light theme; does not follow the system | `theme.zig` `default` |
| Minimum contrast | None. Grey-on-grey is drawn as sent | `cellColors` |
| Scrolling | Wheel delta × 3, truncated to whole lines. Small trackpad deltas truncate to **zero and are dropped**; no momentum, no sub-row motion | `main.zig` `handleWheel`: `@trunc(wheel.y * 3)` |
| Display scale | Captured at init. Moving the window to a 1× display keeps 2× glyphs and scales them | `Renderer.init` `scale`; `setFontSize` reuses it |
| Padding | 6 logical px on the left and top; the remainder of the window falls on the right and bottom | `pad`, `gridSize` |
| Chrome | SDL's default window; no titlebar integration, no menu bar, no blur, no icon | `SDL_CreateWindow` |
| Resize feedback | None — no cols × rows overlay | — |

## The sprints

### X0 — The gallery (one week) — **done**

Turn `--screenshot` into an acceptance test. A set of scripts under
`bench/gallery/` each render one canonical screen and capture it at 1× and
2×:

- the typography page — every printable ASCII, the box-drawing and block
  ranges, braille, powerline, a line of emoji, a line of CJK, combining
  marks on a base, every SGR attribute;
- a colourised `ls`, a `vim` screen, a `htop` screen, and a frame from the
  agent recordings [A0](agentic.md) makes;
- the same page at 10, 14 and 20 pt.

Captures are committed as PNGs. A `zig build gallery` step re-renders and
reports per-image pixel deltas; CI posts the diffs on every PR, non-gating
for the same reason the bench is — but a reviewer sees them.

*Why here:* nothing below can be judged without it, and it makes the
"where we are" table above into pictures anyone can look at.

*Done when:* the gallery runs headless on the macOS CI runner and a
one-pixel change in the cursor shows up as a diff in the PR summary.

*Risk:* low. The flag exists; this is scripting around it.

*Result:* done, and it needed more than scripting. `zig build gallery`
renders ten captures headless and diffs them per pixel; see
[the record](completed/sprint-x0-gallery.md) and
[docs/gallery.md](../gallery.md). The done-when is demonstrated: drawing
the cursor one pixel narrower moves 17 pixels at 1x and 34 at 2x, and
changing its colour by one in a single channel moves 153 pixels at a worst
delta of exactly 1.

The scenes are scripts rather than `vim` and `htop`, whose output varies
with version, locale and the files lying around — a pixel diff cannot tell
that apart from a regression. Real-program screens want recorded byte
streams, which [A0](agentic.md) produces.

### X1 — Typography (two weeks)

- **Real faces.** Load the family's bold, italic and bold-italic — Menlo's
  `.ttc` carries all four; SF Mono's do too — and fall back to synthesis
  only when a face is missing. `--font` and the config key pick the family.
- **Metrics done properly.** Cell height from ascent + descent + line gap,
  rounded once, with an optional line-height multiplier; the baseline
  placed so that underscores and descenders are never clipped at any size
  from 6 to 72 pt. The gallery's three sizes catch this.
- **Weight.** Blending in linear light arrives with
  [D0](dependencies.md)'s second commit — an sRGB drawable format makes
  the hardware do it — so this sprint's job is to *measure* it and add
  the optional stem-darkening step if the number says so. The measure:
  mean stroke coverage of the typography page against a CoreText
  rendering of the same text at the same size (CoreText as oracle, never
  linked), and against a Terminal.app screenshot. Light-on-dark text in
  sRGB blending reads thinner than the same face in a native app; this is
  the difference people describe as "the font looks wrong" without being
  able to say why.
- **Hinting.** None, by construction: [D1](dependencies.md)'s rasterizer
  does not hint, and neither does the platform. The gallery shows whether
  anyone can tell.

*Why here:* after D1 has replaced FreeType and X2 has built the
multi-face path, since fallback faces and style faces share the loading
and atlas-key code — and the `.ttc` face index that gives us real bold
and italic is D1's `name` table.

*Done when:* the typography page at 14 pt on a 2× display is
indistinguishable in weight from Terminal.app's rendering of the same
face side by side, and bold is a real face in the gallery diff.

*Risk:* medium. Weight is a taste call with a measurement behind it; the
measurement is the point.

### X2 — Glyph coverage (two weeks)

- **A fallback chain.** Primary face → the system's symbol and CJK faces →
  Apple Color Emoji → a Nerd Font if one is installed. Each is a face
  [D1](dependencies.md)'s parser loads from its discovery index; the atlas
  key grows a face index. Colour emoji and atlas pages are
  [D2](dependencies.md), which lands in the same sprint.
- **Drawn, not rasterized.** Box drawing (U+2500–257F), blocks (2580–259F),
  braille (2800–28FF) and the powerline range (E0B0–E0BF) become
  pixel-aligned quads over the white texel. They are already in the vertex
  path — `rect` is a quad — so this is a table of rectangles per codepoint.
  Seamless at every scale and never missing, which is the reason kitty and
  Ghostty do it.

*Why here:* the most visible flaw in any agent TUI is a spinner or an icon
that is not there. Second on the whole plan after the corpus, and the
gallery makes it provable.

*Done when:* the typography page has zero empty cells at 1× and 2×, and a
gallery capture of a box-drawing table at 13 pt shows no seams. The CJK
corpus at 200×60 runs with `build` unchanged after the atlas fills.

*Risk:* medium. Colour glyphs need their own blend (premultiplied, no
foreground tint); [D0](dependencies.md)'s shader carries a per-vertex mode
for exactly this, so it is a flag, not a second draw call.

### X3 — Cursor and motion (two weeks)

- **Shapes.** Block, bar, underline, from DECSCUSR ([A2](agentic.md) parses
  it) and the config. The hollow unfocused box stays.
- **Blink**, off by default, driven by an SDL timer that exists only while
  the window is focused and the cursor visible. The event loop currently
  blocks in `SDL_WaitEvent` and an idle terminal wakes zero times a second;
  that number is measured and must not change when blink is off, and must
  return to zero on focus loss when it is on.
- **Cursor motion**, an 60–80 ms ease between cell positions, on by
  default, off under the system's reduce-motion setting. One frame per
  step, no timer once it lands.
- **Scrolling that tracks the finger.** Accumulate fractional wheel deltas
  instead of truncating them — the one-line fix for dropped trackpad
  events, worth doing the day it is read — then sub-row scrolling: the
  `Frame` carries a pixel offset and one extra row, and the viewport
  slides. Momentum comes from the OS: SDL's precise deltas today,
  `NSEvent`'s `momentumPhase` after [D4](dependencies.md); nothing to
  invent either way.
- **Resize overlay** — `120 × 40` in the centre, fading over 300 ms after
  the last size change.

*Why here:* independent of the typography work and the first sprint that
makes the terminal *feel* different rather than look different.

*Done when:* `man zsh` on a trackpad scrolls without a visible step; the
gallery gains the three cursor shapes; the idle wake-up count is zero
with blink off.

*Risk:* low to medium. Sub-row scrolling interacts with the one-row-per-
line assumption in `snapshot`; the fix is one more row, not a redesign.

### X4 — Colour and theme (two weeks)

- **Theme files** in the config format [E5](essentials.md) chooses. Two
  bundled themes, one dark and one light, *designed* — contrast checked,
  ANSI colours distinct from each other at small sizes — rather than
  copied from a popular scheme. The current dark palette is the starting
  point.
- **Follow the system.** `SDL_GetSystemTheme` reports it; switch on the
  theme-changed event and re-answer OSC 10/11 queries so TUIs follow.
- **OSC 4 / 10 / 11 / 12 / 17 / 19** set and reset, so an app can adopt or
  override the palette and a reset restores it.
- **Minimum contrast.** A floor on the fg/bg contrast ratio, applied in
  `cellColors`, with a config key to disable it. Agent TUIs print
  grey-on-grey; the floor is what makes them readable without changing
  what they sent.
- **Use `selection`.** The colour exists; [E1](essentials.md) draws it.
- **Say what the colours are.** Output is sRGB. A gallery check reads a
  pixel back and asserts the theme's background value exactly.

*Why here:* needs a config file to live in.

*Done when:* toggling system appearance switches the theme within one
frame, and a running `vim` follows because it re-queried OSC 11.

*Risk:* low.

### X5 — Chrome and native feel (two to three weeks)

The window should not give away that it is not a native app. The
*mechanism* is [D4](dependencies.md): once the window is ours, each item
below is a property to set rather than a shim to write. This sprint is
the design — what the chrome looks like — and it lands with D4 or
immediately after.

- **Titlebar.** Transparent, with the grid's background behind it and the
  traffic lights placed; the tab strip ([A5](agentic.md)) lives here once
  both exist.
- **Menu bar.** File, Edit, View, Window, Help with the standard shortcuts
  and the standard items — this is where `Cmd N`, `Cmd T`, `Cmd W`,
  `Cmd ,` and Services come from, and where a user looks for them.
- **Background opacity and blur**, off by default, via an
  `NSVisualEffectView` behind the Metal view.
- **Scale changes mid-session.** `viewDidChangeBackingProperties`
  re-rasterizes when the window crosses to a display with a different
  pixel density; today the 2× atlas is scaled down.
- **Even padding.** Centre the grid and split the remainder, so the right
  and bottom edges match the left and top.
- **Fullscreen** that keeps the grid centred, and `Cmd ⏎` to enter it.
- **An icon.** Designed, not generated. It lands with the app bundle in
  [P0](platform.md) and is the first thing anyone sees.

*Why here:* with D4, so the AppKit code is written once with the design
in hand. Early enough that A5's tab strip can move into the titlebar
rather than be built twice.

*Done when:* a screenshot of terminator next to Terminal.app, both with
the same content, cannot be told apart by their chrome; dragging the
window between a 1× and a 2× display re-renders sharp within one frame.

*Risk:* low once D4 exists; it is D4 that carries the risk. Every line
here obeys the `src/platform/` rule — glue, no logic, under 400 lines a
file.

### X6 — Decorations (one week)

- Curly, double, dotted and dashed underline (SGR 4:1–4:5), underline
  colour (58 / 59) — TUIs use these for diagnostics.
- Render `blink` — or decide, in a comment, that it is deliberately
  rendered as bold, the way several terminals do. Either is fine;
  silently ignoring it is not.
- Strikethrough thickness tied to the underline metric.
- Dim as a blend (exists) checked against the contrast floor from X4.

*Done when:* the gallery's attribute line shows every SGR the parser
accepts, and none of them is drawn as plain text.

*Risk:* low. The underline styles need two bits in `Attrs`, which is
`packed struct(u8)` and full — it becomes a `u16`.

### X7 — Ligatures (two weeks) — **gated**

Shaping per run of identical style, with the shaped glyph drawn as one
quad spanning its cells and the cursor and selection overlaid per cell as
today. The run-per-row structure the background pass already has is the
unit of shaping; results are cached by (text, style).

The shaper is ours — [D3](dependencies.md), a GSUB reader for the
monospace case with HarfBuzz as the test oracle and never a link. This
sprint is the rendering half: the spanning quad, the cell map under the
cursor, the cache.

*Gate:* D3's gate — a font with a `GSUB` table the user has installed and
asked for. The system faces do not need it. The
[performance roadmap](performance.md) asked that this wait until the
vertex path was defined; it is.

*Done when:* `->` and `!=` in a ligature font render as one glyph, the
cursor moving through them lands on each cell, and `build` at 200×60 is
within 20% of unshaped.

*Risk:* medium. A cache that must not grow without bound.

## Why this order

- **X0 first**, for the same reason sprint 0 was — and because
  [D0](dependencies.md) must be pixel-identical to what it replaces,
  which only a gallery can say.
- **X2 before X1.** Missing glyphs are a bug; weight is a refinement. And
  X2 rides on D1 and D2, which build the multi-face plumbing X1 needs.
- **X3 is independent** and can be pulled forward whenever a break from
  font work is welcome; its trackpad half gets easier after D4.
- **X4 waits for a config file**; X5 lands with D4.
- **X7 is gated** on the fonts people actually run, through D3.

## Not on this plan

- **Shader effects** — CRT curvature, bloom, scanlines. Not beautiful.
- **Background images.** Opacity and blur cover the case that is not a
  screenshot of somebody else's terminal.
- **A settings window.** The config file is the settings; a GUI for it
  would be a second source of truth.
- **Animations that need a timer while idle.** The idle wake-up count is
  zero and stays zero.
