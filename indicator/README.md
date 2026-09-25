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

One tray item per host, and **there is nothing to configure**. The set comes
from `mux latch`'s own lock directory: latch to a box and its item appears,
detach and it goes. Nothing to stand up, tear down, or keep in sync, and nothing
to edit per machine.

```
$ mux-indicator
mux-indicator: watching manifold
mux-indicator: + manifold
mux-indicator: manifold = idle None
                                     # ... you run `mux latch manifestor`
mux-indicator: watching manifestor, manifold
mux-indicator: + manifestor
mux-indicator: manifestor = working 1
                                     # ... you detach
mux-indicator: - manifestor (latch ended)
```

That works because `mux latch` already writes
`$XDG_RUNTIME_DIR/mux-latch/<target>.lock` at start and removes it via a trap on
every exit path, with the pid on line 1 and the target on line 2. A second job
for a file that already did it perfectly. A lock whose process is gone is
skipped, so a crashed latch cannot leave a phantom host in the tray.

**Your own machine is always there**, first, whether or not you are latched
anywhere. It needs no transport and it is what the indicator showed before it
could show anything else.

The remote command is composed from a template, so ssh is a default and not a
law -- set `indicator-transport` in `$MUX_DIR/config` (or
`MUX_INDICATOR_TRANSPORT`) to anything that carries a command to a host:

```
indicator-transport   kubectl exec %h -- %q
```

`%h` is the host and `%q` the remote command as **one** argument. That matters:
ssh concatenates its remaining arguments and the remote shell re-splits them, so
passing the words through made the far side run mux's bare session picker. The
default also uses `sh -lc`, because sshd runs a remote command *without* a login
shell and `~/.local/bin` is then not on `PATH`; and `BatchMode=yes`, because a
tray daemon can never answer a prompt.

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

### Telling hosts apart

With more than one item in the tray, each tile carries a **three-character
mark** reading downward on a black strip at its left edge, in cyan: `manifold`
is `MLD`, `manifestor` is `MTR`, `rover` is `RVR`. It is the first character
plus the last two consonants of the rest — the *tail*, because fleets share
prefixes and the first letters are exactly the ones that do not distinguish.

**It is an overlay, not a redesign.** The icon underneath is drawn exactly as
it always was, and the mark is composited on top in a fixed order: the icon,
then the strip, then the badge (so the count is never clipped), then the
letters. The strip covers the left border and the `>` chevron outright rather
than trying to fit around them — which is what lets the glyphs be sized to a
third of the tile instead of being squeezed into a column, the difference
between a 13px capital and an unreadable 7px one at a 32px tray size.

Because it only ever *covers*, removing it restores the standard icon exactly.
That is asserted two ways: every no-mark tile is byte-identical to the
pre-overlay renderer, and every pixel to the right of the strip is identical
between a marked and an unmarked tile.

**Colour alone cannot do this job.** mux derives one of eight pairs by hashing,
so with only three machines `manifold` and `manifestor` already collide, and a
wider palette does not save you — the birthday paradox beats you long before
the colours run out. The mark is derived from the name alone, so it is stable,
identical on every machine, and needs no configuration.

The cyan is fixed and belongs to no state. A state-coloured mark was tried and
rejected: it was the most legible option of all, and it made host identity
flicker as the agent worked, which is the one thing identity may not do.

**One host in the tray gets no mark at all** — the tile is exactly what it has
always been. The mark appears when a second host joins and goes when you
detach. It is drawn straight over the `>_`, which shows through; a fragment of
the prompt is enough of a cue, and that is what lets the letters keep their
full size instead of being squeezed into a column of their own.

**Colours still help**, and two hosts can still land on the same pair. Pin the
ones you care about in `$MUX_DIR/hosts`:

```
manifold    fg=colour252,bg=colour236
manifestor  fg=colour230,bg=#5f3a1a
```

`$MUX_DIR/hosts` is per-machine, so a host pinned on one box and derived on
another gets two different colours. If you rely on the colours, share `$MUX_DIR`
(it is designed to be shareable -- everything machine-local lives in `MUX_CACHE`
and `MUX_STATE`).

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
