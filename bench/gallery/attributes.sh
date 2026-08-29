#!/bin/sh
# Every SGR attribute, alone and combined.
printf '\033[0mnormal   \033[1mbold\033[0m   \033[2mdim\033[0m   \033[3mitalic\033[0m   \033[4munderline\033[0m\n'
printf '\033[7mreverse\033[0m  \033[9mstrike\033[0m  \033[1;4mbold+under\033[0m  \033[1;3mbold+italic\033[0m\n'
printf '\033[4;31munder red\033[0m  \033[7;32mrev green\033[0m  \033[2;33mdim yellow\033[0m\n'
