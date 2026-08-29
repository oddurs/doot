#!/bin/sh
# The 16 ANSI slots, the 256 cube, and a truecolour ramp.
i=0; while [ $i -lt 8 ]; do printf '\033[4%dm  ' "$i"; i=$((i+1)); done; printf '\033[0m\n'
i=0; while [ $i -lt 8 ]; do printf '\033[10%dm  ' "$i"; i=$((i+1)); done; printf '\033[0m\n'
i=16; while [ $i -lt 124 ]; do printf '\033[48;5;%dm ' "$i"; i=$((i+1)); done; printf '\033[0m\n'
i=124; while [ $i -lt 232 ]; do printf '\033[48;5;%dm ' "$i"; i=$((i+1)); done; printf '\033[0m\n'
i=0; while [ $i -lt 108 ]; do printf '\033[48;2;%d;80;160m ' $((i*2)); i=$((i+1)); done; printf '\033[0m\n'
