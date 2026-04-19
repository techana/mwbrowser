#!/usr/bin/env python3
"""Build samples/test5.htm as raw ISO-8859-6 bytes.

Source is authored as UTF-8 in this script (editor-friendly) and the
Arabic runs are encoded() to ISO-8859-6 on write. ASCII text and HTML
markup pass through unchanged.
"""
import pathlib

DST     = pathlib.Path("samples/test5.htm")
DST_TXT = pathlib.Path("samples/txt.txt")
DST6    = pathlib.Path("samples/test6.htm")
DST7    = pathlib.Path("samples/test7.htm")

TXT = (
    "Plain text file -- no HTML parsing.\n"
    "Latin: hello world.\n"
    "Arabic: مرحبا بالعالم\n"
    "Lam-alef fuse: كتاب لا شيء\n"
    "Lam-alef fuse 2: لأن هذا لإختبار\n"
    "Digits: ١٢٣ ، ؟\n"
)

HTML = (
    "<HTML>\n"
    "<HEAD><TITLE>Step 5A</TITLE></HEAD>\n"
    "<BODY>\n"
    "<H1>Arabic ISO-8859-6</H1>\n"
    "<P>Latin line: hello world.</P>\n"
    "<P>Pure Arabic: مرحبا بالعالم</P>\n"
    "<P>Mixed: hello مرحبا MSX</P>\n"
    "<P>Digits and punct: ١٢٣ ، ؟ test.</P>\n"
    "<P>Ligature: كتاب لا شيء</P>\n"
    "</BODY>\n"
    "</HTML>\n"
)

# test6.htm: a plausible Arabic news article -- headline, dateline, a lead
# paragraph, two subheads with body text, and a closing note. Every block
# carries dir="rtl" so the renderer exercises paragraph-level BiDi and
# right-aligned default flow end-to-end.
HTML6 = (
    "<HTML>\n"
    "<HEAD><TITLE>خبر</TITLE></HEAD>\n"
    "<BODY>\n"

    "<H1 dir=\"rtl\" align=\"center\">"
    "معرض MSX يجذب عشاق الحاسوب الكلاسيكي"
    "</H1>\n"

    "<H3 dir=\"rtl\">دبي ، ١٧ أبريل ٢٠٢٦</H3>\n"

    "<P dir=\"rtl\">"
    "افتتح أمس في دبي معرض متخصص يضم مجموعة من أجهزة MSX "
    "الكلاسيكية وعروضا حية لبرامج الرسم والألعاب القديمة ، "
    "وشهد المعرض إقبالا من الهواة والباحثين في تاريخ الحاسوب."
    "</P>\n"

    "<H2 dir=\"rtl\">برامج وعروض حية</H2>\n"

    "<P dir=\"rtl\">"
    "قدم المنظمون عرضا لمحرر نصوص يدعم اللغة العربية ، كما "
    "عرضوا متصفحا صغيرا قادرا على عرض صفحات HTML على شاشة "
    "MSX ذات الدقة ٥١٢ في ٢١٢ بكسل."
    "</P>\n"

    "<P dir=\"rtl\">"
    "وأكد المشاركون أن العمل على عتاد محدود يساعد الطلاب "
    "على فهم أساسيات البرمجة فهما عمليا ، ويشجعهم على "
    "الإبداع ضمن قيود صارمة."
    "</P>\n"

    "<H2 dir=\"rtl\">ندوة ختامية</H2>\n"

    "<P dir=\"rtl\">"
    "اختتم المعرض بندوة حول مستقبل المنصات القديمة ودورها "
    "في تعليم الحاسوب ، وشارك فيها عدد من الأكاديميين "
    "والمطورين من المنطقة العربية."
    "</P>\n"

    "</BODY>\n"
    "</HTML>\n"
)

