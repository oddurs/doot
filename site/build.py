#!/usr/bin/env python3
"""Build the site from what the repository already produces.

Standard library only, like bench/gen_corpus.py. Renders docs/ and
CONTRIBUTING.md through a Markdown subset that covers exactly the
constructs the docs use -- headings, paragraphs, tables, fenced code,
lists, blockquotes, a rule, and inline code / bold / italic / links --
and refuses anything else, so a construct the renderer does not know
fails the build instead of passing through as text.

    site/build.py            # writes site/out/
    site/build.py --check    # build, then exit non-zero on any broken link

The engineering log at /log/ is the completed sprint records, newest
first, dated from git. Links between documents are rewritten to their
pages; links to files the site does not render go to GitHub.
"""

import html
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

SITE = Path(__file__).resolve().parent
REPO = SITE.parent
OUT = SITE / "out"
GITHUB = "https://github.com/oddurs/doot"
# Project pages are served under the repository name. SITE_BASE= renders
# for a local root, e.g. `SITE_BASE= python3 site/build.py`.
BASE = os.environ.get("SITE_BASE", "/doot")
BLOB = GITHUB + "/blob/main/"
TREE = GITHUB + "/tree/main/"
REF_DEF = re.compile(r"^\[([^\]]+)\]:\s+(\S+)\s*$")


def tracked():
    """Every path git knows, so a link to something only on disk fails here too."""
    out = subprocess.run(["git", "ls-files", "-z"], cwd=REPO, capture_output=True, text=True).stdout
    return set(out.split("\0")) - {""}


TRACKED = None
PAGE_URLS = set()

# What gets rendered, and where. Keys are repo-relative source paths;
# values are site paths (directories -- every page is <dir>/index.html).
def sources():
    pages = {}
    for md in sorted((REPO / "docs").rglob("*.md")):
        rel = md.relative_to(REPO).as_posix()
        if md.name == "README.md":
            url = "/" + rel[: -len("README.md")].rstrip("/")
        else:
            url = "/" + rel[: -len(".md")]
        pages[rel] = url.rstrip("/") or "/docs"
    pages["CONTRIBUTING.md"] = "/contributing"
    return pages


class Unsupported(Exception):
    pass


def github_slug(text):
    """The id GitHub gives a heading, so anchors written for GitHub work here."""
    t = re.sub(r"[`*_\[\]()]", "", text).lower()
    t = "".join(ch for ch in t if ch.isalnum() or ch in " -")
    return t.replace(" ", "-")


# ---- inline ---------------------------------------------------------------

INLINE = re.compile(
    r"(?P<code>`[^`]+`)"
    r"|(?P<bold>\*\*(?P<btext>.+?)\*\*)"
    r"|(?P<strike>~~(?P<stext>[^~]+)~~)"
    r"|(?P<em>(?<![\w*])\*(?P<etext>[^*\s][^*]*?)\*(?![\w*]))"
    r"|(?P<img>!\[(?P<ialt>[^\]]*)\]\((?P<isrc>[^)]+)\))"
    r"|(?P<link>\[(?P<ltext>[^\]]+)\]\((?P<lhref>[^)]+)\))"
    r"|(?P<ref>\[(?P<rtext>[^\]]+)\]\[(?P<rkey>[^\]]*)\])"
)


