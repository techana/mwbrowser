#!/usr/bin/env python3
"""Round-trip echo test against SERPOC.COM on the MSX side.

SERPOC is a tiny MSX-DOS 1 program that, for every byte it receives
over the 8251 UART, prints the char on screen and echoes it back to
the host. It also recognises the ASCII EOT byte (0x04) as an
end-of-transmission marker: when it sees EOT, it does NOT echo it
back, resets its byte counter, and prints `[EOT: N bytes]` on the MSX
screen -- a visible confirmation that the whole payload landed.

This Python-side driver:
  1. Listens for openMSX to dial in via rs232-net (2323).
  2. Sends a configurable ASCII payload (default: a known alphabet so
     missing/corrupted bytes stand out), followed by EOT.
  3. Collects the echoed bytes from the MSX and compares them to what
     we sent. Reports match / mismatch, bytes/sec, and a hex dump of
     any drift.

Typical session:
    $ python3 tools/serial_echotest.py           # waits for MSX connect
    # (in another shell)
    $ ./tools/run.sh -i                          # launch openMSX
    A> SERPOC                                    # run the POC on MSX
    # (Python side finishes: prints PASS/FAIL + timings)

Exit code 0 = match, 1 = mismatch, 2 = timeout / connect failure.
"""
from __future__ import annotations

import argparse
import select
import socket
import sys
import time
from pathlib import Path


EOT = 0x04


def default_payload() -> bytes:
    """52-byte payload that covers A-Z and a-z so any one-bit flip is
    visually obvious in the mismatch dump. Terminated with \\r\\n so
    the MSX SERPOC screen shows a clean line break before its own
    '[EOT: 52 bytes]' status."""
    return (
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        b"abcdefghijklmnopqrstuvwxyz"
        b"\r\n"
    )


def recv_all(conn: socket.socket, n: int, timeout_s: float) -> bytes:
    """Collect exactly n echoed bytes, bailing out with whatever we
    have after timeout_s seconds of no data."""
    buf = bytearray()
    deadline = time.monotonic() + timeout_s
    conn.setblocking(False)
    while len(buf) < n:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        ready, _, _ = select.select([conn], [], [], remaining)
        if not ready:
            break
        chunk = conn.recv(n - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
    return bytes(buf)


def hexdump(prefix: str, data: bytes) -> str:
    hx = " ".join(f"{b:02X}" for b in data)
    return f"{prefix}[{len(data)}B] {hx}"


SERPOC_BANNER = b"MSX serial POC\r\n"


def wait_for_banner(conn: socket.socket, banner: bytes, timeout_s: float) -> bytes:
    """Wait until SERPOC's greeting has fully arrived on the UART.

    openMSX plugs the rs232 cartridge early -- the TCP connection is
    accepted while MSX-DOS is still at the A> prompt. SERPOC doesn't
    boot until the user types `SERPOC`, which can be many seconds
    after connect. Until then the UART queue is "drained" into the
    cartridge's tiny FIFO and mostly dropped. So: we collect incoming
    bytes until SERPOC's banner marker appears (proof SERPOC is alive
    and listening), then start the test."""
    buf = bytearray()
    deadline = time.monotonic() + timeout_s
    conn.setblocking(False)
    while time.monotonic() < deadline:
        ready, _, _ = select.select([conn], [], [], 0.2)
        if conn in ready:
            try:
                chunk = conn.recv(256)
            except BlockingIOError:
                chunk = b""
            if chunk:
                buf.extend(chunk)
                if banner in bytes(buf):
                    return bytes(buf)
    return bytes(buf)


def run(host: str, port: int, payload: bytes, settle_ms: int, timeout_s: float) -> int:
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"listening on {host}:{port} -- start MSX + SERPOC now")

    conn, addr = srv.accept()
    print(f"MSX connected from {addr}")
    srv.close()

    # Block until SERPOC has actually started on the MSX side (its
    # banner shows up on the UART). Only then does sending bytes have
    # a chance of being read.
    banner_data = wait_for_banner(conn, SERPOC_BANNER, timeout_s=30)
    if SERPOC_BANNER in banner_data:
        print(f"SERPOC banner received ({len(banner_data)} B) -- starting test")
    else:
        print(f"WARN: SERPOC banner not seen in 30 s (got {len(banner_data)} B raw). "
              "Proceeding anyway -- expect a failure if SERPOC isn't running.")

    # Small settle window to let the echo buffer quiet down before we
    # kick off the measurement.
    time.sleep(settle_ms / 1000)

    print(f"sending {len(payload)} B payload + EOT (0x{EOT:02X})")
    t0 = time.monotonic()
    conn.setblocking(True)
    # Slow-drip the payload at ~1 ms per byte so the MSX's 8251 has
    # time to clock each byte in, SERPOC has time to echo it back, and
    # the receiver's overrun flag never trips. Without this, TCP
    # buffers the whole send at once and the MSX drops everything
    # after the first byte.
    for b in payload + bytes([EOT]):
        conn.sendall(bytes([b]))
        time.sleep(0.001)

    # SERPOC echoes the payload back but NOT the EOT, so we expect
    # exactly len(payload) bytes to return.
    echo = recv_all(conn, len(payload), timeout_s)
    elapsed = time.monotonic() - t0
    conn.close()

    rate = len(echo) / elapsed if elapsed > 0 else 0.0
    print(f"echo: {len(echo)}/{len(payload)} B in {elapsed*1000:.1f} ms "
          f"({rate:.0f} B/s)")

    if echo == payload:
        print("PASS -- round-trip matches")
        return 0

    print("FAIL -- mismatch")
    print(hexdump(" sent", payload))
    print(hexdump(" back", echo))
    # Pinpoint the first diverging byte for easier debug.
    for i, (a, b) in enumerate(zip(payload, echo)):
        if a != b:
            print(f"first mismatch at index {i}: sent 0x{a:02X} got 0x{b:02X}")
            break
    else:
        print(f"echo truncated after {len(echo)} of {len(payload)} bytes")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2323)
    ap.add_argument("--payload", type=str, default=None,
                    help="ASCII string to send; default = A-Za-z + CRLF")
    ap.add_argument("--payload-file", type=Path, default=None,
                    help="read binary payload from file instead of --payload")
    ap.add_argument("--settle-ms", type=int, default=500,
                    help="wait this many ms after connect before sending, to "
                         "drain SERPOC's banner from the stream")
    ap.add_argument("--timeout", type=float, default=5.0,
                    help="seconds to wait for the full echo before giving up")
    args = ap.parse_args()

    if args.payload_file:
        payload = args.payload_file.read_bytes()
    elif args.payload is not None:
        payload = args.payload.encode("ascii")
    else:
        payload = default_payload()

    try:
        return run(args.host, args.port, payload, args.settle_ms, args.timeout)
    except (ConnectionError, OSError) as e:
        print(f"connection error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
