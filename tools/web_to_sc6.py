#!/usr/bin/env python3
"""Fetch a live web page with headless Chromium and flatten it into a
set of Screen-6 .sc6 files plus a tiny .htm wrapper that MSX WBrowser
can load and page through.

Pipeline:
  1. Playwright renders the page at the MSX content-area width
     (492 px) -- native resolution, no oversample. Anti-aliased
     glyphs downsampled to 2 bpp are harder to read than font
     metrics chosen at the target size in the first place; letting
     Chromium lay text out at 492 wide gives each glyph its intended
     pixel footprint.
  2. A CSS overlay (see READABILITY_CSS) forces all text to pure
     black on white and strips page-level gradients / decorative
     backgrounds. Screen-6 has 4 grey slots; on a page that mixes
     light-grey text on dark-grey backgrounds the quantiser collapses
     both onto the same slot and the letters disappear. Forcing
     black-on-white keeps the character strokes cleanly separable
     from the background no matter what CSS the source site ships.
  3. The tall screenshot is sliced into page-sized chunks (183 rows
     each by default -- the browser's content-area height). Each
     chunk is packed as a Screen-6 .sc6 file with a 7-byte BLOAD
     header.
  4. An index .htm file stacks the chunks back to back with <img>
     tags so the browser can PageDown through the captured page:

         <BODY>
         <img src="PAGE1.SC6">
         <img src="PAGE2.SC6">
         ...
         </BODY>

     Consecutive <img> tags render without a gap because the image
     loader parks TextY right under the drawn pixels, so the visual
     effect is one long scrollable screenshot.

Why multipage and not one big SC6:
  The BLOAD header holds 16-bit addresses (64 KB max), and browsing
  an oversized single .sc6 would force the renderer to re-open and
  stream the whole file on every PageDown. Splitting at viewport
  height keeps each file small, lets the browser cache decode state
  naturally through the existing scroll pipeline, and matches how
  test10.htm / test6.htm already do multi-page documents.

Requirements:
    pip install playwright Pillow
    python3 -m playwright install chromium

Usage:
    tools/web_to_sc6.py https://www.bbcarabic.com
    tools/web_to_sc6.py https://example.com --out-dir samples/example --prefix EX
"""

from __future__ import annotations

import argparse
import asyncio
import os
import struct
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow required: pip install Pillow")

try:
    from playwright.async_api import async_playwright
except ImportError:
    sys.exit("Playwright required: pip install playwright && python3 -m playwright install chromium")


# Must match src/mwbrowser.asm constants.
MSX_VIEWPORT_W = 492
MSX_VIEWPORT_H = 183
SC6_ROW_BYTES  = 128
SC6_MAX_ROWS   = 240        # browser's SC6 row ceiling per file

# Authoring palette (slot 0 = black, slot 3 = white). Browser's
# ExtImgRemap permutes these onto the UI palette at load time.
FILE_RGB = {
    0: (0, 0, 0),
    1: (96, 96, 96),
    2: (192, 192, 192),
    3: (255, 255, 255),
}
PAD_BYTE = 0xFF  # four value-3 pixels = white padding


# CSS injected after the page loads. Only text colour is forced to
# pure black -- backgrounds, SVG logos, iframes and video posters
# stay visible, so the user can still recognise the page's branding
# and imagery after Screen-6 4-shade quantisation. Every rule is
# !important so it defeats inline styles that news sites use for
# headlines (light-grey on dark-grey would collapse onto a single
# palette slot and erase the letters).
READABILITY_CSS = """
  *, *::before, *::after {
      color: #000 !important;
      text-shadow: none !important;
  }
  /* Links remain recognisable via the underline even without colour. */
  a { color: #000 !important; text-decoration: underline !important; }
"""

# Grayscale filter -- identical effect to the Chrome "Grayscale Tool" /
# "Grayscale Screen" extensions, which also just set a
# `filter: grayscale(100%)` at the <html> level. Applied at the root so
# every nested element inherits the effect (including iframes / SVGs /
# raster images). Forces saturated logos onto the luminance axis so the
# 4-slot Screen-6 palette doesn't have to guess which shade of grey a
# pure red banner should round to.
GRAYSCALE_CSS = "html { filter: grayscale(100%) !important; }"


