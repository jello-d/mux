#!/bin/sh
# test/mux-keys.t - the cheat sheet, checked against the bindings it claims to
# document.
#
# THE INTERESTING ASSERTION IS THE TWO-DIRECTIONAL ONE, and it is the same
# technique test/mux-skill.t uses on the agent instructions: a document that
# describes a program drifts silently unless something compares them. Here:
#
#   every key `share/mux.tmux` binds to mux must be described in `share/keys`
#   every key described in `share/keys` must be bound by the fragment
#
# Both halves matter and they fail differently. An undescribed binding is a
# feature nobody can find, which is the whole reason this verb exists. A
# described key that nothing binds teaches a keystroke that does nothing, which
# is worse: the user presses it, gets tmux's default or silence, and concludes
# the documentation is unreliable.
#
# mux has already paid full price for a hand-written key list. `mux check`
# asserted `( ) b r R` while the fragment had also bound `u` and `E`, so a
# server missing both reported green for two releases.
set -eu
_name=mux-keys
. "$(dirname "$0")/harness_lib"

FRAG=$HERE/share/mux.tmux
KEYSF=$HERE/share/keys
mux() { env -u MUX_SHARE "$HERE/bin/mux" "$@"; }

# EVERY PREFIX BIND THE FRAGMENT MAKES, which is a DIFFERENT question from the
# one `mux check` asks, and the difference is the point. The check can only
# verify a binding that calls mux, because a binding that does not mention mux
# is indistinguishable from another config's. The cheat sheet documents what mux
# GIVES YOU, and `bind B switch-client -l` is mux's binding even though the
# command is tmux's own: it is the other half of the b/B pair and a sheet
# without it would be wrong.
#
# `[^ -]` excludes the mouse binding (`bind -n MouseDown1Status`), which has no
# prefix key to press and is mentioned in the output as prose instead.
bound() {
  sed -n 's/^bind \([^ -][^ ]*\) .*/\1/p' "$FRAG" | sort -u
}
described() {
  sed -n 's/^\([^#	 ][^	]*\)	.*/\1/p' "$KEYSF" | sort -u
}

[ -n "$(bound)" ] || fail "no bindings scraped from $FRAG; the pattern is
broken and every assertion below would pass vacuously"
[ -n "$(described)" ] || fail "no descriptions scraped from $KEYSF"

# --- every binding is described -------------------------------------------
for _k in $(bound); do
  described | grep -qxF -- "$_k" || fail "prefix $_k is bound to mux in
share/mux.tmux and not described in share/keys, so it is a feature nobody can
find. Describe it, or stop binding it."
done

# --- every description is bound -------------------------------------------
for _k in $(described); do
  bound | grep -qxF -- "$_k" || fail "share/keys describes prefix $_k, which
the fragment does not bind to mux. That teaches a keystroke that does nothing,
and a user who tries it stops trusting the rest of the list."
done

# --- the output names them all, with their text ----------------------------
# Asserted on the RENDERED output rather than on the file, because the point of
# the verb is what a human sees when they press the key: a formatting change
# that dropped a column would leave both files agreeing and the sheet useless.
_o=$(mux keys) || fail "mux keys failed: $_o"
for _k in $(described); do
  case $_o in
    *"$_k"*) ;;
    *) fail "mux keys does not mention $_k: [$_o]" ;;
  esac
done
_n_desc=$(described | grep -c .)
_n_out=$(printf '%s\n' "$_o" | grep -cE '^    .  ')
[ "$_n_out" -eq "$_n_desc" ] || fail "mux keys printed $_n_out key lines for
$_n_desc descriptions: the sheet and the data have come apart"

# --- it says how to reach it ----------------------------------------------
# A cheat sheet that does not say which prefix to press is a list of letters.
case $_o in
  *prefix*|*C-*|*M-*) ;;
  *) fail "mux keys does not say what to press before the key: [$_o]" ;;
esac

# --- and the popup binding exists -----------------------------------------
# The verb is reachable from a shell either way; the POINT is reaching it from
# inside the session where the question occurs.
grep -q '^bind ? .*mux keys' "$FRAG" \
  || fail "nothing binds prefix ? to \`mux keys\`, so the sheet is only
reachable by someone who already knows it exists"

# --- AND THE README'S TABLE IS A THIRD COPY -------------------------------
# `share/keys` is held against the fragment in both directions above, so it
# cannot drift from what mux binds. The README's own table can, and had: `u`
# (prefix-u, 0.43) and `E` (prefix-E, 0.50) were both missing, so two shipped
# bindings were undiscoverable from the file most readers start with. `mux
# undo-pane` in particular is one keystroke from a detach, which is the whole
# reason it exists.
#
# ONE DIRECTION ONLY, deliberately. The README's table legitimately carries
# rows share/keys does not (`Space`, `Tab`/`BTab`, a status-chip click): those
# come from mux-opinions.tmux and from tmux's own defaults, and the cheat
# sheet documents what MUX binds. So "every key mux binds is in the README" is
# the assertion, and "nothing else is" would be false by design.
_rm=$HERE/README.md
[ -f "$_rm" ] || fail "no README.md to hold the table against"
_rmiss=
while IFS="$(printf '\t')" read -r _k _; do
  case $_k in ''|'#'*) continue ;; esac
  grep -qF "\`$_k\`" "$_rm" || _rmiss="$_rmiss $_k"
done <"$KEYSF"
[ -z "$_rmiss" ] || fail "share/keys describes these bindings and README.md
names none of them:$_rmiss
A reader who starts at the README cannot discover them, and share/keys is
machine-held against the fragment while the README is prose somebody has to
remember to sweep."

pass
