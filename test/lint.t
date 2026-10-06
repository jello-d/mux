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

# Every shell file, found by EXTENSION or by SHEBANG: most of mux's programs
# are extensionless (bin/mux, libexec/mux-check), so a glob alone would miss
# the bulk of the package and quietly lint almost nothing.
_list=$T/files
: >"$_list"
find "$HERE/bin" "$HERE/lib" "$HERE/libexec" "$HERE/test" "$HERE/share" \
  "$HERE/desktop-notifier" \
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
printf '%s\n' "$HERE/setup.sh" "$HERE/desktop-notifier/setup.sh" >>"$_list"
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

# --- EVERY FILE MUST PARSE UNDER THE SHELL ITS SHEBANG NAMES --------------
# CHEAP, UNCONDITIONAL, AND IT RUNS BEFORE THE shellcheck GATE, because every
# box has a `/bin/sh` and not every box has a linter. A file that does not
# PARSE is not a style question: nothing in it runs at all.
#
# WHAT IT ACTUALLY CATCHES IS A DIFFERENT SHELL, which is the whole reason it
# is worth a rule. On Linux `/bin/sh` is dash and this is a restatement of the
# `dash -n` every edit already gets. On macOS `/bin/sh` IS BASH 3.2, frozen at
# GPLv2 in 2007 and never moving, and bash 3.2 finds the end of a `$( )` by
# COUNTING PARENTHESES: an unparenthesised `case` pattern inside a command
# substitution closes the substitution early and the following `;;` is a
# syntax error. mux shipped exactly that in `libexec/mux-agent`, so `mux agent`
# did not parse on macOS: EVERY verb of the machine contract dead, reported as
# `status-rc: got [2]` in one test and nothing else.
#
# THAT IS THE ARGUMENT FOR CHECKING HERE rather than in a feature test. A parse
# failure surfaces downstream as an exit code with empty stdout, which reads as
# a logic bug in whatever happened to call it first; named here, it says the
# file and the line. The fix is the POSIX `(pat)` form, verified identical in
# dash, bash 3.2, bash 5 and ksh.
#
# `test/conventions.t` also parses with `dash -n` and `bash -n`, and this is not
# a duplicate of that. Its `bash -n` runs bash in BASH mode, while a `#!/bin/sh`
# file runs in SH mode, and it is a VENDORED file: a rule only reaches it
# through the canonical copy and a re-seed of fourteen repos. A check for a
# class mux shipped belongs in mux, where it lands the same day.
_perr=$T/parse
: >"$_perr"
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  /bin/sh -n "$_f" 2>>"$_perr" || printf '%s: did not parse\n' "$_f" >>"$_perr"
done <"$_list"
if [ -s "$_perr" ]; then
  # NAME THE SHELL, because that is the whole point of the check and the
  # answer differs per box. dash has no `--version` at all (it exits 2 and
  # says nothing), so an empty answer is the normal case here rather than a
  # failure: fall back to whatever the path resolves to.
  _shid=$(/bin/sh --version 2>/dev/null | head -1) || _shid=
  [ -n "$_shid" ] || _shid="/bin/sh -> $(readlink -f /bin/sh 2>/dev/null \
    || echo '(unresolved)')"
  printf 'FAIL %s: a file does not parse under /bin/sh (%s):\n' \
    "$_name" "$_shid" >&2
  sed 's|^'"$HERE"'/||' "$_perr" >&2
  printf '\nOn macOS /bin/sh is bash 3.2, which cannot parse a `case`\n' >&2
  printf 'inside a $( ) unless every pattern is parenthesised, so the\n' >&2
  printf 'fix for that one is the POSIX `(pat)` form.\n' >&2
  exit 1
fi

# THE LINTER IS OPTIONAL, THE PARSE CHECK ABOVE IS NOT. shellcheck is absent on
# a bare box and the package's stated floor is "a shell and the repo checkout",
# so a missing linter must not make a correct checkout look broken. The skip
# says which half ran.
command -v shellcheck >/dev/null 2>&1 || {
  printf 'skip %s (%s files parse; no shellcheck)\n' "$_name" "$_n"; exit 0; }

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
  bin lib libexec test share setup.sh 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_bad" || true
if [ -s "$_bad" ]; then
  printf 'FAIL %s: redirect BEFORE its 2>/dev/null:\n' "$_name" >&2
  sed 's/^/  /' "$_bad" >&2
  printf 'Put 2>/dev/null first; it does not silence a failing open.\n' >&2
  exit 1
