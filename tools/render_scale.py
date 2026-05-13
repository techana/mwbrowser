#!/usr/bin/env python3
"""Read the dumped AX-370 8x8 font, render 'm' and 'م' at three
scales using the SAME pixel-double algorithm the current code uses,
and stack them into a clean reference PNG. No screenshot artefacts
-- exact MSX pixel grid scaled 6x nearest-neighbor for visibility."""
import pathlib
from PIL import Image, ImageDraw, ImageFont

FONT = pathlib.Path("resources/fonts/ax370_cgtabl.bin").read_bytes()
DST = pathlib.Path("/tmp/scale_actual.png")

ZOOM = 8           # output px per MSX px
ROW_GAP = 16       # pixel gap between size rows in the output
INK = (0, 0, 0)
PAPER = (255, 255, 255)
LABEL = (60, 60, 60)


def glyph_rows(code: int) -> list[int]:
    """8 bytes from the BIOS CGTABL at index code."""
    base = code * 8
    return list(FONT[base : base + 8])


def render_scale1(rows: list[int]) -> list[list[int]]:
    """Each row's 8 mono pixels as a list of 8 0/1 ints. 8x8 output."""
    return [[(b >> (7 - i)) & 1 for i in range(8)] for b in rows]


def render_h2(rows: list[int]) -> list[list[int]]:
    """ScaleY=2 ScaleX=1: each row duplicated vertically. 8x16."""
    out = []
    for row in render_scale1(rows):
        out.append(list(row))
        out.append(list(row))
    return out


def render_h1(rows: list[int]) -> list[list[int]]:
    """ScaleY=2 ScaleX=2: each row AND each column duplicated. 16x16."""
    base = render_scale1(rows)
    out = []
    for row in base:
        doubled = []
        for px in row:
            doubled.append(px)
            doubled.append(px)
        out.append(list(doubled))
        out.append(list(doubled))
    return out


def draw_grid(canvas: Image.Image, ox: int, oy: int, grid: list[list[int]]):
    """Paint a 2D 0/1 grid at (ox, oy) with ZOOM px per cell."""
    px = canvas.load()
    h = len(grid)
    w = len(grid[0]) if h else 0
    for y in range(h):
        for x in range(w):
            colour = INK if grid[y][x] else PAPER
            for dy in range(ZOOM):
                for dx in range(ZOOM):
                    px[ox + x * ZOOM + dx, oy + y * ZOOM + dy] = colour


M_CODE = ord("m")              # 0x6D
MIM_CODE = 0xE5                # ISO-8859-6 Arabic م

m_rows = glyph_rows(M_CODE)
mim_rows = glyph_rows(MIM_CODE)

# Print the actual bytes so we can see the source pattern.
print("m bytes:   ", " ".join(f"{b:08b}" for b in m_rows))
print("م bytes:   ", " ".join(f"{b:08b}" for b in mim_rows))

# Build canvas: 3 rows of glyphs at varying widths, with labels.
# Widest column is H1 (16 MSX px). Each row holds m then a gap then م.
LABEL_W = 90
GLYPH_W_NORMAL = 8 * ZOOM
GLYPH_W_DOUBLE = 16 * ZOOM
GAP = ZOOM * 3
total_w = LABEL_W + GLYPH_W_DOUBLE + GAP + GLYPH_W_DOUBLE + ZOOM * 4
row_h = ZOOM * 16 + ROW_GAP

canvas_h = 3 * row_h + ZOOM
canvas = Image.new("RGB", (total_w, canvas_h), PAPER)
draw = ImageDraw.Draw(canvas)

for ri, (label, render_fn) in enumerate([
    ("normal", render_scale1),
    ("H2",     render_h2),
    ("H1",     render_h1),
]):
    oy = ri * row_h + ROW_GAP
    draw.text((ZOOM, oy + ZOOM * 4), label, fill=LABEL)
    m_grid = render_fn(m_rows)
    mim_grid = render_fn(mim_rows)
    ox = LABEL_W
    # Pad m_grid vertically if it's shorter than 16-row.
    while len(m_grid) < 16:
        m_grid.append([0] * len(m_grid[0]))
    while len(mim_grid) < 16:
        mim_grid.append([0] * len(mim_grid[0]))
    draw_grid(canvas, ox, oy, m_grid)
    ox += len(m_grid[0]) * ZOOM + GAP
    draw_grid(canvas, ox, oy, mim_grid)

canvas.save(DST, "PNG")
print(f"Wrote {DST} ({DST.stat().st_size} B, {canvas.size[0]}x{canvas.size[1]} px)")
