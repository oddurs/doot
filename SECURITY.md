# Security policy

## Supported versions

doot is pre-1.0 and moves fast. Only `main` is supported — fixes land
there, and there are no backports to older tags.

## Reporting a vulnerability

Report privately through GitHub's
[security advisories](https://github.com/oddurs/doot/security/advisories/new).
Please do not open a public issue for a vulnerability.

Expect an acknowledgement within a week. Since this is a personal project
rather than a funded one, a fix timeline depends on severity, but you will get
a straight answer about where it stands rather than silence.

## What is in scope

A terminal emulator parses untrusted bytes for a living — anything that writes
to your terminal, including `cat` on a hostile file, `curl` of a hostile URL,
or a compromised process on a remote host, controls that input. Bugs worth
reporting privately:

- Memory unsafety reachable from PTY output: out-of-bounds access in the
  parser, grid, scrollback ring, or glyph atlas.
- An escape sequence that causes doot to execute something, write
  outside its own state, or leak memory contents to the screen.
- Anything that lets terminal output inject input back into the shell as if
  typed. Bracketed paste and clipboard handling are the sensitive paths here.
- Denial of service that a short byte sequence triggers — an unbounded
  allocation or a hang from a crafted sequence.

## What the terminal will never send back

Programs can ask a terminal questions, and some of the answers would be a
way to read the screen, the title or the clipboard — and, by asking for
the title after setting it to a command, a way to type. doot's rule, held
by a test per row in [docs/security.md](docs/security.md): **it never
sends the child bytes derived from screen content, the title, the
clipboard, or another tab.** A reply carries only what the child could
already know — modes, capabilities, the cursor position. A reply that
breaks that rule is a vulnerability; report it privately.

## Session recording

doot records every session's **output** to disk by default, and says so
in the window title for as long as it is happening. Keystrokes are never
recorded unless you ask (`--record-input`, or `Cmd ⇧ R`), `--incognito`
records nothing, and `--no-record` turns it off. Files are `0600` in a `0700`
directory, are swept after 14 days, and never leave the machine.

The full privacy shape — what is recorded, what is redacted on the way in,
where the files live, how long they are kept, and what deleting one actually
deletes — is
[the privacy section of docs/roadmap/record.md](docs/roadmap/record.md#privacy-is-the-design),
and the policy it is held to, with a test per line, is
[S6 in docs/roadmap/security.md](docs/roadmap/security.md#s6--the-records-privacy-with-l0-then-per-sprint).

A recording that carries a secret it should have redacted, a file or directory
created with a wider mode than those, a session recorded when the flags said
not to, or a keystroke in a file that was not asked to hold one, is a
vulnerability. Report it privately.

## What is not

- The known gaps listed in the README under "Not done yet". They are missing
  features, not vulnerabilities.
- A crash you can only reach by passing hostile arguments on your own command
  line. If you can run `doot --shell ...`, you can already run anything.
- Bugs in SDL3 or FreeType. Report those upstream; tell us if doot uses
  them in a way that makes it worse.
