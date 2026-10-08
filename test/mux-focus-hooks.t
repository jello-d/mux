#!/bin/sh
# test/mux-focus-hooks.t - every shipped ACTIVATE hook under
# share/desktop-notifier/focus/, which raises the window showing a host's
# latch after the tray has already switched that host's session.
#
# WRITTEN BECAUSE THE FIRST TWO HAD NEVER EXECUTED. The only test naming them
# read `desktop-notifier-activate focus-kitty` out of a config file and
# asserted the STRING came back, which is a test of the config reader.
# Shipping a hook and running it are different acts, and this was the FOURTH
# time this package found a shipped hook completely dark: both latch hooks,
# then all four envhooks, then the notifier's own config key, then these.
#
# AND FOUR OF THE SIX CANNOT BE RUN AGAINST THEIR COMPOSITOR HERE, which is
# the honest limit and decides what this file asserts. sway, Hyprland, niri
# and X11 are not available on this fleet, so what is testable is everything
# EXCEPT whether each compositor accepts the syntax: the guards, the exit
# contract, and the ARGV composed. Each hook's own header says which half is
# verified, because a hook whose mechanism was read rather than run is a
# different thing and 0.81's ET support is what this package paid to learn it.
#
# THE CONTRACT IS 78, NEVER 1, the same three-answer contract latch's hooks
# use. 78 is "cannot answer": not finding the window, not having the tool,
# and the compositor not being the live one are all different facts from the
# raise having failed, and the notifier REPORTS a non-zero exit rather than
# swallowing it, so a misconfigured hook says so instead of doing nothing.
#
# THE ASSERTIONS ARE ON THE ARGV wherever the rule is about WHAT was asked.
# Every hook anchors on `[LABEL]`, because mux's own `set-titles-string` ends
# each window title in `[host_short]`: matching the bare name would also hit
# a SESSION called `northwood`, or a path in the title. A hook that raised the
# wrong window still exits 0, so only the recorded argv can tell them apart.
#
# AND THE ANCHOR IS SPELLED THREE WAYS, which is the per-hook fact this file
# exists to pin: escaped for a regex matcher (sway, Hyprland), literal for a
# substring matcher (wmctrl), and matched in the hook itself for niri, whose
# focus action takes an id rather than a title.
set -eu
_name=mux-focus-hooks
. "$(dirname "$0")/harness_lib"

HOOKS=$HERE/share/desktop-notifier/focus
mkdir -p "$T/bin"
ARGV=$T/argv
export ARGV

# EVERY SHIPPED HOOK IS SWEPT, not a list written here, so a new one cannot
# arrive untested: the generic cases below run over whatever is in the
# directory, and the per-hook argv cases name each explicitly.
ALL=$(find "$HOOKS" -type f | sed 's|.*/||' | sort)
_n=$(printf '%s\n' "$ALL" | wc -l)
[ "$_n" -ge 6 ] || fail "only $_n focus hooks found, which is fewer than the
tree has shipped since the focus/toast split: [$(printf '%s\n' "$ALL" \
| tr '\n' ' ')]"

# A tool that records what it was asked and answers as told.
mk() {   # <name> <exit-code> [stdout]
  cat >"$T/bin/$1" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$ARGV"
${3:+printf '%s\\n' '$3'}
exit $2
EOF
  chmod +x "$T/bin/$1"
}
# Every tool any hook reaches for, all succeeding, so a generic case fails
# only for the reason it is testing.
mkall() {
  mk kitten 0; mk wf-msg 0; mk swaymsg 0; mk hyprctl 0 ok
  mk wmctrl 0; mk niri 0 '[]'; mk jq 0 '7'
}
# EVERY COMPOSITOR'S ENV AT ONCE, so the generic cases get past each hook's
# liveness guard whichever hook they are running. A real box never looks like
# this; the point is to reach the code under test.
LIVE="WAYFIRE_SOCKET=/run/wf.sock SWAYSOCK=/run/sway.sock
HYPRLAND_INSTANCE_SIGNATURE=sig NIRI_SOCKET=/run/niri.sock DISPLAY=:0"

