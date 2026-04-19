#!/usr/bin/env python3
"""Rebuild samples/test9.htm: Arabic counterpart of test8 with the
centered SAKHR logo and a table of MSX generations. UTF-8 in source,
ISO-8859-6 on disk."""

import pathlib

parts = []

def add(s, arabic=False):
    parts.append(s.encode("iso-8859-6") if arabic else s.encode("ascii"))

# --- Document header ---
add('<HTML dir="rtl">\n<HEAD><TITLE>')
add("قصة حواسيب MSX", arabic=True)
add('</TITLE></HEAD>\n<BODY>\n')

# H1 title + H3 subtitle (matches test8's pair)
add('<H1 align="center">')
add("قصة حواسيب MSX", arabic=True)
add('</H1>\n')

add('<H3><FONT COLOR="gray">')
add("تاريخ موجز لمعيار ثماني البِتّات مشهور", arabic=True)
add('</FONT></H3>\n\n')

# First paragraph
add('<P>')
add("في منتصف ", arabic=True)
add('<B>')
add("الثمانينات", arabic=True)
add('</B>')
add(" اتفق عدد من الشركات اليابانية على معيار موحد للحواسيب المنزلية، وأطلق عليه اسم MSX. كان الهدف من المعيار أن يعمل البرنامج المكتوب لجهاز من ", arabic=True)
add('<I>')
add("شركة معينة", arabic=True)
add('</I>')
add(" على أجهزة الشركات الأخرى بلا أي تعديل.", arabic=True)
add('</P>\n\n')

# Centered logo
add('<center><img src="SAKHR.SC6" alt="')
add("شعار صخر", arabic=True)
add('"></center>\n\n')

# Second paragraph
add('<P>')
add("أول حواسيب MSX وصلت عام 1983 من Sony و Panasonic و Sanyo و Toshiba و Yamaha و Philips وغيرها. كلها جاءت بمعالج Z80A بتردد 3.58 ميجاهرتز وذاكرة 16 أو 32 كيلوبايت، ومفسر Microsoft BASIC مضمن في الروم.", arabic=True)
add('</P>\n\n')

# H2: generations table
add('<H2>')
add("أجيال MSX", arabic=True)
add('</H2>\n\n')

add('<P>')
add("مرت منصة MSX بأربعة أجيال رسمية. يلخص الجدول التالي مواعيد كل جيل وأبرز مزاياه:", arabic=True)
add('</P>\n\n')

add('<TABLE>\n')
add('<TR><TH>')
add("الجيل", arabic=True)
add('</TH><TH>')
add("السنة", arabic=True)
add('</TH><TH>')
add("الميزة", arabic=True)
add('</TH></TR>\n')
add('<TR><TD>MSX</TD><TD>1983</TD><TD>')
add("المعيار الأصلي", arabic=True)
add('</TD></TR>\n')
add('<TR><TD>MSX2</TD><TD>1985</TD><TD>')
add("ألوان وذاكرة أكثر", arabic=True)
add('</TD></TR>\n')
add('<TR><TD>MSX2+</TD><TD>1988</TD><TD>')
add("تحسين ياباني", arabic=True)
add('</TD></TR>\n')
add('<TR><TD>TurboR</TD><TD>1990</TD><TD>')
add("معالج R800", arabic=True)
add('</TD></TR>\n')
add('</TABLE>\n\n')

# H2: MSX2
add('<H2>')
add("MSX2 وما بعدها", arabic=True)
add('</H2>\n\n')

add('<P>')
add("في عام 1985 انتقل المعيار إلى ", arabic=True)
add('<B>MSX2</B>')
add(" مع شريحة عرض ", arabic=True)
add('<I>V9938</I>')
add(" من Yamaha: دقة 512 في 212 بـ 16 لوناً أو 256 في 212 بـ 256 لوناً، ذاكرة رئيسية 64 كيلوبايت، وذاكرة فيديو 128 كيلوبايت، وساعة زمن حقيقي، ومحرك أقراص قياسي.", arabic=True)
add('</P>\n\n')

add('<P>')
add("ألعاب تلك الفترة ضغطت الجهاز بقوة. Konami و Compile و Hudson أنتجت عناوين تسابق ألعاب الصالات، مثل Metal Gear و Parodius و Nemesis و Aleste.", arabic=True)
add('</P>\n\n')

add('<P>')
add("MSX2+ ظهر عام 1988 مع أنماط عرض إضافية وتمرير طبيعي وشريحة صوت YM2413 مدمجة. ظل توزيعه يابانياً لكن المجموعة ما زالت مرغوبة لدى الهواة لجودة صوتها وانسيابية حركتها.", arabic=True)
add('</P>\n\n')

# H2: Turbo R
add('<H2>MSX Turbo R</H2>\n\n')

add('<P>')
add("الجيل الأخير ", arabic=True)
add('<B>MSX Turbo R</B>')
add(" ظهر عام 1990 من Panasonic وحدها. أضاف معالج R800 بجانب Z80A، فأعطى أداءً صحيحاً يقارب أربعة أضعاف السرعة. النموذج الأعلى جاء بميجابايت كامل من الذاكرة ومدخل MIDI ومعالجة صوت PCM.", arabic=True)
add('</P>\n\n')

add('<P>')
add("كان سوق بداية التسعينات قد انتقل إلى متوافقات MS-DOS وجهاز Amiga. صنّعت Panasonic طرازين فقط قبل إنهاء الإنتاج خلال سنتين.", arabic=True)
add('</P>\n\n')

# H2: Legacy
add('<H2>')
add("الإرث", arabic=True)
add('</H2>\n\n')

add('<P>')
add("على الرغم من إنهاء الإنتاج رسمياً، لم يختف MSX أبداً. لا يزال هناك مجتمع نشط من المطورين والهواة في ", arabic=True)
add('<B>')
add("اليابان", arabic=True)
add('</B>')
add(" و ", arabic=True)
add('<B>')
add("هولندا", arabic=True)
add('</B>')
add(" و ", arabic=True)
add('<B>')
add("إسبانيا", arabic=True)
add('</B>')
add(" و ", arabic=True)
add('<B>')
add("البرازيل", arabic=True)
add('</B>')
add(" و ", arabic=True)
add('<B>')
add("الخليج العربي", arabic=True)
add('</B>')
add(" يكتبون برامج جديدة ويصنعون عتاداً حديثاً متوافقاً مع الأجهزة الأصلية.", arabic=True)
add('</P>\n\n')

add('<P>')
add("تقام لقاءات سنوية في Tilburg و Barcelona و طوكيو. المحاكيات متكاملة، وكل بيوس ROM محفوظ، والمشهد مستمر.", arabic=True)
add('</P>\n\n')

# Closing note, gray (matches test8's End of article)
add('<P><FONT COLOR="dimgray">')
add("نهاية المقال - شكراً للقراءة.", arabic=True)
add('</FONT></P>\n\n')

add('</BODY>\n</HTML>\n')

out = b"".join(parts)
pathlib.Path("samples/test9.htm").write_bytes(out)
print(f"wrote {len(out)} bytes")
