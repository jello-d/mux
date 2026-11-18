# raise_window.py - a kitty kitten: focus a window, spending a click's token.
#
# Run by focus/kitty as
#
#     kitten @ --to ADDR kitten --match MATCH /path/raise_window.py [TOKEN]
#
# and it executes INSIDE kitty's own process, which is the whole point. An
# xdg-activation token activates only a surface of the client that PRESENTS
# it, so the notifier holding the click's token cannot raise kitty's window
# with it; kitty has to. `kitten @ focus-window` takes no token (kitty 0.45:
# it asks the compositor for one of its own, with no input behind it, which
# a compositor refuses for a window it should not raise), and no remote
# control command passes one. This calls the same thing kitty's own
# notification click calls, `set_active_window(..., activation_token=T)`.
#
# MEASURED from the compositor side (wayfire-mods, 2026-11-17): a kitty
# inside a sandboxed security context, on another workspace, is RAISED this
# way and is NOT by `focus-window`.
#
# NO TOKEN IS kitty's OWN BEHAVIOUR, exactly `focus-window`, so one hook works
# for a terminal that needs a token and one that does not.
#
# LOADED, NOT EXECUTED: kitty imports this by path, which is why it keeps the
# `.py` suffix kitty selects on and carries no shebang or exec bit.

from kittens.tui.handler import result_handler


def main(args):
    pass


def _token(args):
    """The token, or "" for none. Re-checked here rather than trusted: the
    hook validated it, and this is the last process it crosses into."""
    t = args[1] if len(args) > 1 else ""
    if not 0 < len(t) <= 256 or any(not 0x20 < ord(c) < 0x7F for c in t):
        return ""
    return t


@result_handler(no_ui=True)
def handle_result(args, answer, target_window_id, boss):
    w = boss.window_id_map.get(target_window_id)
    if w is None:
        return "no-window"
    boss.set_active_window(w, switch_os_window_if_needed=True,
                           activation_token=_token(args))
    return "raised"
