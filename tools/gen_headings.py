#!/usr/bin/env python3
"""Build samples/headings.html. Mirrors gen_listtest.py's pattern:
ASCII passes through verbatim, chars in the Arabic block (U+0600..
U+06FF) re-encode to ISO-8859-6 so the parser's IsoJoin tables see
the byte form they expect."""
import pathlib

DST = pathlib.Path("samples/headings.html")

HTML = (
    "<html>\n"
    "<head><title>Headings</title></head>\n"
    "<body>\n"

    "<h1>H1 Latin Heading</h1>\n"
    "<h1 dir=\"rtl\">العنوان الأول</h1>\n"

    "<h2>H2 Latin Heading</h2>\n"
    "<h2 dir=\"rtl\">العنوان الثاني</h2>\n"

    "<p>Normal paragraph for size comparison: hello مرحبا world.</p>\n"

    "<h2>H2 mixed: Welcome مرحبا</h2>\n"
    "<h2 dir=\"rtl\">عنوان مختلط: hello العالم</h2>\n"

    "</body>\n"
    "</html>\n"
)


def encode_mixed(s: str) -> bytes:
    out = bytearray()
    for ch in s:
        cp = ord(ch)
        if cp < 0x80:
            out.append(cp)
        elif 0x0600 <= cp <= 0x06FF:
            out.extend(ch.encode("iso-8859-6"))
        else:
            out.append(cp & 0xFF)
    return bytes(out)


DST.write_bytes(encode_mixed(HTML))
print(f"Wrote {DST} ({DST.stat().st_size} bytes)")
