#!/bin/sh
# test/mux-indicator-setup.t - indicator/setup.sh, the last dark file.
#
# A function-level coverage sweep found indicator/setup.sh completely
# unexecuted: app, service, uninstall and check had never run. It is the single
# source of the install procedure and tackup can delegate to it, so its `check`
# is a contract someone else reads.
#
# SYSTEMCTL IS STUBBED, and that is not tidiness. `setup.sh uninstall` runs
# `systemctl --user disable --now mux-indicator.service`, and the user manager
# knows that unit by NAME regardless of where XDG_CONFIG_HOME points -- so a
# test running it unstubbed would stop the developer's actually-running tray.
# The stub also lets the assertions be about what setup.sh DID rather than about
# whatever state this machine happens to be in.
#
# WHAT IS NOT TESTED, said plainly rather than faked: `app` builds a venv and
# pips the package, which needs a network and minutes, and `service` needs a
# real user manager. Stubbing pip would be testing the stub. Those stay
# integration; `setup.sh check` is what reports on them afterwards.
set -eu
_name=mux-indicator-setup
. "$(dirname "$0")/lib.sh"

SETUP=$HERE/indicator/setup.sh
[ -x "$SETUP" ] || fail "indicator/setup.sh is missing or not executable"

mkdir -p "$T/bin" "$T/venv/bin" "$T/xdg"
for _c in sed awk grep cat rm mkdir ln cmp install printf dirname basename; do
	_p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/bin/$_c"
done
# Records what it was asked to do and always succeeds, so the script's own
# `|| true` guards are not what makes this pass.
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SCTL"
if [ "${2:-}" = is-enabled ]; then printf '%s\n' "${SCTL_ENABLED:-disabled}"; fi
exit 0
EOF
chmod +x "$T/bin/systemctl"
SCTL=$T/systemctl.log
UNIT=mux-indicator.service
UNITF=$T/xdg/systemd/user/$UNIT

OUT=; RC=0
run() {   # <verb ...>
	: >"$SCTL"
	RC=0
	OUT=$(env PATH="$T/bin" HOME="$HOME" XDG_CONFIG_HOME="$T/xdg" \
		MUX_INDICATOR_VENV="$T/venv" MUX_INDICATOR_BIN="$T/bin" \
		SCTL="$SCTL" SCTL_ENABLED="${SCTL_ENABLED:-disabled}" \
		"$SETUP" "$@" 2>&1) || RC=$?
}
has() { case $OUT in *"$1"*) ;; *) fail "$2:
$OUT" ;; esac; }

# --- an unknown verb is a usage error, not a silent install -------------
# The dispatch defaults to `install` when given NOTHING, so a typo'd verb must
# not fall through to it: `setup.sh instal` building a venv and enabling a
# service would be a surprising amount of work for a misspelling.
run bogus-verb
[ "$RC" = 2 ] || fail "an unknown verb must exit 2, got $RC"
has usage "an unknown verb must print the usage"
[ ! -s "$SCTL" ] || fail "an unknown verb touched systemctl:
$(cat "$SCTL")"

# --- check REPORTS, and fails when nothing is installed ----------------
run check
[ "$RC" = 1 ] || fail "check on an empty prefix must exit non-zero, got $RC"
has '[FAIL]' "check must use the [FAIL] marker contract"
case $OUT in
*'[OK]'*) fail "nothing is installed, so nothing should read [OK]:
$OUT" ;;
esac
# It must not FIX anything -- an audit that installs is not an audit.
[ ! -e "$T/bin/mux-indicator" ] || fail "check created the bin symlink"
[ ! -e "$UNITF" ] || fail "check installed the unit file"

# --- the markers are PLAIN when captured -------------------------------
# tackup pipes this through its report styler, which repaints plain markers. If
# check emitted colour when not on a terminal, the styler would be painting
# over escape codes and the output would be mangled in the place a human reads.
case $OUT in
*"$(printf '\033')"*) fail "check emitted ANSI colour into a pipe:
$(printf '%s' "$OUT" | cat -v)" ;;
esac

# --- check turns [OK] as the pieces appear -----------------------------
# Each marker is a distinct question; a check that said [OK] to a box that is
# half-installed would be worse than one that failed, because it sends you
# looking elsewhere.
printf '#!/bin/sh\nexit 0\n' >"$T/venv/bin/mux-indicator"
chmod +x "$T/venv/bin/mux-indicator"
run check
has '[OK]' "with the venv app present, at least one marker must pass"
[ "$RC" = 1 ] || fail "still incomplete, so check must still fail"

mkdir -p "$T/xdg/systemd/user"
cp "$HERE/indicator/$UNIT" "$UNITF"
run check
has "$UNIT current" "a unit file matching the package's must read current"

# A STALE unit must not read as current: the whole point of comparing rather
# than merely existing is that an old copy runs old settings forever.
printf '# drifted\n' >>"$UNITF"
run check
case $OUT in
*"$UNIT current"*) fail "a DRIFTED unit file read as current. cmp exists here
precisely so an edited-then-forgotten unit cannot look installed." ;;
esac
cp "$HERE/indicator/$UNIT" "$UNITF"

# --- uninstall removes what it installed, and is idempotent ------------
ln -sf "$T/venv/bin/mux-indicator" "$T/bin/mux-indicator"
run uninstall
[ "$RC" = 0 ] || fail "uninstall must succeed, got $RC"
[ ! -e "$UNITF" ] || fail "uninstall left the unit file behind"
[ ! -e "$T/bin/mux-indicator" ] || fail "uninstall left the bin symlink behind"
grep -q 'disable' "$SCTL" || fail "uninstall never asked systemctl to disable:
$(cat "$SCTL")"

# THE VENV SURVIVES, deliberately: rebuilding it is minutes and a network, so
# uninstall removing it would make a reinstall expensive for no reason.
[ -x "$T/venv/bin/mux-indicator" ] \
	|| fail "uninstall deleted the venv. It says it leaves it in place, and
rebuilding is minutes and a network."
has 'venv' "uninstall should say the venv was left"

# Twice is once. A second run has nothing to remove and must not error.
run uninstall
[ "$RC" = 0 ] || fail "a second uninstall must be a no-op, got $RC"

pass
