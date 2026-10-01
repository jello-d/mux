#!/bin/sh
# test/mux-window.t - `mux window`, the HUMAN presenter of the window engine.
#
# IT CREATES AND SWITCHES, where `mux agent open` creates DETACHED. That is
# the load-bearing difference between the two verbs rather than a nicety: a
# program that moves the human's view mid-turn is an interrupt nobody asked
# for, and a human who typed this obviously wants to go there.
#
# THE ADDRESS IS RIGHT-ANCHORED HERE, the one place mux's grammar is read from
# the other end, because this verb's subject is a WINDOW: a bare word is a
# window name, exactly as `tmux select-window -t foo` reads it. The parser is
# still the single one in mux-addr_lib; only the interpretation of its answer
# differs, in one place.
#
# tmux is stubbed, so no server starts and nothing real is switched.
set -eu
_name=mux-window
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/conf/partitions"

# THE STUB RECORDS THE SOCKET on every call, because asking the DEFAULT
# socket instead of the partition's is a bug this package has shipped THREE
# times (mux-even, next-blocked, and `send`/`read` together), and each time
# the wrong server gave a plausible answer. So the assertions below check what
# was ASKED, not only what came back.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$LOG"
case "$*" in
*has-session*) [ -z "${NOSESSION:-}" ] || exit 1 ;;
*session_name*) printf '%s\n' "${CURSESS:-here}" ;;
*new-window*)  printf '%s\n' "${NEWIDX:-4}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
LOG=$T/log; export LOG
PATH=$T/bin:$PATH; export PATH

# win [ENV...] ARGS -> run the verb, capturing both streams in $OUT.
RC=0
win() {
  RC=0
  : >"$LOG"
  OUT=$(env -u MUX_SHARE MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
    TMUX="${FAKE_TMUX-$T/global,1,0}" LOG="$LOG" \
    NOSESSION="${NOSESSION:-}" NEWIDX="${NEWIDX:-4}" \
    CURSESS="${CURSESS:-here}" \
    "$HERE/bin/mux" window "$@" 2>&1) || RC=$?
}
logged() { cat "$LOG"; }

# --- A BARE NAME IS A WINDOW IN THE SESSION YOU ARE IN --------------------
win build
[ "$RC" = 0 ] || fail "a bare name failed: rc=$RC $OUT"
case "$(logged)" in
*'new-window -t =here'*) ;;
*) fail "a bare name did not open in the current session: $(logged)" ;;
esac
case "$(logged)" in
*'-n build'*) ;;
*) fail "the bare word was not used as the WINDOW name: $(logged)" ;;
esac

# AND IT SWITCHES, which is this verb's whole difference from `agent open`.
# BOTH halves are asserted, because they are different mechanisms: the engine
# is told not to detach (so tmux selects it within the session) AND the client
# is moved (which is what matters when the target session is not the one being
# looked at). Either alone leaves the human somewhere they did not ask for.
case "$(logged)" in
*'new-window'*' -d '*) fail "the human verb detached, so it created a window
and left the human where they were: $(logged)" ;;
esac
case "$(logged)" in
*'switch-client -t =here:4'*) ;;
*) fail "the client was not moved to the new window: $(logged)" ;;
esac
case $OUT in
*'opened here:4'*) ;;
*) fail "it did not say what it opened: [$OUT]" ;;
esac

# --- A QUALIFIED ADDRESS NAMES THE SESSION, WHEREVER YOU ARE --------------
win 'other:build'
[ "$RC" = 0 ] || fail "a qualified address failed: rc=$RC $OUT"
case "$(logged)" in
*'new-window -t =other'*) ;;
*) fail "SESSION:NAME did not target that session: $(logged)" ;;
esac

# --- AND A PARTITION REACHES ITS OWN SOCKET ------------------------------
# NAMING YOUR OWN PARTITION IS NOT A CROSSING, which is the case that must
# still work: a fully-qualified address is what an orchestrator composes, and
# refusing it because a partition was merely SPELLED would break the spelling
# `peers` hands back. So the context is made to answer `work` here.
printf 'label work\n' >"$T/conf/partitions/work.partition"
printf 'context-command ctx\n' >"$T/conf/config"
printf '#!/bin/sh\nprintf work\n' >"$T/conf/ctx"
chmod +x "$T/conf/ctx"
win 'work::proj:build'
[ "$RC" = 0 ] || fail "naming one's OWN partition was refused as a crossing,
which would break the fully-qualified spelling peers hands back: $OUT"
case "$(logged)" in
*'-L work'*) ;;
*) fail "a partition-qualified address did not ask that partition's SERVER.
Asking the default socket gives a plausible answer from the wrong place,
which is the bug this package has shipped three times: $(logged)" ;;
esac

