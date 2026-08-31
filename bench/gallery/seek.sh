#!/bin/sh
# L1's scene, and the only one whose point is a frame that is no longer on
# the screen when the shell exits.
#
# A full-screen program takes the alt screen, draws, and leaves. Every other
# terminal throws that frame away at `?1049l`; here the recording still has
# it, and `--seek-span 1` is `Cmd shift Up` -- the last frame of the most
# recently closed full-screen program. What the capture photographs is that
# frame plus the seek status row, so the picture is of something the live
# terminal cannot show.
#
# Fixed bytes, no `vim`: the gallery's rule is that a scene prints exactly
# what it prints, whatever is installed on the machine.

printf '\033[2J\033[H'
printf '$ ls\n'
printf 'Makefile   README.md  build.zig  src/\n'
printf '$ zig build test\n'
printf 'All tests passed.\n'
printf '$ agent run --watch\n'

# In. From here to `?1049l` is a program nobody can scroll back into.
printf '\033[?1049h\033[2J\033[H'
printf '\033[7m agent \033[0m  run --watch                    \033[32m2 done\033[0m \033[33m1 running\033[0m\n'
printf '\n'
printf '  \033[32m\342\234\223\033[0m  read  src/ckpt.zig            \033[2m1,246 lines\033[0m\n'
printf '  \033[32m\342\234\223\033[0m  read  src/seek.zig            \033[2m  566 lines\033[0m\n'
printf '  \033[33m\342\200\246\033[0m  edit  docs/roadmap/record.md  \033[2m  hunk 3 of 7\033[0m\n'
printf '\n'
printf '     \033[36m+ every 4 MiB, or every minute, a checkpoint\033[0m\n'
printf '     \033[31m- every 4 MiB of output a checkpoint\033[0m\n'
printf '\n'
printf '\033[2m  esc to interrupt\033[0m\n'

# A pause, and the one line of this scene that is load-bearing rather than
# decorative. The index forces a checkpoint at the read that *leaves* the
# alt screen, and the boundary it can force one at is a whole pty read: with
# the final repaint and the `?1049l` in the same read, the checkpoint lands
# one read earlier and the last line of the frame is missing from the
# capture. Two runs without this sleep differed by exactly that line. It is
# the honest caveat in `ckpt.zig`'s builder, photographed.
sleep 0.2

# Out. The frame above is gone from the live screen at this point.
printf '\033[?1049l'
printf 'agent: 3 files, 1 edit, exit 0\n'
printf '$ \n'
