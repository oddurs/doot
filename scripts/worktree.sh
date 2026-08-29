#!/bin/sh
# One working copy per agent session.
#
# Two Claude sessions sharing a checkout will switch branches under each
# other. That is not a theoretical risk: it has already put a finished
# commit on the wrong branch, and made a session grep a file it thought was
# `main` and reach a wrong conclusion about the repository. Neither is
# detectable from inside the session that suffers it.
#
# A worktree gives each session its own directory and its own checked-out
# branch, sharing one .git. Nothing else changes: same history, same
# remotes, `gh` works the same.
#
#   scripts/worktree.sh new  <branch>   create ../<repo>-wt/<branch> and print where
#   scripts/worktree.sh list            what exists, and what each is on
#   scripts/worktree.sh done <branch>   remove it (refuses if it has uncommitted work)
#   scripts/worktree.sh prune           forget worktrees whose directory is gone

set -eu

# The main checkout, wherever this is run from. --show-toplevel would name
# the *current* worktree, so run from inside one the root became
# <repo>-wt/<repo>-wt and `done` could not find anything. The
# common git dir is the main checkout's .git no matter which worktree
# asks.
repo=$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")
# Named after the checkout, so a directory called doot gets doot-wt and one
# still called doot keeps doot-wt.
root=$(dirname "$repo")/$(basename "$repo")-wt

usage() {
    sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

case "${1:-}" in
new)
    branch=${2:?usage: worktree.sh new <branch>}
    dir="$root/$(printf '%s' "$branch" | tr '/' '-')"
    [ -e "$dir" ] && { echo "worktree: $dir already exists" >&2; exit 1; }
    git -C "$repo" fetch --quiet origin
    mkdir -p "$root"
    # Always branch from origin/main, never from whatever this checkout
    # happens to have out -- that is the whole point.
    git -C "$repo" worktree add --quiet -b "$branch" "$dir" origin/main
    echo "$dir"
    ;;
list)
    git -C "$repo" worktree list
    ;;
done)
    branch=${2:?usage: worktree.sh done <branch>}
    dir="$root/$(printf '%s' "$branch" | tr '/' '-')"
    [ -d "$dir" ] || { echo "worktree: no such worktree $dir" >&2; exit 1; }
    case "$(pwd -P)/" in "$dir"/*)
        echo "worktree: you are standing in $dir; cd out of it first" >&2
        exit 1
        ;;
    esac
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        echo "worktree: $dir has uncommitted changes; commit or discard them first" >&2
        git -C "$dir" status --short >&2
        exit 1
    fi
    git -C "$repo" worktree remove "$dir"
    echo "removed $dir"
    ;;
prune)
    git -C "$repo" worktree prune -v
    ;;
*)
    usage
    ;;
esac
