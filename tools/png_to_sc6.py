#!/usr/bin/env python3
"""Convert a small PNG (2..4 colours) to an MSX Screen-6 .sc6 file that
MSX WBrowser can load via <img src="foo.sc6">.

The browser renders SC6 pixels through a 0-3 remap that maps the
conventional "0 = black, 3 = white" SC6 palette onto our UI-tuned
Screen-6 palette:

    file value 0 -> black
    file value 1 -> mid-grey (dither)
    file value 2 -> light grey
    file value 3 -> white

This script emits values in that convention, so you can encode with a
stock image editor and drop the result on the disk.

Aspect ratio: Screen 6 pixels are roughly 0.55 as wide as they are
tall, so a square source image would look narrow+stretched if we
stored it 1-for-1. We compensate by halving the source height after
any width fitting -- same convention as img_encode.py.

Usage:
    png_to_sc6.py input.png [-o output.sc6]
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install Pillow")


# --- MSX WBrowser palette the SC6 file is authored against -----------------

# Browser Screen-6 palette slots (in our .COM palette order):
#   slot 0 = dgray dither, slot 1 = lgray, slot 2 = white, slot 3 = black.
# SC6 file -> slot remap applied by the browser is (0,1,2,3) -> (3,0,1,2),
# so file value 0 displays as black and file value 3 displays as white.
# We author files in that convention:
FILE_RGB = {
    0: (0, 0, 0),         # black
    1: (96, 96, 96),      # dark grey (displays as dither)
    2: (192, 192, 192),   # light grey
    3: (255, 255, 255),   # white
}

# MSX WBrowser layout constants
CONTENT_W_PX    = 492                # visible content width
CONTENT_H_PX    = 183                # viewport height (CONTENT_Y1 - CONTENT_Y0 + 1)
SC6_ROW_BYTES   = 128                # full Screen-6 row (512 px at 2 bpp)
PAD_BYTE        = 0xFF               # four value-3 pixels -> white background

# MAX_H caps the post-halve height so a tall portrait can't push a single
# image off the bottom of the viewport. Matches img_encode.py.
MAX_H           = 180


# --- Palette snap ----------------------------------------------------------

def nearest_palette(rgb: tuple[int, int, int]) -> int:
    """Pick the closest FILE_RGB entry by Euclidean RGB distance."""
    r, g, b = rgb
    best_idx, best_d = 0, None
    for idx, (pr, pg, pb) in FILE_RGB.items():
        d = (pr - r) ** 2 + (pg - g) ** 2 + (pb - b) ** 2
        if best_d is None or d < best_d:
            best_idx, best_d = idx, d
    return best_idx


def build_palette_image() -> Image.Image:
    """A 4-entry palette image for Pillow's quantize() / dither path."""
    flat = []
    for i in range(4):
        flat.extend(FILE_RGB[i])
    flat.extend([0] * (768 - len(flat)))
    pim = Image.new("P", (16, 16))
    pim.putpalette(flat)
    return pim


# --- Image prep ------------------------------------------------------------

def fit_and_halve(im: Image.Image) -> Image.Image:
    """Scale width to fit the viewport, halve height for Screen-6 pixel
    aspect, round width to a multiple of 4, then clamp height at MAX_H."""
    # 1. Downscale (only) to fit content width.
    w, h = im.size
    if w > CONTENT_W_PX:
        new_h = max(1, round(h * CONTENT_W_PX / w))
        im = im.resize((CONTENT_W_PX, new_h), Image.LANCZOS)

    # 2. Round width down to a multiple of 4 (2 bpp packs 4 px/byte).
    w, h = im.size
    w4 = w - (w % 4)
    if w4 != w:
        im = im.crop((0, 0, w4, h))

    # 3. Halve height so Screen-6's narrow pixels render the image
    #    at roughly its natural aspect.
    w, h = im.size
    im = im.resize((w, max(1, h // 2)), Image.LANCZOS)

    # 4. Cap height so one image can't exceed the viewport.
    w, h = im.size
    if h > MAX_H:
        # Proportional shrink preserving width-multiple-of-4.
        scale = MAX_H / h
        new_w = max(4, int(round(w * scale)))
        new_w -= new_w % 4
        im = im.resize((new_w, MAX_H), Image.LANCZOS)
    return im


def quantise_to_palette(im: Image.Image) -> Image.Image:
    """Dither/snap the RGB image onto the 4 authoring palette slots."""
    pim = build_palette_image()
    return im.convert("RGB").quantize(palette=pim, dither=Image.Dither.FLOYDSTEINBERG)


# --- SC6 emitter -----------------------------------------------------------

def pack_sc6(im: Image.Image) -> bytearray:
    """Pack the palette-mapped image into a stream of 128-byte rows,
    padding the right-hand side of each row with PAD_BYTE so the output
    matches the browser's "always 128 bytes per row" SC6 convention."""
    w, h = im.size
    assert w % 4 == 0, f"width {w} not multiple of 4"
    pixels = im.load()
    raw = bytearray()
    for y in range(h):
        row = bytearray()
        for x in range(0, w, 4):
            b = 0
            for k in range(4):
                # Pillow's quantize already returned palette indices 0..3.
                idx = pixels[x + k, y]
                if idx > 3:
                    # Shouldn't happen with a 4-entry palette, but guard.
                    idx = nearest_palette(im.convert("RGB").getpixel((x + k, y)))
                b |= (idx & 3) << ((3 - k) * 2)
            row.append(b)
        # Right-pad to a full 128-byte Screen-6 row.
        row.extend([PAD_BYTE] * (SC6_ROW_BYTES - len(row)))
        raw.extend(row)
    return raw


def build_bload_header(data_len: int) -> bytes:
    """7-byte MSX BSAVE/BLOAD header: 0xFE, start, end, exec addresses.
    The browser's SC6 loader skips these 7 bytes unconditionally."""
    start = 0x0000
    end   = start + data_len - 1
    exec_ = 0x0000
    return bytes([
        0xFE,
        start & 0xFF, (start >> 8) & 0xFF,
        end   & 0xFF, (end   >> 8) & 0xFF,
        exec_ & 0xFF, (exec_ >> 8) & 0xFF,
    ])


# --- CLI -------------------------------------------------------------------

def default_output(src: str) -> str:
    base, _ = os.path.splitext(src)
    return base + ".sc6"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("source", help="Path to input .png")
    ap.add_argument("-o", "--out", default=None,
                    help="Output .sc6 path (default: <source>.sc6)")
    args = ap.parse_args()

    im = Image.open(args.source).convert("RGB")
    im = fit_and_halve(im)
    im = quantise_to_palette(im)
    raw = pack_sc6(im)

    out_path = args.out or default_output(args.source)
    with open(out_path, "wb") as f:
        f.write(build_bload_header(len(raw)))
        f.write(raw)

    w, h = im.size
    print(f"Wrote {out_path}  ({w}x{h} pixels, {len(raw)} pixel bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
