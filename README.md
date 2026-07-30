# mux

A tmux session manager built for an agent-heavy, many-session workflow: a
per-session status strip showing each agent's state (idle / working / blocked),
skip-hidden session cycling, click-to-jump session chips, a data-driven colour
theme system, and a pluggable context seam (used, for example, to mark a
work/personal boundary in the status bar).

## Layout

    bin/mux            the single entry point (on PATH)
    libexec/mux/       internal helpers -- executables mux dispatches to, and
                       sourced shell libraries (*.sh). NOT on PATH.
    share/mux/         package data: themes/, shapes/, agents/, and the tmux
                       integration fragments (mux.tmux, mux-opinions.tmux).

## Integration

- Source `share/mux/mux.tmux` from your `tmux.conf` for the status bar, feature
  bindings, and resize hooks; optionally `share/mux/mux-opinions.tmux` for
  ergonomic defaults (mouse, scroll routing, navigation).
- `$MUX_DIR` (default `~/.config/mux`) holds user/integrator overrides: a
  `context` hook, a `hosts` chip-colour file, and custom layouts/themes.

## Status

Being extracted from a personal provisioning repo (tackup), where it is
currently staged under `repos/mux/`. The remaining steps before it stands alone:
route the tmux fragment's calls through the `mux` entry point (retiring the
`@mux-lib` path seam), install under `~/.local`, then split to its own repo.
