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

## Clicking an item

Left-click jumps that host to whatever has been waiting longest: `mux
next-blocked`, run locally for your own box and over the same transport for a
latched one. That works because **a tray item exists only when a latch does**,
so a client is attached and you are already looking at it.

**Raising the terminal is not mux's job.** If the window showing that latch is
behind three others or on another workspace, the switch happens invisibly and
the click feels broken, but fixing that means knowing about a compositor, and
mux manages sessions inside terminals with no opinion about where a terminal
sits. So it is a seam, unset by default:

```
indicator-activate   focus-kitty
```

The hook is handed the **label** (the host's short name) as its **one and
only** argument, and runs *after* the switch so the window already shows the
right session when it comes forward. Always one argument, including for your
own box; there is no partition or session in it, and no argument-less form.

That is sufficient because mux already puts the label in the window title.
`share/mux.tmux` sets:

```
set-titles-string '#{@mux-prefix}#S:#W⠀⠀⠀⠀[#{host_short}]'
```

and `host_short` is the **tmux server's** hostname, so a latched session
advertises the *remote's* name in the terminal sitting in front of you. The
samples match `[label]` with the brackets, because the bare name would also
match a session called `northwood` or a path in the title.
Two samples ship in `share/indicator/`, trading different requirements:

- `focus-kitty`: kitty remote control (needs `allow_remote_control`),
  matches on the window title
- `focus-wayfire`: asks the compositor instead, so it is terminal-neutral,
  but needs wayfire's IPC plugin

Both are *samples*: the title match is the part most likely to need changing
for your setup, and every mechanism in them is yours to replace. They follow
the same contract as latch's hooks (0 done, 78 cannot tell) and the
indicator reports a non-zero exit rather than swallowing it, so a
misconfigured hook says so instead of doing nothing.

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
(the daemon polls `mux agent status`). Prefer `pipx`? `pipx
install .` then `./setup.sh service` works too -- both land the command at the
same
`~/.local/bin/mux-indicator` the unit runs.

`setup.sh check` asks three separate questions about the code, not one: does
the package match what is INSTALLED, and does the RUNNING daemon predate what
is installed. A long-lived process is a third copy, and a daemon that was
never restarted after an install passes every presence marker while drawing
last week's icon. `setup.sh service` says which of `RESTARTED`, "starts at the
next login" (no user manager here) and `RESTART FAILED` actually happened --
it used to print the same sentence for all three.

The feed is **`mux agent status`** -- mux's machine contract, which answers
JSON for every partition a human is watching. The tray is a program, so it
reads the surface that promises a stable shape; `mux agent-summary` stays free
to change for whoever reads it in a terminal. Polled every
`MUX_INDICATOR_POLL` seconds (default 5).
Overrides via env: `MUX_BIN` (path to `mux`), `MUX_INDICATOR_BLINK` /
`_BLINK_MS` (the cursor blink on change), `MUX_INDICATOR_TIMEOUT` (per-source
deadline, default 10s). Writing
`"<state> <count>"` to `/tmp/mux-indicator.ctl` forces a value for testing;
remove the file to revert to the live feed.

## Several hosts, one tray

One tray item per host, and **there is nothing to configure**. The set comes
from `mux latch`'s own lock directory: latch to a box and its item appears,
detach and it goes. Nothing to stand up, tear down, or keep in sync, and nothing
to edit per machine.

```
$ mux-indicator
mux-indicator: watching northwood
mux-indicator: + northwood
mux-indicator: northwood = idle None
                                     # ... you run `mux latch northgate`
mux-indicator: watching northgate, northwood
mux-indicator: + northgate
mux-indicator: northgate = working 1
                                     # ... you detach
mux-indicator: - northgate (withdrawn)
```

That works because `mux latch` already writes
`$XDG_RUNTIME_DIR/mux-latch/<target>.lock` at start and removes it via a trap on
every exit path, with the pid on line 1, the target on line 2 and the session
on line 3. A second job for a file that already did it perfectly. A lock whose
process is gone is skipped, so a crashed latch cannot leave a phantom host in
the tray.

**Your own machine is always there**, first, whether or not you are latched
anywhere. It needs no transport and it is what the indicator showed before it
could show anything else.

The local item also sorts **first**: its tray id is `mux--<host>` rather than
`mux-<host>`. Most trays alpha-sort by id with no way to say otherwise, so
position has to be bought in the string, and a leading `-` (0x2D) sorts below
every digit, capital and lowercase letter, so it beats any legal hostname. `_`
does not: it loses to `7bravo` and to anything capitalised. The `mux-` prefix a
bar's `order` array keys on is unaffected.

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

### Several partitions, one host

A host can run more than one mux partition (a separate tmux server, a separate
set of sessions, its own agent state), and each gets **its own tray item**:
`northwood`, or `northwood:global` and `northwood:work`. The colon grammar is
`mux latch`'s own.

**An item means somebody is looking at it.** Remotely that is what a latch
already encodes; locally it is a client attached to that partition's server, so
the poll asks `--attached` and a partition running behind a closed window gets
no item. Detach from everything and the tray empties, which supersedes the
older "the local host is always present" rule -- that was written when a host
had one partition and presence *was* the question.

One query answers for all of them. `mux agent status` returns one JSON object
per partition, so a host with three partitions still costs **one** ssh
connection per poll -- that is the whole
reason the verb exists, since a reader on another machine cannot know the
partition names to ask for in the first place.

**The letter stands in for the cursor.** Each item carries an A-Z letter set
into the bottom-right corner, drawn *over* the badge and blinking on the
cursor's phase -- the `_` is not drawn when a letter is, so there is one
blinking glyph, not two. `global` is the reserved baseline partition and is
always **A**; everything else follows alphabetically. Past Z there is no letter
rather than a second alphabet -- 27 partitions is a different problem, and
drawing `AA` would make it look solved.

It is **chartreuse**, not white, and that was measured rather than picked:
almost every light hue on the tile already means something (state owns amber,
red, green, purple and slate; the mark palette owns cyan, pink, lilac, mint and
salmon; the near-whites are the idle check, the count and the local host's
mark), so the ink is ranked by CIELAB distance from all eighteen and this is
the furthest from any of them while staying bright enough to read at 11px.

It sat *in* the cursor's slot in 0.56 and was too small to read on a live tray.
Being boxed in on three sides capped it at 0.30 of the tile; moving it into the
corner and drawing it after the badge removed the ceiling instead of
negotiating with it, which is the same move the host mark made in 0.47. It is
0.46 of the tile now, and on a multi-host tray it shrinks only as far as the
mark strip requires -- the mark is the host's identity and the letter is drawn
on top of it, so a wide capital is clamped rather than allowed to cover it.

**One partition gets no letter at all**, the same rule as the host mark: a
letter distinguishing a thing from nothing is noise, and the common install
keeps the icon it has always had, byte for byte.

**And the host mark is counted in hosts, not items.** Two partitions on one box
get no mark, because marking them would put the same three letters and the same
colour on both -- they *are* the same machine. With a second host present both
of that host's items wear the *same* mark and the *same* palette slot, or the
tray would be saying there are three machines.

**A click carries the partition**: `mux next-blocked --partition work`. Without
it every item on a host does the same thing -- the far side's login shell
resolves its own default and jumps there, landing on a real session that is not
the one you clicked. The focus hook still gets the **host** as its first
argument (the shipped examples match a terminal title against `[host]`), with
the partition as a second one it may ignore.

**An unreachable host keeps its items.** The partition set lives on the other
machine, so a failed query means "could not ask", never "it has none" --
withdrawing them would empty the tray at the exact moment it has something to
say. They stay and draw `unknown`.

### Which machine is this?

**With one item in the tray**, it wears its host's identity colours: the host's
**background** tints the screen, its **foreground** paints the `>_`. Those come
from `mux host-color`, so the tray and the status bar agree -- one rule, one
owner. The pair exists so fg is legible on bg, so using each half for its actual
purpose gets that legibility for free.

State keeps the **frame** and the **badge**, so the two dimensions never
collide: nothing about a host's colour can make a blocked agent look calm.

**With several items** the tint steps aside and the host mark below becomes the
only host channel. Carrying both would put two independent host colours on one
tile that do not agree with each other -- a salmon mark on a dark green screen
says two different things about one machine -- and the mark is the better
channel, since it survives being small and the letters already name the host.

### Telling hosts apart

With more than one item in the tray, each tile carries a **three-character
mark** reading downward on a black strip at its left edge: `northwood` is `NWD`,
`northgate` is `NGT`, `rover` is `RVR`. It is the first character plus the last
two consonants of the rest, the *tail*, because fleets share prefixes and the
first letters are exactly the ones that do not distinguish.

**Three characters, not four.** A fourth costs 22% of the cap height even with
the letters touching (9px down to 7px at a 32px tile, and 5px at 22px), which
lands back on the unreadable size the overlay exists to escape. Stacking them
two-by-two is the only arrangement where four get *bigger*, and its strip would
be 39px wide on a 32px tile.

**It is an overlay, not a redesign.** The icon underneath is drawn exactly as
it always was, and the mark is composited on top in a fixed order: the icon,
then the strip, then the badge (so the count is never clipped), then the
letters. The strip covers the left border and the `>` chevron outright rather
than trying to fit around them, which is what lets the glyphs be sized to a
third of the tile instead of being squeezed into a column, the difference
between a 13px capital and an unreadable 7px one at a 32px tray size.

Because it only ever *covers*, removing it restores the standard icon exactly.
That is asserted two ways: every no-mark tile is byte-identical to the
pre-overlay renderer, and every pixel to the right of the strip is identical
between a marked and an unmarked tile.

**Colour alone cannot do this job.** mux derives one of eight pairs by hashing,
so with only three machines `northwood` and `northgate` already collide, and a
wider palette does not save you: the birthday paradox beats you long before
the colours run out. The mark is derived from the name alone, so it is stable,
identical on every machine, and needs no configuration.

**One host in the tray gets no mark at all**: the tile is exactly what it has
always been, tint included. The mark appears when a second host joins and goes
when you detach.

### The mark's colour

The local host is always **white**, reserved. Home is the absence of a hue, it
is the one item you never have to look up, and a palette slot would mean the
machine you are sitting at changed colour when you latched somewhere new.

Every remote takes one of **five** (cyan, pink, lilac, mint, salmon) as a
second, redundant hint, so you can pick a tile out before reading its letters.
The palette is small because STATE already owns red, amber, green, purple and
slate blue across the frame and badge: a warm mark reads as `blocked`, a green
one as `idle`. Every slot sits on the black strip and never on the screen, so
contrast is a property of the strip rather than of the hue.

No mark colour belongs to any state, for the reason a state-coloured mark was
rejected outright: it was the most legible option tried, and it made host
identity flicker as the agent worked, which is the one thing identity may not
do.

Slots are **seeded by name, bumped only on collision, and then sticky**:

- **Seeded**, so on a box where your hosts do not collide, every host is the
  same colour on *every* box, with nothing shared and nothing to sync. A purely
  first-come rule would make the colour depend on the order you latched.
- **Bumped**, because a derived rule alone cannot promise distinctness, and
  distinctness is the entire point. The bump is confined to the hosts that
  actually collide, exactly where the derived rule was already broken.
- **Sticky**, recorded in `$XDG_STATE_HOME/mux/indicator-slots`, so latching a
  third host never moves the second one's colour, and a host you unlatch for an
  afternoon comes back the colour you learned. Delete that file to reshuffle.

Past five remotes the palette wraps and two share a hue. That is the right
degradation: colour here is a hint and the letters stay unique.

This deliberately does **not** agree with `mux host-color`. The status bar
carries the host *name* in text beside its chip, so colour there is decoration
and here it is load-bearing; constraining the decorative channel to serve the
load-bearing one is backwards. The two surfaces already share the identifier
that is stable everywhere: the three letters.

**Host colours still matter for the single-host tile**, and two hosts can land
on the same pair. Pin the ones you care about in `$MUX_DIR/hosts`:

```
northwood    fg=colour252,bg=colour236
northgate  fg=colour230,bg=#5f3a1a
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
