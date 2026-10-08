#!/bin/sh
# test/mux-config-roots.t - the README mux writes into $MUX_DIR against the
# code that reads $MUX_DIR.
#
# WHAT THE README IS FOR. It is the one artifact that answers "where do I put
# my own thing", and a user reads it instead of the source. So every name mux
# reads under $MUX_DIR has to be in it, and it had drifted the way a second
# copy of a fact always does: `desktop-notifier/` was never added when that
# seam gained a resolver, `themes/` and `agents/` were never added at all,
# and the prose stated a COUNT of shipped validators that was already wrong.
#
# THE EXISTING ASSERTIONS IN test/setup.t ARE A PRESENCE CHECK over a
# hand-picked list (the four $MUX_* roots, "shareable", "machine-local",
# `envhooks.d`), so they cannot see a directory going missing from the list,
# which is exactly what happened three times. This file derives the list.
#
# THREE READER SHAPES, matched one by one rather than with one loose pattern,
# because the measurement that motivated this file is that they disagree
# about which names they can see:
#
#   $MUX_DIR/<name> on a CODE line     config envhooks.d hosts latch
#                                      layouts partitions profiles profiles.d
#   mux_data_find/_stems <KIND>        agents themes (and the data root)
#   python os.path.join(base, "<n>")   desktop-notifier
#
# AND THE SECOND SHAPE IS THE REASON THE FIRST IS NOT ENOUGH. `themes` and
# `agents` appear under $MUX_DIR ONLY IN COMMENTS, because the real reads go
# through mux-data_lib, which never spells the variable. A `$MUX_DIR/` grep
# alone reports them as unread and would have "proved" the README right.
#
# COMMENT LINES ARE EXCLUDED, and that is load-bearing in both directions: a
# comment is not a read, so counting one would make the README owe an entry
# for `$MUX_DIR/context`, a seam retired in favour of a config directive and
# surviving only in one sentence.
set -eu
_name=mux-config-roots
. "$(dirname "$0")/harness_lib"

# --- WHAT THE CODE READS --------------------------------------------------
# Shipped code only: bin, lib, libexec, the shipped hooks, and setup.sh. The
# suite's own fixtures write all over $MUX_DIR and are not a contract.
#
# A FILE LIST, NOT A LIST OF DIRECTORIES, which the vacuity guard below
# caught on this file's very first run: `cat` on a directory fails, so the
# whole shape scraped nothing and would have "proved" the README complete.
FILES=$T/srcfiles
find "$HERE/bin" "$HERE/lib" "$HERE/libexec" "$HERE/share" \
  -type f 2>/dev/null >"$FILES" || :
printf '%s\n' "$HERE/setup.sh" >>"$FILES"
[ -s "$FILES" ] || fail "found no shipped files to scrape"

# COMMENTS STRIPPED ONCE, into one file the three shapes then read. A helper
# function would be the obvious shape and cannot be: `xargs` execs a command,
# so it can never call a shell function, which is what made the guard above
# fire a second time.
CODE=$T/code
xargs cat 2>/dev/null <"$FILES" | grep -vE '^[[:space:]]*#' >"$CODE" || :
[ -s "$CODE" ] || fail "the shipped files concatenated to nothing"

# 1. a literal path under the variable, on a line that is not a comment.
_r1=$(grep -oE '\$MUX_DIR/[A-Za-z0-9._-]+' "$CODE" \
  | sed 's|.*MUX_DIR/||' | sort -u)

# 2. the data resolver's KIND argument. An empty KIND is the data ROOT, where
# layouts live, so it contributes nothing of its own.
_r2=$(grep -oE 'mux_data_(find|stems|stems_line) +[A-Za-z0-9._-]+' "$CODE" \
  | awk '{print $2}' | sort -u)

# 3. the notifier's hook directory, joined under whichever base is iterating.
_r3=$(grep -vE '^[[:space:]]*#' \
    "$HERE/desktop-notifier/mux_desktop_notifier/sources.py" \
  | grep -oE 'os\.path\.join\(base, *"[A-Za-z0-9._-]+"' \
  | sed 's|.*"\(.*\)"|\1|' | sort -u)

# EVERY SCRAPE NEEDS ITS OWN VACUITY GUARD, not one over the union: a shape
# that stops matching is invisible behind the other two, which is how the
# capabilities guard went blind to eleven verbs while its total still read
# healthy. A floor is a vacuity guard and never a completeness one.
for _pair in "1:$_r1" "2:$_r2" "3:$_r3"; do
  _n=${_pair%%:*}
  [ -n "${_pair#*:}" ] || fail "reader shape $_n scraped NOTHING, so the
union below is missing a whole class of read and every assertion in this file
is about a smaller set than it claims. Fix the pattern, not the README."
done

READS=$(printf '%s\n%s\n%s\n' "$_r1" "$_r2" "$_r3" \
  | grep -vE '^$' | sort -u)
_nr=$(printf '%s\n' "$READS" | wc -l)
[ "$_nr" -ge 9 ] || fail "only $_nr names scraped as read under \$MUX_DIR,
which is fewer than the package has had since the notifier seam landed:
[$(printf '%s\n' "$READS" | tr '\n' ' ')]"

