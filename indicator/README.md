# mux-indicator

An **optional** system-tray indicator for mux's agent-session state. It shows,
from anywhere, whether a session is waiting on you -- a single aggregate glyph
(a session waiting > a session working > all done) in the notification tray.

It is a StatusNotifierItem (the freedesktop tray standard), so it shows in
waybar's tray and in any desktop's -- nothing here is waybar-specific. It reads
mux's own per-session state; the state model stays in mux, this is presentation.

It is a **separate, opt-in component**: mux itself stays POSIX shell with no
daemon. This is the one piece that runs as a small background service (a D-Bus
tray item needs one), so it lives here and installs on its own.

## Install

Python, installed in isolation with `pipx` (so no system-package or
externally-managed-environment friction):

```sh
pipx install ./indicator          # from a mux checkout -> ~/.local/bin/mux-indicator
mux-indicator                      # run it in the foreground to try it
```

Dependencies (pulled in automatically): `dbus-next` (pure-Python D-Bus, so no
PyGObject/gobject-introspection system dep) and `Pillow` (renders the glyph).

To run it as a background service that starts with your graphical session, use
the shipped **user** systemd unit (it runs `~/.local/bin/mux-indicator`, so it
works with the `pipx` install above):

```sh
mkdir -p ~/.config/systemd/user
cp mux-indicator.service ~/.config/systemd/user/
systemctl --user enable --now mux-indicator
```

Requires: a running StatusNotifierItem host (waybar's tray, or any desktop's)
and `mux` on `PATH` (the daemon polls `mux agent-summary` for state).

The feed is `mux agent-summary` (the aggregate worst state + session count),
polled every `MUX_INDICATOR_POLL` seconds (default 1.5). Overrides via env:
`MUX_BIN` (path to `mux`), `MUX_INDICATOR_BLINK` / `_BLINK_MS` (the cursor blink
on change). Writing `"<state> <count>"` to `/tmp/mux-indicator.ctl` forces a
value for testing; remove the file to revert to the live feed.

## Status

Live. Registers a StatusNotifierItem with the tray watcher, draws an owned
terminal-tile glyph (state = frame colour + tint; a corner badge holds the
count, or a check when idle), reads state from `mux agent-summary`, and blinks
the cursor on a change.

Next, in order: left-click activates `mux next-blocked` -> tooltip + a
per-session menu (right-click). The visual identity lives entirely in
`render.py`; the D-Bus plumbing is in `sni.py`.
