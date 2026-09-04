#!/bin/sh
# mux-notify.sh - raise and clear desktop notifications without binding mux to
# one notification daemon. Sourced by agent-state-emit (which raises one when an
# agent stops needing the CPU and starts needing YOU) and by agent-state-render
# (which clears one whose pane has since died). Functions only; source it, do
# not run it.
#
# Raising has always been portable: notify-send is libnotify, which every
# freedesktop desktop ships. CLEARING was the part hardcoded to `makoctl
# dismiss`, so a stale "needs you" only ever cleaned itself up under mako on
# Wayland; under dunst, xfce4-notifyd, GNOME or KDE the call was a silent no-op
# and the banner sat there until dismissed by hand.
#
# Nothing about the operation was ever mako-specific. Closing a notification by
# id is in the freedesktop spec that all of those daemons implement, as
# org.freedesktop.Notifications.CloseNotification. So the portable close is a
# plain D-Bus call and the only real variable is which D-Bus CLI is installed:
# gdbus (glib), busctl (systemd) and dbus-send (dbus itself) are each tried in
# turn, with makoctl kept LAST so a mako box carrying no D-Bus CLI at all keeps
# the behaviour it had. All four were verified against a live mako.
#
# Everything here is best effort and silent. A machine with no daemon, no
# notify-send or no session bus is a machine where mux notifies nobody, and
# that must never surface as an error: mux_notify_send runs inside a Claude Code
# hook, where a non-zero exit is a failed hook.
#
# NOT freedesktop at all (macOS, a phone relay, a logger)? Set both of
# MUX_NOTIFY_SEND and MUX_NOTIFY_CLOSE to commands. Send is invoked as
# `CMD URGENCY SUMMARY BODY` and should print an id on stdout (or nothing, if
# it has no notion of one); close is invoked as `CMD ID` and may ignore it. An
# id is opaque to mux -- it only ever hands back what send printed -- so any
# token the pair agrees on works.

# _mux_notify_closer -> the first usable close backend, or `none`. Cached in
# MUX_NOTIFY_CLOSER: the render pass can clear several phantoms in one run and
# there is no reason to re-probe per notification.
_mux_notify_closer() {
	if [ -z "${MUX_NOTIFY_CLOSER:-}" ]; then
		MUX_NOTIFY_CLOSER=none
		for _nc in gdbus busctl dbus-send makoctl; do
			if command -v "$_nc" >/dev/null 2>&1; then
				MUX_NOTIFY_CLOSER=$_nc
				break
			fi
		done
	fi
	printf '%s' "$MUX_NOTIFY_CLOSER"
}

# mux_notify_close ID -- clear a notification mux raised, because the state
# that raised it has passed. Never fails, and does nothing at all for an empty
# ID (the common case: most state files carry no notification).
mux_notify_close() {
	[ -n "${1:-}" ] || return 0
	if [ -n "${MUX_NOTIFY_CLOSE:-}" ]; then
		$MUX_NOTIFY_CLOSE "$1" >/dev/null 2>&1 || true
		return 0
	fi
	case $(_mux_notify_closer) in
	gdbus)
		gdbus call --session \
			--dest org.freedesktop.Notifications \
			--object-path /org/freedesktop/Notifications \
			--method \
			org.freedesktop.Notifications.CloseNotification \
			"$1" >/dev/null 2>&1 || true ;;
	busctl)
		busctl --user call org.freedesktop.Notifications \
			/org/freedesktop/Notifications \
			org.freedesktop.Notifications CloseNotification \
			u "$1" >/dev/null 2>&1 || true ;;
	dbus-send)
		dbus-send --session --type=method_call \
			--dest=org.freedesktop.Notifications \
			/org/freedesktop/Notifications \
			org.freedesktop.Notifications.CloseNotification \
			"uint32:$1" >/dev/null 2>&1 || true ;;
	makoctl)
		makoctl dismiss -n "$1" >/dev/null 2>&1 || true ;;
	esac
	return 0
}

# mux_notify_send URGENCY SUMMARY BODY -> the new notification's id on stdout,
# or nothing when it could not be raised or the server declined to report one.
# URGENCY is the spec's low|normal|critical.
#
# mux passes `normal`, and deliberately never `critical`. critical is the spec's
# "an emergency, do not expire me": mako maps it to urgency=high, whose stock
# config sets default-timeout=0, and dunst treats it the same way. That made
# every "Claude needs you" a banner that outlived the thing it reported and had
# to be swatted by hand. An agent waiting on a permission prompt is not a system
# emergency; the status strip and the tray already hold the state persistently,
# so the notification only has to be the nudge that points at them.
#
# -a names mux as the source, which is what lets a daemon-side rule (a mako
# [app-name=mux] block) style or route these without also catching every other
# notification on the box.
mux_notify_send() {
	_nu=${1:-normal}
	_nsum=${2:-}
	_nbody=${3:-}
	if [ -n "${MUX_NOTIFY_SEND:-}" ]; then
		$MUX_NOTIFY_SEND "$_nu" "$_nsum" "$_nbody" 2>/dev/null || true
		return 0
	fi
	command -v notify-send >/dev/null 2>&1 || return 0
	notify-send -a mux -u "$_nu" -p "$_nsum" "$_nbody" 2>/dev/null || true
}
