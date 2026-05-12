#!/usr/bin/env python3
"""Build samples/listtest.htm. ASCII parts stay verbatim; Arabic runs are
authored UTF-8 here and re-encoded to ISO-8859-6 on write so the parser
sees the bytes its IsoJoin tables expect."""
import pathlib

DST = pathlib.Path("samples/listtest.htm")

HTML = (
    "<html>\n"
    "<head><title>List Test</title></head>\n"
    "<body>\n"

    "<h2>LTR Numbered List</h2>\n"
    "<ol>\n"
    "<li>First item with some text content.</li>\n"
    "<li>Second item with a bit more.</li>\n"
    "<li>Third item.</li>\n"
    "<li>Fourth item.</li>\n"
    "<li>Fifth and final item -- check alignment.</li>\n"
    "</ol>\n"
    "\n"

    "<h2 dir=\"rtl\">قائمة مرقّمة عربية</h2>\n"
    "<ol dir=\"rtl\">\n"
    "<li>البند الأول من القائمة.</li>\n"
    "<li>البند الثاني وهو أطول قليلا.</li>\n"
    "<li>البند الثالث.</li>\n"
    "<li>البند الرابع.</li>\n"
    "<li>البند الخامس والأخير -- تحقق من المحاذاة.</li>\n"
    "</ol>\n"
    "\n"

    "<h2>LTR Bulleted List</h2>\n"
    "<ul>\n"
    "<li>First bullet item.</li>\n"
    "<li>Second bullet item.</li>\n"
    "<li>Third bullet item.</li>\n"
    "<li>Fourth bullet item.</li>\n"
    "<li>Fifth and final bullet item.</li>\n"
    "</ul>\n"

    "</body>\n"
    "</html>\n"
)


def encode_mixed(s: str) -> bytes:
    """Encode each char: ASCII stays as-is, Arabic re-codes to ISO-8859-6,
    everything else (like the smart-quote in dir=\"rtl\") falls back to
    Latin-1 (= byte-equivalent for code points 0-255)."""
    out = bytearray()
    for ch in s:
        cp = ord(ch)
        if cp < 0x80:
            out.append(cp)
        elif 0x0600 <= cp <= 0x06FF:
            # Arabic block -> ISO-8859-6
            out.extend(ch.encode("iso-8859-6"))
        else:
            out.append(cp & 0xFF)
    return bytes(out)


DST.write_bytes(encode_mixed(HTML))
print(f"Wrote {DST} ({DST.stat().st_size} bytes)")
