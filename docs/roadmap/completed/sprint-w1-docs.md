# Sprint W1 — Docs and the engineering log

**Done.** [oddurs.github.io/doot/docs/](https://oddurs.github.io/doot/docs/)
and [/log/](https://oddurs.github.io/doot/log/).

## What was proposed

A generator beside `bench/gen_corpus.py`, with the same rule — standard
library only — rendering `docs/` and `CONTRIBUTING.md` through a Markdown
subset written in the script: exactly the constructs the docs use, and a
build that fails on one it does not know rather than passing it through.
The completed sprint records as the engineering log, newest first, dated
from git. Every internal link checked at build time.

## What was built

`site/build.py`, about 350 lines, no imports outside the standard
library. Before writing it, the constructs in every Markdown file in the
repository were counted, so the subset is a measurement rather than a
guess:

| construct | occurrences | rendered as |
|---|---|---|
| headings, some with inline code or a link | 391 | `h1`–`h6` with an id |
| table rows, always with an alignment row | 622 | `table` with `thead` |
| inline code | 1,665 | `code`, HTML-escaped — `<name>` inside backticks was the only "raw HTML" in the docs |
| bold, italic | 786, 363 | `strong`, `em` |
| inline links; a few reference-style ones | 399, 2 | `a`, rewritten to the page they name |
| `-` and `*` bullets; ordered lists, one nesting level | 537, 26 | `ul`, `ol` |
| fenced code, blockquotes, one rule | 46, 10, 1 | `pre`, `blockquote`, `hr` |

Anything else — a footnote, raw HTML outside code, an indented block that
is not a list, a table without its alignment row — raises `Unsupported`
and the build exits non-zero.

Links between documents become links between pages. A link to a file the
site does not render (`bench/baseline.txt`, `src/terminal.zig`) becomes a
GitHub link; a link to a file that does not exist is a broken link and
fails `--check`. The site lives under `/doot/` on GitHub Pages, so every
generated href carries that base; `SITE_BASE=` renders for a local root.

The engineering log at `/log/` lists every record under
`docs/roadmap/completed/`, newest first, dated from the commit that added
it, with the record's first paragraph as the blurb. The pages workflow
now fetches history for that, builds with `--check`, and uploads
`site/out/` — which also stops `hero.sh` and `render.sh` being published
with the page, the untidiness W0 noted.

## Measured

| | |
|---|---|
| Documents rendered | 37 under `docs/`, plus `CONTRIBUTING.md`; 40 pages with the front page and the log — the count the build prints |
| Unsupported constructs found in the docs | 0 |
| Broken links found by the build | 0 |
| Internal links crawled over HTTP under `/doot/`, from six pages | 41, all resolve |
| Lighthouse, a roadmap page and the log | 100 · 100 · 100 · 100, both — after the generator learned to write a meta description from the first paragraph, which was the one point it lost |

Looked at, over HTTP so the stylesheet resolved: a roadmap page (tables,
nested ordered lists), a retired sprint record (a blockquote, a table
inside prose), and the log. The document pages use the front page's
stylesheet with a section for prose: a 78-character measure, `#` and
`##` before headings in the dim colour, code blocks on a slightly lifted
panel, tables that scroll inside themselves on a narrow screen.

## What it does not do yet

- Render the README or the changelog. The README is the repository's
  front page and the site has its own; the changelog is
  [W3](../website.md)'s, with the feed.
- Anchor links between documents (`file.md#section`) are carried through
  as written; heading ids are the slugified text, which matches the
  GitHub convention for every anchor the docs currently use.
