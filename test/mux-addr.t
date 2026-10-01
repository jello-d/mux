#!/bin/sh
# test/mux-addr.t - the one address grammar.
#
#     [PARTITION::]SESSION[:WINDOW]
#
# THE FIRST SECTION IS ABOUT TMUX, NOT ABOUT MUX, and it is the load-bearing
# one. This grammar is only unambiguous because neither delimiter can occur
# in the thing it separates, and that is a fact about tmux rather than a
# choice mux made: measured by creating `work<D>api` and reading back what
# tmux stored. IT DEPENDS ON THE VERSION, which is what cost two wrong
# decisions: `.` is structural on 3.4 and 3.6 and VERBATIM on 3.7c, so a
# table from one tmux is a table about that tmux. `:` is the only character
# structural on all three, which is why the partition takes a DOUBLED one.
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

  # THE WHOLE TABLE IS MEASURED AND REPORTED, and the METHOD matters more
  # than the loop: two CI runs of the SAME tmux 3.7c returned different
  # tables, and the only difference was the order the candidates were tried
  # in. The first version read the result back with
  # `list-sessions | head -1` and killed the previous session by the name
  # tmux had STORED, so whenever that kill failed the leftover made `head -1`
  # answer about the wrong session. Order-dependent, and therefore worthless
  # for the one claim this whole grammar rests on.
  #
  # SO THE QUESTION IS ASKED EXACTLY: create `work<D>api`, then look for that
  # LITERAL spelling in the full session list. `grep -qxF` cannot be fooled
  # by a leftover and needs no cleanup to be correct, and crucially it cannot
  # be fooled by tmux's TARGET parsing either: `has-session -t =work:api`
  # would read the colon as a window separator, which is the very thing being
  # measured.
  _structural=
  _verbatim=
  for _d in : '::' . '@' '~' '%' '^' '+' '=' ',' '/'; do
    _n="work${_d}api"
    tm new-session -d -s "$_n" 2>/dev/null || true
    if tm list-sessions -F '#{session_name}' 2>/dev/null \
       | grep -qxF -- "$_n"; then
      _verbatim="$_verbatim $_d"
    else
      _structural="$_structural $_d"
    fi
  done
  printf 'note %s: tmux %s structural:[%s] verbatim:[%s]\n' \
    "$_name" "$(tmux -V)" "$_structural" "$_verbatim"

  # THE GRAMMAR NEEDS EXACTLY ITS OWN TWO, and nothing else about the table
  # matters to correctness: a character that became structural is news, while
  # one of OURS becoming verbatim makes every address in this package
  # ambiguous in silence, which is the failure this exists to catch.
  for _d in : '::'; do
    case " $_structural " in
    *" $_d "*) ;;
    *) fail "tmux $(tmux -V) STORES [work${_d}api] verbatim, so '${_d}' can
appear in a session name and 'work${_d}api' could be two fields or one name.
The grammar's whole premise is that this cannot happen.
  structural: [$_structural]
  verbatim:   [$_verbatim]" ;;
    esac
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
p 'work::api'  work   api  ''
p 'work::api:2' work  api  2
# `work.` is the whole partition, a deliberate form rather than an accident.
p 'work::'     work   ''   ''
# A trailing colon says "any window", so the window field comes back EMPTY
# rather than as the empty string being treated as a window named ''.
p 'work::api:' work   api  ''

# THE DOT BINDS TIGHTER THAN THE COLON, and this is the case that pins the
# precedence: `work::api:2` must never read as session `work::api` with a
# `2`. Unreachable in practice (tmux cannot store that name) but the parser
# has to be ordered rather than lucky, because the ONLY thing keeping the
# other reading away is this ordering.
p 'work::api:2' work api 2

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
r '::api'   'no partition before it'
r 'a::b::c' "too many '::'"
r 'a:b:c'   'too many colons'
# A LEADING DOT IS REFUSED RATHER THAN ACCEPTED as a second spelling of the
# bare form. One spelling per meaning is the reason the old grammar's `:api:2`
# placeholder could go away at all, and accepting both would quietly bring
# back two ways to say one thing.
r '::api'   'a bare name is already a session'

# --- the rendering round-trips --------------------------------------------
# A caller that has to quote an address back must never re-assemble it by
# hand, or the package grows a second spelling of its own grammar.
for _a in api 'api:2' 'work::api' 'work::api:2'; do
  mux_addr_parse "$_a" >/dev/null 2>&1
  [ "$(mux_addr_show)" = "$_a" ] || fail "[$_a] rendered as
[$(mux_addr_show)], so a message quoting an address back would teach a
spelling mux does not accept"
done

pass
