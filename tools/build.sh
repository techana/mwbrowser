#!/bin/bash
# Assemble src/mwbrowser.asm into dist/mwbro.com via asMSX.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist
./tools/asmsx/asmsx -o dist/mwbro src/mwbrowser.asm