# --- AND A DIFFERENT PARTITION IS REFUSED -------------------------------
# Opening a window RUNS A COMMAND, so it crosses harder than typing into a
# pane that already exists: where a partition's boundary is a group acquired
# per session, the children of that server hold it.
win 'global::proj:build'
[ "$RC" = 2 ] || fail "a cross-partition open must be refused, got $RC: $OUT"
case $OUT in
*'refusing to open a window'*) ;;
*) fail "the refusal did not say what it would not do: [$OUT]" ;;
esac
case "$(logged)" in
*new-window*) fail "it opened the window anyway: $(logged)" ;;
esac
rm -f "$T/conf/config" "$T/conf/ctx"

# --- A PARTITION WITHOUT A SESSION IS REFUSED, WITH THE REMEDY ----------
# Naming a partition means you are not in it, so there is no "the session I
# am in" over there to default to. Guessing would open a window in a session
# that exists and is not the one meant.
win 'work::build'
[ "$RC" = 2 ] || fail "a partition with no session must exit 2, got $RC: $OUT"
case $OUT in
*'needs the session too'*) ;;
*) fail "the refusal did not say what was missing: [$OUT]" ;;
esac
case $OUT in
*'mux window work::SESSION:build'*) ;;
*) fail "the refusal did not print the working spelling, which is what
_common.md asks of a refusal that costs somebody their muscle memory:
[$OUT]" ;;
esac

# --- OUTSIDE tmux, A BARE NAME IS REFUSED RATHER THAN GUESSED -----------
# THE ASSERTION THAT MATTERS MOST HERE, because doing nothing is not neutral:
# tmux's own default target is the most recently CREATED session, so an
# unqualified call outside tmux would open a window in whichever session
# happened to be newest and say nothing about it.
# EMPTY, NOT UNSET, and `win` reads it with `${FAKE_TMUX-...}` so the two are
# different: unset means "use the default fake $TMUX", empty means "there is
# no tmux here". A plain assignment rather than a `VAR= func` prefix, because
# whether that survives the call is unspecified and test/lint.t refuses it.
FAKE_TMUX=
win build
[ "$RC" = 2 ] || fail "outside tmux a bare name must be refused, got $RC"
# NO CORPUS RECORD REACHES THE NEXT ONE, said rather than implied: the exit
# code above fires first for every mutation that removes the guard, so this
# is the belt-and-braces half. It is kept because it names the consequence
# (a window opened in a session nobody chose) where an exit code only says
# the call was allowed.
case "$(logged)" in
*new-window*) fail "it opened a window with no session named. tmux would
have picked the newest session: plausible, wrong and silent." ;;
esac
case $OUT in
*'mux window SESSION:build'*) ;;
*) fail "the refusal did not name the remedy: [$OUT]" ;;
esac
unset FAKE_TMUX

# --- A MISSING SESSION IS exit 3, NOT A NEW SESSION ---------------------
# `mux go` creates sessions; this never does. Exit 3 is mux's cross-cutting
# "the name is not known here", so a caller that mistyped gets the same answer
# from every verb rather than a surprise session.
NOSESSION=1 win 'nope:build'; unset NOSESSION
[ "$RC" = 3 ] || fail "a missing session must exit 3, got $RC: $OUT"
case "$(logged)" in
*new-window*) fail "it tried to open a window in a session that is not
there: $(logged)" ;;
esac

# --- A CLASS IS DECLARABLE, AND ONLY FROM THE THREE WORDS ---------------
win build --control agent --attention agent
[ "$RC" = 0 ] || fail "declaring classes failed: $OUT"
case "$(logged)" in
*'@mux-control agent'*) ;;
*) fail "--control did not reach the new pane: $(logged)" ;;
esac
case "$(logged)" in
*'@mux-attention agent'*) ;;
*) fail "--attention did not reach the new pane: $(logged)" ;;
esac
win build --control supervisor
[ "$RC" = 2 ] || fail "an unknown class must exit 2, got $RC: $OUT"

# A WINDOW NAME MAY NOT CONTAIN A COLON, for the same reason a session name
# may not: the grammar spends `:` on the window separator, so the name would
# be unaddressable by the very grammar that wrote it. Two colons make it a
# three-field address, which is the parser's job to refuse; one makes it a
# session and a window, so this asserts the THREE-field spelling.
win 'a:b:c:d'
[ "$RC" = 2 ] || fail "an over-qualified address must exit 2, got $RC: $OUT"

pass
