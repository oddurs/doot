#!/bin/sh
# One scene for every way the selection highlight can be got wrong, arranged
# so the capture's selection cuts across each of them rather than covering it
# whole -- a highlight that swallowed the thing it is meant to be compared
# against would prove nothing.
#
# Row 0:   a coloured background, with the selection starting inside it: the
#          same run appears in its own blue and in the selection colour.
# Row 1-2: a line longer than the grid, so it wraps. The highlight runs to the
#          margin on the first row and continues on the second.
# Row 3:   a CJK pair, so a selection edge can land on a `.spacer`.
# Row 4:   a reverse-video run, with the selection ending inside it. The
#          selected half is drawn with its *unreversed* foreground and the
#          unselected half is not -- side by side, which is the fix for a
#          `less` status line disappearing the moment it is selected.
printf 'bg: \033[44mblue background here\033[0m plain\n'
printf 'wrapped: the quick brown fox jumps over the lazy dog and keeps going\n'
printf 'wide: \344\270\200\344\272\214\344\270\211 pairs\n'
printf 'rev: \033[7mreverse video run\033[0m plain\n'
