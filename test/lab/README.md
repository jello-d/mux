# The hook lab

Real compositors and a real notification daemon, driving the hooks under
`share/desktop-notifier/` end to end. It exists because the unit suite can
only prove the **argv** a hook composes and the **lines** it prints: whether
the compositor accepts that syntax, and whether the daemon renders those
lines as the intended rows, are facts about somebody else's software.

Four of the six focus hooks shipped with their headers saying *not verified
against a running compositor*. This is how that sentence gets retired, one
environment at a time.

## Not part of `test/run`

`test/run` globs `test/*.t`, so nothing in `test/lab/` is picked up by it.
The relationship is the one `test/mutate` already has with the suite: a cheap
continuous check, and an expensive explicit one.

```sh
sh test/lab/lab list              # what this box can run, and what it cannot
sh test/lab/lab run               # every available environment
sh test/lab/lab run sway x11      # named ones
sh test/lab/lab shots             # keep the screenshots for a human to look at
```

`test/mux-hook-lab.t` runs the subset that needs nothing installed beyond
what is already here, and SKIPS loudly otherwise, so the suite and CI get
some of the value without the matrix.

## Two layers, and the seam between them

An **environment** knows how to bring a display up and answer questions about
it. A **probe** knows what a hook is supposed to do. Neither knows the other,
which is what lets one probe assert six compositors.

`test/lab/env/<name>` is an executable answering these verbs. Every one is
also the contract a new environment has to satisfy, so adding niri means
writing this file and nothing else:

| verb | answers |
| --- | --- |
| `deps` | `tool package` per line: everything it needs, and where from |
| `available` | exit 0 if this box can run it; a reason on stderr if not |
| `hooks` | which hooks it can exercise, one per line |
| `probes` | which probes it hosts (`focus`, `toast`) |
| `up DIR` | start it, write `DIR/env` as `KEY=VALUE` lines a client needs |
| `window TITLE` | open a window carrying TITLE, and wait for it to appear |
| `focus TITLE` | force focus elsewhere, so a probe starts from the wrong one |
| `focused` | print the focused window's title |
| `shot FILE` | screenshot, or exit 78 if it cannot |
| `down` | tear down, leaving nothing behind |
| `kind` | `wayland` or `x11`, which is all a probe needs to know |

**`available` is DERIVED from `deps`**, through `avail_lib`, so "what this
needs" is written once. That single table is also what `lab deps` aggregates
for the provisioner, which is the reason it exists: a package list typed
twice is one that goes stale against the thing it provisions.

**`probes` is a declaration and not an inference.** The toast probe counts
rows of ink in a screenshot, so any other window with text in it is counted
too: run on `env/kitty`, whose clients draw a prompt, four of eight
assertions failed for a reason that had nothing to do with the daemon. It
tests the *daemon*, so one environment hosts it.

**Not every environment here has been run.** `env/hyprland` and
`daemon/dunst` were written from documentation because `lab deps` is what
asks the provisioner to install them, so they exist before the packages do.
Each says so in its own header, `available` reports them missing with their
apt name, and the first run afterwards is the verification. A hook whose
mechanism was read rather than exercised is a different thing, and turning
the first into the second is what this directory is for.

`78` means **cannot answer**, the same three-answer contract the hooks
themselves use, so an environment that is present but cannot screenshot is
distinguishable from one that failed.

## Headless beats a VM wherever it can

Measured first, and it decided the whole shape: `WLR_BACKENDS=headless` sway
comes up on this host in under a second with the live session untouched. So
sway, wayfire and Hyprland need **no VM at all**, and neither does X11
(`Xvfb`). A VM is reserved for what genuinely cannot nest: a compositor this
distribution does not package, and the desktops whose notification daemon is
part of a whole session.

That is not a small difference in cost. A nested compositor is a second of
setup and no disk; a VM is a minute and a gigabyte. Being able to run the
focus matrix in seconds is what makes it something you run while editing a
hook rather than before a release.

## A client must be launched BY the compositor

The first thing that went wrong, and the reason `window` is a verb rather
than something a probe does itself: a headless sway creates its **own**
`WAYLAND_DISPLAY` and does not take the one you pass it, so a terminal
started from outside reports `failed to connect to wayland; no compositor
running?`. Every environment launches its clients through its own IPC
(`swaymsg exec`, and the equivalents), which is also how a real session does
it.

## The live session is never touched

Every environment runs with `WAYLAND_DISPLAY` and the compositor's own socket
variable **unset**, its state under a scratch directory, and its own socket
name. This repo has broken that rule in a hand probe three times (`$TMUX`
into a scratch server, `MUX_DIR` beating a `HOME` pin, and scratch servers
pruning the real agent state), so it is the harness's job rather than the
caller's discipline.
