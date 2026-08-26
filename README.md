# mux

**A tmux session manager for agent-heavy, many-session work.**

You run several coding agents at once — one per project, each in its own tmux
session. They spend much of their time *working*, then *block*, waiting for you
to answer a prompt or approve a step. The hard part isn't running them; it's
knowing **which one needs you, and jumping straight to it** — without hunting
through a wall of look-alike sessions.

mux turns tmux into that dashboard:

- **Declarative layouts.** A session's windows, panes, working directory, agent,
  and theme live in one small file. `mux go api` builds or attaches the `api`
  session the same way every time.
- **A live agent-state strip.** Every session wears a glyph for its agent —
  idle, working, or blocked (needs you). One glance answers "who's waiting on
  me."
- **Jump to whoever's waited longest.** One key takes you to the most-blocked
  session; repeat to walk down the urgency order.
- **Per-host colour chips, per-client hide/show, skip-hidden cycling,
  data-driven themes**, and a **pluggable context seam** to mark (say) a
  work/personal boundary in the status bar.

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
  - [Layouts](#layouts)
  - [Agents](#agents)
  - [Themes](#themes)
  - [The context seam](#the-context-seam)
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
(`libexec/mux/`) and data (`share/mux/`) as siblings under one prefix — the
standard package layout. Install it wherever you keep local tools, e.g.:

```sh
git clone https://github.com/jello-d/mux ~/.local/opt/mux
ln -s ~/.local/opt/mux/bin/mux ~/.local/bin/mux   # on PATH
```

Then source the tmux integration from your `~/.config/tmux/tmux.conf` (or
`~/.tmux.conf`):

```tmux
source-file /path/to/mux/share/mux/mux.tmux           # required
source-file /path/to/mux/share/mux/mux-opinions.tmux  # optional ergonomics
```

`mux.tmux` reaches mux only as `mux <verb>`, so it carries no paths; it just
needs `mux` on `PATH`. `mux-opinions.tmux` adds mouse, scroll-routing, and
navigation defaults you can skip if you have your own.

Man pages install to `share/man/man1/`; put that on your `MANPATH` for
`man mux`.

## Quickstart

```sh
# open (or attach) a session for the current project, agent continuing
mux go

# write a layout for a project, then bring it up
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

A **session** is a running tmux session; mux builds it from a **layout** of the
same name (or an explicit one you pass). Two build verbs differ only in how the
agent pane starts:

- `mux go [NAME] [LAYOUT]` — the agent **continues** its most recent
  conversation.
- `mux resume [NAME] [LAYOUT]` — the agent **resumes**, prompting you to pick a
  conversation.

If the session is already up, both just attach or switch to it (idempotent —
they never clobber a live session). `--bare` builds the shape but runs a plain
shell in the agent pane instead.

### Layouts

A layout is a small declarative file, `$MUX_DIR/<name>.layout`, parsed and
validated in full **before** any tmux call, so a malformed layout builds
nothing. Directives are either **session-wide** (last-wins, order-independent)
or **shape** (build windows and panes in the order they appear):

| directive | kind | meaning |
| --- | --- | --- |
| `root DIR` | session | working dir for every pane (`~` expands) |
| `theme NAME` | session | the colour theme |
| `agent NAME` | session | which agent profile a `pane agent` runs |
| `notify always\|away` | session | when the agent notification fires |
| `window NAME` | shape | start a new window |
| `pane CMD` | shape | a pane running `CMD` (`pane agent` = the agent) |
| `bottom N\|MIN-MAX` | shape | a full-width bottom shell, bounded height |
| `include REF` | shape | splice in `REF.layout` (a shape or a layout) |

A real layout composes a shared shape:

```
# ~/.config/mux/api.layout
theme   orange
root    ~/src/api
include shapes/code      # the shared vim | agent | shell shape (from share/)
```

`include` searches your config first (`$MUX_DIR`), then the shipped defaults
(`$MUX_SHARE`), so `shapes/code` pulls the packaged shape while your own
`include mylayout` finds a layout you wrote. `mux new` and `mux save` write
layouts for you.

### Agents

An **agent profile**, `share/mux/agents/<name>.agent`, is two lines — a `go`
command and a `resume` command, each a shell command mux runs as the agent
pane's process:

```
# share/mux/agents/claude.agent
go      claude --continue || claude
resume  claude --resume
```

A layout picks one with `agent <name>`; Claude is the default. Add any CLI by
dropping in a profile. The state strip works for any agent whose lifecycle
calls `mux agent-emit working|blocked|idle` (Claude Code does this via a hook
plugin).

### Themes

The palette is **data**: `share/mux/themes/<name>.theme`, each naming up to six
styles — `bar`, `window` (the current-window chip), `accent` (active border),
`border` (inactive), `select` (copy-mode), `prompt`. Only `bar`/`window`/
`accent` are required; mux derives the rest.

```
# share/mux/themes/orange.theme
bar     bg=colour94 fg=colour223
window  fg=colour232 bg=colour214 bold
accent  fg=colour214
```

`themes/defaults` names the global default (`default <name>`). `mux themes`
compiles the palette into tmux `@theme-*` options at server start and re-pushes
it on drift, so a theme edit needs no manual step. `mux theme [NAME|next|prev]`
switches a live session (`-p` persists it into the layout). A theme dropped in
`$MUX_DIR/themes` overrides a shipped one of the same name.

### The context seam

mux core knows nothing about any particular notion of "context" — a
work/personal split, a Kubernetes namespace, a git host. It asks an **optional**
hook, `$MUX_DIR/context` (an executable), and falls back to a single default
context when none is installed. The hook answers three verbs:

- `context env [PID]` — the context of a process: an isolation `socket` (a tmux
  `-L` suffix, so a marked context gets its own server), an opaque `side` token
  (drives layout filtering and the marker), a `label` and `banner` (the reminder
  text and its style), and a default `theme`.
- `context side ROOT` — which side a layout rooted at `ROOT` belongs to (or
  `shared`, visible everywhere).
- `context sockets` — every non-default context server, so `reload` and palette
  sync reach them all.

Output is parsed against a key whitelist, never eval'd. **mux only reflects a
context; it enforces nothing** — whatever backs a boundary (a Unix group, an
ACL, a namespace) lives in the integrator that supplies the hook.

## Commands

Full reference in **`man mux`**. The essentials:

```
mux                          pick a session to attach (fzf or a menu)
mux go [NAME] [LAYOUT]        create/attach/switch; agent continues
mux resume [NAME] [LAYOUT]    same, but the agent resumes (choose a chat)
mux --bare ...               build the shape, plain shell in the agent pane
mux ls                       list sessions (with agent-state glyphs)
mux new [NAME] [COLOR] [ROOT] write a layout ('-' = default colour / no root)
mux save [NAME]              snapshot this session's shape to NAME.layout
mux edit [NAME]              open a layout in $EDITOR
mux rename [OLD] NEW         rename a session and its layout
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
  fragments. Default: the `share/mux` sibling of the `mux` binary.
- **`MUX_CACHE`** — per-socket palette stamp directory. Default `~/.cache/mux`.

Defaults live in `MUX_SHARE`; your overrides and layouts live in `MUX_DIR`. mux
reads your override first, then the shipped default.

## How it works

- **One entry point, self-locating.** `bin/mux` resolves its own path and finds
  `../libexec/mux` and `../share/mux` beside it, so it works from any install
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
  `share/mux/themes` (ship it), then `mux reload`.
- **Add an agent:** drop `<name>.agent` (a `go` and a `resume` line) in
  `share/mux/agents`, and select it with `agent <name>` in a layout.
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
