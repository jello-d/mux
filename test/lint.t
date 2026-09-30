#!/bin/sh
# test/lint.t - shellcheck over every shell file in the package.
#
# This is a TEST, not a separate lint target, for one reason: a lint you have
# to remember to run is a lint that stops being run. Riding the *.t glob means
# `sh test/run` and `./setup.sh test` both enforce it, and CI gets it free.
#
# It SKIPS when shellcheck is absent rather than failing, because the package's
# stated floor is "a shell and the repo checkout" (see test/run) and mux has no
# runtime dependency beyond tmux. A missing linter must not make a correct
# checkout look broken.
#
# WHY LINT AT ALL, given `dash -n` already runs on every edit: they see
# different classes. `dash -n` accepts anything syntactically valid, including
# every word-splitting bug mux has shipped.
#
# But be precise about how much this buys, because it is easy to overclaim and
# then trust a net with a hole in it. MEASURED, with `-s sh`:
#
#     for x in $*                 SC2048     CAUGHT
#     conventions: allow -- the table's "no SC code" column value
#     for x in $(tmux ls)         --         NOT CAUGHT
#     for x in $set               --         NOT CAUGHT
#     case " $set " in *" $n "*)  --         NOT CAUGHT
#
# So of the four places "a session name is not a word" shipped (mux-cycle,
# mux-next-blocked, the hidden-set membership test, and `mux resume`), this
# check would have found exactly ONE, the `$*` in resume, which is in fact how
# that one WAS found. An external audit found two by reading the code; the
# other two needed tests. shellcheck is a floor, not the net: test/mux-session-
# names.t is what actually holds that class down.
#
# Its real value is the bugs nobody is looking for: an unquoted expansion in
# an `rm` path, a `local` that is not POSIX, a masked return value.
#
# The configuration (../.shellcheckrc) disables only what is systematically
# wrong about THIS codebase, each with its reason written down. Anything
# intentional but rare is disabled INLINE at the site, so a second, ACCIDENTAL
# instance of the same pattern still fails here.
set -eu
_name=lint
. "$(dirname "$0")/harness_lib"

command -v shellcheck >/dev/null 2>&1 || {
  printf 'skip %s (no shellcheck)\n' "$_name"; exit 0; }

# Every shell file, found by EXTENSION or by SHEBANG: most of mux's programs
# are extensionless (bin/mux, libexec/mux-check), so a glob alone would miss
# the bulk of the package and quietly lint almost nothing.
_list=$T/files
: >"$_list"
find "$HERE/bin" "$HERE/libexec" "$HERE/test" "$HERE/share" "$HERE/indicator" \
  -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r _f; do
  case $_f in
  # NOT SELECTED BY `.sh`, deliberately. A suffix-keyed selector SILENTLY
  # SHRINKS the moment something is renamed: the corpus gets smaller, the
  # test still passes, and nothing says so. Measured before removing it:
  # every sourced lib in this tree carries `#!/bin/sh`, and so does every
  # `.t`, so the shebang arm below already covers them and the suffix was
  # never what made them visible. Now the selector cannot go stale when a
  # name changes, which is the property the count assertion below wants.
  *.py|*.tmux|*.md|*.toml|*.json|*.yaml|*/.git/*) ;;
  *)  # A shebang naming sh/dash/bash, and nothing else.
    case "$(head -c 64 -- "$_f" 2>/dev/null | head -1)" in
    '#!'*/sh|'#!'*/dash|'#!'*/bash|'#!'*env\ sh|'#!'*env\ dash)
      printf '%s\n' "$_f" ;;
    esac ;;
  esac
done >>"$_list"
printf '%s\n' "$HERE/setup.sh" "$HERE/indicator/setup.sh" >>"$_list"
LC_ALL=C sort -u "$_list" -o "$_list"

# A floor on the count. Without it, a find that matched NOTHING (a layout
# change, a bad case arm above) would lint zero files and report a triumphant
# pass: the failure mode this whole file exists to prevent, reproduced one
# level up.
#
# THE FLOOR IS TIGHT, not generous, and that is the point. At 40 against a real
# 115 it would have sat there while a rename dropped fifteen files out of the
# corpus: visible to nobody, because a shrinking corpus reports the same
# cheerful pass as a whole one. Close to the real number, a shrink FAILS and
# says so; the cost is bumping this line when files are legitimately removed,
# which is a deliberate trade and cheap next to a linter that quietly stops
# looking.
_n=$(wc -l <"$_list")
[ "$_n" -ge 100 ] || fail "only $_n shell files found (expected 100+): either
the discovery is broken, or files left the corpus; if that was deliberate,
lower this floor in the same commit so the next shrink is still visible"

