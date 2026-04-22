#!/bin/bash
# Launch openMSX with MSX-DOS 1.03 disk + autorun.tcl.
# Screenshots land in /tmp/vwr-*.png. Flags:
#   -i     interactive mode (no autorun script, no timeout)
#   -t N   override emulator lifetime in wall seconds (default 38)
#   -a     use the Al Alamiah AX-370 (for Arabic-font regression runs).
#          Default is Sony HB-F1XD, which has a clean TPA and accepts
#          .COM sizes well past the ~15565 B cap AX-370's slot layout
#          inflicts on MSX-DOS 1. Feature work runs under HB-F1XD; swap
#          to AX-370 only for Arabic shaping + ISO-8859-6 tests.
set -euo pipefail
cd "$(dirname "$0")/.."

OPENMSX="/Applications/openMSX.app/Contents/MacOS/openmsx"
MACHINE="Sony_HB-F1XD"
DISK="MSX-DOS/MSX-DOS v1.03.DSK"

INTERACTIVE=0
WALL_T=38
while getopts "iat:" opt; do
    case $opt in
        i) INTERACTIVE=1 ;;
        a) MACHINE="Al_Alamiah_AX370" ;;
        t) WALL_T="$OPTARG" ;;
        *) echo "usage: $0 [-i] [-a] [-t seconds]"; exit 2 ;;
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
