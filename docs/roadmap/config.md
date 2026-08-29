# Configuration roadmap

One file, every setting, and a key that opens it. Sized for one person
at 8–12 focused hours a week. Sprint prefix: **K**.

Arbiter: **one source of truth.** Every setting is a field on one struct
with a type, a default and a doc comment, and the parser, the CLI flags,
`+help`, the template, and the website's reference page are all derived
from it. If two of those can disagree, the sprint is not done.

## The model

The Ghostty model, chosen on purpose: a flat text file, `key = value`,
no framework, no GUI, no scripting language. A file is data. It is
readable in any editor, diffable, copyable between machines, and
explainable in one screen of `--help`.

```
# ~/.config/doot/config

font-family        = SF Mono
font-size          = 14
theme              = light:paper, dark:ink
scrollback-lines   = 10000
cursor-style       = bar
copy-on-select     = false
paste-guard        = true
record-input       = false
record-retain-days = 30

keybind = cmd+t=new_tab
keybind = cmd+shift+a=next_attention
keybind = cmd+enter=text:\x1b\r

config-file = ~/.config/doot/work.conf
```

Rules of the format, all of them:

- `key = value`, one per line; whitespace around `=` ignored; `#` to
  end of line is a comment; a blank line is nothing.
- A value runs to the end of the line. Quotes are literal unless the
  key's type is a string and the value is wrapped in `"…"`, which is
  how a leading or trailing space is kept.
- **Repeated keys append** for list-typed keys (`keybind`,
  `font-family` as a fallback chain, `config-file`) and **replace** for
  everything else. The last write wins.
- `config-file = path` includes another file, relative to the one that
  named it, at that point in the order.
- Precedence: built-in defaults → the file → files it includes, in
  order → command-line flags. A flag is the same key with `--` in front:
  `--font-size=18` and `font-size = 18` are one thing.
- An unknown key or a bad value is an **error on that line**, reported
  with the line, and the rest of the file still applies. A config file
  never prevents the terminal from opening.

## Where we are

| | Today | Where |
|---|---|---|
| Config file | **None.** | — |
| Settings | Six flags: `--font-size`, `--shell`, `--frame-stats`, `--size`, `--scale`, `--screenshot` — plus `--help` and `--version` | `src/cli.zig` `parseArgs`, landed with V0 |
| Defaults | Constants: font size 14, 100×30, scrollback 10,000, padding 6, wheel × 3 | `cli.zig`, `terminal.zig` `scrollback_lines`, `render.zig` `pad`, `main.zig` `handleWheel` |
| Theme | One, hard-coded | `theme.zig` `default` |
| Keybinds | Fixed: `Cmd + - 0 V K` | `main.zig` `handleKey` |
| `Cmd ,` | Does nothing | — |
| Docs for settings | `--help`, one screen, hand-written | `cli.zig` `help` |

V0's `cli.zig` is the right seed: a typed `Options` struct with a parser
and tests. K0 grows it into the struct everything derives from.

## The sprints

### K0 — The struct, the file, the flags (one week)

`src/config.zig` with one `Config` struct. Every field carries its type,
its default, and a doc comment that is the documentation — the only
copy of it. Field metadata says whether a change applies **live** or
needs a **restart**, and from which version the key exists.

Derived from the struct by comptime reflection, so none of it can drift:

- the file parser — a field's type decides how its value is read
  (`bool`, integer with bounds, `[]const u8`, colour, enum, list);
- the flag parser — `--key=value` for every field, replacing the
  hand-written arm per flag in `cli.zig`;
- `--help`, one line per key from the doc comment's first sentence;
- the template (K2), every key commented out with its default and doc.

The file lives at `$XDG_CONFIG_HOME/doot/config`, falling back to
`~/.config/doot/config`; on macOS
`~/Library/Application Support/doot/config` is read too, after
it, for people who expect that. `--config-file` adds one more.

Every constant that is really a setting becomes a key in this sprint:
`font-size`, `font-family`, `shell`, `initial-size`, `scrollback-lines`,
`padding`, `scroll-multiplier`, `frame-stats`, `screenshot`. Later
sprints add theirs the sprint they land — this is the file the
[record](record.md)'s retention key, the [paste guard](security.md)'s
switch and the [bell](agentic.md)'s behaviour were each waiting for.

*Why here:* early. Six roadmaps have a sprint that wants a key, and
each was about to invent a place to put it.

*Done when:* every flag today is a key and the flag still works;
`--help` is generated; a unit test round-trips the template through the
parser to the defaults; a file with a bad line and a good line applies
the good one and reports the bad one with its line number.

*Risk:* low. The reflection is the interesting part and it is a
hundred lines of comptime.

### K1 — Feedback: errors, the effective config, `+` commands (one week)

- **Errors are shown, not logged.** On launch, or on reload, any error
  lines appear in the grid for one frame set — file, line, message, in
  the theme's error colour — until a keypress. `stderr` gets them too,
  for scripts.
