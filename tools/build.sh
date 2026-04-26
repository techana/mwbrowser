#!/bin/bash
# Assemble src/mwbrowser.asm into dist/mwbro.com via SjASMPlus.
#
# We migrated from asMSX to SjASMPlus because the former's trail
# (a pinned binary, no upstream commits) was getting in the way as we
# started pushing binary size past the AX-370 TPA ceiling. At the code
# size the migration happened, both assemblers produced bit-identical
# output -- the switch is transparent; SjASMPlus is the open-source,
# actively-maintained Z80 assembler with the widest MSX-homebrew use.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist

SJASMPLUS=${SJASMPLUS:-./tools/sjasmplus/sjasmplus}
if [[ ! -x "$SJASMPLUS" ]]; then
    if command -v sjasmplus >/dev/null 2>&1; then
        SJASMPLUS=sjasmplus
    else
        echo "sjasmplus not found at $SJASMPLUS and not on PATH" >&2
        echo "Build it from https://github.com/z00m128/sjasmplus and" >&2
        echo "drop the binary at tools/sjasmplus/sjasmplus." >&2
        exit 2
    fi
fi

# Optional baud-rate override. SERIAL_DIVISOR is a build-time symbol
# the SerialInit code reads; SERIAL_BAUD is a friendlier env var that
# we translate to the matching divisor. If neither is set we use the
# in-source default (currently divisor 1 = 115200 baud).
DEFINES=()
if [[ -n "${SERIAL_DIVISOR:-}" ]]; then
    DEFINES+=(-DSERIAL_DIVISOR="$SERIAL_DIVISOR")
elif [[ -n "${SERIAL_BAUD:-}" ]]; then
    case "$SERIAL_BAUD" in
        1200)   DEFINES+=(-DSERIAL_DIVISOR=96) ;;
        2400)   DEFINES+=(-DSERIAL_DIVISOR=48) ;;
        4800)   DEFINES+=(-DSERIAL_DIVISOR=24) ;;
        9600)   DEFINES+=(-DSERIAL_DIVISOR=12) ;;
        19200)  DEFINES+=(-DSERIAL_DIVISOR=6)  ;;
        38400)  DEFINES+=(-DSERIAL_DIVISOR=3)  ;;
        57600)  DEFINES+=(-DSERIAL_DIVISOR=2)  ;;
        115200) DEFINES+=(-DSERIAL_DIVISOR=1)  ;;
        *) echo "build.sh: unsupported SERIAL_BAUD=$SERIAL_BAUD" >&2; exit 2 ;;
    esac
fi

# -I src tells sjasmplus where to find iso8859_6.inc / logo.inc; --sym
# writes dist/mwbro.sym so tools/*.tcl can resolve labels by name.
# The `+` expansion guards against `set -u` tripping on an empty array.
"$SJASMPLUS" -I src --sym=dist/mwbro.sym ${DEFINES[@]+"${DEFINES[@]}"} src/mwbrowser.asm
