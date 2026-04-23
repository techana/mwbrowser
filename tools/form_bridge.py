#!/usr/bin/env python3
"""Minimal form-echo bridge for MSX WBrowser.

The browser submits a form by building `/submit?name=value&...` into
UrlBuf and calling NavigateAndFocusContent -- exactly the same code
path it uses to fetch regular URLs. That means the wire protocol is
the same one RemoteGet already understands:

    MSX -> bridge:  GET /submit?a=1&b=2\\r\\n
    bridge -> MSX:  OK HTM <len>\\r\\n<body>

Running this script instead of tools/web_bridge.py gives you a tiny
Playwright-free echo server that just renders the received fields as
a <table>. Useful for exercising the form-submit path without spinning
up a full web-fetching bridge.

    $ python3 -u tools/form_bridge.py
    $ ./tools/run.sh -i -ext rs232 -script tools/plug_rs232.tcl
      (in MSX) A> MWBRO
      (fill the form, click Send)
"""

from __future__ import annotations

import argparse
import socket
import sys
import time
from urllib.parse import unquote


def html_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def render_echo(pairs: list[tuple[str, str]]) -> bytes:
    rows = "".join(
        f"<tr><td>{html_escape(k)}</td><td>{html_escape(v)}</td></tr>"
        for k, v in pairs
    )
    body = (
        "<html><head><title>Form echo</title></head><body>"
        "<h2>Form received</h2>"
        f"<table>{rows}</table>"
        "</body></html>"
    )
    return body.encode("iso-8859-6", "replace")


def parse_query(q: str) -> list[tuple[str, str]]:
    out = []
    if not q:
        return out
    for pair in q.split("&"):
        if "=" in pair:
            k, v = pair.split("=", 1)
        else:
            k, v = pair, ""
        out.append((unquote(k), unquote(v)))
    return out


def handle_request(conn: socket.socket, line: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"\n{ts} -> {line!r}")
    # Expect "GET <target>". Everything else is an error.
    if not line.startswith("GET "):
        conn.sendall(b"ERR 400\r\n")
        return
    target = line[4:]
    # Browser uses "http:/submit?..." so the scheme check in LoadFile
    # routes it to RemoteGet. Strip the scheme here.
    if target.startswith("http:/submit") or target.startswith("/submit"):
        if target.startswith("http:"):
            target = target[5:]              # drop "http:" keep "/submit?..."
        q = target.split("?", 1)[1] if "?" in target else ""
        pairs = parse_query(q)
        for k, v in pairs:
            print(f"    {k!r:<14} = {v!r}")
        body = render_echo(pairs)
        hdr = f"OK HTM {len(body)}\r\n".encode("ascii")
        conn.sendall(hdr + body)
        print(f"    -> HTM {len(body)} B")
    else:
        conn.sendall(b"ERR 404\r\n")
        print(f"    -> 404")


def handle_session(conn: socket.socket) -> None:
    """Requests are line-terminated (CRLF). Read into a buffer and
    dispatch one at a time; the same TCP connection can carry many
    requests."""
    buf = bytearray()
    conn.setblocking(True)
    while True:
        chunk = conn.recv(256)
        if not chunk:
            return
        buf.extend(chunk)
        while b"\r\n" in buf:
            line, _, rest = buf.partition(b"\r\n")
            buf[:] = rest
            handle_request(conn, line.decode("ascii", "replace"))


def serve(host: str, port: int) -> int:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"form_bridge: listening on {host}:{port}")

    while True:
        conn, addr = srv.accept()
        print(f"\n[connected from {addr}]")
        try:
            handle_session(conn)
        except (ConnectionError, OSError) as e:
            print(f"[session error: {e}]", file=sys.stderr)
        finally:
            conn.close()
            print("[disconnected]")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2323)
    args = ap.parse_args()

    try:
        serve(args.host, args.port)
    except KeyboardInterrupt:
        print("\nbye.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