fi

# --- A HARDCODED /bin/<tool> THAT macOS DOES NOT HAVE ----------------------
# macOS `/bin` is a much smaller set than Linux's: no `true`, `false`, `grep`,
# `sed`, `awk`, `tr`, `wc`, `head`, `tail`, `sort` or `cut`. Those live in
# /usr/bin there.
#
# IT COST TWO macOS FAILURES. `MUX_LATCH_AUTH=/bin/true` in the latch tests made
# latch refuse a named hook it could not resolve, which is mux behaving exactly
# as designed (0.31: a NAMED hook that does not resolve exits 2 loudly), and the
# tests reported it as latch refusing to attempt. Twenty-odd sites across five
# files, all of them meaning "a command that succeeds and does nothing".
#
# THE BARE NAME IS THE FIX, and it is also the only portable one: `command -v
# true` answers `true` in both dash and bash (the BUILTIN), so there is no
# absolute path to compute. Every consumer here runs the value through a shell
# or through latch's own resolver, both of which search PATH.
#
# /usr/bin/env IS NOT MATCHED, which the pattern has to be careful about: a
# substring match on `/bin/env` hits every `#!/usr/bin/env` shebang in the tree.
_hcb=$T/hardcoded
( cd "$HERE" && grep -rnE \
  '(^|[^rn])/bin/(true|false|grep|sed|awk|tr|wc|head|tail|sort|cut)\b' \
  bin lib libexec test share setup.sh desktop-notifier 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v '^test/lint\.t:' ) >"$_hcb" || true
if [ -s "$_hcb" ]; then
  printf 'FAIL %s: hardcoded /bin path macOS does not have:\n' "$_name" >&2
  sed 's/^/  /' "$_hcb" >&2
  printf 'Use the bare name; those tools are in /usr/bin on macOS.\n' >&2
  exit 1
fi

