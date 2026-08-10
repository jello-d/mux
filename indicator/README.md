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

One command, all userspace (no sudo):

```sh
./install                          # from this directory
```

It builds an isolated environment (a venv, so no system-package or
externally-managed-environment friction), puts the `mux-indicator` command on
`~/.local/bin`, and installs + enables the systemd **user** service so it starts
with your graphical session. It is idempotent -- re-run it any time to update.

Dependencies (`dbus-next`, a pure-Python D-Bus so no PyGObject/gobject-
introspection system dep, and `Pillow`) come from `pyproject.toml` and are
pulled in automatically. Sub-commands:

```sh
./install app         # just the command (no service)
./install service     # just the systemd --user unit
./install check       # verify the install
./install uninstall   # remove the unit + the ~/.local/bin command
```

Requires: `python3`, a systemd **user** manager (for the service), a running
StatusNotifierItem host (waybar's tray, or any desktop's), and `mux` on `PATH`
(the daemon polls `mux agent-summary` for state). Prefer `pipx`? `pipx install
.` then `./install service` works too -- both land the command at the same
`~/.local/bin/mux-indicator` the unit runs.

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
