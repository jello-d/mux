#!/bin/sh
# test/mux-check.t - `mux check`, the install audit.
#
# It is the thing you run to find out whether mux is coherently installed, so
# it being wrong is worse than most bugs: it does not merely fail, it tells you
# everything is fine. Its contract is small and exact --
#
#   one [OK]/[WARN]/[FAIL] line per check, and a NON-ZERO exit on any [FAIL]
#
# -- and the second half is the part with teeth, because anything gating on
# mux check reads the exit code, not the text. A check that could print [FAIL]
# without setting it made the auditor itself assert something untrue.
#
# Everything runs against a scratch MUX_SHARE/MUX_DIR with a reduced PATH, so
# the real install is never consulted and nothing outside T is touched.
set -eu
_name=mux-check
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/share" "$T/conf/partitions" "$T/src"
cp -R "$HERE/share/." "$T/share/"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/tmux"; chmod +x "$T/bin/tmux"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/mux";  chmod +x "$T/bin/mux"
# Everything mux-check shells out to. A reduced PATH is the point -- the
# notification checks below turn backends on and off by their PRESENCE -- so
# the ordinary tools have to be put back explicitly.
for _c in sed awk grep cut tr head tail wc cat ls id date find sort \
          basename dirname mktemp rm mkdir cp mv readlink; do
	_p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done
# Partition `probe`, NOT `global`: mux resolves MUX_DIR over MUX_SHARE, so
# deleting an overlay global.partition falls back to the SHIPPED one and the
# audit reads the real ~/src. A name nothing ships has no fallback to hide
# behind, which is what lets the no-scan-roots case be tested at all.
printf '#!/bin/sh\necho probe\n' >"$T/conf/cc"; chmod +x "$T/conf/cc"
printf 'context-command cc\n' >"$T/conf/config"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# check [ENV=VAL ...] -> the audit's output; RC holds its exit status.
check() {
	OUT=$(env -u MUX_NOTIFY_SEND -u MUX_NOTIFY_CLOSE \
		PATH="$T/bin" NO_COLOR=1 MUX_DIR="$T/conf" \
		MUX_SHARE="$T/share" MUX_CACHE="$T/cache" \
		"$@" "$HERE/libexec/mux-check" 2>&1) && RC=0 || RC=$?
	printf '%s' "$OUT"
}
has() { case "$OUT" in *"$1"*) ;; *) fail "$2: want [$1] in:
$OUT" ;; esac; }
no_has() { case "$OUT" in *"$1"*) fail "$2: unwanted [$1] in:
$OUT" ;; esac; }

# --- a healthy install: every marker OK, exit 0 ---------------------------
check >/dev/null
[ "$RC" -eq 0 ] || fail "a healthy install exited $RC:
$OUT"
no_has "[FAIL]" "healthy install reported a FAIL"
has "tmux present" "no tmux line"
has "package data" "no package-data line"
has "config overlay" "no overlay line"
has "scan root $T/src" "the configured scan root was not checked"

# --- a FAIL must set the exit code ----------------------------------------
# Each of these is raised from a DIFFERENT part of the file, which is the
# point: the scan-root check ran inside a `while` behind a pipe, so its RC=1
# was set in a subshell and discarded. It printed [FAIL] and exited 0.
check MUX_SHARE="$T/nosuchshare" >/dev/null
[ "$RC" -ne 0 ] || fail "missing package data exited 0"
has "[FAIL]" "missing package data raised no FAIL"

rm -rf "$T/src"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing scan root printed FAIL but exited 0"
has "scan root missing" "no report of the missing root"
# ... and it is still reported per-root, not collapsed to the first.
printf 'scan %s/src 2\nscan %s/other 2\n' "$T" "$T" \
	>"$T/conf/partitions/probe.partition"
check >/dev/null
[ "$RC" -ne 0 ] || fail "two missing roots exited 0"
has "$T/src" "first missing root unreported"
has "$T/other" "second missing root unreported"
mkdir -p "$T/src" "$T/other"
check >/dev/null
[ "$RC" -eq 0 ] || fail "both roots present, still exited $RC"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# --- a broken install is a FAIL, not a warning ----------------------------
mv "$T/share/layouts" "$T/share/layouts.away"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing share/layouts exited 0"
has "share/layouts missing" "no report of the missing share dir"
mv "$T/share/layouts.away" "$T/share/layouts"

# --- WARN is advisory: it reports, it does not fail -----------------------
# The distinction is the whole value of three markers rather than two.
printf 'root=%s\n' "$T" >"$T/conf/old.layout"
check >/dev/null
has "pre-rename" "a pre-rename *.layout was not surfaced"
has "mux migrate-profiles" "no pointer to the fix"
[ "$RC" -eq 0 ] || fail "a WARN must not fail the audit (rc=$RC)"
rm -f "$T/conf/old.layout"

# A name in BOTH the profile table and profiles.d is drift, and advisory.
mkdir -p "$T/conf/profiles.d"
printf 'dup root=%s\n' "$T/src" >"$T/conf/profiles"
printf 'root %s\n' "$T/src" >"$T/conf/profiles.d/dup.profile"
check >/dev/null
has "both a row and a breakout" "the row/file collision was not surfaced"
[ "$RC" -eq 0 ] || fail "a drift WARN must not fail the audit"
rm -rf "$T/conf/profiles" "$T/conf/profiles.d"

# --- no scan roots at all: discovery is OFF, and says so ------------------
rm -f "$T/conf/partitions/probe.partition"
check >/dev/null
has "no scan roots" "silent about discovery being off"
has "discovery is off" "did not say what that means"
printf 'scan %s/src 2\n' "$T" >"$T/conf/partitions/probe.partition"

# --- notifications are reported in TWO halves ----------------------------
# Raising and clearing can be separately absent, and a box that raises but
# cannot clear accumulates dead banners -- the failure the old mako-only
# close produced everywhere that was not mako.
printf '#!/bin/sh\nexit 0\n' >"$T/bin/notify-send"
chmod +x "$T/bin/notify-send"
check >/dev/null
has "notifications raise but never clear" "no report of a missing closer"
[ "$RC" -eq 0 ] || fail "an absent notification path must not FAIL"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/gdbus"; chmod +x "$T/bin/gdbus"
check >/dev/null
has "cleared via gdbus" "a usable closer was not credited"
rm -f "$T/bin/notify-send"
check >/dev/null
has "no notify-send" "silent about being unable to notify at all"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/notify-send"
chmod +x "$T/bin/notify-send"

# Both overrides set is a supported path; half an override is a mistake.
check MUX_NOTIFY_SEND=/bin/true MUX_NOTIFY_CLOSE=/bin/true >/dev/null
has "notifications overridden" "the override pair was not recognised"
check MUX_NOTIFY_SEND=/bin/true >/dev/null
has "together, or neither" "half an override was not called out"

# --- tmux itself: the one hard runtime dependency -------------------------
rm -f "$T/bin/tmux"
check >/dev/null
[ "$RC" -ne 0 ] || fail "a missing tmux exited 0"
has "tmux not found" "no report of the missing dependency"

pass