# --- A SECOND ANSWER FOR XDG_RUNTIME_DIR -----------------------------------
# The spec gives that variable no default, so mux has to pick one, and for a
# while it had picked TWO: `/tmp/user-$(id -u)` at three sites (agent state,
# the exclude set, the demo) and plain `/tmp` at two (latch's lock directory
# and undo-pane's record directory).
#
# PLAIN /tmp IS SHARED, which is what makes this a bug and not untidiness.
# Both of those directories are created with `mkdir -p` at the process umask,
# so on a box with no XDG_RUNTIME_DIR the first user to latch owns
# /tmp/mux-latch world-readable, and then: the second user cannot write a lock
# there, silently, because that mkdir ends `|| true`, so single flight stops
# holding for them; prefix-u stops recording for them; and their
# mux-desktop-notifier can read the first user's latched hostnames straight
# out of the directory. Unreachable on a box with a logind session, which is
# why it sat there.
#
# A CHECK RATHER THAN A FUNCTION, deliberately. The obvious fix is one
# `mux_runtime_dir` in mux-paths_lib, and the two worst sites are LIBS
# (mux-agent-state_lib, mux-exclude_lib) whose own callers would then each
# need mux-paths_lib sourced first: about twenty files, ten of them tests, to
# centralise a one-line DEFAULT. This tree already measured that trade once
# and came down the same way (`${MUX_DIR:-...}` is open-coded in thirteen
# byte-identical places on purpose): CENTRALISE A RULE, NOT A DEFAULT. What
# the default was missing is the thing a rule gets for free, which is somebody
# noticing when a copy disagrees. That is this.
_xrd=$T/xrd
( cd "$HERE" && grep -rn 'XDG_RUNTIME_DIR:-' \
  bin lib libexec share setup.sh 2>/dev/null \
  | grep -v 'XDG_RUNTIME_DIR:-/tmp/user-\$(id -u)' \
  | grep -v 'XDG_RUNTIME_DIR:-}' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_xrd" || true
if [ -s "$_xrd" ]; then
  printf 'FAIL %s: a different XDG_RUNTIME_DIR fallback:\n' "$_name" >&2
  sed 's/^/  /' "$_xrd" >&2
  printf 'mux uses /tmp/user-$(id -u) everywhere. Plain /tmp is\n' >&2
  printf 'SHARED, so the second user silently cannot write there.\n' >&2
  exit 1
fi

# --- `wc -l` IN A STRING COMPARISON ----------------------------------------
# BSD `wc` PADS ITS COUNT WITH SPACES, so `[ "$(... | wc -l)" = 2 ]` compares
# `"       2"` with `"2"` as STRINGS: false on macOS, true here. Three of the
# macOS failures were this, in nine places across three files: mux-log's `-n`
# bound, mux-setup's backup count, and mux-undo-pane's pane count.
#
# `-eq` IS THE FIX, not `tr -d ' '`: a numeric comparison ignores whitespace by
# definition, so there is nothing to remember to strip. `bin/mux` already
# carried a `| tr -d ' '` at one site, the same fact discovered once and never
# written down.
#
# THE RULE IS THE COMPARISON, NOT THE TOOL: `wc -l` is fine, and so is capturing
# it. Only `=` against a captured count is wrong, which is what this matches.
_wcl=$T/wcl
_wclre='\[ *"\$\([^)]*wc -l[^)]*\)" *=|= *"\$\([^)]*wc -l\)"'
( cd "$HERE" && grep -rnE "$_wclre" \
  bin lib libexec test share setup.sh desktop-notifier 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -v '^test/lint\.t:' ) >"$_wcl" || true
if [ -s "$_wcl" ]; then
  printf 'FAIL %s: `wc -l` compared as a STRING:\n' "$_name" >&2
  sed 's/^/  /' "$_wcl" >&2
  printf 'BSD wc pads the count, so this is false on macOS. Use -eq.\n' >&2
  exit 1
fi

# --- A DESTRUCTIVE TRAP MAY NOT DEFER ITS EXPANSION ------------------------
# The standing rule in ~/src/CLAUDE.md, made mechanical: `rm -rf` never runs
# with variable expansion, and a `trap` is the sharpest case because the
# expansion happens at FIRE TIME, when the shell is already exiting and usually
# on an error path.
#
# THIS EXISTS BECAUSE IT HAPPENED. `trap 'rm -rf "$T"' EXIT` in test/harness_lib
# removed ~/src/mux on 2026-09-30: `$T` had resolved to the CURRENT DIRECTORY,
# because `cd -- "$(mktemp -d)" && pwd -P` turns an empty mktemp answer into
# `cd ""` plus `pwd -P`, and nothing could see that until the trap fired. The
# tracked files came back from a re-clone; the untracked ones did not.
#
# Bake the literal in when ARMING it (`_C="'$T'"; trap "rm -rf $_C" EXIT`), so
# `trap` prints exactly what will run and no later assignment can move it.
#
# test/conventions.t WAS EXCLUDED BY NAME and no longer needs to be: it carried
# the identical shape, vendored into fourteen repos, so the fix went into the
# canonical ~/src/shared-notes/_conventions.t and came back here as a re-seed.
# That is the only sanctioned direction, and it means this rule now covers every
# file in the tree with no exception but its own checker.
# THE DISCRIMINATOR IS THE QUOTING, which the first version of this rule got
# wrong by flagging any trap mentioning `rm -rf` and a `$`: that is also the
# CORRECT form, where the variable already holds a literal expanded at arm time.
# A SINGLE-quoted trap string defers to fire time and is the dangerous one; a
# double-quoted one has already expanded. So the pattern is a single-quoted trap
# carrying both `rm -rf` and a `$`.
#
# lint.t IS EXCLUDED BY NAME because a checker necessarily contains the shape it
# looks for, the same reason the dash-name rule below excludes its own message.
_trp=$T/traps
( cd "$HERE" && grep -rnE "trap '[^']*rm -rf[^']*\\\$" \
  bin lib libexec test share setup.sh desktop-notifier 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE '^test/lint\.t:' ) >"$_trp" || true
if [ -s "$_trp" ]; then
  printf 'FAIL %s: a destructive trap defers its expansion:\n' "$_name" >&2
  sed 's/^/  /' "$_trp" >&2
  printf 'Bake the literal in at ARM time: _C="'"'"'$DIR'"'"'"; ' >&2
  printf 'trap "rm -rf $_C" EXIT\n' >&2
  printf 'This shape deleted this repository once.\n' >&2
  exit 1
fi

# --- A VARIABLE ASSIGNMENT ON A FUNCTION CALL IS UNSPECIFIED ---------------
# `VAR=x somefunc` does NOT mean the same thing in every shell, and POSIX says
# so: for a FUNCTION (unlike an external command) whether the assignment
# survives the call is unspecified. MEASURED, all five shells this tree meets:
#
#     dash                 does NOT persist
#     bash 5 (sh or bash)  does NOT persist
#     bash 3.2 as sh       PERSISTS      <- macOS /bin/sh
#     ksh                  PERSISTS      <- the login shell on these boxes
#
# SO IT LEAKS INTO THE NEXT CALL on exactly the two shells nobody develops in.
# test/mux-agent.t had twenty of these and the leak produced a real failure:
# `CLASS=agent run send ...` left CLASS set, so the NEXT case, which exists to
# prove that a human's pane is never granted, ran against a pane classified
# `agent` and was granted. It reported `human-star-rc: got [0] want [1]` on
# macOS and passed here, and the assertion it defeated is a SECURITY one.
#
# THE FIX IS `; unset VAR` ON THE SAME LINE, which is why this rule can be
# mechanical: it keeps the concise call style, it is a no-op in the shells that
# already scope it, and having it on the same line means the reader sees the
# whole lifetime at once.
#
# SCOPED TO A LINE-LEADING PREFIX, deliberately. Inside `$( )` the command runs
# in a SUBSHELL, so a leak dies with it and needs nothing; every dangerous site
# in this tree was a bare call at line start and every safe one was a
# substitution, so the distinction is not a guess.
#
# AND ONLY FOR A FUNCTION DEFINED IN THAT FILE. `VAR=x /some/program` is
# perfectly well specified and used all over this suite; the whole hazard is
# the function case. That check is what the naming rule bought elsewhere: it
# needs the list of function names, so the program reads each file twice.
cat >"$T/prefix.awk" <<'AWK'
# pass 1: the functions this file defines. pass 2: line-leading assignment
# prefixes calling one of them with no `unset` on the line.
NR == FNR {
  if ($0 ~ /^[A-Za-z_][A-Za-z_0-9]*\(\)[ \t]*\{/) {
    nm = $0; sub(/\(\).*/, "", nm); fn[nm] = 1
  }
  next
}
/^[ \t]*#/ { next }
/unset/ { next }
{
  s = $0
  sub(/^[ \t]+/, "", s)
  k = 0
  more = 1
  while (more) {
    more = 0
    # a value is a single-quoted run, a double-quoted run, or a blank-free
    # run that carries no `;` (a separate command), no substitution, and no
    # `)`. THE PAREN IS WHAT KEEPS A CASE ARM OUT: `fg=*) _sgr_color ...` in
    # bin/mux reads as an assignment of `*)` otherwise, and the first two
    # things this rule reported were exactly that.
    if (match(s, /^[A-Za-z_][A-Za-z_0-9]*='[^']*'[ \t]+/) \
     || match(s, /^[A-Za-z_][A-Za-z_0-9]*="[^"]*"[ \t]+/) \
     || match(s, /^[A-Za-z_][A-Za-z_0-9]*=[^ \t;`"'\''$()]*[ \t]+/)) {
      s = substr(s, RLENGTH + 1)
      k++
      more = 1
    }
  }
  if (k > 0) {
    split(s, w, /[ \t]/)
    if (w[1] in fn) printf "%s:%d: %s\n", FILENAME, FNR, $0
  }
}
AWK
_pfx=$T/prefix
: >"$_pfx"
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  awk -f "$T/prefix.awk" "$_f" "$_f" >>"$_pfx" || true
done <"$_list"
if [ -s "$_pfx" ]; then
  printf 'FAIL %s: a variable assignment prefixes a FUNCTION call:\n' \
    "$_name" >&2
  sed 's|^'"$HERE"'/||' "$_pfx" >&2
  printf '\nWhether that assignment survives the call is UNSPECIFIED: it\n' >&2
  printf 'persists in bash 3.2 (macOS /bin/sh) and in ksh, and not in\n' >&2
  printf 'dash or bash 5. Append `; unset VAR` on the same line.\n' >&2
  exit 1