- **`doot +show-config`** prints the effective configuration:
  every key, its value, and where it came from — default, which file
  and line, or the flag. `--changes-only` shows what differs from
  default; `--default` shows the defaults alone.
- **`+validate-config`** parses and exits non-zero on any error, for
  editors and CI.
- **`+help key`** prints the key's full doc comment, type, default and
  since-version. `+list-keys`, `+list-actions`, `+list-themes`,
  `+list-fonts` list what the other sprints add.

The `+` form is Ghostty's convention for "this is not a terminal
session"; it keeps flags for settings and `+verbs` for tools, and it is
the shape [A6](agentic.md)'s `doot open` will use too.

*Done when:* `+show-config` on a file with an include shows the
included file's line numbers; the error overlay is in the gallery.

*Risk:* low.

### K2 — `Cmd ,` opens the config, in a tab (one week)

The action `open_config`, bound to `Cmd ,` by default:

- If the file does not exist, **write the template** — every key,
  commented out, with its default and its doc — and open that.
- **Open a new tab** running `$VISUAL`, else `$EDITOR`, else `vi`, on
  the file, with the tab titled *config*. The terminal is the right
  place to edit its own config; that is the point of the request.
- **When the editor exits, reload.** Also reload on `reload_config`
  (bound to `Cmd ⇧ ,`) and when the file's mtime has changed at focus
  gain — which costs nothing while idle.
- **Reload reports.** Errors go to the overlay (K1); keys marked
  *restart* that changed are listed in one line — *`shell` will apply
  to new tabs* — so a reload never silently half-applies.
- Before tabs exist ([A5](agentic.md)), `open_config` opens the file
  with the OS's default editor, which is what Ghostty does and is
  correct for a single-window terminal. The in-tab behaviour is the
  reason this sprint is sequenced after A5.

*Done when:* `Cmd ,` on a fresh machine writes the template and opens it
in a tab; saving a font-size change and quitting the editor changes
the font in the next frame; a syntax error shows in the overlay with
its line and the previous config stays in effect.

*Risk:* low. The reload must be atomic — parse fully into a new struct,
swap on success, never apply a half-parsed file.

### K3 — Themes as config (half a week, with X4)

A theme is a config file that sets only colour keys — `background`,
`foreground`, `cursor-color`, `cursor-text`, `selection-background`,
`selection-foreground`, `palette = N=#rrggbb` — found by `theme = name`
in `~/.config/doot/themes/name`, then among the bundled ones
embedded in the binary. `theme = light:paper, dark:ink` picks by system
appearance and switches live ([X4](experience.md)). `+list-themes`
lists both directories; a theme file is a config file, so `+validate-
config` validates it.

*Done when:* the two bundled themes are files, the gallery renders
both, and a user theme with a bad palette line reports the line.

*Risk:* none.

### K4 — Keybinds as config (half a week, with E6)

`keybind = trigger=action` — `cmd+shift+t=new_tab`, `ctrl+l=text:\x0c`,
`cmd+k=unbind`. Triggers: modifiers `cmd`, `ctrl`, `alt`, `shift`, then
a key name from a fixed list or a printable character. Actions from
[E6](essentials.md)'s table, with an argument after `:`. `text:` sends
bytes, with escapes. The defaults are themselves written as `keybind`
lines and `+list-keybinds` prints them with the overrides marked.
Two bindings on one trigger is an error naming both lines.

*Done when:* `+list-keybinds` shows every default; a rebinding takes
effect on reload; an `unbind` removes a default.

*Risk:* low.

### K5 — The reference, generated (half a week, with W1)

`site/build.py` asks the binary — `doot +list-keys --json` — and
renders `/docs/config/`: one page, every key, its type, default, doc,
since-version, and whether it reloads live. The same doc comments back
`+help`. Deprecated keys carry a `deprecated` note and a replacement,
per [V2](releases.md)'s rule that a minor removes nothing; they warn,
never fail.

*Done when:* the site's reference and the binary's `+help` are the same
text because they have the same source.

*Risk:* none.

## Why this order

- **K0 first**, and early on the priorities order, because six roadmaps
  are waiting for a key.
- **K1 immediately**, because a config file without error reporting
  teaches people to distrust it.
- **K2 after A5**, since the tab is the feature; the OS-editor fallback
  covers the gap.
- **K3 with X4, K4 with E6, K5 with W1** — each is the config half of a
  sprint that lives elsewhere.

## Not on this plan

- **A settings window.** The file is the settings. A second place to
  change them is a second source of truth.
- **TOML, YAML, JSON, or a scripting language.** A file is data;
  `key = value` needs no library and no spec beyond the eight rules
  above. Lua-style configuration is a program, and a program's bugs are
  the user's to debug.
- **Profiles.** `config-file` includes and `--config-file` on the
  command line cover "a different setup for this window" without a new
  concept. Revisit if includes prove insufficient.
- **Per-tab or per-host configuration.** After [A8](agentic.md) shows
  what host-awareness actually needs.
- **Syncing.** It is a file; the user's dotfiles repository is the
  sync.
