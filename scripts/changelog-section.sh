#!/bin/sh
# Print CHANGELOG.md's section for a version, or fail if there isn't one.
#
# The release workflow uses this for both of its jobs at once: it refuses
# to publish a tag the changelog says nothing about, and it uses what the
# changelog does say as the release body. Notes generated from PR titles
# alone are a list of commits; they go underneath, not instead.
#
#   scripts/changelog-section.sh 0.1.0 [CHANGELOG.md]
#   scripts/changelog-section.sh v0.1.0          # leading v is fine
#
# Exits 1 with a message on stderr when the section is missing or empty,
# which is what makes it a gate rather than a formatter.

set -eu

version=${1:?usage: changelog-section.sh VERSION [FILE]}
version=${version#v}
file=${2:-"$(dirname "$0")/../CHANGELOG.md"}

if [ ! -r "$file" ]; then
    echo "changelog-section: cannot read $file" >&2
    exit 1
fi

# Everything between this version's heading and the next `## ` heading,
# with blank lines trimmed off both ends.
#
# Fences are tracked because a `## ` line inside a code block is content,
# not a heading -- ending the section there would publish a body cut off
# mid-fence, and would do it while exiting 0. For a gate, silently wrong
# content is worse than a hard failure.
#
# The link-reference block at the bottom of the file starts with `[`, so
# it ends the section too. `\r` is tolerated so a CRLF changelog trims the
# same way a LF one does.
section=$(
    awk -v want="## [$version]" '
        function blank(s) { sub(/\r$/, "", s); return s == "" }
        substr($0, 1, length(want)) == want { found = 1; next }
        !found { next }
        /^(```|~~~)/ { lines[++n] = $0; last = n; fence = !fence; next }
        !fence && /^## / { exit }
        !fence && /^\[[^]]+\]:/ { exit }
        { lines[++n] = $0; if (!blank($0)) last = n }
        END {
            first = 1
            while (first <= last && blank(lines[first])) first++
            for (i = first; i <= last; i++) print lines[i]
        }
    ' "$file"
)

if [ -z "$section" ]; then
    echo "changelog-section: CHANGELOG.md has no section for $version" >&2
    echo "changelog-section: add a '## [$version]' heading before tagging" >&2
    exit 1
fi

printf '%s\n' "$section"
