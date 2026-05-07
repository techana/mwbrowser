#!/usr/bin/env python3
"""Generate the two scroll-benchmark HTML pages used by
optimization_round_1.

Both pages are deterministic (seeded) so re-running the script after a
renderer change produces byte-identical HTML, keeping benchmarks
comparable across builds.

Output:
  samples/BENCHTX.HTM   ~22 KB, text + tables + lists, no images
  samples/BENCHIM.HTM   ~10 KB markup + 8-12 <img src="PGnn.PCX">

Both are kept under FILE_BUF_SIZE = 24576 bytes so TryFetchMore never
fires; the benchmark only measures the renderer / scroll path.
"""

from __future__ import annotations

import os
import random
import sys

# ── Word/sentence pool ─────────────────────────────────────────────
# Mix of ASCII and ISO-8859-6-safe Arabic, so the Arabic shaper /
# RTL machinery is exercised on the text-heavy page too.
ASCII_WORDS = (
    "MSX browser scroll page render parser layout cache HMMM "
    "VRAM byte chunk pixel font glyph table column row image "
    "cartridge VDP serial bridge latency wire palette dither "
    "PCX shape join Arabic ligature line break paragraph header "
    "viewport content area pagination hover link history form"
).split()

# Ten short Arabic phrases (Arabic block, will encode cleanly to
# ISO-8859-6 since the renderer uses that wire charset).
ARABIC_PHRASES = [
    "متصفح صغير", "صفحة الاختبار", "نص طويل", "السطر الأول",
    "الصفحة الثانية", "الجدول الكبير", "قائمة من العناصر",
    "صورة من الذاكرة", "أداء التمرير", "ذاكرة الفيديو",
]

random.seed(42)


def sentence(min_words=6, max_words=14):
    n = random.randint(min_words, max_words)
    words = random.choices(ASCII_WORDS, k=n)
    if random.random() < 0.18:
        words.insert(random.randint(0, n - 1),
                     random.choice(ARABIC_PHRASES))
    return " ".join(words).capitalize() + "."


def paragraph(min_sent=3, max_sent=6):
    return " ".join(sentence() for _ in range(
        random.randint(min_sent, max_sent)))


# ── Page builders ───────────────────────────────────────────────────


def build_text_page() -> str:
    """~22 KB of mixed-tag content. Stresses parser + scroll without
    pulling the image pipeline into the measurement."""
    parts = [
        "<html><head><title>Bench: text</title></head><body>",
        "<h1>Scroll-bench / text only</h1>",
        "<p><b>Purpose:</b> exercise the renderer's prefix-walk on "
        "scroll without any image fetches. Hold <b>M</b> (PageDown) "
        "or the down-arrow to drive the bench harness.</p>",
        "<hr>",
    ]

    # Mix of headings + paragraphs. Section count tuned so the
    # encoded output lands ~12 KB -- well under the 21 KB
    # FILE_BUF_SIZE cap (post-FileBuf-overlap-fix), and small enough
    # that the post-fix REAL parser walk (HTML tag dispatch + Arabic
    # shaping, vs the corrupted-state PlainTextMode fast-path that
    # was inflating the original baseline) completes in <60 s of
    # emulated time. Earlier 23 KB version was tuned for the
    # corrupted-state fast-path; it became unrunnably slow once the
    # parser started doing real work.
    for i in range(13):
        level = random.choice([2, 2, 3, 3, 4, 4, 4])
        parts.append(f"<h{level}>Section {i+1}: {sentence(2, 5)}</h{level}>")
        # Two or three paragraphs per heading.
        for _ in range(random.randint(2, 3)):
            parts.append(f"<p>{paragraph()}</p>")
        # Every 4th section, throw in a list.
        if i % 4 == 3:
            parts.append("<ul>")
            for _ in range(random.randint(3, 6)):
                parts.append(f"  <li>{sentence(4, 9)}</li>")
            parts.append("</ul>")
        # Every 6th section, a table.
        if i % 6 == 5:
            parts.append('<table border="1" cellpadding="2">')
            parts.append("<tr><th>Field</th><th>Value</th><th>Note</th></tr>")
            for _ in range(random.randint(3, 5)):
                parts.append(
                    f"<tr><td>{random.choice(ASCII_WORDS)}</td>"
                    f"<td>{random.randint(0, 999)}</td>"
                    f"<td>{sentence(2, 6)}</td></tr>"
                )
            parts.append("</table>")

    parts.append("<hr><p><i>End of bench page.</i></p></body></html>")
    return "\r\n".join(parts) + "\r\n"


def build_image_page() -> str:
    """Fewer paragraphs, 10 inline <img src='PGnn.PCX'> references.
    Stresses the image pipeline + scrolling-with-images. Image files
    must already exist under samples/ -- we don't generate them."""
    parts = [
        "<html><head><title>Bench: images</title></head><body>",
        "<h1>Scroll-bench / images</h1>",
        "<p>Each section ends with an inline image so the scroll "
        "path crosses image rectangles -- exercises both the "
        "parser's image-skip logic on scrolled passes and the "
        "VDP-side paint when the image is in view.</p>",
        "<hr>",
    ]

    img_pool = [f"PG{n:02d}.PCX" for n in range(1, 13)]   # 12 images
    for i, img in enumerate(img_pool):
        parts.append(f"<h2>Section {i+1}: {sentence(2, 4)}</h2>")
        parts.append(f"<p>{paragraph(2, 4)}</p>")
        parts.append(f'<center><img src="{img}" alt="{img}"></center>')
        parts.append(f"<p>{paragraph(1, 2)}</p>")

    parts.append("<hr><p><i>End of image-heavy bench page.</i></p>"
                 "</body></html>")
    return "\r\n".join(parts) + "\r\n"


# ── Main ────────────────────────────────────────────────────────────


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    samples = os.path.join(os.path.dirname(here), "samples")
    os.makedirs(samples, exist_ok=True)

    text = build_text_page().encode("iso-8859-6", errors="replace")
    imgs = build_image_page().encode("iso-8859-6", errors="replace")

    cap = 24 * 1024
    if len(text) >= cap:
        # Trim from the end until under the cap, preserving </body></html>.
        # (Cheap; if this fires, lower the section count above.)
        print("warn: BENCHTX over cap, truncating", file=sys.stderr)
        text = text[: cap - 32] + b"</body></html>\r\n"
    if len(imgs) >= cap:
        print("warn: BENCHIM over cap, truncating", file=sys.stderr)
        imgs = imgs[: cap - 32] + b"</body></html>\r\n"

    with open(os.path.join(samples, "BENCHTX.HTM"), "wb") as f:
        f.write(text)
    with open(os.path.join(samples, "BENCHIM.HTM"), "wb") as f:
        f.write(imgs)

    print(f"BENCHTX.HTM   {len(text):>6} bytes")
    print(f"BENCHIM.HTM   {len(imgs):>6} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
