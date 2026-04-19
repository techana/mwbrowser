#!/usr/bin/env python3
"""Convert <img> tags in an HTML page to MSX WBrowser's data:msx;base64 format.

Usage:
    img_encode.py <input.html-or-url> [<output.html>]

Processing per image:
    1. Fetch (http/https URL or local path; path may be absolute or relative
       to the HTML file's directory).
    2. If wider than the MSX content area, scale the width down to fit while
       keeping aspect ratio.
    3. Halve the height (width kept from step 2). This compensates for the
       ~2:1 display pixel aspect of Screen 6.
    4. Quantize to the four Screen-6 palette colours (white, light gray,
       dark gray, black).
    5. Pack as 2 bpp row-major bytes (4 pixels per byte, MSB first) with a
       two-byte header (width-in-bytes, height-in-rows) and base64-encode.
    6. Write the encoded payload back into the <img src=...> as
       data:msx;base64,... .

Needs: Pillow, requests (optional; urllib is used for URLs).
"""

from __future__ import annotations

import argparse
import base64
import io
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Optional, Tuple

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install Pillow")


# --- MSX WBrowser constants -------------------------------------------------

# Screen 6 content area width (CONTENT_X_END = 491 inclusive).
MSX_VIEW_W = 492

# Palette slots (Screen 6 pair values that the browser expects).
PAL_DGRAY = 0
PAL_LGRAY = 1
PAL_WHITE = 2
PAL_BLACK = 3

# RGB targets that the quantizer snaps each pixel to.
PAL_RGB = {
    PAL_WHITE: (255, 255, 255),
    PAL_LGRAY: (192, 192, 192),
    PAL_DGRAY: (96, 96, 96),
    PAL_BLACK: (0, 0, 0),
}


# --- Image fetching --------------------------------------------------------

def _is_url(s: str) -> bool:
    return s.lower().startswith(("http://", "https://"))


def fetch_bytes(source: str, base_dir: Optional[str] = None) -> bytes:
    if _is_url(source):
        with urllib.request.urlopen(source, timeout=15) as r:
            return r.read()
    # Local path: allow both absolute and relative-to-base-dir.
    path = source
    if base_dir and not os.path.isabs(path):
        path = os.path.join(base_dir, path)
    with open(path, "rb") as f:
        return f.read()


# --- Image processing ------------------------------------------------------

def _nearest_palette_index(rgb: Tuple[int, int, int]) -> int:
    # Pick palette entry closest in Euclidean RGB distance.
    r, g, b = rgb
    best = PAL_WHITE
    best_d = None
    for idx, (pr, pg, pb) in PAL_RGB.items():
        d = (pr - r) ** 2 + (pg - g) ** 2 + (pb - b) ** 2
        if best_d is None or d < best_d:
            best, best_d = idx, d
    return best


def quantize_to_palette(im: Image.Image) -> Image.Image:
    # Build a PIL palette image with our four fixed colours and dither onto it.
    pal_flat = []
    # Keep slot 0..3 ordering consistent with PAL_RGB lookup above, then pad to 256.
    for idx in (PAL_DGRAY, PAL_LGRAY, PAL_WHITE, PAL_BLACK):
        pal_flat.extend(PAL_RGB[idx])
    pal_flat.extend([0] * (768 - len(pal_flat)))
    pal_im = Image.new("P", (16, 16))
    pal_im.putpalette(pal_flat)
    rgb = im.convert("RGB")
    q = rgb.quantize(palette=pal_im, dither=Image.Dither.FLOYDSTEINBERG)
    return q  # palette indices correspond to DGRAY / LGRAY / WHITE / BLACK slots 0..3


# Screen-6 content viewport is 183 px tall. Stay a hair under it so a
# block-level image never spills past the bottom border (which would wrap
# around the Screen-6 VRAM and overwrite the titlebar). The format byte
# allows 255 but the browser can only show ~180 rows of any one image.
MAX_H = 180


