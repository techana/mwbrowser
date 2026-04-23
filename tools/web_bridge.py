#!/usr/bin/env python3
"""Serial web bridge for the MSX WBrowser.

Listens on a TCP port (openMSX's rs232-net pluggable dials out to us)
and answers a tiny line-oriented protocol:

    MSX -> bridge:  GET <target>\\r\\n
    bridge -> MSX:  OK HTM <length>\\r\\n<body>
                    OK PCX <length>\\r\\n<body>
                    ERR 404\\r\\n
                    ERR 500\\r\\n

Behaviour per request:
  - "GET http://..."  -- fetch + render. For image URLs the response
    is a single PCX. For HTML, the response is an MSX-friendly wrapper
    whose <img src="pgNN.pcx"> tags refer back to the bridge's cache.
  - "GET pgNN.pcx" (bare name, no scheme) -- serve chunk NN of the
    most recently rendered page.
  - Anything else -- ERR 404.

Run:
    python3 tools/web_bridge.py [--host 127.0.0.1] [--port 2323] [--verbose]

Pair with:
    openmsx -exta rs232 -script tools/plug_rs232.tcl
    A> mwbrowsr
    Address bar: e.g. `http://www.bbcarabic.com`  (no drive: prefix)
"""

from __future__ import annotations

import argparse
import asyncio
import io
import socket
import struct
import sys
import urllib.parse
from pathlib import Path

# Reuse the encoding primitives from the web_to_sc6 tool -- keeps the
# PCX output identical to what web_to_sc6.py writes to disk.
sys.path.insert(0, str(Path(__file__).parent))
import web_to_sc6 as w2s  # noqa: E402

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow required: pip install Pillow")

try:
    from playwright.async_api import async_playwright
except ImportError:
    sys.exit("Playwright required: pip install playwright && python3 -m playwright install chromium")


IMG_EXTS = (".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp")


def _looks_like_url(s: str) -> bool:
    return s.lower().startswith(("http://", "https://"))


def _html_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def _is_image_url(url: str) -> bool:
    path = urllib.parse.urlparse(url).path.lower()
    return path.endswith(IMG_EXTS)


# ----------------------------------------------------------------------------
# Playwright render (HTML page -> tall PNG + link boxes). Same pipeline as
# tools/web_to_sc6.py, minus the on-disk emission.
# ----------------------------------------------------------------------------

async def _render_page(url: str) -> tuple[str, Image.Image, list[dict]]:
    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        ctx = await browser.new_context(
            viewport={"width": w2s.MSX_VIEWPORT_W, "height": w2s.MSX_VIEWPORT_H},
            device_scale_factor=1,
        )
        page = await ctx.new_page()
        await page.goto(url, wait_until="networkidle", timeout=45000)
        await page.add_style_tag(content=w2s.READABILITY_CSS)
        await page.wait_for_timeout(400)
        png_bytes = await page.screenshot(full_page=True)
        title = await page.title()
        links = await page.evaluate("""
() => {
    const out = [];
    for (const a of document.querySelectorAll('a[href]')) {
        const r = a.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) continue;
        out.push({
            x: Math.round(r.left),
            y: Math.round(r.top + window.scrollY),
            w: Math.round(r.width),
            h: Math.round(r.height),
            href: a.href,
        });
    }
    return out;
}
""")
        await browser.close()
    im = Image.open(io.BytesIO(png_bytes))
    return title, im, links


def _render_image_url(data: bytes) -> Image.Image:
    im = Image.open(io.BytesIO(data))
    im.load()
    return im


# ----------------------------------------------------------------------------
# Bridge session state. Only one active page at a time; chunks for the most
# recent URL live in _chunk_store, keyed by bare filename.
# ----------------------------------------------------------------------------