fi

# --- `${*##pat}` IS PER-ELEMENT IN bash AND JOINED IN dash -----------------
# The single biggest macOS cluster this suite has had: SEVEN failing tests from
# one idiom. Measured, `set -- has-session -t =api` in three shells:
#
#     dash           ${*##*=}  ->  [api]
#     bash --posix   ${*##*=}  ->  [has-session -t api]
#     bash           ${*##*=}  ->  [has-session -t api]
#
# POSIX says pattern removal on `$*`/`$@` applies to EACH parameter, so bash is
# the conformant one and dash's join-first is the lenient reading. Every stub in
# this suite wanted the joined reading, so all of them rested on an ambiguity
# that only a second shell could expose: macOS `/bin/sh` IS bash, so a stub
# answering `tmux has-session -t =api` returned the WHOLE ARGV as the session
# name, grep found nothing, and mux correctly said `no such session: api`. Two
# tests died silently and five failed, all of them reading as mux defects.
#
# `_j=$*` FIRST, THEN STRIP, is identical in all three. The rule rather than the
# vigilance: a stub cannot call a harness helper (it is a separate script,
# executed under its own shebang), so the only thing that stops this coming back
# is a check.
_star=$T/star
( cd "$HERE" && grep -rn '\${\*[#%]' bin lib libexec test share setup.sh \
  2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' ) >"$_star" || true
if [ -s "$_star" ]; then
  printf 'FAIL %s: pattern removal directly on $*:\n' "$_name" >&2
  sed 's/^/  /' "$_star" >&2
  printf 'bash applies it PER PARAMETER and dash to the joined string.\n' >&2
  printf 'Assign first: `_j=$*; _j=${_j##pat}`.\n' >&2
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
  bin lib libexec share setup.sh 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | grep -vE 'grep( +-[a-zA-Z]+)* +-- ' ) >"$_dash" || true
