"""test/lab/wfipc.py - the smallest wayfire IPC client the lab needs.

Handed to python3 by env/wayfire, which is why this keeps a suffix and no
executable bit (see test/lab/rows.py for the same call).

NOT THE `wayfire` PyPI PACKAGE, deliberately, and for the reason
share/desktop-notifier/focus/wayfire gives: the thing under test speaks this
protocol with stdlib alone, so a lab that needed a venv would be testing a
different client from the one that ships.

THE PROTOCOL: a 4-byte NATIVE-order length prefix and a JSON body over an
AF_UNIX stream. `=i` rather than `<i`, which is what the compositor writes;
little-endian is a guess that happens to agree on every box we have.

AND FAILURE ARRIVES IN THE PAYLOAD, not as a status: there is no process to
exit, so a bad request answers `{"error": "..."}` on a healthy connection.
Every call here checks for it, because the alternative assumption is the
kitty bug this directory exists to have caught.

Verbs, all read-only but the last:

    list            every mapped toplevel, `id<TAB>pid<TAB>title`
    titles          one title per line, for a creation poll
    focused         the focused view's title, or nothing
    pids            the mapped toplevels' pids, for teardown
    focus-exact T   focus the view whose title is EXACTLY T
"""

import json
import os
import socket
import struct
import sys


def die(msg):
    sys.stderr.write("wfipc: %s\n" % msg)
    raise SystemExit(1)


class Wf:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(5)
        try:
            self.s.connect(path)
        except OSError as e:
            die("cannot reach %s: %s" % (path, e))

    def call(self, method, data=None):
        body = json.dumps({"method": method, "data": data or {}}).encode()
        try:
            self.s.sendall(struct.pack("=i", len(body)) + body)
            head = self._exact(4)
            want = struct.unpack("=i", head)[0]
            buf = self._exact(want)
        except OSError as e:
            die("%s: %s" % (method, e))
        try:
            res = json.loads(buf.decode("utf-8"))
        except ValueError as e:
            die("%s: answer is not JSON: %s" % (method, e))
        if isinstance(res, dict) and "error" in res:
            die("%s: %s" % (method, res["error"]))
        return res

    def _exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                die("wayfire closed the connection")
            buf += chunk
        return buf

    def toplevels(self):
        """wayfire's OWN filter, the same triple its reference client uses:
        a view counts only when it is mapped, is not the desktop environment
        and has a real pid. Without it an unmapped or background view is a
        candidate and focus lands on something invisible."""
        out = []
        for v in self.call("window-rules/list-views"):
            if not isinstance(v, dict):
                continue
            if v.get("mapped") is not True:
                continue
            if v.get("role") == "desktop-environment":
                continue
            if v.get("pid") == -1:
                continue
            out.append(v)
        return out


def main(argv):
    path = os.environ.get("WF_SOCK")
    if not path:
        die("WF_SOCK must name the compositor's IPC socket")
    if not argv:
        die("usage: wfipc.py {list|titles|focused|pids|focus-exact TITLE}")
    verb = argv[0]
    wf = Wf(path)

    if verb == "list":
        for v in wf.toplevels():
            print("%s\t%s\t%s" % (v["id"], v.get("pid"), v.get("title") or ""))
    elif verb == "titles":
        for v in wf.toplevels():
            print(v.get("title") or "")
    elif verb == "pids":
        for v in wf.toplevels():
            print(v["pid"])
    elif verb == "focused":
        info = wf.call("window-rules/get-focused-view").get("info") or {}
        print(info.get("title") or "")
    elif verb == "focus-exact":
        if len(argv) < 2:
            die("focus-exact needs a title")
        want = argv[1]
        hit = [v for v in wf.toplevels() if (v.get("title") or "") == want]
        if not hit:
            die("no view titled %r" % want)
        wf.call("window-rules/focus-view", {"id": hit[0]["id"]})
    else:
        die("unknown verb %r" % verb)


if __name__ == "__main__":
    main(sys.argv[1:])
