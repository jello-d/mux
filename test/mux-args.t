#!/bin/sh
# test/mux-args.t - the front end's argument parse: an OPTION is an option
# wherever it sits, before the verb or after it. `mux --bare go` is the form
# the README and the man page have always shown, and it used to die on
# "unknown verb: --bare" because the parser took the verb first.
#
# Driven through `mux new`, which writes a file and exits before any tmux or
# socket work, so nothing is started and nothing outside T is touched.
set -eu
_name=mux-args
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/conf" "$T/proj"

# mux ARGS... : run the front end against the scratch overlay, from a scratch
# cwd. $MUX_SHARE is scrubbed so bin/mux self-locates THIS checkout.
mux() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		"$HERE/bin/mux" "$@" 2>&1 )
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
ok create        new lay - -
ok force-after   new --force lay - -
ok force-before  --force new lay - -
# ... and without it, the existing file is still protected.
no no-force "profile exists" new lay - -

# -h / --help are help wherever they appear, and exit 0.
ok help-long  --help
ok help-short -h

# An option that does not apply to the verb is still rejected from EITHER
# position -- moving a flag in front of the verb must not smuggle it past the
# per-verb gate.
no bare-after-gate  "--bare is only for go/resume"  new --bare lay2 - -
no bare-before-gate "--bare is only for go/resume"  --bare new lay2 - -
no persist-gate     "--persist is only for theme"   --persist new lay2 - -

# Unknown options and unknown verbs still fail loud, in either position.
no unknown-opt-before "unknown option: --nosuch" --nosuch new lay3 - -
no unknown-opt-after  "unknown option: --nosuch" new --nosuch lay3 - -
no unknown-verb       "unknown verb: nosuchverb" nosuchverb

# A POSITIONAL is not a verb: the first non-option is the verb, the rest stay
# positional. `new lay4 cyan -` must write lay4, not treat `cyan` as a verb.
ok positional new lay4 cyan -
[ -f "$T/conf/lay4.profile" ] || fail "positional: lay4.layout was not written"
grep -q '^theme   cyan$' "$T/conf/lay4.profile" \
	|| fail "positional: COLOR was not written as the theme"

pass
