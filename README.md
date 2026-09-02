# mux

**A tmux session manager for agent-heavy, many-session work.**

You run several coding agents at once — one per project, each in its own tmux
session. They spend much of their time *working*, then *block*, waiting for you
to answer a prompt or approve a step. The hard part isn't running them; it's
knowing **which one needs you, and jumping straight to it** — without hunting
through a wall of look-alike sessions.

mux turns tmux into that dashboard:

- **Declarative profiles.** A session's identity and appearance (working
  directory, theme, agent) live in one small file that names a *layout* for the
  pane arrangement. `mux go api` builds or attaches `api` the same way every
  time, and with no profile at all you still get a working session.
- **A live agent-state strip.** Every session wears a glyph for its agent —
  idle, working, or blocked (needs you). One glance answers "who's waiting on
  me."
- **Jump to whoever's waited longest.** One key takes you to the most-blocked
  session; repeat to walk down the urgency order.
- **Per-host colour chips, per-client hide/show, skip-hidden cycling,
  data-driven themes**, and **contexts and partitions** to isolate (say) work
  from personal, driven by one word from an integrator.

It's POSIX shell over tmux. No daemon, no runtime dependencies beyond tmux
itself (`fzf` optional, for a nicer session picker).

---

## Contents

- [The status bar](#the-status-bar)
- [Requirements](#requirements)
- [Install](#install)
- [Quickstart](#quickstart)
- [Concepts](#concepts)
  - [Sessions: go and resume](#sessions-go-and-resume)
  - [Profiles and layouts](#profiles-and-layouts)
  - [Agents](#agents)
  - [Themes](#themes)
  - [Contexts and partitions](#contexts-and-partitions)
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
┌ status-left ─────────────┐            ┌──────────── status-right ───────────┐
│ [[WORK: api]]  host  api ▸│ 1:code 2:… │ ⚠ api · 🧠 web · ✓ docs · ⚫ notes  │
└──────────────────────────┘            └──────────────────────────────────────┘
      context banner  host   current      per-session agent-state strip
      (optional)      chip    session
```

- **status-left** — an optional **context banner** (e.g. a work marker), a
  per-**host** colour chip so identically-named sessions on different machines
  are told apart, then the current session name.
- **status-right** — one token per session, in cycle order, each with an
  agent-state glyph: `⚠` needs you, `🧠` working, `✓` just finished, `⚫` no
  agent. The session that has needed you **longest** is the loudest; `prefix b`
  jumps there.

The text is the signal; colour is decoration.

## Requirements

- **tmux** (3.x) and a POSIX shell (`dash` is fine — mux uses no bash-isms).
- Optional: **fzf** for the fuzzy session picker (`mux` with no arguments falls
  back to a numbered menu without it).
- Optional: a coding agent CLI (e.g. Claude Code) to actually run in the agent
  panes, and its lifecycle hooks wired to `mux agent-emit` for the state strip
  (see [Agent state](#how-it-works)).

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

## Quickstart

```sh
# open (or attach) a session for the current project, agent continuing
mux go

# write a profile for a project, then bring it up
mux new api - ~/src/api      # name=api, default colour, root=~/src/api
mux go api

# the essentials, from inside tmux (default prefix, adjust to yours):
#   prefix b     jump to the agent that has waited longest
#   prefix B     jump back
#   prefix ( )   cycle to the prev / next session (skips hidden)
#   prefix Space explorer (choose-tree)
```

## Concepts

### Sessions: go and resume

A **session** is a running tmux session. mux builds it from a **profile** of
the same name if there is one, and from its own defaults if there is not. Two
build verbs differ only in how the agent pane starts:

- `mux go [NAME] [PROFILE]` — the agent **continues** its most recent
  conversation.
- `mux go --resume [NAME]` — the agent **resumes**, prompting you to pick a
  conversation (`mux resume` is kept as an alias).

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
kg          root=~/src/ManifestOS/apps/knowledge-store
jellotron   layout=logs
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
roots. Declare them in `$MUX_DIR/scan`, one `PATH [DEPTH]` per line (`~/src 3`
is assumed if the file is absent):

```
~/src 3
~/work 2
```

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
`mux restore` replay a command anyone could type instead of reaching into
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
agent whose lifecycle calls `mux agent-emit working|blocked|idle` (Claude Code
does this via a hook plugin).

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
switches a live session (`-p` persists it into the layout). A theme dropped in
`$MUX_DIR/themes` overrides a shipped one of the same name.

### Session sets

The sessions you have open are recorded as you open them, per socket, in
`$MUX_CACHE/sessions.<socket>` — one `NAME<TAB>ROOT` per line. After a reboot:

```sh
mux restore          # rebuild them all, then attach the first
mux restore --list   # just show what would be rebuilt
```

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
manifold    fg=colour252,bg=colour236
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
context-command   severance mux-context
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
`layout`, `scan`, `host-chip`, plus `partition` in a context — so **where you
put a key is the statement of its scope**, and there is no per-key rule to
learn. Drop-in files have owners: an integrator installs
`partitions/manifest.partition` without ever editing a file you also edit.

```
# $MUX_DIR/partitions/manifest.partition
label   Manifest
theme   orange
scan    ~/src/manifest 3
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

## Commands

Full reference in **`man mux`**. The essentials:

```
mux                          pick a session to attach (fzf or a menu)
mux go [NAME|DIR] [PROFILE]   create/attach/switch; agent continues
mux resume [NAME] [PROFILE]   same, but the agent resumes (choose a chat)
mux --no-agent ...           build the panes, plain shell in the agent pane
mux restore                  rebuild this partition's sessions (--list)
mux scan                     rebuild the project discovery map
mux why [NAME]               show each resolved value and where it came from
mux ls                       list sessions (with agent-state glyphs)
mux new NAME                 create NAME here, binding the name if needed
mux scan                     rebuild the project discovery map
mux save [NAME]              snapshot this session (records only deltas)
mux edit [NAME]              open a profile in $EDITOR
mux rename [OLD] NEW         rename a session and its profile
mux theme [NAME|next|prev]   set/cycle/show the theme (-p to persist)
mux next-blocked             jump to the session that has needed you longest
mux hide/show SESSION        hide/unhide a session for this client
mux show-all                 clear this client's hidden sessions
mux reload                   re-source tmux.conf on every mux server
mux kill NAME | kill-all     tear down a session, or all (prompts)
```

## Key bindings

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
- **`MUX_CACHE`** — per-socket palette stamp directory. Default `~/.cache/mux`.

Defaults live in `MUX_SHARE`; your overrides and layouts live in `MUX_DIR`. mux
reads your override first, then the shipped default.

## How it works

- **One entry point, self-locating.** `bin/mux` resolves its own path and finds
  `../libexec` and `../share` beside it, so it works from any install
  prefix with no configuration. Every helper is reached as `mux <verb>`, so the
  tmux fragment and agent hooks carry no paths.
- **Agent state** lives in per-pane files under `$XDG_RUNTIME_DIR`, namespaced
  by tmux socket (a marked context never shows another's agents).
  `mux agent-emit <state>` (called from the agent's lifecycle hooks) records a
  transition; `mux agent-render` draws the status-right strip from it, degrading
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
- **Mark a context:** make `$MUX_DIR/context` an executable implementing the
  three verbs above; mux picks it up automatically.

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
