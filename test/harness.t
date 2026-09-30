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

# --- AN UNUSABLE TMPDIR IS A REFUSAL, NEVER A GUESS -----------------------
# Driven as a separate process from a scratch cwd, because the property under
# test is about the CALLER'S directory and this test's own cwd is the repo.
_c=$T/canary; mkdir -p "$_c"
: >"$_c/DO_NOT_DELETE"
cat >"$_c/probe.t" <<'EOF'
#!/bin/sh
set -eu
_name=probe
. "$HL"
pass
EOF

_rc=0
_o=$(cd "$_c" && HL=$HERE/test/harness_lib TMPDIR=$T/nope sh probe.t 2>&1) \
  || _rc=$?

# THE LOAD-BEARING ASSERTION, and it is deliberately first: everything else
# here is about how politely it declined.
[ -f "$_c/DO_NOT_DELETE" ] || fail "THE HARNESS DELETED ITS CALLER'S DIRECTORY.
With an unusable TMPDIR the scratch dir resolves to the CURRENT directory, and
the EXIT trap removes it. That is how this repository was lost once."

[ "$_rc" != 0 ] || fail "the harness accepted an unusable TMPDIR and reported
success. It must refuse: everything it does afterwards assumes a private
directory it is allowed to delete.
output: $_o"

case $_o in
*refusing*|*"mktemp -d failed"*) ;;
*) fail "the refusal did not say why, so the next person sees a test that
simply will not run: $_o" ;;
esac

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

pass
