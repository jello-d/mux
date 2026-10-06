#!/bin/sh
# test/mux-migrate-profiles.t - the one-shot converter from the pre-rename
# `<name>.layout` world to today's profile row plus `layouts/<name>.layout`.
#
# WRITTEN BECAUSE THE HELPER HAD NEVER EXECUTED. The suite mentioned
# `mux-migrate-profiles` in exactly one place: inside the failure MESSAGE the
# profile parser prints when it meets retired `include` syntax. So 113 lines
# that MOVE and REWRITE a user's configuration had no test, which is the same
# gap `mux setup` turned out to have and the same stake: the failure that
# matters is not "the migration did not happen", it is "the migration ate
# something".
#
# THE DRY RUN IS THE LOAD-BEARING HALF, because this is a verb somebody runs
# once, on a config they cannot reconstruct, and the plan is the only thing
# they get to read first. Every case here asserts what is NOT written.
set -eu
_name=mux-migrate-profiles
. "$(dirname "$0")/harness_lib"

CONF=$T/conf
mkdir -p "$CONF"
mig() { env -u MUX_SHARE MUX_DIR="$CONF" \
  "$HERE/libexec/mux-migrate-profiles" "$@" 2>&1; }
rc() { _r=0; mig "$@" >/dev/null 2>&1 || _r=$?; echo "$_r"; }
row() { awk -v n="$1" '$1==n{$1="";sub(/^ +/,"");print;exit}' \
  "$CONF/profiles" 2>/dev/null; }
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }
has() { case "$1" in *"$2"*) ;; *) fail "$3: want [$2] in [$1]" ;; esac; }

# --- an unknown argument is a usage error, before anything is read ---------
eq bad-arg-rc "$(rc --nope)" 2
has "$(mig --nope)" "usage: mux migrate-profiles" bad-arg-usage

# --- nothing to do says so, and is not an error ---------------------------
eq empty-rc "$(rc)" 0
has "$(mig)" "nothing to migrate" empty-says-so

# --- A DRY RUN WRITES NOTHING --------------------------------------------
# Both spellings: bare, and the explicit flag. Asserted on the FILES rather
# than on the output, because a plan that prints perfectly and also acts is
# exactly the defect a dry run exists to make impossible.
printf 'theme cyan\nagent claude\n' >"$CONF/api.layout"
for _flag in '' --dry-run; do
  _o=$(mig $_flag)
  has "$_o" "conv  api -> theme=cyan agent=claude" "plan-$_flag"
  [ -e "$CONF/api.layout" ] \
    || fail "a dry run ($_flag) MOVED the original away"
  [ ! -e "$CONF/profiles" ] \
    || fail "a dry run ($_flag) wrote the profile table"
  [ ! -e "$CONF/api.layout.bak" ] \
    || fail "a dry run ($_flag) took a backup, so it acted"
done

# --- applying: identity keys become a ROW --------------------------------
eq apply-rc "$(rc --apply)" 0
eq row-written "$(row api)" "theme=cyan agent=claude"
[ -f "$CONF/api.layout.bak" ] \
  || fail "the original was not kept as api.layout.bak, so an apply that got
something wrong cannot be undone"
[ ! -e "$CONF/api.layout" ] || fail "the original was left in place, so the
retired file still shadows the row that replaced it"

# --- IDEMPOTENT: a second run skips what it already did -------------------
# This is a verb people re-run because they are not sure it worked. A second
# pass must not re-convert a name whose row already exists, which would
# overwrite edits made since.
printf 'theme cyan\nagent claude\n' >"$CONF/api.layout"
sed -i 's/theme=cyan/theme=green/' "$CONF/profiles"
_o=$(mig --apply)
has "$_o" "skip  api: already migrated" second-run-skips
eq second-run-kept-edit "$(row api)" "theme=green agent=claude"

# --- ARRANGEMENT SPLITS OUT, and the row points at it --------------------
# The whole reason for the rename: identity in a profile, arrangement in a
# layout. A `.layout` holding both becomes one of each, and the row's
# `layout=` is what still ties them together.
rm -f "$CONF/profiles" "$CONF"/*.layout.bak
printf 'theme slate\nwindow code\npane agent\nbottom 5-10\n' \
  >"$CONF/web.layout"
_o=$(mig --apply)
has "$_o" "split web -> row + layouts/web.layout" split-reported
eq split-row "$(row web)" "theme=slate layout=web"
[ -f "$CONF/layouts/web.layout" ] || fail "no layout file was written"
for _d in 'window code' 'pane agent' 'bottom 5-10'; do
  grep -qxF -- "$_d" "$CONF/layouts/web.layout" \
    || fail "the split layout lost [$_d]: [$(cat "$CONF/layouts/web.layout")]"
done
# ... and the IDENTITY key does NOT follow it into the layout, or the split
# would have made two homes for one fact rather than one each.
grep -q '^theme' "$CONF/layouts/web.layout" \
  && fail "an identity key followed the arrangement into the layout"

# --- `default` is SUPERSEDED, not carried over ---------------------------
# The shipped defaults replaced it, so converting it would reinstate whatever
# the old file happened to say as an explicit override of mux's own answer.
rm -f "$CONF/profiles" "$CONF"/*.layout.bak
printf 'window code\npane agent\n' >"$CONF/default.layout"
_o=$(mig --apply)
has "$_o" "note  default: superseded" default-noted
[ -z "$(row default)" ] || fail "default was converted to a row, reinstating
the old file as an explicit override of the shipped defaults"
[ -f "$CONF/default.layout.bak" ] \
  || fail "default.layout was not backed up before being set aside"

# --- a name with nothing left to say is DROPPED --------------------------
# Everything it held is derivable now, so a row would be a no-op the user has
# to read and wonder about.
rm -f "$CONF/profiles" "$CONF"/*.layout.bak
printf 'include shapes/code\n' >"$CONF/plain.layout"
_o=$(mig --apply)
has "$_o" "drop  plain: everything about it is derivable now" dropped
[ -z "$(row plain)" ] || fail "a derivable name still got a row: [$(row plain)]"

# --- COMMENTS ARE REPORTED, because a row cannot hold one ----------------
# The one thing silently lost by the conversion, so it is named per file with
# the path to the prose. Saying "some files had comments" would be useless.
rm -f "$CONF/profiles" "$CONF"/*.layout.bak
printf '# why this session exists\ntheme cyan\n' >"$CONF/noted.layout"
_o=$(mig --apply)
has "$_o" "these carried COMMENTS" comments-reported
has "$_o" "noted" comments-named
has "$_o" "noted.layout.bak" comments-point-at-the-prose

pass
