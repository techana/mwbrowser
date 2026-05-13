#!/usr/bin/env python3
"""Generate a stylized "MSX home computer" line-art image and pack
it as MSXCOMP.SC6 for tools/root/. Four-colour palette
(black/dgray/lgray/white) so png_to_sc6.py snaps cleanly.

Layout: a wedge-shaped home computer body (lgray top, dgray sides)
with a black 3-row keyboard, function-key strip, and a tiny power
LED. Pre-halved horizontally to compensate for Screen 6's narrow
pixel aspect; the result reads as a chunky little 1980s home
micro on the AX-370."""
from __future__ import annotations
import pathlib
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("Need Pillow: pip install Pillow")

# Source size. Width pre-halved because Screen-6 pixels are ~0.55:1
# (narrow); the on-screen image will then have natural proportions.
W, H = 200, 96
BLACK = (0, 0, 0)
DGRAY = (96, 96, 96)
LGRAY = (192, 192, 192)
WHITE = (255, 255, 255)

im = Image.new("RGB", (W, H), WHITE)
d = ImageDraw.Draw(im)

# --- Computer body outline ---------------------------------------------
# Top plate (lighter), front keyboard plate (darker grey).
# Coordinates expressed in source pixels; aspect compensated below.
body_x0, body_x1 = 10, W - 10
body_y_top    = 18           # top of the slanted plate
body_y_mid    = 38           # where the keyboard plate begins
body_y_bottom = H - 10       # bottom of the case

# Slanted upper plate (perspective hint).
top_pts = [
    (body_x0 + 12, body_y_top),     # back-left
    (body_x1 - 12, body_y_top),     # back-right
    (body_x1,      body_y_mid),     # front-right
    (body_x0,      body_y_mid),     # front-left
]
d.polygon(top_pts, fill=LGRAY, outline=BLACK)

# Front keyboard deck.
d.rectangle([body_x0, body_y_mid, body_x1, body_y_bottom],
            fill=DGRAY, outline=BLACK)

# --- Function-key strip (top plate) ------------------------------------
fkey_y = body_y_top + 6
for i in range(5):
    fx = body_x0 + 22 + i * 14
    d.rectangle([fx, fkey_y, fx + 10, fkey_y + 6],
                fill=BLACK, outline=BLACK)

# Brand badge on the upper plate (just a small rectangle).
badge_x = body_x1 - 32
badge_y = body_y_top + 4
d.rectangle([badge_x, badge_y, badge_x + 18, badge_y + 8],
            fill=WHITE, outline=BLACK)

# --- Main key rows -----------------------------------------------------
key_y0 = body_y_mid + 4
key_rows = 3
key_cols = 13
key_w = 11
key_h = 11
key_gap = 2
total_kbd_w = key_cols * key_w + (key_cols - 1) * key_gap
key_x0 = (W - total_kbd_w) // 2

for r in range(key_rows):
    # Slight row indent each row down (typewriter stagger).
    indent = r * 3
    for c in range(key_cols):
        kx = key_x0 + indent + c * (key_w + key_gap)
        ky = key_y0 + r * (key_h + 2)
        if kx + key_w > body_x1 - 2:
            break
        d.rectangle([kx, ky, kx + key_w, ky + key_h],
                    fill=LGRAY, outline=BLACK)

# Space bar.
sb_y = key_y0 + key_rows * (key_h + 2)
sb_x0 = key_x0 + 18
sb_x1 = key_x0 + total_kbd_w - 18
if sb_y + 6 < body_y_bottom - 2:
    d.rectangle([sb_x0, sb_y, sb_x1, sb_y + 6],
                fill=LGRAY, outline=BLACK)

# Power LED dot on the right side of the front deck.
led_x = body_x1 - 14
led_y = body_y_mid + 5
d.ellipse([led_x, led_y, led_x + 4, led_y + 4],
          fill=BLACK, outline=BLACK)

# --- Save and convert to SC6 ------------------------------------------
out_png = pathlib.Path("/tmp/msx_computer.png")
im.save(out_png)
print(f"Wrote {out_png}  ({W}x{H})")

repo_root = pathlib.Path(__file__).resolve().parent.parent
sc6_path = repo_root / "tools" / "root" / "MSXCOMP.SC6"
subprocess.check_call([
    sys.executable,
    str(repo_root / "tools" / "png_to_sc6.py"),
    str(out_png),
    "-o", str(sc6_path),
    "--center",
])
print(f"Wrote {sc6_path}")