def inline(text, ctx):
    out = []
    pos = 0
    for m in INLINE.finditer(text):
        out.append(html.escape(text[pos : m.start()]))
        pos = m.end()
        if m.group("code"):
            out.append("<code>" + html.escape(m.group("code")[1:-1]) + "</code>")
        elif m.group("bold"):
            out.append("<strong>" + inline(m.group("btext"), ctx) + "</strong>")
        elif m.group("em"):
            out.append("<em>" + inline(m.group("etext"), ctx) + "</em>")
        elif m.group("strike"):
            out.append("<s>" + inline(m.group("stext"), ctx) + "</s>")
        elif m.group("img"):
            # Only the README's badges use images, and the README is not
            # rendered here; a doc that adds one gets a GitHub-hosted image
            # rather than a copied asset.
            out.append(
                '<img alt="%s" src="%s">' % (html.escape(m.group("ialt")), html.escape(m.group("isrc")))
            )
        elif m.group("link"):
            href = ctx.href(m.group("lhref"))
            out.append('<a href="%s">%s</a>' % (html.escape(href, quote=True), inline(m.group("ltext"), ctx)))
        elif m.group("ref"):
            key = (m.group("rkey") or m.group("rtext")).lower()
            if key not in ctx.refs:
                raise Unsupported("undefined reference link [%s]" % key)
            href = ctx.href(ctx.refs[key])
            out.append('<a href="%s">%s</a>' % (html.escape(href, quote=True), inline(m.group("rtext"), ctx)))
    out.append(html.escape(text[pos:]))
    # Raw HTML is not in the subset. Inside inline code it was escaped
    # above; anything tag-shaped that survives outside code is refused.
    if re.search(r"<[a-zA-Z/!][^>]*>", re.sub(r"`[^`]+`", "", text)):
        raise Unsupported("looks like raw html, which is not in the subset: " + text.strip()[:60])
    return "".join(out)


# ---- blocks ---------------------------------------------------------------

class Doc:
    def __init__(self, src_rel, pages):
        self.src_rel = src_rel
        self.src = REPO / src_rel
        self.url = pages[src_rel]
        self.pages = pages
        self.refs = {}
        self.links = []  # (target, resolved, target_rel, fragment) for the checker
        self.ids = set()
        self.title = None

    def href(self, target):
        """Rewrite a Markdown link target to where it lives on the site."""
        if re.match(r"^[a-z]+:", target):
            return target
        if target.startswith("#"):
            self.links.append((target, target, self.src_rel, target[1:]))
            return target
        path, _, frag = target.partition("#")
        rel = (self.src.parent / path).resolve()
        try:
            rel = rel.relative_to(REPO).as_posix()
        except ValueError:
            raise Unsupported("link escapes the repository: " + target)
        readme = rel.rstrip("/") + "/README.md"
        if rel in self.pages:
            resolved = BASE + self.pages[rel] + "/" + ("#" + frag if frag else "")
        elif rel.rstrip("/") == "docs/roadmap/completed":
            resolved, rel = BASE + "/log/", None
        elif readme in self.pages:
            resolved, rel = BASE + self.pages[readme] + "/", readme
        elif rel in TRACKED:
            resolved = BLOB + rel + ("#" + frag if frag else "")
            rel = None  # GitHub's page, not ours to check anchors on
        elif any(t.startswith(rel.rstrip("/") + "/") for t in TRACKED):
            resolved, rel = TREE + rel.rstrip("/"), None
        else:
            resolved = None
        self.links.append((target, resolved, rel, frag))
        return resolved or target


def split_row(line):
    r"""A table row's cells: split on `|` outside code spans; `\|` is a pipe."""
    cells, cur, in_code, k = [], [], False, 0
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith("\\|"):
        line = line[:-1]
    while k < len(line):
        ch = line[k]
        if ch == "\\" and k + 1 < len(line) and line[k + 1] == "|":
            cur.append("|")
            k += 2
            continue
        if ch == "`":
            in_code = not in_code
        if ch == "|" and not in_code:
            cells.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        k += 1
    cells.append("".join(cur))
    return cells


