#!/bin/sh
# Tests for changelog-section.sh and zon-version.sh.
#
# These two scripts gate every release, and a gate that fails open is worse
# than no gate -- code review of the sprint that added them found exactly
# that: a `## ` line inside a fenced code block ended the section early and
# still exited 0, publishing a body cut off mid-fence.
#
# Run directly, or via `zig build test-scripts`.

set -eu

here=$(dirname "$0")
section="$here/changelog-section.sh"
zon="$here/zon-version.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

check() { # name expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else
        fail "$1"
        printf '        want: %s\n        got:  %s\n' "$2" "$3"
    fi
}

check_fails() { # name file version
    if "$section" "$3" "$2" >/dev/null 2>&1; then
        fail "$1 (exited 0; a gate must fail closed)"
    else
        pass "$1"
    fi
}

printf 'changelog-section.sh\n'

cat > "$tmp/basic.md" <<'MD'
# Changelog

## [Unreleased]

Nothing yet.

## [0.2.0] — 2026-09-01

Body line.

### Added

- A thing.

## [0.1.0] — 2026-08-28

Older.

[0.2.0]: https://example.invalid/2
MD

check "extracts a section" \
    "Body line.
### Added
- A thing." \
    "$($section 0.2.0 "$tmp/basic.md" | grep -v '^$')"

check "a leading v is accepted" \
    "Body line." \
    "$($section v0.2.0 "$tmp/basic.md" | head -1)"

check "stops before the link-reference block" \
    "Older." \
    "$($section 0.1.0 "$tmp/basic.md" | grep -v '^$')"

check_fails "a missing version fails" "$tmp/basic.md" 9.9.9
check_fails "a missing file fails" "$tmp/nope.md" 0.2.0
check_fails "a directory instead of a file fails" "$tmp" 0.2.0

# A version whose section is present but empty is as bad as an absent one:
# it would publish a release with no notes.
printf '# C\n\n## [0.3.0]\n\n## [0.2.0]\n\nreal\n' > "$tmp/empty.md"
check_fails "an empty section fails" "$tmp/empty.md" 0.3.0
printf '# C\n\n## [0.3.0]\n\n\n\n## [0.2.0]\n\nreal\n' > "$tmp/blank.md"
check_fails "a blank-only section fails" "$tmp/blank.md" 0.3.0

# The silent-wrong-content case: a heading inside a fence is content.
printf '# C\n\n## [0.3.0]\n\nBefore.\n\n```sh\n## not a heading\necho hi\n```\n\nAfter.\n\n## [0.2.0]\n\nold\n' > "$tmp/fence.md"
check "a ## line inside a fence does not truncate" \
    "After." \
    "$($section 0.3.0 "$tmp/fence.md" | tail -1)"
check "the fence itself is kept intact" \
    "2" \
    "$($section 0.3.0 "$tmp/fence.md" | grep -c '^```')"

# Version matching is exact, so neighbours and prefixes never collide.
printf '# C\n\n## [0.1.0-rc1]\n\nprerelease\n\n## [0.10.0]\n\nten\n\n## [0.1.0]\n\nplain\n' > "$tmp/near.md"
check "0.1.0 does not match 0.1.0-rc1 or 0.10.0" "plain" "$($section 0.1.0 "$tmp/near.md")"
check "0.1.0-rc1 matches only itself" "prerelease" "$($section 0.1.0-rc1 "$tmp/near.md")"
check "0.10.0 matches only itself" "ten" "$($section 0.10.0 "$tmp/near.md")"

# A CRLF changelog trims the same way a LF one does.
printf '# C\r\n\r\n## [0.3.0]\r\n\r\nBody.\r\n\r\n## [0.2.0]\r\n\r\nold\r\n' > "$tmp/crlf.md"
check "CRLF blank lines are trimmed" "1" "$($section 0.3.0 "$tmp/crlf.md" | wc -l | tr -d ' ')"

# The repository's own changelog must satisfy its own gate.
check "the committed changelog has a section for its version" \
    "0" \
    "$($section "$("$zon")" >/dev/null 2>&1; echo $?)"

printf 'zon-version.sh\n'

check "reads .version" "0.1.0" "$("$zon" "$here/../build.zig.zon")"

printf '.{\n    .name = .x,\n    .fingerprint = 0x1,\n}\n' > "$tmp/noversion.zon"
if "$zon" "$tmp/noversion.zon" >/dev/null 2>&1; then
    fail "a zon with no .version fails"
else
    pass "a zon with no .version fails"
fi

if [ "$fails" -eq 0 ]; then
    printf '\nall script tests passed\n'
else
    printf '\n%d script test(s) failed\n' "$fails"
    exit 1
fi