def nearest_palette_index(rgb):
    r, g, b = rgb
    best_idx, best_d = 0, None
    for idx, (pr, pg, pb) in FILE_RGB.items():
        d = (pr - r) ** 2 + (pg - g) ** 2 + (pb - b) ** 2
        if best_d is None or d < best_d:
            best_idx, best_d = idx, d
    return best_idx


async def _fetch_png(url: str, png_path: Path, grayscale: bool):
    """Returns (title, [(x, y, w, h, href), ...]) alongside writing the PNG.
    All link geometry is in CSS pixels of the fully-rendered page, which
    matches the pre-halve PNG coordinate space; the slicing step halves
    Y/H and translates into chunk-local coords for the image map."""
    async with async_playwright() as pw:
        browser = await pw.chromium.launch()
        # Native-resolution capture: Chromium lays out the page at
        # exactly the MSX content-area width, so a 14-px CSS headline
        # becomes 14 real pixels in the screenshot instead of 7 from
        # a halved 2x render.
        context = await browser.new_context(
            viewport={"width": MSX_VIEWPORT_W, "height": MSX_VIEWPORT_H},
            device_scale_factor=1,
        )
        page = await context.new_page()
        await page.goto(url, wait_until="networkidle", timeout=45000)
        await page.add_style_tag(content=READABILITY_CSS)
        if grayscale:
            await page.add_style_tag(content=GRAYSCALE_CSS)
        # Give web fonts a moment to restyle after the overlay lands
        # (fonts can trigger a relayout that moves text around).
        await page.wait_for_timeout(400)
        await page.screenshot(path=str(png_path), full_page=True)

        # Collect every visible <a href> with its page-absolute bounding
        # box. We resolve href to its absolute form (Playwright's own
        # `a.href` already does that), then strip to URL path so the
        # MSX browser's loader -- which sees the wrapper HTM, not the
        # live page -- has something it can feed to the FCB builder.
        # Zero-sized / offscreen links are dropped; they'd collapse to
        # empty <area> rects the MSX can never hit.
        title = await page.title()
        links = await page.evaluate("""
() => {
    const out = [];
    for (const a of document.querySelectorAll('a[href]')) {
        const r = a.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) continue;
        // Use page-absolute coords (add scrollY because getBoundingClientRect
        // is viewport-relative, and full_page=True captures the whole doc
        // starting at y=0).
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
        return title, links


def _resize_to_msx(im: Image.Image) -> Image.Image:
    """Enforce 492 wide, then halve height to compensate for Screen 6's
    ~1:2 pixel aspect. Use NEAREST for the vertical halve so we simply
    drop every other row -- LANCZOS averages two adjacent source rows
    into a mid-grey that the 4-slot palette then snaps into a dithered
    speckle pattern, blurring text. Keeping only even rows preserves
    the sharpest possible glyph edges at the cost of a tiny bit of
    vertical aliasing on horizontal lines."""
    im = im.convert("RGB")
    if im.size[0] != MSX_VIEWPORT_W:
        new_h = max(1, round(im.size[1] * MSX_VIEWPORT_W / im.size[0]))
        im = im.resize((MSX_VIEWPORT_W, new_h), Image.LANCZOS)
    return im.resize((MSX_VIEWPORT_W, max(1, im.size[1] // 2)), Image.NEAREST)


def _pack_sc6_chunk(im: Image.Image) -> bytes:
    """Pack an image of <=SC6_MAX_ROWS rows to 2 bpp SC6 bytes, each
    row right-padded to 128 B with white."""
    pixels = im.load()
    w, h = im.size
    img_bytes = (w + 3) // 4
    raw = bytearray()
    for y in range(h):
        row = bytearray()
        for bx in range(img_bytes):
            packed = 0
            for k in range(4):
                x = bx * 4 + k
                if x < w:
                    idx = nearest_palette_index(pixels[x, y])
                else:
                    idx = 3
                packed |= (idx & 3) << ((3 - k) * 2)
            row.append(packed)
        if len(row) < SC6_ROW_BYTES:
            row.extend([PAD_BYTE] * (SC6_ROW_BYTES - len(row)))
        raw.extend(row)
    return bytes(raw)


def _bload_header(data_len: int) -> bytes:
    start = 0x0000
    end   = start + data_len - 1
    return struct.pack("<BHHH", 0xFE, start, end & 0xFFFF, 0x0000)


def _write_sc6(path: Path, im_chunk: Image.Image) -> int:
    raw = _pack_sc6_chunk(im_chunk)
    path.write_bytes(_bload_header(len(raw)) + raw)
    return len(raw)


def _wrapper_html(chunks: list[dict], title: str) -> str:
    """Build the index HTM. Each chunk entry is
        {'name': 'PG01A.SC6', 'map_id': 'M01A' | None, 'areas': [...], ...}
    Areas are already clipped + translated to chunk-local 2bpp coords. The
    browser is expected to parse <map>/<area> and attach the map to its
    <img usemap="#..."> so clicking inside the image resolves to a href.
    Chunks without any link hits get a plain <img> (no usemap)."""
    lines = [f"<HTML><HEAD><TITLE>{title}</TITLE></HEAD>", "<BODY>"]
    for ch in chunks:
        if ch["map_id"]:
            lines.append(f'<map name="{ch["map_id"]}">')
            for (x1, y1, x2, y2, href) in ch["areas"]:
                lines.append(
                    f'<area shape="rect" coords="{x1},{y1},{x2},{y2}" '
                    f'href="{href}">'
                )
            lines.append("</map>")
            lines.append(
                f'<img src="{ch["name"]}" usemap="#{ch["map_id"]}" '
                f'alt="{ch["name"]}">'
            )
        else:
            lines.append(f'<img src="{ch["name"]}" alt="{ch["name"]}">')
    lines.append("</BODY></HTML>")
    return "\n".join(lines) + "\n"


def _clip_links_to_chunk(links, chunk_top_msx, chunk_h):
    """Clip each link rect to the chunk's Y span and translate into
    chunk-local MSX pixel coords. Link coords are in CSS space of the
    pre-halve PNG; dividing Y/H by 2 puts them in MSX-post-halve space.

    Returns a list of (x1, y1, x2, y2, href). Rejects links whose
    clipped height or width would be zero."""
    out = []
    for L in links:
        # CSS -> MSX post-halve.
        lx1 = max(0, min(MSX_VIEWPORT_W - 1, L["x"]))
        lx2 = max(0, min(MSX_VIEWPORT_W,     L["x"] + L["w"]))
        ly1 = L["y"] // 2
        ly2 = (L["y"] + L["h"] + 1) // 2
        # Clip to chunk.
        top = chunk_top_msx
        bot = chunk_top_msx + chunk_h
        if ly2 <= top or ly1 >= bot: continue
        ly1 = max(ly1, top) - top
        ly2 = min(ly2, bot) - top
        if ly2 - ly1 < 2 or lx2 - lx1 < 2: continue
        out.append((lx1, ly1, lx2, ly2, L["href"]))
    return out


async def _run(args) -> int:
    png_tmp = Path(args.png or "/tmp/web_to_sc6.png")
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Fetching  {args.url}  (grayscale={not args.no_grayscale})")
    title, links = await _fetch_png(args.url, png_tmp, grayscale=not args.no_grayscale)
    print(f"Captured  title={title!r}  links={len(links)}")

    im = _resize_to_msx(Image.open(png_tmp))
    total_w, total_h = im.size
    rows_per_page = min(args.rows_per_page, SC6_MAX_ROWS)
    num_pages = (total_h + rows_per_page - 1) // rows_per_page
    if args.max_pages and num_pages > args.max_pages:
        print(f"note: page renders to {num_pages} chunks; capping at {args.max_pages}")
        num_pages = args.max_pages

    # Keep PREFIX + two-digit page index <= 8 chars so MSX-DOS 1's
    # FCB parser doesn't truncate PREFIX10 back onto PREFIX01.
    if len(args.prefix) > 6:
        sys.exit(f"prefix '{args.prefix}' too long: max 6 chars (8.3 FCB limit with 2-digit numbering)")

    print(f"Slicing   {total_w}x{total_h} into {num_pages} x {rows_per_page}-row chunks")
    chunks_meta: list[dict] = []

    def _chunk_name(i: int) -> str:
        # One full-viewport chunk per logical page -- PG01.SC6 is the
        # first screenful, PG02.SC6 the second, etc. One file per
        # PageDown hop.
        return f"{args.prefix}{i+1:02d}.SC6"

    for i in range(num_pages):
        top = i * rows_per_page
        bot = min(total_h, top + rows_per_page)
        chunk = im.crop((0, top, total_w, bot))
        name  = _chunk_name(i)
        path  = out_dir / name
        size  = _write_sc6(path, chunk)
        if args.debug_png:
            chunk.save(out_dir / (name[:-4] + ".PNG"))

        areas = _clip_links_to_chunk(links, chunk_top_msx=top, chunk_h=bot - top)
        map_id = None
        if areas:
            # Keep map names 8.3-safe: 'M' + the chunk's 2-digit page
            # index (e.g. M01).
            map_id = "M" + name[len(args.prefix):-4]
        chunks_meta.append({
            "name":   name,
            "map_id": map_id,
            "areas":  areas,
        })
        print(f"  {name}  ({chunk.size[1]} rows, {size} bytes, {len(areas)} areas)")

    # MSX browser reads ISO-8859-6 for Arabic; UTF-8 bytes would go
    # through the Latin-1 glyph table and display as mojibake. Encode
    # the whole wrapper as ISO-8859-6 and replace anything outside
    # that codepage with '?', which is at least better than leaking
    # UTF-8 continuation bytes into the title bar.
    index_name = f"{args.prefix}.HTM"
    html_text = _wrapper_html(chunks_meta, title or args.url)
    (out_dir / index_name).write_bytes(html_text.encode("iso-8859-6", "replace"))
    print(f"Wrote     {out_dir / index_name}")

    if not args.keep_png:
        try:
            png_tmp.unlink()
        except FileNotFoundError:
            pass
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("url", help="URL to fetch (http/https)")
    ap.add_argument("--out-dir", default="samples",
                    help="Where to write the .sc6 + .htm (default: samples)")
    ap.add_argument("--prefix", default="PG",
                    help="Base filename -- pages become PREFIX01.SC6, "
                         "PREFIX02.SC6, ... and the index is PREFIX.HTM "
                         "(default: PG). MSX-DOS 1 enforces 8.3 filenames; "
                         "with two-digit page numbers the prefix must be "
                         "<= 6 characters.")
    ap.add_argument("--rows-per-page", type=int, default=MSX_VIEWPORT_H,
                    help=f"Rows per .sc6 chunk (default: {MSX_VIEWPORT_H}"
                         f" = one full viewport per image, so each chunk"
                         f" corresponds to one PageDown of scrolling)")
    ap.add_argument("--max-pages", type=int, default=0,
                    help="Cap the number of half-viewport chunks (default 0 = no"
                         " cap; the full page is sliced, bounded only by disk"
                         " space on the MSX-DOS floppy). Two chunks make one"
                         " logical viewport, so N chunks = ~N/2 PageDowns.")
    ap.add_argument("--png", default=None,
                    help="Intermediate PNG path (default: /tmp/web_to_sc6.png)")
    ap.add_argument("--keep-png", action="store_true",
                    help="Keep the intermediate PNG instead of deleting it.")
    ap.add_argument("--debug-png", action="store_true",
                    help="Also write a {PREFIX}{N}.PNG next to each .sc6"
                         " chunk so a human can eyeball what the encoder"
                         " saw before 4-shade quantisation.")
    ap.add_argument("--no-grayscale", action="store_true",
                    help="Skip the grayscale CSS filter. Off by default"
                         " because forcing the page onto the luminance"
                         " axis matches how the Chrome Grayscale Tool /"
                         " Grayscale Screen extensions behave, and keeps"
                         " saturated logos from snapping to the wrong"
                         " Screen-6 palette slot.")
    args = ap.parse_args()
    if args.max_pages == 0:
        args.max_pages = None
    return asyncio.run(_run(args))


if __name__ == "__main__":
    sys.exit(main())
