#!/usr/bin/env python3
"""Serial bridge host for the openMSX 'Generic MSX RS-232C' POC.

openMSX's `rs232-net` pluggable connects out to a TCP server, so this
script is the one that listens. Pair with:
  - tools/plug_rs232.tcl         (plugs msx-rs232 <-> 127.0.0.1:2323)
  - dist/SERPOC.COM (built from src/serial_poc.asm) as the MSX-side
    program that banners and echoes over the UART

Typical session:
    $ python3 tools/serial_host.py            # start listener
    # (in another shell)
    $ ./tools/run.sh -i                       # launch openMSX
    # inside openMSX, at the DOS prompt:
    A> SERPOC

The MSX-side banner bytes should arrive in this terminal immediately.
Whatever you type here is echoed to the MSX screen; whatever the MSX
keyboard types is echoed back here.

Options:
    --host HOST       listen on HOST (default 127.0.0.1)
    --port PORT       listen on PORT (default 2323)
    --log  PATH       also tee the bidirectional stream to PATH
"""

from __future__ import annotations

import argparse
import select
import socket
import sys
import termios
import tty
from pathlib import Path


def _raw_stdin():
    """Context manager: put stdin into raw/cbreak so each keystroke
    flushes immediately to the MSX UART instead of line-buffering in
    the tty driver."""

    class _Raw:
        def __enter__(self):
            self.fd = sys.stdin.fileno()
            self.old = termios.tcgetattr(self.fd)
            tty.setcbreak(self.fd)
            return self

        def __exit__(self, *_):
            termios.tcsetattr(self.fd, termios.TCSADRAIN, self.old)

    return _Raw()


def _hex_preview(buf: bytes) -> str:
    """Print-safe representation of bytes we just received from the
    UART: ASCII when printable, hex otherwise. Keeps the terminal from
    being garbled by stray control bytes."""
    out = []
    for b in buf:
        if 0x20 <= b < 0x7F or b in (0x0A, 0x0D, 0x09):
            out.append(chr(b))
        else:
            out.append(f"\\x{b:02X}")
    return "".join(out)


def serve(host: str, port: int, log_path: Path | None) -> int:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"listening on {host}:{port} -- start openMSX now", flush=True)

    conn, addr = srv.accept()
    conn.setblocking(False)
    print(f"openMSX connected from {addr}", flush=True)
    srv.close()

    log = log_path.open("ab") if log_path else None

    try:
        with _raw_stdin():
            while True:
                ready, _, _ = select.select([conn, sys.stdin], [], [])
                if conn in ready:
                    buf = conn.recv(256)
                    if not buf:
                        print("\r\n-- MSX closed the link --")
                        return 0
                    sys.stdout.write(_hex_preview(buf))
                    sys.stdout.flush()
                    if log:
                        log.write(b"<< " + buf + b"\n")
                        log.flush()
                if sys.stdin in ready:
                    ch = sys.stdin.buffer.read1(1)
                    if not ch:
                        continue
                    # Ctrl-] quits the host, the MSX keeps running.
                    if ch == b"\x1d":
                        print("\r\n-- detaching from MSX --")
                        return 0
                    conn.sendall(ch)
                    if log:
                        log.write(b">> " + ch + b"\n")
                        log.flush()
    finally:
        conn.close()
        if log:
            log.close()
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2323)
    ap.add_argument("--log", type=Path, default=None)
    args = ap.parse_args()
    return serve(args.host, args.port, args.log)


if __name__ == "__main__":
    sys.exit(main())
