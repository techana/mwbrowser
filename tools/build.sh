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

# -I src tells sjasmplus where to find iso8859_6.inc / logo.inc; --sym
# writes dist/mwbro.sym so tools/*.tcl can resolve labels by name.
"$SJASMPLUS" -I src --sym=dist/mwbro.sym src/mwbrowser.asm
