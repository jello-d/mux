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
./setup.sh                          # from this directory
```

It builds an isolated environment (a venv, so no system-package or
externally-managed-environment friction), puts the `mux-indicator` command on
`~/.local/bin`, and installs + enables the systemd **user** service so it starts
with your graphical session. It is idempotent -- re-run it any time to update.

Dependencies (`dbus-next`, a pure-Python D-Bus so no PyGObject/gobject-
introspection system dep, and `Pillow`) come from `pyproject.toml` and are
pulled in automatically. Sub-commands:

```sh
./setup.sh app         # just the command (no service)
./setup.sh service     # just the systemd --user unit
./setup.sh check       # verify the install
./setup.sh uninstall   # remove the unit + the ~/.local/bin command
```

Requires: `python3`, a systemd **user** manager (for the service), a running
StatusNotifierItem host (waybar's tray, or any desktop's), and `mux` on `PATH`
(the daemon polls `mux agent-summary` for state). Prefer `pipx`? `pipx install
.` then `./setup.sh service` works too -- both land the command at the same
`~/.local/bin/mux-indicator` the unit runs.

The feed is `mux agent-summary` (the aggregate worst state + session count),
polled every `MUX_INDICATOR_POLL` seconds (default 5). Overrides via env:
`MUX_BIN` (path to `mux`), `MUX_INDICATOR_BLINK` / `_BLINK_MS` (the cursor blink
on change), `MUX_INDICATOR_TIMEOUT` (per-source deadline, default 10s). Writing
`"<state> <count>"` to `/tmp/mux-indicator.ctl` forces a value for testing;
remove the file to revert to the live feed.

## Several hosts, one tray

One tray item per SOURCE, and a source is a **command**, not a host -- the same
seam shape as mux's `context-command`. So it works over ssh, a jump host,
`kubectl exec`, anything; the indicator never learns what ssh is. The box you
are sitting at **pulls**; nothing is pushed to it.

List them in `$MUX_DIR/indicator-sources` (or point `MUX_INDICATOR_SOURCES` at a
file), one `LABEL COMMAND...` per line:

```sh
# LABEL       COMMAND...
manifold      mux agent-summary
manifestor    ssh manifestor "sh -lc \"mux agent-summary\""
```

With no file you get one source for this machine, which is what the indicator
always did -- it just gains a name.

The LABEL does three jobs: it names the host in the tooltip (`mux @ manifold`),
it becomes the tray id `mux-<label>` (so a bar can order items, and the id is
self-describing in the D-Bus name list), and it keys `mux host-color` so a
remote host is drawn in the same colour as its status-bar chip.

### Which machine is this?

Each item wears its host's identity colours: the host's **background** tints the
screen, its **foreground** paints the `>_`. Those come from `mux host-color`, so
the tray and the status bar agree -- one rule, one owner. The pair exists so fg
is legible on bg, so using each half for its actual purpose gets that legibility
for free.

State keeps the **frame** and the **badge**, so the two dimensions never
collide: nothing about a host's colour can make a blocked agent look calm.

The lookup runs **locally**, even for a remote host: the colour derives from the
NAME by hashing, so this box can colour a remote host with nothing shared. That
matters most when the host is unreachable: the `unknown` glyph still has to
say *which* host it cannot see.

**Two hosts can land on the same colour.** mux derives one of eight pairs by
name, which is plenty for a status-bar chip (the name is written right there in
text) but thin for a tray icon, where colour is the only cue. Pin the ones you
care about in `$MUX_DIR/hosts`:

```
manifold    fg=colour252,bg=colour236
manifestor  fg=colour230,bg=#5f3a1a
```

That file is per-machine, so a host pinned on one box and derived on another
gets two different colours. If you rely on the colours, share `$MUX_DIR` (it is
designed to be shareable -- everything machine-local lives in `MUX_CACHE` and
`MUX_STATE`).

If `mux host-color` refuses -- colours 0-15 have no fixed hex, since every theme
remaps them -- the item draws host-neutral rather than guessing.

**Quote the remote command as one argument.** `ssh` concatenates its remaining
arguments into a single string and the remote shell re-splits it, so
`ssh host sh -lc "mux agent-summary"` arrives as `sh -lc mux` with
`agent-summary` as `$0` -- which runs mux's bare session picker. It fails by
doing something plausible rather than erroring, so it is worth getting right
once. The nested form above is correct. `sh -lc` is needed because sshd runs a
remote command without a login shell, so `~/.local/bin` is not on `PATH`.

**An unreachable host reads as `unknown`, never as calm.** `mux agent-summary`
exits 0 and prints `none 0` on a quiet host, so empty *is* an answer and a
non-zero exit can only be the transport. A source that fails, times out, or
answers something mux would never emit gets its own slate-blue glyph with a `?`
badge -- visually distinct from `none` (agentless) and from `idle`, because
drawing either of those would assert the one thing we do not know.

## Status

Live. Registers a StatusNotifierItem with the tray watcher, draws an owned
terminal-tile glyph (state = frame colour + tint; a corner badge holds the
count, or a check when idle), reads state from `mux agent-summary`, and blinks
the cursor on a change.

Multi-host is live: N items from one process (a D-Bus connection each, which is
required -- `RegisterStatusNotifierItem` takes only a service name, so two names
on one connection resolve to the same object and you get the same item twice).
Verified against a live waybar.

Next, in order: left-click activates `mux next-blocked`, then a per-session menu
(right-click). The visual identity lives entirely in `render.py`; the D-Bus
plumbing is in `sni.py`; the source list is in `sources.py`.
