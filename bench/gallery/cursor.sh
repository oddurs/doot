#!/bin/sh
# The cursor, parked somewhere unambiguous. X0's done-when is that a
# one-pixel change in the cursor shows up as a diff, so it gets a scene
# whose only interesting feature is the cursor.
printf '\033[2J\033[H'
printf 'cursor below, on the second row, at column 5\n'
printf '    '
