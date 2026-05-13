#!/usr/bin/env python3
"""Crop /tmp/vwr-scale-p1-0001.png down to the m / م region at the
three sizes, scale up 4x nearest-neighbor, stack into a single
reference image for the user to annotate."""
import pathlib
from PIL import Image

SRC = pathlib.Path("/tmp/vwr-scale-p1-0001.png")
DST = pathlib.Path("/tmp/scale_reference.png")

img = Image.open(SRC).convert("RGB")
W, H = img.size  # 640x480

# The openMSX screenshot upscales 512x192 -> 640x480 (1.25x horizontal,
# 2.5x vertical, framebuffer-based). The content area in MSX coords
# starts at y=29, so y=29 in MSX maps to y=29*2.5 = ~73 in screenshot.
# Each MSX text row is 8 px = 20 px in screenshot.
#
# The three target rows are:
#   normal : MSX y ~30..38 (one body line) → screenshot 75..95
#   H2     : MSX y ~46..62 (after gap + 16-px H2)
#   H1     : MSX y ~78..94 (after H2 + gap + 16-px H1)
#
# To avoid hand-tuning we just crop a wide horizontal band that covers
# all three rows; the user can annotate within it.

# Crop: left ~24px (skips left content margin), right ~280, top ~70,
# bottom ~210. That captures the three "X: m م" lines.
crop = img.crop((20, 70, 320, 220))

# Upscale 4x nearest-neighbor so each rendered pixel is visible as
# a 4x4 block in the reference.
zoom = crop.resize((crop.width * 4, crop.height * 4), Image.NEAREST)
zoom.save(DST, "PNG")
print(f"Wrote {DST} ({DST.stat().st_size} bytes, {zoom.size[0]}x{zoom.size[1]} px)")
