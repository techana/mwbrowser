#!/usr/bin/env python3
"""Form-submission echo bridge for MSX WBrowser.

The browser sends a form submission over the rs232-net cartridge (TCP
2323) when the user clicks a submit button or hits Enter on a focused
text field. The wire format matches an HTTP query string with a small
prefix so we can find the boundaries:

    FORM name1=value1&name2=value2\r\n

This script:
  1. Listens on TCP 2323 (so openMSX's rs232-net connects to us).
  2. Reads bytes until it sees the trailing CRLF.
  3. Parses the "FORM " line, prints what was received in a friendly
     way, then echoes the same line back to the MSX prefixed with
     "OK " so the operator can verify the round-trip.

Pair with tools/plug_rs232.tcl (which gets passed to openMSX -script),
then launch the browser with run.sh.

    $ python3 tools/form_bridge.py            # start listener
    $ ./tools/run.sh -i                       # in another terminal
    A> MWBRO
    (... fill in test12.htm form, click Send ...)
"""

from __future__ import annotations

import argparse
import socket
import sys
import time
from urllib.parse import unquote


def serve(host: str, port: int) -> int:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"form_bridge: listening on {host}:{port} -- start MSX + MWBRO now")

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


def handle_session(conn: socket.socket) -> None:
    """Stream lines forever -- one TCP connect can carry many submits.

    The MSX sends a CRLF-terminated `FORM ...` line per submission. We
    print + echo each one as it lands, so the operator can submit
    multiple times without restarting either side."""
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
            handle_line(conn, line.decode("ascii", "replace"))


def handle_line(conn: socket.socket, line: str) -> None:
    """Print the submission as a parsed dict + echo the literal line
    back to the MSX prefixed with 'OK '. The browser doesn't read the
    echo for now (no UI surface for it), but the operator sees it land
    in the openMSX window and can correlate."""
    ts = time.strftime("%H:%M:%S")
    print(f"\n--- {ts} -- raw: {line!r}")

    if line.startswith("FORM "):
        body = line[5:]
        fields = parse_query(body)
        print(f"    parsed:")
        for k, v in fields:
            print(f"      {k!r:<14} = {v!r}")
    else:
        print("    (not a FORM line)")

    reply = ("OK " + line + "\r\n").encode("ascii", "replace")
    try:
        conn.sendall(reply)
        print(f"    echoed back: {reply!r}")
    except OSError as e:
        print(f"    echo failed: {e}")


def parse_query(body: str) -> list[tuple[str, str]]:
    """Split "a=1&b=2" into [(a, 1), (b, 2)]; URL-decode each piece so
    a future version that escapes '&' or '=' inside a value still
    round-trips legibly here."""
    out = []
    if not body:
        return out
    for pair in body.split("&"):
        if "=" in pair:
            k, v = pair.split("=", 1)
        else:
            k, v = pair, ""
        out.append((unquote(k), unquote(v)))
    return out


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
