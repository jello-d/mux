#!/bin/sh
# test/mux-context.t - the CONTEXT seam (lib/mux-context_lib): one word in,
# every setting out.
#
# The contract is deliberately tiny: an optional command prints a token, and
# mux decides the partition, the socket, the theme, the banner and the scan
# roots itself. What this guards:
#
#   - a token is VALIDATED before it becomes a socket name and a path
#     component, and an invalid one is an error rather than a silent fall back
#     to the baseline (which would put work sessions in the personal
#     partition);
#   - settings resolve built-in -> partition -> context, unconditionally, so
#     there is no per-key scope rule to remember;
#   - the built-in defaults carry NO location keys, which is what stops `scan`
#     leaking from one partition into another.
#
# Pure file and string logic against a scratch $MUX_DIR; nothing is launched.
set -eu
_name=mux-context
. "$(dirname "$0")/harness_lib"

MUX_DIR=$T/conf
MUX_SHARE=$T/share
export MUX_DIR MUX_SHARE
mkdir -p "$MUX_DIR/partitions" "$MUX_DIR/contexts" "$MUX_SHARE/partitions"
# mux-conf_lib FIRST, which mux-context_lib's header declares: its config
# read goes through mux_conf_clean, so the one comment rule covers this file
# too. Without it the reader answers nothing and every resolution is baseline,
# which is how the suite found the missing source rather than by review.
. "$HERE/lib/mux-conf_lib"
. "$HERE/lib/mux-context_lib"

eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }
# cc BODY: install a context-command with that body.
cc() {
  printf '#!/bin/sh\n%s\n' "$1" >"$T/cc"
  chmod +x "$T/cc"
  printf 'context-command %s\n' "$T/cc" >"$MUX_DIR/config"
}

# --- no command at all: the baseline ---------------------------------------
rm -f "$MUX_DIR/config"
mux_ctx_resolve || fail "resolve failed with no context-command"
eq bare-token "$MUX_CTX_TOKEN" global
eq bare-part  "$MUX_CTX_PARTITION" global
# EMPTY, not purple: "a context set a theme" must be distinguishable from
# "nobody did", which is what lets an explicit context theme beat the name
# hash. The last-resort colour is a separate constant.
eq bare-theme "$MUX_CFG_theme" ""
eq fallback "$MUX_THEME_FALLBACK" purple
eq bare-agent "$MUX_CFG_agent" claude
eq bare-derive "$MUX_CFG_derive" hash
# Built-ins carry BEHAVIOUR only. If a location ever creeps in here, every
# partition silently inherits it and the missing-config signal disappears.
eq builtin-no-scan "$MUX_CFG_scan" ""
eq builtin-no-label "$MUX_CFG_label" ""

# --- token validation -------------------------------------------------------
for _bad in '../etc' 'Work' 'has space' '-lead' 'trail-' 'a/b'; do
  mux_ctx_valid "$_bad" && fail "validator accepted [$_bad]"
done
for _good in manifest a acme-2 x9; do
  mux_ctx_valid "$_good" || fail "validator rejected [$_good]"
done
# An invalid token is an ERROR, not a quiet fall back to global.
cc 'echo ../../etc'
mux_ctx_resolve && fail "an invalid token should fail resolution"
case ${MUX_CTX_ERR:-} in
  *"invalid context token"*) ;; *) fail "no useful error: [${MUX_CTX_ERR:-}]" ;;
esac

# --- a FAILING context-command has not answered ----------------------------
# Its stdout is not an answer either. The status has to be read before the
# output is trimmed: a pipeline reports its LAST command's status, so piping
# the command straight into head/tr would report tr's success and trust the
# output of a command that failed.
cc 'echo shouldbeignored; exit 1'
mux_ctx_resolve || fail "a failing context-command should resolve to global"
eq failed-token "$MUX_CTX_TOKEN" global

# ...and it must not be mistaken for an INVALID token either: it said nothing.
case ${MUX_CTX_ERR:-} in
  '') ;; *) fail "a failing command set an error: [${MUX_CTX_ERR:-}]" ;;
esac

# A command that fails while printing something INVALID is still just global,
# not a validation error: there is no token to validate.
cc 'echo ../../etc; exit 1'
mux_ctx_resolve || fail "failing command with bad output should be global"
eq failed-bad-token "$MUX_CTX_TOKEN" global

