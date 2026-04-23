#!/usr/bin/env python3
"""Serial web bridge for MSX WBrowser -- HTML passthrough mode.

Listens on a TCP port (openMSX's rs232-net pluggable dials out to us)
and speaks the same line-oriented protocol RemoteGet expects:

    MSX -> bridge:  GET <target>\\r\\n
    bridge -> MSX:  OK HTM <length>\\r\\n<body>
                    OK PCX <length>\\r\\n<body>
                    ERR 404\\r\\n

Behaviour:
  - "GET http(s)://..."     -- fetch the URL. If it's an HTML page the
                               raw bytes are forwarded verbatim, with
                               two cleanups: every `<img src>` is
                               rewritten to a short "imNN.pcx" handle
                               the browser can fetch back, and every
                               `<a href>` is rewritten to an absolute
                               URL so relative links can be followed.
                               Images get fetched lazily + converted
                               to 2bpp PCX on demand.
  - "GET imNN.pcx"          -- serve the cached image URL associated
                               with that handle, converted to PCX.
  - "GET /submit?..."       -- form-echo helper, same as before.
  - Anything else           -- ERR 404.

There is no Playwright / screenshot pipeline in this bridge; small
HTML-2-ish sites (like frogfind.com) render natively in the MSX
browser's own parser.

Run:
    python3 tools/web_bridge.py [--host 127.0.0.1] [--port 2323] [--verbose]

Pair with:
    openmsx -exta rs232 -script tools/plug_rs232.tcl
    A> MWBRO
    Address bar: http://frogfind.com
"""

from __future__ import annotations

import argparse
import io
import re
import socket
import struct
import sys
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import web_to_sc6 as w2s  # noqa: E402 -- reuse PCX packing primitives

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow required: pip install Pillow")


IMG_SRC_DQ = re.compile(rb'(<img\b[^>]*\bsrc=)"([^"]*)"', re.I)
IMG_SRC_SQ = re.compile(rb"(<img\b[^>]*\bsrc=)'([^']*)'", re.I)
A_HREF_DQ  = re.compile(rb'(<a\b[^>]*\bhref=)"([^"]*)"', re.I)
A_HREF_SQ  = re.compile(rb"(<a\b[^>]*\bhref=)'([^']*)'", re.I)

USER_AGENT = "MSX-WBrowser/0.5 (openMSX)"
FETCH_TIMEOUT = 20.0


def _html_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


# ----------------------------------------------------------------------------
# Session -- per-page state: image handle -> original URL.
# ----------------------------------------------------------------------------

