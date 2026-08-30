# Sprint W2 — Numbers that are live

**Done.** The bench table and its history on
[the front page](https://oddurs.github.io/doot/#numbers), and the
gallery's references at [/rendering/](https://oddurs.github.io/doot/rendering/).

## What was proposed

The bench table on the front page rendered from `bench/baseline.txt` at
build time; a history, one line per corpus across releases, drawn as an
SVG by the script with no chart library and no script tag; the
typography page from the gallery at 1× and 2×; and the link line from
`otool -L` as a badge once [D5](../dependencies.md) makes it short.

The roadmap sequenced this after [V1](../releases.md) "starts recording
a baseline per release", under `bench/history/<tag>.txt`.

## What was built

**No history directory.** Every tagged release already carries its
baseline: `git show v0.1.0:bench/baseline.txt` is the file as it was
when the tag was cut, and `main`'s copy is the newest point. So the
history is derived from tags at build time — one `git show` per tag —
and there is no second copy of any number anywhere. V1 gets a smaller
job: tag, and the chart grows a point.

`site/build.py` gained three pieces, about 80 lines:

- `parse_baseline` reads the parse table — fixed-width columns, so a
  regular expression per row — into `{corpus: (MiB/s, what it is)}`.
- `history` walks `git tag -l 'v*'` in version order, parses each tag's
  copy, and appends `main`.
- `bench_svg` draws it: a gridline every quarter of the range, one
  polyline and one dot per corpus, the label at the line's end. Labels
  are then pushed apart so no two are closer than a line of text —
  `sgr`, `altscreen` and the two agent corpora sit within 20 MiB/s of
  each other and collided on the first draw. It is 3 KB of SVG inline
  on the page, and it uses `currentColor`, so it follows the theme.

The front page became a template with one slot, `<!-- numbers -->`, that
the build fills; the build fails if the slot is missing. The sentence
that typed "490 MiB/s" into the copy in W0 is gone — the number is drawn
now, which is what W0's record said would happen.

`/rendering/` shows four of the gallery's committed references — the
typography page at 1× and 2×, the attribute sheet, the colour sheet —
copied byte-for-byte from `bench/gallery/expected/`, never re-encoded.
It says plainly which ranges still render as nothing.

**The badge waits.** Until D5, the link line is `libc, SDL3, FreeType,
Metal…` — true, but not the sentence the badge is for. The page says
so in the "what is ours" table instead.

## Measured

| | |
|---|---|
| Pages | 41 |
| Front page with image | 82,271 bytes of a 307,200 budget; the SVG is 3,186 of them |
| Numbers typed by hand on the site | 0 — every one is read from `bench/baseline.txt` or a tag's copy |
| Lighthouse, front page | 100 · 100 · 100 · 100 |
| Gallery images copied | 4, 94 KB together, byte-identical to the references |

Two tags' worth of history draws two points per corpus — v0.1.0 and
`main` — and the two agent corpora, recorded after v0.1.0, draw one.
That is the chart being honest about how young the project is.

## What it does not do yet

- `--frame-stats` figures. They need a window and a quiet machine, so
  they live in the sprint records, quoted from runs, until
  [Sprint 6](../performance.md) puts a latency line into the baseline
  file that this same parser can read.
- The gate on the numbers: the front page reads the baseline, but
  nothing yet fails a build when a tag's baseline is *slower* than the
  previous tag's. That is [T3](../testing.md)'s ratio check, on the
  bench side, not the site's.
