# mux-desktop-notifier

An **optional** system-tray indicator for mux's agent-session state. It shows,
from anywhere, whether a session is waiting on you: a single aggregate glyph
(a session waiting > a session working > all done) in the notification tray.

It is a StatusNotifierItem (the freedesktop tray standard), so it shows in
waybar's tray and in any desktop's: nothing here is waybar-specific. It reads
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
desktop-notifier-activate   kitty
```

A bare name resolves in `$MUX_SHARE/desktop-notifier/**focus**/`, and your own
copy in `$MUX_DIR/desktop-notifier/focus/` wins over a shipped one of the same
name. **The kind is the directory, so it is not in the value**: a value
containing a `/` is taken as a literal path and never searched for.

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
Six ship in `share/desktop-notifier/focus/`. Pick the one named after what you
run:

| name | reaches | needs |
| --- | --- | --- |
| `kitty` | kitty tabs/splits, any compositor | `--listen-on`, and a `--to` |
| `sway` | sway | `swaymsg`, `SWAYSOCK` |
| `hyprland` | Hyprland | `hyprctl` |
| `niri` | niri | `niri`, and `jq` to read its window list |
| `wayfire` | wayfire | `python3`, and the ipc plugin enabled |
| `wmctrl` | **every X11 window manager**, via EWMH | `wmctrl`, `DISPLAY` |

**`kitty` is narrower than it looks**, and this was measured rather than
assumed: kitty remote control can focus a window *within* an OS window and
has no verb to raise one. Between two kitty OS windows `focus-window` exits 0
and moves nothing. So it suits a setup where your sessions are kitty tabs or
splits, and for one terminal window per machine the compositor's hook is the
one that works. The hook verifies its own outcome, so the unsupported shape
answers 78 rather than reporting success.

It also needs two things where its header used to say one:
`allow_remote_control yes` **and** a listening socket, and only
`--listen-on` on the command line creates one (a `listen_on` line in
kitty.conf produces nothing, measured on 0.45.0). The socket address reaches
the hook as `--to`, because `kitten @` without one looks for a controlling
terminal and a notification daemon has none.

`wmctrl` is the widest per line, because X11 standardised this twenty years
ago: one file reaches i3, bspwm, openbox, awesome, xfwm, Mutter-on-X11 and
KWin-on-X11 without knowing which it is talking to. Every Wayland compositor
needs its own hook because each has its own IPC. Note that on a Wayland
session `DISPLAY` is usually set for XWayland's benefit, so `wmctrl` will run
and will only ever see X11 clients: if your terminal is a native Wayland one,
use the hook named after your compositor.

**GNOME Shell and KDE under Wayland ship no hook**, because neither exposes a
supported window-raise IPC. That is a gap stated rather than papered over with
something that does not work.

**`wayfire` needs `python3`, alone in this directory**, and that is not a
preference: wayfire ships no IPC client, so there is no command to call.
Measured, its eight binaries are `wayfire`, `wayfire-plugin`,
`wayland-logout`, `wcm`, `wf-background`, `wf-dock`, `wf-info` and
`wf-panel`. The protocol is a length-prefixed JSON message over a unix
socket, which is a few lines of stdlib, so the hook speaks it directly
rather than depending on a PyPI package a user may not have.

The matchers take the `[label]` anchor four different ways, which is the
thing to copy carefully if you write your own: escaped for a regex (`sway`,
`hyprland`), literal for a substring match (`wmctrl`), and matched inside the
hook itself where the compositor's focus verb takes a window id rather than a
title (`niri`, `wayfire`).

Each hook's header says what it was **verified against**, because a hook whose
mechanism was read rather than run is a different thing. Four of the six are
now driven against a real compositor by `test/lab` (`kitty`, `sway`,
`wayfire`, and `wmctrl` under Xvfb, which covers every X11 window manager at
once). `hyprland` and `niri` are not: neither can be nested on the machines
this was written on, so they remain read rather than run, and
`test/lab/env/hyprland` records in detail why.

All follow the same contract as latch's hooks
(0 done, 78 cannot tell), and the notifier reports a non-zero exit rather than
swallowing it, so a misconfigured hook says so instead of doing nothing. The
cost of one being wrong is bounded: the click has already switched the session.

## Wording the banner yourself

The toasts ship deliberately plain:

```
Claude finished: api (on northgate)     <- the title
your turn                               <- the body
```

**Styling is the daemon's, not mux's.** mako interprets Pango markup in the
*body* and never in the summary; dunst differs; a macOS presenter will have no
Pango at all. So mux emits text that reads correctly everywhere and offers a
seam to anyone who wants their own, the same line it already draws for a
terminal emulator and a compositor:

```
desktop-notifier-toast   pango
```

A bare name resolves in `$MUX_SHARE/desktop-notifier/**toast**/`, overlaid from
`$MUX_DIR` the same way as the focus hooks, and for the same reason the kind is
the directory rather than part of the value.

The hook is handed `KIND SESSION HOST PARTITION LOCALITY` and prints the
**summary on its first line and the body on every line after it**. One stream,
split once, because where the line break goes *is* the layout and only the
hook knows the daemon it is writing for. mux falls back to its own wording on
every failure there is (no hook, will not start, non-zero, hangs, prints
nothing), so a mistake costs styling and never the notification.

**Two ship, and one question picks between them: can you configure your
daemon's format?**

| name | for | host goes | daemon config |
| --- | --- | --- | --- |
| `pango` | mako, dunst | on the **title row** | one line, required |
| `dim` | swaync, GNOME Shell, plasma, xfce4 | on its **own row** | none |

Leave it unset for a daemon with no markup at all: mux's own wording is
already two correct rows there.

`pango` puts a dim, normal-weight host on the **title row**, with the body
underneath.

```
Claude finished: api (on northgate)     <- bold, then dim and normal weight
your turn
```

It **requires** one line of daemon config. For mako:

```
[app-name="mux"]
format=<big><b>%s</b></big> %b
```

A space where mako's default has `\n`: the break between the title and the
rest then comes from the hook's own newline rather than from the format, which
is what puts the host on the title row and leaves the body its own. That is
also why the hook always prints three lines, the middle one empty when there
is no host to name.

**Requires, rather than pairs with.** Against mako's default
`<b>%s</b>\n%b` that empty line becomes a blank *row*, because Pango does not
collapse one (measured with `pango-view` at Sans 11: 83px against the built-in
wording's 62px, one line taller). Only on the local path, which is the common
one on your own box. So each half is wrong alone, in opposite directions: the
format with no hook puts the whole banner on one row, the hook with no format
adds an empty one.

Which is what `dim` is for. It never emits an empty line, so it needs no
format change, and it spends a whole row on the host rather than the title's
spare width:

```
Claude needs you: api        <- the summary, as your daemon styles it
(on northgate)               <- dim, and only when there is a host
permission or input          <- the body
```

**So the first body line is positional in one hook and not the other**, which
is the one rule a reader will try to harmonise and must not. `pango` always
prints three lines, the middle empty when there is no host, because under a
joining format that first line *is* the title row and a two-line answer would
put the message there. `dim` varies instead: three lines remote, two local,
and never an empty one. Same contract, opposite constraint, which is why there
are two files rather than a flag.

`dim` is not verified against any of the four daemons it is for (none is
installed here). What *is* verified is the shape: the line split is asserted,
and the markup was rendered with `pango-view`, which is the same Pango those
daemons use.

Note the asymmetry inside it, which is the thing most likely to look like a
bug: the **host is escaped and the session is not**. Only the body is parsed,
so an unescaped `&` there makes the daemon refuse the banner and draw nothing,
while escaping the summary would print `a&amp;b` at somebody whose session is
called `a&b`.

## Install

One command, all userspace (no sudo):

```sh
./setup.sh                          # from this directory
```

It builds an isolated environment (a venv, so no system-package or
externally-managed-environment friction), puts the
`mux-desktop-notifier` command on
`~/.local/bin`, and installs + enables the systemd **user** service so it starts
with your graphical session. It is idempotent: re-run it any time to update.

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
install .` then `./setup.sh service` works too: both land the command at the
same
`~/.local/bin/mux-desktop-notifier` the unit runs.

