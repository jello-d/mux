#!/bin/sh
# setup.sh - set up mux-indicator (the SNI tray icon for mux agent-session
# state) for the CURRENT user. Standalone: just run `./setup.sh`. This script is
# the single source of the install procedure; an integrator (a provisioning
# system) can delegate to it by calling `setup.sh install` / `setup.sh check`,
# so the steps are identical whether or not one drives it, and pipx-vs-venv
# stays an internal detail.
#
#   setup.sh install     build the app env + install & enable the service
#   setup.sh app         just the app: an isolated venv + a ~/.local/bin script
#   setup.sh service     just the systemd --user unit (install + enable + start)
#   setup.sh check       verify the install ([OK]/[FAIL]/[WARN] markers)
#   setup.sh uninstall   remove the unit + the ~/.local/bin script
#
# All userspace: NO sudo. Idempotent (safe to re-run; adopts what exists). Needs
# python3 (for the venv) and, for the service, a systemd --user manager. A tray
# HOST (waybar's tray, or any desktop's) and `mux` on PATH are runtime needs.
# Overrides:
#   MUX_INDICATOR_VENV   venv dir   (default ~/.venvs/mux-indicator)
#   MUX_INDICATOR_BIN    bin dir    (default ~/.local/bin)
set -eu

self=$0
case $self in */*) ;; *) self=$(command -v -- "$self" || echo "$self") ;; esac
PKG_DIR=$(CDPATH= cd -- "$(dirname -- "$self")" && pwd)

VENV=${MUX_INDICATOR_VENV:-$HOME/.venvs/mux-indicator}
BIN_DIR=${MUX_INDICATOR_BIN:-$HOME/.local/bin}
UNIT=mux-indicator.service
UNIT_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

app() {
	[ -d "$VENV" ] || python3 -m venv "$VENV"
	"$VENV/bin/pip" install -q --upgrade pip
	# Deps come from the package's pyproject.toml (the single source): the first
	# install resolves them; the forced --no-deps reinstall then guarantees a
	# code change is picked up on a re-run (same version would else no-op).
	"$VENV/bin/pip" install -q "$PKG_DIR"
	"$VENV/bin/pip" install -q --force-reinstall --no-deps "$PKG_DIR"
	rm -rf "$PKG_DIR/build" "$PKG_DIR"/*.egg-info    # in-place build detritus
	mkdir -p "$BIN_DIR"
	ln -sfn "$VENV/bin/mux-indicator" "$BIN_DIR/mux-indicator"
	echo "mux-indicator: app -> $BIN_DIR/mux-indicator"
}

service() {
	mkdir -p "$UNIT_DIR"
	install -m 0644 "$PKG_DIR/$UNIT" "$UNIT_DIR/$UNIT"
	systemctl --user daemon-reload 2>/dev/null || true
	systemctl --user enable "$UNIT" 2>/dev/null || true
	# restart (not just enable --now) so a re-run picks up a unit/code change; a
	# headless install (no user bus yet) falls through to the next login.
	systemctl --user restart "$UNIT" 2>/dev/null || true
	echo "mux-indicator: service $UNIT installed + enabled"
}

uninstall() {
	systemctl --user disable --now "$UNIT" 2>/dev/null || true
	rm -f "$UNIT_DIR/$UNIT" "$BIN_DIR/mux-indicator"
	systemctl --user daemon-reload 2>/dev/null || true
	echo "mux-indicator: uninstalled (venv $VENV left in place)"
}

# _code_current: is the INSTALLED code the package's code?
#
# THE CHECK THAT WAS MISSING, and its absence was not theoretical: manifold ran
# a copy installed on 2026-08-30 for weeks while every marker here read [OK].
# Everything existed, the unit matched, the service was enabled -- and because a
# provisioner runs `apply` only when `check` FAILS, passing is exactly what kept
# the stale code alive. A green check was the thing preventing the fix.
#
# That is this package's own rule turned on itself: `mux check` exists because a
# presence check says [OK] to a box that is fully installed and fully broken,
# which is worse than failing because it sends you to look elsewhere.
#
# BY CONTENT, NOT BY VERSION. A version-keyed check needs someone to remember to
# bump it, and the same fleet has already watched a version-keyed plugin cache
# sit stale through two full provisions for exactly that reason. Content cannot
# be forgotten.
#
# The interpreter is ASKED where the package landed rather than globbing a
# python version out of the venv path -- one less thing to break when the
# interpreter moves.
_code_current() {
	_cc_dir=$("$VENV/bin/python" -c \
		'import mux_indicator,os;print(os.path.dirname(mux_indicator.__file__))' \
		2>/dev/null || true)
	if [ -z "$_cc_dir" ] || [ ! -d "$_cc_dir" ]; then
		bad "installed code not found (the venv cannot import it)"
		return 0
	fi
	_cc_drift=
	for _cc_f in "$PKG_DIR"/mux_indicator/*.py; do
		[ -f "$_cc_f" ] || continue
		_cc_b=${_cc_f##*/}
		cmp -s "$_cc_f" "$_cc_dir/$_cc_b" 2>/dev/null \
			|| _cc_drift="$_cc_drift $_cc_b"
	done
	if [ -n "$_cc_drift" ]; then
		bad "installed code is STALE or missing:$_cc_drift"
		bad "  run: setup.sh indicator install   (then the service restarts)"
	else
		ok "installed code matches the package"
	fi
}

# check: the [OK]/[FAIL] MARKER contract (same as `mux check`) -- coloured ONLY
# on a real terminal, so a caller that captures the output repaints the plain
# markers itself. mux owns this copy; no integrator dependency.
check() {
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
		_e=$(printf '\033')
		_G="$_e[1;32m"; _R="$_e[1;31m"; _O="$_e[0m"
	else
		_G=; _R=; _O=
	fi
	RC=0
	ok()  { printf '  %s[OK]%s   %s\n' "$_G" "$_O" "$*"; }
	bad() { printf '  %s[FAIL]%s %s\n' "$_R" "$_O" "$*"; RC=1; }

	if [ -x "$VENV/bin/mux-indicator" ]; then ok "venv app ($VENV)"
	else bad "venv app missing ($VENV) -- run: install app"; fi
	if "$VENV/bin/python" -c 'import dbus_next, PIL' 2>/dev/null
	then ok "deps import (dbus-next, Pillow)"
	else bad "deps not importable in the venv"; fi
	if [ -x "$BIN_DIR/mux-indicator" ]; then ok "$BIN_DIR/mux-indicator"
	else bad "$BIN_DIR/mux-indicator missing"; fi
	if cmp -s "$PKG_DIR/$UNIT" "$UNIT_DIR/$UNIT" 2>/dev/null
	then ok "$UNIT current"; else bad "$UNIT missing or stale"; fi
	_code_current
	_st=$(systemctl --user is-enabled "$UNIT" 2>/dev/null || true)
	if [ "$_st" = enabled ]; then ok "$UNIT enabled"
	else bad "$UNIT not enabled (${_st:-unknown})"; fi
	return "$RC"
}

case "${1:-install}" in
	install)   app; service ;;
	app)       app ;;
	service)   service ;;
	check)     check ;;
	uninstall) uninstall ;;
	*) echo "usage: setup.sh [install|app|service|check|uninstall]" >&2
	   exit 2 ;;
esac
