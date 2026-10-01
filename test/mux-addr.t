#!/bin/sh
# test/mux-addr.t - the one address grammar.
#
#     [PARTITION.]SESSION[:WINDOW]
#
# THE FIRST SECTION IS ABOUT TMUX, NOT ABOUT MUX, and it is the load-bearing
# one. This grammar is only unambiguous because neither delimiter can occur
# in the thing it separates, and that is a fact about tmux rather than a
# choice mux made: measured by creating `work<D>api` and reading back what
# tmux stored. If a future tmux ever keeps a `.` or a `:` verbatim, every
# address in this package becomes ambiguous in silence, so the premise is
# asserted rather than trusted to a comment.
#
# A partition name is a DNS label (`mux_ctx_valid`), so it can hold neither
# character either way; the session side is the half that needed measuring.
set -eu
_name=mux-addr
. "$(dirname "$0")/harness_lib"

# shellcheck source=/dev/null
. "$HERE/libexec/mux-addr_lib"

# --- the premise, against a real tmux -------------------------------------
if command -v tmux >/dev/null 2>&1; then
  SOCK=$(tmux_fresh_socket muxaddr)
  cleanup() { tmux_drop_socket "$SOCK"; }
  t_trap 'cleanup'
  tm() { env -u TMUX -u TMUX_PANE tmux -L "$SOCK" "$@"; }
  tm -f /dev/null new-session -d -s base -x 80 -y 24 \
    || { printf 'skip %s (cannot start a tmux server)\n' "$_name"; exit 0; }

  # `.` and `:` MUST BOTH BE REWRITTEN, or they are not structural.
  for _d in . :; do
    tm new-session -d -s "work${_d}api" 2>/dev/null || true
    _got=$(tm list-sessions -F '#{session_name}' 2>/dev/null \
      | grep -v '^base$' | head -1)
    [ "$_got" != "work${_d}api" ] || fail "tmux now STORES [work${_d}api]
verbatim, so '${_d}' can appear in a session name and every address in this
package is ambiguous: 'work${_d}api' could be two fields or one name. The
grammar's whole premise is that this cannot happen."
    tm kill-session -t "=$_got" 2>/dev/null || true
  done

  # AND THE REJECTED CANDIDATES MUST STILL BE REJECTED, which is the other
  # half and is what stops someone "improving" the grammar to a friendlier
  # character. Each of these is kept VERBATIM, so each is a legal session
  # name and therefore unusable as a delimiter. `@` was proposed and is in
  # this list for that reason.
  for _d in '@' '~' '%' '^' '+' '=' ',' '/'; do
    tm new-session -d -s "work${_d}api" 2>/dev/null || continue
    _got=$(tm list-sessions -F '#{session_name}' 2>/dev/null \
      | grep -v '^base$' | head -1)
    [ "$_got" = "work${_d}api" ] || fail "tmux no longer keeps [work${_d}api]
verbatim (it stored [$_got]), so '${_d}' may now be safe as a delimiter. That
is not a failure, it is news: the grammar chose '.' and ':' because they were
the ONLY two available, and that measurement has changed."
    tm kill-session -t "=$_got" 2>/dev/null || true
  done
else
  printf 'note %s: no tmux, the delimiter premise is unchecked\n' "$_name"
fi

# --- parsing ---------------------------------------------------------------
# p ADDRESS PART SESS WIN: one form, all three fields, because a parser that
# gets two right and one wrong is the failure that looks like success.
p() {
  _pr=0
  mux_addr_parse "$1" >/dev/null 2>&1 || _pr=$?
  [ "$_pr" -eq 0 ] || fail "[$1] was refused (rc=$_pr) and should parse"
  [ "$MUX_ADDR_PART" = "$2" ] || fail "[$1] partition: got
[$MUX_ADDR_PART] want [$2]"
  [ "$MUX_ADDR_SESS" = "$3" ] || fail "[$1] session: got
[$MUX_ADDR_SESS] want [$3]"
  [ "$MUX_ADDR_WIN" = "$4" ] || fail "[$1] window: got
[$MUX_ADDR_WIN] want [$4]"
}

# A BARE WORD IS A SESSION, which is the whole ergonomic point: it is the
# common case by a wide margin and naming a partition is rare.
p api          ''     api  ''
p 'api:2'      ''     api  2
p work.api     work   api  ''
p 'work.api:2' work   api  2
# `work.` is the whole partition, a deliberate form rather than an accident.
p 'work.'      work   ''   ''
# A trailing colon says "any window", so the window field comes back EMPTY
# rather than as the empty string being treated as a window named ''.
p 'work.api:'  work   api  ''

# THE DOT BINDS TIGHTER THAN THE COLON, and this is the case that pins the
# precedence: `work.api:2` must never read as session `work.api` with window
# `2`. Unreachable in practice (tmux cannot store that name) but the parser
# has to be ordered rather than lucky, because the ONLY thing keeping the
# other reading away is this ordering.
p 'work.api:2' work api 2

# EMPTY IS NOT "global", and every call site depends on it: resolving an
# unspecified partition to the caller's own context is the CALLER's decision,
# since update-env and a window verb want different answers for it.
mux_addr_parse api >/dev/null 2>&1
[ -z "$MUX_ADDR_PART" ] || fail "an unspecified partition came back as
[$MUX_ADDR_PART] rather than empty. A default buried in the parser makes one
of its callers silently wrong, which is why this is the caller's call."

# --- refusals, each with its own reason ------------------------------------
# r ADDRESS FRAGMENT: refused with rc 2, and the message SAYS WHICH, because
# one sentence covering several causes is how a remedy becomes wrong about
# one of them.
r() {
  _rr=0
  _ro=$(mux_addr_parse "$1" 2>&1 >/dev/null) || _rr=$?
  [ "$_rr" -eq 2 ] || fail "[$1] must be refused with 2, got $_rr"
  case $_ro in
  *"$2"*) ;;
  *) fail "[$1] was refused without saying why: want [$2] in [$_ro]" ;;
  esac
}

r ''        'empty address'
r '.api'    'no partition before it'
r 'a.b.c'   'too many dots'
r 'a:b:c'   'too many colons'
# A LEADING DOT IS REFUSED RATHER THAN ACCEPTED as a second spelling of the
# bare form. One spelling per meaning is the reason the old grammar's `:api:2`
# placeholder could go away at all, and accepting both would quietly bring
# back two ways to say one thing.
r '.api'    'a bare name is already a session'

# --- the rendering round-trips --------------------------------------------
# A caller that has to quote an address back must never re-assemble it by
# hand, or the package grows a second spelling of its own grammar.
for _a in api 'api:2' work.api 'work.api:2'; do
  mux_addr_parse "$_a" >/dev/null 2>&1
  [ "$(mux_addr_show)" = "$_a" ] || fail "[$_a] rendered as
[$(mux_addr_show)], so a message quoting an address back would teach a
spelling mux does not accept"
done

pass
