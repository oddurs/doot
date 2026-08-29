# Sprint N — Rename to doot

**Done.** The project was called terminator from its first commit
(2026-08) until this sprint.

## Why the name had to change

`terminator` is the name of a well-known GNOME terminal. Every roadmap that
touched distribution ran into it: the Homebrew cask would have been
ambiguous ([P2](../platform.md)), the bundle id needed a disambiguating
comment ([P0](../platform.md)), and the website roadmap's first row under
"where we are" was that a search for the name finds the other one
([W4](../website.md)). It had to change before the site (W0) and the
bundle (P0) baked it in, and both were near the top of the order.

## Why doot

Two directions were tried — names from the film, and names from Duke Nukem
— and checked against what actually blocks a name: a Homebrew formula or
cask, a popular GitHub repository, and the obvious domains.

| candidate | verdict |
|---|---|
| `doot` | four letters; sounds like a bell; no Homebrew entry; no GitHub repository of that exact name; `doot.sh` free |
| `technoir` | free, and names the aesthetic — runner-up |
| `mimetic` | the T-1000's polyalloy; free, but adjective-shaped |
| `holoduke` | free, and the best joke (a hologram of Duke is an emulator), but eight letters and inside a trademark |
| `skynet`, `hail`, `tape`, `reel` | ★5k–14k projects of the same name; every domain gone |

`doot` won because it is the only candidate that names what the product is
*for*: the bell that reaches you when an agent needs you
([A1](../agentic.md), [A7](../agentic.md)) is the agentic roadmap's first
visible feature, and `doot` is the sound it makes. `kitty`, `foot` and
`ghostty` established that a terminal can have a silly name and be taken
seriously; the name is the least serious thing about any of them.

## What changed

- The binary, the bundle id, `TERM_PROGRAM`, the window title, `--help`,
  `--version`, the release artifact names, the recordings directory
  (`~/Library/Application Support/doot/sessions`), the config path
  ([K0](../config.md) will read `~/.config/doot/config`), the `zon`
  package name, and every document under `docs/`.
- The GitHub repository: `oddurs/terminator` → `oddurs/doot`. GitHub
  redirects the old name for both the web and `git`, so existing clones
  and the other sessions' worktrees keep working; `git remote set-url` is
  the tidy version.
- The `tui` gallery scene prints the name in bold, so its references were
  re-rendered with `zig build gallery -- --update`; the diff is the word.
- `scripts/worktree.sh` now names its root after the checkout directory,
  so a checkout called `doot` gets `doot-wt` and one still called
  `terminator` keeps working.

## What did not

- **The recorded corpora.** `bench/corpus/agent-stream.bin` contains the
  old name because the session it recorded printed it. Corpora are
  committed bytes; changing one voids every baseline that came before.
  It stays.
- **The local checkout's directory name.** Every worktree's `.git` file
  points at the main checkout by absolute path; renaming the directory
  while sessions are running would break all of them. Rename it when
  nothing is running, then `git worktree repair`.
- **Old URLs in merged PRs and closed issues.** They redirect.