run() {   # <hook> [args...] -> exit code, with stderr in $T/err
  : >"$ARGV"
  _h=$1; shift
  _r=0
  # A CURATED PATH, holding NOTHING but the stubs. Every hook reaches for
  # `command -v`, `echo` and `printf`, which are builtins, so the only thing
  # any of them can find is what this test put there. With /usr/bin on the
  # end, `kitten`, `swaymsg` and `jq` are REAL on this box and the
  # missing-tool case silently becomes the tool-fails case: green here, and a
  # false pass on a developer's machine, which is the direction that wastes
  # the most time.
  # shellcheck disable=SC2086
  env -i PATH="$T/bin" $ENVSET \
    "$HOOKS/$_h" "$@" >"$T/out" 2>"$T/err" || _r=$?
  echo "$_r"
}
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }
errhas() { case "$(cat "$T/err")" in (*"$1"*) ;;
  (*) fail "$2: want [$1] in [$(cat "$T/err")]" ;; esac; }

# --- NO LABEL IS A USAGE ERROR, AND IT IS 78 LIKE EVERYTHING ELSE --------
# Not 2: this is a hook answering mux, so it speaks the hook contract rather
# than mux's own exit codes, and a caller must not have to know which.
#
# SWEPT OVER EVERY HOOK, which is what makes a new one arrive tested: the
# message names the hook by its path, so `focus/sway` rather than the bare
# `sway` a reader could confuse with the compositor.
ENVSET=$LIVE
for _h in $ALL; do
  mkall
  eq "no-label-$_h" "$(run "$_h")" 78
  errhas "usage: focus/$_h LABEL" "no-label-$_h-says-so"
  [ ! -s "$ARGV" ] || fail "focus/$_h ran its tool with no label to match"
done

# --- A MISSING TOOL IS 78, AND NAMES THE TOOL ---------------------------
# The likeliest real failure: the hook is wired and the tool for it is not
# installed. Saying WHICH command is absent is the difference between a
# one-line fix and a hunt.
#
# ONE ROW PER HOOK because the tool differs, and the table is the point: it
# is also the only place the tool each hook depends on is written down in one
# view.
for _row in "kitty kitten" "wayfire wf-msg" "sway swaymsg" \
            "hyprland hyprctl" "wmctrl wmctrl" "niri niri"; do
  # shellcheck disable=SC2086   # a two-word table row, split on purpose
  set -- $_row
  mkall; rm -f "$T/bin/$2"
  eq "missing-$2" "$(run "$1" box)" 78
  errhas "$2 is not on PATH" "missing-$2-names-it"
done

# --- A HOOK WHOSE COMPOSITOR IS NOT LIVE IS 78, BEFORE THE TOOL ---------
# Checked in that order deliberately: the tool being installed tells you
# nothing about the compositor running right now, and that is the usual
# missing half. swaymsg in particular is installed on this very box, which
# runs wayfire.
for _row in "wayfire WAYFIRE_SOCKET" "sway SWAYSOCK" \
            "hyprland HYPRLAND_INSTANCE_SIGNATURE" "niri NIRI_SOCKET" \
            "wmctrl DISPLAY"; do
  # shellcheck disable=SC2086   # a two-word table row, split on purpose
  set -- $_row
  mkall
  # THE WHOLE ENV MINUS ONE NAME, so the hook meets exactly the state being
  # described rather than an empty environment that several guards would
  # refuse for their own reasons.
  # shellcheck disable=SC2086   # LIVE is a list of assignments, split
  ENVSET=$(printf '%s\n' $LIVE | grep -v "^$2=" | tr '\n' ' ')
  eq "unset-$2" "$(run "$1" box)" 78
  errhas "$2" "unset-$2-names-the-variable"
  [ ! -s "$ARGV" ] || fail "focus/$1 ran its tool with $2 unset"
  ENVSET=$LIVE
done
# AND WAYFIRE NAMES THE REMEDY, not just the variable: the socket comes from
# a plugin you have to enable, so "unset" alone sends you looking for a bug.
mkall
# ON ITS OWN LINE, because a directive attaches to the next COMMAND: above
# `mkall; ENVSET=...` it covered the `mkall` and the assignment stayed
# flagged, which is a trap this tree has already paid for once.
# shellcheck disable=SC2086   # LIVE is a list of assignments, split
ENVSET=$(printf '%s\n' $LIVE | grep -v '^WAYFIRE_SOCKET=' | tr '\n' ' ')
run wayfire box >/dev/null
errhas "ipc plugin" wayfire-names-the-remedy
ENVSET=$LIVE

# --- THE HAPPY PATH, AND THE THREE SPELLINGS OF THE ANCHOR --------------
# The load-bearing assertions. Each hook's matcher takes the anchor in its
# own form and only the recorded argv can show which.
mkall
eq kitty-ok "$(run kitty northwood)" 0
eq kitty-argv "$(cat "$ARGV")" '@ focus-window --match title:\[northwood\]'