def resize_for_msx(im: Image.Image) -> Image.Image:
    w, h = im.size
    # Step 1: scale down to viewport width if wider, keep aspect ratio.
    target_w = min(w, MSX_VIEW_W)
    if target_w != w:
        new_h = max(1, round(h * (target_w / w)))
        im = im.resize((target_w, new_h), Image.LANCZOS)
    # Round width down to a multiple of 4 (our 2 bpp format packs 4 px / byte).
    w = im.size[0] - (im.size[0] % 4)
    if w != im.size[0]:
        im = im.crop((0, 0, w, im.size[1]))
    # Step 2: halve the height.
    new_h = max(1, im.size[1] // 2)
    im = im.resize((im.size[0], new_h), Image.LANCZOS)
    # Format only has 8 bits for height; if the halved image is still too
    # tall, scale both dimensions down proportionally (width stays multiple
    # of 4) so the final picture fits the header limits.
    if im.size[1] > MAX_H:
        scale = MAX_H / im.size[1]
        new_w = max(4, int(round(im.size[0] * scale)))
        new_w -= new_w % 4
        im = im.resize((new_w, MAX_H), Image.LANCZOS)
    return im


def encode_msx(im: Image.Image) -> str:
    """Pack the palette-mapped image into the browser's 2 bpp byte stream
    plus the two-byte header, then base64-encode."""
    w, h = im.size
    assert w % 4 == 0, f"width {w} is not a multiple of 4"
    assert w // 4 <= 255 and h <= 255, f"image {w}x{h} exceeds 255-byte header limits"
    pixels = im.load()
    out = bytearray([w // 4, h])
    for y in range(h):
        for x in range(0, w, 4):
            b = 0
            for k in range(4):
                b |= (pixels[x + k, y] & 0x03) << ((3 - k) * 2)
            out.append(b)
    return base64.b64encode(bytes(out)).decode()


# --- HTML rewriting --------------------------------------------------------

IMG_RE = re.compile(r"<img\b[^>]*>", re.IGNORECASE | re.DOTALL)
SRC_RE = re.compile(r"""(?P<key>\bsrc\b)\s*=\s*(?P<val>"[^"]*"|'[^']*'|[^\s>]+)""",
                    re.IGNORECASE)


@dataclass
class Rewrite:
    orig_tag: str
    new_tag: str
    before_len: int  # bytes
    after_len: int


def rewrite_img_tag(tag: str, base_dir: Optional[str]) -> Tuple[str, Optional[str]]:
    """Return (new_tag, note). `note` is either a failure message or None."""
    m = SRC_RE.search(tag)
    if not m:
        return tag, "no src attribute"
    raw = m.group("val")
    if raw.startswith(('"', "'")):
        src_value = raw[1:-1]
    else:
        src_value = raw
    # Skip images already in data: form so we don't double-encode.
    if src_value.lower().startswith("data:"):
        return tag, "already data-uri"
    try:
        blob = fetch_bytes(src_value, base_dir)
        with Image.open(io.BytesIO(blob)) as im:
            im.load()
            im = resize_for_msx(im)
            im = quantize_to_palette(im)
            payload = encode_msx(im)
    except Exception as exc:
        return tag, f"failed {src_value}: {exc}"
    new_src = f'"data:msx;base64,{payload}"'
    new_tag = tag[:m.start("val")] + new_src + tag[m.end("val"):]
    return new_tag, None


def rewrite_html(html: str, base_dir: Optional[str]) -> Tuple[str, list]:
    notes = []
    pieces = []
    last = 0
    for m in IMG_RE.finditer(html):
        pieces.append(html[last:m.start()])
        new_tag, note = rewrite_img_tag(m.group(0), base_dir)
        if note:
            notes.append(note)
        pieces.append(new_tag)
        last = m.end()
    pieces.append(html[last:])
    return "".join(pieces), notes


# --- CLI -------------------------------------------------------------------

def read_html_input(source: str) -> Tuple[str, Optional[str]]:
    """Returns (html_text, base_dir_for_relative_urls)."""
    if _is_url(source):
        with urllib.request.urlopen(source, timeout=15) as r:
            raw = r.read()
        # Use the URL's directory as base for relative <img src>.
        base = urllib.parse.urljoin(source, ".")
        html = raw.decode("utf-8", errors="replace")
        return html, base
    with open(source, "rb") as f:
        raw = f.read()
    return raw.decode("utf-8", errors="replace"), os.path.dirname(os.path.abspath(source))


def default_output_for(source: str) -> str:
    if _is_url(source):
        return "output.msx.html"
    # Place the rewritten file next to the input so relative paths stay sane.
    base = os.path.splitext(source)[0]
    return f"{base}.msx.html"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("source", help="Path or URL to the input HTML page")
    ap.add_argument("output", nargs="?", default=None, help="Output HTML path (defaults to <source>.msx.html)")
    args = ap.parse_args()

    html, base_dir = read_html_input(args.source)
    new_html, notes = rewrite_html(html, base_dir)

    out_path = args.output or default_output_for(args.source)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(new_html)

    print(f"Wrote {out_path}")
    if notes:
        print("Notes:")
        for n in notes:
            print(f"  - {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