`setup.sh check` asks three separate questions about the code, not one: does
the package match what is INSTALLED, and does the RUNNING daemon predate what
is installed. A long-lived process is a third copy, and a daemon that was
never restarted after an install passes every presence marker while drawing
last week's icon. `setup.sh service` says which of `RESTARTED`, "starts at the
next login" (no user manager here) and `RESTART FAILED` actually happened;
it used to print the same sentence for all three.

The feed is **`mux agent stream`**, mux's machine contract on a loop: one JSON
object per line, emitted only when the answer CHANGES, with the first line
being the current state so a reader is never blank waiting for an event. The
polling therefore happens on the watched box and only changes cross the
network, where the tray used to open a connection to every host every few
seconds.

**A source that cannot stream falls back to a poll.** A remote running a mux
too old to know the verb answers one `{"status":"usage"}` line and exits, which
from the stream alone is indistinguishable from a host that is simply
unreachable. So on a stream that has never once produced a usable answer, the
other channel is asked: `mux agent status` answers for a remote that is merely
old, and neither answers if the box is down. A stream that worked and then
dropped is a disruption and is retried, never downgraded.

**A heartbeat, because silence is ambiguous.** Polling could tell a calm host
from an unreachable one by the exit code; a stream cannot, so it writes one
every `MUX_AGENT_STREAM_HEARTBEAT` seconds and a feed silent past
`MUX_DESKTOP_NOTIFIER_STALE` (45) is UNKNOWN rather than calm. The same write
is how the producer learns its reader has gone, so closing the pipe stops it.

