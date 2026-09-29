# mux

**A tmux session manager for agent-heavy, many-session work.**

You run several coding agents at once, one per project, each in its own tmux
session. They spend much of their time *working*, then *block*, waiting for you
to answer a prompt or approve a step. The hard part is not running them; it is
knowing **which one needs you, and jumping straight to it**, without hunting
through a wall of look-alike sessions.

## What mux is for

**Every session comes up the same way.** A session's identity and appearance
(working directory, theme, agent, pane arrangement) live in one small
declarative profile that names a *layout*. `mux go api` builds or attaches `api`
identically every time, on either machine, and with no profile at all you still
get a working session. Projects are discovered rather than registered, themes
are data, and partitions keep one boundary's sessions from seeing another's.
The point is that nothing drifts: the session you come back to is the session
you left.

**You can see which agent needs you, and go there in one key.** Every session
wears a glyph for its agent: idle, working, or blocked. `prefix b` jumps to
whichever has been blocked longest, and repeating walks down the urgency order.
The states come from the agent's own lifecycle hooks, which `mux setup claude`
wires for you; a session mux started an agent in and has never heard from wears
`🔌`, so an unwired install says so instead of looking calm.

**Higher layers get a contract, not a screen to scrape.** `mux agent` is a
machine surface: one JSON object on stdout, always, including on failure.
`peers` says who is here and what each is doing, `read` captures a pane, `wait`
blocks until a session reaches a state, and `send` hands work to another agent
under a root-owned policy the agent itself cannot edit. mux ships the
instructions for using it (`mux skill`, and the same text as `AGENTS.md`), so an
orchestrator above mux does not have to reverse-engineer a status bar. mux stays
serverless and leaves orchestration to that layer.

**Remote sessions survive the network.** `mux latch HOST[:PARTITION] [SESSION]`
holds an attachment to another machine's mux open across drops, and **brings
your own transport**: mux owns the state machine and the attach semantics while
ssh, mosh or anything else supplies the pipe. It tells a wait apart from a dead
end, repairs the terminal when a session dies under it, and never carries a
keystroke.

**One tray for every box you are attached to.** An optional StatusNotifier icon
shows one item per (host, partition) with its worst agent state and a count,
following your latches: attach to a box and its item appears. The machine you
are sitting at PULLS, so nothing is pushed to it and every platform-specific
decision stays local. Clicking an item jumps that box to whoever needs you.

It is POSIX shell over tmux. No daemon, no runtime dependencies beyond tmux
itself (`fzf` optional, for a nicer session picker; the tray is a separate
optional Python package).

---

## Contents

