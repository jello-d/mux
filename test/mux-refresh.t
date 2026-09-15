#!/bin/sh
# test/mux-refresh.t - `mux refresh` puts a window's geometry back.
#
# It used to only re-pin the BOTTOM pane's height. But tmux redistributes width
# proportionally on every resize, and the rounding means a window resized a few
# times drifts off an even split and STAYS there -- 79|81 in a 161-column
# window that should be 80|80. mux builds a row with `select-layout
# even-horizontal`, so even IS the canonical state and nothing in a layout can
# ask for anything else; there was simply nothing that restored it. With
# border-drag unbound (mux-opinions drops MouseDrag1Border so a copy drag
# cannot yank a divider) there was then no way to fix it by hand at all.
#
# The arithmetic is what this pins, so tmux is stubbed and the resize-pane
# calls are inspected directly: no server, no panes, no real geometry.
set -eu
_name=mux-refresh
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin"
PANES=$T/panes           # "pane_id pane_height [@mux-bottom]" per line
WIDTH=$T/width
LOG=$T/log
export PANES WIDTH LOG
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$LOG"
case "$*" in
# mux-pin walks every pane on the server; give it nothing so it no-ops here.
*list-panes*-a*)          : ;;
# The balance query asks for heights; the bottom-pane query does not.
*list-panes*pane_height*) cat "$PANES" ;;
*list-panes*)             awk 'NF>2 {print $1, $3}' "$PANES" ;;
*window_width*)           cat "$WIDTH" ;;
*window_id*)              printf '@0\n' ;;
*pane_id*)                printf '%%0\n' ;;
*@mux-bottom*)            printf '5-10\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
printf '161\n' >"$WIDTH"

run() { : >"$LOG"; PATH="$T/bin:$PATH" "$HERE/libexec/mux-refresh" "$@" \
	>/dev/null 2>&1 || true; }
# Just the WIDTH resizes, in order: "pane=width" per line.
widths() { grep -- '-x' "$LOG" 2>/dev/null \
	| sed 's/.*-t \([^ ]*\) -x \([0-9]*\).*/\1=\2/' | tr '\n' ' '; }

# --- an even split of an even width ---------------------------------------
# 161 columns, two panes, one border column between them: 80|80. Only the
# leftmost is set; the last pane takes whatever is left, so it needs no call.
printf '%%0 52\n%%1 52\n%%2 10 5-10\n' >"$PANES"
run
[ "$(widths)" = "%0=80 " ] \
	|| fail "two panes in 161: got [$(widths)]"

# --- the remainder lands leftmost, as even-horizontal does -----------------
# 180 columns, two panes, one border: 179 to share, so 90|89 and not 89|90.
printf '180\n' >"$WIDTH"
run
[ "$(widths)" = "%0=90 " ] \
	|| fail "two panes in 180: got [$(widths)] want %0=90"
printf '161\n' >"$WIDTH"

# --- three panes ----------------------------------------------------------
# 161 less two borders = 159, which divides evenly: 53|53|53.
printf '%%0 52\n%%1 52\n%%2 52\n%%3 10 5-10\n' >"$PANES"
run
[ "$(widths)" = "%0=53 %1=53 " ] \
	|| fail "three panes in 161: got [$(widths)]"

# --- STACKED panes are refused, not mangled -------------------------------
# Non-bottom panes of differing HEIGHT are not one row: they are stacked, an
# arrangement this arithmetic does not model. Setting widths across it would
# rearrange a layout rather than restore it, so it declines. Refusing to act on
# a shape you do not understand beats acting confidently on it.
printf '%%0 52\n%%1 25\n%%2 26\n%%3 10 5-10\n' >"$PANES"
run
[ -z "$(widths)" ] || fail "a stacked layout was resized: [$(widths)]"

# --- nothing to balance ---------------------------------------------------
printf '%%0 52\n%%1 10 5-10\n' >"$PANES"     # one pane over the bottom
run
[ -z "$(widths)" ] || fail "a single pane was resized: [$(widths)]"

# --- no bottom pane at all: still balances, still no error ----------------
# The bottom pane is optional in a layout; the row above it is not.
printf '%%0 52\n%%1 52\n' >"$PANES"
run
[ "$(widths)" = "%0=80 " ] || fail "no-bottom window: got [$(widths)]"

# --- --force balances too -------------------------------------------------
# It is the bigger hammer, so it must not do LESS than the plain one; the
# reported symptom was reaching for prefix+R and getting no rebalance.
printf '%%0 52\n%%1 52\n%%2 10 5-10\n' >"$PANES"
run --force
[ "$(widths)" = "%0=80 " ] || fail "--force did not balance: [$(widths)]"

pass
