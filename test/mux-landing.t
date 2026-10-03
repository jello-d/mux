#!/bin/sh
# test/mux-landing.t - `mux landing`, the recorder behind resume's landing spot.
#
# The LANDING is asserted in test/mux-resume.t, which is its consumer. This
# file is about the recorder's own three decisions, none of which that test can
# see: which partition the mark is filed under, that recording is SILENT, and
# that a write it cannot do costs the caller nothing.
#
# WHY THE KEY NEEDS ITS OWN FIXTURE: mux-resume.t's partition is `global`, so a
# mutation replacing the derivation with a literal `global` would be a no-op
# against its inputs and would report SURVIVED while proving nothing. The
# socket here is deliberately NOT global.
set -eu
_name=mux-landing
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/conf" "$T/sock"

# The only tmux call the verb makes. `*client_session*` rather than a bare
# *display-message*, so it cannot answer a different format question.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$ASKLOG"
case "$*" in
*client_session*) printf '%s\n' "${WANTSESS:-}" ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
ASKLOG=$T/asked; : >"$ASKLOG"; export ASKLOG
PATH=$T/bin:$PATH; export PATH

landing() {               # <args...> -- outside tmux
  ( cd "$T" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
    MUX_CACHE="$T/cache" "$HERE/bin/mux" landing "$@" ) 2>&1
}
inlanding() {             # <socket name> <args...> -- as if inside that server
  _s=$1; shift
  ( cd "$T" && env -u MUX_SHARE MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
    TMUX="$T/sock/$_s,1,0" "$HERE/bin/mux" landing "$@" ) 2>&1
}

# --- the mark is filed under the partition the SOCKET names ----------------
# $TMUX names the server we are ACTUALLY in. Re-resolving a partition from a
# hook's run-shell child is a guess that answers `global` wherever the context
# cannot tell, and this package has shipped the wrong-socket bug three times
# (agent read/send, mux even, next-blocked), every time because one answer was
# derived in two places. mux_ctx_socket is the identity function on the
# partition, so the socket's basename IS the key.
WANTSESS=api; export WANTSESS
_o=$(inlanding work --record)
[ -z "$_o" ] || fail "recording must be silent, printed: [$_o]"
[ -f "$T/state/landing.work" ] \
  || fail "a record made inside the 'work' server must be filed under that
partition. state holds [$(ls "$T/state" 2>/dev/null | tr '\n' ' ')]"
[ ! -e "$T/state/landing.global" ] \
  || fail "the mark was filed under the AMBIENT partition rather than the
server's own, so a non-default partition would record into global's mark and
resume would land on the wrong session there"
[ "$(cat "$T/state/landing.work")" = api ] \
  || fail "wrong value: [$(cat "$T/state/landing.work")]"

# IT ASKS THE SOCKET IT WAS GIVEN, by PATH. Asserted on the ASK rather than
# the answer, which is the rule this project adopted after paying for the
# wrong-socket bug twice: an outcome assertion passes whenever the wrong
# server happens to give a plausible answer.
grep -q -- "-S $T/sock/work display-message" "$ASKLOG" \
  || fail "the verb did not ask the socket \$TMUX named:
[$(cat "$ASKLOG")]"

# --- read and write agree on the key ---------------------------------------
# If they did not, `mux landing` would print a different mark from the one
# resume uses, which is a disagreement nothing else could surface.
[ "$(inlanding work)" = api ] \
  || fail "inside 'work', the read form must answer work's mark: got
[$(inlanding work)]"
[ -z "$(landing)" ] \
  || fail "OUTSIDE tmux the read form must answer the AMBIENT partition
(global here, which has no mark), not whatever file exists: [$(landing)]"

# --- a name with a space survives ------------------------------------------
# Session names may contain one (which is why the session set is
# tab-separated), and the whole line is the value precisely so nothing splits
# it. The verb ASKS for the name rather than being handed it in argv, so this
# cannot be broken by quoting at the call site either.
WANTSESS='two words'; export WANTSESS
inlanding work --record >/dev/null
[ "$(inlanding work)" = 'two words' ] \
  || fail "a session name with a space did not round-trip:
[$(inlanding work)]"
WANTSESS=api; export WANTSESS

# --- outside tmux there is nothing to record -------------------------------
# Not an error: `mux landing --record` is wired to a hook, and refusing loudly
# on a box where somebody runs it by hand would be noise. It must simply not
# invent a partition and write into it.
rm -f "$T/state/landing.work"
_o=$(landing --record)
[ -z "$_o" ] || fail "recording outside tmux should say nothing: [$_o]"
# A GLOB, not `ls | grep`: the question is whether any mark file exists, and
# an `if` inside the loop rather than a trailing `&&`, which would leave the
# loop non-zero and take the file down under set -e.
_left=
for _f in "$T"/state/landing.*; do
  if [ -e "$_f" ]; then _left="$_left ${_f##*/}"; fi
done
[ -z "$_left" ] \
  || fail "with no server to ask, it recorded something anyway: [$_left]"

# --- a write it cannot make costs the caller nothing -----------------------
# BEST EFFORT is a claim the library makes in a comment, so it gets an
# assertion: this runs from a session switch, and a read-only state directory
# must never cost somebody that switch.
chmod a-w "$T/state"
_rc=0
_o=$(inlanding work --record) || _rc=$?
chmod u+w "$T/state"
[ "$_rc" = 0 ] \
  || fail "an unwritable state dir must not fail the recorder, got $_rc"
[ -z "$_o" ] || fail "and it must still say nothing: [$_o]"

# --- an unknown argument is refused ----------------------------------------
# Exit 2 is mux's usage code. Silent acceptance would make a typo in the hook
# look like it worked while recording nothing.
_rc=0
_o=$(landing --recrod 2>&1) || _rc=$?
[ "$_rc" = 2 ] || fail "an unknown argument should exit 2, got $_rc: [$_o]"
case $_o in *"unknown argument"*) ;;
*) fail "the refusal did not say what was wrong: [$_o]" ;; esac

pass
