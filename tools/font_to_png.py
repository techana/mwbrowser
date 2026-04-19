#!/usr/bin/env python3
"""Render the 2 KB MSX font dump (256 glyphs x 8 rows, 1 bpp) as a PNG.

Layout: 16 glyphs per row, 16 rows. Each glyph 8x8, scaled 2x with a 1px
grid separator so it's legible when zoomed out.
"""
import struct, sys, zlib, pathlib

SRC = pathlib.Path("/tmp/msx_font.bin")
DST = pathlib.Path("dist/font_dump.png")

def png(w, h, pixels):
    """pixels: bytes, len = w*h, grayscale 0..255."""
    raw = b"".join(b"\x00" + pixels[y*w:(y+1)*w] for y in range(h))
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)
    return (sig + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))

def main():
    data = SRC.read_bytes()
    assert len(data) == 2048, f"expected 2048 bytes, got {len(data)}"

    SCALE = 2
    GAP = 1                       # grid line between glyphs
    CELL = 8 * SCALE + GAP        # one glyph cell incl. right/bottom gap
    COLS, ROWS = 16, 16
    W = GAP + COLS * CELL
    H = GAP + ROWS * CELL
    BG = 40                        # gray grid
    FG_ON = 255                    # glyph set pixels
    FG_OFF = 0                     # glyph clear pixels

    buf = bytearray([BG]) * (W * H)

    for idx in range(256):
        gx = idx % COLS
        gy = idx // COLS
        x0 = GAP + gx * CELL
        y0 = GAP + gy * CELL
        glyph = data[idx*8:(idx+1)*8]
        for row in range(8):
            bits = glyph[row]
            for col in range(8):
                on = (bits >> (7 - col)) & 1
                color = FG_ON if on else FG_OFF
                for dy in range(SCALE):
                    for dx in range(SCALE):
                        px = x0 + col*SCALE + dx
                        py = y0 + row*SCALE + dy
                        buf[py*W + px] = color

    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_bytes(png(W, H, bytes(buf)))
    print(f"wrote {DST}  ({W}x{H})")

if __name__ == "__main__":
    main()
