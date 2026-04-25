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


IMG_TAG    = re.compile(r"<img\b[^>]*>", re.I)
IMG_SRC    = re.compile(r"""\bsrc\s*=\s*["']?([^"'\s>]+)["']?""", re.I)
IMG_W      = re.compile(r"""\bwidth\s*=\s*["']?(\d+)["']?""", re.I)
IMG_H      = re.compile(r"""\bheight\s*=\s*["']?(\d+)["']?""", re.I)
A_HREF_DQ  = re.compile(r'(<a\b[^>]*\bhref=)"([^"]*)"', re.I)
A_HREF_SQ  = re.compile(r"(<a\b[^>]*\bhref=)'([^']*)'", re.I)
FORM_TAG   = re.compile(r"(?is)<form\b([^>]*)>")
FORM_ACTION = re.compile(r"""\baction\s*=\s*["']?([^"'\s>]+)["']?""", re.I)
FORM_METHOD = re.compile(r"""\bmethod\s*=\s*["']?(\w+)["']?""", re.I)
FORM_BLOCK  = re.compile(r"(?is)<form\b.*?</form\s*>")
META_CHARSET_B = re.compile(rb"""<meta[^>]*charset\s*=\s*["']?([\w-]+)""", re.I)

USER_AGENT = "MSX-WBrowser/0.5 (openMSX)"
FETCH_TIMEOUT = 20.0

# Outgoing wire encoding. ISO-8859-6 covers Latin letters + ASCII in its
# low half and Arabic in 0xC1..0xDA. The MSX side renders those byte
# values directly through its font tables (Latin + AX-370 Arabic
# CGTABL), so anything the decoder can't map lands as '?' rather than
# arbitrary multi-byte noise.
WIRE_CHARSET = "iso-8859-6"


def _html_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;"))


def _int_or_none(m):
    return int(m.group(1)) if m else None


def _decode_body(raw: bytes, content_type: str) -> str:
    """Decode a server's HTML bytes to unicode. Tries, in order:
    the Content-Type header's charset, a <meta charset> near the top,
    then UTF-8, then a last-ditch latin-1. Aliases like windows-1256
    are kept -- Python handles them natively."""
    charset = None
    m = re.search(r"charset\s*=\s*([\w-]+)", content_type, re.I)
    if m:
        charset = m.group(1).strip().lower()
    if not charset:
        mm = META_CHARSET_B.search(raw[:2048])
        if mm:
            charset = mm.group(1).decode("ascii", "replace").strip().lower()
    for cs in (charset, "utf-8", "cp1256", "latin-1"):
        if not cs:
            continue
        try:
            return raw.decode(cs)
        except (LookupError, UnicodeDecodeError):
            continue
    # Guaranteed to succeed:
    return raw.decode("latin-1", "replace")


def _simplify_with_readability(html: str) -> str:
    """Run Mozilla Readability (via the Python port) to extract the
    article-like content of the page. Keeps the original title. Falls
    back to the input unchanged if the library isn't installed or the
    extraction produced nothing useful (pages that aren't articles --
    home pages, search results, login forms -- usually don't)."""
    try:
        from readability import Document
    except ImportError:
        return html
    try:
        doc = Document(html)
        summary = doc.summary(html_partial=False)
        title = doc.title() or ""
    except Exception:
        return html
    if not summary or len(summary) < 64:
        return html
    # Glue on a head with the original title so the MSX titlebar still
    # reflects the page the user visited, not an empty string.
    head = f"<html><head><title>{_html_escape(title)}</title></head>"
    return head + summary + "</html>"


def _preserve_forms(original: str, simplified: str) -> str:
    """Readability typically strips <form> blocks (they're not article
    content), which kills interactive pages like search boxes. Find
    every form in the source HTML and, if any are missing from the
    simplified version, paste them back in just before </body>."""
    forms = FORM_BLOCK.findall(original)
    if not forms:
        return simplified
    missing = [f for f in forms if f not in simplified]
    if not missing:
        return simplified
    appendage = "\n" + "\n".join(missing) + "\n"
    if re.search(r"(?i)</body>", simplified):
        return re.sub(r"(?i)</body>", appendage + "</body>",
                      simplified, count=1)
    return simplified + appendage


