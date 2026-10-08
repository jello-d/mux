#!/bin/sh
# test/mux-toast-pango.t - the shipped Pango banner hook.
#
# WRITTEN WITH THE HOOK, not after it. A seam stubbed at its caller leaves the
# seam itself untested, and this package has now found that FOUR times: both
# latch hooks, all four envhooks, the notifier's own config key, and the two
# focus hooks. The python side (test_sni.ToastHook) proves the SEAM; this
# proves the FILE.
#
# THE LINE SPLIT IS THE WHOLE CONTRACT: first line is the summary, every line
# after it is the body. The daemon's format decides whether the body's first
# line joins the title row, so where this script puts its newline IS the
# layout, and that is why the empty-line case below matters as much as the
# populated one.
set -eu
_name=mux-toast-pango
. "$(dirname "$0")/harness_lib"

HOOK=$HERE/share/desktop-notifier/toast-pango
[ -x "$HOOK" ] || fail "$HOOK is missing or not executable"

run() { "$HOOK" "$@" >"$T/out" 2>"$T/err"; }
line() { sed -n "$1p" "$T/out"; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- THREE LINES, ALWAYS, because the body's first one is positional ------
# A hook that emitted two lines when there is no host would put the body on
# the title row locally and on its own row remotely: the same banner changing
# shape depending on which machine it came from.
run finished api northgate global remote
eq remote-lines "$(wc -l <"$T/out" | tr -d ' ')" 3
run finished api here global local
eq local-lines "$(wc -l <"$T/out" | tr -d ' ')" 3

# --- the summary carries the session, and is NOT marked up ----------------
# Only the BODY is parsed, so a span here would print its own tags. Asserted
# as an absence, because "it has the session in it" is true of both.
run blocked api northgate global remote
eq blocked-summary "$(line 1)" "Claude needs you: api"
case $(line 1) in *'<span'*) fail "the summary carries markup, which a daemon
that does not parse it will print literally: [$(line 1)]" ;; esac
run finished api northgate global remote
eq finished-summary "$(line 1)" "Claude finished: api"

# --- A REMOTE host is the body's FIRST line, dim and alone ----------------
eq remote-host "$(line 2)" \
  '<span foreground="#8a8a8a">(on northgate)</span>'
eq remote-body "$(line 3)" "your turn"

# --- AND A LOCAL ONE LEAVES IT EMPTY, which is the line break -------------
# The control, and the load-bearing half: with a format that joins the body's
# first line to the title, an empty one is what puts the body on its own row.
run finished api here global local
eq local-host-line "$(line 2)" ""
eq local-body "$(line 3)" "your turn"
# ... and the host is named NOWHERE, not merely moved: saying "on this-box"
# every time is the noise the built-in wording also refuses.
case $(cat "$T/out") in *here*) fail "a LOCAL banner named the host" ;; esac

# --- ESCAPED IN THE BODY, RAW IN THE SUMMARY ------------------------------
# The asymmetry is deliberate and is the one thing a reader will want to
# "fix". An unescaped `&` in the BODY makes the daemon refuse to parse the
# banner and draw nothing; an ESCAPED one in the summary prints `&amp;` at
# somebody who called their session `a&b`.
run finished 'a&b' 'ho&st' global remote
eq summary-is-raw "$(line 1)" 'Claude finished: a&b'
case $(line 2) in *'&amp;st'*) ;;
  *) fail "the host was not escaped into the body, so a name with an
ampersand makes the daemon drop the banner: [$(line 2)]" ;; esac

# --- the partition, only when it says something ---------------------------
# `global` is the baseline every box has, so naming it adds a word that never
# varies. Both directions, because one assertion passes on a hook that prints
# the partition never and on one that prints it always.
run finished api northgate global remote
case $(line 3) in *global*) fail "the baseline partition was named: it is on
every box, so it is a word that never varies" ;; esac
run finished api northgate work remote
case $(line 3) in *'[work]'*) ;;
  *) fail "a non-baseline partition was NOT named, so two partitions on one
host produce identical banners: [$(line 3)]" ;; esac

# --- the dim colour is overridable, and it is the only knob ---------------
run finished api northgate global remote
case $(line 2) in *'#8a8a8a'*) ;; *) fail "no default dim: [$(line 2)]" ;; esac
# `env`, NOT a prefix on `run`: a variable assignment before a FUNCTION call
# is unspecified and PERSISTS on macOS /bin/sh and ksh, which test/lint.t
# refuses for that reason.
env MUX_TOAST_DIM='#ff0000' "$HOOK" finished api northgate global remote \
  >"$T/out" 2>"$T/err"
case $(line 2) in *'#ff0000'*) ;;
  *) fail "MUX_TOAST_DIM did not reach the span: [$(line 2)]" ;; esac

# --- and it says nothing on stderr ----------------------------------------
# mux prints a hook's stderr when it exits non-zero, so noise on a SUCCESSFUL
# run would read as a failure in the daemon's log.
run finished api northgate global remote
eq quiet "$(cat "$T/err")" ""

pass
