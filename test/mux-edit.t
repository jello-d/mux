#!/bin/sh
# test/mux-edit.t - `mux edit` round-trips a one-line profile row through a
# multi-line DRAFT in the breakout file's syntax, so you edit the readable form
# while storage stays compact.
#
# Three behaviours carry the design:
#   - the draft path is DETERMINISTIC, so recovering a botched edit needs no
#     argument to be remembered or typed;
#   - a COMMENT (or a value with a space) cannot live in a one-line row, so it
#     is what promotes the entry to a breakout file -- the breakout happens
#     when you actually need it, never on a rule you have to remember;
#   - an unparseable draft is KEPT and reported, so a failed save hands your
#     work back rather than eating it.
#
# No tmux at all: `mux edit` is pure file work.
set -eu
_name=mux-edit
. "$(dirname "$0")/lib.sh"

mkdir -p "$T/conf" "$T/ed"
# ed NAME BODY : a scratch $EDITOR that rewrites the draft with BODY.
ed() {
	printf '#!/bin/sh\n%s\n' "$2" >"$T/ed/$1"
	chmod +x "$T/ed/$1"
}
ed show    'cat "$1"'
ed green   'printf "theme green\n" > "$1"'
ed comment 'printf "# why this one is special\ntheme plum\n" > "$1"'
ed spacey  'printf "root /tmp/has space\n" > "$1"'
ed bogus   'printf "bogus x\n" > "$1"'
ed fixit   'printf "theme cyan\n" > "$1"'
ed empty   ': > "$1"'
ed fail    'exit 1'

edit() {  # EDITOR NAME
	env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" MUX_CACHE="$T/cache" \
		EDITOR="$T/ed/$1" "$HERE/bin/mux" edit "$2" 2>&1
}
row() { grep "^$1 " "$T/conf/profiles" 2>/dev/null || true; }
draft() { printf '%s/cache/edit/%s.profile' "$T" "$1"; }

printf 'api         theme=cyan root=/tmp/api\nweb         theme=red\n' \
	>"$T/conf/profiles"

# --- the draft is the row, in breakout syntax -------------------------------
_seen=$(edit show api)
case $_seen in
*"theme cyan"*) ;; *) fail "draft did not carry the row: [$_seen]" ;;
esac
case $_seen in
*"root /tmp/api"*) ;; *) fail "draft lost a key: [$_seen]" ;;
esac

# --- a saved draft REPLACES the row: a deleted key must not survive ---------
edit green api >/dev/null || fail "saving a draft failed"
case "$(row api)" in
*theme=green*) ;; *) fail "edit did not apply: [$(row api)]" ;;
esac
case "$(row api)" in
*root=*) fail "a key deleted in the draft survived: [$(row api)]" ;;
esac
[ ! -f "$(draft api)" ] || fail "a successful save left its draft behind"
# The row keeps its POSITION, so an edit does not churn the file.
[ "$(awk 'NR==1{print $1}' "$T/conf/profiles")" = api ] \
	|| fail "the edited row moved in the file"

# --- a comment promotes to a breakout, and the row goes ---------------------
_o=$(edit comment web) || fail "promoting failed"
case $_o in *profiles.d/web.profile*) ;; *) fail "no promotion reported" ;; esac
[ -f "$T/conf/profiles.d/web.profile" ] || fail "no breakout file written"
grep -q '^# why this one is special' "$T/conf/profiles.d/web.profile" \
	|| fail "promotion dropped the comment it was triggered by"
[ -z "$(row web)" ] || fail "the row survived promotion; a name is in both"

# --- a value with a space promotes too, being the other thing a row can't do -
edit spacey api >/dev/null || fail "promoting a spaced value failed"
grep -q '^root /tmp/has space' "$T/conf/profiles.d/api.profile" \
	|| fail "the spaced value was not preserved"

# --- an already-promoted name is edited in place, with no draft -------------
edit green web >/dev/null || fail "editing a breakout failed"
grep -q '^theme green' "$T/conf/profiles.d/web.profile" \
	|| fail "editing a breakout did not write through"
[ ! -f "$(draft web)" ] || fail "editing a breakout created a draft"

# --- an unparseable draft is kept, named, and non-zero ----------------------
_o=$(edit bogus zz) && fail "an unknown key should fail the save"
case $_o in *"unknown key 'bogus'"*) ;; *) fail "unhelpful error: [$_o]" ;; esac
[ -f "$(draft zz)" ] || fail "the unparseable draft was eaten"
[ -z "$(row zz)" ] || fail "an unparseable draft wrote a row anyway"

# --- ... and re-editing RESUMES it, with no argument ------------------------
_o=$(edit fixit zz) || fail "resuming failed"
case $_o in *resuming*) ;; *) fail "resume was not announced: [$_o]" ;; esac
case "$(row zz)" in *theme=cyan*) ;; *) fail "the resumed edit did not save" ;;
esac
[ ! -f "$(draft zz)" ] || fail "the draft survived a successful resume"

# --- an editor that fails keeps the draft rather than saving garbage --------
# A fresh name, so this goes through the DRAFT path: an already-promoted name
# is edited in place and there is no draft to keep.
_o=$(edit fail ff) && fail "a failing editor should not count as a save"
[ -f "$(draft ff)" ] || fail "a failing editor lost the draft"
[ -z "$(row ff)" ] || fail "a failing editor wrote a row anyway"
rm -f "$(draft ff)"

# --- emptying a draft means nothing deviates: the row goes ------------------
edit empty zz >/dev/null || fail "emptying a draft failed"
[ -z "$(row zz)" ] || fail "an emptied draft left a row behind"

pass
