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
*%q*) fail "the documented line uses %q: $_line. See above" ;;
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
# CAPTURED, for the reason mux-latch.t records at its own no-probe case: if
# latch refuses before attempting, its message is the only thing that says why,
# and `>/dev/null 2>&1` is where that went.
_eo=$(env XDG_RUNTIME_DIR="$T/run" MUX_DIR="$T/conf" MUX_SHARE="$HERE/share" \
  ETLOG="$T/argv" \
  MUX_LATCH_TRANSPORT="$_stub_line" \
  MUX_LATCH_CLASSIFY=et-classify \
  MUX_LATCH_AUTH=/bin/true MUX_LATCH_MAX_TRIES=1 \
  "$HERE/libexec/mux-latch" box proj 2>&1) || true
_got=$(cat "$T/argv" 2>/dev/null || true)
[ -n "$_got" ] || fail "the stubbed et was never invoked, so the argv assertion
below would prove nothing. latch may have refused before attempting.
latch said: ${_eo:-<nothing>}"
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


# --- the PROBE, which is what makes a stopped etserver diagnosable ---------
# IT EXISTS FOR A REASON ssh-probe DOES NOT HAVE. Over ssh a failure explains
# itself on stderr, which the classifier reads. ET writes its diagnostics to
# stdout and propagates no remote status, so a stopped etserver reaches the
# classifier as a bare exit 1 and nothing can tell it from anything else. The
# probe moves that diagnosis to the one place that can still make it: before the
# attempt, over TCP, from here.
P=$HERE/share/latch/et-probe
[ -x "$P" ] || fail "share/latch/et-probe is missing or not executable"

# `nc` IS STUBBED, because the real one needs a network this test must not
# touch, and because the interesting cases are its exit codes rather than its
# bytes. NCRC is what the stub returns; NCLOG records the argv so the port
# actually used can be asserted: a probe that tests the wrong port parks latch
# in a backoff about a service that is running.
mkdir -p "$T/pbin"
cat >"$T/pbin/nc" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$NCLOG"
exit ${NCRC:-0}
EOF
chmod +x "$T/pbin/nc"
for _c in sed head command timeout; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/pbin/$_c"
done

probe() {   # <nc exit> [env assignments...] -> the probe's exit
  _ncrc=$1; shift
  : >"$T/nclog"
  _prc=0
  env PATH="$T/pbin:$PATH" NCRC="$_ncrc" NCLOG="$T/nclog" \
    MUX_DIR="$T/pconf" "$@" "$P" box >/dev/null 2>&1 || _prc=$?
  printf '%s' "$_prc"
}
mkdir -p "$T/pconf"

# THE OPEN PORT IS THE ONLY "ATTEMPT IT" ANSWER.
_got=$(probe 0)
[ "$_got" = 0 ] || fail "a reachable etserver port must answer 0 (attempt it),
got [$_got]"

# A CLOSED PORT IS A WAIT, NOT A DEAD END. etserver stopped, a box still
# booting, a firewall: all of them either heal by themselves or are fixed and
# then heal, and this is the whole reason the hook exists.
_got=$(probe 1)
[ "$_got" = 1 ] || fail "a closed etserver port must answer 1 (not reachable:
wait and retry), got [$_got]. That verdict is the one thing the classifier
cannot reach over ET, which is why this hook is worth wiring at all."

# THE PORT IT TESTS IS ET'S, AND IS OVERRIDABLE. Asserted on the argv the stub
# recorded, because "it answered 0" is true of testing the wrong port too.
probe 0 >/dev/null
grep -q ' 2022$' "$T/nclog" || fail "the probe did not test ET's default port
2022; it asked: [$(cat "$T/nclog")]"
probe 0 MUX_ET_PORT=2099 >/dev/null
grep -q ' 2099$' "$T/nclog" || fail "MUX_ET_PORT did not move the port the probe
tests; it asked: [$(cat "$T/nclog")]"
printf 'latch-et-port  2101\n' >"$T/pconf/config"
probe 0 >/dev/null
grep -q ' 2101$' "$T/nclog" || fail "the latch-et-port config key did not move
the port; it asked: [$(cat "$T/nclog")]"
rm -f "$T/pconf/config"

# timeout(1)'s CODE IS A DEFINITE NO. A port that will not complete a handshake
# inside the bound will not serve an attach either, so this is 1 rather than
# "cannot tell", which keeps latch in a visible backoff instead of a silent
# wait.
_got=$(probe 124)
[ "$_got" = 1 ] || fail "the bound being hit must answer 1, got [$_got]"

# nc FAILING FOR ITS OWN REASONS IS "CANNOT TELL", because it says nothing about
# the host and quietly attempting would hide a local misconfiguration.
_got=$(probe 2)
[ "$_got" = 78 ] || fail "an nc failure that is not a refusal must answer 78,
got [$_got]"

# NO HOST AT ALL IS 78, never 0: a probe with nothing to test must not report a
# host usable.
_prc=0
env PATH="$T/pbin:$PATH" "$P" >/dev/null 2>&1 || _prc=$?
[ "$_prc" = 78 ] || fail "no host must answer 78, got [$_prc]"

# AND NO `nc` MEANS NO OPINION, WHICH IS THE ONE ANSWER THAT DIFFERS FROM
# ssh-probe. latch treats 78 as WAIT, so answering it here would park a
# perfectly good ET transport forever on a box that merely lacks netcat,
# whereas a missing `ssh` genuinely means the ssh transport is dead anyway.
# A curated PATH, not a broken stub: absence has to be modelled by absence, the
# lesson test/mux-portability.t paid for.
mkdir -p "$T/nonc"
for _c in sed head command; do
  _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/nonc/$_c"
done
[ -e "$T/nonc/nc" ] && fail "the curated PATH still has nc, so this case models
nothing"
_prc=0
env -i PATH="$T/nonc" HOME="$T" "$P" box >/dev/null 2>&1 || _prc=$?
[ "$_prc" = 0 ] || fail "with no nc the probe answered [$_prc]; it must answer 0
(attempt it, the same as no probe at all). 78 would make latch WAIT, which holds
a transport that works fine on any box without netcat."

pass