if [ -s "$_dash" ]; then
  printf 'FAIL %s: grep pattern from a variable, with no `--`:\n' "$_name" >&2
  sed 's/^/  /' "$_dash" >&2
  printf 'A name starting with `-` is read as OPTIONS.\n' >&2
  # conventions: allow -- the dashes below are the end-of-options marker this
  # check exists to require, printed as the example to copy. Rewording them
  # would print advice that fails the very rule it is giving.
  printf 'Write it as: grep -qxF -- "$x"\n' >&2
  exit 1
fi

# --- the exit-code contract, mechanically -------------------------------
# NO LITERAL `exit <digit>` AT ALL in bin/, lib/ or libexec/: the names in
# lib/mux-exit_lib say which condition is being reported, where a bare 2, 3 or
# 4 does not. The ABSENCE of every other code is what the set buys, so a
# caller attributes 255 to ssh and 127 to a missing binary rather than to mux.
#
# THREE EXCEPTIONS, and each is a different language or a different contract,
# listed here because an exemption nobody can explain becomes a hole:
#
#   an `exit` inside an awk/sed PROGRAM   awk's exit, not the shell's, and
#                                         `$MUX_EC_X` in a single-quoted
#                                         program is a literal string awk
#                                         evaluates as 0
#   an `exit` inside a `( )` SUBSHELL     the subshell's true/false, read by
#                                         the caller as a predicate
#   share/ hooks                          the 0/1/78 hook contract, checked
#                                         separately below
#
# test/mux-exit.t pins what today's verbs return; this holds the rule against
# code nobody has written.
#
# Whole-line COMMENTS are excluded and have to be: a file that classifies a
# FOREIGN code must name it to explain itself, and mux-latch documenting "ssh
# exits 255" is the opposite of mux exiting 255. A trailing comment on a real
# line is still caught.
#
# share/latch/ AND share/desktop-notifier/ ARE A DIFFERENT CONTRACT, checked
# separately below rather than excluded. A hook answers a QUESTION in three
# states (0 yes, 1 no, 78 cannot tell), and 78 is the point: "cannot tell" must
# be distinguishable from "no", or an edge nobody can check reports as fine.
# Exempting the directories with a hole would let a hook invent a fourth code.
_ecset=$(sed -n 's/^MUX_EC_[A-Z]*=\([0-9]*\).*/\1/p' "$HERE/lib/mux-exit_lib" \
  | sort -u | tr -d '\n')