def render(doc):
    lines = doc.src.read_text(encoding="utf-8").split("\n")
    # Reference definitions first, so a link can precede its definition.
    for line in lines:
        m = REF_DEF.match(line)
        if m:
            doc.refs[m.group(1).lower()] = m.group(2)
    body = []
    i = 0
    n = len(lines)

    def para_end(j):
        while j < n and lines[j].strip() and not re.match(r"^(#{1,6} |```|\||[-*] |\d+\. |> |---$|\[[^\]]+\]:\s)", lines[j]):
            j += 1
        return j

    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        if REF_DEF.match(line):
            i += 1
            continue
        m = re.match(r"^(#{1,6}) (.*)$", line)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            if doc.title is None and level == 1:
                doc.title = re.sub(r"`", "", text)
            slug = github_slug(text)
            doc.ids.add(slug)
            body.append('<h%d id="%s">%s</h%d>' % (level, slug, inline(text, doc), level))
            i += 1
            continue
        if line.startswith("```"):
            j = i + 1
            while j < n and not lines[j].startswith("```"):
                j += 1
            if j >= n:
                raise Unsupported("unterminated code fence at line %d" % (i + 1))
            body.append("<pre><code>" + html.escape("\n".join(lines[i + 1 : j])) + "</code></pre>")
            i = j + 1
            continue
        if line.startswith("|"):
            j = i
            while j < n and lines[j].startswith("|"):
                j += 1
            rows = [split_row(r) for r in lines[i:j]]
            if len(rows) < 2 or not all(re.match(r"^\s*:?-+:?\s*$", c) for c in rows[1]):
                raise Unsupported("table without an alignment row at line %d" % (i + 1))
            head, rest = rows[0], rows[2:]
            for k, r in enumerate(rows):
                if len(r) != len(head):
                    raise Unsupported("table row %d has %d cells, the header has %d" % (i + 1 + k, len(r), len(head)))
            t = ["<table><thead><tr>"]
            t += ["<th>%s</th>" % inline(c.strip(), doc) for c in head]
            t.append("</tr></thead><tbody>")
            for r in rest:
                t.append("<tr>" + "".join("<td>%s</td>" % inline(c.strip(), doc) for c in r) + "</tr>")
            t.append("</tbody></table>")
            body.append("".join(t))
            i = j
            continue
        if line == "---":
            body.append("<hr>")
            i += 1
            continue
        if line.startswith("> "):
            j = i
            while j < n and lines[j].startswith(">"):
                j += 1
            quoted = " ".join(l[1:].strip() for l in lines[i:j])
            body.append("<blockquote><p>%s</p></blockquote>" % inline(quoted, doc))
            i = j
            continue
        m = re.match(r"^([-*]|\d+\.) ", line)
        if m:
            ordered = m.group(1)[0].isdigit()
            tag = "ol" if ordered else "ul"
            items = []
            j = i
            while j < n:
                mm = re.match(r"^(\d+\.|[-*]) (.*)$", lines[j])
                if not mm or (mm.group(1)[0].isdigit()) != ordered:
                    break
                text = [mm.group(2)]
                j += 1
                # continuation lines are indented; a nested ordered list is
                # indented too, and is the only nesting the docs use.
                nested = []
                while j < n and lines[j].startswith("  ") and lines[j].strip():
                    raw = lines[j]
                    sub = raw.strip()
                    if re.match(r"^[-*+] ", sub) or sub.startswith("```"):
                        raise Unsupported("a nested bullet or a fence inside a list item at line %d" % (j + 1))
                    nm = re.match(r"^(\d+\.) (.*)$", sub)
                    if nm:
                        if not raw.startswith("  " + nm.group(1)):
                            raise Unsupported("a nested ordered item must be indented exactly two spaces, line %d" % (j + 1))
                        nested.append(nm.group(2))
                    elif nested:
                        nested[-1] += " " + sub
                    else:
                        text.append(sub)
                    j += 1
                item = inline(" ".join(text), doc)
                if nested:
                    item += "<ol>" + "".join("<li>%s</li>" % inline(x, doc) for x in nested) + "</ol>"
                items.append("<li>%s</li>" % item)
            body.append("<%s>%s</%s>" % (tag, "".join(items), tag))
            i = j
            continue
        if re.match(r"^\s+\S", line):
            raise Unsupported("indented block outside a list at line %d: %s" % (i + 1, line.strip()[:50]))
        j = para_end(i)
        if j == i:
            raise Unsupported("unrecognised line %d: %s" % (i + 1, line[:60]))
        body.append("<p>%s</p>" % inline(" ".join(l.strip() for l in lines[i:j]), doc))
        i = j
    if doc.title is None:
        raise Unsupported("no h1")
    return "\n".join(body)


# ---- numbers ---------------------------------------------------------------
#
# W2: the bench table and its history are drawn from bench/baseline.txt --
# the current file, and each tagged release's copy via `git show`. No
# second copy of any number exists on the site.

def parse_baseline(text):
    """The parse table of bench/baseline.txt: {corpus: (mibs, what)}."""
    rows = {}
    in_parse = False
    for line in text.splitlines():
        if line.startswith("parse:"): in_parse = True; continue
        if in_parse and line.startswith(("scroll:", "scan:")): break
        m = re.match(r"^\s{2}([a-z0-9-]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(.*)$", line)
        if in_parse and m:
            rows[m.group(1)] = (float(m.group(2)), m.group(6).strip())
    return rows

