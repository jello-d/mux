#!/usr/bin/env python3
"""Read a window title out of a compositor's JSON tree on stdin.

A FILE RATHER THAN AN INLINE `python3 -c`, and that is not tidiness: the
first version of this was a one-liner inside a shell heredoc, and the
escaped quotes an f-string needs made it a SyntaxError that read as the
compositor answering nothing. A probe that lies costs more than no probe.

With no argument it prints the FOCUSED window's title and nothing else; with
`--all` it prints every window's title, one per line, which is what a
"did it appear yet" poll needs. Both answer EMPTY rather than failing when
there is no such window, because "nothing is focused" is a real state in a
compositor that has just started.

sway's shape is `{nodes, floating_nodes, focused, name, type}` recursively.
Hyprland and niri answer flat lists instead and have their own readers; this
one is deliberately about the sway/i3 tree alone rather than a format
guesser, because a reader that tries to handle every shape is how a wrong
answer looks like a right one.
"""
import json
import sys


def windows(node):
    """Every (focused, title) pair for a real window, depth first."""
    kind = node.get("type")
    name = node.get("name")
    # A WORKSPACE HAS A NAME TOO, which is how an early version of this
    # reported `1` as the focused window and sent me looking for a bug in
    # the hook. Only con and floating_con are windows.
    if kind in ("con", "floating_con") and name:
        yield bool(node.get("focused")), name
    for key in ("nodes", "floating_nodes"):
        for child in node.get(key, ()):
            yield from windows(child)


def main():
    try:
        tree = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # NOT A CRASH: the compositor may have gone away between the query
        # and the read, and a traceback there would be reported as the probe
        # failing rather than as the environment being down.
        return 0
    everything = "--all" in sys.argv[1:]
    for focused, name in windows(tree):
        if everything:
            print(name)
        elif focused:
            print(name)
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
