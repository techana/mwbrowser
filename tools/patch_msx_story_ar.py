#!/usr/bin/env python3
"""Replace Section 7 ("MSX in the Arab World") of MSX_Story.htm with
an Arabic + RTL version, then re-emit the whole file using the
ISO-8859-6 byte mapping that gen_headtest.py and gen_listtest.py
use for the AX-370 BIOS character set.

Patches both the main-repo bridge root and the worktree copy so
the file is in sync whichever checkout the bridge serves from."""
from __future__ import annotations
import pathlib
import re
import sys

# --- Arabic section (Unicode source) ----------------------------------
SECTION_7_AR = """\
<h2 dir="rtl">7. MSX في العالم العربي</h2>

<center><img src="SAKHR.SC6"></center>

<p dir="rtl">خارج اليابان، لم تتبنَّ أي منطقة معيار MSX كما
تبنّاه العالم العربي. قامت الشركة الكويتية العالمية، تحت
العلامة التجارية <b>صخر</b>، بترخيص مواصفة MSX عام 1984
وبَنَت حولها منظومة حاسوبية متكاملة.</p>

<p dir="rtl">شُحنت أجهزة صخر <b>AX-150</b> و <b>AX-170</b>
و <b>AX-330</b> و <b>AX-350</b> و <b>AX-370</b> ببيوس مخصص
يحوي مجموعة محارف ثنائية اللغة: رموز ASCII القياسية في
المواقع 0x20 إلى 0x7E، وأبجدية عربية كاملة وفق ISO-8859-6
فوق 0xA0 تتضمن الأشكال الموضعية الأربعة لكل حرف، إضافة إلى
الأرقام الهندية في المواقع 0xB0 إلى 0xB9. مفتاح في لوحة
المفاتيح يبدّل بين الإدخال اللاتيني والعربي فوراً.</p>

<p dir="rtl">خلال أواخر الثمانينات، أصبحت سلسلة AX الحاسوب
التعليمي المعتمد في المدارس عبر المملكة العربية السعودية
والكويت والإمارات العربية المتحدة ومصر. كتب جيل كامل من
المبرمجين العرب أول سطر بيسك على جهاز صخر MSX، ولا يزال
كثير منهم يحتفظ بواحد منها حتى اليوم.</p>

<p dir="rtl">جلب جهاز AX-370 على وجه الخصوص ميزات MSX2
(شريحة V9938، و128 كيلوبايت من ذاكرة الفيديو، ونظام
MSX-DOS) إلى السوق العربية. وهو العتاد المستهدف لعارض HTML
الذي تقرأ به هذا المقال: متصفح صغير أصيل يقرأ النصوص
العربية بترميز ISO-8859-6 مباشرة من مولّد المحارف في
البيوس، ويعكس التخطيط للكتل المكتوبة من اليمين إلى اليسار،
ويدعم الصور المدمجة بصيغة SC6 مثل شعار صخر أعلاه.</p>

"""

# --- Encoding helper (same scheme as tools/gen_headtest.py) -----------
def enc(s: str) -> bytes:
    out = bytearray()
    for ch in s:
        cp = ord(ch)
        if cp < 0x80:
            out.append(cp)
        elif 0x0600 <= cp <= 0x06FF:
            # ISO-8859-6 maps the Arabic block at U+060C..U+0652
            # onto bytes 0xAC..0xF2; Python's codec handles the
            # subset we use here (letters, comma, parens markers).
            try:
                out.extend(ch.encode("iso-8859-6"))
            except UnicodeEncodeError:
                # Diacritics (shadda, kasra, fatha, sukun) that
                # the strict codec rejects -- fall back to the
                # well-known MSX/ISO 8859-6 byte positions.
                fallback = {
                    0x064B: 0xEB,  # fathatan
                    0x064C: 0xEC,  # dammatan
                    0x064D: 0xED,  # kasratan
                    0x064E: 0xEE,  # fatha
                    0x064F: 0xEF,  # damma
                    0x0650: 0xF0,  # kasra
                    0x0651: 0xF1,  # shadda
                    0x0652: 0xF2,  # sukun
                }
                if cp in fallback:
                    out.append(fallback[cp])
                else:
                    raise
        else:
            out.append(cp & 0xFF)
    return bytes(out)


# --- Patch the file in place ------------------------------------------
TARGETS = [
    pathlib.Path("/Users/mans/Workarea/msx html viewer/tools/root/MSX_Story.htm"),
    pathlib.Path("/Users/mans/Workarea/msx html viewer/.claude/worktrees/"
                 "exciting-bouman-5900e1/tools/root/MSX_Story.htm"),
]

PATTERN = re.compile(
    r"<h2>7\. MSX in the Arab World</h2>.*?(?=<h2>8\. )",
    re.DOTALL,
)


def patch(path: pathlib.Path) -> None:
    if not path.exists():
        print(f"skip {path} (not present)", file=sys.stderr)
        return
    src = path.read_bytes().decode("utf-8", errors="replace")
    if not PATTERN.search(src):
        print(f"warn {path}: section-7 marker not found, "
              "leaving untouched", file=sys.stderr)
        return
    new_src = PATTERN.sub(SECTION_7_AR, src, count=1)
    path.write_bytes(enc(new_src))
    print(f"Wrote {path} ({path.stat().st_size} bytes)")


for p in TARGETS:
    patch(p)