Overrides via env, all optional:

| name | default | what it does |
|------|---------|--------------|
| `MUX_BIN` | `mux` | path to the `mux` to run |
| `MUX_DESKTOP_NOTIFIER_TRAY` | on | draw the tray items at all |
| `MUX_DESKTOP_NOTIFIER_TOASTS` | on | raise desktop notifications |
| `MUX_DESKTOP_NOTIFIER_IGNORE` | the demo | partitions to leave out |
| `MUX_DESKTOP_NOTIFIER_TRANSPORT` | ssh | the remote command template |
| `MUX_DESKTOP_NOTIFIER_ACTIVATE` | unset | hook run after a click |
| `MUX_DESKTOP_NOTIFIER_POLL` | 5 | the fallback poll interval |
| `MUX_DESKTOP_NOTIFIER_TIMEOUT` | 10 | per-source deadline |
| `MUX_DESKTOP_NOTIFIER_STALE` | 45 | a quiet feed becomes unknown |
| `MUX_DESKTOP_NOTIFIER_RESPAWN` / `_MAX` | 2 / 30 | stream restart backoff |
| `MUX_DESKTOP_NOTIFIER_BLINK` / `_MS` | on | the cursor blink on change |
| `MUX_DESKTOP_NOTIFIER_CTL` | unset | a path to force a value, below |

The three config keys (`desktop-notifier-transport`, `-ignore`,
`-activate`) are read from `$MUX_DIR/config`, and the env name always wins.

**Forcing a value for testing** is opt-in: set `MUX_DESKTOP_NOTIFIER_CTL` to a
path and write `"<state> <count>"` into it. Remove the file to revert to the
live feed. It is not a fixed location, because a tray that could be driven by
anything able to create one path is a tray nobody can trust.

## Several hosts, one tray