# --- a token with no files at all ------------------------------------------
cc 'echo lonely'
mux_ctx_resolve || fail "resolve failed for an unconfigured token"
eq lonely-token "$MUX_CTX_TOKEN" lonely
# The partition still applies: that is the load-bearing part, and why an
# unconfigured context is a warning rather than a refusal.
eq lonely-part "$MUX_CTX_PARTITION" lonely
eq lonely-unknown "$MUX_CTX_UNKNOWN" 1
# ... and it gets no scan roots, so discovery is visibly off rather than
# quietly pointed at somebody else's tree.
eq lonely-scan "$MUX_CFG_scan" ""

# --- partition file supplies the settings ----------------------------------
printf 'label Manifest\ntheme orange\nscan %s/w 3\n' "$T" \
  >"$MUX_DIR/partitions/work.partition"
cc 'echo manifest'
mux_ctx_resolve || fail "resolve failed with a partition file"
eq part-token "$MUX_CTX_TOKEN" manifest
eq part-part  "$MUX_CTX_PARTITION" manifest
eq part-label "$MUX_CFG_label" Manifest
eq part-theme "$MUX_CFG_theme" orange
eq part-scan  "$MUX_CFG_scan" "$T/w 3"
eq part-known "$MUX_CTX_UNKNOWN" 0
# A behaviour key it did not set still comes from the built-ins.
eq part-inherit "$MUX_CFG_agent" claude
# A .partition file with no .context file is NOT unknown: a context whose
# settings are entirely partition-shared needs no file of its own.

# --- a context may join another partition ----------------------------------
printf 'scan %s/g 3\n' "$T" >"$MUX_DIR/partitions/global.partition"
printf 'partition global\nagent gemini\n' >"$MUX_DIR/contexts/gpu.context"
cc 'echo gpu'
mux_ctx_resolve || fail "resolve failed for a shared partition"
eq gpu-token "$MUX_CTX_TOKEN" gpu
eq gpu-part  "$MUX_CTX_PARTITION" global
eq gpu-agent "$MUX_CFG_agent" gemini
# It inherits the GLOBAL partition's roots, because that is the partition it
# joined, which is the whole point of letting contexts share one.
eq gpu-scan "$MUX_CFG_scan" "$T/g 3"

# --- the context wins over its partition -----------------------------------
printf 'partition global\ntheme cyan\nscan %s/own 2\n' "$T" \
  >"$MUX_DIR/contexts/gpu.context"
mux_ctx_resolve || fail "resolve failed with context overrides"
eq ctx-over-part "$MUX_CFG_theme" cyan
# A context's scan REPLACES the partition's rather than adding to it.
eq ctx-scan-replaces "$MUX_CFG_scan" "$T/own 2"

# --- repeatable scan within one file ---------------------------------------
printf 'scan %s/a 1\nscan %s/b 2\n' "$T" "$T" \
  >"$MUX_DIR/partitions/global.partition"
printf 'partition global\n' >"$MUX_DIR/contexts/gpu.context"
mux_ctx_resolve || fail "resolve failed with repeated scan keys"
eq scan-repeat "$(printf '%s' "$MUX_CFG_scan" | tr '\n' '|')" "$T/a 1|$T/b 2"

# --- an unknown key is ignored, not fatal ----------------------------------
# These files are commonly generated; a newer mux writing a key this one does
# not know must not break it.
printf 'partition global\nfuture-key whatever\ntheme red\n' \
  >"$MUX_DIR/contexts/gpu.context"
mux_ctx_resolve || fail "an unknown key should not fail resolution"
eq unknown-key-ok "$MUX_CFG_theme" red

# --- a bare context-command resolves against $MUX_DIR ----------------------
# The config file is commonly shared between machines through a dotfiles repo,
# so it must not have to carry an absolute path that is right on only one.
printf '#!/bin/sh\necho bare\n' >"$MUX_DIR/tok"; chmod +x "$MUX_DIR/tok"
printf 'context-command tok\n' >"$MUX_DIR/config"
mux_ctx_resolve || fail "a bare context-command should resolve"
eq bare-cmd "$MUX_CTX_TOKEN" bare

# --- the socket is derived, and global is an ordinary name -----------------
eq socket-derived "$(mux_ctx_socket global)" global
eq socket-named "$(mux_ctx_socket manifest)" manifest

# --- every partition is discoverable, for reload and palette sync ----------
_p=$(mux_ctx_partitions | tr '\n' ' ')
case $_p in
  *global*) ;; *) fail "partitions omitted global: [$_p]" ;;
esac
case $_p in
  *manifest*) ;; *) fail "partitions omitted manifest: [$_p]" ;;
esac

