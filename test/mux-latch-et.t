#!/bin/sh
# test/mux-latch-et.t - the Eternal Terminal transport: its classifier, and the
# one property of its transport line that is easy to get plausibly wrong.
#
# ET IS THE SECOND TRANSPORT, and the seam was built for exactly this: no core
# change, and the ssh-specific knowledge living in a file that can be REPLACED.
#
# THIS FILE WAS REWRITTEN AFTER A LAB RUN, and the shape of what it asserts is
# the lesson. The first version drove a dozen synthetic stderr strings through
# the classifier and passed, while the shipped transport line did not work at
# all and no arm keyed on stderr could ever fire against a real et. Two VMs said
# so in twenty minutes. So what is asserted here is now ONLY what a real et can
# actually produce:
#
#   - the documented transport line, scraped from the hook's header and RUN, so
#     the line a user copies is the line proven to hand the command over as one
#     unquoted element;
#   - the two exit codes et really returns, and nothing about stderr, because et
#     writes its diagnostics to STDOUT where a CLASSIFY hook cannot see them.
#
# WHAT IS DELIBERATELY NOT HERE, so nobody adds it back as "coverage": arms for
# mux's own 2/3/126/127. et 7.0.0 does not propagate the remote exit status, so
# those inputs never occur, and a test that feeds them by hand proves only that
# a `case` statement works.
set -eu
_name=mux-latch-et
. "$(dirname "$0")/harness_lib"

C=$HERE/share/latch/et-classify
[ -x "$C" ] || fail "share/latch/et-classify is missing or not executable; the
hook library's files are run by name, so the mode bit is part of the contract"

# --- the two answers the exit code can carry ------------------------------
_err=$T/err
: >"$_err"
cl() { "$C" "$1" "$_err"; }

# A CLEAN EXIT IS A DETACH. Measured end to end in the lab: a human detaching
# on the far side ends the transport at 0 and leaves the remote session alive,
# which is what `ended` promises. Retrying here would resurrect a session
# somebody just closed, which is the bug autossh has.
_got=$(cl 0)
[ "$_got" = ended ] || fail "a clean exit must be \`ended\`, got [$_got]"

# ET'S OWN CONNECT FAILURE MUST BE RETRYABLE. With etserver stopped, et exits 1
# (its message goes to stdout, which is why this is keyed on the CODE and not on
# a string). A booting box is the common cause and it heals by itself, so a
# terminal verdict would mean a human restarting latch after a fix latch could
# have waited through.
_got=$(cl 1)
[ "$_got" = probing ] || fail "et exit 1 is 'could not reach the ET server' in
practice, which heals by itself, so it must be retryable (probing), got [$_got].
A terminal verdict here strands a latch whose far side is merely rebooting."

# ANYTHING ELSE RETRIES. Including whatever et exits with when it gives up
# reconnecting, which its source does not name: being wrong in this direction
# costs a delay, and being wrong the other way kills a latch whose transport
# exists to survive drops.
for _rc in 143 255 78; do
  _got=$(cl "$_rc")
  [ "$_got" = unknown ] || fail "exit $_rc must be \`unknown\` (retry), got
[$_got]"
done
_got=$("$C" '' /dev/null)
[ "$_got" = unknown ] || fail "no exit code at all must be \`unknown\`, got
[$_got]"

# --- the documented transport line, executed -----------------------------
# SCRAPED, so the line people copy is the line under test. The first version of
# this file asserted a line containing `-t`, which reads as "request a pty" in
# ET's own flag table and is `--tunnel` in the release: it TAKES A VALUE, so it
# swallowed the host and et answered "Missing host to connect to" on exit 0.
# Nothing in a stub suite could have caught that. What can be caught here is the
# argv shape, so that is asserted, and the flags are asserted NOT to include the
# one that broke it.
_line=$(sed -n 's/^#  *latch-transport  *\(et .*\)/\1/p' "$C" | head -1)
[ -n "$_line" ] || fail "no \`latch-transport et ...\` example found in
share/latch/et-classify's header. The test scrapes the documented line so the
copy a user reads is the copy proven to work; without it every assertion below
would pass vacuously against a line nobody publishes."
case $_line in
*%c*) ;;
*) fail "the documented ET transport line does not use %c:
  $_line
ET types the command as keystrokes into a remote LOGIN shell, so it must arrive
as ONE UNQUOTED element. %q shell-quotes it, which is right for ssh (the far
side re-parses) and wrong here." ;;
esac
case $_line in
*%q*) fail "the documented line uses %q: $_line -- see above" ;;
esac
case $_line in
*" -t "*) fail "the documented line passes \`-t\`: $_line
In et 7.0.0 that is --tunnel and it TAKES A VALUE, so it swallows the host and
et exits 0 saying 'Missing host to connect to'. A pty is the default for
--command, so no flag is needed. Measured between two VMs, 2026-09-29." ;;
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
