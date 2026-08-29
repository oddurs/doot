# Security policy

## Supported versions

terminator is pre-1.0 and moves fast. Only `main` is supported — fixes land
there, and there are no backports to older tags.

## Reporting a vulnerability

Report privately through GitHub's
[security advisories](https://github.com/oddurs/terminator/security/advisories/new).
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
- An escape sequence that causes terminator to execute something, write
  outside its own state, or leak memory contents to the screen.
- Anything that lets terminal output inject input back into the shell as if
  typed. Bracketed paste and clipboard handling are the sensitive paths here.
- Denial of service that a short byte sequence triggers — an unbounded
  allocation or a hang from a crafted sequence.

## What is not

- The known gaps listed in the README under "Not done yet". They are missing
  features, not vulnerabilities.
- A crash you can only reach by passing hostile arguments on your own command
  line. If you can run `terminator --shell ...`, you can already run anything.
- Bugs in SDL3 or FreeType. Report those upstream; tell us if terminator uses
  them in a way that makes it worse.
