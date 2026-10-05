#!/bin/sh
# test/mux-why.t - `mux why` must explain what `mux go` would actually DO.
#
# It is the verb you reach for when mux surprised you, so an answer that
# disagrees with the thing it explains is worse than no answer at all. It used
# to disagree constantly: the root of a TYPED name was derived as the CURRENT
# DIRECTORY, consulting neither the session set nor the discovery map: the two
# sources `go` actually resolves from. So `mux why NAME` reported a confident
# root for a name resolving somewhere else entirely, for an AMBIGUOUS name that
# `go` refuses outright, and for a name nothing knew at all.
#
# It also credited the context-command for a token that came from the baseline,
# by asking whether one was CONFIGURED rather than whether it had ANSWERED.
#
# So the assertions are about AGREEMENT with go, and about provenance being
# reported from what happened rather than re-derived.
set -eu
_name=mux-why
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/conf/partitions" "$T/cache"
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

# Two repos sharing a basename, plus two that do not: the work partition's
# actual shape (PlatformOS under both the tree root and vendor-repos/).
for d in src/dup src/nested/dup src/solo src/other; do
  mkdir -p "$T/$d/.git"
done
printf 'scan %s/src 3\n' "$T" >"$T/conf/partitions/work.partition"
printf '#!/bin/sh\necho work\n' >"$T/conf/cc"; chmod +x "$T/conf/cc"
printf 'context-command cc\n' >"$T/conf/config"

run() {
  _d=$1; shift
  ( cd "$_d" && env -u MUX_SHARE -u TMUX -u TMUX_PANE \
    MUX_DIR="$T/conf" MUX_CACHE="$T/cache" PATH="$T/bin:$PATH" \
    "$HERE/bin/mux" "$@" 2>&1 )
}
has() {  # OUTPUT WANT LABEL
  case "$1" in
  *"$2"*) ;;
  *) fail "$3: want [$2] in: $1" ;;
  esac
}
no_has() {
  case "$1" in
  *"$2"*) fail "$3: did NOT want [$2] in: $1" ;;
  esac
}
# One field's line. `where` legitimately says "the project you are in" on every
# run, so a negative assertion about the ROOT has to be scoped to root's line.
line() { printf '%s\n' "$1" | awk -v k="$2" '$1==k{print; exit}'; }
run "$T" scan >/dev/null 2>&1 || true

# --- a typed name resolves through the MAP, not the cwd --------------------
# Run from a directory that is NOT the answer, so a cwd-derived root is
# obviously wrong rather than accidentally right.
_o=$(run "$T" why solo); _r=$(line "$_o" root)
has "$_r" "$T/src/solo" "typed name: root is not the map's answer"
has "$_r" "the discovery map" "typed name: provenance not the map"
no_has "$_r" "the project you are in" "typed name: root still claims the cwd"

# --- an AMBIGUOUS name: why must refuse to name one, exactly as go does ----
_o=$(run "$T" why dup)
has "$_o" "(ambiguous)" "ambiguous: named a single root anyway"
has "$_o" "2 projects share this name" "ambiguous: no count"
has "$_o" "REFUSES" "ambiguous: did not say go would refuse"
has "$_o" "$T/src/dup" "ambiguous: first candidate not listed"
has "$_o" "$T/src/nested/dup" "ambiguous: second candidate not listed"
# ... and go really does refuse, so the two agree.
_g=$(run "$T" go dup) && fail "go should refuse an ambiguous name"
has "$_g" "ambiguous" "go: no ambiguity refusal"

# --- a name NOTHING knows: likewise a refusal, not a fabricated root -------
# `|| true` because `why` EXITS 3 on a name nothing knows, and an unguarded
# command substitution takes the whole file down silently under `set -e`: it
# did exactly that when the code was introduced, and the only symptom was this
# test vanishing from the runner's output.
_o=$(run "$T" why nosuchproject || true)
has "$_o" "(unknown)" "unknown: invented a root"
has "$_o" "REFUSES" "unknown: did not say go would refuse"
# The report is not the whole answer: the exit code has to say so too, or a
# caller has to parse English to learn that a name resolved to nothing.
_wrc=0; run "$T" why nosuchproject >/dev/null 2>&1 || _wrc=$?
[ "$_wrc" = 3 ] \
  || fail "why on a name nothing knows must exit 3 (mux's standard
unknown-name code), got $_wrc"
_wrc=0; run "$T" why dup >/dev/null 2>&1 || _wrc=$?
[ "$_wrc" != 3 ] \
  || fail "why exited 3 for a name that IS known (ambiguously). 3 means
the name resolves to nothing, and an ambiguous name resolves to too much"
_g=$(run "$T" go nosuchproject) && fail "go should refuse an unknown name"

# --- a profile that DECLARES a root wins, and the map is not consulted -----
# This mirrors go's `hasroot` short-circuit: the declaration already answered,
# so even an ambiguous NAME is unambiguous once a profile pins it.
printf 'dup root=%s/src/other\n' "$T" >"$T/conf/profiles"
_o=$(run "$T" why dup); _r=$(line "$_o" root)
has "$_r" "$T/src/other" "declared root: not honoured"
has "$_r" "declared" "declared root: provenance not 'declared'"
no_has "$_o" "(ambiguous)" "declared root: map consulted anyway"
rm -f "$T/conf/profiles"