One tray item per host, and **there is nothing to configure**. The set comes
from `mux latch`'s own lock directory: latch to a box and its item appears,
detach and it goes. Nothing to stand up, tear down, or keep in sync, and nothing
to edit per machine.

```
$ mux-desktop-notifier
mux-desktop-notifier: watching northwood
mux-desktop-notifier: + northwood
mux-desktop-notifier: northwood = idle None
                                     # ... you run `mux latch northgate`
mux-desktop-notifier: watching northgate, northwood
mux-desktop-notifier: + northgate
mux-desktop-notifier: northgate = working 1
                                     # ... you detach
mux-desktop-notifier: - northgate (withdrawn)
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
law: set `desktop-notifier-transport` in `$MUX_DIR/config` (or
`MUX_DESKTOP_NOTIFIER_TRANSPORT`) to anything that carries a command to a host:

```
desktop-notifier-transport   kubectl exec %h: %q
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
older "the local host is always present" rule: that was written when a host
had one partition and presence *was* the question.

One query answers for all of them. `mux agent status` returns one JSON object
per partition, so a host with three partitions still costs **one** ssh
connection per poll: that is the whole
reason the verb exists, since a reader on another machine cannot know the
partition names to ask for in the first place.

**The letter stands in for the cursor.** Each item carries an A-Z letter set
into the bottom-right corner, drawn *over* the badge and blinking on the
cursor's phase: the `_` is not drawn when a letter is, so there is one
blinking glyph, not two. `global` is the reserved baseline partition and is
always **A**; everything else follows alphabetically. Past Z there is no letter
rather than a second alphabet: 27 partitions is a different problem, and
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
mark strip requires: the mark is the host's identity and the letter is drawn
on top of it, so a wide capital is clamped rather than allowed to cover it.

**One partition gets no letter at all**, the same rule as the host mark: a
letter distinguishing a thing from nothing is noise, and the common install
keeps the icon it has always had, byte for byte.

**And the host mark is counted in hosts, not items.** Two partitions on one box
get no mark, because marking them would put the same three letters and the same
colour on both: they *are* the same machine. With a second host present both
of that host's items wear the *same* mark and the *same* palette slot, or the
tray would be saying there are three machines.

**A click carries the partition**: `mux next-blocked --partition work`. Without
it every item on a host does the same thing: the far side's login shell
resolves its own default and jumps there, landing on a real session that is not
the one you clicked. The focus hook still gets the **host** as its first
argument (the shipped examples match a terminal title against `[host]`), with
the partition as a second one it may ignore.

**An unreachable host keeps its items.** The partition set lives on the other
machine, so a failed query means "could not ask", never "it has none":
withdrawing them would empty the tray at the exact moment it has something to
say. They stay and draw `unknown`.

### Which machine is this?

**With one item in the tray**, it wears its host's identity colours: the host's
**background** tints the screen, its **foreground** paints the `>_`. Those come
from `mux host-color`, so the tray and the status bar agree: one rule, one
owner. The pair exists so fg is legible on bg, so using each half for its actual
purpose gets that legibility for free.

State keeps the **frame** and the **badge**, so the two dimensions never
collide: nothing about a host's colour can make a blocked agent look calm.

**With several items** the tint steps aside and the host mark below becomes the
only host channel. Carrying both would put two independent host colours on one
tile that do not agree with each other (a salmon mark on a dark green screen
says two different things about one machine), and the mark is the better
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
- **Sticky**, recorded in `$XDG_STATE_HOME/mux/desktop-notifier-slots`,
  so latching a
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
(it is designed to be shareable: everything machine-local lives in `MUX_CACHE`
and `MUX_STATE`).

If `mux host-color` refuses (colours 0-15 have no fixed hex, since every theme
remaps them), the item draws host-neutral rather than guessing.

