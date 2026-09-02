#!/bin/sh
# test/mux-verbs.t - the consolidated interface: verbs that were really flags
# folded into flags, with the old spellings kept as aliases so muscle memory
# and existing scripts keep working. Plus the collision guard, `mux why`, and
# that the help listings actually SEE the profile table.
set -eu
_name=mux-verbs
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/bin" "$T/conf/profiles.d" "$T/proj"
cat >"$T/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$TMUXLOG"
case "$*" in
*has-session*)   [ -n "${LIVE:-}" ] && exit 0; exit 1 ;;
*list-sessions*)
	[ -n "${LIVE:-}" ] || exit 1
	printf '%s %s\n' "$LIVE" "$LIVEROOT" ;;
*window_index*)  printf '0\n' ;;
*pane_id*)       printf '%%1\n' ;;
esac
exit 0
EOF
chmod +x "$T/bin/tmux"
TMUXLOG=$T/log; export TMUXLOG
PATH=$T/bin:$PATH; export PATH

mux() {
	( cd "$T/proj" && env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" \
		MUX_CACHE="$T/cache" "$HERE/bin/mux" "$@" ) 2>&1
}
fails() {  # LABEL WANT ARGS...
	_l=$1 _w=$2; shift 2
	_o=$(mux "$@") && fail "$_l: expected a non-zero exit, got [$_o]"
	case $_o in *"$_w"*) ;; *) fail "$_l: want [$_w], got [$_o]" ;; esac
}

# --- the flag forms and the retired verbs are the same command --------------
# Both must reach the same gate: --all takes no NAME either way.
fails all-flag  "takes no NAME" kill --all zz
fails all-verb  "takes no NAME" kill-all zz
# ... and without --all, kill still demands one.
fails kill-bare "needs a NAME, or --all" kill

# --all belongs to kill/show only, from either position.
fails all-gate  "--all is only for kill/show" ls --all
fails all-gate2 "--all is only for kill/show" --all ls

# --- --bare is still accepted, --no-agent is the name -----------------------
fails noagent-gate "--no-agent is only for go/new" ls --no-agent
fails bare-gate    "--no-agent is only for go/new" ls --bare

# --- the version is one constant, not a hardcoded string --------------------
case "$(mux --version)" in
mux\ [0-9]*) ;; *) fail "--version: got [$(mux --version)]" ;;
esac
[ "$(mux --version)" = "$(mux -V)" ] || fail "-V and --version disagree"

# --- help LISTS the table, which is the primary form now --------------------
printf 'alpha       theme=cyan\n' >"$T/conf/profiles"
printf 'theme red\n' >"$T/conf/profiles.d/bravo.profile"
_h=$(mux --help || true)
case $_h in *alpha*) ;; *) fail "--help omits a table row" ;; esac
case $_h in *bravo*) ;; *) fail "--help omits a breakout profile" ;; esac
_p=$(mux help profiles)
case $_p in *alpha*) ;; *) fail "help profiles omits a table row" ;; esac
case $_p in *bravo*) ;; *) fail "help profiles omits a breakout" ;; esac

# --- mux why explains each field, and names its source ----------------------
_w=$(mux why alpha)
case $_w in
*"theme"*cyan*declared*) ;; *) fail "why: theme not declared: $_w" ;;
esac
case $_w in
*"(row)"*) ;; *) fail "why: did not name the row as the source: $_w" ;;
esac
# A fully derived session says so, and names the derivation for each field.
_w=$(mux why undeclared)
case $_w in *"(none)"*) ;; *) fail "why: should report no profile: $_w" ;; esac
case $_w in *"hashed from the name"*) ;;
*) fail "why: did not attribute the derived theme: $_w" ;;
esac

# --- why says WHERE, and flags a root that is not there ---------------------
# The confusing case: a directory whose basename matches a profile rooted
# somewhere ELSE. Without saying so, the output reads as if that root described
# where you are standing.
mkdir -p "$T/proj/elsewhere"
printf 'proj        root=%s/proj/elsewhere\n' "$T" >"$T/conf/profiles"
_w=$(mux why)
case $_w in
*"where"*) ;; *) fail "why does not say where it is answering about" ;;
esac
case $_w in
*"NOT where you are"*) ;;
*) fail "why did not flag a profile root that differs from the cwd: [$_w]" ;;
esac
# It also EXPLAINS the collision rather than only marking it: the name came
# from the directory, the profile it landed on lives elsewhere, and `mux go`
# here will refuse. Answering "why is it talking about a directory I did not
# mention" is the whole job of this verb.
case $_w in
*"but it is also a"*) ;;
*) fail "why flagged the mismatch without explaining it: [$_w]" ;;
esac

# --- and `mux go` refuses rather than building the wrong project ------------
# Same rule as the live-session guard, one step earlier: a name mux DERIVED
# must not silently resolve somewhere you did not ask for.
_o=$(mux go) && fail "a derived name colliding with a profile should refuse"
case $_o in
*"already means"*) ;; *) fail "unhelpful collision error: [$_o]" ;;
esac
# A TYPED name is still trusted -- looking a profile up by name is the point.
mux go proj >/dev/null || fail "a typed name should still resolve"

# ... and when the root DOES match, no alarming marker.
printf 'proj        root=%s/proj\n' "$T" >"$T/conf/profiles"
_w=$(mux why)
case $_w in
*"NOT where you are"*) fail "why flagged a root that is exactly here" ;;
esac

# --- why does not print an alternative identical to the declared value ------
# "declared (x would give x)" reads like a bug rather than an explanation.
printf 'proj        theme=purple\n' "$T" >"$T/conf/profiles"
mkdir -p "$T/conf/partitions"
printf 'theme purple\n' >"$T/conf/partitions/global.partition"
_w=$(mux why)
case $_w in
*"would give purple"*) fail "why showed a redundant alternative: [$_w]" ;;
esac
rm -f "$T/conf/partitions/global.partition"

# --- the collision guard: a DERIVED name meeting a live session elsewhere ---
LIVE=proj; LIVEROOT=$T/somewhere-else; export LIVE LIVEROOT
fails collide "is live at" go
fails collide-fix "--attach" go
# An explicit name is trusted -- looking a session up by the name you typed is
# what a name argument is for.
mux go proj >/dev/null || fail "a typed name should attach without the guard"
# ... and --attach overrides it for the derived case.
mux go --attach >/dev/null || fail "--attach did not override the guard"
# No mismatch, no guard.
LIVEROOT=$T/proj
mux go >/dev/null || fail "same-root attach should not be guarded"

pass
