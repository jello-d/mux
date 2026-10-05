#!/bin/sh
# test/harness.t - the harness's OWN guards, because it can delete your work.
#
# WHY THIS FILE EXISTS, and it is the worst thing this suite has done: on
# 2026-09-30 the harness deleted this repository. `T=$(mktemp -d)` leaves T
# EMPTY when mktemp fails, so the EXIT trap's `rm -rf ""` was harmless; the
# canonicalisation added that morning (`cd -- "$(mktemp -d)" && pwd -P`) turns
# the same empty string into `cd ""`, which stays put, and `pwd -P` then answers
# THE CURRENT DIRECTORY. One run with a TMPDIR that did not exist, and the trap
# removed the working tree.
#
# Nothing about that is exotic: a stale export, an unmounted tmpfs, or probing
# another platform's TMPDIR value, which is exactly what happened.
#
# So the harness checks its own scratch dir before arming the trap, and this
# file asserts the check, from the only angle that means anything: a CANARY in
# the caller's directory that must still be there afterwards.
set -eu
_name=harness
. "$(dirname "$0")/harness_lib"

# --- A SCRATCH DIR IT CANNOT VERIFY IS A REFUSAL, NEVER A GUESS -----------
# DRIVEN BY A STUB `mktemp`, NOT BY A BOGUS TMPDIR, and the difference matters:
# the first version pointed TMPDIR at a path that does not exist and asserted a
# refusal, which asserts a fact about the PLATFORM'S mktemp rather than about
# this guard. GNU mktemp fails there; BSD mktemp succeeds anyway, so the case
# was green here and red on macOS for a reason that had nothing to do with the
# code under test. Stub the tool and the test is about the guard.
#
# BOTH FAILURE SHAPES, because they are caught by different halves of it and the
# second is the one that destroyed a working tree: an empty answer with a ZERO
# exit slips straight past `||`.
_c=$T/canary
cat >"$T/probe.t" <<'EOF'
#!/bin/sh
set -eu
_name=probe
. "$HL"
pass
EOF
for _shape in 'exit 1' 'exit 0'; do
  rm -rf "$_c"; mkdir -p "$_c/bin"
  : >"$_c/DO_NOT_DELETE"
  # prints NOTHING, which is the shape that matters; the exit code varies.
  { echo '#!/bin/sh'; echo "$_shape"; } >"$_c/bin/mktemp"
  chmod +x "$_c/bin/mktemp"
  _rc=0
  _o=$(cd "$_c" && PATH=$_c/bin:$PATH HL=$HERE/test/harness_lib \
    sh "$T/probe.t" 2>&1) || _rc=$?

  # THE LOAD-BEARING ASSERTION, deliberately first: everything below is about
  # how politely it declined.
  [ -f "$_c/DO_NOT_DELETE" ] || fail "THE HARNESS DELETED ITS CALLER'S
DIRECTORY (mktemp shape: $_shape). An unverifiable scratch dir resolves to the
CURRENT directory and the EXIT trap removes it. That is how this repository was
lost once."

  [ "$_rc" != 0 ] || fail "mktemp shape [$_shape]: the harness accepted a
scratch dir it could not verify and reported success. Everything it does
afterwards assumes a private directory it is allowed to delete.
output: $_o"

  case $_o in
  *refusing*|*"mktemp -d failed"*) ;;
  *) fail "mktemp shape [$_shape]: the refusal did not say why, so the next
person meets a test that simply will not run: $_o" ;;
  esac
done

# --- THE CLEANUP TRAP HOLDS LITERALS, NOT A VARIABLE ----------------------
# The standing rule in ~/src/CLAUDE.md: `rm -rf` never runs with variable
# expansion. A trap is the sharpest case because it defers the expansion to FIRE
# TIME, which is when this harness removed a working tree: `$T` had resolved to
# the cwd and nothing could see that until the shell was already exiting.
#
# INSPECTED WITHOUT A SUBSTITUTION, which is load-bearing and was measured: in
# dash `$(trap)` reports NOTHING, because the subshell clears the EXIT trap,
# while bash reports it. So `$(trap)` would have made this assertion vacuous on
# the platform the suite mostly runs on. Redirecting keeps it in this shell.
trap >"$T/traps"
[ -s "$T/traps" ] || fail "could not read this shell's traps, so the assertion
below proves nothing"
grep -q 'rm -rf' "$T/traps" || fail "no cleanup trap is armed at all:
$(cat "$T/traps")"
# AN EXPANSION, NOT A DOLLAR SIGN, and the difference is a real one that only
# a third shell exposed. The first version grepped the trap text for any `$`
# and reported a DEFERRED EXPANSION under ksh against a trap holding perfect
# literals, because ksh renders a trap with ANSI-C quoting (the marker below
# is because this is ksh's OWN output, quoted verbatim):
#
#     trap -- $'rm -rf \'/tmp/x\'' EXIT   # conventions: allow --
#
# That `$` belongs to the QUOTING STYLE, so the assertion was about the
# shell's rendering rather than about the trap. Matching the three real
# expansion shapes (`$NAME`, `${`, `$(`) says what it means. ksh is not an
# interpreter this suite runs under, so nothing was broken; an assertion one
# quoting style away from lying is worth fixing anyway.
if grep 'rm -rf' "$T/traps" \
  | grep -qE '\$[A-Za-z_{(]'; then
  fail "the cleanup trap DEFERS AN EXPANSION:
$(grep 'rm -rf' "$T/traps")
It must hold the literal path, baked in when the trap was armed, so \`trap\`
prints exactly what will run and no later assignment can move the target. This
is the shape that deleted the repository."
fi
# ... and it is the RIGHT literal, or a trap naming some other path would pass
# the check above while removing the wrong thing (or nothing).
grep -q "$T" "$T/traps" || fail "the cleanup trap does not name the scratch
dir [$T]:
$(grep 'rm -rf' "$T/traps")"

# --- THE SOCKET PATH FITS ON macOS ----------------------------------------
# `sun_path` caps a unix socket path at 104 bytes there (108 on Linux), and
# macOS $TMPDIR spends ~50 of them before anything is added. With TMUX_TMPDIR
# inside $T the path came to 105 and tmux answered `File name too long`, which
# surfaced as `mux: demo: could not start a tmux server` and read as a demo bug.
#
# ASSERTED WITH A REAL SOCKET NAME from the real generator, since the name is
# part of the length and the longest one this suite uses is the one that broke.
_sp="$TMUX_TMPDIR/tmux-$(id -u)/$(tmux_fresh_socket mux.demotest99999)"
[ "${#_sp}" -le 104 ] || fail "a test socket path is ${#_sp} bytes, over macOS's
104-byte sun_path cap, so every test that drives a real tmux fails there with
\`File name too long\`:
  $_sp
TMUX_TMPDIR must stay short and must not derive from \$TMPDIR."

# ... and it is still PRIVATE, which is the property the length must not cost.
case $(ls -ld "$TMUX_TMPDIR" | cut -c1-10) in
drwx------) ;;
*) fail "the tmux socket dir is not private: $(ls -ld "$TMUX_TMPDIR")" ;;
esac

# --- EVERY NAME MUX EXPORTS IS ACCOUNTED FOR HERE ------------------------
# ASKED AS A CLASS, not one hole at a time, which is the only version of this
# that cannot rot. Four inherited handles have escaped this sandbox so far
# (`$TMUX`, `MUX_SHARE`, `XDG_RUNTIME_DIR`, `MUX_VIEW_SOCKET`), each found by
# falling into it, and each time the fix was one more name. A DERIVED PATH IS
# NOT THE ONLY WAY OUT OF A SANDBOX, AN INHERITED HANDLE IS ANOTHER, and the
# second is invisible because nothing about the test looks wrong.
#
# SO THE RULE IS CHECKED RATHER THAN REMEMBERED: anything mux EXPORTS is a
# value a test can inherit, so this file must either pin it or unset it. The
# next export gains a failing assertion the day it is written, which is what
# the three previous holes cost a debugging session each for.
_unacc=
# WORD-SPLITTING IS THE POINT HERE, not an oversight: the corpus is variable
# NAMES, matched as `[A-Z_]+`, so no element can contain a space or a glob
# character and a `while read` loop would buy nothing but a subshell.
# shellcheck disable=SC2013
for _v in $(grep -ohE 'export [A-Z_]+' "$HERE"/bin/mux "$HERE"/libexec/* \
    "$HERE"/lib/* 2>/dev/null | awk '{print $2}' | sort -u); do
  grep -q "\b$_v\b" "$HERE/test/harness_lib" || _unacc="$_unacc $_v"
done
[ -z "$_unacc" ] || fail "mux exports these and the harness neither pins nor
unsets them, so a suite run inheriting one tests against the developer's own
state:$_unacc

Add it to the \`unset\` line (or pin it, if tests need a value), beside
TMUX, MUX_SHARE and MUX_VIEW_SOCKET."

# AND THE ONE THAT MOTIVATED IT IS ASSERTED DIRECTLY, because the sweep above
# only proves the NAME is mentioned somewhere in the file: a comment would
# satisfy it. `mux-views_lib` reaches for this exactly when `$TMUX` is unset,
# which is the state this harness creates.
[ -z "${MUX_VIEW_SOCKET:-}" ] || fail "MUX_VIEW_SOCKET survived into a test,
so every views call here would run against tmux -L [$MUX_VIEW_SOCKET]"

pass
