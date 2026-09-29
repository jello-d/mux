#!/bin/sh
# test/mux-homebrew.t - the Homebrew formula, held against the source it claims
# to install.
#
# WHY THIS FILE IS THE REASON THE FORMULA LIVES IN THIS REPO. A formula pins a
# VERSION, so it is a second copy of `MUX_VERSION`, and this project's standing
# rule is that a second copy of a fact needs a check rather than vigilance. In a
# separate `homebrew-mux` tap that check cannot be written at all: the formula
# would sit in a repo holding no copy of the source and gated by none of this
# suite. Here it is four assertions.
#
# THE FAILURE IT EXISTS TO CATCH IS SILENT AND SLOW. Cut a release, forget this
# file, and `brew install mux` keeps installing the old one forever while every
# other check on both boxes reads green. Nobody finds that except a stranger on
# a Mac, which is the one reader who cannot tell it from mux simply being stale.
#
# THE INTENDED RELEASE ORDER, which this test enforces rather than documents:
#
#     bump MUX_VERSION, commit   ->  git tag vX.Y  ->  update the formula
#
# The window between the tag and the formula bump is RED ON PURPOSE. That is the
# reminder, and the fix is two lines (tag and revision).
#
# THE GIT-FREE ASSERTIONS COME FIRST and the tag checks last, which is not
# cosmetic: `setup.sh test` must work from an unpacked tarball, and the mutation
# driver copies the tree WITHOUT `.git`, so anything sitting after that skip is
# unreachable to the corpus. The first draft had them the other way round and
# every record aimed at this file reported SURVIVED for that reason alone.
# Whichever part is skipped says so on stderr, because a skip must never
# quietly stand in for coverage.
set -eu
_name=mux-homebrew
. "$(dirname "$0")/harness_lib"

F=$HERE/HomebrewFormula/mux.rb
[ -r "$F" ] || fail "$F is missing: the tap lives in this repo, so the formula
is part of the package rather than an optional extra"

# --- it is valid Ruby -----------------------------------------------------
# The cheapest floor available, and the one failure mode a text assertion
# cannot see: a formula that does not parse installs nothing, and the error
# surfaces on a stranger's Mac rather than here. `brew audit --strict` is the
# real check and needs brew; this needs only ruby, and skips without it.
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$F" >/dev/null 2>&1 || fail "HomebrewFormula/mux.rb is not valid
Ruby: $(ruby -c "$F" 2>&1 | head -3)"
fi

# --- the version the formula pins ----------------------------------------
# Scraped rather than restated, for the same reason `mux check` derives its key
# list from the fragment: a second hand-written copy in the test would agree
# with a stale formula and report a green suite about it.
_ftag=$(sed -n 's/^ *tag: *"\([^"]*\)".*/\1/p' "$F" | head -1)
_frev=$(sed -n 's/^ *revision: *"\([^"]*\)".*/\1/p' "$F" | head -1)
[ -n "$_ftag" ] || fail "no \`tag:\` found in the formula; the scrape is broken
and every assertion below would pass vacuously"
[ -n "$_frev" ] || fail "no \`revision:\` found in the formula. The git-tag form
pins integrity with the revision instead of a tarball checksum, so dropping it
is dropping the only thing that says WHICH commit this release is"

_mv=$(sed -n 's/^MUX_VERSION=\(.*\)/\1/p' "$HERE/bin/mux" | head -1)
[ -n "$_mv" ] || fail "MUX_VERSION not found in bin/mux"

# --- the caveats carry the steps brew cannot take ------------------------
# brew INSTALLS BY COPYING, so `setup.sh` never runs and neither do its two
# notices. Without these lines a Homebrew user gets the exact state mux's own
# check exists to catch: fully installed, fully inert, with nothing saying why.
# Asserted because a caveat has no other test, which is the same reason this
# repo now checks remedy text at all (the agent-doctor advice that could not
# come true, and `mux check` telling a stale server to source a file it already
# sourced).
#
# BEFORE THE GIT BLOCK, DELIBERATELY. These need no repository, and when they
# sat after it they were unreachable in exactly the place it matters: the
# mutation driver copies the tree with `--exclude=.git`, so every record aimed
# at the formula reported SURVIVED because the file exited at the skip before
# reaching them. Order is what makes them guardable.
for _want in 'share/mux.tmux' 'mux setup claude' 'mux reload'; do
  grep -qF -- "$_want" "$F" || fail "the formula's caveats never mention