**Quote the remote command as one argument.** `ssh` concatenates its remaining
arguments into a single string and the remote shell re-splits it, so
`ssh host sh -lc "mux agent stream"` arrives as `sh -lc mux` with `agent` as
`$0`, which runs mux's bare session picker. It fails by
doing something plausible rather than erroring, so it is worth getting right
once. The nested form above is correct. `sh -lc` is needed because sshd runs a
remote command without a login shell, so `~/.local/bin` is not on `PATH`.

**An unreachable host reads as `unknown`, never as calm.** A quiet host is an
ANSWER: the stream says so and keeps beating, so silence is the transport
rather than the news. A source that fails, goes quiet past its deadline, or
answers something mux would never emit gets its own slate-blue glyph with a `?`
badge: visually distinct from `none` (agentless) and from `idle`, because
drawing either of those would assert the one thing we do not know.

## Status

Live. Registers a StatusNotifierItem with the tray watcher, draws an owned
terminal-tile glyph (state = frame colour + tint; a corner badge holds the
count, or a check when idle), reads state from `mux agent stream`, and blinks
the cursor on a change.

It owns every desktop surface now, not just the tray: the toasts come from here
too. That is what makes a LATCHED session notify the right machine, which was
structurally impossible while the agent's own hook raised the banner on the box
the agent runs on. One owner, so the two cannot drift.

Multi-host is live: N items from one process (a D-Bus connection each, which is
required. `RegisterStatusNotifierItem` takes only a service name, so two names
on one connection resolve to the same object and you get the same item twice).
Verified against a live waybar.

Left-click activating `mux next-blocked` is live (see **Clicking an item**).
Next: a per-session menu on right-click.

## Where the platform lives

One file. `backend_dbus.py` is the only module that imports `dbus_next`;
everything else runs on a machine with no bus at all. That is enforced by the
tests rather than asserted here: with `dbus_next` hidden, 293 tests run, 10
skip and none fail, and the 10 are the StatusNotifierItem wire surface.

    render.py    every pixel, on every platform. `tile()` returns a Pillow
                 image; `icon_pixmap()` packs the same pixels into SNI's ARGB
    sources.py   discovery, transports, the latch locks, the `%p` grammar
    slots.py     the sticky per-host colour slots
    sni.py       which items should exist, and what each should show
                 (`Tile`), plus the supervisor that keeps the set live
    backend_*.py the presenter

A presenter owes exactly three things, and `sni._backend()` is the only place
one is named:

    session_bus()                        -> a connection, or whatever the
                                            platform's toaster needs
    toaster(bus, enabled)                -> .announce / .withdraw / .sync
    export(index, tile, activate)        -> handle, with .close()

`export` wires the tile's two callbacks (`on_icon`, `on_status`) to whatever
tells the desktop to repaint, and `close()` withdraws the item. On D-Bus a
withdrawal IS a disconnect, because the SNI spec has no unregister; another
platform will mean something else by it, which is why the supervisor only ever
calls `close()`.

### A macOS presenter, and the two things that need a Mac to settle

The shared half above is already portable and `pip install` resolves there
(`dbus-next` carries a `sys_platform == 'linux'` marker). What is missing is a
`backend_appkit.py` implementing those three functions over
`NSStatusItem` plus `UNUserNotificationCenter`, a launchd agent in place of
the systemd unit, and PyObjC as a macOS-only dependency.

Two questions cannot be answered honestly without the hardware, so they are
written down rather than guessed:

- **The run loop.** AppKit wants the main thread and its own loop; this daemon
  is asyncio. Whether they can be made to coexist (an `NSRunLoop` pumped from
  a task, or asyncio driven from a CFRunLoop observer) decides the shape of
  the whole backend.
- **Withdrawal.** `Toaster` keeps an id per banner so a finished turn closes
  the one it raised, which is four rules' worth of behaviour.
  `osascript -e 'display notification'` returns no id at all, and
  `UNUserNotificationCenter` generally wants a signed bundle. That has to be
  designed, not ported.
