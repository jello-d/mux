#!/bin/sh
# test/mux-resolve.t - lib/mux-resolve_lib: how a NAME becomes a project.
#
# THIS LIB IS THE SHARED SURFACE BETWEEN `go` AND `why`, which is why it has a
# test of its own rather than being covered through either verb. Its own
# header records what it cost when the two did NOT share: `why` derived a
# typed name's root as the current directory, so `mux why NAME` described a
# session `go` would have refused to build. A consumer's test cannot see a
# divergence that both consumers inherit.
#
# THE PARTITION IS THE POINT OF MOST OF THIS FILE. In bin/mux these functions
# read the global `$part`; extracting them made it an ARGUMENT, and that is
# exactly the change a suite can miss: a lib still reaching for a caller's
# variable works in the one file that defines it and answers about nothing
# anywhere else. So the partition is asserted as an argument, in both
# directions, and the refusal when it is absent is asserted too.
set -eu
_name=mux-resolve
. "$(dirname "$0")/harness_lib"

MUX_DIR=$T/conf
MUX_SHARE=$T/share
MUX_STATE=$T/state
MUX_CACHE=$T/cache
export MUX_DIR MUX_SHARE MUX_STATE MUX_CACHE
mkdir -p "$MUX_DIR" "$MUX_SHARE/themes" "$MUX_STATE" "$MUX_CACHE"

# THE DEPENDENCIES ARE SOURCED BY THE CALLER, which this lib's header
# declares and which nothing else enforces: no lib here sources another,
# because a sourced POSIX sh file sees the CALLER'S $0 and cannot locate a
# sibling. Getting this list wrong is the failure the header exists to
# prevent, so this file IS the assertion that the declared list is complete.
. "$HERE/lib/mux-conf_lib"
. "$HERE/lib/mux-paths_lib"
. "$HERE/lib/mux-data_lib"
. "$HERE/lib/mux-scan_lib"
. "$HERE/lib/mux-sessions_lib"
. "$HERE/lib/mux-resolve_lib"

eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }

# --- is_path: which arguments are ROOTS rather than names ------------------
# `mux go ~/src/x` and `mux go x` are different questions, and this predicate
# is the only thing that separates them. A name wrongly read as a path gets
# resolved against the filesystem and vanishes; a path wrongly read as a name
# is looked up in the profile table and vanishes too. Both fail silently.
for p in '~' '~/src' . .. ./x a/b /abs/path; do
  mux_resolve_is_path "$p" \
    || fail "is_path said [$p] is a NAME; it has a path shape, so a session
addressed by its root would be looked up in the profile table instead"
done
for n in mux my-project alpha2 'two words' -dash; do
  mux_resolve_is_path "$n" \
    && fail "is_path said [$n] is a PATH, so mux go would resolve it
against the filesystem rather than the profile table"
done

# --- project_base: the git toplevel, else the directory -------------------
# ONE derivation for both the default session NAME and the default root, so
# `mux new` writes a profile under exactly the name `mux go` later looks for.
# They used to disagree (new took the cwd basename, go the git toplevel's), so
# a `mux new` anywhere but a repo's top level wrote a profile go could never
# find. That is why this is one function and not two call sites.
mkdir -p "$T/plain/below"
eq base-plain "$(mux_resolve_project_base "$T/plain/below")" "$T/plain/below"
mkdir -p "$T/repo/sub"
( cd "$T/repo" && git init -q . && git config user.email t@e \
  && git config user.name t ) >/dev/null 2>&1
if [ -d "$T/repo/.git" ]; then
  # FROM A SUBDIRECTORY, which is the case the bug was about: the answer must
  # be the toplevel, not the cwd.
  _b=$(mux_resolve_project_base "$T/repo/sub")
  case $_b in
  */repo) ;;
  *) fail "project_base from a repo SUBDIRECTORY answered [$_b]; it must
climb to the toplevel, or a session built from a subdirectory takes its name
and root from the wrong place" ;;
  esac
else
  printf 'note %s: no git, toplevel case skipped\n' "$_name"
fi

