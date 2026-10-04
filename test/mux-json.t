#!/bin/sh
# test/mux-json.t - the JSON emitter, proved against a REAL PARSER.
#
# WHY THIS FILE IS A ROUND TRIP and not a set of expected strings. An escaper
# checked against hand-written expectations only proves it agrees with whoever
# wrote them; the question that matters is whether a parser gets back the bytes
# that went in. So every case here goes value -> mux_json_str -> python's json
# -> value, and compares to the original. A wrong escape shows up as a wrong
# value or as a parse error, which is the whole space of ways to be wrong.
#
# IT ALREADY EARNED ITS KEEP BEFORE IT WAS WRITTEN. The second hand-check of
# mux_json_str lost a backslash outright: `awk -v` processes escape sequences
# in the assigned value, so awk consumed it before the function saw it. Data
# loss, silent, in the one function whose entire job is not losing characters.
# The value goes through the environment now.
#
# This is the bargain that kept mux in shell rather than porting it to Python
# for JSON: the escaping is the risk, so it is the thing that gets proved.
set -eu
_name=mux-json
. "$(dirname "$0")/harness_lib"

command -v python3 >/dev/null 2>&1 || {
  printf 'skip %s (no python3 to parse with)\n' "$_name"; exit 0; }

. "$HERE/lib/mux-json_lib"

# rt LABEL VALUE: emit VALUE as JSON, parse it, and require the parsed value
# to be byte-identical to what went in.
rt() {
  _l=$1; _v=$2
  printf '%s' "$_v" >"$T/in"
  mux_json_str "$_v" >"$T/json"
  # stderr into a file, so the FAILURE SAYS WHY. A test that reports only
  # which case broke, with the parser's explanation lost to the terminal,
  # is the shape this suite already refuses everywhere else.
  MUX_T_IN=$T/in MUX_T_JSON=$T/json python3 - 2>"$T/err" <<'PY' \
    || fail "$_l: $(cat "$T/err" 2>/dev/null)"
import json, os, sys
raw = open(os.environ["MUX_T_JSON"], "rb").read()
want = open(os.environ["MUX_T_IN"], "rb").read()
try:
    got = json.loads(raw.decode("utf-8"))
except Exception as e:                       # a document no parser accepts
    sys.stderr.write("not valid JSON: %s: %r\n" % (e, raw))
    sys.exit(1)
if not isinstance(got, str):
    sys.stderr.write("parsed to %r, not a string\n" % (got,))
    sys.exit(1)
if got.encode("utf-8") != want:
    sys.stderr.write("round trip changed it:\n  in  %r\n  out %r\n  json %r\n"
                     % (want, got.encode("utf-8"), raw))
    sys.exit(1)
PY
}

# --- the ordinary cases ---------------------------------------------------
rt plain      'hello'
rt empty      ''
rt spaces     'my project'
rt path       '/home/you/src/mux'

# --- the ones that break a hand-rolled escaper ----------------------------
# Each of these has a real counterpart in mux: a session name is arbitrary, a
# pane's start command is `claude --continue || claude` with quotes in it, and
# a cwd is whatever the filesystem allows.
rt quote      'he said "hi"'
rt backslash  'a \ b'
rt both       'exec "${SHELL:-/bin/sh}" \\ done'
rt backslash_n 'a\nb'
rt json_ish   '{"already":"json"}'

# --- control characters, which are ILLEGAL raw inside a JSON string -------
rt tab        "$(printf 'a\tb')"
rt cr         "$(printf 'a\rb')"
rt bell       "$(printf 'a\007b')"
rt soh        "$(printf 'a\001b')"
rt escape     "$(printf 'a\033[0mb')"

# --- UTF-8 passes through as ITS OWN BYTES --------------------------------
# JSON strings are UTF-8, so nothing above 0x1F needs \u. The risk is the
# opposite one: an escaper working in characters rather than bytes can split a
# multibyte sequence, and awk implementations disagree about which substr does.
rt accented   'héllo'
rt cjk        '日本語'
rt braille    "$(printf '\342\240\200')"
rt emoji      '🙂'

# --- mux_json_num ---------------------------------------------------------
eq() { [ "$2" = "$3" ] || fail "$1: got [$2] want [$3]"; }
eq num-int    "$(mux_json_num 5)"    '5'
eq num-zero   "$(mux_json_num 0)"    '0'
eq num-neg    "$(mux_json_num -3)"   '-3'
# NULL, NOT ZERO. A count mux could not determine is not a count of none:
# the same conflation "empty is exit 0" exists to prevent one level up, where
# a quiet host and an unreachable one must not draw the same tile.
eq num-empty  "$(mux_json_num '')"   'null'
eq num-word   "$(mux_json_num none)" 'null'
eq num-mixed  "$(mux_json_num 1x)"   'null'
eq num-inner  "$(mux_json_num 1-2)"  'null'
# An unvalidated value would make the WHOLE document unparseable, so a bad
# number must not be able to escape as a bare token.
_o=$(printf '{"n":%s}\n' "$(mux_json_num 'oops')")
eq num-doc "$_o" '{"n":null}'

# --- mux_json_array -------------------------------------------------------
eq arr-two   "$(printf '{"a":1}\n{"b":2}\n' | mux_json_array)" \
  '[{"a":1},{"b":2}]'
eq arr-one   "$(printf '{"a":1}\n' | mux_json_array)"          '[{"a":1}]'
# EMPTY IS `[]`, NOT NOTHING. A consumer parses one document either way, so a
# host with no sessions answers the same SHAPE as one with five, which is
# the JSON form of "empty is exit 0".
eq arr-empty "$(printf '' | mux_json_array)"                   '[]'
eq arr-blank "$(printf '\n\n' | mux_json_array)"               '[]'

# ... and the assembled document parses, which is the property the separator
# exists for: a trailing comma is a document no parser accepts, so one bad
# element would make the entire answer unreadable rather than degrade.
_doc=$( { mux_json_str 'a "quoted" one'; printf '\n'
    mux_json_str 'a \ backslashed one'; printf '\n'; } | mux_json_array)
printf '%s' "$_doc" >"$T/doc"
MUX_T_DOC=$T/doc python3 - <<'PY' || fail "the assembled array did not parse"
import json, os, sys
got = json.loads(open(os.environ["MUX_T_DOC"]).read())
if got != ['a "quoted" one', 'a \\ backslashed one']:
    sys.stderr.write("array round trip: %r\n" % (got,))
    sys.exit(1)
PY

pass
