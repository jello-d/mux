"""test/wffake.py - a fake wayfire IPC server, for test/mux-focus-hooks.t.

    python3 wffake.py SOCKET LOG VIEWS_JSON [focus-error]

WHY THIS EXISTS. focus/wayfire is the one hook in its directory with no CLI
to stub: wayfire ships no IPC client, so the hook speaks the protocol itself
and there is no argv for the suite to record. Without a fake socket, CI
covers none of its behaviour, and CI is the only place the lab does NOT run
(no compositor on either runner). So this is the stub-shaped half of what
test/lab/env/wayfire proves for real.

IT ASSERTS THE REQUESTS, which is the contract with wayfire: the method
names, and that the id focused is the one the anchor matched. A hook that
raised the wrong window still exits 0, so the request log is the only thing
that can tell them apart, exactly as the recorded argv is for every other
hook here.

ONE CONNECTION, THEN EXIT. The hook opens exactly one, and a server that
outlived its client would leak a process per case: this suite has already
collected ten of those from a different test.

AND IT ANSWERS THE SHAPE THE REAL ONE DOES, measured against a live wayfire
rather than copied from a wrapper: a 4-byte native-order length prefix and a
JSON body, with failure reported IN the payload as `{"error": ...}` rather
than by any status, because a socket has no exit code to carry it.
"""

import json
import os
import socket
import struct
import sys


def send(conn, obj):
    body = json.dumps(obj).encode()
    conn.sendall(struct.pack("=i", len(body)) + body)


def recv_one(conn):
    head = b""
    while len(head) < 4:
        chunk = conn.recv(4 - len(head))
        if not chunk:
            return None
        head += chunk
    want = struct.unpack("=i", head)[0]
    buf = b""
    while len(buf) < want:
        chunk = conn.recv(want - len(buf))
        if not chunk:
            return None
        buf += chunk
    return json.loads(buf.decode("utf-8"))


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: wffake.py SOCKET LOG VIEWS [focus-error]\n")
        return 2
    sock_path, log_path, views_path = argv[0], argv[1], argv[2]
    focus_error = argv[3] if len(argv) > 3 else ""
    with open(views_path) as fh:
        views = json.load(fh)

    try:
        os.unlink(sock_path)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    # READY ONLY ONCE IT IS LISTENING, so the test polls for this file rather
    # than sleeping: a client connecting to a bound-but-not-listening socket
    # is refused, which would read as the hook being unable to reach wayfire.
    with open(sock_path + ".ready", "w") as fh:
        fh.write("1")
    srv.settimeout(20)

    conn, _ = srv.accept()
    conn.settimeout(20)
    with open(log_path, "a") as log:
        while True:
            req = recv_one(conn)
            if req is None:
                break
            log.write(json.dumps(req, sort_keys=True) + "\n")
            log.flush()
            method = req.get("method")
            if method == "window-rules/list-views":
                send(conn, views)
            elif method == "window-rules/focus-view":
                if focus_error:
                    send(conn, {"error": focus_error})
                else:
                    send(conn, {"result": "ok"})
            else:
                send(conn, {"error": "No such method found!"})
    conn.close()
    srv.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