def history(repo):
    tags = subprocess.run(["git","tag","-l","v*","--sort=version:refname"], cwd=repo, capture_output=True, text=True).stdout.split()
    points = []
    for t in tags:
        txt = subprocess.run(["git","show",f"{t}:bench/baseline.txt"], cwd=repo, capture_output=True, text=True).stdout
        if txt: points.append((t, parse_baseline(txt)))
    head = open(repo+"/bench/baseline.txt").read()
    points.append(("main", parse_baseline(head)))
    return points

def bench_svg(points, width=640, height=220):
    corpora = [c for c in points[-1][1]]
    colours = ["#7fd6c1","#61afef","#e5c07b","#c678dd","#8fbf7f","#e06c75","#56b6c2"]
    top = max(v[0] for _, rows in points for v in rows.values()) * 1.1
    pad_l, pad_r, pad_t, pad_b = 48, 150, 14, 30
    W = width - pad_l - pad_r; H = height - pad_t - pad_b
    n = len(points)
    def x(i): return pad_l + (W * i / max(n-1, 1))
    def y(v): return pad_t + H - H * v / top
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-label="Parse throughput per corpus, by release" font-family="ui-monospace, SF Mono, Menlo, monospace" font-size="11">']
    for g in range(0, 5):
        v = top * g / 4; yy = y(v)
        out.append(f'<line x1="{pad_l}" y1="{yy:.1f}" x2="{pad_l+W}" y2="{yy:.1f}" stroke="currentColor" stroke-opacity="0.15"/>')
        out.append(f'<text x="{pad_l-6}" y="{yy+4:.1f}" text-anchor="end" fill="currentColor" fill-opacity="0.6">{v:.0f}</text>')
    for i, (label, _) in enumerate(points):
        out.append(f'<text x="{x(i):.1f}" y="{height-10}" text-anchor="middle" fill="currentColor" fill-opacity="0.6">{label}</text>')
    labels = []
    for k, c in enumerate(corpora):
        col = colours[k % len(colours)]
        pts = [(x(i), y(rows[c][0])) for i, (_, rows) in enumerate(points) if c in rows]
        d = " ".join(f"{px:.1f},{py:.1f}" for px, py in pts)
        out.append(f'<polyline fill="none" stroke="{col}" stroke-width="2" points="{d}"/>')
        for px, py in pts: out.append(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="3" fill="{col}"/>')
        labels.append([pts[-1][1], col, f"{c} {points[-1][1][c][0]:.0f}"])
    # Labels are placed at their line's end, then pushed apart so that no
    # two are closer than a line of text, walking down from the top.
    labels.sort(key=lambda l: l[0])
    gap = 13
    for i in range(1, len(labels)):
        if labels[i][0] - labels[i-1][0] < gap:
            labels[i][0] = labels[i-1][0] + gap
    overflow = labels[-1][0] - (pad_t + H)
    if overflow > 0:
        for l in labels: l[0] -= overflow
    lx = x(n - 1) + 8
    for ly, col, text in labels:
        out.append(f'<text x="{lx:.1f}" y="{ly+4:.1f}" fill="{col}">{text}</text>')
    out.append("</svg>")
    return "\n".join(out)


def bench_table(rows):
    out = ['<table class="bench"><thead><tr><th>corpus</th><th>MiB/s</th><th>what it is</th></tr></thead><tbody>']
    for name, (mibs, what) in sorted(rows.items(), key=lambda kv: -kv[1][0]):
        out.append("<tr><td><code>%s</code></td><td>%.1f</td><td>%s</td></tr>" % (html.escape(name), mibs, html.escape(what)))
    out.append("</tbody></table>")
    return "".join(out)


def numbers_html():
    points = history(str(REPO))
    rows = points[-1][1]
    head = (REPO / "bench/baseline.txt").read_text(encoding="utf-8").splitlines()
    machine = next((l.strip() for l in head if "zig " in l), "")
    figure = (
        '<figure class="chart">%s<figcaption>Parse throughput per corpus, MiB/s, at each tagged release and on <code>main</code>. '
        'Drawn from <code>bench/baseline.txt</code> at build time; a number that goes down is drawn going down.</figcaption></figure>'
        % bench_svg(points)
    )
    note = '<p class="fine">%s — best of nine repetitions on a quiet machine. The shared CI runner posts its own numbers on every PR and they are labelled as indicative.</p>' % html.escape(machine)
    return bench_table(rows) + figure + note


# ---- pages ----------------------------------------------------------------

def describe(body):
    """The first paragraph, as plain text, for the page's description."""
    m = re.search(r"<p>(.*?)</p>", body, re.S)
    text = html.unescape(re.sub(r"<[^>]+>", "", m.group(1))) if m else ""
    return (text[:157] + "…") if len(text) > 160 else text


def page(title, body, url, subtitle=None):
    crumbs = []
    parts = [p for p in url.split("/") if p]
    acc = ""
    for p in parts[:-1]:
        acc += "/" + p
        if acc == "/docs/roadmap/completed":
            crumbs.append('<a href="%s/log/">%s</a>' % (BASE, html.escape(p)))
        elif acc in PAGE_URLS:
            crumbs.append('<a href="%s%s/">%s</a>' % (BASE, acc, html.escape(p)))
        else:
            crumbs.append(html.escape(p))
    nav = " / ".join(['<a href="%s/">doot</a>' % BASE] + crumbs)
    sub = "<p class=\"sub\">%s</p>" % subtitle if subtitle else ""
    return """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s — doot</title>
<meta name="description" content="%s">
<meta name="color-scheme" content="dark light">
<link rel="stylesheet" href="%s/site.css">
<link rel="icon" href="data:image/svg+xml,%%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%%3E%%3Crect width='16' height='16' rx='3' fill='%%2310141a'/%%3E%%3Crect x='3' y='4' width='3' height='8' fill='%%237fd6c1'/%%3E%%3C/svg%%3E">
</head>
<body class="doc">
<nav class="crumbs">%s</nav>
<main>
%s%s
</main>
<footer><p>Rendered from <a href="%s">the repository</a> by <code>site/build.py</code>. No script, no tracking.</p></footer>
</body>
</html>
""" % (html.escape(title), html.escape(describe(body), quote=True), BASE, nav, body, sub, GITHUB)


GALLERY = (
    "typography-14pt-1x.png", "typography-14pt-2x.png",
    "attributes-14pt-2x.png", "colors-14pt-2x.png",
)


def rendering_html():
    def fig(name, caption):
        return '<figure><img src="%s/gallery/%s" alt="%s" loading="lazy"><figcaption>%s</figcaption></figure>' % (
            BASE, name, html.escape(caption), html.escape(caption))
    return "".join([
        '<h1 id="rendering">How it renders</h1>',
        "<p>These are the gallery's reference captures &mdash; the images <code>zig build gallery</code> diffs every change against, "
        "rendered by the terminal itself, headless, and committed. What you see here is what the pixels are. "
        "The ranges the system face lacks &mdash; braille, CJK, emoji &mdash; still render as nothing; that is X2 on the "
        "experience roadmap, and the typography page is where it will show up first.</p>",
        fig("typography-14pt-1x.png", "The typography page at 14 pt, 1×: printable ASCII, box drawing, blocks, braille, CJK, combining marks."),
        fig("typography-14pt-2x.png", "The same page at 2×, which is what a Retina display shows."),
        fig("attributes-14pt-2x.png", "Every SGR attribute the parser accepts, at 2×."),
        fig("colors-14pt-2x.png", "The sixteen ANSI colours and the 256-colour cube, at 2×."),
        '<p>How the gallery works, and how to add a scene: <a href="%s/docs/gallery/">docs/gallery</a>.</p>' % BASE,
    ])


def added_dates(directory):
    """{path: datetime} for every file under `directory`, from the commit that added it.

    One git call; the log is newest first, so the last mention of a path
    is the commit that added it. The datetime keeps the commit's own
    offset, because the day it was committed is the day to show.
    """
    out = subprocess.run(
        ["git", "log", "--diff-filter=A", "--format=%x1e%cI", "--name-only", "--", directory],
        cwd=REPO, capture_output=True, text=True,
    ).stdout
    dates = {}
    for block in out.split("\x1e"):
        lines = [l for l in block.strip().splitlines() if l.strip()]
        if not lines:
            continue
        when = datetime.fromisoformat(lines[0])
        for path in lines[1:]:
            dates[path] = when
    return dates


def build(check=False):
    global TRACKED, PAGE_URLS
    TRACKED = tracked()
    pages = sources()
    PAGE_URLS = set(pages.values())
    docs = {}
    problems = []
    for rel in pages:
        d = Doc(rel, pages)
        try:
            body = render(d)
        except Unsupported as e:
            problems.append("%s: %s" % (rel, e))
            continue
        docs[rel] = (d, body)
        for target, resolved, _, _ in d.links:
            if resolved is None:
                problems.append("%s: broken link %s" % (rel, target))
    # Anchors, once every page knows its ids.
    for rel, (d, body) in docs.items():
        for target, resolved, target_rel, frag in d.links:
            if frag and target_rel in docs and frag not in docs[target_rel][0].ids:
                problems.append("%s: dead anchor %s" % (rel, target))

    # Write pages.
    if OUT.exists():
        for p in sorted(OUT.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ("site.css", "hero.png"):
        (OUT / name).write_bytes((SITE / name).read_bytes())
    index = (SITE / "index.html").read_text(encoding="utf-8")
    if "<!-- numbers -->" not in index:
        raise SystemExit("site/index.html has lost its <!-- numbers --> slot")
    (OUT / "index.html").write_text(index.replace("<!-- numbers -->", numbers_html()), encoding="utf-8")
    # The gallery's references, so a visitor can judge the rendering
    # before installing: the typography page at 1x and 2x, and the
    # attribute and colour sheets. Copied, never re-encoded.
    (OUT / "gallery").mkdir(exist_ok=True)
    for name in GALLERY:
        (OUT / "gallery" / name).write_bytes((REPO / "bench/gallery/expected" / name).read_bytes())
    (OUT / "rendering").mkdir(exist_ok=True)
    (OUT / "rendering" / "index.html").write_text(page("How it renders", rendering_html(), "/rendering"), encoding="utf-8")
    for rel, (d, body) in docs.items():
        dest = OUT / d.url.lstrip("/") / "index.html"
        dest.parent.mkdir(parents=True, exist_ok=True)
        src_link = '<a href="%s%s">source</a>' % (BLOB, rel)
        dest.write_text(page(d.title, body, d.url, subtitle=src_link), encoding="utf-8")

    # The engineering log: completed records, newest first.
    records = []
    dates = added_dates("docs/roadmap/completed")
    for rel, (d, body) in docs.items():
        if rel.startswith("docs/roadmap/completed/"):
            if rel not in dates:
                problems.append("%s: no commit adds it, so the log cannot date it (a shallow clone?)" % rel)
            records.append((dates.get(rel), d, body))
    records.sort(key=lambda r: (r[0] or datetime.min.replace(tzinfo=timezone.utc)).timestamp(), reverse=True)
    items = []
    for when, d, body in records:
        first_p = re.search(r"<p>(.*?)</p>", body)
        blurb = first_p.group(1) if first_p else ""
        items.append(
            '<li><span class="when">%s</span> <a href="%s%s/">%s</a><p>%s</p></li>'
            % (when.strftime("%Y-%m-%d") if when else "", BASE, d.url, html.escape(d.title), blurb)
        )
    log_body = (
        '<h1 id="log">The engineering log</h1>'
        "<p>One record per sprint: what was proposed, what was measured, and what it changed about the plan. "
        "Two of them retired their own work before a line was written, and those are the most useful ones.</p>"
        '<ul class="log">%s</ul>' % "".join(items)
    )
    (OUT / "log").mkdir(exist_ok=True)
    (OUT / "log" / "index.html").write_text(page("The engineering log", log_body, "/log"), encoding="utf-8")

    n_pages = len(docs) + 2
    print("wrote %d pages to %s" % (n_pages + 1, OUT.relative_to(REPO)))
    if problems:
        print("\n".join(problems), file=sys.stderr)
        if check:
            sys.exit(1)
    return problems


if __name__ == "__main__":
    build(check="--check" in sys.argv)
