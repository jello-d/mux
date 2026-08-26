# mux

A tmux session manager for agent-heavy, many-session work. POSIX shell over
tmux, no daemon, no runtime dependency beyond tmux itself. This file is the
working guide for changes to mux; the README is the user-facing overview and
`man mux` (share/man/man1/mux.1) is the full reference. Read those for what
mux does; this file covers how to change it safely.

mux was extracted from a personal provisioning repo into its own project. It
is integrator-neutral by design: nothing here names a particular provisioning
system, host, or work boundary. Keep it that way (see Naming).

## Repo layout

A standard self-contained package: one entry point that self-locates its
siblings under a single prefix.

- `bin/mux`             the single entry point (self-locating dispatcher)
- `libexec/mux/`        helpers, plus the sourced `*.sh` libraries
- `share/mux/`          package data: `themes/`, `shapes/`, `agents/`, and the
                        tmux fragments (`mux.tmux`, `mux-opinions.tmux`)
- `share/man/man1/`     the man page
- `indicator/`          optional Python SNI tray icon, its own pipx package
                        (kept out of core so mux core stays shell/no-daemon)

## Conventions

- POSIX sh, runs under `dash`. No bashisms anywhere in `bin/mux` or
  `libexec/`. (`indicator/` is Python; it does not share this rule.)
- 80-column limit for code and prose.
- Prose I write here avoids em-dashes and double-hyphens standing in for them.
  Note the existing shell comments use a ` -- ` separator throughout; when
  editing an existing file, match that file's surrounding style rather than
  fighting it.
- After a shell edit: `dash -n <file>`. After a Python edit: `python3 -m
  py_compile <file>`. After a man-page edit: `groff -z -man share/man/man1/
  mux.1` (lints clean). There is no automated test suite in-repo yet; the
  cheap linters plus a live tmux smoke test are the floor (see Testing).

## Self-location invariant (do not reintroduce a path seam)

`bin/mux` resolves `$0` (a bare-name PATH lookup, relative, or absolute, via
`command -v` + `readlink -f`), then `libexec/` and `share/` are its siblings
under the resolved prefix. No hardcoded paths, no `MUX_LIB`-style env seam.
Every helper is reachable as `mux <verb>` through an early exec dispatch that
sits before the heavy setup, so the tmux fragment and the agent hooks carry no
paths (they call `mux <verb>`) and the hot paths pay no extra parse. Keep new
helpers on this pattern; do not add a path env.

## MUX_DIR vs MUX_SHARE

- `MUX_SHARE` = shipped defaults (`share/mux`), the sibling of `bin`/`libexec`.
- `MUX_DIR` = the user overlay (default `~/.config/mux`): layouts, the optional
  `context` hook, theme overrides.
- `MUX_CACHE` = per-socket palette stamp dir (default `~/.cache/mux`).

Reads check `MUX_DIR` first, then fall back to `MUX_SHARE` (so `include
shapes/code` finds the shipped shape, a user layout wins over a shipped one of
the same name). Writes (`mux new`, `mux save`, `mux theme -p`) go to `MUX_DIR`.

## The context seam (mux reflects, it does not enforce)

`$MUX_DIR/context` is an optional executable answering three verbs (`env`,
`side`, `sockets`). mux only DISPLAYS a context: a status marker, an isolation
socket suffix (a tmux `-L` server), a side token for layout filtering, a
default theme. Whatever backs a boundary (a Unix group, an ACL, a namespace)
lives in the integrator that supplies the hook, never in mux. Output is parsed
against a key whitelist, never eval'd. A work/personal split is ONE example of
a context, described generically; mux core stays ignorant of any specific
notion of it.

## The `mux check` marker contract

`libexec/mux/mux-check` prints plain `[OK]` / `[FAIL]` / `[WARN]` MARKER lines
and self-colours them ONLY on a terminal (`[ -t 1 ] && [ -z "$NO_COLOR" ]`);
piped or captured it stays plain, so an external styler can repaint. It exits
non-zero on any `[FAIL]`. This is a string convention with no shared-code
dependency, which is what lets an outside tool drive `mux check` and paint its
output. Preserve both properties when extending the check.

## Agent state (single source of truth)

Per-pane state files live under `$XDG_RUNTIME_DIR/agent-state/<ns>` (the
namespace `<ns>` is `$TMUX` or `default`), so state is answerable headless.

- `mux agent-emit <state>` (called from an agent's lifecycle hooks) records a
  transition.
- `mux agent-render` draws the status-right strip.
- `mux agent-summary [NS]` prints `<state> <count>`: the worst live state
  across the namespace (blocked > working > idle) and how many sessions sit in
  it, else `none 0`. It derives sessions from the state FILES, not `tmux
  list-sessions`, so it works with no server attached.

All ranking and glyph logic lives in `libexec/mux/mux-agent-state.sh`. It is
the single source; do not duplicate the ranking in a helper or the indicator.

## The indicator (indicator/)

An optional StatusNotifierItem tray icon, its OWN Python package so mux core
stays shell and daemonless. Dependencies chosen for a painless install:
`dbus-next` (pure-Python D-Bus, no PyGObject / gobject-introspection system
dep) and `Pillow`. It is a THIN presenter: it polls `mux agent-summary` and
renders an owned vector glyph. All visual identity (the terminal-tile glyph,
the per-state frame colour, the count badge) lives in `render.py`; the state
logic stays in mux.

- Install standalone: `./indicator/install` (POSIX sh, no sudo, idempotent,
  env-overridable; verbs `all` | `app` | `service` | `check` | `uninstall`),
  or `pipx install ./indicator`. Both land `~/.local/bin/mux-indicator` and
  the same `--user` service unit. `install check` prints the same
  `[OK]`/`[FAIL]` marker contract as `mux check`.
- Dev/test: the deps are not in system Python, so use a throwaway venv:
  `python3 -m venv /tmp/mux-ind && /tmp/mux-ind/bin/pip install dbus-next
  Pillow`, then run `python -m mux_indicator` from `indicator/`. KILL GOTCHA:
  never `pkill -f "python -m mux_indicator"`, which self-matches the shell and
  kills it. Find the real pid via `pgrep -f mux_indicator` filtered to
  `comm == python`.
- Roadmap: left-click Activate to `mux next-blocked`; tooltip plus a
  right-click dbusmenu; then let notifications go transient once the persistent
  icon carries the signal.

## Naming (do not reintroduce integrator specifics)

mux is integrator-neutral. Do not name any specific provisioning system, host,
account, or a particular work/personal boundary in code, comments, or docs.
The context seam is the ONLY hook, and any boundary is described as one generic
example. The commit history was scrubbed of such references at extraction; keep
new work clean the same way.

## Testing

`test/run` runs the shell-library tests (`test/*.t`): `mux-conf` (the config
normalizer `mux_conf_clean`) and `mux-context` (the context-seam adapter
`mux_ctx_*`). Each is pure string logic against a library under `libexec/mux/`,
touching nothing outside a scratch dir. Add a `test/<name>.t` (source
`test/lib.sh`, then the library) when you add or change a library with
non-trivial parsing. Beyond that suite, verify a change with:

1. The linters above (`dash -n`, `py_compile`, `groff -z -man`).
2. A live tmux smoke test: from a scratch tmux, `source-file share/mux/
   mux.tmux`, then `mux go` / `mux ls` / `mux check`, and confirm the palette
   loads and the agent-state strip renders.
