#!/bin/sh
# Render the front page's frame with the real binary, headless, at 2x --
# the same way `zig build gallery` renders a scene. The PNG this writes is
# the only image on the site, and it is regenerated, never edited.
#
#   zig build -Doptimize=ReleaseFast && site/render.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bin=${1:-"$here/../zig-out/bin/doot"}
SDL_VIDEODRIVER=dummy "$bin" \
    --shell "$here/hero.sh" --size 60x20 --font-size 14 --scale 2 \
    --screenshot "$here/hero.png"
ls -l "$here/hero.png"
