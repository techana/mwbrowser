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


IMG_TAG    = re.compile(rb"<img\b[^>]*>", re.I)
IMG_SRC    = re.compile(rb"""\bsrc\s*=\s*["']?([^"'\s>]+)["']?""", re.I)
IMG_W      = re.compile(rb"""\bwidth\s*=\s*["']?(\d+)["']?""", re.I)
IMG_H      = re.compile(rb"""\bheight\s*=\s*["']?(\d+)["']?""", re.I)
A_HREF_DQ  = re.compile(rb'(<a\b[^>]*\bhref=)"([^"]*)"', re.I)
A_HREF_SQ  = re.compile(rb"(<a\b[^>]*\bhref=)'([^']*)'", re.I)

USER_AGENT = "MSX-WBrowser/0.5 (openMSX)"
FETCH_TIMEOUT = 20.0


def _html_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def _int_or_none(m):
    return int(m.group(1)) if m else None


def _predict_msx_size(declared_w: int, declared_h: int) -> "tuple[int, int]":
    """Mirror the declared-dimensions branch of _resize_for_msx() so the
    HTML rewriter can update width/height attrs to what the PCX will
    actually be. Keeps the "halve height + round-up width to /4" steps in
    one place; if _resize_for_msx changes its math, update this too."""
    tgt_w = declared_w
    tgt_h = max(1, declared_h // 2)
    MAX_W, MAX_H = 492, 183
    tgt_w = min(MAX_W, max(4, tgt_w))
    tgt_w = (tgt_w + 3) & ~3
    tgt_h = min(MAX_H, max(1, tgt_h))
    return tgt_w, tgt_h


def _resize_for_msx(im: "Image.Image",
                    declared_w: "int | None",
                    declared_h: "int | None") -> "Image.Image":
    """Pick a target size for the PCX we'll ship. MSX Screen 6 has a
    2:1 pixel aspect ratio -- one logical pixel is twice as tall as
    it is wide -- so to keep the image looking proportional we halve
    the on-screen row count before encoding. The browser just paints
    each packed row once and you end up with the right shape.

    Priority:
      1. Honour declared <img width=x height=y> if both given
         (then halve height for the 2:1 correction).
      2. Otherwise keep the source's native size, capped to the MSX
         content area (492 logical wide x 2*183 = 366 source rows
         before the halving), with aspect preserved.

    Width is rounded up to a multiple of 4 so Screen-6's byte-aligned
    row stride works out evenly."""
    src_w, src_h = im.size
    MAX_W = 492
    MAX_H = 183

    if declared_w and declared_h:
        tgt_w, tgt_h = declared_w, declared_h
    else:
        tgt_w, tgt_h = src_w, src_h
        # Treat the source as square-pixeled; we'll halve height at the
        # end, so the "virtual" vertical budget is 2 * MAX_H.
        if tgt_w > MAX_W:
            tgt_h = max(1, round(tgt_h * MAX_W / tgt_w))
            tgt_w = MAX_W
        vh_budget = MAX_H * 2
        if tgt_h > vh_budget:
            tgt_w = max(1, round(tgt_w * vh_budget / tgt_h))
            tgt_h = vh_budget

    # MSX pixel aspect: halve height so the image is tall-wise
    # proportional on screen.
    tgt_h = max(1, tgt_h // 2)

    # Cap + 4-px-align the width.
    tgt_w = min(MAX_W, max(4, tgt_w))
    tgt_w = (tgt_w + 3) & ~3
    tgt_h = min(MAX_H, max(1, tgt_h))

    if (tgt_w, tgt_h) != (src_w, src_h):
        im = im.resize((tgt_w, tgt_h), Image.BOX)
    return im


def _pack_2bpp(im: "Image.Image") -> bytes:
    """Quantise to the MSX Screen-6 4-colour palette and pack 4 pixels
    per byte (MSB-first). Uses a simple luminance bucketing since the
    content-image pipeline doesn't need the full dither-to-pair logic
    the full-page screenshot pipeline had."""
    if im.mode != "L":
        im = im.convert("L")
    w, h = im.size
    row_bytes = w // 4
    px = im.tobytes()
    out = bytearray(h * row_bytes)
    for y in range(h):
        row_start = y * w
        for xb in range(row_bytes):
            b = 0
            for i in range(4):
                v = px[row_start + xb * 4 + i]
                # Four buckets: black(3) / dgray(0) / lgray(1) / white(2).
                # Map luminance -> a pair-friendly nybble.
                if v < 64:
                    p = 3
                elif v < 128:
                    p = 0
                elif v < 192:
                    p = 1
                else:
                    p = 2
                b |= (p & 3) << (6 - i * 2)
            out[y * row_bytes + xb] = b
    return bytes(out)


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
            entry = self._img_cache.get(target.lower())
            if not entry:
                return ("404", None)
            url, dw, dh = entry
            return self._fetch_image(url, dw, dh)

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
            tag = m.group(0)
            src_m = IMG_SRC.search(tag)
            if not src_m:
                return tag
            src = src_m.group(1).decode("latin-1", "replace").strip()
            w = _int_or_none(IMG_W.search(tag))
            h = _int_or_none(IMG_H.search(tag))
            handle = self._register_image(src, w, h)
            new_src = b'src="' + handle.encode("ascii") + b'"'
            new_tag = tag[:src_m.start()] + new_src + tag[src_m.end():]
            # Rewrite width / height to match the dimensions the PCX will
            # actually have after _resize_for_msx(). The browser's sticky
            # re-render path (ReserveImgLayout) reads these attributes to
            # reserve the layout rectangle without re-fetching -- if they
            # disagree with the rendered PCX, content below the image
            # shifts on every Tab. Applies only when the author gave
            # both dimensions; _resize_for_msx() halves height for MSX
            # 2:1 pixel aspect in that path.
            if w and h:
                tgt_w, tgt_h = _predict_msx_size(w, h)
                new_tag = IMG_W.sub(
                    lambda _m, v=tgt_w: b'width="' + str(v).encode() + b'"',
                    new_tag, count=1)
                new_tag = IMG_H.sub(
                    lambda _m, v=tgt_h: b'height="' + str(v).encode() + b'"',
                    new_tag, count=1)
            return new_tag

        def href_repl(m: re.Match) -> bytes:
            prefix = m.group(1)
            href = m.group(2).decode("latin-1", "replace").strip()
            # In-page anchors + javascript: links are useless on MSX; leave
            # them as-is so the click is a no-op rather than a 404.
            if href.startswith(("#", "javascript:", "mailto:")):
                return m.group(0)
            absolute = urllib.parse.urljoin(self._current_base or "", href)
            return prefix + b'"' + absolute.encode("latin-1", "replace") + b'"'

        body = IMG_TAG.sub(img_repl, body)
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

    def _register_image(self, src: str,
                        declared_w: int | None,
                        declared_h: int | None) -> str:
        """Absolutise + mint a short imNN.pcx handle for `src`. The
        declared width/height on the <img> tag (if any) are remembered
        so the PCX we produce on demand matches the author's size --
        otherwise a 174x80 logo ends up 492 px wide."""
        absolute = urllib.parse.urljoin(self._current_base or "", src)
        entry = (absolute, declared_w, declared_h)
        for handle, v in self._img_cache.items():
            if v == entry:
                return handle
        self._img_counter += 1
        handle = f"im{self._img_counter:02d}.pcx"
        self._img_cache[handle] = entry
        return handle

    # -- Image conversion -------------------------------------------------

    def _fetch_image(self, url: str,
                     declared_w: int | None = None,
                     declared_h: int | None = None):
        try:
            raw, _final, ctype = _fetch(url)
        except Exception as exc:
            self._log(f"img fetch failed: {exc}")
            return ("404", None)
        return self._convert_image_bytes(raw, declared_w, declared_h)

    def _convert_image_bytes(self, raw: bytes,
                             declared_w: int | None = None,
                             declared_h: int | None = None):
        try:
            im = Image.open(io.BytesIO(raw))
            im.load()
        except Exception as exc:
            self._log(f"image decode failed: {exc}")
            return ("404", None)
        im = _resize_for_msx(im, declared_w, declared_h)
        pcx = self._to_pcx(im)
        self._log(f"PCX {len(pcx)} B ({im.size[0]}x{im.size[1]})")
        return ("PCX", pcx)

    @staticmethod
    def _to_pcx(im: Image.Image) -> bytes:
        width_px = im.size[0]
        rows = im.size[1]
        row_bytes = width_px // 4
        raw = _pack_2bpp(im)
        hdr = bytearray(128)
        hdr[0] = 0x0A
        hdr[1] = 5
        hdr[2] = 1                              # RLE on
        hdr[3] = 2                              # 2 bpp
        struct.pack_into("<HHHH", hdr, 4, 0, 0, width_px - 1, rows - 1)
        struct.pack_into("<HH",   hdr, 12, 75, 75)
        hdr[65] = 1
        struct.pack_into("<H", hdr, 66, row_bytes)
        hdr[68] = 1
        out = bytearray(hdr)
        for y in range(rows):
            row = raw[y * row_bytes : (y + 1) * row_bytes]
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
    """Responses land in openMSX's rs232-net TCP socket and trickle out
    the emulated 8251 UART at ~9600 baud. The MSX-side SerialRead polls
    byte-at-a-time but has a ~0.8 s inter-byte timeout; a burst of a few
    hundred bytes in a single sendall() can overrun the 1-byte 8251 FIFO
    before the poll loop picks them up. Chunk the body into small
    writes with a tiny sleep between them -- same trick tools/
    serial_host.py uses for the echo tester."""
    if kind in ("HTM", "PCX"):
        header = f"OK {kind} {len(body)}\r\n".encode("ascii")
        conn.sendall(header)
        _slow_send(conn, body)
    elif kind == "404":
        conn.sendall(b"ERR 404\r\n")
    else:
        conn.sendall(b"ERR 500\r\n")


def _slow_send(conn: socket.socket, body: bytes, chunk: int = 64,
               gap: float = 0.005) -> None:
    import time
    for i in range(0, len(body), chunk):
        conn.sendall(body[i:i + chunk])
        time.sleep(gap)


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