def _retranscode_query(q: str) -> str:
    """The MSX URL-encodes form values as raw ISO-8859-6 bytes. The
    destination site expects UTF-8 (the modern default). Unescape the
    %XX sequences, reinterpret the bytes as ISO-8859-6, and re-encode
    to UTF-8 URL form. ASCII-only queries survive unchanged."""
    pairs = []
    for pair in q.split("&"):
        if not pair:
            continue
        if "=" in pair:
            k, v = pair.split("=", 1)
        else:
            k, v = pair, ""
        k_uni = urllib.parse.unquote_to_bytes(k).decode(WIRE_CHARSET, "replace")
        v_uni = urllib.parse.unquote_to_bytes(v).decode(WIRE_CHARSET, "replace")
        pairs.append((k_uni, v_uni))
    return urllib.parse.urlencode(pairs)


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
    # Viewport simulator parameters. The MSX content area is 492 px /
    # 8 px-per-glyph = ~61 chars wide and TEXT_MAX_LINES = 22 visible
    # 8-px rows tall. The simulator walks each chunk like a tiny
    # browser -- accumulating chars per line, wrapping at LINE_CHARS,
    # bumping the line counter on block-end tags, doubling cost
    # inside <h1>/<h2> -- and cuts as soon as the rendered total
    # would overflow the viewport. MAX_CHUNK_BYTES is a hard
    # watchdog for pathological pages (huge data: URLs, single
    # multi-KB <a href> with no whitespace, etc.) so the browser's
    # serial timeout doesn't bite.
    LINE_CHARS      = 60
    # MSX content area is 183 px (CONTENT_Y1 - CONTENT_Y0 + 1) but the
    # block-level tags the simulator doesn't model (<h1> and <table>
    # each call EmitBlankLine on open + close, <h1>...</h1> also adds a
    # half-line gap below) carve out roughly 40 px for typical pages.
    # Budget against the leftover so the chunk doesn't clip below the
    # fold even when h1 / table overhead lands.
    VIEWPORT_PX     = 140
    TEXT_LINE_PX    = 8       # TEXT_LINE_H
    TR_LINE_PX      = 10      # TEXT_LINE_H + TABLE_ROW_GAP
    MAX_CHUNK_BYTES = 6000

    def __init__(self, verbose: bool = False, simplify: bool = False,
                 no_images: bool = False, pagination: bool = False):
        self.verbose = verbose
        self.simplify = simplify
        self.no_images = no_images
        self.pagination = pagination
        self._img_cache: dict[str, str] = {}
        self._current_base: str | None = None
        self._img_counter = 0
        # Pagination state for the current page-load. _pending_chunks is
        # FIFO; first fetch returns chunks[0] and shifts; later "GET MORE"
        # requests pop the next one. _page_total stays fixed for the
        # whole session so the page header always reports M/N consistently.
        self._pending_chunks: list[bytes] = []
        self._page_total: int = 0
        self._page_served: int = 0

    # -- public -----------------------------------------------------------

    def handle_get(self, target: str):
        self._log(f"GET {target!r}")

        # MORE: serve the next chunk of the current paginated page.
        # See the OK HTM "<bytes> <page>/<total>" header below.
        if target.upper() == "MORE":
            return self._serve_next_chunk()

        # The MSX used to POST form data to a bridge-local "/submit?..."
        # shim; the browser now builds the full target URL from the
        # <form action=...> attribute (which we absolutise during the
        # HTML rewrite) and sends it as a plain GET. Keep a compatibility
        # fallback for the form_bridge.py echo server and for pages
        # whose browser-side action parse failed.
        if target.startswith("http:/submit") or target.startswith("/submit"):
            stripped = target[5:] if target.startswith("http:") else target
            return self._echo_submit(
                stripped.split("?", 1)[1] if "?" in stripped else "")

        # Image handle produced by our own HTML rewriter: imNN.pcx.
        if re.fullmatch(r"im\d+\.pcx", target, flags=re.I):
            if self.no_images:
                return ("404", None)
            entry = self._img_cache.get(target.lower())
            if not entry:
                return ("404", None)
            url, dw, dh = entry
            return self._fetch_image(url, dw, dh)

        # Real URL? Fetch and passthrough.
        if target.lower().startswith(("http://", "https://")):
            return self._fetch_page(target)

        # Bare hostname / path -- the user typed "frogfind.com" or
        # "msx.org/foo" without a scheme. Prepend http:// and fetch.
        # Reject anything that doesn't even contain a '.' (most
        # mistypes / bookmarklets).
        if "." in target or target.startswith("/"):
            return self._fetch_page("http://" + target.lstrip("/"))

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

        # Everything else we treat as HTML / text. Decode upstream's
        # bytes using whatever charset the server advertises, strip
        # scripts/styles, optionally run Readability, preserve any
        # <form> we'd need to submit back, rewrite img srcs + a hrefs
        # + width/height, and finally re-encode as ISO-8859-6 for the
        # MSX wire protocol.
        html = _decode_body(raw, content_type)
        body = self._rewrite_html(html).encode(WIRE_CHARSET, "replace")
        # Split the encoded body into viewport-sized chunks at safe
        # tag boundaries when --pagination is on; otherwise ship the
        # whole body as one OK HTM frame. Chunking is opt-in because
        # the chunk seams can split tags or links on hostile pages.
        if self.pagination:
            chunks = self._split_into_chunks(body)
        else:
            chunks = [body]
        self._pending_chunks = chunks
        self._page_total = len(chunks)
        self._page_served = 0
        self._log(f"HTM {len(body)} B (was {len(raw)}) -> "
                  f"{self._page_total} chunk(s) from {final_url}")
        return self._serve_next_chunk()

    def _serve_next_chunk(self):
        """Pop the next pending chunk and ship it as 'OK HTM B P/T'."""
        if not self._pending_chunks:
            return ("404", None)
        chunk = self._pending_chunks.pop(0)
        self._page_served += 1
        return ("HTMP", (chunk, self._page_served, self._page_total))

    # Tags the MSX parser treats as a newline. Each row carries the
    # row's pixel cost so the simulator can sum them against the
    # viewport's 183-px content area instead of pretending every
    # tag is exactly 8 px tall. Most lines are TEXT_LINE_H = 8 px;
    # <tr> rows draw text + TABLE_ROW_GAP (2 px) = 10 px.
    _LINE_END_RE = re.compile(
        rb"(?i)<br\s*/?>|</p>|</tr>|</li>|</h[1-6]>|</div>|</center>")
    _TR_END_RE   = re.compile(rb"(?i)</tr>")
    # h1 / h2 render at scale 2 -> their lines count double the height.
    _SCALE2_OPEN  = re.compile(rb"(?i)<h[12](?:\s[^>]*)?>")
    _SCALE2_CLOSE = re.compile(rb"(?i)</h[12]>")

    def _split_into_chunks(self, body: bytes) -> list[bytes]:
        """Walk `body` simulating the MSX renderer in pixels: every
        block-end marker advances a virtual TextY (8 px standard, 10 px
        for </tr>, doubled inside <h1>/<h2>); a text run that wraps
        past LINE_CHARS spills onto another line at the current scale.
        Cut at the FIRST safe boundary whose advance would push past
        VIEWPORT_PX. Falls back to MAX_CHUNK_BYTES + last '>' for
        pathological pages with no usable line markers."""
        view_px   = self.VIEWPORT_PX
        line_px   = self.TEXT_LINE_PX
        tr_px     = self.TR_LINE_PX
        line_w    = self.LINE_CHARS
        byte_lim  = self.MAX_CHUNK_BYTES
        line_re   = self._LINE_END_RE
        tr_re     = self._TR_END_RE
        h2_open   = self._SCALE2_OPEN
        h2_close  = self._SCALE2_CLOSE

        chunks: list[bytes] = []
        pos, n = 0, len(body)
        while pos < n:
            end_limit = min(pos + byte_lim, n)
            i = pos
            scale = 1                        # 1 = normal, 2 = inside <h1>/<h2>
            cur_chars = 0
            used_px = 0
            last_safe = -1                   # last clean cut point seen
            while i < end_limit:
                if body[i] == 0x3C:          # '<' -> tag
                    tag_end = body.find(b">", i, end_limit)
                    if tag_end == -1:
                        break
                    tag = body[i:tag_end + 1]
                    low = tag.lower()
                    if h2_open.match(low):
                        scale = 2
                    elif h2_close.match(low):
                        scale = 1
                    if line_re.match(low):
                        # Flush text wrap then the marker's own row.
                        per_px = (tr_px if tr_re.match(low) else line_px) * scale
                        if cur_chars > 0:
                            wrap_lines = (cur_chars + line_w - 1) // line_w
                            used_px += wrap_lines * line_px * scale
                        else:
                            used_px += per_px
                        cur_chars = 0
                        last_safe = tag_end + 1
                        if used_px >= view_px:
                            break
                    i = tag_end + 1
                else:
                    b = body[i]
                    if b in (0x20, 0x09, 0x0A, 0x0D):
                        if cur_chars > 0:
                            cur_chars += 1
                            if cur_chars >= line_w:
                                used_px += line_px * scale
                                cur_chars = 0
                    else:
                        cur_chars += 1
                        if cur_chars >= line_w:
                            used_px += line_px * scale
                            cur_chars = 0
                    i += 1
            # Decide where to cut.
            if end_limit == n and used_px < view_px:
                # Whole tail fits in remaining viewport -> ship it.
                chunks.append(body[pos:])
                break
            if last_safe > pos:
                cut = last_safe
            else:
                # No line marker inside the byte budget; cut at the
                # last '>' so we don't split mid-tag. Hard-cut at the
                # byte limit if even that fails.
                gt = body.rfind(b">", pos, end_limit)
                cut = gt + 1 if gt != -1 else end_limit
            chunks.append(body[pos:cut])
            pos = cut
        return chunks if chunks else [body]

    def _rewrite_html(self, html: str) -> str:
        # Drop script/style/noscript blocks: the MSX parser ignores
        # them but stripping keeps the wire small and frees Readability
        # from parsing JS.
        html = re.sub(r"(?is)<script\b[^>]*>.*?</script>", "", html)
        html = re.sub(r"(?is)<style\b[^>]*>.*?</style>", "", html)
        html = re.sub(r"(?is)<noscript\b[^>]*>.*?</noscript>", "", html)
        # Drop HTML comments. The MSX parser doesn't render them, and
        # they often hide entire blocks of dead markup that still
        # consume wire budget.
        html = re.sub(r"(?is)<!--.*?-->", "", html)
        # Collapse runs of whitespace in TEXT positions to a single
        # space; collapse multiple inter-tag newlines to one. The MSX
        # renderer normalises whitespace anyway, so the source-side
        # pretty-printing just wastes serial budget. Don't touch the
        # contents of <pre> -- preserved whitespace matters there.
        # Cheap heuristic: protect <pre>...</pre> blocks behind a
        # placeholder, compress everything else, then restore.
        pre_blocks: list[str] = []
        def _stash_pre(m):
            pre_blocks.append(m.group(0))
            return f"\x00PRE{len(pre_blocks)-1}\x00"
        html = re.sub(r"(?is)<pre\b.*?</pre>", _stash_pre, html)
        # Strip whitespace-only runs between '>' and '<'.
        html = re.sub(r">\s+<", "><", html)
        # Collapse remaining consecutive whitespace to a single space.
        html = re.sub(r"[ \t\r\n]{2,}", " ", html)
        # Restore <pre>.
        html = re.sub(r"\x00PRE(\d+)\x00",
                      lambda m: pre_blocks[int(m.group(1))], html)

        # Simplify article-like pages via Readability, then splice any
        # <form> back in (Readability drops them as non-article chrome).
        if self.simplify:
            simplified = _simplify_with_readability(html)
            html = _preserve_forms(html, simplified)

        # Reset per-page image cache.
        self._img_cache = {}
        self._img_counter = 0

        def img_repl(m: re.Match) -> str:
            # --no-images: drop every <img> so the MSX never even asks
            # the bridge for a PCX. Big wall-clock win for test runs.
            if self.no_images:
                return ""
            tag = m.group(0)
            src_m = IMG_SRC.search(tag)
            if not src_m:
                return tag
            src = src_m.group(1).strip()
            w = _int_or_none(IMG_W.search(tag))
            h = _int_or_none(IMG_H.search(tag))
            handle = self._register_image(src, w, h)
            new_src = f'src="{handle}"'
            new_tag = tag[:src_m.start()] + new_src + tag[src_m.end():]
            # Rewrite width / height to the post-resize PCX dimensions so
            # the browser's sticky re-render path (ReserveImgLayout)
            # reserves a rect matching what the PCX actually paints.
            if w and h:
                tgt_w, tgt_h = _predict_msx_size(w, h)
                new_tag = IMG_W.sub(f'width="{tgt_w}"', new_tag, count=1)
                new_tag = IMG_H.sub(f'height="{tgt_h}"', new_tag, count=1)
            return new_tag

        def href_repl(m: re.Match) -> str:
            prefix = m.group(1)
            href = m.group(2).strip()
            # In-page anchors + javascript: are no-ops on MSX; leave
            # them alone so the click doesn't 404.
            if href.startswith(("#", "javascript:", "mailto:")):
                return m.group(0)
            absolute = urllib.parse.urljoin(self._current_base or "", href)
            return f'{prefix}"{absolute}"'

        def form_repl(m: re.Match) -> str:
            # Absolutise <form action="..."> so the MSX can POST (well,
            # GET) directly to the real site without having to know its
            # own base URL. We can't build on IMG_SRC-style regex here
            # because we need to preserve the rest of the tag verbatim.
            tag = m.group(0)
            am = FORM_ACTION.search(tag)
            if not am:
                return tag
            action = am.group(1).strip()
            absolute = urllib.parse.urljoin(self._current_base or "", action)
            new_attr = f'action="{absolute}"'
            return tag[:am.start()] + new_attr + tag[am.end():]

        html = IMG_TAG.sub(img_repl, html)
        html = A_HREF_DQ.sub(href_repl, html)
        html = A_HREF_SQ.sub(href_repl, html)
        html = FORM_TAG.sub(form_repl, html)
        return html

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

    def _echo_submit(self, raw_query: str):
        """Tiny local echo for the /submit compat path. The MSX browser
        builds the real target URL from <form action=...> itself, so
        this only fires when the author shipped a form with no action
        attribute (or for standalone tests with form_bridge.py)."""
        pairs = []
        if raw_query:
            for pair in raw_query.split("&"):
                if "=" in pair:
                    k, v = pair.split("=", 1)
                else:
                    k, v = pair, ""
                # Interpret %XX as ISO-8859-6 bytes (matches what the
                # MSX actually sent) so the echo shows the expected
                # string back.
                kb = urllib.parse.unquote_to_bytes(k).decode(WIRE_CHARSET, "replace")
                vb = urllib.parse.unquote_to_bytes(v).decode(WIRE_CHARSET, "replace")
                pairs.append((kb, vb))
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
        return ("HTM", body.encode(WIRE_CHARSET, "replace"))

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
    elif kind == "HTMP":
        # Paginated HTM: body is a (bytes, page, total) tuple. The
        # extended header "OK HTM <bytes> <page>/<total>\r\n" is only
        # sent when total > 1, so single-chunk pages keep the legacy
        # "OK HTM <bytes>\r\n" wire format and old browsers Just Work.
        chunk, page, total = body
        if total > 1:
            header = f"OK HTM {len(chunk)} {page}/{total}\r\n".encode("ascii")
        else:
            header = f"OK HTM {len(chunk)}\r\n".encode("ascii")
        conn.sendall(header)
        _slow_send(conn, chunk)
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


