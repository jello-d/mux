#!/bin/sh
# test/mux-focus-hooks.t - the two shipped ACTIVATE hooks, `focus-kitty` and
# `focus-wayfire`, which raise the window showing a host's latch after the
# tray has already switched that host's session.
#
# WRITTEN BECAUSE NEITHER HAD EVER EXECUTED. The only test naming them reads
# `desktop-notifier-activate focus-kitty` out of a config file and asserts the
# STRING comes back, which is a test of the config reader. Shipping a hook and
# running it are different acts, and this is the FOURTH time this package has
# found a shipped hook completely dark: both latch hooks, then all four
# envhooks, then the notifier's own config key, now these.
#
# THE CONTRACT IS 78, NEVER 1, and it is the same three-answer contract latch's
# hooks use. 78 is "cannot answer": not finding the window, or not having the
# tool, is a different fact from the raise having failed, and the notifier
# REPORTS a non-zero exit rather than swallowing it, so a misconfigured hook
# says so instead of doing nothing.
#
# AND THE ASSERTIONS ARE ON THE ARGV, not on the exit code, wherever the rule
# is about WHAT was asked. Both hooks match `title:\[LABEL\]` with the
# brackets, because mux's own `set-titles-string` ends every window title in
# `[host_short]`: matching the bare name would also match a SESSION called
# `northwood`, or a path in the title. A hook that raised the wrong window
# still exits 0, so only the recorded argv can tell them apart.
set -eu
_name=mux-focus-hooks
. "$(dirname "$0")/harness_lib"

HOOKS=$HERE/share/desktop-notifier
mkdir -p "$T/bin"
ARGV=$T/argv
export ARGV

# A tool that records what it was asked and answers as told. One stub shape
# for both hooks, because both reach for exactly one command.
mk() {   # <name> <exit-code>
  cat >"$T/bin/$1" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$ARGV"
exit $2
EOF
  chmod +x "$T/bin/$1"
}
run() {   # <hook> [args...] -> exit code, with stderr in $T/err
  : >"$ARGV"
  _h=$1; shift
  _r=0
  # A CURATED PATH, holding NOTHING but the stubs. Both hooks reach for
  # `command -v` and `echo`, which are builtins, so the only thing either can
  # find is what this test put there. With /usr/bin on the end, `kitten` is
  # REAL on a box that has kitty installed and the missing-tool case silently
  # becomes the tool-fails case: green here, and a false pass on a developer's
  # machine, which is the direction that wastes the most time.
  env PATH="$T/bin" WAYFIRE_SOCKET="${WFS:-}" \
    "$HOOKS/$_h" "$@" >"$T/out" 2>"$T/err" || _r=$?
  echo "$_r"
}
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }
errhas() { case "$(cat "$T/err")" in *"$1"*) ;;
  *) fail "$2: want [$1] in [$(cat "$T/err")]" ;; esac; }

# --- NO LABEL IS A USAGE ERROR, and it is 78 like everything else here ----
# Not 2: this is a hook answering mux, so it speaks the hook contract rather
# than mux's own exit codes, and a caller must not have to know which.
WFS=/run/wf.sock
for _h in focus-kitty focus-wayfire; do
  mk kitten 0; mk wf-msg 0
  eq "no-label-$_h" "$(run "$_h")" 78
  errhas "usage: $_h LABEL" "no-label-$_h-says-so"
  [ ! -s "$ARGV" ] || fail "$_h ran its tool with no label to match"
done

# --- A MISSING TOOL IS 78, AND NAMES THE TOOL ----------------------------
# The likeliest real failure: the hook is wired and the terminal is not the
# one it knows about. Saying which command is absent is the difference between
# a one-line fix and a hunt.
rm -f "$T/bin/kitten"
eq missing-kitten "$(run focus-kitty box)" 78
errhas "kitten is not on PATH" missing-kitten-names-it
rm -f "$T/bin/wf-msg"
eq missing-wfmsg "$(run focus-wayfire box)" 78
errhas "wf-msg is not on PATH" missing-wfmsg-names-it

# --- WAYFIRE NEEDS ITS SOCKET, and says which plugin supplies it ---------
# Checked BEFORE the tool, because wf-msg being present tells you nothing
# about the ipc plugin being enabled, and that is the usual missing half.
mk wf-msg 0
# THE PREFIX GOES ON `run`, inside the substitution, which is a SUBSHELL, so
# the value cannot leak past this line. A prefix on `eq` itself would be the
# unspecified shape test/lint.t refuses, and it bought nothing: `run` is what
# reads WFS.
eq no-socket "$(WFS= run focus-wayfire box)" 78
errhas "WAYFIRE_SOCKET unset" no-socket-says-so
errhas "ipc plugin" no-socket-names-the-remedy

# --- THE HAPPY PATH, AND THE BRACKETS ------------------------------------
# The load-bearing assertion of the file. `title:\[LABEL\]`, escaped, because
# mux emits `...[#{host_short}]` and an unanchored match would also hit a
# session of that name or a path in the title.
mk kitten 0; mk wf-msg 0
eq kitty-ok "$(run focus-kitty northwood)" 0
eq kitty-argv "$(cat "$ARGV")" '@ focus-window --match title:\[northwood\]'
eq wayfire-ok "$(run focus-wayfire northwood)" 0
eq wayfire-argv "$(cat "$ARGV")" 'focus-window title:\[northwood\]'

# A LABEL THAT IS A SUBSTRING OF ANOTHER must not be able to match it, which
# is what the closing bracket buys and what no exit code can show.
eq kitty-anchored-right "$(run focus-kitty man; cat "$ARGV")" \
  "0
@ focus-window --match title:\\[man\\]"

# --- AND A TOOL THAT FAILS IS 78, NOT ITS OWN CODE -----------------------
# A raise that did not happen is "cannot answer"; passing the tool's status
# through would mean the notifier had to learn each terminal's exit codes.
mk kitten 3
eq kitty-failed "$(run focus-kitty northwood)" 78
errhas "no kitty window titled 'northwood'" kitty-failed-says-so
mk wf-msg 3
eq wayfire-failed "$(run focus-wayfire northwood)" 78
errhas "could not focus a window titled 'northwood'" wayfire-failed-says-so

pass