[ -n "$_ecset" ] || fail "no MUX_EC_* declarations found in lib/mux-exit_lib,
so the exit-code rule below would allow everything"
# TWO NAMED EXEMPTIONS, both in one file and both the subshell case: the
# status of a `( )` read by the caller as a predicate is a true/false, not one
# of mux's codes. Named here rather than pattern-matched, because "is this
# exit inside a subshell" is not a question a grep can answer.
_ecx='lib/mux-send-policy_lib'
_ec=$T/exitcodes
# A single-quoted `exit N` is an awk or sed program's own exit, in a language
# where `"$MUX_EC_FAIL"` would be a literal string evaluating to 0. That is
# not a hypothetical: this sweep converted one and the mutation went silent.
#
# A DIGIT INSIDE A PARAMETER EXPANSION IS STILL A LITERAL EXIT CODE, and the
# first version of this rule could not see one. `exit "${1:-2}"` in the usage
# path carried a magic 2 through the whole sweep: the exit-code records then
# reported MUX_EC_USAGE as UNKILLABLE, because the most-travelled error path
# in mux never read it.
#
# AND THE BOOTSTRAP GUARD CANNOT USE THE LIB IT IS CHECKING FOR, so the line
# that reports mux-exit_lib missing keeps a literal. It is written with the
# exit ON that line precisely so this exemption is one grep and names itself.
( cd "$HERE" && grep -rnE '\bexit ([0-9]+|"?\$\{[A-Za-z_0-9]+:-[0-9]+\}"?)' \
    bin lib libexec setup.sh \
  2>/dev/null \
  | grep -vE "^($_ecx):" \
  | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#" \
  | grep -vE "'[^']*\bexit [0-9]+[^']*'" \
  | grep -vE 'mux-exit_lib' ) >"$_ec" || true
if [ -s "$_ec" ]; then
  printf 'FAIL %s: a literal exit code in shipped code:\n' "$_name" >&2
  sed 's/^/  /' "$_ec" >&2
  printf 'Use the MUX_EC_* name from lib/mux-exit_lib (%s), so the\n' \
    "$(printf '%s' "$_ecset" | sed 's/./&, /g; s/, $//')" >&2
  printf 'call site says WHICH condition it reports. See test/mux-exit.t\n' >&2
  printf 'and man mux EXIT STATUS.\n' >&2
  exit 1
fi

# AND A FILE USING THE NAMES MUST GET THEM FROM SOMEWHERE. bin/ and libexec/
# source the lib; a lib cannot source another, so it declares the dependency
# in its header and the caller supplies it. Without this, a forgotten source
# is an unset variable under `set -u`, which is loud but only on the path that
# exits.
_ecs=$T/ecsrc
: >"$_ecs"
for _f in "$HERE"/bin/mux "$HERE"/libexec/* "$HERE"/lib/*_lib \
    "$HERE"/setup.sh; do
  [ -f "$_f" ] || continue
  grep -vE '^[[:space:]]*#' "$_f" | grep -q 'MUX_EC_' || continue
  case ${_f##*/} in mux-exit_lib) continue ;; esac
  grep -q 'mux-exit_lib' "$_f" || printf '%s\n' "${_f#"$HERE"/}" >>"$_ecs"
done
if [ -s "$_ecs" ]; then
  printf 'FAIL %s: uses MUX_EC_* without sourcing or declaring the lib:\n' \
    "$_name" >&2
  sed 's/^/  /' "$_ecs" >&2
  exit 1
fi

# --- the HOOK contract: a latch hook answers 0, 1 or 78, and nothing else ---
_hc=$T/hookcodes
( cd "$HERE" && grep -rnE '\bexit [0-9]+' share/latch share/desktop-notifier \
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
for _h in "$HERE"/share/latch/* "$HERE"/share/desktop-notifier/*; do
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
# THE DIRECTORY NOW CARRIES THE ROLE TOO, which is a stronger signal than the
# name and is asserted alongside it: lib/ is what mux SOURCES and libexec/ what
# it EXECUTES (FHS), so a file in the wrong one is caught even if it is named
# correctly, and a file named wrongly is caught even if it is placed correctly.
for _f in "$HERE"/lib/*; do
  [ -f "$_f" ] || continue
  [ ! -x "$_f" ] || fail "$(basename "$_f") is in lib/, which mux SOURCES, and
is EXECUTABLE. The bit is a lie: running it does nothing useful."
  case $_f in *_lib) ;; *)
    fail "$(basename "$_f") is in lib/ but is not named *_lib, so the two
signals for 'sourced library' disagree." ;;
  esac
done
for _f in "$HERE"/libexec/*; do
  [ -f "$_f" ] || continue
  case $_f in
    *_lib)
      fail \
        "$(basename "$_f") is named as a sourced library but sits in libexec/,
which mux EXECUTES. Sourced libraries live in lib/."
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
