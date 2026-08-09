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
pipx install ./indicator          # from a mux checkout
mux-indicator                      # run it (or wire it into session startup)
```

Dependencies (pulled in automatically): `dbus-next` (pure-Python D-Bus, so no
PyGObject/gobject-introspection system dep) and `Pillow` (renders the glyph).

## Status

**Walking skeleton.** Registers a StatusNotifierItem with the live tray watcher
and shows one static, owned-drawn glyph -- proving the D-Bus + pixmap path.

Next, in order: read mux's state (a machine-readable `mux agent-summary`) ->
the count badge over the glyph -> left-click activates `mux next-blocked` ->
tooltip + a per-session menu. The glyphs in `render.py` are v1 placeholder art
(simple owned shapes); richer owned vector glyphs slot in there without touching
the D-Bus plumbing.
