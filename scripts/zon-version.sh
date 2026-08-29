#!/bin/sh
# Print build.zig.zon's `.version` -- the one source of truth for the number.
#
# The release workflow compares this against the tag being built. Without
# that check the changelog gate is satisfied by a hand-written section
# alone, and a `v0.2.0` tag can ship a binary that reports 0.1.0 and
# exports TERM_PROGRAM_VERSION=0.1.0 -- exactly the drift having one source
# of truth was supposed to remove.
#
#   scripts/zon-version.sh [build.zig.zon]

set -eu

file=${1:-"$(dirname "$0")/../build.zig.zon"}

version=$(
    sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1
)

if [ -z "$version" ]; then
    echo "zon-version: no .version found in $file" >&2
    exit 1
fi

printf '%s\n' "$version"