[$_want]. brew runs no installer, so a step it does not print is a step nobody
takes."
done

# THE THREE DIRECTORIES MUST STAY SIBLINGS, which is the one layout property
# `bin/mux` requires: it resolves \$0 and then reads ../libexec and ../share.
# Dropping one from the install block leaves a mux that reports an incomplete
# install and blames the install rather than the formula.
for _d in bin libexec share; do
  grep -q "libexec.install.*\"$_d\"" "$F" \
    || fail "the install block does not put \`$_d\` under libexec alongside the
others; bin/mux resolves its siblings from \$0 and would not find them"
done

# --- against git, if this is a checkout ----------------------------------
# WHAT CANNOT BE MUTATION-GUARDED, said plainly rather than left to look like
# coverage: the four assertions below compare the formula to THIS REPOSITORY'S
# tags, and `test/mutate` copies the tree without `.git` on purpose (an
# interrupted run must not be able to leave a broken mux behind, and the copy is
# what makes that true). So no record can reach them. Each was verified by hand
# on 2026-09-29 instead, by breaking it and watching this file fail: a stale
# tag, a wrong revision. That is weaker than a record and it is what is
# available, so it is written down rather than claimed.
if [ ! -d "$HERE/.git" ] || ! command -v git >/dev/null 2>&1; then
  printf 'note: %s skipped the tag checks (no git checkout)\n' "$_name" >&2
  pass
fi
_tags=$(git -C "$HERE" tag -l --sort=-v:refname)
if [ -z "$_tags" ]; then
  printf 'note: %s skipped the tag checks (no tags here)\n' "$_name" >&2
  pass
fi

# THE NEWEST TAG IS THE ONE THE FORMULA MUST NAME. This is the assertion that
# catches the real failure: a release was tagged and this file was not touched.
_newest=$(printf '%s\n' "$_tags" | head -1)
[ "$_ftag" = "$_newest" ] || fail "the formula pins $_ftag but the newest tag is
$_newest, so \`brew install mux\` would install $_ftag forever. Update
HomebrewFormula/mux.rb (tag and revision) as part of cutting the release."

# THE REVISION MUST BE THAT TAG'S COMMIT. A tag can be moved and a sha can be
# mistyped; either way Homebrew would fetch something other than the release
# this file names, and the only symptom is an installed mux whose version
# disagrees with the formula that installed it.
_want=$(git -C "$HERE" rev-parse "$_newest^{commit}")
[ "$_frev" = "$_want" ] || fail "the formula's revision does not match tag
$_newest:
  formula: $_frev
  $_newest:    $_want"

# THE TAG MUST CARRY THE VERSION IT CLAIMS, read out of the tagged commit rather
# than out of the working tree. Homebrew infers the version from the tag, so a
# tag cut at the wrong commit makes `brew install` produce a mux whose `-V`
# disagrees with what brew believes it installed -- and the formula's own `test`
# block asserts those agree, which would then fail on the user's machine
# instead of here.
_tv=$(git -C "$HERE" show "$_newest:bin/mux" 2>/dev/null \
  | sed -n 's/^MUX_VERSION=\(.*\)/\1/p' | head -1)
[ "v${_tv:-?}" = "$_newest" ] || fail "tag $_newest carries MUX_VERSION
${_tv:-<none>}, so the tag and the version it names disagree. Homebrew infers
the version from the tag."

# AND THE RELEASE MUST BE IN THIS HISTORY. A formula naming a tag that is not an
# ancestor of HEAD is pinning a release this branch does not contain, which is
# how a tag cut on a side branch quietly becomes what everyone installs.
git -C "$HERE" merge-base --is-ancestor "$_newest" HEAD 2>/dev/null \
  || fail "tag $_newest is not an ancestor of HEAD, so the formula pins a
release that is not in this branch's history"

pass
