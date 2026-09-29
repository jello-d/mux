#!/bin/sh
# test/mux-latch-et.t - the Eternal Terminal transport: its classifier, and the
# one property of its transport line that is easy to get plausibly wrong.
#
# ET IS THE SECOND TRANSPORT, and the seam was built for exactly this: five
# commands, no core change, and the classifier's ssh-specific knowledge living
# in a file that can be REPLACED rather than in mux. This test is what says the
# replacement actually holds together, because the shipped state machine is
# already covered by mux-latch.t against a stub.
#
# THE TWO THINGS WORTH ASSERTING ARE NOT THE SAME KIND:
#
#   1. every arm of et-classify, because a classifier that answers `ended` to a
#      failure reports SUCCESS for a session that never existed, and mux has
#      shipped that bug once already (`mux latch -V` ran `ssh -V`, which
#      succeeds);
#   2. that the DOCUMENTED transport line hands the command over as ONE
#      UNQUOTED argv element, because ET types it as keystrokes into a remote
#      login shell, so `%q`'s quoting -- which is exactly right for ssh -- would
#      make the far side try to run a command whose NAME contains spaces.
#
# THE TRANSPORT LINE IS SCRAPED FROM THE DOCUMENTATION, not restated here. A
# second copy would drift, and the copy people read is the one in the hook's
# header; scraping it makes that copy executable. Same technique test/mux-keys.t
# uses on the cheat sheet and test/mux-skill.t on the agent instructions.
#
# NO REAL `et` IS INVOLVED and none is needed for either question: the argv
# property is about what latch composes, and the classifier's input is an exit
# code and a file. What a live ET does with a real etserver is a different
# claim, and the hook's header says plainly that it has not been made.
set -eu
_name=mux-latch-et
. "$(dirname "$0")/harness_lib"

C=$HERE/share/latch/et-classify
[ -x "$C" ] || fail "share/latch/et-classify is missing or not executable; the
hook library's files are run by name, so the mode bit is part of the contract"

# --- every arm of the classifier ------------------------------------------
_err=$T/err
cl() {   # <exit> <stderr text> -> the state word
  printf '%s\n' "$2" >"$_err"
  "$C" "$1" "$_err"
}

# THE EXIT-0 TRAP FIRST, because it is the one with a precedent. et answers 0 to
# several of its own usage errors, so a classifier that believes an exit 0 turns
# a broken `latch-transport` line into "the human detached", reports success,
# and exits 0 for a session that never existed.
for _case in 'Missing host to connect to' \
    'Value for keepalive must be specified only once' \
    'Keep-alive duration must between 1 and 3600'; do
  _got=$(cl 0 "$_case")
  [ "$_got" = refused ] || fail "et exits 0 on its own usage error, and
et-classify read [$_got] rather than refused for:
  $_case
