#!/bin/sh
# Dump the benchmark corpora at the terminal and exit.
#
# Pointed at with `--shell`, this turns the app into an end-to-end benchmark:
#
#   zig build -Doptimize=ReleaseFast
#   ./zig-out/bin/terminator --frame-stats --shell bench/dump.sh
#
# The window opens, the corpora stream through the real PTY, parser, grid and
# renderer, the child exits and so does the app, and stderr carries one line
# per second plus a totals line with the MiB/s the PTY was actually drained
# at. That is the figure `zig build bench` structurally cannot produce: it has
# no window, so the mutex is never contended and no frame is ever presented.
#
# PASSES controls how many times each corpus is written; 16 corpora-passes is
# 24 MiB, which is long enough to swamp start-up and short enough to sit
# through.

passes=${PASSES:-16}
dir=$(dirname "$0")/corpus

i=0
while [ "$i" -lt "$passes" ]; do
    for f in ascii sgr scroll altscreen cjk region; do
        cat "$dir/$f.bin"
    done
    i=$((i + 1))
done
