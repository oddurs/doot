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
# with blank lines trimmed off both ends. The link-reference block at the
# bottom of the file starts with `[`, not `## `, so it is excluded by
# matching only headings -- and by the trailing-blank trim.
section=$(
    awk -v want="## [$version]" '
        substr($0, 1, length(want)) == want { found = 1; next }
        found && /^## / { exit }
        found && /^\[[^]]+\]:/ { exit }
        found { lines[++n] = $0; if (NF) last = n }
        END {
            first = 1
            while (first <= last && lines[first] == "") first++
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
