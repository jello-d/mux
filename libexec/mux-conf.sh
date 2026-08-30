#!/bin/sh
# mux-conf.sh - the ONE comment/normalize rule for mux's line-directive config
# (layouts, themes, agents). Sourced (functions only); every config PARSE site
# runs its input through mux_conf_clean, so the rule lives in exactly one place
# and cannot drift between layouts, themes, and agent profiles.
#
# mux_conf_clean: stdin -> clean directive lines. In order it
#   - strips a trailing CR (CRLF files saved by another editor),
#   - drops FULL-LINE comments (optional indent, then #),
#   - strips INLINE comments -- WHITESPACE then # to end of line. A hash that
#     BEGINS a comment goes; a hash INSIDE a token stays, so `bg=#3f5f00` (no
#     space before #) survives while `theme slate  # note` loses the note. The
#     one casualty is a literal " #" inside a pane/bottom COMMAND (rare -- use
#     `pane sh -c '...'`, or avoid the space-hash),
#   - trims trailing whitespace (so `theme slate ` is not the name "slate "),
#   - drops the blank lines all of the above leaves behind.
mux_conf_clean() {
	sed -e 's/\r$//' \
	    -e '/^[[:space:]]*#/d' \
	    -e 's/[[:space:]]#.*$//' \
	    -e 's/[[:space:]]*$//' \
	    -e '/^[[:space:]]*$/d'
}
