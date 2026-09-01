#!/bin/sh
# test/mux-args.t - the front end's argument parse: an OPTION is an option
# wherever it sits, before the verb or after it. `mux --bare go` is the form
# the README and the man page have always shown, and it used to die on
# "unknown verb: --bare" because the parser took the verb first.
#
# Driven through `mux new`, with tmux stubbed in $T/bin so no server starts and
# no real session is touched. Nothing outside T.
set -eu
_name=mux-args
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
case "$*" in
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
PATH=$T/bin:$PATH; export PATH

# mux ARGS... : run the front end against the scratch overlay, from a scratch
# cwd. $MUX_SHARE is scrubbed so bin/mux self-locates THIS checkout.
mux() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" "$@" 2>&1 )
}
# ok LABEL ARGS... : the run must succeed.
ok() {
	_l=$1; shift
	mux "$@" >/dev/null || fail "$_l: \`mux $*\` should have succeeded"
}
# no LABEL WANT ARGS... : the run must fail, mentioning WANT.
no() {
	_l=$1 _w=$2; shift 2
	_o=$(mux "$@") && fail "$_l: \`mux $*\` should have failed"
	case $_o in
	*"$_w"*) ;;
	*) fail "$_l: want [$_w] in output, got [$_o]" ;;
	esac
}

# --force before the verb and after it are the same command. The first write
# creates the profile; both --force runs must then clobber it.
ok create        new lay
ok force-after   new --force lay
ok force-before  --force new lay
# ... and without it, the existing file is still protected.
no no-force "already has a profile" new lay

# -h / --help are help wherever they appear, and exit 0.
ok help-long  --help
ok help-short -h

# An option that does not apply to the verb is still rejected from EITHER
# position -- moving a flag in front of the verb must not smuggle it past the
# per-verb gate. (--bare IS valid for new, which builds; --persist is not.)
no persist-gate  "--persist is only for theme"  --persist new lay2
no persist-gate2 "--persist is only for theme"  new --persist lay2

# Unknown options and unknown verbs still fail loud, in either position.
no unknown-opt-before "unknown option: --nosuch" --nosuch new lay3
no unknown-opt-after  "unknown option: --nosuch" new --nosuch lay3
no unknown-verb       "unknown verb: nosuchverb" nosuchverb

# A POSITIONAL is not a verb: the first non-option is the verb, the rest stay
# positional. `go lay4 lay` must treat lay4 as the NAME and lay as the PROFILE,
# not read either as a verb.
ok positional go lay4 lay
grep -q '^lay ' "$T/conf/profiles" || fail "positional: no row for lay"

pass
