#!/bin/sh
# test/mux-scan-init.t - turning discovery on, and refusing to guess.
#
# THE DEFECT THIS REPLACES: mux SHIPPED `scan ~/src 3` in
# share/partitions/global.partition, so an install that did not keep projects in
# ~/src got `[FAIL] scan root missing: /home/<user>/src` from mux's own check.
# That is most machines and every CI runner, and a fresh install failing its own
# check for declining to guess where somebody keeps their work is the worst
# possible first impression. A default is fine; a default nobody confirmed is
# not, so the bootstrap ASKS.
#
# MOST OF THIS NEEDS NO PTY, which is the reason the coverage is real rather
# than aspirational: the REFUSAL prints the default it would have offered, so
# the sniffing is observable from a pipe. Only the accept-the-default path needs
# a terminal, and t_pty supplies one on either userland.
set -eu
_name=mux-scan-init
. "$(dirname "$0")/harness_lib"

H=$T/home; mkdir -p "$H"
mux() {   # always THIS checkout, and never the ambient MUX_SHARE
  env -u MUX_SHARE -u TMUX -u TMUX_PANE \
    HOME="$H" MUX_DIR="$MD" MUX_CACHE="$T/cache" MUX_STATE="$T/state" \
    "$HERE/bin/mux" "$@"
}

# --- THE SHIPPED PARTITION DECLARES NO LOCATION ---------------------------
# The regression guard for the whole point. A `scan` line here is a root nobody
# chose, and it reaches every install.
_gp=$HERE/share/partitions/global.partition
[ -r "$_gp" ] || fail "share/partitions/global.partition is missing"
if grep -qE '^[[:space:]]*scan[[:space:]]' "$_gp"; then
  fail "the SHIPPED global partition declares a scan root:
$(grep -nE '^[[:space:]]*scan[[:space:]]' "$_gp")
That is a location nobody chose, on every machine that installs mux, and it is
what made \`mux check\` FAIL on any box without that directory."
fi

# --- --roots ANSWERS, so a caller need not parse config -------------------
MD=$T/c1
mux scan --roots >"$T/out" 2>&1 && fail "--roots must exit non-zero with no
roots configured, or setup.sh cannot tell whether to ask"
[ ! -s "$T/out" ] || fail "--roots printed something with nothing configured:
$(cat "$T/out")"

# --- WITHOUT A TERMINAL IT REFUSES, and names the remedy -----------------
# The same call `mux setup claude` makes. A provisioner runs the installer on
# every sweep, so a prompt would hang it and a silent write would hand one
# machine a root the human never named.
_rc=0
mux scan --init >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "no terminal and no directory must exit 2, got $_rc:
$(cat "$T/out")"
grep -q 'needs a terminal' "$T/out" || fail "the refusal did not say why:
$(cat "$T/out")"

# --- THE DEFAULT IS SNIFFED, NOT HARDCODED -------------------------------
# Asserted through the refusal, which prints the exact command it would have
# offered. Both directions, because "it suggested something" is equally true of
# a hardcoded answer: with no ~/src the default is HOME, with one it is that.
grep -q "mux scan --init $H\$" "$T/out" || fail "with no ~/src the default
should be \$HOME, but the refusal offered:
$(grep 'scan --init' "$T/out")"

mkdir -p "$H/src"
mux scan --init >"$T/out2" 2>&1 || true
grep -q "mux scan --init $H/src\$" "$T/out2" || fail "with a ~/src present it
should be preferred, but the refusal offered:
$(grep 'scan --init' "$T/out2")"

# --- A DIRECTORY NAMED OUTRIGHT IS RECORDED ------------------------------
mkdir -p "$H/projects"
mux scan --init "$H/projects" >"$T/out" 2>&1 \
  || fail "--init DIR failed: $(cat "$T/out")"
_pf=$MD/partitions/global.partition
[ -r "$_pf" ] || fail "--init wrote no partition file at $_pf"
grep -qE "^scan[[:space:]]+$H/projects 3\$" "$_pf" \
  || fail "the scan line is not what was asked for:
$(cat "$_pf")"
# It says WHERE it wrote, because a bootstrap that edits a file silently is one
# nobody can undo.
grep -q "$_pf" "$T/out" || fail "--init did not name the file it wrote:
$(cat "$T/out")"

# ... and --roots now agrees, which is what setup.sh keys on.
mux scan --roots >"$T/out" 2>&1 || fail "--roots still exits non-zero after
--init, so a re-install would ask again every time"
grep -q "$H/projects 3" "$T/out" || fail "--roots does not report the new root:
$(cat "$T/out")"

# --- IDEMPOTENT: a second run adds nothing -------------------------------
# Running it twice must not give the partition two roots, which would double
# every scan and read as a mux that cannot count.
mux scan --init "$H/projects" >"$T/out" 2>&1 \
  || fail "a second --init failed: $(cat "$T/out")"
_n=$(grep -cE '^scan[[:space:]]' "$_pf")
[ "$_n" = 1 ] || fail "a second --init added another root ($_n scan lines):
$(cat "$_pf")"
grep -q 'already set' "$T/out" || fail "the second run did not say the roots
were already set, so a user cannot tell it declined: $(cat "$T/out")"

# --- IT APPENDS, NEVER OVERWRITES ---------------------------------------
# THE LOAD-BEARING SAFETY PROPERTY. A partition file may already carry a label,
# a theme or a layout, and a bootstrap step that rewrote somebody's config is
# the one unrecoverable mistake available here.
MD=$T/c2
mkdir -p "$MD/partitions"
cat >"$MD/partitions/global.partition" <<'EOF'
# a config that already exists, with settings mux must not eat
theme   copper
layout  code
EOF
mux scan --init "$H/projects" >"$T/out" 2>&1 \
  || fail "--init failed on an existing partition file: $(cat "$T/out")"
for _keep in 'theme   copper' 'layout  code'; do
  grep -qF "$_keep" "$MD/partitions/global.partition" \
    || fail "--init DESTROYED an existing setting [$_keep]:
$(cat "$MD/partitions/global.partition")"
done
grep -qE '^scan[[:space:]]' "$MD/partitions/global.partition" \
  || fail "--init did not append its scan line to the existing file"

# --- A PATH THAT IS NOT A DIRECTORY IS REFUSED ---------------------------
MD=$T/c3
_rc=0
mux scan --init "$H/nope" >"$T/out" 2>&1 || _rc=$?
[ "$_rc" = 2 ] || fail "a non-existent directory must exit 2, got $_rc"
[ -e "$T/c3/partitions/global.partition" ] && fail "it wrote a partition file
for a directory that does not exist"

# --- AND THE INTERACTIVE PATH, where a terminal exists ------------------
# The only case that needs a pty: pressing Enter takes the offered default.
# Skipped rather than failed without one, the same as every other pty case here.
if [ -n "$T_PTY" ]; then
  MD=$T/c4
  printf '\n' | t_pty /dev/null \
    "env -u MUX_SHARE -u TMUX HOME=$H MUX_DIR=$MD MUX_CACHE=$T/cache \
MUX_STATE=$T/state $HERE/bin/mux scan --init" >"$T/out" 2>&1 || true
  grep -q 'where do you keep your projects' "$T/out" \
    || fail "no prompt appeared on a terminal: $(cat "$T/out")"
  grep -qE "^scan[[:space:]]+$H/src 3\$" "$MD/partitions/global.partition" \
    2>/dev/null || fail "pressing Enter did not accept the offered default:
$(cat "$MD/partitions/global.partition" 2>/dev/null)
output was: $(cat "$T/out")"
else
  printf 'note: %s skipped the prompt case (no usable script(1))\n' "$_name" >&2
fi

pass
