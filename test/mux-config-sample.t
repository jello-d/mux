#!/bin/sh
# test/mux-config-sample.t - share/config.sample against the code that reads
# $MUX_DIR/config.
#
# WHY A TEST AND NOT VIGILANCE. The sample is a SECOND COPY of the knob list,
# and this package's own rule for a second copy is that it needs a check
# rather than somebody remembering: the homebrew formula is held to the
# newest tag the same way, for the same reason. The failure it prevents is
# silent and slow, and it has two directions that fail differently:
#
#   a key the source READS and the sample does not name
#       an undiscoverable knob. Nothing breaks, so nothing says so, and the
#       only way to find it is to read the source, which is what a sample
#       exists to save you.
#   a key the sample names and the source does not READ
#       worse, because it reads as a promise. Somebody sets it, mux ignores
#       it, and the config LOOKS configured. That is the inert-flag defect
#       this tree already records for `mux agent status --all`.
#
# BOTH DIRECTIONS ARE ASSERTED SEPARATELY, because one "the lists differ"
# check kills neither mutation and could not say which way it differed.
#
# AND IT CARRIES THE CONVENTION RULES THE GENERIC CHECKER GAVE UP. The sample
# is in test/conventions.exempt (two shipped ssh defaults are over 80 columns
# and the config format has no line continuation, so they cannot wrap), and
# an exemption that removes a check without replacing it is how a file stops
# being read at all. The reason lives in both files.
set -eu
_name=mux-config-sample
. "$(dirname "$0")/harness_lib"

SAMPLE=$HERE/share/config.sample
# NO BACKTICKS IN A DOUBLE-QUOTED MESSAGE, which the linter caught and which
# is a bug rather than a style note: the shell would have RUN the command
# inside them while building the string.
[ -r "$SAMPLE" ] || fail "share/config.sample is missing: every knob mux
accepts is supposed to be discoverable from the package rather than from the
source, and the man page's FILES entry points here"

# --- WHICH KEYS THE SOURCE ACTUALLY READS ---------------------------------
# SCRAPED, NEVER RESTATED, which is the whole point: a hand-written list here
# would be a THIRD copy, and three copies is how two of them agree with each
# other about the wrong thing (the key-binding derivation shipped exactly
# that once, with the check and its fixture using the same narrow pattern).
#
# Four reader shapes in the tree, deliberately matched one by one rather than
# with one loose pattern, so a NEW shape shows up as a missing key here
# instead of being quietly swallowed:
#
#   latch's `_seam "$ENV" key default`        the five latch seams
#   `awk '$1 == "key"'` after mux_conf_clean  env-timeout, latch-transport
#   `mux_ctx_conf key`                        context-command, env-ready
#   python `_conf("key")`                     the notifier's three
#   a standalone hook's own sed               latch-et-port (share/latch is
#                                             shipped to be replaced, so it
#                                             may not source mux's libs)
#
# THE AWK ARM IS WINDOWED, and that is not fussiness. `$1 == "NAME"` is how
# this tree parses EVERY line-directive format it has (agent descriptors,
# the env plan's verdicts, tmux's own `list-keys` output), so an unwindowed
# match reported `bind-key busy dropped set stripped` as config keys on its
# first run. Anchoring it to within four lines of a `$MUX_DIR/config` read
# is what makes it a question about this file rather than about awk.
_src() {
  {
    grep -rhoE '_seam "[^"]*" [a-z][a-z-]+' "$HERE/libexec" \
      | awk '{print $NF}'
    grep -rhA4 'MUX_DIR/config"' "$HERE/libexec" "$HERE/lib" "$HERE/bin" \
      | grep -ohE '\$1 == "[a-z][a-z-]+"' | sed 's/.*"\(.*\)"/\1/'
    grep -rhoE 'mux_ctx_conf [a-z][a-z-]+' "$HERE/libexec" "$HERE/lib" \
      "$HERE/bin" | awk '{print $2}'
    grep -rhoE '_conf\("[a-z][a-z-]+"\)' "$HERE/desktop-notifier" \
      | sed 's/.*"\(.*\)".*/\1/'
    grep -rhoE 'latch-et-port' "$HERE/share/latch"
  } 2>/dev/null | grep -E '^[a-z][a-z-]+$' | sort -u
}

# --- AND WHICH THE SAMPLE NAMES -------------------------------------------
# THE COMMENTED DIRECTIVE, not the prose. A key mentioned only in a sentence
# is not a key you can uncomment, and the user's rule for this file is that
# every knob carries a comment block AND a default you can act on. Matching
# the directive is what makes the assertion about the actionable half.
#
# COMMENTED OR NOT, because a key is DOCUMENTED either way and the two facts
# are separate assertions. Matching only the commented form made the
# everything-is-commented check below unreachable: uncommenting a directive
# dropped it from this list, so the MISSING-key assertion fired first and
# named the wrong defect. Found by probing the guard, not by reading it.
_doc() {
  sed -n 's/^#\{0,1\}\([a-z][a-z-]*\)[ \t].*/\1/p' "$SAMPLE" | sort -u
}