# test7.htm: the Jeddah variant. One <HTML dir="rtl"> propagates RTL to
# every block, no per-tag dir attrs needed. Expanded body, plus inline
# <font color> runs (gray dateline, dimgray byline) to exercise mid-line
# fg colour with the line buffer.
HTML7 = (
    "<HTML dir=\"rtl\">\n"
    "<HEAD><TITLE>خبر</TITLE></HEAD>\n"
    "<BODY>\n"

    "<H1 align=\"center\">"
    "معرض MSX يجذب عشاق الحاسوب الكلاسيكي"
    "</H1>\n"

    "<H3>"
    "<font color=\"gray\">جدة ، ١٧ أبريل ٢٠٢٦</font>"
    "</H3>\n"

    "<P>"
    "افتتح أمس في جدة معرض متخصص يضم مجموعة من أجهزة MSX "
    "الكلاسيكية وعروضا حية لبرامج الرسم والألعاب القديمة ، "
    "وشهد المعرض إقبالا كبيرا من الهواة والباحثين في تاريخ "
    "الحاسوب الشخصي."
    "</P>\n"

    "<P>"
    "ويأتي المعرض ضمن سلسلة فعاليات تنظمها جمعية محلية "
    "مهتمة بالحفاظ على إرث الحواسيب القديمة وتعريف الجيل "
    "الجديد بها ، بمشاركة متطوعين من عدة مدن."
    "</P>\n"

    "<H2>برامج وعروض حية</H2>\n"

    "<P>"
    "قدم المنظمون عرضا لمحرر نصوص يدعم اللغة العربية ، كما "
    "عرضوا متصفحا صغيرا قادرا على عرض صفحات HTML على شاشة "
    "MSX ذات الدقة ٥١٢ في ٢١٢ بكسل."
    "</P>\n"

    "<P>"
    "وأكد المشاركون أن العمل على عتاد محدود يساعد الطلاب "
    "على فهم أساسيات البرمجة فهما عمليا ، ويشجعهم على "
    "الإبداع ضمن قيود صارمة."
    "</P>\n"

    "<H2>ورشة عمل للهواة</H2>\n"

    "<P>"
    "نظمت إلى جانب المعرض ورشة عمل قصيرة تعلم المشاركين "
    "كيفية كتابة برامج صغيرة بلغة BASIC وتجربتها مباشرة "
    "على الأجهزة المعروضة ، وحصل المشاركون على نسخة مطبوعة "
    "من شيفرات البرامج للاحتفاظ بها."
    "</P>\n"

    "<H2>ندوة ختامية</H2>\n"

    "<P>"
    "اختتم المعرض بندوة حول مستقبل المنصات القديمة ودورها "
    "في تعليم الحاسوب ، وشارك فيها عدد من الأكاديميين "
    "والمطورين من المنطقة العربية."
    "</P>\n"

    "<P>"
    "<font color=\"dimgray\">تقرير : فريق التحرير</font>"
    "</P>\n"

    "</BODY>\n"
    "</HTML>\n"
)

# Al-Alamiah extensions that Python's iso-8859-6 codec doesn't cover.
# Arabic-Indic digits and lam-alef ligatures live in positions the
# standard leaves unassigned, but the MSX font + CSV define them.
EXTRA = {
    # Arabic-Indic digits 0..9 -> 0xB0..0xB9
    **{chr(0x0660 + i): bytes([0xB0 + i]) for i in range(10)},
    # Lam-alef ligatures -> 0xF3..0xF6
    "ﻵ": bytes([0xF3]),   # U+FEF5 lam-alef-madda
    "ﻷ": bytes([0xF4]),   # U+FEF7 lam-alef-hamza-above
    "ﻹ": bytes([0xF5]),   # U+FEF9 lam-alef-hamza-below
    "ﻻ": bytes([0xF6]),   # U+FEFB lam-alef
}

def to_iso(text: str) -> bytes:
    out = bytearray()
    for ch in text:
        if ch in EXTRA:
            out += EXTRA[ch]
        else:
            out += ch.encode("iso-8859-6")
    return bytes(out)

def main():
    data = to_iso(HTML)
    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_bytes(data)
    print(f"wrote {DST}  ({len(data)} bytes, ISO-8859-6)")

    txt = to_iso(TXT)
    DST_TXT.write_bytes(txt)
    print(f"wrote {DST_TXT}  ({len(txt)} bytes, ISO-8859-6)")

    data6 = to_iso(HTML6)
    DST6.write_bytes(data6)
    print(f"wrote {DST6}  ({len(data6)} bytes, ISO-8859-6)")

    data7 = to_iso(HTML7)
    DST7.write_bytes(data7)
    print(f"wrote {DST7}  ({len(data7)} bytes, ISO-8859-6)")

if __name__ == "__main__":
    main()
