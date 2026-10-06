#!/bin/sh
# test/mux-save.t - `mux save` records a live session the way everything else
# does: as a DEVIATION. The interesting cases are the ones where it should
# write LESS than it read.
#
#   - an arrangement identical to an existing layout mints no private copy;
#   - a root the name derives from is not recorded;
#   - a theme equal to the one the name hashes to is not recorded;
#   - so saving a session you never touched correctly writes NOTHING.
#
# The agent pane is the trap: `emit_window` reads each pane's running command,
# and an agent that exited (or was never installed) looks exactly like a shell,
# so without the @mux-agent mark a round trip silently degrades `pane agent`
# into a bare `pane` and every save looks like a change.
#
# tmux is stubbed, so no server starts.
set -eu
_name=mux-save
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/conf" "$T/proj"
# The stub models one session: three panes matching the shipped default, with
# the middle one marked as the agent, plus the session's own start path.
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*session_name*)  printf 'proj\n' ;;
*session_path*)  printf '%s\n' "$PROJDIR" ;;
*list-windows*)  cat "$WINDOWS" ;;
*"@mux-theme"*)  cat "$THEMEF" 2>/dev/null || true ;;
*list-panes*)
  # index|bottom|agent|control|attention|command, in the order bin/mux asks.
  case "$*" in
  *pane_index*) cat "$PANES" ;;
  *) grep '|5-10|' "$PANES" \
    | while IFS='|' read -r _i b a k n c; do
      printf '%s|%s\n' "$b" "$c"
      done ;;
  esac ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; PROJDIR=$T/proj; WINDOWS=$T/win; PANES=$T/panes; THEMEF=$T/theme
export TMUXLOG PROJDIR WINDOWS PANES THEMEF
PATH=$T/bin:$PATH; export PATH
printf '0 main\n' >"$WINDOWS"
# index|bottom|agent|control|attention|command: the middle pane is the agent,
# the last the full-width bottom, i.e. exactly the shipped default
# arrangement. No pane declares either class, so the default arrangement
# round-trips to itself.
{
  printf '0|||||bash\n'
  printf '1||1|||bash\n'
  printf '2|5-10||||bash\n'
} >"$PANES"
: >"$THEMEF"

save() {
  : >"$TMUXLOG"
  ( cd "$T/proj" && env -u MUX_SHARE MUX_DIR="$T/conf" \
    MUX_CACHE="$T/cache" TMUX="$T/default,0,proj" \
    "$HERE/bin/mux" save "$@" ) 2>&1
}
row() { grep '^proj ' "$T/conf/profiles" 2>/dev/null || true; }

# --- an untouched session: the arrangement matches the shipped default, the
# root derives the name, and no theme is set, so NOTHING is recorded ---------
_o=$(save) || fail "save failed: $_o"
case $_o in
  *"matches the 'default' layout"*) ;;
  *) fail "an identical arrangement minted a copy: [$_o]" ;;
esac
case $_o in
  *"entirely derivable"*) ;; *) fail "a derivable session wrote a row: [$_o]" ;;
esac
[ ! -e "$T/conf/layouts/proj.layout" ] || fail "a redundant layout was written"
[ -z "$(row)" ] || fail "a redundant row was written: [$(row)]"

# --- a theme that is NOT the hashed one is a real deviation, so it is kept:
printf 'red\n' >"$THEMEF"
_o=$(save) || fail "save with a theme failed: $_o"
case "$(row)" in *theme=red*) ;; *) fail "an explicit theme was dropped" ;; esac
case "$(row)" in *layout=*) fail "layout=default should not be recorded" ;;
esac
: >"$THEMEF"

# --- an extra window IS a deviation: a layout file, and a row naming it -----
printf '0 main\n1 extra\n' >"$WINDOWS"
_o=$(save) || fail "save with an extra window failed: $_o"
[ -f "$T/conf/layouts/proj.layout" ] || fail "no layout written for a change"
case "$(row)" in *layout=proj*) ;; *) fail "the row does not name the layout" ;;
esac
# The agent pane must survive the round trip as `pane agent`, not as a shell.
grep -qE '^pane[[:space:]]+agent' "$T/conf/layouts/proj.layout" \
  || fail "the agent pane was saved as a plain shell"
