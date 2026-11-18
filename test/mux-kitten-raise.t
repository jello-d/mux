#!/bin/sh
# test/mux-kitten-raise.t - share/kittens/raise_window.py, the kitty kitten
# focus/kitty runs INSIDE kitty to spend a click's activation token.
#
# A token activates only a surface of the client that presents it, so kitty
# has to spend it, and the one call that takes one for an EXISTING window is
# `boss.set_active_window(..., activation_token=T)`. This asserts the kitten
# makes exactly that call, with the token, for the window kitty matched.
#
# kitty's own modules are not on a CI runner, so the one import the kitten
# makes (kittens.tui.handler.result_handler) is stubbed with what kitty's
# version does: attach `no_ui` to the handler and return it. What it CALLS on
# the boss is the claim under test, and a recording boss is the right tool
# for a claim about a call. That the call raises the window is the
# compositor-side measurement in the kitten's header, and test/lab's job.
_name=mux-kitten-raise
. "$(dirname "$0")/harness_lib"

command -v python3 >/dev/null 2>&1 || {
  printf 'skip %s (no python3)\n' "$_name"; exit 0; }

mkdir -p "$T/stub/kittens/tui"
: >"$T/stub/kittens/__init__.py"
: >"$T/stub/kittens/tui/__init__.py"
cat >"$T/stub/kittens/tui/handler.py" <<'PYEOF'
def result_handler(no_ui=False, **_kw):
    def wrap(fn):
        fn.no_ui = no_ui
        return fn
    return wrap
PYEOF

# PROGRAM TEXT IN A FILE, never a heredoc fed to `python3 -`: the kitten path
# and the stub path are arguments, and nothing here can be cut short by an
# inner delimiter.
cat >"$T/drive.py" <<'PYEOF'
import importlib.util, sys
stub, kitten = sys.argv[1], sys.argv[2]
sys.path.insert(0, stub)
spec = importlib.util.spec_from_file_location("raise_window", kitten)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Boss:
    def __init__(self):
        self.window_id_map = {7: "win7"}
        self.calls = []

    def set_active_window(self, w, switch_os_window_if_needed=False,
                          activation_token=""):
        self.calls.append((w, switch_os_window_if_needed, activation_token))


def case(args, wid):
    b = Boss()
    r = m.handle_result([kitten] + args, None, wid, b)
    print(r, repr(b.calls))


print("noui", getattr(m.handle_result, "no_ui", None))
case(["tok-1"], 7)
case([], 7)
case(["has space"], 7)
case(["tok-1"], 99)
PYEOF

_o=$(python3 -I "$T/drive.py" "$T/stub" "$HERE/share/kittens/raise_window.py" \
  2>&1) || fail "the kitten did not load or run: $_o"

line() { printf '%s\n' "$_o" | sed -n "$1p"; }

# NO UI: kitty then calls handle_result directly and opens no overlay window,
# which for a click would flash a blank pane in front of the user.
[ "$(line 1)" = "noui True" ] || fail "the kitten is not no_ui: $(line 1)"

# THE TOKEN REACHES set_active_window, for the matched window, with the OS
# window switched: the call kitty's own notification click makes.
[ "$(line 2)" = "raised [('win7', True, 'tok-1')]" ] \
  || fail "the token did not reach set_active_window: $(line 2)"

# NO TOKEN is kitty's own behaviour (it mints its own), never a refusal.
[ "$(line 3)" = "raised [('win7', True, '')]" ] \
  || fail "no token did not fall back to kitty's own focus: $(line 3)"

# JUNK FROM ACROSS A BOUNDARY is no token, re-checked in the last process
# it crosses into rather than trusted to the hook.
[ "$(line 4)" = "raised [('win7', True, '')]" ] \
  || fail "a junk token was passed to kitty: $(line 4)"

# A WINDOW kitty DOES NOT HAVE is said, and nothing is focused.
[ "$(line 5)" = "no-window []" ] \
  || fail "a missing window was not reported: $(line 5)"

pass
