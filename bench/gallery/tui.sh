#!/bin/sh
# The shape an agent TUI draws: a scroll region, a framed panel, a status
# line pinned to the bottom. Exercises DECSTBM, absolute addressing and
# box drawing together.
printf '\033[2J\033[H'
printf '\033[1;10r'
printf '\033[1;1H\342\224\214'; i=0; while [ $i -lt 46 ]; do printf '\342\224\200'; i=$((i+1)); done; printf '\342\224\220\n'
printf '\342\224\202 \033[1mterminator\033[0m  a terminal that gets out of the way \342\224\202\n'
printf '\342\224\234'; i=0; while [ $i -lt 46 ]; do printf '\342\224\200'; i=$((i+1)); done; printf '\342\224\244\n'
printf '\342\224\202 \033[32m\342\234\223\033[0m parser      \033[2m1,204 sequences\033[0m              \342\224\202\n'
printf '\342\224\202 \033[32m\342\234\223\033[0m grid        \033[2m  ring, no memmove\033[0m           \342\224\202\n'
printf '\342\224\202 \033[33m\342\200\246\033[0m renderer    \033[2m  one draw call\033[0m              \342\224\202\n'
printf '\342\224\224'; i=0; while [ $i -lt 46 ]; do printf '\342\224\200'; i=$((i+1)); done; printf '\342\224\230\n'
printf '\033[12;1H\033[7m NORMAL \033[0m main \342\234\232 clean                          '
