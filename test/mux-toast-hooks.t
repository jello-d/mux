#!/bin/sh
# test/mux-toast-hooks.t - the shipped banner hooks under
# share/desktop-notifier/toast/.
#
# WRITTEN WITH THE HOOKS, not after. A seam stubbed at its caller leaves the
# seam itself untested, and this package has now found that four times: both
# latch hooks, all four envhooks, the notifier's own config key, and the two
# focus hooks. The python side (test_sni.ToastHook) proves the SEAM; this
# proves the FILES.
#
# THE LINE SPLIT IS THE WHOLE CONTRACT: first line is the summary, every line
# after it is the body. The daemon's format decides whether the body's first
# line joins the title row, so where a hook puts its newline IS the layout.
#
# AND THE TWO HOOKS SPLIT IT DIFFERENTLY ON PURPOSE, which is the fact this
# file exists to pin, because it is the one thing a reader will try to
# "harmonise":
#
#   pango  ALWAYS THREE LINES, the middle empty when there is no host. Its
#          daemon's format JOINS summary and body, so the body's first line
#          IS the title row and a two-line answer would put the message
#          there. The empty line is what buys the break.
#   dim    THREE REMOTE, TWO LOCAL, and never an empty one. Its daemon's
#          format cannot be changed, so there is no joined row to fill and
#          an empty first body line renders as a BLANK ROW (measured with
#          pango-view at Sans 11: 83px against 62px, a whole line taller).
#
# Same contract, opposite constraint. Neither shape is right for the other's
# daemon, which is why there are two files rather than a flag.
set -eu
_name=mux-toast-hooks
. "$(dirname "$0")/harness_lib"

HOOKS=$HERE/share/desktop-notifier/toast
ALL=$(find "$HOOKS" -type f | sed 's|.*/||' | sort)
_n=$(printf '%s\n' "$ALL" | wc -l)
[ "$_n" -ge 2 ] || fail "only $_n toast hooks found: [$(printf '%s\n' "$ALL" \
| tr '\n' ' ')]"

