#!/bin/sh
# test/mux-new.t - `mux new NAME` and `mux go` must agree on what "the project"
# is. `new` used to take the cwd basename while `go` took the git toplevel
# basename, so a `mux new` run anywhere but a repo's top level bound a name to
# the wrong directory and `mux go` would never find it.
#
# That parity is now load-bearing in a second way: `new` writes a row only when
# the name is NOT what the directory derives, so a disagreement between the two
# derivations would write spurious rows for names that needed none.
#
# tmux is stubbed, so no server starts. Scratch repo, scratch overlay.
set -eu
_name=mux-new
. "$(dirname "$0")/lib.sh"

command -v git >/dev/null 2>&1 || { printf 'skip %s (no git)\n' "$_name"
	exit 0; }

mkdir -p "$T/bin" "$T/conf" "$T/myrepo/deep/sub" "$T/plaindir/sub"
git init -q "$T/myrepo" 2>/dev/null || fail "could not make a scratch repo"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; export TMUXLOG
PATH=$T/bin:$PATH; export PATH

# mux DIR ARGS... : GIT_CEILING_DIRECTORIES stops the toplevel search at T, so
# a repo ABOVE the scratch tree cannot leak in.
mux() {
	_d=$1; shift
	( cd "$_d" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" GIT_CEILING_DIRECTORIES="$T" \
		"$HERE/bin/mux" "$@" ) 2>&1
}
# built -> the session name of the last new-session call.
built() {
	awk '/^new-session /{for(i=1;i<=NF;i++) if($i=="-s") print $(i+1)}' \
		"$TMUXLOG" | head -1
}
rooted() {
	awk '/^new-session /{for(i=1;i<=NF;i++) if($i=="-c") print $(i+1)}' \
		"$TMUXLOG" | head -1
}

# --- a NAME is required: `new` exists to name something ---------------------
mux "$T/myrepo" new >/dev/null 2>&1 && fail "bare `mux new` should be refused"

# --- `new` names THIS directory, even inside a repo -------------------------
# The one place it deliberately differs from bare `go`: without this a
# subdirectory could never have a session of its own, because the binding would
# swallow the whole enclosing repo.
: >"$TMUXLOG"
mux "$T/myrepo/deep/sub" new alias1 >/dev/null || fail "mux new alias1 failed"
[ "$(rooted)" = "$T/myrepo/deep/sub" ] \
	|| fail "new rooted at [$(rooted)], want $T/myrepo/deep/sub"
grep -q "^alias1 .*root=$T/myrepo/deep/sub" "$T/conf/profiles" \
	|| fail "new bound alias1 wrongly: $(cat "$T/conf/profiles")"

# --- bare `mux go` still derives the REPO, from any subdirectory ------------
# The subdirectory binding above must not hijack the enclosing project: the
# root-to-name lookup is an EXACT match, never a walk up the tree.
: >"$TMUXLOG"
mux "$T/myrepo/deep/sub" go >/dev/null || fail "bare go in a subdir failed"
[ "$(built)" = myrepo ] || fail "bare go built [$(built)], want myrepo"
[ "$(rooted)" = "$T/myrepo" ] || fail "bare go rooted at [$(rooted)]"
: >"$TMUXLOG"
mux "$T/myrepo" go >/dev/null || fail "bare go at the repo top failed"
[ "$(built)" = myrepo ] || fail "top-of-repo go built [$(built)], want myrepo"

# --- a name the directory already derives needs NO row ----------------------
: >"$TMUXLOG"
mux "$T/myrepo" new myrepo >/dev/null || fail "mux new myrepo failed"
grep -q '^myrepo ' "$T/conf/profiles" 2>/dev/null \
	&& fail "new wrote a row for a name the directory already derives"

# --- outside a repo, the project is the cwd ---------------------------------
: >"$TMUXLOG"
mux "$T/plaindir/sub" go >/dev/null || fail "bare go outside a repo failed"
[ "$(built)" = sub ] || fail "outside a repo, go built [$(built)], want sub"
[ "$(rooted)" = "$T/plaindir/sub" ] || fail "non-repo root: [$(rooted)]"

pass