class BridgeSession:
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self._img_cache: dict[str, str] = {}
        self._current_base: str | None = None
        self._img_counter = 0

    # -- public -----------------------------------------------------------

    def handle_get(self, target: str):
        self._log(f"GET {target!r}")

        # Form submit: "http:/submit?..." is what the MSX side sends (the
        # http: prefix makes LoadFile pick the remote path). Strip and
        # hand off to the echo helper.
        if target.startswith("http:/submit") or target.startswith("/submit"):
            stripped = target[5:] if target.startswith("http:") else target
            return self._handle_submit(stripped)

        # Image handle produced by our own HTML rewriter: imNN.pcx.
        if re.fullmatch(r"im\d+\.pcx", target, flags=re.I):
            url = self._img_cache.get(target.lower())
            if not url:
                return ("404", None)
            return self._fetch_image(url)

        # Real URL? Fetch and passthrough.
        if target.lower().startswith(("http://", "https://")):
            return self._fetch_page(target)

        return ("404", None)

    # -- HTML passthrough -------------------------------------------------

    def _fetch_page(self, url: str):
        try:
            raw, final_url, content_type = _fetch(url)
        except Exception as exc:
            self._log(f"fetch failed: {exc}")
            return ("404", None)

        self._current_base = final_url

        if content_type.startswith("image/"):
            # User typed an image URL directly -- skip the HTML rewrite
            # and deliver the PCX.
            return self._convert_image_bytes(raw)

        # Everything else we treat as HTML / text. Rewrite img srcs and
        # a hrefs, then pass the result through.
        body = self._rewrite_html(raw)
        self._log(f"HTM {len(body)} B (was {len(raw)}) from {final_url}")
        return ("HTM", body)

    def _rewrite_html(self, body: bytes) -> bytes:
        # Drop <script>/<style>/<noscript> blocks; the MSX parser ignores
        # them anyway but stripping keeps the wire small.
        body = re.sub(rb"<script\b[^>]*>.*?</script>", b"",
                      body, flags=re.I | re.S)
        body = re.sub(rb"<style\b[^>]*>.*?</style>", b"",
                      body, flags=re.I | re.S)
        body = re.sub(rb"<noscript\b[^>]*>.*?</noscript>", b"",
                      body, flags=re.I | re.S)

        # Reset per-page image cache.
        self._img_cache = {}
        self._img_counter = 0

        def img_repl(m: re.Match) -> bytes:
            prefix = m.group(1)
            src = m.group(2).decode("latin-1", "replace").strip()
            handle = self._register_image(src)
            return prefix + b'"' + handle.encode("ascii") + b'"'

        def href_repl(m: re.Match) -> bytes:
            prefix = m.group(1)
            href = m.group(2).decode("latin-1", "replace").strip()
            # In-page anchors + javascript: links are useless on MSX; leave
            # them as-is so the click is a no-op rather than a 404.
            if href.startswith(("#", "javascript:", "mailto:")):
                return m.group(0)
            absolute = urllib.parse.urljoin(self._current_base or "", href)
            return prefix + b'"' + absolute.encode("latin-1", "replace") + b'"'

        body = IMG_SRC_DQ.sub(img_repl, body)
        body = IMG_SRC_SQ.sub(img_repl, body)
        body = A_HREF_DQ.sub(href_repl, body)
        body = A_HREF_SQ.sub(href_repl, body)

        # Best-effort encoding: decode as UTF-8 (the modern default) then
        # re-encode as latin-1 so the MSX font can render ASCII + Latin-1
        # glyphs it has. Non-encodable chars get '?'.
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            text = body.decode("latin-1", "replace")
        return text.encode("latin-1", "replace")

    def _register_image(self, src: str) -> str:
        """Absolutise + mint a short imNN.pcx handle for `src`."""
        absolute = urllib.parse.urljoin(self._current_base or "", src)
        # Re-use existing handles so two <img>s to the same URL share a fetch.
        for handle, url in self._img_cache.items():
            if url == absolute:
                return handle
        self._img_counter += 1
        handle = f"im{self._img_counter:02d}.pcx"
        self._img_cache[handle] = absolute
        return handle

    # -- Image conversion -------------------------------------------------

    def _fetch_image(self, url: str):
        try:
            raw, _final, ctype = _fetch(url)
        except Exception as exc:
            self._log(f"img fetch failed: {exc}")
            return ("404", None)
        return self._convert_image_bytes(raw)

    def _convert_image_bytes(self, raw: bytes):
        try:
            im = Image.open(io.BytesIO(raw))
            im.load()
        except Exception as exc:
            self._log(f"image decode failed: {exc}")
            return ("404", None)
        im = w2s._resize_to_msx(im, Image.BOX)
        pcx = self._to_pcx(im)
        self._log(f"PCX {len(pcx)} B")
        return ("PCX", pcx)

    @staticmethod
    def _to_pcx(im: Image.Image) -> bytes:
        raw = w2s._pack_sc6_chunk(im)
        rows = len(raw) // w2s.SC6_ROW_BYTES
        width_px = w2s.MSX_VIEWPORT_W
        hdr = bytearray(128)
        hdr[0] = 0x0A
        hdr[1] = 5
        hdr[2] = 1
        hdr[3] = 2
        struct.pack_into("<HHHH", hdr, 4, 0, 0, width_px - 1, rows - 1)
        struct.pack_into("<HH",   hdr, 12, 75, 75)
        hdr[65] = 1
        struct.pack_into("<H", hdr, 66, w2s.SC6_ROW_BYTES)
        hdr[68] = 1
        out = bytearray(hdr)
        for y in range(rows):
            row = raw[y * w2s.SC6_ROW_BYTES : (y + 1) * w2s.SC6_ROW_BYTES]
            x = 0
            while x < len(row):
                v = row[x]
                run = 1
                while x + run < len(row) and row[x + run] == v and run < 63:
                    run += 1
                if run > 1 or (v & 0xC0) == 0xC0:
                    out.append(0xC0 | run)
                    out.append(v)
                else:
                    out.append(v)
                x += run
        return bytes(out)

    # -- Form submit echo -------------------------------------------------

    def _handle_submit(self, target: str):
        q = target.split("?", 1)[1] if "?" in target else ""
        pairs = []
        if q:
            for pair in q.split("&"):
                if "=" in pair:
                    k, v = pair.split("=", 1)
                else:
                    k, v = pair, ""
                pairs.append((urllib.parse.unquote(k),
                              urllib.parse.unquote(v)))
        self._log(f"submit: {pairs}")
        rows = "".join(
            f"<tr><td>{_html_escape(k)}</td><td>{_html_escape(v)}</td></tr>"
            for k, v in pairs
        )
        body = (
            "<html><head><title>Form echo</title></head><body>"
            "<h2>Form received</h2>"
            f"<table>{rows}</table>"
            "</body></html>"
        )
        return ("HTM", body.encode("iso-8859-6", "replace"))

    # -- helpers ----------------------------------------------------------

    def _log(self, msg: str) -> None:
        if self.verbose:
            print(f"[bridge] {msg}", flush=True)


