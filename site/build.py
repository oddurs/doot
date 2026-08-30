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


# ---- inline ---------------------------------------------------------------

INLINE = re.compile(
    r"(?P<code>`[^`]+`)"
    r"|(?P<bold>\*\*(?P<btext>[^*]+)\*\*)"
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
    s = "".join(out)
    if "<" in text.replace("<code>", "") and re.search(r"<[a-zA-Z/!][^>]*>", text):
        # Raw HTML outside of inline code is not in the subset; inside
        # code it was escaped above, so anything that survives is real.
        if re.search(r"<[a-zA-Z/!][^>]*>", re.sub(r"`[^`]+`", "", text)):
            raise Unsupported("raw html: " + text.strip()[:60])
    return s


# ---- blocks ---------------------------------------------------------------

class Doc:
    def __init__(self, src_rel, pages):
        self.src_rel = src_rel
        self.src = REPO / src_rel
        self.url = pages[src_rel]
        self.pages = pages
        self.refs = {}
        self.links = []  # (target, resolved) for the checker
        self.title = None

    def href(self, target):
        """Rewrite a Markdown link target to where it lives on the site."""
        if re.match(r"^[a-z]+:", target) or target.startswith("#"):
            return target
        path, _, frag = target.partition("#")
        rel = (self.src.parent / path).resolve()
        try:
            rel = rel.relative_to(REPO).as_posix()
        except ValueError:
            raise Unsupported("link escapes the repository: " + target)
        if rel in self.pages:
            resolved = BASE + self.pages[rel] + "/" + ("#" + frag if frag else "")
        elif (REPO / rel).exists():
            resolved = BLOB + rel + ("#" + frag if frag else "")
        else:
            resolved = None
        self.links.append((target, resolved))
        return resolved or target


def render(doc):
    lines = doc.src.read_text(encoding="utf-8").split("\n")
    # Reference definitions first, so a link can precede its definition.
    for line in lines:
        m = re.match(r"^\[([^\]]+)\]:\s+(\S+)\s*$", line)
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
        if re.match(r"^\[([^\]]+)\]:\s+\S+\s*$", line):
            i += 1
            continue
        m = re.match(r"^(#{1,6}) (.*)$", line)
        if m:
            level = len(m.group(1))
            text = m.group(2).strip()
            if doc.title is None and level == 1:
                doc.title = re.sub(r"`", "", text)
            slug = re.sub(r"[^a-z0-9]+", "-", re.sub(r"`|\*", "", text).lower()).strip("-")
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
            rows = [r.strip().strip("|").split("|") for r in lines[i:j]]
            if len(rows) < 2 or not all(re.match(r"^\s*:?-+:?\s*$", c) for c in rows[1]):
                raise Unsupported("table without an alignment row at line %d" % (i + 1))
            head, rest = rows[0], rows[2:]
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
            item_re = re.compile(r"^(\d+\.|[-*]) (.*)$") if True else None
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
                    sub = lines[j].strip()
                    nm = re.match(r"^(\d+\.) (.*)$", sub)
                    if nm and (nested or lines[j].startswith("  " + nm.group(1))):
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
        crumbs.append('<a href="%s%s/">%s</a>' % (BASE, acc, html.escape(p)))
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


def git_date(path):
    out = subprocess.run(
        ["git", "log", "--diff-filter=A", "--follow", "--format=%cI", "--", path],
        cwd=REPO, capture_output=True, text=True,
    ).stdout.strip().splitlines()
    if not out:
        return None
    return datetime.fromisoformat(out[-1]).astimezone(timezone.utc)


def build(check=False):
    pages = sources()
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
        for target, resolved in d.links:
            if resolved is None:
                problems.append("%s: broken link %s" % (rel, target))

    # Write pages.
    if OUT.exists():
        for p in sorted(OUT.rglob("*"), reverse=True):
            p.unlink() if p.is_file() else p.rmdir()
    OUT.mkdir(parents=True, exist_ok=True)
    for name in ("index.html", "site.css", "hero.png"):
        (OUT / name).write_bytes((SITE / name).read_bytes())
    for rel, (d, body) in docs.items():
        dest = OUT / d.url.lstrip("/") / "index.html"
        dest.parent.mkdir(parents=True, exist_ok=True)
        src_link = '<a href="%s%s">source</a>' % (BLOB, rel)
        dest.write_text(page(d.title, body, d.url, subtitle=src_link), encoding="utf-8")

    # The engineering log: completed records, newest first.
    records = []
    for rel, (d, body) in docs.items():
        if rel.startswith("docs/roadmap/completed/"):
            records.append((git_date(rel), d, body))
    records.sort(key=lambda r: (r[0] or datetime.min.replace(tzinfo=timezone.utc)), reverse=True)
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
    print("wrote %d pages to %s" % (n_pages, OUT.relative_to(REPO)))
    if problems:
        print("\n".join(problems), file=sys.stderr)
        if check:
            sys.exit(1)
    return problems


if __name__ == "__main__":
    build(check="--check" in sys.argv)