# --- hash_theme: stable, and derived from the NAME alone ------------------
# A project wears a colour with nothing configured, and the same name must
# land on the same theme on every machine: the value does not matter, only
# that it never moves. Nothing shares this derivation, so a drift here is
# invisible until two boxes disagree about one project.
for t in red blue green; do
  printf 'bar fg=white\n' >"$MUX_SHARE/themes/$t.theme"
done
_h1=$(mux_resolve_hash_theme alpha)
_h2=$(mux_resolve_hash_theme alpha)
eq hash-stable "$_h1" "$_h2"
[ -n "$_h1" ] || fail "hash_theme answered nothing with three themes shipped"
# THE VARIABLE IS THE CASE WORD, not the pattern. Written the other way round
# it works and shellcheck calls it out (SC2194, "this word is constant"),
# correctly: a constant case word is nearly always a mistake, and the padded
# `case " $list " in *" $x "*` idiom this tree uses elsewhere has the LIST in
# the variable, which is the opposite situation.
case $_h1 in
red|blue|green) ;;
*) fail "hash_theme chose [$_h1], which is not one of the themes that exist" ;;
esac
# AND IT IS NOT CONSTANT, which is the half that proves it hashes the name
# rather than answering the first row: with three themes and a handful of
# names, at least two answers must differ.
_set=$(for n in a b c d e f g h; do mux_resolve_hash_theme "$n"; done \
  | sort -u | grep -c .)
[ "$_set" -gt 1 ] || fail "hash_theme gave every name the same theme, so it is
not deriving from the name at all and every project would wear one colour"
# WITH NO THEMES AT ALL it answers nothing rather than failing: a box with an
# empty overlay and no shipped themes is a working mux.
rm -f "$MUX_SHARE/themes"/*.theme
eq hash-no-themes "$(mux_resolve_hash_theme alpha)" ""
for t in red blue green; do
  printf 'bar fg=white\n' >"$MUX_SHARE/themes/$t.theme"
done

# --- typed_roots: THE PARTITION IS AN ARGUMENT ---------------------------
# The recorded session set is keyed by partition, so asking with the wrong one
# answers about another partition's sessions. That is the failure mode the
# extraction could have introduced silently, since the old code read a global
# that happened to hold the right value in the one file that set it.
mux_sess_add alpha "$T/plain" work
mux_sess_add beta "$T/plain/below" other

_r=$(mux_resolve_typed_roots alpha work)
case $_r in
*"a session you had"*"$T/plain"*) ;;
*) fail "typed_roots did not find a recorded session in its OWN partition:
[$_r]" ;;
esac
# THE OTHER PARTITION MUST NOT ANSWER, which is the whole point of the
# argument: `alpha` is recorded in `work` and nowhere else.
_r=$(mux_resolve_typed_roots alpha other)
case $_r in
*"a session you had"*) fail "typed_roots answered about partition 'work'
while asked about 'other'. A partition is an isolation boundary and the set
is keyed by it, so this is the wrong partition's sessions: [$_r]" ;;
esac
# and the reverse, so neither direction is passing by coincidence
_r=$(mux_resolve_typed_roots beta other)
case $_r in
*"a session you had"*"$T/plain/below"*) ;;
*) fail "typed_roots found nothing for beta in 'other', where it IS
recorded: [$_r]" ;;
esac

# --- AND AN ABSENT PARTITION REFUSES, rather than guessing --------------
# `${2:?}` is deliberate. A caller that forgets the argument would otherwise
# get the EMPTY partition, which `mux_sess_file` resolves to a real file name,
# so the answer would be about a set nobody keeps: plausible, wrong, silent,
# which is this package's signature failure.
_rc=0
( mux_resolve_typed_roots alpha ) >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] || fail "typed_roots with NO partition answered successfully.
An empty partition names a real-looking set file, so the caller would get a
confident answer about a set nobody keeps."
_rc=0
( mux_resolve_map_lookup alpha ) >/dev/null 2>&1 || _rc=$?
[ "$_rc" -ne 0 ] || fail "map_lookup with no partition answered successfully"

pass
