# Website roadmap

The marketing site, on GitHub Pages. It is the first screenshot most
people will ever see of this terminal, so it is held to the
[experience](experience.md) bar — and it is built the way the terminal
is: from scratch, no framework, nothing linked that is not the
platform. Sized for one person at 8–12 focused hours a week. Sprint
prefix: **W**.

Arbiter: **a fresh visitor and Lighthouse.** Someone who has never heard
of the project goes from the link to a running terminal without a
question; Lighthouse scores 100 on all four axes; and every number on
the site was generated from a file in the repository.

## The one rule for the site

**Nothing on the site that the repository does not already produce.**
The screenshot is a gallery capture. The numbers are `bench/baseline.txt`.
The docs are `docs/`. The release notes are `CHANGELOG.md`. The
engineering stories are the sprint records. Marketing copy that can
drift from the truth is not written; a page that renders artifacts
cannot drift.

## Where we are

| | Today | Where |
|---|---|---|
| Site | One page at [oddurs.github.io/doot](https://oddurs.github.io/doot/), deployed from `site/` by Actions (W0) | `.github/workflows/pages.yml` |
| Screenshots | The gallery's references, and the front page's frame, rendered by the binary from a scene | `bench/gallery/`, `site/render.sh` |
| Pitch | The README's first paragraph and the repository description | `README.md` |
| Docs | Fourteen files under `docs/`, readable only on GitHub | `docs/` |
| Numbers | `bench/baseline.txt`, `--frame-stats` output in sprint records | `bench/`, `docs/roadmap/completed/` |
| Changelog | `CHANGELOG.md`, Keep-a-Changelog form | — |
| Name | `doot`, since [the rename](completed/sprint-n-rename-doot.md): four letters, no Homebrew or GitHub collision, `doot.sh` free at the time | — |
| Domain | None | — |

## The sprints

### W0 — The one page — **done**

`site/index.html` and `site/site.css`, written by hand. No build step,
no JavaScript, no web font — the system monospace, which is what the
terminal uses too. Deployed by an Actions workflow with
`actions/deploy-pages` from `site/`, so there is no `gh-pages` branch to
keep in sync.

On the page, in order:

1. **One real screenshot**, full width, captured with `--screenshot` at
   2× — the flag exists today, so the first version ships with a real
   frame, and [X0](experience.md)'s gallery replaces it with a
   maintained one.
2. **One sentence.** The README's: a terminal emulator for macOS,
   written in Zig; the parser, the grid, the scrollback and the atlas
   from scratch.
3. **A download button** that links to `releases/latest` — GitHub
   resolves it, no script needed — and the cask line once
   [P2](platform.md) exists. Until [P1](platform.md) has signing, the
   button says so in one line beneath it.
4. **What is ours** — the table from [dependencies.md](dependencies.md),
   which is the pitch.
5. Links: docs, changelog, the repository.

Design: the terminal's own theme, both of [X4](experience.md)'s once
they exist, following `prefers-color-scheme`. Monospace-forward,
generous measure, one accent. It should look like a frame from the
terminal, because the screenshot is one.

*Why here:* the site can exist the day the screenshot can, and that day
is today.

*Done when:* Lighthouse 100 / 100 / 100 / 100; the page including the
screenshot is under 300 KB; it reads at 320 px wide; there is no
`<script>` tag; the repository's homepage field points at it.

*Risk:* low. The temptation is to add a second page; W1 is where that
happens.

*Result:* done — [oddurs.github.io/doot](https://oddurs.github.io/doot/).
Lighthouse 100 / 100 / 100 / 100 under mobile emulation, 74,966 bytes
with the image, no script tag, the homepage field set. The frame is a
scene rendered by the binary itself (`site/hero.sh`, `site/render.sh`),
and rendering it found two glyphs the system face lacks. See
[the record](completed/sprint-w0-site.md).

### W1 — Docs and the engineering log (one week)

A generator, `site/build.py`, beside `bench/gen_corpus.py` and with the
same rule — standard library only. It renders `docs/` to `/docs/…` and
`CONTRIBUTING.md` to `/contributing/`, with a Markdown subset written
in the script: headings, paragraphs, lists, tables, code, links,
emphasis. That is every construct the docs use, and the generator fails
the build on one it does not know rather than passing it through.

The sprint records under `completed/` become **the engineering log** at
`/log/`, newest first, each with its date from `git log`. A 150× win, a
4.3× win, and two sprints retired by their gates before a line was
written are the best marketing the project has, and they are already
written.

Every internal link is checked at build time; a broken one fails the
deploy.

*Why here:* after W0 exists to hang it on, and because the roadmaps and
records are the content the site has that no competitor's does.

*Done when:* every file under `docs/` has a URL; `/log/` lists every
record; the build fails on a broken link or an unknown construct.

*Risk:* low. The Markdown subset is small because the docs are
disciplined; keep both true.

### W2 — Numbers that are live (one week)

- **The bench table** on the front page, rendered from
  `bench/baseline.txt` at build time — corpus, MiB/s, what it is. When
  the baseline changes, the site changes.
- **A history**: each tagged release's baseline kept under
  `bench/history/<tag>.txt`, and the front page draws one SVG line per
  corpus across releases — generated by the script, no chart library,
  no script tag. A number that goes down is drawn going down.
- **The typography page** from the gallery, at 1× and 2×, so a visitor
  can judge the rendering before installing.
- **The link line** from [D5](dependencies.md) — `libc, AppKit, Metal,
  QuartzCore` — as a badge, generated from `otool -L` in the release
  workflow. When it is that short, say so.

*Why here:* after [V1](releases.md) starts recording a baseline per
release, so there is a history to draw.

*Done when:* the numbers on the site are byte-identical to the files in
the repository at the deployed commit, checked by a test in the build.

*Risk:* low.

### W3 — Releases on the site (half a week)

`/releases/` from `CHANGELOG.md` in [V3](releases.md)'s shape, one page
per version, the latest three with download links, the nightly noted
once [P1](platform.md) makes it a download. An Atom feed, written by the
same script — a feed is a hundred lines of XML and needs no library —
covering releases and the engineering log.

The site rebuilds on every push to `main` and on every release tag.

*Done when:* a release tag produces a release page and a feed entry
within fifteen minutes of the workflow finishing.

*Risk:* low.

### W5 — The player page (half a week)

`/play/`: the browser player ([M4](compatibility.md)) on a page of its
own, the one page on the site with a script tag, and the site says so
on it. Drop an exported session file ([L4](record.md)) onto it and it
plays; a few of the engineering log's recordings — the 150× before and
after, an agent session from the corpus — are linked as examples. A
visitor sees a real session at full fidelity before installing
anything, and a colleague sent a transcript needs nothing installed to
read it.

*Why here:* after M4 and L4; it is their public face.

*Done when:* an exported session opens from a link and plays with the
same grid the app shows; the rest of the site still has no script tag.

*Risk:* low.

### W4 — Launch (one week) — **gated**

- **The name** is settled — *doot, a terminal for macOS* — and the
  description says Zig in the first line. A domain, if one is wanted, is
  `doot.sh` (free at the time of the rename) as a custom domain on Pages
  with HTTPS; until then `oddurs.github.io/doot` is fine and permanent.
- **An Open Graph image** generated from the gallery capture, so the
  link unfurls as the screenshot everywhere it is pasted.
- **The README links the site** in its first paragraph.
- **One post**, drafted from the engineering log — the story is
  measured sprints and the two that were retired — for wherever the
  maintainer wants to put it.

*Gate:* not before [P1](platform.md) has signing and the
[0.5 "our window"](releases.md) release has shipped. A launch that
sends people to a Gatekeeper dialog, or to a binary that needs
Homebrew, spends the only first impression the project gets.

*Done when:* a person who has never heard of the project goes from the
link to a running terminal in under two minutes with no terminal
commands; the link unfurls as a screenshot.

*Risk:* low in code, high in timing. The gate is the whole sprint.

## Why this order

- **W0 today**, because the screenshot flag exists and a page with one
  real frame beats a page with a paragraph.
- **W1 next**, because the docs and the log are the content.
- **W2 after V1** has a baseline per release to draw.
- **W3 with V3**, since both render the same file.
- **W4 gated** on a release worth sending people to.

## Not on this plan

- **Analytics, cookies, a consent banner.** Nothing is collected, so
  there is nothing to consent to. The site has no script tag.
- **A framework, a CMS, a theme.** Two files and a script in the
  standard library, like everything else here.
- **A comparison table.** Other terminals are named as prior art and as
  test oracles — kitty and Ghostty draw their own box glyphs, and the
  docs say so — never as a column with an X in it.
- **A newsletter.** The feed is the newsletter.
- **A separate documentation site.** `/docs/` on this one, from the
  same files.
