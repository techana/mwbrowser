#!/bin/bash
# Extract the live 2 KB CGTABL font the AX-370 BIOS hands MWBRO at
# ExtractFont time and save it as resources/fonts/ax370_cgtabl.bin.
# The font is the indexed-by-ISO-8859-6 Arabic character generator
# the AX-370's BIOS installs in Screen 6 mode -- our dumped copy
# means future builds can render Arabic without depending on the
# AX-370 machine ROM (useful now that day-to-day development uses
# Sony HB-F1XD, whose Japanese BIOS doesn't ship Arabic glyphs).
#
# How it works: MWBRO's ExtractFont runs at boot and copies the live
# CGTABL into FontBuf byte-by-byte via BIOS RDSLT. We let it finish,
# then peek FontBuf out via openMSX's debug interface.
#
# Pre-req: dist/mwbro.com already built (tools/build.sh) and the
# symbol file dist/mwbro.sym current so FontBuf's address is known.
set -euo pipefail
cd "$(dirname "$0")/.."

OPENMSX="/Applications/openMSX.app/Contents/MacOS/openmsx"
DISK="MSX-DOS/MSX-DOS v1.03.DSK"
OUT="resources/fonts/ax370_cgtabl.bin"

# SjASMPlus emits lines like `FontBuf: EQU 0x0000CDC3`.
FONTBUF_HEX=$(awk '$1=="FontBuf:" && $2=="EQU" { sub(/^0x/, "", $3); print $3; exit }' dist/mwbro.sym)
if [[ -z "${FONTBUF_HEX:-}" ]]; then
    echo "FontBuf symbol not found in dist/mwbro.sym -- run tools/build.sh first" >&2
    exit 2
fi
FONTBUF_DEC=$((16#$FONTBUF_HEX))
echo "FontBuf at 0x$FONTBUF_HEX ($FONTBUF_DEC)"

# Make sure the disk has the current .COM so ExtractFont runs from
# the version whose FontBuf address we just read.
mcopy -i "$DISK" -o dist/mwbro.com ::/MWBRO.COM

TCL=$(mktemp /tmp/dump_font_XXXX.tcl)
cat > "$TCL" <<EOF
after time 23 { type "MWBRO\r" }
# ExtractFont is the dominant boot cost (~1 BIOS RDSLT per byte *
# 2048 bytes). 45 s is comfortably past that on wall-clock time.
after time 45 {
    set f [open "$OUT" wb]
    for {set i 0} {\$i < 2048} {incr i} {
        puts -nonewline \$f [format "%c" [debug read memory [expr $FONTBUF_DEC + \$i]]]
    }
    close \$f
}
after time 50 { exit }
EOF

"$OPENMSX" -machine Al_Alamiah_AX370 -diska "$DISK" \
    -script tools/plug_mouse.tcl -script "$TCL" \
    >/tmp/openmsx_dumpfont.out 2>&1 &
PID=$!
( sleep 60 && kill "$PID" 2>/dev/null ) &
wait "$PID" 2>/dev/null || true
rm -f "$TCL"

if [[ ! -s "$OUT" ]]; then
    echo "Font dump failed -- see /tmp/openmsx_dumpfont.out" >&2
    exit 3
fi

size=$(stat -f%z "$OUT")
echo "Wrote $size B to $OUT (sha1: $(shasum "$OUT" | cut -d' ' -f1))"
