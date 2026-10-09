#!/usr/bin/env python3
"""Read a window title out of `kitten @ ls` JSON on stdin.

A SIBLING OF tree.py RATHER THAN A BRANCH IN IT, because the shapes are
genuinely different and a reader that guesses between them is how a wrong
answer looks like a right one. sway answers a recursive tree of nodes;
kitty answers a flat list of OS windows, each with tabs, each with windows.

NOT EXECUTABLE, AND THE SUFFIX STAYS, for the reason tree.py's header gives:
it is handed to an interpreter the caller already names, so it is an
argument rather than a command.

THE TITLE IT READS IS THE KITTY WINDOW'S, which is the one `kitten @
--match title:` matches and is NOT the OS window's. They differ whenever the
running program has not emitted an OSC title: `kitty -T foo -- sleep`
reports `sleep` here and `foo` to the compositor. That distinction cost a
fixture, so it is stated in both places.

With no argument it prints the FOCUSED window's title; with `--all`, every
window's, one per line. Both answer EMPTY rather than failing when there is
nothing, because a kitty that has just started is a real state.
"""
import json
import sys


def windows(doc):
    """Every (focused, title) pair, in kitty's os-window/tab/window order."""
    for os_window in doc:
        for tab in os_window.get("tabs", ()):
            for win in tab.get("windows", ()):
                title = win.get("title")
                if not title:
                    continue
                # BOTH HAVE TO BE TRUE for a window to be the focused one:
                # kitty marks a focused window inside every tab, and a
                # focused tab inside every OS window, so reading only the
                # window's flag reports one per tab and the first wins
                # whichever is listed first.
                focused = bool(win.get("is_focused")) and \
                    bool(tab.get("is_focused")) and \
                    bool(os_window.get("is_focused"))
                yield focused, title


def main():
    try:
        doc = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # NOT A CRASH: kitty may have gone away between the query and the
        # read, and a traceback there would be reported as the probe failing
        # rather than as the environment being down.
        return 0
    everything = "--all" in sys.argv[1:]
    for focused, title in windows(doc):
        if everything:
            print(title)
        elif focused:
            print(title)
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
