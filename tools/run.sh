#!/bin/bash
# Launch openMSX on AX370 with MSX-DOS 1.03 disk + autorun.tcl.
# Screenshots land in /tmp/vwr-*.png. Flags:
#   -i     interactive mode (no autorun script, no timeout)
#   -t N   override emulator lifetime in wall seconds (default 38)
set -euo pipefail
cd "$(dirname "$0")/.."

OPENMSX="/Applications/openMSX.app/Contents/MacOS/openmsx"
MACHINE="Al_Alamiah_AX370"
DISK="MSX-DOS/MSX-DOS v1.03.DSK"

INTERACTIVE=0
WALL_T=38
while getopts "it:" opt; do
    case $opt in
        i) INTERACTIVE=1 ;;
        t) WALL_T="$OPTARG" ;;
        *) echo "usage: $0 [-i] [-t seconds]"; exit 2 ;;
    esac
done

ARGS=(-machine "$MACHINE" -diska "$DISK" -script tools/plug_mouse.tcl)
if [[ $INTERACTIVE -eq 0 ]]; then
    rm -f /tmp/vwr-*.png 2>/dev/null || true
    ARGS+=(-script tools/autorun.tcl)
fi

if [[ $INTERACTIVE -eq 1 ]]; then
    exec "$OPENMSX" "${ARGS[@]}"
fi

"$OPENMSX" "${ARGS[@]}" >/tmp/openmsx.out 2>&1 &
PID=$!
echo "openMSX PID=$PID  wall-timeout=${WALL_T}s"
( sleep "$WALL_T" && kill "$PID" 2>/dev/null ) &
WAITER=$!
wait "$PID" 2>/dev/null || true
kill "$WAITER" 2>/dev/null || true
echo "--- openMSX log ---"
cat /tmp/openmsx.out
echo "--- screenshots ---"
ls /tmp/vwr-*.png 2>/dev/null || echo "(none)"
