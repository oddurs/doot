# Sprint W0 — The one page

**Done.** [oddurs.github.io/doot](https://oddurs.github.io/doot/).

## What was proposed

Two hand-written files, no build step, no script, no web font, deployed
from `site/` by an Actions workflow with no `gh-pages` branch to keep in
sync. One real screenshot, one sentence, a download button, the "what is
ours" table, links. The done-when: Lighthouse 100 on all four axes, the
page with its image under 300 KB, readable at 320 px, no `<script>` tag,
the repository's homepage field pointing at it.

## What was built

`site/index.html`, `site/site.css`, and `site/hero.png` — plus two
scripts that exist so the image is never edited by hand:

- `site/hero.sh` is a scene, like the gallery's: a session drawn with
  escape sequences. A bench run, an agent editing a file, a framed prompt
  asking whether to apply a patch, a status line reading *4 sessions ·
  1 needs you*. It is the product thesis in one frame, and it says
  `doot` in the box where the bell would ring.
- `site/render.sh` runs that scene through the real binary headless at
  2×, the way `zig build gallery` does, and writes the PNG. 1044 × 704,
  67 KB.

The page's register is the one the name set: a goofy little app with
serious insides. The lede is the README's sentence; the tagline says
what the name is; the download note says, in plain words, that the
build is unsigned and still needs Homebrew's two libraries, and that the
page will say when that stops being true. Nothing on the page is a claim
the repository does not already make.

Palette: the terminal's own theme for dark, a scheme derived from it for
light, following `prefers-color-scheme`. Type: the system monospace,
which is what the terminal uses too. The favicon is a 100-byte inline
SVG of the cursor block.

`.github/workflows/pages.yml` deploys on a push to `main` that touches
`site/`, and holds the two promises a diff cannot show — no script tag,
and the byte budget — as a step that fails the deploy.

## Measured

| | |
|---|---|
| Lighthouse, mobile emulation (412 px, 1.75×) | performance 100 · accessibility 100 · best practices 100 · SEO 100 |
| Horizontal overflow at 320 px and 375 px | none — `scrollWidth` equals the viewport in both, measured by loading the page in iframes of those widths and reading the DOM |
| Page with image | 74,966 bytes of a 307,200 budget |
| `<script>` tags | 0 |
| Repository homepage | set |

Rendered and looked at, in dark and light at 1280 px and at 320 and
375 px, before it was committed. A note for whoever does this next:
headless Chrome's `--window-size` will not go below roughly 500 px wide
on macOS, so a "375 px" screenshot is a 375 px crop of a wider layout;
the iframe harness is how a narrow width is actually rendered and
measured. The one thing found by looking:
two glyphs in the first draft of the scene — `❯` and `✚` — are not in
the system face and rendered as nothing, exactly as
[X2](../experience.md)'s "where we are" table says they will until a
fallback face exists. The scene uses `$` and `*` instead. That is what a
scene rendered by the real binary is for.

## What it does not do yet

- Link to docs on the site: the links go to GitHub until
  [W1](../website.md) renders `docs/` and the engineering log.
- Numbers from the file: the three figures in the copy are typed from
  `bench/baseline.txt` and `--frame-stats` today. [W2](../website.md)
  draws them from the file at build time, and the copy says so.
- Deploy the `hero.sh` and `render.sh` sources as part of the artifact:
  they are uploaded with the page, which is harmless and a little
  untidy. W1's generator writes to an output directory and fixes it.
