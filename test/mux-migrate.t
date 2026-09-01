#!/bin/sh
# test/mux-migrate.t - converting a pre-rename $MUX_DIR (one <name>.layout per
# session, holding identity AND arrangement) into the profile table plus
# layouts. The risky part is deciding what NOT to carry over: a root that mux
# would derive anyway is dropped, but only when it genuinely would.
set -eu
_name=mux-migrate
. "$(dirname "$0")/lib.sh"

command -v git >/dev/null 2>&1 || { printf 'skip %s (no git)\n' "$_name"
	exit 0; }

mkdir -p "$T/conf" "$T/src/proj/sub/deep" "$T/src/other"
git init -q "$T/src/proj"
git init -q "$T/src/other"

# A plain conversion: theme kept, root dropped (the repo's own basename).
printf '# rationale\ntheme purple\nroot %s\ninclude shapes/code\n' \
	"$T/src/proj" >"$T/conf/proj.layout"
# A SUBDIRECTORY root whose basename matches the name. mux would derive `proj`
# there (the git toplevel), NOT `sub`, so this root must be KEPT.
printf 'theme slate\nroot %s\ninclude shapes/code\n' \
	"$T/src/proj/sub" >"$T/conf/sub.layout"
# Nothing but the shared shape: wholly derivable, so nothing survives.
printf 'root %s\ninclude shapes/code\n' "$T/src/other" \
	>"$T/conf/other.layout"
# Composed: an include PLUS its own window.
printf 'theme cyan\nroot %s\ninclude shapes/code\n' "$T/src/proj" \
	>"$T/conf/composed.layout"
printf 'window logs\npane tail\n' >>"$T/conf/composed.layout"

mig() {
	env -u MUX_SHARE -u TMUX MUX_DIR="$T/conf" "$HERE/bin/mux" \
		migrate-profiles "$@" 2>&1
}
row() { grep "^$1 " "$T/conf/profiles" 2>/dev/null || true; }

# A dry run must change nothing at all.
_plan=$(mig) || fail "dry run failed"
[ -f "$T/conf/proj.layout" ] || fail "the dry run moved a file"
[ ! -f "$T/conf/profiles" ] || fail "the dry run wrote a table"
case $_plan in *"re-run with --apply"*) ;; *) fail "no dry-run notice" ;; esac

_out=$(mig --apply) || fail "apply failed"

# Originals are kept, never deleted.
[ -f "$T/conf/proj.layout.bak" ] || fail "no .bak kept for proj"
[ ! -f "$T/conf/proj.layout" ] || fail "the original was left in place"

# proj: theme carried, root dropped -- it is the repo's own basename, so the
# name derives from it and config never restates what mux works out.
case "$(row proj)" in
*theme=purple*) ;; *) fail "proj lost its theme: [$(row proj)]" ;;
esac
case "$(row proj)" in
*root=*) fail "proj kept a root mux would derive: [$(row proj)]" ;;
esac

# sub: the root MUST survive. Dropping it would repoint the session from the
# subdirectory at the whole enclosing repo.
case "$(row sub)" in
*"root=$T/src/proj/sub"*) ;;
*) fail "sub lost its subdirectory root: [$(row sub)]" ;;
esac

# other: wholly derivable, so it gets no row at all.
[ -z "$(row other)" ] \
	|| fail "other got a row it need not have: [$(row other)]"

# composed: a layout file, and a row pointing at it.
[ -f "$T/conf/layouts/composed.layout" ] \
	|| fail "no layout for the composed one"
case "$(row composed)" in
*layout=composed*) ;; *) fail "composed row does not name its layout" ;;
esac
# The included arrangement is spliced in, so it builds what the original did
# rather than leaving the reader a note.
grep -qE '^pane[[:space:]]+agent' "$T/conf/layouts/composed.layout" \
	|| fail "the included arrangement was not spliced in"
grep -qE '^window[[:space:]]+logs' "$T/conf/layouts/composed.layout" \
	|| fail "the file's own window was not carried over"

# Comments cannot live in a row, so the ones that had them are reported.
case $_out in
*"carried COMMENTS"*) ;; *) fail "dropped prose was not reported" ;;
esac
case $_out in *proj*) ;; *) fail "proj not listed as commented" ;; esac

# Idempotent: a second apply finds nothing to do.
_again=$(mig --apply) || fail "second apply failed"
case $_again in
*"nothing to migrate"*) ;; *) fail "not idempotent: [$_again]" ;;
esac

pass