- [What mux is for](#what-mux-is-for)
- [The status bar](#the-status-bar)
- [Requirements](#requirements)
- [Install](#install)
  - [Homebrew (macOS and Linux)](#homebrew-macos-and-linux)
- [Quickstart](#quickstart)
- [Concepts](#concepts)
  - [Sessions: go and go --resume](#sessions-go-and-go---resume)
  - [Profiles and layouts](#profiles-and-layouts)
  - [Agents](#agents)
  - [Themes](#themes)
  - [Contexts and partitions](#contexts-and-partitions)
  - [Views and tension](#views-and-tension)
  - [Remote sessions: latch](#remote-sessions-latch)
  - [The agent contract: mux agent](#the-agent-contract-mux-agent)
  - [The tray](#the-tray)
- [Commands](#commands)
- [Key bindings](#key-bindings)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Extending](#extending)
- [Reference](#reference)
- [Status and license](#status-and-license)

---

## The status bar

The whole point is the bar. A sketch of what you see (colour omitted):

```
┌ status-left ─────────────┐          ┌────────── status-right ────────────┐
│ [[WORK: api]]  host  api ▸│ 1:code 2:…│ ⚠ api · 🧠 web · ✓ docs · ⚫ notes│✱│
└──────────────────────────┘          └────────────────────────────────────┘
      context banner  host   current    per-session agent-state strip    view
      (optional)      chip    session                                    state
```

- **status-left** — an optional **context banner** (e.g. a work marker), a
  per-**host** colour chip so identically-named sessions on different machines
  are told apart, then the current session name.
- **status-right** — one token per session, in cycle order, each with an
  agent-state glyph: `⚠` needs you, `🧠` working, `✓` just finished, `⚫` no
  agent, and `🔌` an agent mux started that has never reported: its hooks are
  not wired, which `mux setup <agent>` fixes. The session that has needed you
  **longest** is the loudest; `prefix b` jumps there.
- **the right edge** — one glyph for [view tension](#views-and-tension), always
  present: `✱` auto, `┻` floor, `┳` ceil. Shape is the mode you chose; colour is
  what is happening to *this* view.

The strip is measured against the bar's width and **degrades in tiers** rather
than letting tmux truncate it — it drops the age, folds agentless sessions into
a `·N·` cluster, then windows around the current session with edge counts. A
session that needs you is never silently dropped.

The text is the signal; colour is decoration.

## Requirements

- **tmux** (3.x) and a POSIX shell (`dash` is fine — mux uses no bash-isms).
- Optional: **fzf** for the fuzzy session picker (`mux` with no arguments falls
  back to a numbered menu without it).
- Optional: a coding agent CLI (e.g. Claude Code) to actually run in the agent
  panes, with its lifecycle hooks wired to mux for the state strip. **`mux setup
  claude` does that for you**, idempotently and reversibly, and installs the
  agent instructions at the same time. The hooks call `mux agent-hook
  <EventName>` and say only what HAPPENED: mux decides what each event means, so
  a rule change is a mux release rather than a coordinated one.

## Install

mux is a single entry point (`bin/mux`) that self-locates its helpers
(`libexec/`) and data (`share/`) as siblings under one prefix — the
standard package layout. Clone it and let `setup.sh` wire it into `~/.local`:

```sh
git clone https://github.com/jello-d/mux ~/.mux
~/.mux/setup.sh install    # links mux into ~/.local (bin, libexec, share, man)
```

Then source the tmux integration from your `~/.config/tmux/tmux.conf` (or
`~/.tmux.conf`):

```tmux
source-file ~/.local/share/mux/mux.tmux           # required
source-file ~/.local/share/mux/mux-opinions.tmux  # optional ergonomics
```

`mux.tmux` reaches mux only as `mux <verb>`, so it carries no paths; it just
needs `mux` on `PATH`. `mux-opinions.tmux` adds mouse, scroll-routing, and
navigation defaults you can skip if you have your own.

`setup.sh` installs the man page under `~/.local/share/man`, on the default
`MANPATH`, so `man mux` works.

### Homebrew (macOS and Linux)

This repository is its own tap, so there is no separate formula repo to keep in
step with it. Only the one-argument form of `brew tap` requires a repository
named `homebrew-<name>`; the two-argument form takes the URL instead, which
costs one extra argument exactly once:

```sh
brew tap jello-d/mux https://github.com/jello-d/mux
brew install mux
```

After that, `brew upgrade mux` as usual, or `brew install --HEAD mux` to track
the tip instead of the latest tag. Homebrew puts the tree under the formula's
`libexec`, links `mux` onto `PATH`, and links the man page, so `man mux` works.

Two things differ from the clone install above, both because brew installs by
copying and so never runs `setup.sh`:

- **The `source-file` path is your Homebrew prefix's**, which varies by
  platform (`/opt/homebrew`, `/usr/local`, `/home/linuxbrew/.linuxbrew`), and
  tmux.conf does not expand shell commands. The formula prints the exact line
  for your machine on install; `brew info mux` shows it again.
- **Run `mux reload` after an upgrade.** A tmux server that is already running
  still has the bindings and hooks it read at start, and nothing in a brew
  upgrade refreshes it. (`setup.sh install` does this for you; brew cannot,
  because it never runs it.)

## Quickstart

Nothing wired yet and want to see what the fuss is about? `mux demo` builds a
throwaway mux on its own tmux server, with four pretend agents cycling through
states, and tears itself down with `mux demo --stop`. It needs no agent, no
hooks and no configuration, and it cannot touch your real sessions: its own
server means its own agent-state namespace.

```sh
mux demo          # look at the strip, press prefix b, then: mux demo --stop
```

Then, for real:

```sh
# 1. wire your agent up, so the strip has something to report. Shows the change
#    first; --remove takes it back out; running it twice changes nothing.
mux setup claude --dry-run
mux setup claude

# 2. open (or attach) a session for the current project, agent continuing
mux go

# write a profile for a project, then bring it up
mux new api - ~/src/api      # name=api, default colour, root=~/src/api
mux go api

# the essentials, from inside tmux (default prefix, adjust to yours):
#   prefix b     jump to the agent that has waited longest
#   prefix B     jump back
#   prefix ( )   cycle to the prev / next session (skips hidden)
#   prefix Space explorer (choose-tree)

# is it all wired? `mux check` asks functional questions, not presence ones,
# and names any session whose agent has never reported.
mux check
```

Without step 1 the strip draws `🔌` for every session mux started an agent in:
the panes are right and nothing is reporting. That is the one first-run failure
worth knowing about, which is why the glyph exists rather than leaving those
sessions looking like plain shells.

## Concepts

### Sessions: go and go --resume

A **session** is a running tmux session. mux builds it from a **profile** of
the same name if there is one, and from its own defaults if there is not. Two
build verbs differ only in how the agent pane starts:

- `mux go [NAME] [PROFILE]` — the agent **continues** its most recent
  conversation.
- `mux go --resume [NAME]` — the agent **resumes**, prompting you to pick a
  conversation. (This was once the bare verb `mux resume`; that name now
  belongs to the session rebuild below.)

If the session is already up, both just attach or switch to it (idempotent —
they never clobber a live session). `--no-agent` builds the same panes but a
plain shell runs in the agent pane instead.

### Profiles and layouts

Two files, two jobs, and a directive in the wrong one fails loud rather than
half-working.

A **profile** is the session: who it is and how it looks. It lives at
`$MUX_DIR/<name>.profile`, and the filename is the session name. Every
directive is optional.

| directive | meaning |
| --- | --- |
| `root DIR` | working dir for every pane (`~` expands) |
| `theme NAME` | the colour theme |
| `agent NAME` | which agent a `pane agent` runs |
| `notify always\|away` | when the agent notification fires |
| `layout NAME` | the pane arrangement to build (default: `default`) |

The agent notification fires when an agent stops needing the CPU and starts
needing *you* — a real transition out of `working`, and only when you are not
already looking at that pane (`notify always` overrides the second half). It is
raised at **normal** urgency, never `critical`: critical means "never expire"
to mako and dunst alike, which left every "needs you" banner sitting there
after the prompt it announced was long answered. mux clears its own banner when
the state passes, using the freedesktop `CloseNotification` call rather than
any one daemon's CLI, so it cleans up under X11 and Wayland alike.

A **layout** is the pane arrangement, and only that: `layouts/<name>.layout`,
in your config or shipped in `$MUX_SHARE`. Two ship: `default` (yours | the
agent, over a scratch shell) and `logs` (the same, plus a second window for
something long-running). A session opens focused on the **agent** pane.

| directive | meaning |
| --- | --- |
| `window NAME` | start a new window (the first opens the session) |
| `pane CMD` | a pane running `CMD` (`pane agent` = the agent; bare = a shell) |
| `bottom N\|MIN-MAX` | a full-width bottom shell, bounded height |

So a real profile is three lines, or fewer:

```
# ~/.config/mux/api.profile
theme   orange
root    ~/src/api
layout  default          # optional; this is already the default
```

Both are parsed and validated in full **before** any tmux call, so a malformed
pair builds nothing.

Every package-data read follows one rule: your config (`$MUX_DIR`) first, then
the shipped defaults (`$MUX_SHARE`). So `layout default` finds the packaged
arrangement, while a layout, theme, or agent you drop in `$MUX_DIR` under a
shipped name overrides it. Writes (`mux new`, `mux save`, `mux theme -p`)
always land in `$MUX_DIR`. `mux new` and `mux save` write these for you.

**A profile is a deviation, not a requirement.** With no profile at all, `mux
go` roots the session at the project you are standing in, builds the shipped
`default` layout, and takes a theme derived from the name. You only write one
when you want something *other* than that, which is why most projects need none.

Most deviations are a single line, so they live in a table rather than a file
each, `$MUX_DIR/profiles`:

```
# NAME      key=value ...
api         theme=cyan
kg          root=~/src/PlatformOS/apps/knowledge-store
dashboard   layout=logs
```

Same keys as the file form, so the two say the same things. `mux edit NAME`
opens the row as a readable multi-line draft and folds it back into a line on
save. If the draft comes back with a **comment** in it — or a value containing a
space, the other thing a line cannot hold — the entry is promoted to
`$MUX_DIR/profiles.d/<name>.profile` instead and the row is dropped, so the
breakout happens exactly when you need it and never on a rule you have to
remember. A draft that will not parse is kept and named rather than discarded;
`mux edit` on the same name resumes it, and `mux check` lists any you forgot.

### Discovery

`mux go <name>` reaches a project you have never configured and never have to
`cd` to first, because mux keeps a **map** of the repositories under your source
roots. Declare them with `scan PATH [DEPTH]` in the partition (or context) file
— repeatable, and there is no built-in root, so a partition nobody configured
gets no map rather than quietly indexing someone else's tree:

```
scan   ~/src 3
scan   ~/work 2
ignore */vendor/*
ignore node_modules
```

`ignore PATTERN` prunes discovery, which is how two repos sharing a basename
stop being ambiguous without renaming either. A pattern **with a slash** globs
the whole absolute path; one **without** matches a single path component, so
`ignore node_modules` means the obvious thing. It follows `scan`'s multiplicity
rule exactly: repeatable within a file, and a file that sets it *replaces* the
inherited list rather than extending it, so a context can drop what its
partition ignores.

It governs only what mux **volunteers**. An explicit
`mux go ~/some/ignored/repo` still works, because a path you typed is
evidence. And a pattern that matches nothing is reported by `mux scan` — a
filter that silently does nothing looks exactly like one that works.

The map is a cache, not config: it holds only derived facts, it is rewritten
wholesale, and deleting it loses nothing. It rebuilds on exactly three triggers
and never on a timer — `mux scan`, first use, and a lookup miss (or a hit whose
directory has since vanished). Between the last two it self-corrects whether a
project appeared, moved, or went away.

A session is addressable **by name or by root**:

```sh
mux go api            # the short name, most of the time
mux go ~/src/api      # the root, which is equally a public address
mux go .              # here
```

Anything with a slash is a path, since a session name never contains one. A
path is *evidence*, so it never reaches the unknown-name refusal below — and an
exact-root claim wins over climbing to the git toplevel, so a subdirectory
session resolves to itself rather than to its enclosing repo. That is what lets
`mux resume` replay a command anyone could type instead of reaching into
mux's internals.

`mux go` resolves a NAME in this order: a live session, a breakout profile, a
table row, the map, and then **nothing** — at which point it refuses:

```
$ mux go tackp
mux: nothing known as 'tackp'
mux:   did you mean:      tackup
mux:   or create it here:  mux new tackp
```

That refusal is the one piece of deliberate strictness. With no evidence at all,
a new session and a typo look identical, and silently creating a session at the
current directory is almost never what was wanted. **`mux new NAME` is how you
say you meant it**: it creates the session here and binds the name, writing a
row only if the name is not one this directory already derives. Bare `mux go`
never reaches that refusal — no name was typed, so nothing was mistyped.

### Agents

An **agent**, `share/agents/<name>.agent`, is two lines — a `go`
command and a `resume` command, each a shell command mux runs as the agent
pane's process:

```
# share/agents/claude.agent
go      claude --continue || claude
resume  claude --resume
```

A layout picks one with `agent <name>`; Claude is the default. Add any CLI by
dropping in a profile — `$MUX_DIR/agents/<name>.agent` for one of your own, or
to override a shipped profile of the same name. The state strip works for any
agent whose lifecycle events reach `mux agent-hook <EventName>`; mux owns the
mapping from event to state, so wiring an agent up says only what happened.
`mux setup claude` does it for Claude Code.

### Themes

The palette is **data**: `share/themes/<name>.theme`, each naming up to six
styles — `bar`, `window` (the current-window chip), `accent` (active border),
`border` (inactive), `select` (copy-mode), `prompt`. Only `bar`/`window`/
`accent` are required; mux derives the rest.

```
# share/themes/orange.theme
bar     bg=colour94 fg=colour223
window  fg=colour232 bg=colour214 bold
accent  fg=colour214
```

`themes/defaults` names the global default (`default <name>`) and how an unset
theme is derived (`derive hash`). Twenty-four themes ship, spread across
background lightness as well as hue — dark, mid-tone, and light — since a pale
bar in a strip of dark ones is the most legible distinction there is.

With `hash`, a session with no `theme` of its
own takes one deterministically from its **name**, so every project wears a
stable colour with nothing configured. Two projects share one only by
coincidence; `mux theme` fixes that in a keystroke. Priority is explicit >
context > derived > global default. `mux themes`
compiles the palette into tmux `@theme-*` options at server start and re-pushes
it on drift, so a theme edit needs no manual step. `mux theme [NAME|next|prev]`
switches a live session and **remembers** it: a theme chosen by hand is a
decision, so it is written to the profile immediately rather than behind a flag
you have to recall. (`-p`/`--persist` is retired -- accepted and ignored, since
it is the default now.) A theme dropped in `$MUX_DIR/themes` overrides a shipped
one of the same name.

### Session sets

The sessions you have open are recorded as you open them, per socket, in
`$MUX_STATE/sessions.<socket>` — one `NAME<TAB>ROOT` per line. After a reboot:

```sh
mux resume           # rebuild them all, then attach the first
mux resume --list    # just show what would be rebuilt
mux resume work      # another PARTITION's set, not the one you are in
mux resume work api  # ... and land on `api` when it is done
```

Both arguments are optional and **positional**: the first is always the
partition, never whichever word happens to name one, since that magic changes
meaning the day you add a partition. A partition nothing knows exits 3 rather
than resuming an empty set and reporting "no sessions recorded", which reads
as data loss when the truth is a typo. The session only says where to *focus*
afterwards (a resume brings them all back either way), and a name that is not
in the set is refused **before** the rebuild. `global` is the baseline
partition, and therefore the reserved word for "not the one my context
resolved" — needed only where a context mechanism can resolve to something
other than the baseline in an ordinary login shell.

It is **state, not config**: never in `$MUX_DIR`, never in git, and per
machine. Recording is additive when a session is built or attached and
subtractive on `mux kill` (`kill --all` clears it) — deliberately *not* a
snapshot of what is live, which the first `mux go` after a reboot would
clobber. The root is recorded because the common session is a bare `mux go` in
a directory, with no profile to rebuild it from. That also makes the set an
evidence source: `mux go <name>` resolves through it, so a session you had is
as good a reason to build as a profile or a scanned repo.

### Host chips

`$MUX_DIR/hosts` pins the status-left host chip's colour per machine, one
`HOST STYLE` per line where `HOST` is `hostname -s` and `STYLE` is a
**comma**-joined tmux run:

```
northwood    fg=colour252,bg=colour236
```

Optional, and it holds only the hosts you want to pin — an unlisted host gets a
stable, readable colour derived from its name, so identically-named sessions on
different machines are told apart with no configuration.

### Contexts and partitions

mux core knows nothing about any particular notion of "context" — a
work/personal split, a Kubernetes namespace, a git host. It asks an **optional
command for one word** and decides everything else itself.

```
# $MUX_DIR/config
context-command   severance current
```

A bare name is looked up in `$MUX_DIR` before `$PATH`, so a config shared
between machines needn't carry an absolute path. The command prints a
**token**; empty output or a non-zero exit means `global`. That is the entire
integration surface — no sockets, no styles, no themes, no path
classification. The integrator reports *identity*; mux decides presentation
and isolation.

Two axes, deliberately separate:

- a **context** is a settings axis, named by the token;
- a **partition** is an isolation axis. Sessions in different partitions are
  mutually invisible. A context's partition defaults to its own token, so
  contexts are isolated by default — but several contexts may name one
  partition to share it, which is how you can pick a default agent from
  external criteria *without* forcing a separate session namespace on yourself.

Everything isolation-scoped keys on the partition: the tmux socket, the
agent-state directory, the discovery map, the session set, and which profiles
are visible.

Settings resolve in three levels, merged last-wins, with no conditions:

```
1. mux's built-in defaults      behaviour only, never a location
2. partitions/<name>.partition  what this partition shares
3. contexts/<token>.context     what is unique to this context
```

The same key set is legal in either file — `label`, `theme`, `derive`, `agent`,
`layout`, `scan`, `ignore`, `host-chip`, plus `partition` in a context — so
**where you put a key is the statement of its scope**, and there is no per-key
rule to
learn. Drop-in files have owners: an integrator installs
`partitions/work.partition` without ever editing a file you also edit.

```
# $MUX_DIR/partitions/work.partition
label   Manifest
theme   orange
scan    ~/src/manifest 3
ignore  */vendor-repos/*
```

The built-in defaults carry **no location keys**. That is what stops `scan`
leaking between partitions: a partition nobody configured gets no roots and
therefore no map, so a missing context file is *visible* rather than quietly
indexing the wrong tree. mux ships `partitions/global.partition` with
`scan ~/src 3`, which is why the out-of-the-box case works.

A token becomes a socket name and a path component, so it is validated as a DNS
label (`[a-z0-9]([a-z0-9-]*[a-z0-9])?`). An invalid one is an error, never a
silent fall back — a typo'd token quietly becoming the baseline would put work
sessions in the personal partition.

**mux only reflects a context; it enforces nothing.** Whatever backs a boundary
— a Unix group, an ACL, a namespace — lives in whatever supplies the token. The
banner is a reminder, never permission.

`mux why` prints the resolved context, partition, and where every setting came
from.

### Views and tension

tmux sizes a window from **the clients attached to its session** — so two
clients of different sizes looking at the same session leave no size that suits
both. tmux picks one, and by default it picks whichever looked last, so every
window resizes as you cycle and mux re-pins each layout. That is usually an ssh
window you forgot was attached.

mux calls that **view tension**, shows it on the bar while it lasts, and names
the ways out:

| mode | glyph | the window | the cost |
| --- | --- | --- | --- |
| `auto` | `✱` | follows the last client | it moves as you cycle |
| `floor` | `┻` | fits the **smallest** client | a bigger view has dead rows |
| `ceil` | `┳` | fits the **largest** client | a smaller view is clipped |

The colour says which side **this** view is on: grey when nothing contends for
it, white when it is setting the size, amber when it carries dead rows, and the
caution pairing when it is **clipped** and part of the window is off screen.

No mode is right in general — each buys stability with something — so mux picks
none for you. `mux views` reports every client, its size and how long it has
been idle (which is what identifies the forgotten one), and says whether the
tension actually reaches the window you are in. Clicking the glyph cycles the
mode; `mux views --detach <client>` ends a claim outright.

### Remote sessions: latch

`mux latch HOST[:PARTITION] [SESSION]` holds an attachment to a mux session on
another machine open across network drops. **Bring your own transport:** mux
owns the state machine and the attach semantics, and ssh, mosh, Eternal Terminal
or anything else supplies the pipe. latch never carries a keystroke and knows
nothing about hosts, addresses or MTUs.

The first field is always the host and the colon is optional; everything after
the first colon is the **partition**, and the session is a separate second
argument. What that asks the far side to run:

```
mux latch box             ->  mux resume            what that box had
mux latch box api         ->  mux go api            that session specifically
mux latch box:work        ->  mux resume work       another partition's set
mux latch box:work api    ->  mux resume work api   ... landing on `api`
```

**The colon held the session until 0.56**, so `mux latch box:api` changed
meaning. The partition took the slot because it is the field a remote command
cannot otherwise reach — every verb but `resume` acts on whatever the far side's
own context resolved — while a session needs no slot. Which partitions exist is
the far side's question, so latch does not validate the name: one the remote
does not know exits 3 there, reported as `gone` with the remote's own message
naming the partitions it does have.

With no session named it is `mux resume`, and that is the right verb *because*
of how it creates: after a reboot it restores the sessions you actually had,
where `go` would build a single empty one. Attach-only therefore applies to the
bare named form only, and nothing is lost either way: `resume` never invents
anything, and a focus session it does not hold exits 3 rather than creating one.

The question that partitions its states is not which exit code came back, but:
does resolving this need **a human**, or **patience**?

| state | what it means | what latch does |
| --- | --- | --- |
| `probing` | down, recoverable on its own | retry on a backoff |
| `blocked` | no credential live **yet** | wait, and never attempt |
| `denied` | a credential or host key was refused | stop, and say what to fix |
| `refused` | the far side answered and cannot help | stop, and say why |
| `unknown` | cannot be determined | retry, with more patience |
| `ended` | you detached or quit | stop (exit 0) |
| `gone` | the session, or its tmux server, is gone | stop, never recreate |

`blocked` is the interesting one. Every attempt while no credential is live is a
password or touch prompt, so a retry loop there is a prompt storm. latch polls
the **credential** instead of the connection, which costs about 12ms, raises no
prompt while it waits, and moves on by itself the moment a key appears. So it is
a waiting state rather than a dead end. `denied` is the opposite case and is
terminal: latch cannot observe a human fixing `authorized_keys`, so retrying a
refusal forever is that same storm wearing a backoff.

`refused` covers the two cases people actually hit first: a remote mux too old
for the verb (exit 2), and `mux` missing from a non-interactive ssh PATH (127).
Those codes are attributable only because mux itself uses nothing but 0, 1 and
2, so a foreign code can only have come from the transport or the remote shell.

Five seams, each a command, each settable in the environment or as a `latch-*`
key in `$MUX_DIR/config`: `MUX_LATCH_TRANSPORT`, `_AUTH`, `_PROBE`, `_CLASSIFY`
and `_STATUS`. A hook answers 0 yes, 1 no, or 78 "cannot tell", and a hook that
cannot tell is never read as fine. A hook that is *unset* is different again:
that means no opinion, so latch proceeds.

**Eternal Terminal is supported as data, not code.** Two lines:

```
latch-transport  et %h --command %c
latch-classify   et-classify
latch-probe      et-probe
```

The probe is worth wiring here even though it is off by default for ssh. With
etserver stopped, one attempt costs 0.04s instead of 0.68s, latch stops
announcing an attach that cannot happen, and the reason it gives is right ("the
target is not reachable" rather than "the transport dropped"). Tell it the port
with `MUX_ET_PORT` or `latch-et-port` if etserver is not on 2022.

Verified between two VMs against et 7.0.0: the attach works, mux's status bar
renders on the far side, and a detach ends the latch at 0 while leaving the
remote session alive. `ssh-auth` still answers for it, because ET handshakes
over ssh.

Two limitations, both ET's rather than mux's. **A remote refusal reads as
`ended`**, because et 7.0.0 does not propagate the remote command's exit status,
so a far side with no mux looks like a deliberate close (its own message is on
your terminal, where et wrote it). And **latch cannot quote the reason a
connection failed**, because et writes its diagnostics to stdout rather than
stderr, which is why the classifier keys on the exit code alone. `man mux` has
the details, including why the template carries no `-t`.

**It puts your terminal back.** When ssh dies mid-session tmux never sends its
teardown, so the cursor stays hidden, mouse reporting stays on (moving the mouse
types control characters at your shell) and the alternate screen stays up.
`stty sane` only half works: it fixes the kernel's line discipline, while those
modes live in the terminal *emulator* and need the matching escape sequences.
latch repairs the terminal **first** on every drop, before it reports or waits —
otherwise "retrying in 8s" is printed into a hidden-cursor alternate screen and
a reconnect looks like a hang. `mux sane` is the same repair by hand, after any
wedged session — named after `stty sane`, which only fixes the kernel half.

**Hooks ship as a library, and wiring them is your step.** `share/latch/` holds
`ssh-auth`, `ssh-classify` and `ssh-probe`; a bare name in your
config resolves
`$MUX_DIR/latch` first, then `$MUX_SHARE/latch`, then `PATH` — the same
overlay-over-shipped order layouts and themes use, so a config can travel
between machines without absolute paths. `ssh-auth` and `ssh-classify` are
wired by default. `ssh-probe` ships **unwired** on purpose: no probe means no
opinion, and the attempt is the probe. Adding a mosh or
Eternal Terminal hook is a file, not a patch.

On a retry latch asks for `mux go --attach-only`, which refuses rather than
creates, so a rebooted host is *reported* instead of silently replaced by an
empty session. It negotiates that once, lazily, via `mux capabilities` — the
first real consumer of the handshake — and degrades gracefully against an older
remote. See **LATCH** in `man mux`.

### The agent contract: mux agent

Everything above is for a human reading a bar. `mux agent` is the surface a
PROGRAM is invited to depend on, and it is deliberately a different contract
rather than a second spelling of the same one.

```sh
mux agent status              # worst state + count, per partition
mux agent peers               # per session: state, age, control, root
mux agent read api -n 200     # what that agent is doing
mux agent wait api idle -t 60 # block until it is done
mux agent send api 'run the integration suite'
```

**One JSON object on stdout, always, including on failure.** A reader never has
to decide whether today's answer is a document or a sentence:

```json
{"status":"ok",
 "partitions":[{"partition":"global","state":"working","count":1}]}
{"status":"refused","reason":"blocked","override":"none",
 "class":"human","message":"..."}
```

A symbolic `status` sits beside the numeric exit code because mux uses exactly
four exit codes and the ABSENCE of the rest is load-bearing: latch can attribute
126, 127 and 255 to the shell and to ssh precisely because mux never emits them.
So richer outcomes go in the payload, where they cost nothing. The shape is
stable or the capability number moves (`mux capabilities` declares `agent
contract N`).

**`send` is the hook a higher layer needs, and the one with teeth.** mux refuses
to type into a pane that is `blocked` (sitting at a prompt addressed to a
person) or that it knows nothing about. An override exists, and it cannot live
anywhere
the governed party can reach: a command-line flag is forgeable and `$MUX_DIR` is
user-owned by design, so the policy is a root-owned file
(`/etc/mux/send-policy`), allowlist-only, scoped as finely as one window. mux
refuses to obey it if this user can write the file or its directory. Both halves
are required and neither is sufficient: the policy says whether it may ever
happen here, and an explicit `--answer-prompt` says you meant it now. Every
refusal reports whether an override is `available`, so a caller discovers the
answer in one round trip instead of guessing.

WHO CONTROLS THE PANE decides whether an override is possible at all, because
what makes answering a prompt wrong is not that an agent typed it, it is that
the prompt was addressed to a HUMAN. `human` is refused before the policy is
consulted; `agent` (a worker spawned and supervised by an agent) is grantable as
a whole class, which is what makes a village of generated names workable;
`hybrid` is its own class, grantable but usually scoped, because collapsing it
into either of the others is wrong in one direction or the other.

The guard is organisational, not a sandbox, and says so: mux runs as the agent's
own user, so any mark it reads is one the agent could rewrite. What it buys is
that the dangerous thing stops being the easy thing, the default sits outside
the agent's reach, and a bypass leaves mux's audit log.

**mux ships the instructions.** `mux skill` prints the agent-facing document
that
matches THIS mux, and `mux skill --agents-md` prints the same text in the
vendor-neutral `AGENTS.md` convention. Release-matched on purpose: a copy taken
from a website teaches whatever the verbs were that day. `mux setup claude`
places it. See **THE AGENT CONTRACT** in `man mux`.

### The tray

An optional StatusNotifierItem icon, its own Python package so mux core stays
shell and daemonless. It draws **one item per (host, partition)**, each carrying
that partition's worst agent state and how many sessions sit in it, with three
letters and a colour for the host and a letter for the partition.

**The box you are sitting at PULLS; nothing is pushed to it.** Every
platform-specific decision then happens on the only machine where it belongs,
which is what makes a macOS tray a presenter swap rather than a new transport.
Sources are COMMANDS rather than hosts, the same seam shape as the context hook,
so it works over ssh, a jump host, `kubectl exec` or anything else, and mux
never
learns what ssh is.

**The item set follows your latches.** Attach to a box and its item appears;
detach and it goes, because a tray item exists only if somebody is looking at
that machine. Locally the equivalent is a client attached to that partition's
server. An unreachable host KEEPS its items and draws them as unknown: "could
not ask" is a different answer from "it has none", and withdrawing them would
empty the tray at the moment it has something to say.

Clicking an item runs `mux next-blocked` on that box, which is meaningful for a
remote precisely because the item only exists while a latch does, and the latch
IS your live view of it.

```sh
./indicator/setup.sh          # install + a --user service unit
./indicator/setup.sh check    # same [OK]/[FAIL] marker contract as mux check
```

## Commands

Full reference in **`man mux`**. The essentials:

```
mux                          pick a session to attach (fzf or a menu)
mux go [NAME|DIR] [PROFILE]   create/attach/switch; agent continues
mux go --resume [NAME]       same, but the agent resumes (choose a chat)
mux --no-agent ...           build the panes, plain shell in the agent pane
mux resume [PART [SESS]]     rebuild a partition's sessions (--list)
mux setup claude             wire an agent's hooks to mux (--dry-run first)
mux demo                     a throwaway mux to look at (--stop when done)
mux keys                     what the key bindings do (also prefix ?)
mux skill                    the agent instructions this mux ships
mux skill --agents-md        the same, in the AGENTS.md convention
mux agent status             per-partition worst state + count, as JSON
mux agent peers              who is here, what each is doing, who drives it
mux agent read NAME [-n N]   capture that session's agent pane
mux agent wait NAME STATE    block until it gets there (-t SECONDS)
mux agent send NAME TEXT     hand it work (refuses a blocked or unknown pane)
mux scan                     rebuild the project discovery map
mux why [NAME]               show each resolved value and where it came from
mux views [auto|floor|ceil]  who is attached, at what size, what it costs
mux agent-doctor             does recorded agent state match reality?
mux ls                       list sessions (with agent-state glyphs)
mux new NAME                 create NAME here, binding the name if needed
mux save [NAME]              snapshot this session (records only deltas)
mux edit [NAME]              open a profile in $EDITOR
mux rename [OLD] NEW         rename a session and its profile
mux theme [NAME|next|prev]   set/cycle/show the theme (always remembered)
mux next-blocked [--partition NAME]
                             jump to the session that has needed you longest
mux hide/show SESSION        hide/unhide a session for this client
mux show-all                 clear this client's hidden sessions
mux reload                   re-source tmux.conf on every mux server
mux kill NAME | kill-all     tear down a session, or all (prompts)
mux sane                     put the terminal back after a wedged session
mux go --attach-only [NAME]  attach if live, else refuse (never create)
mux latch HOST[:PART] [SESS] hold a remote attachment open across drops
mux capabilities             what this mux supports, for other programs
```

## Key bindings

`prefix ?` shows this list inside tmux (`mux keys` from a shell).

Provided by `mux.tmux` (prefix table unless noted; your prefix is untouched):

| binding             | action                                        |
|---------------------|-----------------------------------------------|
| `(` / `)`           | cycle to the prev / next **visible** session  |
| `b`                 | jump to the longest-blocked session           |
| `B`                 | toggle back to the last session               |
| `r` / `R`           | refresh / rebuild a wedged pane layout        |
| `Space`             | the explorer (`choose-tree`)                  |
| `Tab` / `BTab`      | next / previous window                        |
| click a status chip | jump straight to that session (needs mouse)  |

## Configuration

- **`MUX_DIR`** — your config and overrides: layouts, the optional `context`
  hook, and theme overrides. Default `~/.config/mux`.
- **`MUX_SHARE`** — shipped package data: themes, shapes, agents, and the tmux
  fragments. Default: the `share` sibling of the `mux` binary.
- **`MUX_CACHE`** — regenerable state: palette stamps and the discovery map.
  Default `~/.cache/mux`. Everything here rebuilds on demand, which is what
  makes it a cache — and the stamps prune themselves as servers come and go.
- **`MUX_STATE`** — state that *cannot* be rebuilt: the session set, and an
  unsaved profile draft. Default `~/.local/state/mux`. The dividing line is one
  question: does mux regenerate it? A cache clear must not be able to take the
  answer to "what was I working on".

Defaults live in `MUX_SHARE`; your overrides and layouts live in `MUX_DIR`. mux
reads your override first, then the shipped default.

## How it works

- **One entry point, self-locating.** `bin/mux` resolves its own path and finds
  `../libexec` and `../share` beside it, so it works from any install
  prefix with no configuration. Every helper is reached as `mux <verb>`, so the
  tmux fragment and agent hooks carry no paths.
- **Agent state** lives in per-pane files under `$XDG_RUNTIME_DIR`, namespaced
  by tmux socket (a marked context never shows another's agents).
  `mux agent-hook <EventName>` (called from the agent's lifecycle hooks, which
  `mux setup claude` wires) records a transition through `mux agent-emit`;
  `mux agent-render` draws the status-right strip from it, degrading
  gracefully as the session count grows so a blocked session is never silently
  dropped.
- **The palette** is compiled from `*.theme` files to tmux options by
  `mux themes` and re-pushed on drift, so themes stay data.
- **Layouts** are flattened (includes expanded) and validated before any tmux
  state changes; the build then lays out windows and panes and pins a bottom
  pane's height across resizes.

## Extending

- **Add a theme:** drop `<name>.theme` in `$MUX_DIR/themes` (override) or
  `share/themes` (ship it), then `mux reload`.
- **Add an agent:** drop `<name>.agent` (a `go` and a `resume` line) in
  `share/agents`, and select it with `agent <name>` in a layout.
- **Mark a context:** put `context-command CMD` in `$MUX_DIR/config`. CMD is
  run with the calling PID and prints ONE DNS-label token on stdout (or
  nothing, for the baseline). A bare name resolves against `$MUX_DIR` before
  `$PATH`, so the same config travels between machines.
- **Notify from a non-freedesktop platform:** set `MUX_NOTIFY_SEND` and
  `MUX_NOTIFY_CLOSE`. Send is called `CMD URGENCY SUMMARY BODY` and prints an
  id; close is called `CMD ID`. The id is opaque to mux, so any token the two
  agree on works. `mux check` reports which path is live.

## Reference

Complete command, layout, theme, and seam reference: **`man mux`** (or
`man -l share/man/man1/mux.1` from a checkout).

## Status and license

mux is stable and in daily use, published as a standalone project extracted
from a personal environment repository.

Copyright 2026 JFC Innovations, Inc. Licensed under the Apache License,
Version 2.0. See [LICENSE](LICENSE).

## Development

An 80-column limit is enforced by a tracked pre-commit hook. Enable it once
per clone:

    git config core.hooksPath .githooks