_missing=$(comm -23 "$(_src >"$T/src"; echo "$T/src")" \
  "$(_doc >"$T/doc"; echo "$T/doc")" | tr '\n' ' ')
[ -z "${_missing% }" ] || fail "mux reads these config keys and
share/config.sample does not carry a commented directive for them:
  ${_missing% }
An undiscoverable knob is one nobody can use without reading the source.
Add a comment block and a commented-out default, beside the others."

_extra=$(comm -13 "$T/src" "$T/doc" | tr '\n' ' ')
[ -z "${_extra% }" ] || fail "share/config.sample offers these and nothing in
mux reads them:
  ${_extra% }
That is worse than omitting them: somebody sets one, mux ignores it, and the
config LOOKS configured. Either wire the key or drop the line."

# --- EVERY DIRECTIVE IS COMMENTED OUT -------------------------------------
# The file ships as documentation. An ACTIVE line would be a default restated
# where it can drift, which is the defect this package met when a config
# restated three latch seams and got one of them wrong, breaking `mux latch`
# on both boxes within a day. A commented line cannot do that.
_live=$(grep -nE '^[a-z]' "$SAMPLE" | head -3)
[ -z "$_live" ] || fail "share/config.sample has an ACTIVE directive:
$_live
Every line must be commented: the file documents what mux already does, so
an active copy freezes that value at whatever it was the day it was written."

# --- AND IT PARSES AS THE CONFIG IT DOCUMENTS ------------------------------
# Uncommenting the whole file must yield directives mux's own cleaner reads
# back intact. That is the assertion that catches a sample drifting away from
# the FORMAT rather than from the key list: a smart quote, a stray tab, a
# wrapped line.
. "$HERE/lib/mux-conf_lib"
sed 's/^#\([a-z]\)/\1/' "$SAMPLE" >"$T/asconf"
_bad=$(mux_conf_clean <"$T/asconf" | grep -vE '^[a-z][a-z-]+[ \t]+\S' || true)
[ -z "$_bad" ] || fail "uncommenting share/config.sample yields lines that
are not KEY VALUE directives:
$_bad"

# A TAB WOULD SURVIVE THE CLEANER AND IS STILL WRONG HERE, because the values
# are copied by hand and a tab is invisible in the copy.
_tabs=$(grep -nP '\t' "$SAMPLE" 2>/dev/null || grep -n "$(printf '\t')" \
  "$SAMPLE" || true)
[ -z "$_tabs" ] || fail "share/config.sample contains a TAB:
$_tabs"

# --- THE HOUSE PROSE RULES, WHICH THE EXEMPTION GAVE UP -------------------
# conventions.t no longer reads this file, so the two rules that still apply
# to it are asserted here. Only the COLUMN rule was impossible; these were
# never in question and must not be lost with it.
# THE PATTERN IS BUILT FROM CODEPOINTS, not typed. A detector that embeds
# the character it forbids is a file that fails its own rule, and
# conventions.t rejected this on its first commit. printf's octal escapes
# are POSIX and need no locale.
_EMDASH=$(printf '\342\200\224'); _ENDASH=$(printf '\342\200\223')
_dash=$(grep -n -e "$_EMDASH" -e "$_ENDASH" -e ' -- ' "$SAMPLE" || true)
[ -z "$_dash" ] || fail "share/config.sample uses an em-dash or a double
hyphen standing in for one:
$_dash"

# AND EVERY PROSE LINE STILL FITS, which is the half of the column rule the
# exemption did not need to cover: only the two shipped ssh DEFAULTS are too
# long, and they are directive lines. A comment that overflows is just an
# unwrapped comment.
_wide=$(awk 'length > 80 && $0 !~ /^#[a-z]/ { print FNR": "length }' \
  "$SAMPLE" || true)
[ -z "$_wide" ] || fail "a PROSE line in share/config.sample is over 80
columns. The exemption covers the two shipped ssh defaults, which cannot be
wrapped; a comment can be:
$_wide"

# --- AND setup.sh SHIPS IT -------------------------------------------------
# A sample nothing installs is a sample only a developer ever sees, and the
# man page's FILES entry would then name a path that does not exist on an
# installed box: advice that cannot come true, which is this package's oldest
# defect class.
grep -q 'config\.sample\|share' "$HERE/setup.sh" \
  || fail "setup.sh does not appear to install share/, so config.sample
would not reach an installed box"

pass
