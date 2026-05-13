#!/usr/bin/env python3
"""samples/headtest.html: h1..h6 in Latin AND Arabic, with normal
paragraph in between for size comparison. ASCII passes through;
Arabic block (U+0600..06FF) re-encodes to ISO-8859-6."""
import pathlib

DST = pathlib.Path("samples/headtest.html")

HTML = (
    "<html>\n"
    "<head><title>Headings</title></head>\n"
    "<body>\n"

    "<h1>H1 Latin</h1>\n"
    "<h1 dir=\"rtl\">عنوان أول</h1>\n"
    "<h2>H2 Latin</h2>\n"
    "<h2 dir=\"rtl\">عنوان ثاني</h2>\n"
    "<h3>H3 Latin</h3>\n"
    "<h3 dir=\"rtl\">عنوان ثالث</h3>\n"
    "<h4>H4 Latin</h4>\n"
    "<h4 dir=\"rtl\">عنوان رابع</h4>\n"
    "<h5>H5 Latin</h5>\n"
    "<h5 dir=\"rtl\">عنوان خامس</h5>\n"
    "<h6>H6 Latin</h6>\n"
    "<h6 dir=\"rtl\">عنوان سادس</h6>\n"
    "<p>Normal paragraph: hello مرحبا world.</p>\n"

    "</body>\n"
    "</html>\n"
)


def enc(s: str) -> bytes:
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


DST.write_bytes(enc(HTML))
print(f"Wrote {DST} ({DST.stat().st_size} bytes)")
