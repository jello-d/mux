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
. "$(dirname "$0")/harness_lib"

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
# position: moving a flag in front of the verb must not smuggle it past the
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

# --- `resume` is a VERB now, not a spelling of `go --resume` ----------------
# It used to be an alias that set cmd=go and the --resume flag, and internally
# the flag was ALSO carried as cmd=resume. Renaming the session rebuild onto
# `resume` collided with both, so the flag now lives only in $resume. These
# pin the two apart: the verb owns --list, and the flag is rejected everywhere
# except go.
#
# The verb used to take NO arguments; since 0.56 it takes an optional
# PARTITION and SESSION. So the arity assertion moved to the real boundary
# (three is too many) and the first argument is checked as a PARTITION:
# positionally, never by guessing which of the words names one.
no resume-arity  "resume [PARTITION [SESSION]]" resume a b c
no resume-part   "no such partition"            resume nosuchpartition::
# A SYNTACTICALLY INVALID name is a different refusal from an UNKNOWN one, and
# the case above cannot tell them apart: `nosuchpartition` is a perfectly legal
# DNS label, so it reaches `mux_ctx_valid` and passes, and the refusal comes
# from the known-set check further down. Measured while guarding the parser: a
# mutation that deleted the VALIDATION entirely left this file green.
#
# A partition name becomes a socket NAME and a state DIRECTORY, so the
# validation is an identity guard rather than input hygiene: on a
# case-insensitive filesystem `Work` and `work` are two partitions to mux and
# one directory to the OS, which is why the validator enumerates its
# characters instead of using a range.
no resume-badname "not a partition name" resume 'Bad Name::'
no resume-flag   "--resume is only for go"   resume --resume
no resume-flag2  "--resume is only for go"   new --resume lay5
no list-gate     "--list is only for resume" kill --list lay4
# These two shipped UNGATED and were found by the class audit at the bottom of
# this file; the per-flag cases are here so each arm is individually killable,
# where the audit only sees a flag with no gate at all.
no attachonly-gate "--attach-only is only for go"    kill --attach-only lay4
no nowaitenv-gate  "--no-wait-env is only for resume" kill --no-wait-env lay4

# The flag itself still works, in either position: the old behaviour did not
# go away with the verb, it just has one spelling now.
ok go-resume-after  go --resume lay4
ok go-resume-before --resume go lay4

# --- EVERY FLAG THAT SETS A VARIABLE MUST HAVE A PER-VERB GATE -------------
# Asked as a CLASS rather than per flag, which is the only version that can
# catch the regression that matters: a flag added to the option loop and
# never gated parses on every verb and is then silently IGNORED, and no
# mutation record can see a MISSING arm. That is the defect this package
# already records for `mux agent status --all` (assigned, set by the flag,
# never read): a flag that parses and does nothing is worse than a missing
# one, because the caller believes it asked for something.
#
# IT FOUND TWO ON ITS FIRST RUN, 2026-10-05: `--attach-only` and
# `--no-wait-env`. Measured, `mux kill --attach-only x` and
# `mux ls --no-wait-env` were both accepted in silence while the identical
# `mux kill --persist x` was refused. The sharpest was --no-wait-env, whose
# whole purpose is to override the readiness wait: typed on `go` it did
# nothing and said nothing, which reads as the override being broken.
#
# BOTH LISTS COME OUT OF THE SOURCE. A second copy here would drift in
# exactly the direction this is checking for, which is what `mux check`
# learned about its own key list.
# INDENTATION-AGNOSTIC ON PURPOSE. This used to require exactly four leading
# spaces, and the case-indent sweep made it six: the scrape found NOTHING and
# the audit below would have passed about the empty set, which is why that
# vacuity guard exists. Match the shape, never the column.
_flags=$(awk '/while \[ "\$#" -gt 0 \]; do/{p=1} p && /^[[:space:]]*esac$/{p=0}
 p && /^[[:space:]]*-/ && /=1; shift ;;/ {
   match($0, /[^[:space:]][^)]*\)/); a=substr($0, RSTART, RLENGTH-1)
   split(a, f, "|"); print f[1] }' "$HERE/bin/mux" | sort -u)
# THE TWO SCRAPES READ TWO FILES NOW, and that is the split the parser took
# on 2026-10-05 rather than an accident: the option LOOP stayed in bin/mux,
# because a function's `shift` cannot move the caller's argv, while the GATES
# moved to lib/mux-args_lib, which reads only `$#` and the flag variables.
# When they moved, this audit failed LOUDLY with every flag reported ungated,
# which is the diff-and-vacuity shape working: a selector whose input has
# moved reads as "nothing is gated" rather than quietly scanning an empty set.
_gated=$(sed -n 's/.*"mux: \(--[a-z-]*\) is only for.*/\1/p' \
  "$HERE/lib/mux-args_lib" | sort -u)
# VACUITY FIRST: a scrape that matched nothing would make the comparison
# below pass about the empty set, for ever.
[ "$(printf '%s\n' "$_flags" | grep -c .)" -ge 8 ] \
  || fail "the flag scrape found $(printf '%s\n' "$_flags" | grep -c .) flags,
which cannot be right: the option loop has carried at least eight that set a
variable since 0.56. The scrape has stopped matching the loop's shape."
# A GENUINELY UNIVERSAL FLAG WOULD GO HERE, with its reason, and there are
# none today: every flag the loop records is verb-specific. `-h`, `-V` and
# `--` are not in the list at all, because they act and exit rather than
# setting a variable for a verb to read.
_ungated=
for _f in $_flags; do
  printf '%s\n' "$_gated" | grep -qxF -- "$_f" || _ungated="$_ungated $_f"
done
[ -z "$_ungated" ] || fail "flag(s) with no per-verb gate:$_ungated
Each parses on EVERY verb and is then silently ignored, so a caller that
typed it believes it asked for something. Add a \`case \$cmd in\` block
beside the others naming the verb(s) it applies to, or if it is genuinely
universal, say so in this test with the reason."

pass
