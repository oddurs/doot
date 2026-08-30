#!/bin/sh
# The frame on the front page. A real session, drawn by doot itself:
# site/render.sh runs this scene through the binary headless at 2x, the way
# the gallery does, and the PNG it writes is the only image on the site.
#
# Only glyphs the gallery already proves render: box drawing, ✓ ✚ …, the
# 16 colours, bold, dim, reverse. No emoji until X2 lands a fallback face.

bold='\033[1m'; dim='\033[2m'; rev='\033[7m'; off='\033[0m'
grn='\033[32m'; yel='\033[33m'; blu='\033[34m'; mag='\033[35m'; cyn='\033[36m'; red='\033[31m'

printf '\033[2J\033[H\033[?25l'
printf "${dim}~/code/doot${off} ${cyn}main${off}${grn}*${off}\n"
printf "${mag}\$${off} zig build bench\n"
printf "${dim}  corpus        MiB/s   what it is${off}\n"
printf "  ascii         ${bold}490.2${off}   plain source dump\n"
printf "  altscreen     394.2   full-screen app redraw\n"
printf "  sgr           372.2   colourised build log\n"
printf "  cjk           181.9   wide and multibyte text\n"
printf "\n"
printf "${mag}\$${off} claude ${dim}\"make the atlas two pages\"${off}\n"
printf "  ${dim}…${off} reading ${blu}src/font.zig${off}\n"
printf "  ${yel}●${off} edited  ${blu}src/font.zig${off}  ${grn}+41${off} ${red}−7${off}\n"
printf "  ${grn}✓${off} zig build test   ${bold}387 passed${off}\n"
printf "\n"
printf "  ┌──────────────────────────────────────────────┐\n"
printf "  │ ${bold}doot${off}  ${cyn}the atlas needs a second page. apply?${off}  │\n"
printf "  │ ${dim}y  apply    n  skip    d  show the diff${off}      │\n"
printf "  └──────────────────────────────────────────────┘\n"
printf "\n"
printf "${rev} 4 sessions ${off} ${dim}2 running${off}  ${yel}1 needs you${off}  ${dim}1 done${off}"