class BridgeSession:
    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self._chunks: dict[str, bytes] = {}
        self._current_origin: str | None = None

    # -- public API ------------------------------------------------------

    def handle_get(self, target: str) -> tuple[str, bytes] | tuple[str, None]:
        """Returns ("HTM", body) / ("PCX", body) / ("404", None)."""
        self._log(f"GET {target!r}")
        if target.startswith("/submit?") or target.startswith("/submit"):
            return self._handle_submit(target)
        if _looks_like_url(target):
            return self._fetch_url(target)
        # Bare filename -> try the current page's chunk cache.
        blob = self._chunks.get(target.lower())
        if blob is None:
            return ("404", None)
        return ("PCX", blob)

    def _handle_submit(self, target: str) -> tuple[str, bytes]:
        """Echo-render a form submission. The browser builds
        "/submit?a=1&b=2" and lands it here via the same RemoteGet path
        regular URL loads use; we answer with a small HTML page that
        shows each received field so the operator can verify the
        round-trip on the MSX screen."""
        q = ""
        if "?" in target:
            q = target.split("?", 1)[1]
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

    # -- implementation --------------------------------------------------

    def _fetch_url(self, url: str) -> tuple[str, bytes] | tuple[str, None]:
        # Image URLs are converted directly to PCX and shipped.
        if _is_image_url(url):
            try:
                import urllib.request
                with urllib.request.urlopen(url, timeout=15) as r:
                    raw = r.read()
                im = _render_image_url(raw)
                im = w2s._resize_to_msx(im, Image.BOX)
                pcx = self._to_pcx(im)
                return ("PCX", pcx)
            except Exception as exc:
                self._log(f"image fetch failed: {exc}")
                return ("404", None)

        # HTML page: render with Playwright, slice into full-viewport
        # PCX chunks, stash them, hand back the HTM wrapper.
        try:
            title, im, links = asyncio.run(_render_page(url))
        except Exception as exc:
            self._log(f"playwright failed: {exc}")
            return ("404", None)

        im = w2s._resize_to_msx(im, Image.BOX)
        total_h = im.size[1]
        rows = w2s.MSX_VIEWPORT_H
        pages = (total_h + rows - 1) // rows
        self._chunks = {}
        self._current_origin = url
        chunks_meta = []
        for i in range(pages):
            name = f"pg{i + 1:02d}.pcx"
            top = i * rows
            bot = min(total_h, top + rows)
            sub = im.crop((0, top, im.size[0], bot))
            pcx = self._to_pcx(sub)
            self._chunks[name] = pcx
            areas = w2s._clip_links_to_chunk(links, top, bot - top)
            chunks_meta.append({
                "name":   name.upper(),
                "map_id": f"M{i + 1:02d}" if areas else None,
                "areas":  areas,
            })
        self._log(f"rendered {url} -> {pages} chunks, {sum(len(b) for b in self._chunks.values())} B")
        html = w2s._wrapper_html(chunks_meta, title or url)
        return ("HTM", html.encode("iso-8859-6", "replace"))

    @staticmethod
    def _to_pcx(im: Image.Image) -> bytes:
        """In-memory twin of web_to_sc6._write_pcx_2bpp."""
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

    def _log(self, msg: str) -> None:
        if self.verbose:
            print(f"[bridge] {msg}", flush=True)


# ----------------------------------------------------------------------------
# Line-oriented TCP server. openMSX dials out; we accept a single connection
# at a time (serialises nicely with the emulator's single UART).
# ----------------------------------------------------------------------------

def _readline(conn: socket.socket) -> bytes:
    """Blocking read up to and including \\r\\n."""
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


def _send_response(conn: socket.socket, kind: str, body: bytes | None) -> None:
    if kind == "HTM" or kind == "PCX":
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
    print(f"web bridge listening on {host}:{port}", flush=True)
    while True:
        conn, addr = srv.accept()
        print(f"openMSX connected from {addr}", flush=True)
        try:
            while True:
                line = _readline(conn)
                if not line:
                    break
                if not line.endswith(b"\r\n"):
                    _send_response(conn, "500", None)
                    break
                try:
                    text = line.rstrip(b"\r\n").decode("ascii", "replace")
                except Exception:
                    _send_response(conn, "500", None)
                    continue
                if not text.startswith("GET "):
                    _send_response(conn, "500", None)
                    continue
                target = text[4:].strip()
                kind, body = session.handle_get(target)
                _send_response(conn, kind, body)
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            conn.close()
            print("connection closed; waiting for next", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=2323)
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()
    try:
        serve_forever(args.host, args.port, args.verbose)
    except KeyboardInterrupt:
        print("\nshutting down", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
