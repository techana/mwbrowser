#!/usr/bin/env python3
"""Convert a small PNG/BMP image (already sized for Screen 6) to an
.sc6 file that MSX WBrowser can load via <img src="foo.sc6">.

No resizing and no dithering: every source pixel is snapped to the
nearest of the 4 authoring palette slots. The input image is expected
to already account for Screen 6's ~0.55:1 pixel aspect (i.e. supply a
pre-halved image if you want natural proportions) and to contain only
a handful of distinct colours -- the tests ship SAKHR-LOGO.bmp and
MSX-LOGO.bmp which are 3-colour (black / mid-grey / white).

Authoring palette -- the conventional "slot 0 = black, slot 3 = white"
layout that the browser's SC6 remap expects:

    file value 0 -> black
    file value 1 -> dgray
    file value 2 -> lgray
    file value 3 -> white

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


# Authoring palette -- slot index matches the byte value that will sit in
# the .sc6 file. See the module docstring for the mapping the browser
# applies at load time.
FILE_RGB = {
    0: (0, 0, 0),         # black
    1: (96, 96, 96),      # dgray
    2: (192, 192, 192),   # lgray
    3: (255, 255, 255),   # white
}

# Full Screen-6 row in bytes (512 px / 4 px per byte).
SC6_ROW_BYTES = 128
# Four value-3 pixels == white background; used to pad short rows.
PAD_BYTE = 0xFF


def nearest_palette(rgb):
    r, g, b = rgb
    best_idx, best_d = 0, None
    for idx, (pr, pg, pb) in FILE_RGB.items():
        d = (pr - r) ** 2 + (pg - g) ** 2 + (pb - b) ** 2
        if best_d is None or d < best_d:
            best_idx, best_d = idx, d
    return best_idx


def pack_sc6(im, center=False):
    """Pack the RGB image row-major into 2 bpp bytes. Width that isn't a
    multiple of 4 gets right-padded with white so no source pixels are
    lost, and each row is padded out to 128 bytes to match the
    'always-full-row' SC6 layout the browser's loader expects.

    center=False (default): pad on the right only. The image sits at
    x=0 of the Screen-6 row; wrap the <img> in <center> and you'll see
    it hug the left edge because the padded bytes extend to the right
    scrollbar and the browser's SC6 loader can't shift a 128-byte row
    inside the 123-byte content area.

    center=True: split the padding evenly between left and right. Once
    rendered, the image content itself sits at the middle of the
    content area -- the simplest way to match an HTML <center> wrap
    without a width-aware SC6 header."""
    im = im.convert("RGB")
    w, h = im.size
    pixels = im.load()
    # Round width up to a multiple of 4. The extra 0..3 pixels are set
    # to the white palette slot so the logo keeps its full width.
    w4 = (w + 3) & ~3
    bytes_per_img_row = w4 // 4

    pad_total = max(0, SC6_ROW_BYTES - bytes_per_img_row)
    if center:
        pad_left  = pad_total // 2
        pad_right = pad_total - pad_left
    else:
        pad_left, pad_right = 0, pad_total

    raw = bytearray()
    for y in range(h):
        row = bytearray([PAD_BYTE] * pad_left)
        for bx in range(bytes_per_img_row):
            b = 0
            for k in range(4):
                x = bx * 4 + k
                if x < w:
                    idx = nearest_palette(pixels[x, y])
                else:
                    idx = 3
                b |= (idx & 3) << ((3 - k) * 2)
            row.append(b)
        row.extend([PAD_BYTE] * pad_right)
        raw.extend(row)
    return raw


def build_bload_header(data_len):
    start = 0x0000
    end   = start + data_len - 1
    exec_ = 0x0000
    return bytes([
        0xFE,
        start & 0xFF, (start >> 8) & 0xFF,
        end   & 0xFF, (end   >> 8) & 0xFF,
        exec_ & 0xFF, (exec_ >> 8) & 0xFF,
    ])


def default_output(src):
    base, _ = os.path.splitext(src)
    return base + ".sc6"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("source", help="Path to input PNG or BMP")
    ap.add_argument("-o", "--out", default=None,
                    help="Output .sc6 path (default: <source>.sc6)")
    ap.add_argument("-c", "--center", action="store_true",
                    help="Center the image inside the 128-byte SC6 row"
                         " (splits the white padding between both sides"
                         " so an <img> wrapped in <center> lands in the"
                         " middle of the viewport).")
    args = ap.parse_args()

    im = Image.open(args.source)
    raw = pack_sc6(im, center=args.center)

    out_path = args.out or default_output(args.source)
    with open(out_path, "wb") as f:
        f.write(build_bload_header(len(raw)))
        f.write(raw)

    w, h = im.size
    print(f"Wrote {out_path}  ({w}x{h} pixels, {len(raw)} pixel bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