grep -qE '^bottom[[:space:]]+5-10' "$T/conf/layouts/proj.layout" \
  || fail "the bottom pane was not captured"

# --- re-saving an UNCHANGED session is a silent no-op ----------------------
# The arrangement now matches the layout the previous save wrote, so it is
# recognised rather than rewritten.
_o=$(save) || fail "re-saving failed: $_o"
case $_o in
  *"matches the 'proj' layout"*) ;;
  *) fail "re-saving an unchanged session rewrote it: [$_o]" ;;
esac

# --- but a further change will not clobber the file without --force --------
printf '0 main\n1 extra\n2 third\n' >"$WINDOWS"
_o=$(save) && fail "save should refuse to overwrite a layout"
case $_o in *"use --force"*) ;; *) fail "unhelpful overwrite error: [$_o]" ;;
esac
save --force >/dev/null || fail "--force did not allow the overwrite"
grep -qE '^window[[:space:]]+third' "$T/conf/layouts/proj.layout" \
  || fail "--force did not write the new arrangement"

# --- THE CONTROL CLASS ROUND-TRIPS ----------------------------------------
# EXACTLY THE REASON `@mux-agent` IS READ TWO FIELDS EARLIER, applied to the
# option that decides who may TYPE into a pane. Without it a save-then-build
# cycle silently reclasses a worker to `human`, which is mux's safe default
# and precisely wrong here: a supervisor then cannot type into its own
# worker, and nothing anywhere says why.
printf '0|||agent||bash\n1||1|hybrid|agent|bash\n2|5-10||||bash\n' \
  >"$PANES"
save --force >/dev/null || fail "save with declared classes failed"
grep -qE '^control[[:space:]]+agent'  "$T/conf/layouts/proj.layout" \
  || fail "a pane declared 'control agent' came back unclassed, so the next
build would hand it to the human and the send policy would refuse its own
supervisor: $(cat "$T/conf/layouts/proj.layout")"
grep -qE '^control[[:space:]]+hybrid' "$T/conf/layouts/proj.layout" \
  || fail "'hybrid' did not survive the round trip. It is its own class on
purpose: folding it into either neighbour would force the strictest grant to
express the middling case."

# AND `attention` ROUND-TRIPS SEPARATELY, asserted on the pane that declares
# BOTH: it is `control hybrid` and `attention agent`, which is the
# combination that proves the two are carried independently rather than one
# being inferred from the other. A worker the supervisor may type into but
# the human should still SEE is the case that would otherwise be unsayable.
grep -qE '^attention[[:space:]]+agent' "$T/conf/layouts/proj.layout" \
  || fail "'attention agent' was dropped, so a round trip hands a worker back
to the human's strip, notifications and next-blocked: the inversion R2 exists
to prevent. $(cat "$T/conf/layouts/proj.layout")"

# AND `human` IS OMITTED, because a layout holds only what OVERRIDES: an
# explicit `control human` is indistinguishable from the absence of the line,
# so writing it would read as a decision somebody made.
printf '0|||human|human|bash\n1||1|||bash\n2|5-10||||bash\n' >"$PANES"
save --force >/dev/null || fail "save with an explicit human class failed"
grep -qE '^control|^attention' "$T/conf/layouts/proj.layout" \
  && fail "a default class was written out: $(cat \
"$T/conf/layouts/proj.layout")"
:

# --- THE VERB IS A LAZILY SOURCED LIB (2026-10-05) ------------------------
# 132 lines moved to lib/mux-save_lib, which also needs bin/mux's own `tm`
# and `emit_window`: see its header. t_lib_lazy drives the two properties of
# the move itself, invisible to every assertion above.
muxp() {
  ( cd "$T/proj" && env -u MUX_SHARE MUX_DIR="$T/conf" \
    MUX_CACHE="$T/cache" TMUX="$T/default,0,proj" \
    "$T_PREFIX/bin/mux" "$@" ) 2>&1
}
t_lib_lazy muxp mux-save_lib save ls

pass