# --- A COMMENT IN THE CONFIG IS A COMMENT HERE TOO -------------------------
# This reader used to carry its OWN sed, which dropped a full-line comment
# and left an INLINE one inside the value, so it disagreed with every other
# config reader in the tree about the same bytes. Not cosmetic: the value is
# EXECUTED (context-command) or validated as a list of variable names
# (env-ready), and in the second case the stray `#` reads as a name nothing
# manages, which makes `mux resume` exit 2, which ssh-classify calls
# `refused`, which is TERMINAL. A latch gives up for ever on a box that is
# fine, because somebody commented their own config.
#
# TWO KEYS, TWO ASSERTIONS, because they fail differently and one check kills
# neither: the command is run and the list is parsed.
printf '%s\n' \
  '# a full-line comment' \
  'context-command  tok   # which severance am I in' \
  'env-ready  WAYLAND_DISPLAY  # wait for the compositor' >"$MUX_DIR/config"
eq inline-comment-stripped "$(mux_ctx_conf env-ready)" WAYLAND_DISPLAY
mux_ctx_resolve || fail "a commented context-command line should still
resolve: the inline comment is being passed to the command as arguments"
eq inline-comment-cmd "$MUX_CTX_TOKEN" bare

# ... and a hash with NO space before it is part of the token, which is the
# other half of the one rule and the reason it cannot be a plain `s/#.*//`:
# a colour literal is the shape that proved it.
printf 'env-ready  A#B\n' >"$MUX_DIR/config"
eq hash-inside-token "$(mux_ctx_conf env-ready)" 'A#B'

# --- mux_ctx_mine: THE CALLER'S OWN PARTITION, OR NOTHING -----------------
# Seven places derived this by hand (`mux_ctx_resolve 2>/dev/null &&
# _x=$MUX_CTX_PARTITION`), every one a headless caller with no $TMUX to take a
# namespace from. One answer in one place, because this package has shipped
# the wrong-socket bug three times and every time the cause was one answer
# derived in two.
cc 'echo work'
eq mine-answers "$(mux_ctx_mine)" work

# A HOOK THAT EXITS NON-ZERO IS STILL AN ANSWER, and it is `global`. Measured,
# because the function's exit status does NOT distinguish these three and
# reading it as if it did is how the wrong partition gets acted on:
#
#     no context-command at all   rc 0  part=global  src=baseline
#     the command EXITS 1         rc 0  part=global  src=failed
#     the command names one       rc 0  part=work    src=command
#
# So the discriminator is MUX_CTX_SRC, and `mux_ctx_mine` DOES NOT CARRY IT:
# a command substitution is a subshell, so a caller that must tell a broken
# hook from an absent one has to call `mux_ctx_resolve` directly. None of the
# seven callers converted to this helper does, and `mux resume`, which is the
# one verb that refuses on `failed`, was deliberately not converted. Written
# down here because the hidden side effect is the trap this tree already paid
# for when `$(_remote_cmd)` discarded the cache it had just filled.
printf '#!/bin/sh\nexit 1\n' >"$T/cc"; chmod +x "$T/cc"
printf 'context-command %s\n' "$T/cc" >"$MUX_DIR/config"
eq mine-failed-is-global "$(mux_ctx_mine)" global

# EMPTY ONLY WHEN RESOLUTION ITSELF FAILS, which is an INVALID token or
# partition and nothing else. That is the case the seven hand-written copies
# guarded with `&&`, and preserving it is the whole reason this returns early
# rather than printing unconditionally: a caller then decides what an
# unanswerable context costs it. `mux agent` scopes to global, because failing
# OPEN is the one answer an actuating verb must not give; `mux resume`
# refuses, because resuming the baseline hands you another partition's
# sessions while looking like success.
cc 'echo NOPE'
eq mine-unresolvable-is-empty "$(mux_ctx_mine)" ""

# AND A NON-ZERO RESOLVE MUST NOT TAKE THE CALLER DOWN. Every call site is
# `_x=$(mux_ctx_mine)` under `set -eu`, so a bare non-zero return inside the
# substitution kills the shell: the exact truncation `mux_env_plan` shipped,
# where one invalid name silently cut off every name after it.
_mine_rc=0
( set -eu; _x=$(mux_ctx_mine); : "$_x" ) || _mine_rc=$?
[ "$_mine_rc" -eq 0 ] || fail "mux_ctx_mine returned non-zero with an
unresolvable context, so every caller that assigns it under set -eu dies
silently inside a command substitution. rc=$_mine_rc"

pass
