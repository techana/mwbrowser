#!/bin/bash
# Assemble src/serial_poc.asm and drop the .COM onto the boot disk so
# the user can type `SERPOC` from MSX-DOS. Uses SjASMPlus, matching
# tools/build.sh since the asMSX -> SjASMPlus migration.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist

SJASMPLUS=${SJASMPLUS:-./tools/sjasmplus/sjasmplus}
if [[ ! -x "$SJASMPLUS" ]]; then
    if command -v sjasmplus >/dev/null 2>&1; then
        SJASMPLUS=sjasmplus
    else
        echo "sjasmplus not found at $SJASMPLUS and not on PATH" >&2
        exit 2
    fi
fi

"$SJASMPLUS" -I src src/serial_poc.asm
DISK="MSX-DOS/MSX-DOS v1.03.DSK"
if [[ -f "$DISK" ]]; then
    chmod u+w "$DISK" 2>/dev/null || true
    mcopy -i "$DISK" -o dist/serpoc.com ::/SERPOC.COM
    echo "SERPOC.COM injected to $DISK"
fi