eq wayfire-ok "$(run wayfire northwood)" 0
eq wayfire-argv "$(cat "$ARGV")" 'focus-window title:\[northwood\]'

# SWAY'S CRITERIA ARE A REGEX, so the brackets are escaped INSIDE the quoted
# criteria value, which is a second level of quoting a reader will get wrong.
eq sway-ok "$(run sway northwood)" 0
eq sway-argv "$(cat "$ARGV")" '[title="\[northwood\]"] focus'

# HYPRLAND'S MATCHER IS A FULL MATCH, so the anchor is wrapped in `.*` and
# the whole thing anchored: an unwrapped title would match nothing at all,
# which is the failure a bare "it exits 0" check cannot see.
eq hypr-ok "$(run hyprland northwood)" 0
eq hypr-argv "$(cat "$ARGV")" \
  'dispatch focuswindow title:^.*\[northwood\].*$'

# WMCTRL MATCHES A SUBSTRING, so the brackets are LITERAL here. A hook that
# copied sway's escaping would search for backslashes and find nothing.
eq wmctrl-ok "$(run wmctrl northwood)" 0
eq wmctrl-argv "$(cat "$ARGV")" '-a [northwood]'

# NIRI MATCHES IN THE HOOK, because its action takes an id: the argv proves
# the anchor reached jq's filter and that the id came back out to the action.
mkall
eq niri-ok "$(run niri northwood)" 0
case $(cat "$ARGV") in
  (*'[northwood]'*) ;;
  (*) fail "niri-anchor: the label never reached the window query:
[$(cat "$ARGV")]" ;;
esac
case $(cat "$ARGV") in
  (*'msg action focus-window --id 7'*) ;;
  (*) fail "niri-focuses-the-id: the id jq answered was not focused:
[$(cat "$ARGV")]" ;;
esac

# --- A LABEL THAT IS A SUBSTRING OF ANOTHER MUST NOT MATCH IT -----------
# What the CLOSING bracket buys, and what no exit code can show. `man` is a
# substring of every host name here on purpose.
mkall
eq kitty-anchored-right "$(run kitty man; cat "$ARGV")" \
  "0
@ focus-window --match title:\\[man\\]"
eq wmctrl-anchored-right "$(run wmctrl man; cat "$ARGV")" \
  "0
-a [man]"

# --- A TOOL THAT FAILS IS 78, NOT ITS OWN CODE --------------------------
# A raise that did not happen is "cannot answer"; passing the tool's status
# through would mean the notifier had to learn each compositor's exit codes.
for _row in "kitty kitten" "wayfire wf-msg" "sway swaymsg" \
            "wmctrl wmctrl"; do
  # shellcheck disable=SC2086   # a two-word table row, split on purpose
  set -- $_row
  mkall; mk "$2" 3
  eq "failed-$1" "$(run "$1" northwood)" 78
done
errhas "no X11 window titled 'northwood'" wmctrl-failure-says-so

# --- AND HYPRLAND'S EXIT CODE IS NOT THE ANSWER -------------------------
# The one hook where a zero exit means nothing: `hyprctl dispatch` succeeds
# as a PROCESS and reports the outcome in its output, which is the shape that
# cost latch two shipped bugs (`ssh -V` and `et`'s usage errors, both of
# which reported a session that never existed). Asserted with a stub that
# exits 0 and says it failed, which is the state a bare rc check waves
# through.
mkall; mk hyprctl 0 "Invalid dispatcher"
eq hypr-exit-0-but-failed "$(run hyprland northwood)" 78
errhas "Invalid dispatcher" hypr-quotes-what-it-was-told
# And the control, because "it always fails" would pass the line above: a
# literal `ok` is the one output that counts.
mkall
eq hypr-ok-counts "$(run hyprland northwood)" 0

# --- NIRI'S TWO EXTRA FAILURE MODES -------------------------------------
# It is the only hook with a dependency beyond its compositor's CLI, and the
# only one that can be told "no such window" by its own matcher rather than
# by the tool.
mkall; rm -f "$T/bin/jq"
eq niri-no-jq "$(run niri northwood)" 78
errhas "jq is not on PATH" niri-no-jq-names-it

mkall; mk jq 0 ''
eq niri-no-match "$(run niri northwood)" 78
errhas "no niri window titled 'northwood'" niri-no-match-says-so

pass