def serve_forever(host: str, port: int, verbose: bool,
                  simplify: bool = False,
                  no_images: bool = False,
                  pagination: bool = False) -> None:
    session = BridgeSession(verbose=verbose, simplify=simplify,
                            no_images=no_images, pagination=pagination)
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
    ap.add_argument("--simplify", action="store_true",
                    help="Run Mozilla Readability on incoming HTML to strip "
                         "chrome/footers/sidebars. Off by default because it "
                         "tends to displace or mangle pages where the main "
                         "content IS a form (search boxes, login pages).")
    ap.add_argument("--no-images", action="store_true",
                    help="Strip every <img> tag before shipping HTML to the "
                         "MSX. Handy for test runs -- PCX encode + serial "
                         "transfer of an image costs real wall-clock time, "
                         "which drowns out the rest of the render timings.")
    ap.add_argument("--pagination", action="store_true",
                    help="Chunk the body into ~1.2 KB OK HTM frames at safe "
                         "tag boundaries. Off by default because the chunk "
                         "boundaries can break tags and links on some pages; "
                         "enable when a page is too big to ship in one go.")
    args = ap.parse_args()
    try:
        serve_forever(args.host, args.port, args.verbose,
                      simplify=args.simplify,
                      no_images=args.no_images,
                      pagination=args.pagination)
    except KeyboardInterrupt:
        print("\nbye.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