_out=$T/out
# Run from the repo root so shellcheck finds .shellcheckrc, and pass the list
# through `xargs -0` so no filename is ever word-split (mux lives in a path
# with no spaces today, but that is exactly the assumption this suite exists
# to stop making). -0 rather than GNU's -d '\n': BSD xargs has the former and
# not the latter, and shellcheck runs on machines that are not Linux.
( cd "$HERE" && tr '\n' '\0' <"$_list" \
  | xargs -0 shellcheck -s sh -f gcc -- ) >"$_out" 2>&1 || true
if [ -s "$_out" ]; then
  printf 'FAIL %s: shellcheck found %s issue(s) across %s files:\n' \
    "$_name" "$(wc -l <"$_out")" "$_n" >&2
  sed 's|^'"$HERE"'/||' "$_out" >&2
  printf '\nFix it, or (if it is intentional) add an inline\n' >&2
  printf '# shellcheck disable=SCxxxx with the reason at the site.\n' >&2
  exit 1
fi

# --- a rule shellcheck does not have: redirection ORDER --------------------
# `cmd <"$f" 2>/dev/null` does NOT silence a missing $f. Redirections apply
# left to right, so the OPEN fails while stderr is still the terminal, and the
# SHELL prints `cannot open ...` before cmd ever runs: cmd's own 2>/dev/null
# is attached too late to cover it. `cmd 2>/dev/null <"$f"` is correct.
#
# Three shipped: `stty size </dev/tty` (every context with no controlling
# terminal (cron, a systemd unit, this suite) got a spurious error on a
# path built to fall through), and two on agent-state RACE paths, where a file
# pruned between the glob and the read is the normal case, not the exception.
# Each looks deliberately silenced, which is what makes it worth a machine
# check rather than a reviewer's eye.
#
# IT APPLIES TO OUTPUT TOO, which this rule missed until 2026-09-23. A brand new
# `printf ... >>"$f" 2>/dev/null` in mux-log_lib printed `cannot create ...:
# Permission denied` from a path built to be silent, and the input-only pattern
# below sailed past it. The direction was never the point (a failing OPEN is a
# failing open), so both are checked now. The output pattern wants a target
# starting with a quote or `$`, which is every form this codebase uses and
# conveniently excludes `>/dev/null 2>/dev/null` (a target that cannot fail).
#
# IT FOUND TEN SHIPPED INSTANCES the moment it was added, four of them in
# libexec: the session-set write and delete, mux-scan's log fallback, and
# mux-agent-state-render's session query, which runs on every status TICK.
# Every
# one was a path built to be silent that would have printed shell noise instead.
_bad=$T/order
# The second grep drops COMMENT lines, including the ones just above,
# which describe the bad shape and would otherwise report this file. A line
# with a TRAILING comment is still checked; only a comment-only line is not.
( cd "$HERE" && grep -rnE \
  '<[^ <]+ +2>/dev/null|>>?["'"'"'$][^ ]* +2>/dev/null' \
  bin libexec test share setup.sh 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_bad" || true
if [ -s "$_bad" ]; then
  printf 'FAIL %s: redirect BEFORE its 2>/dev/null:\n' "$_name" >&2
  sed 's/^/  /' "$_bad" >&2
  printf 'Put 2>/dev/null first; it does not silence a failing open.\n' >&2
  exit 1
fi

# --- a test may not REPLACE the harness's EXIT trap ------------------------
# POSIX sh has no trap stack, so `trap '...' EXIT` in a test file silently
# discards harness_lib's `rm -rf "$T"` and that run's whole scratch directory
# stays in /tmp forever. SIX FILES had done it, every one of them for a good
# reason (kill a tmux server, restore a mode so the dir can be removed), and
# none of them meant to keep the dir.
#
# INVISIBLE BECAUSE THE LITTER WAS UNIFORM, the same way 123 dead tmux sockets
# went unnoticed: one more `/tmp/tmp.XXXX` among hundreds looks like everyone
# else's. It became countable only once the harness put a recognisable `tmux/`
# inside each scratch dir.
#
# `t_trap 'CMD'` composes instead of replacing. This rule is what stops the
# next test reintroducing it, since the failure is invisible by construction.
# SCOPED TO FILES THAT SOURCE THE HARNESS, which is the actual rule: only such
# a file has a trap to discard. `test/mutate` and `test/run` are drivers with
# scratch dirs and traps of their own, and the first version of this check
# reported the driver, a rule wider than its reason.
#
# SCOPING BY THE `.t` SUFFIX WAS STILL TOO WIDE, for the same reason, and the
# house conventions test is the case that proved it: test/conventions.t is
# vendored byte-identical from ~/src/shared-notes/_conventions.t into thirteen
# repos, so it is deliberately SELF-CONTAINED and sources no harness at all
# (the thirteen expose four different harness APIs). Its own `trap ... EXIT`
# cleans up its own mktemp files and can discard nothing, because it inherited
# nothing. Reported by the suffix version the moment it was vendored here.
#
# So the predicate is the SOURCE LINE, not the name: 67 of 68 `.t` files here
# source the harness and are checked; the one that does not is out of scope by
# construction rather than by an exception anyone has to maintain.
_bt=$T/traps
: >"$_bt"
for _f in "$HERE"/test/*.t; do
  grep -qE '^[[:space:]]*\.[[:space:]].*harness' "$_f" 2>/dev/null || continue
  grep -nE "^[[:space:]]*trap[[:space:]].*EXIT" "$_f" 2>/dev/null \
    | sed "s|^|${_f#"$HERE"/}:|" >>"$_bt" || true
done
if [ -s "$_bt" ]; then
  printf 'FAIL %s: a test replaced the harness EXIT trap:\n' "$_name" >&2
  sed 's/^/  /' "$_bt" >&2
  printf 'Use `t_trap CMD`, which keeps the scratch-dir removal.\n' >&2
  exit 1
fi

# --- a grep PATTERN that came from a name needs `--` ---------------------
# `grep -qxF "$name"` parses a leading-dash name as OPTIONS: the match silently
# fails and grep prints a usage block to stderr. Seven shipped instances when
# this was added (2026-09-26), across profiles, the session set, check, views
# and three in bin/mux.
#
# The worst was mux_sess_has, because mux_sess_add consults it for idempotence:
# such a name would be re-appended on EVERY attach and the recorded set would
# grow without bound, taking `mux resume` with it. tmux refuses to create the
# name, so all seven were latent, which is exactly why a rule is worth more
# than a memory here.
#
# Matches a -F/-x/-q grep whose pattern is a "$..." expansion with no `--`
# before it. A literal pattern is fine, and so is one already guarded.
_dash=$T/dashgrep
( cd "$HERE" && grep -rnE \
  'grep( +-[a-zA-Z]+)* +"\$' \
  bin libexec share setup.sh 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE 'grep( +-[a-zA-Z]+)* +-- ' ) >"$_dash" || true
if [ -s "$_dash" ]; then
  printf 'FAIL %s: grep pattern from a variable, with no `--`:\n' "$_name" >&2
  sed 's/^/  /' "$_dash" >&2
  printf 'A name starting with `-` is read as OPTIONS.\n' >&2
  printf 'Write it as: grep -qxF -- "$x"\n' >&2
  exit 1
fi

# --- the exit-code contract, mechanically -------------------------------
# mux uses exactly 0, 1, 2 and 3. The ABSENCE of everything else is what lets a
# caller attribute 255 to ssh and 127 to a missing binary rather than to mux,
# which is what `latch` will classify retries on and how a fleet mid-upgrade
# avoids reading as half-broken. test/mux-exit.t pins what today's verbs return;
# this holds the rule against code nobody has written yet, which a per-verb test
# cannot do.
#
# Literal codes only. A handful of sites exit through a variable (`exit "$RC"`
# in mux-check, `exit "${1:-2}"` in usage), and those are covered behaviourally
# instead: a grep cannot evaluate them, and pretending otherwise would be a
# guard that looks stronger than it is.
#
# Whole-line COMMENTS are excluded, and they have to be: the files that classify
# a FOREIGN exit code have to name it to explain themselves, and mux-latch
# documenting "ssh exits 255" is the opposite of mux exiting 255. A trailing
# comment on a real line is still caught, so the exclusion is as narrow as it
# can be made with a grep.
#
# share/latch/ AND share/indicator/ ARE A DIFFERENT CONTRACT, checked
# separately below rather than merely excluded. A hook is not a mux command:
# it answers a QUESTION in three states (0 yes, 1 no, 78 cannot tell), and 78
# is the whole point: "cannot tell" has to be distinguishable from "no" or
# an edge nobody can check gets reported as fine. Exempting the directories
# with a hole would let a hook invent a fourth code; a rule of their own does
# not. The original wording, kept because it is the argument:
#
# share/latch/ IS A DIFFERENT CONTRACT and is checked separately below, not
# merely excluded. A latch hook is not a mux command: it answers a QUESTION in
# three states (0 yes, 1 no, 78 cannot tell), and 78 is the whole point:
# "cannot tell" has to be distinguishable from "no" or an edge nobody can check
# gets reported as fine. Exempting the directory with a hole would let a hook
# invent a fourth code; a rule of its own does not.
_ec=$T/exitcodes
( cd "$HERE" && grep -rnE '\bexit [0-9]+' bin libexec share setup.sh \
  2>/dev/null | grep -vE '\bexit [0123]\b' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE '^share/(latch|indicator)/' ) >"$_ec" || true
if [ -s "$_ec" ]; then
  printf 'FAIL %s: an exit code outside the 0/1/2 contract:\n' "$_name" >&2
  sed 's/^/  /' "$_ec" >&2
  printf 'mux exits 0 (answered), 1 (refused, reason on stderr),\n' >&2
  printf '2 (usage/unknown verb) or 3 (the name is not known here).\n' >&2
  printf 'Anything else makes 255 and 127 ambiguous for a remote\n' >&2
  printf 'caller. See test/mux-exit.t.\n' >&2
  exit 1
fi

# --- the HOOK contract: a latch hook answers 0, 1 or 78, and nothing else ---
_hc=$T/hookcodes
( cd "$HERE" && grep -rnE '\bexit [0-9]+' share/latch share/indicator \
  2>/dev/null \
  | grep -vE '\bexit (0|1|78)\b' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_hc" || true
if [ -s "$_hc" ]; then
  printf 'FAIL %s: a hook used an exit code outside 0/1/78:\n' \
    "$_name" >&2
  sed 's/^/  /' "$_hc" >&2
  printf 'A hook answers 0 (yes), 1 (no) or 78 (cannot tell). A fourth\n' >&2
  printf 'code is read as "cannot tell" by latch, so it is silently\n' >&2
  printf 'indistinguishable from 78 and says something it does not mean.\n' >&2
  exit 1
fi

# Every shipped hook must be EXECUTABLE. A hook that is present and unrunnable
# resolves by name, then fails to run, and latch reports the state it could not
# determine rather than the install that is broken.
for _h in "$HERE"/share/latch/* "$HERE"/share/indicator/*; do
  [ -e "$_h" ] || continue
  [ -x "$_h" ] || fail "$(basename "$_h") is not executable;
a hook that cannot run is a hook latch resolves and then cannot use"
done

# THE MODE IS AUTHORITATIVE IN libexec/, and asserted in BOTH directions. mux
# had it both ways before this: four of fifteen sourced libs were 775 and the
# rest 664, so the mode bit was a second, self-contradicting signal for
# "library". Two coherent answers existed (mode means nothing and the NAME
# carries it, which is tackup's position; or mode is authoritative and a test
# says so) and having a third of the cases disagree was not one of them.
#
# THIS FLEET HAS PAID FOR A LOST MODE BIT MORE THAN ONCE: `test/mutate` shipped
# a bug where `awk >tmp` then `mv` left every mutated PROGRAM at 0644, so the
# bit is worth asserting rather than ignoring. And the naming convention is what
# makes it assertable at all: `*_lib` is machine-parseable in a way `*-lib`
# would not be.
#
# A COMMAND THAT IS NOT EXECUTABLE is the failure that actually happens: it
# resolves by name through the dispatcher, then cannot run.
for _f in "$HERE"/libexec/*; do
  [ -f "$_f" ] || continue
  case $_f in
  *_lib)
    [ ! -x "$_f" ] || fail "$(basename "$_f") is a sourced library and
is EXECUTABLE. The bit is a lie: running it does nothing useful, and mux asserts
the opposite everywhere else in this directory."
    ;;
  *)
    [ -x "$_f" ] || fail "$(basename "$_f") is a command and is NOT
executable. It resolves by name through the dispatcher and then fails to run,
which reads as a missing feature rather than a broken install."
    ;;
  esac
done

# THE VERSION IS REPORTED, because this verdict DEPENDS on it and that was
# invisible for the whole life of CI. shellcheck 0.11 and 0.9.0 disagree about
# SC2119/SC2120 (0.9.0 finds 13 of them in this tree, 0.11 finds none), so a
# green run here stood in for a red one on ubuntu-latest, whose apt package is
# 0.9.0, on every push since the workflow was added. The rules the two disagree
# about are now disabled with their reason in .shellcheckrc; printing the
# version is what makes the NEXT disagreement legible instead of mysterious.
_scv=$(shellcheck --version 2>/dev/null \
  | awk '/^version:/{print $2; exit}')
printf 'ok   %s (%s files clean, shellcheck %s)\n' \
  "$_name" "$_n" "${_scv:-?}"
exit 0
