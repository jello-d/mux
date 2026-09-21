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
# `|| true`: `undeclared` is a name nothing knows, so why exits 3, and an
# unguarded substitution takes the file down SILENTLY under `set -e` -- the
# only symptom is the test disappearing from the runner's list.
_w=$(mux why undeclared || true)
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
printf 'proj        theme=purple
' >"$T/conf/profiles"
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

# --- `mux help TOPIC` must reach the TOPIC ---------------------------------
# This was an inline block where $1 was the script's first POSITIONAL -- the
# topic. Extracting it into cmd_help() without passing "$@" made $1 the
# FUNCTION's own, which is unset, so every topic silently fell through to the
# usage summary. Silently, because printing usage is a plausible thing for a
# help verb to do, so nothing looked wrong.
for _t in agents themes profiles; do
	_o=$(mux help "$_t" 2>&1 | head -1)
	case $_o in
	"$_t"*) ;;
	*) fail "mux help $_t did not reach the topic: [$_o]" ;;
	esac
done
# ... and a bare `mux help` is still the usage summary.
case "$(mux help 2>&1 | head -1)" in
usage:*) ;;
*) fail "bare 'mux help' should print usage" ;;
esac

# --- `help palette` renders the 256-colour grid --------------------------
# The last functions the suite never reached: help_palette (the one function in
# bin/mux over the 50-line guideline), _palette_grid, _palette_preview and
# _sgr_frag. They need a TERMINAL, so without a pty the verb refuses and the
# whole grid is unreachable -- which is why it stayed dark.
#
# script(1) supplies the pty. Skipped rather than failed where it is absent: the
# package's stated floor is a shell and a checkout.
if command -v script >/dev/null 2>&1; then
	_pal=$(script -qc "env -u TMUX $HERE/bin/mux help palette" /dev/null \
		</dev/null 2>&1 || true)
	case $_pal in
	*"needs a terminal"*) fail "script(1) did not provide a pty" ;;
	esac
	# All three bands of the 256-colour space are labelled, so a truncated
	# grid is visible rather than merely shorter.
	for _band in "system 0-15" "cube 16-231" "grayscale 232-255"; do
		case $_pal in
		*"$_band"*) ;;
		*) fail "the palette is missing the $_band band" ;;
		esac
	done
	# Every colour is present, and each cell carries a real SGR pair (fg AND
	# bg), since the whole point is that any colour works as either.
	for _n in 0 15 16 231 232 255; do
		case $_pal in
		*"48;5;${_n}m"*) ;;
		*) fail "colour $_n has no background SGR in the grid" ;;
		esac
	done
	case $_pal in
	*"38;5;"*) ;;
	*) fail "the grid sets no foreground, so a dark cell is unreadable" ;;
	esac
	# And it resets: a grid that leaks its last background would tint the
	# rest of the terminal.
	case $_pal in
	*"[0m"*) ;;
	*) fail "the palette never resets its styling" ;;
	esac

	# An explicit FG applies to every cell, rather than the per-cell black
	# and white contrast the bare form picks.
	_pf=$(script -qc "env -u TMUX $HERE/bin/mux help palette 226" \
		/dev/null </dev/null 2>&1 || true)
	case $_pf in
	*"fg 226 over every bg"*) ;;
	*) fail "an explicit palette fg was not honoured: [$_pf]" ;;
	esac
	case $_pf in
	*"38;5;226m"*) ;;
	*) fail "the requested fg never reached a cell" ;;
	esac

	# The status-bar PREVIEW form, which renders four chosen colours as the
	# bar would actually draw them. Reachable only through `test`, so it was
	# the last unexercised path in the file.
	_pt=$(script -qc \
		"env -u TMUX $HERE/bin/mux help palette test 231 54 16 214" \
		/dev/null </dev/null 2>&1 || true)
	case $_pt in
	*"bar fg=231 bg=54"*) ;;
	*) fail "the preview did not echo the bar colours: [$_pt]" ;;
	esac
	case $_pt in
	*"active fg=16 bg=214"*) ;;
	*) fail "the preview did not echo the active colours" ;;
	esac
	# It draws a real chip, not just a description.
	case $_pt in
	*"48;5;54m"*) ;;
	*) fail "the preview rendered no bar background" ;;
	esac
fi

# An unusable fg spec is refused with the accepted forms named, and exit 2 --
# not silently ignored, which would render a grid that answers a question you
# did not ask.
if command -v script >/dev/null 2>&1; then
	_bad=$(script -qec "env -u TMUX $HERE/bin/mux help palette notacolour" \
		/dev/null </dev/null 2>&1 || true)
	case $_bad in
	*"0-255, colourN, #rrggbb"*) ;;
	*) fail "a bad palette fg was not explained: [$_bad]" ;;
	esac
else
	printf 'note: %s palette grid unchecked (no script(1))\n' "$_name"
fi

# Without a terminal it refuses cleanly rather than emitting escapes into a
# pipe, which is what would happen if a caller redirected it.
_o=$(env -u TMUX "$HERE/bin/mux" help palette 2>&1)
case $_o in
*"needs a terminal"*) ;;
*) fail "help palette did not refuse without a tty: [$_o]" ;;
esac

pass