run() { _h=$1; shift; "$HOOKS/$_h" "$@" >"$T/out" 2>"$T/err"; }
line() { sed -n "$1p" "$T/out"; }
nlines() { wc -l <"$T/out" | tr -d ' '; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- WHAT BOTH OWE: A SUMMARY ON LINE ONE, AND NO MARKUP IN IT -----------
# Swept over every shipped hook, so a new one arrives tested. Only the BODY
# is parsed by any of these daemons, so a span in the summary prints its own
# tags, and asserting that is an ABSENCE: "it has the session in it" is true
# of a marked-up summary too.
for _h in $ALL; do
  run "$_h" blocked api northgate global remote
  eq "summary-$_h" "$(line 1)" "Claude needs you: api"
  case $(line 1) in (*'<span'*|*'</'*)
    fail "$_h: the summary carries markup, which a daemon that does not
parse it will print literally: [$(line 1)]" ;; esac
  run "$_h" finished api northgate global remote
  eq "finished-summary-$_h" "$(line 1)" "Claude finished: api"
  # AND NOTHING ON STDERR ON A SUCCESSFUL RUN: mux prints a hook's stderr
  # when it exits non-zero, so noise here would read as a failure in the log.
  eq "quiet-$_h" "$(cat "$T/err")" ""
  # A LOCAL BANNER NAMES NO HOST, the rule the built-in wording follows too:
  # saying "on this-box" every time is noise on the common path.
  run "$_h" finished api here global local
  case $(cat "$T/out") in (*here*)
    fail "$_h: a LOCAL banner named the host" ;; esac
done

# --- pango: THREE LINES ALWAYS, because its first body line is positional
# A hook that emitted two when there is no host would put the body on the
# title row locally and on its own row remotely: the same banner changing
# shape depending on which machine it came from.
run pango finished api northgate global remote
eq pango-remote-lines "$(nlines)" 3
run pango finished api here global local
eq pango-local-lines "$(nlines)" 3
eq pango-local-host-line "$(line 2)" ""
eq pango-local-body "$(line 3)" "your turn"

run pango blocked api northgate global remote
eq pango-remote-host "$(line 2)" \
  '<span foreground="#8a8a8a">(on northgate)</span>'
eq pango-remote-body "$(line 3)" "permission or input"

# --- dim: NEVER AN EMPTY LINE, which is the whole reason it exists -------
# FIRST, AND THAT ORDER IS LOAD-BEARING. This is the direct statement of the
# rule and it sweeps every shape the hook has; the line counts below are the
# same fact seen through one case each. Ordered the other way round, a plant
# that adds a blank line lands on a COUNT, which says a line moved and not
# which rule was broken, and this sweep could never be shown to fire at all.
#
# AND THE EXIT SENSE IS THE AWKWARD WAY ROUND: `grep -q` answers 0 when it
# FINDS one, so the failure is the success. Written as an `if` rather than
# `grep && fail`, because that form is a bare AND-OR list whose status is
# grep's, and reading it takes a trip through what `set -e` exempts.
for _c in "finished api northgate global remote" \
          "finished api here global local" \
          "blocked api northgate work remote" \
          "finished api here work local" \
          "finished api northgate work remote"; do
  # shellcheck disable=SC2086   # a case's arguments, split on purpose
  run dim $_c
  if grep -qE '^$' "$T/out"; then
    fail "dim emitted an EMPTY line for [$_c], which renders as a blank ROW
on a daemon whose format it cannot change. That is the one failure this hook
exists to avoid, and it is what toast/pango does deliberately: a blank line
is correct there and wrong here."
  fi
done

# AND THE SHAPE, one case each: three lines remote, two local. A count cannot
# make the claim above (a stray blank plus a dropped body is still three) but
# it does catch a hook that stopped emitting a row at all.
run dim finished api northgate global remote
eq dim-remote-lines "$(nlines)" 3
run dim finished api here global local
eq dim-local-lines "$(nlines)" 2
eq dim-local-body "$(line 2)" "your turn"

# --- THE HOST GETS ITS OWN ROW, DIM, AND CARRIES THE PARTITION ----------
# They share a row because together they are the address of the thing asking
# for you, which is the same reasoning that moved the host into pango's
# title. `global` is the baseline every box has, so naming it would add a
# word that never varies.
run dim blocked api northgate global remote
eq dim-host "$(line 2)" '<span foreground="#8a8a8a">(on northgate)</span>'
eq dim-body "$(line 3)" "permission or input"
run dim finished api northgate work remote
eq dim-host-part "$(line 2)" \
  '<span foreground="#8a8a8a">(on northgate [work])</span>'
# A NON-BASELINE PARTITION IS WORTH A ROW EVEN LOCALLY, because two
# partitions on one box otherwise produce identical banners. Both directions,
# since one assertion passes on a hook that prints it never and on one that
# prints it always.
run dim finished api here work local
eq dim-local-part-lines "$(nlines)" 3
eq dim-local-part "$(line 2)" '<span foreground="#8a8a8a">[work]</span>'
# THE OTHER DIRECTION IS `dim-local-lines` ABOVE, which asserts 2 for the
# same call with the BASELINE partition: a row appearing there is the only
# way the global case can go wrong. A second copy of it here was redundant
# and the corpus said so, by killing on the first one.
run pango finished api northgate global remote
case $(line 3) in (*global*) fail "pango named the baseline partition" ;;
esac
run pango finished api northgate work remote
case $(line 3) in (*'[work]'*) ;;
  (*) fail "pango did not name a non-baseline partition, so two partitions
on one host produce identical banners: [$(line 3)]" ;; esac

# --- ESCAPED IN THE BODY, RAW IN THE SUMMARY ----------------------------
# The asymmetry is deliberate and is the one thing a reader will want to
# "fix". An unescaped `&` in the BODY makes the daemon refuse to parse the
# banner and draw NOTHING; an ESCAPED one in the summary prints `&amp;` at
# somebody who called their session `a&b`.
for _h in $ALL; do
  run "$_h" finished 'a&b' 'ho&st' global remote
  eq "summary-raw-$_h" "$(line 1)" 'Claude finished: a&b'
  case $(line 2) in (*'&amp;st'*) ;;
    (*) fail "$_h: the host was not escaped into the body, so a name with an
ampersand makes the daemon drop the banner: [$(line 2)]" ;; esac
done

# --- THE DIM COLOUR IS OVERRIDABLE, AND IT IS THE ONLY KNOB -------------
# `env`, NOT a prefix on a function call: that shape is unspecified and
# PERSISTS on macOS /bin/sh and ksh, which test/lint.t refuses for the reason.
for _h in $ALL; do
  run "$_h" finished api northgate global remote
  case $(line 2) in (*'#8a8a8a'*) ;;
    (*) fail "$_h: no default dim: [$(line 2)]" ;; esac
  env MUX_TOAST_DIM='#ff0000' "$HOOKS/$_h" \
    finished api northgate global remote >"$T/out" 2>"$T/err"
  case $(line 2) in (*'#ff0000'*) ;;
    (*) fail "$_h: MUX_TOAST_DIM did not reach the span: [$(line 2)]" ;;
  esac
done

pass
