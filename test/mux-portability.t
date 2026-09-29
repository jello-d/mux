#!/bin/sh
# test/mux-portability.t - the BSD/macOS userland differences, tested on Linux.
#
# YOU CAN TEST A MACOS FAILURE WITHOUT A MAC, for the class that matters most
# here: mux's only real portability exposure is GNU-vs-BSD flags, and a tool
# stubbed to behave like the BSD one reproduces that exactly. The same technique
# the rest of this suite uses on `tmux`, `python` and `systemctl`.
#
# IT FOUND A REAL BUG THE FIRST TIME IT WAS RUN. `bin/mux` resolved its own
# location with `readlink -f ... || echo "$_self"`, and macOS had no
# `readlink -f` until 12.3 -- so on any older Mac the fallback was silently
# WRONG rather than merely unresolved. Through the install symlink
# (~/.local/bin/mux -> the clone) an unresolved $0 puts the prefix at ~/.local,
# so LIBEXEC became ~/.local/libexec while setup.sh installs the NAMESPACED
# ~/.local/libexec/mux. mux could not find its own libraries and reported
# "missing (incomplete install)", blaming the install rather than the missing
# tool.
#
# WHAT IS DELIBERATELY NOT HERE: bash-3.2 differences (mux is POSIX sh under
# dash, so the version macOS ships cannot matter), and anything needing a real
# Darwin kernel. Those belong on a macOS CI runner, which is what
# .github/workflows/test.yml is for. This file covers what a stub can honestly
# reach.
set -eu
_name=mux-portability
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/stub"

# A pre-Monterey readlink: everything except -f. Written to REJECT the flag the
# way BSD does rather than to ignore it, because ignoring it would silently
# return the wrong thing and the stub would be lying in mux's favour.
cat >"$T/stub/readlink" <<'EOF'
#!/bin/sh
case ${1:-} in
-f|-f*) echo "readlink: illegal option -- f" >&2; exit 1 ;;
esac
exec /usr/bin/readlink "$@"
EOF
chmod +x "$T/stub/readlink"

# The stub has to be WRONG in the way BSD is wrong, or this file proves nothing.
env PATH="$T/stub:$PATH" readlink -f / >/dev/null 2>&1 \
  && fail "the stub still accepts -f, so every assertion below would pass on a
tool that is not the one being modelled"

# A REAL INSTALL, because the bug only appears through the install's symlink and
# its namespaced libexec. Running ./bin/mux from the checkout cannot see it:
# there $0 is already the real path, which is exactly why this went unnoticed.
PREFIX=$T/prefix; export PREFIX
sh "$HERE/setup.sh" install >/dev/null 2>&1 || fail "setup.sh install failed"
[ -L "$PREFIX/bin/mux" ] || fail "the install is not a symlink, so this file is
no longer testing what it claims"
[ -d "$PREFIX/libexec/mux" ] || fail "the install is not namespaced, so the
failure mode this pins does not exist any more"

bsd() { env PATH="$T/stub:$PREFIX/bin:$PATH" "$@"; }

# --- it finds its own libraries with no `readlink -f` ---------------------
_o=$(bsd "$PREFIX/bin/mux" -V 2>&1) || fail "mux -V failed under a BSD
readlink: [$_o]"
case $_o in
mux\ *) ;;
*) fail "mux -V did not print a version under a BSD readlink: [$_o]" ;;
esac
case $_o in
*"incomplete install"*|*missing*) fail "mux could not find its own libexec
under a BSD readlink, which is the macOS bug this exists to catch: [$_o]" ;;
esac

# A VERB THAT SOURCES LIBRARIES, because -V might answer before any lookup.
_o=$(bsd "$PREFIX/bin/mux" skill --agents-md 2>&1) \
  || fail "a lib-sourcing verb failed under a BSD readlink: [$_o]"
case $_o in
'# Working with peer agents through mux'*) ;;
*) fail "mux skill printed something else under a BSD readlink: [$_o]" ;;
esac

# --- a CHAIN of symlinks, and a RELATIVE target --------------------------
# `readlink -f` follows a chain to the end and resolves relative targets against
# the link's own directory. A one-step fallback would pass the simple case above
# and break on either of these, which is how a hand-rolled resolver usually
# fails.
ln -sf "$PREFIX/bin/mux" "$T/l1"
ln -sf "$T/l1" "$T/l2"
_o=$(bsd "$T/l2" -V 2>&1) || fail "a symlink CHAIN broke it: [$_o]"
case $_o in mux\ *) ;; *) fail "chain: [$_o]" ;; esac

mkdir -p "$T/rel"
(cd "$T/rel" && ln -sf ../prefix/bin/mux m)
_o=$(bsd "$T/rel/m" -V 2>&1) || fail "a RELATIVE symlink target broke it: [$_o]"
case $_o in mux\ *) ;; *) fail "relative: [$_o]" ;; esac

# --- A SYMLINK LOOP IS NOT TESTABLE HERE, and saying so beats pretending ---
# The fallback bounds its walk at 40 links, because an unbounded loop in code
# that runs on every status-bar tick would spin forever. That bound is NOT
# asserted, and the first version of this file asserted it VACUOUSLY: a symlink
# loop cannot be EXECUTED (the kernel refuses with ELOOP before mux starts)
# so `$0` can never be one, and the test timed a command that never reached
# the resolver. Mutation said so -- removing the bound changed nothing.
#
# The bound stays: it is one comparison, and the cost of being wrong about
# reachability is a hung status bar. But no record claims it is covered, because
# a vacuous assertion is worse than an absent one -- it reads as coverage.

