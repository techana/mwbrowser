#!/bin/bash
# Assemble src/serial_poc.asm and drop the .COM onto the boot disk so
# the user can type `SERPOC` from MSX-DOS.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
./tools/asmsx/asmsx -o dist/serpoc src/serial_poc.asm
DISK="MSX-DOS/MSX-DOS v1.03.DSK"
if [[ -f "$DISK" ]]; then
    chmod u+w "$DISK" 2>/dev/null || true
    mcopy -i "$DISK" -o dist/serpoc.com ::/SERPOC.COM
    echo "SERPOC.COM injected to $DISK"
fi
