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

# focus/wayfire's TOOL IS python3, so its absence is a skip rather than a
# failure, the same call test/lab makes about a missing compositor.
PY3=$(command -v python3 2>/dev/null || true)
[ -n "$PY3" ] || skip "no python3, which focus/wayfire needs"

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
# A kitten stub that dispatches on the VERB, because focus/kitty makes TWO
# calls now: `focus-window` to act, then `ls --match ... and state:focused`
# to VERIFY. A single-exit-code stub cannot answer them differently, and the
# second one is the whole point: measured against a live kitty,
# `focus-window` exits 0 having moved NOTHING whenever the target is in
# another OS window, so a hook trusting that exit code reported success for
# a click that raised nothing.
mk_kitten() {   # <focus-window rc> <ls rc>
  cat >"$T/bin/kitten" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$ARGV"
for a in "\$@"; do
  case \$a in
    (focus-window) exit $1 ;;
    (ls)           exit $2 ;;
  esac
done
exit 0
EOF
  chmod +x "$T/bin/kitten"
}

# Every tool any hook reaches for, all succeeding, so a generic case fails
# only for the reason it is testing.
mkall() {
  mk_kitten 0 0; mk swaymsg 0; mk hyprctl 0 ok
  mk wmctrl 0; mk niri 0 '[]'; mk jq 0 '7'
  # A REAL python3, by name, because focus/wayfire's tool IS python3: there
  # is no wayfire IPC client to stub, so the hook speaks the protocol itself
  # and a recording stub would replace the logic under test. This is the
  # same move CI makes for `timeout`, with the difference stated: there a
  # harness dependency is linked in, here it is the hook's own.
  ln -sf "$PY3" "$T/bin/python3"
}
# EVERY COMPOSITOR'S ENV AT ONCE, so the generic cases get past each hook's
# liveness guard whichever hook they are running. A real box never looks like
# this; the point is to reach the code under test.
LIVE="WAYFIRE_SOCKET=/run/wf.sock SWAYSOCK=/run/sway.sock
HYPRLAND_INSTANCE_SIGNATURE=sig NIRI_SOCKET=/run/niri.sock DISPLAY=:0
KITTY_LISTEN_ON=unix:/run/kitty.sock"

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
  errhas "usage: focus/$_h" "no-label-$_h-says-so"
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
for _row in "kitty kitten" "wayfire python3" "sway swaymsg" \
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
# BOTH CALLS, IN ORDER, because the second is the GUARD and an assertion
# on the first alone passes with the verification deleted. `--to` is on
# each: without it kitten looks for a controlling terminal, which a
# notification daemon does not have, so the hook could never have worked
# from the only place it is ever invoked.
eq kitty-argv "$(cat "$ARGV")" "\
@ --to unix:/run/kitty.sock focus-window --match title:\\[northwood\\]
@ --to unix:/run/kitty.sock ls --match title:\\[northwood\\] and state:focused"

# WAYFIRE IS ASSERTED ON ITS REQUESTS, not an argv, because it has no tool
# to record: `wf_serve` stands a fake socket up and logs what arrived. What
# this pins is the pair that matters, and the SECOND half is the hook's
# whole reason for being two steps: the anchor matched the window carrying
# it, and the id handed to wayfire is THAT window's.
#
# THE PREVIOUS VERSION OF THIS CASE PINNED A DEFECT. It asserted
# `focus-window title:\[northwood\]` against a stubbed `wf-msg`, and
# `wf-msg` does not exist: no apt package, no source tree, and not among
# wayfire's eight binaries. Measured against a live compositor, of 79 IPC
# methods none matches by title, so neither the tool nor the verb nor the
# argument form was real. A stub cannot refuse a call the tool would never
# have understood, which is the limit this whole file states in its header.
wf_serve() {   # <views-json> [focus-error]
  rm -f "$T/wf.log" "$T/wf.sock" "$T/wf.sock.ready"
  printf '%s' "$1" >"$T/wf.views"
  "$PY3" "$HERE/test/wffake.py" "$T/wf.sock" "$T/wf.log" "$T/wf.views" \
    "${2:-}" >"$T/wf.err" 2>&1 &
  WF_PID=$!
  _i=0
  while [ "$_i" -lt 100 ]; do
    [ -f "$T/wf.sock.ready" ] && return 0
    _i=$((_i + 1)); sleep 0.05
  done
  fail "the fake wayfire socket never came up: $(cat "$T/wf.err" 2>/dev/null)"
}
# `wait` IS GUARDED, because a server the test killed answers 128+SIGTERM and
# `set -e` would turn that into a no-verdict exit with no output. This suite
# has paid for exactly that once.
wf_stop() { kill "$WF_PID" 2>/dev/null || :; wait "$WF_PID" 2>/dev/null || :; }