# --- a PATH argument is not a session name ---------------------------------
# go derives a name from a path exactly as it does for a bare `mux go`; why
# used to print the whole path in the `name` field.
_o=$(run "$T" why "$T/src/solo"); _r=$(line "$_o" root)
has "$_r" "the path you gave" "path: provenance"
case "$_o" in
*"name      solo"*) ;;
*) fail "path: name not derived to the basename: $_o" ;;
esac

# --- a bare `mux why` still answers about where you are standing -----------
_o=$(run "$T/src/other" why); _r=$(line "$_o" root)
has "$_r" "the project you are in" "bare: lost the cwd answer"
has "$_r" "$T/src/other" "bare: wrong directory"

# --- the session set OUTRANKS the map, and says so -------------------------
# It is the only source that knows where a profile-less `mux go` was rooted,
# so it must win, and be named, not passed off as the map.
printf 'solo\t%s/src/other\n' "$T" >"$T/state/sessions.work"
_o=$(run "$T" why solo); _r=$(line "$_o" root)
has "$_r" "a session you had" "session set: not credited"
has "$_r" "$T/src/other" "session set: did not outrank the map"
rm -f "$T/state/sessions.work"

# --- provenance of the CONTEXT comes from what happened, not what is set ---
# The failing case is northwood's exactly: a context-command configured against
# a severance that does not implement the verb yet.
_o=$(run "$T" why); has "$_o" "from context-command" "ctx: answering command"

printf '#!/bin/sh\nexit 2\n' >"$T/conf/cc"
_o=$(run "$T" why)
has "$_o" "context-command FAILED" "ctx: a FAILED command still credited"
has "$_o" "global" "ctx: a failed command should leave the baseline token"

printf '#!/bin/sh\nexit 0\n' >"$T/conf/cc"
_o=$(run "$T" why)
has "$_o" "named none" "ctx: a DECLINING command still credited"

rm -f "$T/conf/config"
_o=$(run "$T" why)
has "$_o" "no context-command" "ctx: none configured"

# --- THE REPORT IS A LAZILY SOURCED LIB (2026-10-05) ----------------------
# 243 lines moved to lib/mux-why_lib, and the two properties that split
# carries are invisible to every assertion above: they are about the MOVE,
# not about the report.
#
# A SCRATCH PREFIX, because asserting either one means interfering with the
# lib, and doing that in the checkout would reach every other session on the
# box as well as this test. bin/mux self-locates from $0, with no env seam,
# so the only way to give it a different lib tree is to stand it in one:
# bin/ and lib/ are COPIES (one file gets removed, another poisoned) and
# libexec/share are links, since nothing resolves those through readlink.
_P=$T/prefix
mkdir -p "$_P/bin"
cp "$HERE/bin/mux" "$_P/bin/mux"
cp -R "$HERE/lib" "$_P/lib"
ln -s "$HERE/libexec" "$_P/libexec"
ln -s "$HERE/share" "$_P/share"
runp() {
  ( cd "$T" && env -u MUX_SHARE -u TMUX -u TMUX_PANE \
    MUX_DIR="$T/conf" MUX_CACHE="$T/cache" PATH="$T/bin:$PATH" \
    "$_P/bin/mux" "$@" 2>&1 )
}
# The control FIRST: this prefix answers at all, or the two cases below
# would pass for the wrong reason.
_o=$(runp why) || fail "the scratch prefix cannot run why: $_o"
has "$_o" "where" "prefix: the control report did not render"

# 1. IT IS SOURCED ONLY FOR `why`, which is why the branch sources it rather
# than the top of the file: the front end is parsed on every invocation, and
# a verb nobody called must not cost a lib.
#
# A POISONED LIB IS WHAT MEASURES IT: a file that kills the shell when read,
# so another verb still answering proves it was never read. `mux ls` is the
# probe because it runs nearly the whole file before dispatching, which is
# the range an eager source would live in. Measured: a source placed just
# ABOVE the why branch is not caught here and is also not a regression, since
# every verb that exits earlier still never reads it.
printf 'echo POISONED >&2\nexit 9\n' >"$_P/lib/mux-why_lib"
_o=$(runp ls) || fail "mux ls died with a poisoned why lib, so the lib is
sourced EAGERLY and every verb now pays for it: $_o"
no_has "$_o" POISONED "mux ls read the why lib"
_rc=0; _o=$(runp why) || _rc=$?
[ "$_rc" -eq 9 ] || fail "why did not read the lib at all (rc=$_rc), so the
poison test above proves nothing"

# 2. A MISSING LIB IS LOUD. `mux why` is a whole verb, so a `.` of an absent
# file would otherwise fail with the SHELL's wording and a code nobody
# chose, which this package calls an incomplete install and says so.
rm -f "$_P/lib/mux-why_lib"
_rc=0; _o=$(runp why) || _rc=$?
has "$_o" "mux-why_lib missing" "a lost why lib must name itself"
[ "$_rc" -eq 1 ] || fail "a lost why lib exited $_rc, want 1. An install
missing a file is this package's exit 1, and a verb that cannot run must not
answer 0 or borrow the shell's code."

pass
