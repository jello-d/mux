#!/bin/sh
# mux-indicator-code-check.t - indicator/setup.sh's STALE-CODE marker, which is
# the one thing standing between a box and silently running month-old code.
#
# IT WAS VACUOUS FROM INSIDE THE PACKAGE DIRECTORY. `python -c` puts the CURRENT
# directory first on sys.path, so `./setup.sh check` run from the checkout
# imported the SOURCE copy, compared every file against ITSELF and reported
# agreement whatever the venv held. The provisioner was unaffected (it runs
# `sh <path>/setup.sh` from elsewhere), so this only ever lied to a human
# iterating on the code -- precisely when a false [OK] costs the most.
#
# Driven against a STUB venv, so no real Python install is needed: the stub is
# the seam, and it answers the one question setup.sh asks the interpreter.
_name=mux-indicator-code-check
. "$(dirname "$0")/harness_lib"     # HERE=repo root, T=scratch, fail/pass

SETUP=$HERE/indicator/setup.sh
[ -f "$SETUP" ] || fail "indicator/setup.sh is missing"

# A venv whose `python` reports where it "imported" the package from.
#
# IT MODELS sys.path's CURRENT-DIRECTORY-FIRST RULE, which is the whole point:
# a stub that simply echoed a fixed path could not exhibit the bug at all, and
# the mutation proved it -- deleting the `cd /` left the corpus green. The one
# behaviour this check depends on is that a package in the CWD shadows the
# installed one, so that is the behaviour the stub reproduces and nothing else.
mkdir -p "$T/venv/bin"
cat >"$T/venv/bin/python" <<EOF
#!/bin/sh
if [ -f ./mux_indicator/__init__.py ]; then
	printf '%s\n' "\$PWD/mux_indicator"
else
	cat "$T/where"
fi
EOF
chmod +x "$T/venv/bin/python"

run() {   # -> the check's output, rc ignored (a sandbox has no systemd)
	( cd "$1" && env MUX_INDICATOR_VENV="$T/venv" \
		MUX_INDICATOR_BIN="$T/bin" NO_COLOR=1 \
		sh "$SETUP" check 2>&1 ) || true
}

# --- 1. A GENUINELY STALE INSTALL IS REPORTED, from either directory --------
# The installed copy exists and differs, which is the case the marker is for.
mkdir -p "$T/installed/mux_indicator"
for f in "$HERE"/indicator/mux_indicator/*.py; do
	printf '# not the shipped file\n' >"$T/installed/mux_indicator/${f##*/}"
done
echo "$T/installed/mux_indicator" >"$T/where"

run "$HERE/indicator" >"$T/inside"
run "$T" >"$T/outside"

grep -q 'installed code is STALE' "$T/inside" \
	|| fail "stale code passed when checked from INSIDE the package dir"
grep -q 'installed code is STALE' "$T/outside" \
	|| fail "stale code passed when checked from outside"

# THE TWO MUST AGREE. Asserted separately from either verdict above, because a
# check that is right from one directory and wrong from another is the actual
# defect, and each line alone passes while that is true.
_i=$(grep -c 'installed code' "$T/inside")
_o=$(grep -c 'installed code' "$T/outside")
[ "$_i" = "$_o" ] || fail "the verdict depends on the working directory"

# --- 2. A CURRENT INSTALL IS STILL REPORTED CURRENT -------------------------
# The guard must not simply fail always, which would pass every assertion above
# and make the marker useless in the other direction.
rm -rf "$T/installed"
mkdir -p "$T/installed/mux_indicator"
cp "$HERE"/indicator/mux_indicator/*.py "$T/installed/mux_indicator/"
run "$HERE/indicator" >"$T/fresh"
grep -q 'installed code matches' "$T/fresh" \
	|| fail "a byte-identical install was reported stale"

# --- 3. A SELF-COMPARISON IS REFUSED, NOT PASSED ----------------------------
# The venv importing the source tree cannot answer the question at all: there
# are not two sides to compare. Covers every other way the paths can converge
# (an editable install, a symlinked site-packages) rather than just the cwd.
echo "$HERE/indicator/mux_indicator" >"$T/where"
run "$HERE/indicator" >"$T/self"
grep -q 'vacuous' "$T/self" \
	|| fail "a self-comparison reported a verdict instead of refusing"
grep -q 'installed code matches' "$T/self" \
	&& fail "a self-comparison reported the code CURRENT"

pass
