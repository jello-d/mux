"""test/lab/hyinst.py - read Hyprland's own instance record.

    hyprctl -j instances | python3 hyinst.py SIGFILE WDFILE

Handed to python3 by env/hyprland, so it keeps a suffix and no executable
bit (see test/lab/rows.py and test/lab/wfipc.py for the same call).

WHY A FILE RATHER THAN A `find` IN THE SHELL: the thing being read is
`hyprctl -j instances`, which answers with NO signature set and reports both
the signature and the `wl_socket` this instance published. The version this
replaced took the newest directory under $XDG_RUNTIME_DIR/hypr, which is a
guess that another compositor starting in the same instant wins, and
env/sway already records paying for exactly that.

EXIT 1 UNTIL BOTH FIELDS ARE THERE, so the caller can poll this and nothing
else: an instance appears in that list slightly before it is useful, and a
partial answer written to the files would read as readiness.

AND IT WRITES ATOMICALLY, by rename, for the reason mux's undo record had to
learn: a caller polling for a non-empty file otherwise sees one that exists
and is not finished yet.
"""

import json
import os
import sys


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: hyinst.py SIGFILE WDFILE\n")
        return 2
    sig_file, wd_file = argv[0], argv[1]
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return 1
    if not isinstance(data, list) or not data:
        return 1
    # THE NEWEST BY `time`, not the first: the list is every live Hyprland on
    # the box, and on a developer's machine that can include their own
    # session. Ours is the one that just started.
    try:
        inst = sorted(data, key=lambda d: d.get("time") or 0)[-1]
    except (TypeError, AttributeError):
        return 1
    sig = inst.get("instance")
    wd = inst.get("wl_socket")
    if not sig or not wd:
        return 1
    for path, value in ((sig_file, sig), (wd_file, wd)):
        tmp = path + ".new"
        with open(tmp, "w") as fh:
            fh.write(value)
        os.rename(tmp, path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