# --- WHAT THE README SAYS -------------------------------------------------
# Driven through a real install into a scratch prefix, rather than by reading
# setup.sh, so what is asserted is the file a user actually gets.
#
# MUX_DIR MUST BE UNSET AND NOT MERELY REDIRECTED. bin/mux EXPORTS it, so an
# inherited value BEATS the XDG derivation and the README lands in the
# developer's real config root. harness_lib pins this; a probe run by hand
# has broken it three times, and `test/setup.t` itself did for a while.
PREFIX=$T/prefix
env -u MUX_DIR PREFIX="$PREFIX" HOME="$T/home" \
  XDG_CONFIG_HOME="$T/conf" XDG_STATE_HOME="$T/state" \
  XDG_CACHE_HOME="$T/cache" \
  sh "$HERE/setup.sh" install >"$T/inst" 2>&1 \
  || fail "install failed, so the README was never written:
$(sed 's/^/  /' "$T/inst")"

RM=$T/conf/mux/README
[ -s "$RM" ] || fail "install wrote no README into the config root"

# The listing block, one name per line, first field. The names are written
# one per line precisely so this parse is `$1`: an earlier version packed
# `profiles, profiles.d/` onto one row, and a parser clever enough for that
# is a parser that can be wrong in silence.
NAMED=$(awk '/^WHAT GOES IN HERE/ {inb=1; next}
  inb && /^[A-Z][A-Z ]+$/ {inb=0}
  inb && /^  [a-z]/ {print $1}' "$RM" \
  | sed 's|/$||' | sort -u)
[ -n "$NAMED" ] || fail "the README's WHAT GOES IN HERE section parsed to
NOTHING, so both assertions below are vacuous. The section is gone, renamed,
or no longer one name per line."

# --- A NAME THE CODE READS MUST BE NAMED ----------------------------------
# The direction that was live and wrong three times over. Nothing breaks when
# it is, which is why only a test can say so: the overlay works perfectly and
# is simply undiscoverable.
_missing=
for _n in $READS; do
  printf '%s\n' "$NAMED" | grep -qxF -- "$_n" || _missing="$_missing $_n"
done
[ -z "$_missing" ] || fail "mux reads these under \$MUX_DIR and the README
never names them, so a user cannot discover the overlay without reading the
source:$_missing"

# --- AND A NAME IT OFFERS MUST BE READ ------------------------------------
# The worse direction, asserted separately because one "the lists differ"
# check kills neither mutation: an entry nothing reads is a PROMISE. Somebody
# puts a file there, mux ignores it, and the directory LOOKS configured,
# which is the inert-flag defect this tree records for `agent status --all`.
_inert=
for _n in $NAMED; do
  printf '%s\n' "$READS" | grep -qxF -- "$_n" || _inert="$_inert $_n"
done
[ -z "$_inert" ] || fail "the README offers these and no shipped code reads
them, so a file put there is silently ignored while the directory looks
configured:$_inert"

# --- EVERY OVERRIDABLE NAME MUX ALSO SHIPS NAMES ITS PAYLOAD PATH ---------
# The other half of "where do I put my own thing" is "what is there to
# override", and a name is only worth `ls`-ing when mux ships a directory of
# its own for it. So the set is DERIVED as an intersection rather than
# listed: a read name whose share/ twin exists owes a payload path.
#
# THIS REPLACES A COUNT CHECK, and the reason is worth keeping. The drift
# that started this file was the prose saying mux ships "four environment
# validators" while five were installed, and the obvious guard greps for a
# number word. It cannot work: the sentence that drifted named no path, and
# the pattern flags "to add one, use a name mux does not ship", so a numeral
# and a pronoun are indistinguishable to it. A guard that cries wolf on
# ordinary English is a guard that gets exempted. Asserting the LIST is
# complete is decidable, and it catches the real future drift, which is a new
# shipped hook directory nobody documents: exactly what `desktop-notifier`
# was until today.
_shipped=
for _n in $READS; do
  [ -d "$HERE/share/$_n" ] || continue
  _shipped="$_shipped $_n"
  grep -qF "share/mux/share/$_n/" "$RM" || fail "mux ships
share/$_n/ and a file of the same name in \$MUX_DIR/$_n/ overrides it, and
the README never says where the shipped ones are. A user cannot see what
there is to override."
done
[ -n "$_shipped" ] || fail "no read name has a shipped share/ twin, so the
assertion above examined nothing: either the scrape or the payload moved"

# AND THE PATHS IT PRINTS MUST EXIST, because a typo'd one reads to a user as
# an empty directory rather than as a mistake. That is the half the grep
# above cannot see: it only asks whether a SHIPPED name is mentioned, so a
# path for something mux does not ship passes it and fails here.
#
# A HERE-DOC AND NOT A PIPE INTO `while read`, which is what shellcheck's
# SC2013 suggests and is wrong for this body: a pipe puts the loop in a
# SUBSHELL, so the `fail` inside it would exit the subshell and the file
# would carry on to `pass`. This tree has shipped that exact defect once, in
# `mux update-env`, where a refusal printed its message and exited 0.
while read -r _p; do
  [ -n "$_p" ] || continue
  [ -d "$_p" ] || fail "the README tells a user the shipped defaults are in
$_p and that directory does not exist in the install it was written for"
done <<EOF
$(grep -oE "$PREFIX/share/mux/share/[A-Za-z0-9._-]+/" "$RM" | sort -u)
EOF

pass