WF_VIEWS='[{"id": 3, "mapped": true, "role": "toplevel", "pid": 11,
  "title": "mux api [northwoodx]"},
 {"id": 5, "mapped": true, "role": "toplevel", "pid": 12,
  "title": "mux api [northwood]"},
 {"id": 7, "mapped": true, "role": "toplevel", "pid": 13,
  "title": "northwood"}]'

# THE DECOY IS FIRST IN THE LIST, and that ordering IS the assertion: with
# the real window first, a hook whose anchor had lost its closing bracket
# would match both, take the first, and land on the right one anyway. The
# lab learned this against a live wayfire, and the same ordering is why
# test/lab/probe/focus creates its decoy before its target.
mkall
ENVSET="WAYFIRE_SOCKET=$T/wf.sock"
wf_serve "$WF_VIEWS"
eq wayfire-ok "$(run wayfire northwood)" 0
wf_stop
eq wayfire-methods "$(sed -n 's/.*"method": "\([^"]*\)".*/\1/p' "$T/wf.log")" \
  "window-rules/list-views
window-rules/focus-view"
# THE ID IS THE LOAD-BEARING FIELD: 5 is `[northwood]` and 3 is the longer
# name that a missing closing bracket reaches first.
case "$(cat "$T/wf.log")" in
  (*'"id": 5'*) ;;
  (*) fail "wayfire-id: focused the wrong view: $(cat "$T/wf.log")" ;;
esac

# NO MATCH IS 78, and the hook never asks wayfire to focus anything: an id
# it guessed would be a wrong window raised with every appearance of
# success.
wf_serve "$WF_VIEWS"
eq wayfire-no-match "$(run wayfire nosuchhost)" 78
wf_stop
errhas "no wayfire window titled" wayfire-no-match-says-so
case "$(cat "$T/wf.log")" in
  (*focus-view*) fail "wayfire-no-match: it focused something anyway" ;;
esac

# AN ERROR IN THE PAYLOAD IS A FAILURE, which is the half no exit code can
# carry here: a socket has no status, so a refused focus arrives as
# `{"error": ...}` on a healthy connection. Measured against a live
# compositor, since the alternative assumption is kitty's bug, where a
# focus call reported success having moved nothing.
wf_serve "$WF_VIEWS" "No view with id=5"
eq wayfire-payload-error "$(run wayfire northwood)" 78
wf_stop
errhas "could not focus view 5" wayfire-payload-error-says-so

# AN UNMAPPED VIEW IS NOT A CANDIDATE, which is wayfire's own filter: a
# background or unmapped view carrying the anchor would otherwise be raised
# and nothing would be on screen.
wf_serve '[{"id": 9, "mapped": false, "role": "toplevel", "pid": 14,
  "title": "mux api [northwood]"}]'
eq wayfire-unmapped "$(run wayfire northwood)" 78
wf_stop
errhas "no wayfire window titled" wayfire-unmapped-says-so
ENVSET=$LIVE

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
@ --to unix:/run/kitty.sock focus-window --match title:\\[man\\]
@ --to unix:/run/kitty.sock ls --match title:\\[man\\] and state:focused"
eq wmctrl-anchored-right "$(run wmctrl man; cat "$ARGV")" \
  "0
-a [man]"

