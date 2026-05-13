#!/usr/bin/env python3
"""Build samples/scaletest.html: 'm' + 'م' at normal / H2 / H1 sizes.
ASCII passes through; the single Arabic codepoint U+0645 re-encodes
to ISO-8859-6 (0xE5)."""
import pathlib

DST = pathlib.Path("samples/scaletest.html")

HTML = (
    "<html>\n"
    "<head><title>Scale</title></head>\n"
    "<body>\n"
    "<p>normal: m م</p>\n"
    "<h2>H2: m م</h2>\n"
    "<h1>H1: m م</h1>\n"
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
