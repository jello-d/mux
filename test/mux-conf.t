#!/bin/sh
# test/mux-conf.t - the shared config normalizer, mux_conf_clean in
# lib/mux-conf_lib: the ONE comment/normalize rule for layouts, themes,
# and agent profiles. Pure string logic; nothing on the box is touched.
set -eu
_name=mux-conf
. "$(dirname "$0")/harness_lib"
. "$HERE/lib/mux-conf_lib"

# ck LABEL RAW EXPECT : clean RAW (with \n \r \t escapes) and compare to EXPECT.
ck() {
  _got=$(printf '%b' "$2" | mux_conf_clean)
  _exp=$(printf '%b' "$3")
  [ "$_got" = "$_exp" ] || fail "$1: got [$_got] want [$_exp]"
}

# hex colours (a # NOT preceded by whitespace) MUST survive (the trap).
ck hex-preserved  'bar bg=#3f5f00 fg=#c8f0a0\n' 'bar bg=#3f5f00 fg=#c8f0a0'
# a # inside a token (no leading space) is kept, not read as a comment.
ck hash-in-token  'pane echo a#b\n'             'pane echo a#b'
# ORDER MATTERS HERE, and it is the whole value of the records below it.
# These two sat AFTER the inline-comment cases, and dropping the
# trailing-whitespace rule then fired on `inline-space` instead (the inline
# rule leaves one space behind, which the trailing rule trims), so two
# mutations landed on one assertion and neither proved its own rule.
# trailing whitespace trimmed; the latent bug: "slate " != the name "slate".
ck trailing-ws    'theme slate   \n'            'theme slate'
# a trailing CR (CRLF from another editor). NO explicit rule does this: POSIX
# [:space:] includes carriage return, so the trailing-whitespace rule above
# covers it, and the redundant `s/\r$//` was measured and removed. This case
# is what would catch a platform whose [:space:] disagreed.
ck crlf           'theme red\r\n'               'theme red'
# inline comment: WHITESPACE then # to EOL is stripped, the value kept.
ck inline-space   'theme slate  # my note\n'    'theme slate'
ck inline-tab     'theme cyan\t# note\n'        'theme cyan'
# full-line comments (indented or not) are dropped.
ck full-line      '# top\n  # indented\ntheme cyan\n' 'theme cyan'
# blank and whitespace-only lines are dropped.
ck blanks         'theme red\n\n   \nagent x\n' 'theme red\nagent x'
# DOCUMENTED casualty: a literal " #" inside a command is treated as a comment.
ck cmd-casualty   'pane echo "a # b"\n'         'pane echo "a'

pass