# --- A TOOL THAT FAILS IS 78, NOT ITS OWN CODE --------------------------
# A raise that did not happen is "cannot answer"; passing the tool's status
# through would mean the notifier had to learn each compositor's exit codes.
# WAYFIRE IS NOT IN THIS LOOP: it calls no tool whose status could be
# passed through, so its equivalent is a refused focus, which the
# `wayfire-payload-error` case above drives through the fake socket.
for _row in "sway swaymsg" "wmctrl wmctrl"; do
  # shellcheck disable=SC2086   # a two-word table row, split on purpose
  set -- $_row
  mkall; mk "$2" 3
  eq "failed-$1" "$(run "$1" northwood)" 78
done
# THE MESSAGE CHECK SITS WITH ITS OWN RUN, not after the loop: `errhas`
# reads whatever stderr was written LAST, so a case appended below the loop
# silently re-points it. That is the positional hazard this suite already
# records for a shared `$_o`.
errhas "no X11 window titled 'northwood'" wmctrl-failure-says-so

# kitty separately, since its stub takes two codes. The ACT failing first.
mkall; mk_kitten 3 0
eq failed-kitty "$(run kitty northwood)" 78
errhas "no kitty window titled 'northwood'" failed-kitty-says-so

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

# --- AND KITTY'S ZERO EXIT IS NOT THE ANSWER ----------------------------
# THE PRODUCT BUG THIS FILE EXISTS TO HOLD DOWN, found by building a lab
# environment for the hook and measured against a live kitty 0.45.0: two
# kitty OS windows, focus on the second, `focus-window --match` the first,
# and it exits 0 having moved nothing, in kitty's own view and the
# compositor's alike. kitty remote control can focus a window WITHIN an OS
# window and has no verb to RAISE one.
#
# So the hook asks a second question whose answer is an exit code
# (`ls --match "title:... and state:focused"`), and a stub that succeeds at
# the ACT and fails the VERIFY is the state a bare rc check waves through.
mkall; mk_kitten 0 1
eq kitty-acted-but-did-not-focus "$(run kitty northwood)" 78
errhas "is not focused" kitty-says-it-did-not-focus
errhas "cannot
RAISE one" kitty-names-the-limit
# And the control, because "it always fails" would pass the line above.
mkall
eq kitty-verify-ok "$(run kitty northwood)" 0

# --- A SOCKET IS REQUIRED, AND ITS ABSENCE IS NOT THE TOOL'S FAULT ------
# `kitten @` with no `--to` reaches kitty through the CONTROLLING TERMINAL
# of the window it runs inside, and a notification daemon has none: the real
# error is `open /dev/tty: no such device or address`, reported as the hook
# failing while `allow_remote_control yes` sits correctly in kitty.conf. So
# the hook refuses FIRST and says what to set, rather than letting kitten
# produce that.
mkall
# shellcheck disable=SC2086   # LIVE is a list of assignments, split
ENVSET=$(printf '%s\n' $LIVE | grep -v '^KITTY_LISTEN_ON=' | tr '\n' ' ')
eq kitty-no-socket "$(run kitty northwood)" 78
errhas "no kitty socket" kitty-no-socket-says-so
errhas "--listen-on" kitty-names-the-flag
[ ! -s "$ARGV" ] || fail "focus/kitty called kitten with no socket to talk
to, so the error a user sees is kitten's /dev/tty one rather than mux's"
ENVSET=$LIVE

# --- AND `--to` BEATS THE INHERITED VALUE -------------------------------
# The config case, which is the only one that matters in anger: the daemon
# has no KITTY_LISTEN_ON, so the address comes from the hook's own argument.
# Asserted on the ARGV, because both forms exit 0 and only what was ASKED
# tells them apart.
mkall
# CAPTURED, not called bare: `run` ANSWERS on stdout, so an uncaptured call
# leaks a lone `0` into the suite's output, which is where a real message
# goes to hide.
eq kitty-to-wins-rc "$(run kitty --to unix:/tmp/other.sock northwood)" 0
case $(sed -n 1p "$ARGV") in
  (*'--to unix:/tmp/other.sock'*) ;;
  (*) fail "kitty-to-wins: the flag did not reach kitten:
[$(sed -n 1p "$ARGV")]" ;;
esac

pass
