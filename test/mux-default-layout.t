#!/bin/sh
# test/mux-default-layout.t - a FRESH install must be able to run `mux go`.
# With an empty $MUX_DIR and no per-project profile, `mux go NAME` builds from
# mux's own defaults: the shipped layouts/default arrangement, rooted at the
# project. This used to die on "mux: no layout: default", and it is the verb
# every quickstart opens with, so it is the one path that must never need
# configuration.
#
# tmux is stubbed in $T/bin and logs the session-building calls, so the run goes
# all the way through the build pass without starting a server or touching any
# real session. $MUX_DIR is a scratch dir (the empty-overlay case) and the cwd
# is a scratch dir, so no profile of the developer's can satisfy the lookup.
# BARE `mux go` is the path under test: a typed name that nothing knows is
# refused by design (see mux-discover.t), but the directory you stand in is
# always evidence enough to build.
set -eu
_name=mux-default-layout
. "$(dirname "$0")/harness_lib"

mkdir -p "$T/bin" "$T/emptyconf" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
# No server anywhere: `mux themes sync` skips every heal and `has-session`
# reports the session missing, so mux takes the BUILD path.
*list-sessions*|*has-session*) exit 1 ;;
*window_index*) printf '0\n' ;;
*pane_id*)      printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"

TMUXLOG=$T/log; : >"$TMUXLOG"
export TMUXLOG
PATH=$T/bin:$PATH
export PATH

# -u MUX_SHARE so bin/mux self-locates THIS checkout's share/, not an installed
# one; -u TMUX so the run reads as a plain shell, not a live client.
( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/emptyconf" \
  MUX_CACHE="$T/cache" "$HERE/bin/mux" go ) \
  || fail "mux go on a fresh install exited $?"

# The shape actually got built: a session named zz-scratch, opened on the
# window the default layout declares, and a full-width bottom pane.
grep -q 'new-session -d -s proj -n main' "$TMUXLOG" \
  || fail "no new-session for the default layout (see $TMUXLOG)"
grep -q 'split-window -v -f' "$TMUXLOG" \
  || fail "the default layout built no bottom pane"
# AND AT THE HEIGHT THE SPEC NAMES. `bottom 5-10` means 5 minimum, 10 at
# build, and the build uses the MAX: nothing asserted which end of that range
# reached tmux, so a `bottom_spec` that answered 5 (or the whole `5-10`
# string) built a differently shaped session and every check still passed.
# Measured as a gap while moving that function into lib/mux-build_lib, which
# carried no mutation record of any kind.
grep -q 'split-window -v -f -l 10 ' "$TMUXLOG" \
  || fail "the bottom pane was not built at the spec's MAX (10 rows). The
shipped default declares \`bottom 5-10\`, so bottom_spec must answer b_max=10;
the build log says: $(grep 'split-window' "$TMUXLOG")"
grep -q 'attach-session -t =proj' "$TMUXLOG" \
  || fail "mux did not attach the session it built"

# An explicit PROFILE that does not exist must still fail loud: building from
# defaults is for the NO-profile case, it must not paper over a typo.
if ( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/emptyconf" \
  MUX_CACHE="$T/cache" "$HERE/bin/mux" go proj nosuchprofile \
  >/dev/null 2>&1 ); then
  fail "an unknown explicit PROFILE should fail, not fall back"
fi

pass