# --- the theme hash works with no `sha256sum` --------------------------
# macOS ships `shasum` and NO `sha256sum`, and themes load on every new tmux
# server, so a hasher that errors there makes the palette stamp meaningless at
# every start. End to end against a real server, because the stamp FILE is the
# observable and the bug was invisible to anything that only read the function.
#
# A CURATED PATH, NOT A STUB, and that distinction cost a wrong conclusion on
# the way here: a stub that EXISTS and exits 127 is "present but broken", which
# is not what macOS is. `command -v sha256sum` finds such a stub, picks it, and
# the fix looks broken when it is fine. Absence has to be modelled by absence.
if command -v tmux >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
  mkdir -p "$T/curated" "$T/tconf"
  for _c in sh dash sed awk sort cut tr cat xargs grep mkdir rm ls dirname \
      basename mktemp readlink tmux id wc head tail shasum; do
    _p=$(command -v "$_c" 2>/dev/null) && ln -sf "$_p" "$T/curated/$_c"
  done
  [ -e "$T/curated/sha256sum" ] && fail "the curated PATH still has sha256sum,
so this case models nothing"

  _sock=$(tmux_fresh_socket muxport)
  tmux -L "$_sock" new-session -d -x 80 -y 24 2>/dev/null \
    || fail "could not start a tmux server for the theme-hash case"
  _sp=$(tmux -L "$_sock" display-message -p '#{socket_path}')
  env PATH="$T/curated" MUX_CACHE="$T/thcache" MUX_SHARE="$HERE/share" \
    MUX_DIR="$T/tconf" TMUX="$_sp,0,0" \
    "$HERE/libexec/mux-themes" load >"$T/thout" 2>&1 || true
  _stamp=$(cat "$T/thcache"/* 2>/dev/null | head -1)
  tmux_drop_socket "$_sock"
  case ${_stamp:-} in
  ?*) ;;
  *) fail "the palette stamp is EMPTY with no sha256sum on PATH, so every tmux
server start on macOS would re-push the palette and compare against nothing.
themes load said: [$(head -2 "$T/thout")]" ;;
  esac
  case $(cat "$T/thout") in
  *'not found'*|*'illegal option'*) fail "themes load hit a missing or
BSD-incompatible tool: [$(cat "$T/thout")]" ;;
  esac
fi

# --- the rest of the userland: nothing GNU-only ships -------------------
# An audit rather than an execution, and it is the cheap half of this file: each
# of these is a flag BSD does not have, so one appearing in a shipped file is a
# macOS break waiting for its first user. Kept as a list because the tree is
# clean today and the point is that it stays that way.
# COMMENTS ARE EXCLUDED, or this check fails on the prose explaining it -- and
# a note saying "BSD has no `xargs -r`" is the opposite of a violation.
_gnuisms='grep[^|]*-[a-zA-Z]*P |sed -i|stat -c|date -r |date -d |ps --'
_gnuisms=$_gnuisms'|pgrep |xargs -r|realpath |nproc'
# SHELL FILES ONLY, by shebang, the same way test/lint.t picks its corpus.
# Documentation is not shipped code: share/skills/mux-agent/AGENTS.md documents
# `timed-out` and a `-t` flag, and a word in prose is not a call.
_shipped=$T/shipped
: >"$_shipped"
find "$HERE/bin" "$HERE/libexec" "$HERE/share" -type f 2>/dev/null \
  | while IFS= read -r _f; do
    case $_f in
    *.md|*.py|*.theme|*.layout|*.partition|*.agent|*.yaml)
      continue ;;
    esac
    case "$(head -1 -- "$_f" 2>/dev/null)" in
    '#!'*/sh|'#!'*/dash|'#!'*/bash|'#!'*env\ sh) printf '%s\n' "$_f" ;;
    esac
  done >>"$_shipped"
printf '%s\n' "$HERE/setup.sh" >>"$_shipped"
[ "$(grep -c . "$_shipped")" -ge 20 ] || fail "only $(grep -c . "$_shipped")
shipped shell files found; the discovery is broken and the audit below would
pass vacuously"

# shellcheck disable=SC2046,SC2013   # one path per line, no spaces in any of
# them (they are this repo's own files), so word splitting is what is wanted and
# a `while read` loop would need a subshell to accumulate the hits.
_hits=$(grep -nE "$_gnuisms" $(cat "$_shipped") 2>/dev/null \
  | grep -vE '^[^:]*:[0-9]*: *#' || true)
[ -z "$_hits" ] || fail "GNU-only construct(s) in shipped code, which a BSD
userland does not have:
$_hits"

# `timeout` IS GNU AND IS ALLOWED, guarded. It has no BSD equivalent and mux
# uses it only as a backstop, so the rule is that any shipped file reaching for
# it must also ASK for it first -- which share/latch/ssh-probe already does.
# TWO TOOLS ARE ALLOWED IF ASKED FOR FIRST. `timeout` has no BSD equivalent and
# mux uses it only as a backstop; `sha256sum` has one under another name. Either
# way the rule is the same: a shipped file may reach for it only if that same
# file also ASKS whether it is there. That is what share/latch/ssh-probe and
# libexec/mux-themes already do, and it is the pattern to copy.
for _t in timeout sha256sum; do
  # shellcheck disable=SC2046,SC2013   # as above: this repo's own paths
  for _f in $(grep -l -- "$_t" $(cat "$_shipped") 2>/dev/null); do
    # A use, not a mention: a non-comment line that is not the guard itself.
    grep -E "^[^#]*[^-]$_t" "$_f" | grep -qv 'command -v' || continue
    grep -q "command -v $_t" "$_f" || fail "$_f uses \`$_t\` without asking
whether it exists. A BSD userland does not have it under that name, so it fails
there rather than degrading."
  done
done

pass