def _fetch(url: str) -> tuple[bytes, str, str]:
    """HTTP GET with a realistic User-Agent. Returns (bytes, final URL
    after redirects, lower-cased Content-Type)."""
    req = urllib.request.Request(url, headers={
        "User-Agent": USER_AGENT,
        "Accept":     "text/html, image/*;q=0.8, */*;q=0.1",
    })
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as r:
        data = r.read()
        final_url = r.url
        ctype = (r.headers.get("content-type") or "").lower()
    return data, final_url, ctype


# ----------------------------------------------------------------------------
# Line-oriented TCP server.
# ----------------------------------------------------------------------------

def _readline(conn: socket.socket) -> bytes:
    buf = bytearray()
    while True:
        b = conn.recv(1)
        if not b:
            return bytes(buf)
        buf.extend(b)
        if buf.endswith(b"\r\n"):
            return bytes(buf)
        if len(buf) > 4096:
            return bytes(buf)


def _send_response(conn: socket.socket, kind: str, body):
    if kind in ("HTM", "PCX"):
        header = f"OK {kind} {len(body)}\r\n".encode("ascii")
        conn.sendall(header)
        conn.sendall(body)
    elif kind == "404":
        conn.sendall(b"ERR 404\r\n")
    else:
        conn.sendall(b"ERR 500\r\n")


def serve_forever(host: str, port: int, verbose: bool) -> None:
    session = BridgeSession(verbose=verbose)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(1)
    print(f"web_bridge listening on {host}:{port}", flush=True)
    while True:
        conn, addr = srv.accept()
        print(f"[connected from {addr}]", flush=True)
        try:
            while True:
                line = _readline(conn)
                if not line:
                    break
                text = line.rstrip(b"\r\n").decode("ascii", "replace")
                if not text.startswith("GET "):
                    _send_response(conn, "500", None)
                    continue
                target = text[4:]
                kind, body = session.handle_get(target)
                _send_response(conn, kind, body)
        except (ConnectionError, OSError) as exc:
            print(f"[session error: {exc}]", file=sys.stderr, flush=True)
        finally:
            conn.close()
            print("[disconnected]", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2323)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    try:
        serve_forever(args.host, args.port, args.verbose)
    except KeyboardInterrupt:
        print("\nbye.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