That is the \`mux latch -V\` bug: a clean exit from a transport that never
connected reads as the human detaching, so latch reports SUCCESS for a session
that was never created."
done

# ... and a genuine clean exit is still `ended`, or the guard above would have
# eaten the one case that matters most: a human detaching on purpose.
_got=$(cl 0 '')
[ "$_got" = ended ] || fail "a clean exit with nothing on stderr must be
\`ended\` (the human detached; the typed \`; exit\` carried mux's own 0), got
[$_got]"

# ET's OWN failure, the one with no ssh equivalent: the handshake works and
# etserver is not answering. RETRIED rather than terminal, because it heals the
# moment the service comes up and a terminal verdict would need the human to
# restart latch after a fix latch could have waited through.
_got=$(cl 1 'Could not reach the ET server: box:2022')
[ "$_got" = probing ] || fail "etserver not answering must be retryable
(probing), got [$_got]: a box that is still booting is the common case, and a
terminal verdict there means restarting latch by hand after it comes up"

# ET BOOTSTRAPS OVER SSH, so ssh's refusals arrive through it with their
# meanings intact. Both directions asserted, because they differ on the axis
# that decides terminality: a host key mismatch happens during key exchange and
# spends no credential, a denial spends one and raises a prompt.
_got=$(cl 1 'Host key verification failed.')
[ "$_got" = untrusted ] || fail "a host key mismatch through ET's bootstrap ssh
must be \`untrusted\` (bounded retry), got [$_got]"
_got=$(cl 1 'Permission denied (publickey).')
[ "$_got" = denied ] || fail "a rejected credential must be \`denied\`
(terminal, needs a human), got [$_got]"

# Anything else at exit 1 is the remote mux refusing, or et rejecting its own
# arguments. Both terminal, both explained on stderr, which latch prints.
_got=$(cl 1 'mux: no such profile')
[ "$_got" = refused ] || fail "an unrecognised exit 1 must be refused, got
[$_got]"

# THE REMOTE MUX'S CODES ARRIVE INTACT, which is what lets this file be short:
# ET propagates the remote exit status (the client returns remoteExitStatus, and
# the typed `; exit` gives the login shell the command's own code). If that ever
# stops being true these three arms go silently useless, so they are asserted
# together to say what they depend on.
_got=$(cl 2 ''); [ "$_got" = refused ] \
  || fail "mux's usage code (2) must be refused, got [$_got]"
_got=$(cl 3 ''); [ "$_got" = gone ] \
  || fail "mux's unknown-name code (3) must be gone, got [$_got]"
_got=$(cl 127 ''); [ "$_got" = refused ] \
  || fail "the remote shell's 127 must be refused, got [$_got]"

# A code nobody has documented -- including whatever et exits with when it stops
# reconnecting -- must RETRY. Being wrong in that direction costs a delay; being
# wrong the other way kills a latch whose transport exists to survive drops.
_got=$(cl 143 ''); [ "$_got" = unknown ] \
  || fail "an unknown exit must be \`unknown\` (retry), got [$_got]"
_got=$("$C" '' /dev/null); [ "$_got" = unknown ] \
  || fail "no exit code at all must be \`unknown\`, got [$_got]"

# --- the documented transport line, executed -----------------------------
# SCRAPED, so the line people copy is the line under test. If the header's
# example is edited into something that word-splits the command, this fails.
_line=$(sed -n 's/^#  *latch-transport  *\(et .*\)/\1/p' "$C" | head -1)
[ -n "$_line" ] || fail "no \`latch-transport et ...\` example found in
share/latch/et-classify's header. The test scrapes the documented line so that
the copy a user reads is the copy that is proven to work; without it every
assertion below would pass vacuously against a line nobody publishes."
case $_line in
*%c*) ;;
*) fail "the documented ET transport line does not use %c:
  $_line
ET types the command as keystrokes into a remote LOGIN shell, so the command
must arrive as ONE UNQUOTED element. %q shell-quotes it, which is right for ssh
(the far side re-parses) and wrong here -- the shell would look for a command
whose name contains spaces." ;;
esac
case $_line in
*%q*) fail "the documented ET transport line uses %q: $_line
See above -- %q is the ssh form and would break ET." ;;
esac

# A stub standing in for `et`, recording the argv it was handed. The COUNT is
# the assertion (a split shows up as extra elements) and the last element makes
# a failure legible.
mkdir -p "$T/bin"
cat >"$T/bin/et" <<'EOF'
#!/bin/sh
_a=
for _a in "$@"; do :; done
printf 'n=%s last=[%s]\n' "$#" "$_a" >"$ETLOG"
exit 0
EOF
chmod +x "$T/bin/et"

mkdir -p "$T/conf" "$T/run"
_stub_line=$T/bin/et${_line#et}
env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
  ETLOG="$T/argv" \
  MUX_LATCH_TRANSPORT="$_stub_line" \
  MUX_LATCH_CLASSIFY=et-classify \
  MUX_LATCH_AUTH=/bin/true MUX_LATCH_MAX_TRIES=1 \
  "$HERE/libexec/mux-latch" box proj >/dev/null 2>&1 || true
_got=$(cat "$T/argv" 2>/dev/null || true)
[ -n "$_got" ] || fail "the stubbed et was never invoked, so the argv assertion
below would prove nothing. latch may have refused before attempting."
case $_got in
*'last=[mux go proj]') ;;
*) fail "the ET transport did not hand the command over as one unquoted
element. Wanted the last argv element to be exactly
  mux go proj
got
  $_got
A quoted last element means the documented line uses %q, and the far side's
login shell would try to run a command whose name contains spaces. More
elements than expected means it word-split." ;;
esac

pass
