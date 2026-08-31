#!/bin/sh
# test/mux-new.t - `mux new` and `mux go` must derive the session name the SAME
# way. new used to take the cwd basename while go took the git toplevel
# basename, so a `mux new` run anywhere but a repo's top level wrote a profile
# `mux go` would never find.
#
# `mux new` writes a file and exits before any tmux or socket work, so this
# starts no server. Scratch repo, scratch overlay; nothing outside T.
set -eu
_name=mux-new
. "$(dirname "$0")/lib.sh"

command -v git >/dev/null 2>&1 || { printf 'skip %s (no git)\n' "$_name"
	exit 0; }

mkdir -p "$T/conf" "$T/myrepo/deep/sub" "$T/plaindir/sub"
git init -q "$T/myrepo" 2>/dev/null || fail "could not make a scratch repo"

# new DIR ARGS... : run `mux new` from DIR against the scratch overlay.
# GIT_CEILING_DIRECTORIES stops the toplevel search at T, so a repo ABOVE the
# scratch dir (this checkout, if /tmp were ever inside one) cannot leak in.
new() {
	_d=$1; shift
	( cd "$_d" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		GIT_CEILING_DIRECTORIES="$T" "$HERE/bin/mux" new "$@" ) \
		>/dev/null || fail "mux new in $_d exited $?"
}
# root_of NAME -> the root line of NAME.profile, or empty if it has none.
root_of() {
	awk '$1=="root"{print $2; exit}' "$T/conf/$1.profile"
}

# --- in a repo: the profile is named for the REPO, wherever you run it -------
new "$T/myrepo/deep/sub"
[ -f "$T/conf/myrepo.profile" ] \
	|| fail "from a repo subdir, new wrote $(ls "$T/conf") not myrepo.profile"
# ... and rooted at the repo, not at the subdir it was run from, so the
# session `mux go` builds from it is the same session either way.
eq_root=$(root_of myrepo)
[ "$eq_root" = "$T/myrepo" ] \
	|| fail "root: got [$eq_root] want [$T/myrepo]"

# Running it again from the TOP of the same repo must resolve to the same
# profile name -- that is the whole point -- so it hits the exists guard.
_out=$( ( cd "$T/myrepo" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
	GIT_CEILING_DIRECTORIES="$T" "$HERE/bin/mux" new ) 2>&1 ) \
	&& fail "second new should have refused to clobber"
case $_out in
*"profile exists"*) ;;
*) fail "top-of-repo new resolved to a DIFFERENT name: [$_out]" ;;
esac

# --- outside a repo: the cwd, as before ------------------------------------
new "$T/plaindir/sub"
[ -f "$T/conf/sub.profile" ] \
	|| fail "outside a repo, new should name the profile for the cwd"
eq_root=$(root_of sub)
[ "$eq_root" = "$T/plaindir/sub" ] \
	|| fail "non-repo root: got [$eq_root] want [$T/plaindir/sub]"

# --- explicit arguments still win ------------------------------------------
new "$T/myrepo/deep/sub" chosen - "$T/plaindir"
[ -f "$T/conf/chosen.profile" ] || fail "an explicit NAME was not honoured"
eq_root=$(root_of chosen)
[ "$eq_root" = "$T/plaindir" ] || fail "an explicit ROOT was not honoured"

# '-' still means NO root line, so the profile stays portable.
new "$T/myrepo" rootless - -
[ -f "$T/conf/rootless.profile" ] || fail "rootless layout was not written"
[ -z "$(root_of rootless)" ] || fail "'-' should write no root line"

pass
