#!/bin/sh
# test/mux-pin.t - the BOTTOM PANE's height, which is the one number mux pins
# on every window it builds or refreshes.
#
# WRITTEN BECAUSE NOTHING EXERCISED THE ARITHMETIC. `mux-refresh.t` is the
# only test that names mux-pin, and it deliberately hands it an EMPTY
# `list-panes -a` so the pin no-ops while the width balance is measured. So
# the divisor, the clamp and the skip rules ran in no test at all.
#
# WHAT IT COSTS TO GET WRONG is recorded in mux's notes as the 0.50 finding: a
# window that loses its `@mux-bottom` freezes BOTH halves of the layout
# machinery, because the pin skips an unmarked pane and the width balance then
# cannot tell the bottom pane from the row above it and correctly declines. So
# "an unmarked pane is skipped" is not a tidy edge case, it is the behaviour
# that made prefix-r and prefix-R appear to do nothing.
#
# tmux IS STUBBED, which is the right call here and not a compromise: this is
# integer arithmetic over `window_height` and a spec string, and a real server
# would let us set a window height only approximately (it depends on the
# attached client) while telling us nothing extra about the rounding.
set -eu
_name=mux-pin
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin"
PANES=$T/panes                # pane_id window_height pane_height spec
LOG=$T/log
export PANES LOG
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$LOG"
case "$*" in
*list-panes*) cat "$PANES" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

run() { : >"$LOG"; PATH="$T/bin:$PATH" "$HERE/libexec/mux-pin" \
  >"$T/out" 2>"$T/err" || true; }
# The resizes it asked for: "pane=height" per line, in order.
sizes() { sed -n 's/^resize-pane -t \(.*\) -y \(.*\)$/\1=\2/p' "$LOG" \
  | tr '\n' ' '; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- the divisor, and the clamp at each end --------------------------------
# A FIFTH OF THE WINDOW, then held inside the spec's range. Each case is its
# own assertion rather than one combined check: a pin that ignored the divisor
# and always took `min` would satisfy any assertion about the clamp alone.
printf '%%1 50 10 5-10\n' >"$PANES"       # 50/5 = 10, inside 5-10
run; eq divisor "$(sizes)" ""             # already 10, so nothing to do
printf '%%1 50 7 5-10\n' >"$PANES"
run; eq divisor-applied "$(sizes)" "%1=10 "
printf '%%1 100 7 5-10\n' >"$PANES"       # 100/5 = 20, capped at the MAX
run; eq clamp-max "$(sizes)" "%1=10 "
printf '%%1 20 7 5-10\n' >"$PANES"        # 20/5 = 4, lifted to the MIN
run; eq clamp-min "$(sizes)" "%1=5 "
# A BARE `N` IS BOTH BOUNDS, which falls out of `${spec%%-*}` and
# `${spec##*-}` answering the same thing on a string with no dash. `mux save`
# emits this form, so it is not hypothetical.
printf '%%1 100 7 8\n' >"$PANES"
run; eq bare-spec "$(sizes)" "%1=8 "

# --- ALREADY RIGHT MEANS NO RESIZE ----------------------------------------
# Not cosmetic: tmux redistributes WIDTH proportionally on every resize, so a
# pin that re-applied the height it already has would churn the widths of
# every pane beside it on each refresh, which is the drift mux-refresh and
# `mux even` exist to undo.
printf '%%1 40 8 5-10\n' >"$PANES"        # 40/5 = 8, which it already is
run; eq idempotent "$(sizes)" ""

# --- an UNMARKED pane is skipped silently ---------------------------------
# The pin walks EVERY pane on the server, so most of what it sees has no
# marker and must cost nothing and say nothing. Asserted on stderr too: this
# runs from a key binding and from the build path, where noise is a bug.
printf '%%0 50 40\n%%1 50 7 5-10\n' >"$PANES"
run
eq skips-unmarked "$(sizes)" "%1=10 "
eq skips-quietly "$(cat "$T/err")" ""

# --- a BAD spec is reported, and skipped ---------------------------------
# LOUD here, where the unmarked case is silent, and the difference is the
# point: no marker means nobody asked for a pinned height, while a marker mux
# cannot parse is a window whose layout will now silently never be held. Each
# malformed shape gets its own case, because one `*[!0-9]*` guard covering
# both ends is two rules.
for _bad in 'x-10' '5-x' 'abc' '-'; do
  printf '%%1 50 7 %s\n' "$_bad" >"$PANES"
  run
  eq "bad-spec-$_bad-no-resize" "$(sizes)" ""
  case $(cat "$T/err") in *'bad @mux-bottom on %1'*) ;;
    *) fail "a @mux-bottom of [$_bad] was skipped SILENTLY, so a window whose
layout can never be held again looks exactly like one with no bottom pane:
[$(cat "$T/err")]" ;;
  esac
done

# --- and a bad spec does not stop the panes after it ---------------------
# The loop body `continue`s rather than exiting, which matters because the
# walk is server-wide: one window with a corrupt marker must not cost every
# other window its height. The same shape as the `set -e` truncation that
# once cut mux's environment plan short at the first invalid name.
printf '%%1 50 7 bogus\n%%2 50 7 5-10\n' >"$PANES"
run
eq bad-spec-does-not-truncate "$(sizes)" "%2=10 "

pass
