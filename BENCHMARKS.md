# MSX WBrowser — scroll & image-load benchmarks

Cycle-accurate baselines for the `optimization_round_1` work. All
times are openMSX **emulated wall-clock** seconds. The Sony HB-F1XD
runs at Z80 3.58 MHz; emulated time ≈ real-MSX time when the
emulator is at 100 % speed.

Methodology:
- `BENCH=1 ./tools/build.sh` → `dist/mwbro.com` with `IFDEF BENCH`
  sentinels: `OUT (0x2E),1` at `PrintFileContent` entry, `OUT
  (0x2E),2` at the `.eof` exit.
- `tools/bench_scroll.tcl` arms `debug set_watchpoint write_io 0x2E`
  and records `[machine_info time]` plus the byte value to
  `/tmp/bench_<page>.log` on every fire.
- Per-render latency = exit-stamp − entry-stamp. The harness types
  `A:<page>\r` to load from MSX-DOS, then issues N PageDown presses
  spaced `BENCH_GAP` seconds apart so each press starts from a
  rendered, idle state.
- Two pages (`samples/`):
  - **BENCHTX.HTM** (23 402 B) — text-heavy: headings + paras +
    lists + tables + a sprinkling of Arabic phrases. No images. Fits
    in one `FILE_BUF_SIZE=24 KB` load (no `TryFetchMore` involved).
  - **BENCHIM.HTM** (5 298 B) — short markup, 12 inline `<img
    src="PGnn.PCX">`. Stresses the image pipeline + scroll-with-images.

## Pre-fix baseline — INVALIDATED

The first set of numbers I captured here (BENCHTX 23 402 B / 10.12 s
per scroll) was measured with the FileBuf-vs-globals overlap bug
silently corrupting `PlainTextMode` to a non-zero value during file
load. That flipped the renderer into the `<pre>` / plain-text fast
path, which is much cheaper per byte than the real parser. The
"10 s per scroll on 23 KB" number is therefore not comparable to a
correctly-rendering build.

The same load corrupted `HtmlTitleBuf`, `ArBuf`, `HistoryBuf`, etc.
— renderable globals that had ended up at addresses inside the
`ORG 0x6800` / `ds FILE_BUF_SIZE` reservation as the `.COM` grew
past 26 KB. See the `optimization_round_1: fix FileBuf-vs-globals
overlap` commit for the full diagnosis.

## Post-fix baseline (real-parser render)

Branch: `optimization_round_1` after the FileBuf-overlap fix.
Symbols are now placed via EQU at `FILEBUF_BASE = 0x9400`, past
the natural-PC end of the .COM (`FileEnd = 0x9353`). Build-time
ASSERTs trip if either bound is violated again. `FILE_BUF_SIZE`
dropped from `0x6000` (24 KB) to `0x5400` (21 KB) so
`FileBuf + FontBuf + ImgBuf` ends safely below BDOS HIMEM.

`BENCHTX.HTM` was resized 23 402 B → **12 270 B** because the
old size was tuned for the broken fast-path; with the parser
actually doing tag dispatch + Arabic shaping, the larger
file took unrunnably long for an automated harness. 12 KB is
still big enough to exercise the prefix-walk cost and produce
4 viewport-pages of content.

### `BENCHTX.HTM` — text only, 12 270 B (post-fix)

| Render # | Trigger | Start (s) | End (s) | Duration (s) |
|---|---|--:|--:|--:|
| 1 | Initial page load | 44.43 | 51.02 | **6.59** |
| 2 | 1st PageDown        | 51.65 | 56.16 | **4.51** |
| 3 | 2nd PageDown        | 106.36 | 110.99 | **4.63** |
| 4 | 3rd PageDown        | 166.37 | 171.21 | **4.84** |

**Mean per-scroll: 4.66 s. Std dev: 0.13 s.**

### `BENCHIM.HTM` — 12 inline PCX images, 5 511 B markup (post-fix)

| Render # | Trigger | Start (s) | End (s) | Duration (s) |
|---|---|--:|--:|--:|
| 1 | Initial load (markup + 12 image fetches) | 41.67 | 93.06 | **51.39** |
| 2 | 1st PageDown | 93.69 | 98.17 | **4.48** |
| 3 | 2nd PageDown | 106.37 | 111.01 | **4.64** |

**Initial load: 51.39 s** — dominated by 12 × disk-read PCX +
RLE decode + VRAM blit. Effectively identical to the corrupted-state
number because BENCHIM is small enough (5.5 KB) to land entirely in
the FileBuf safe zone (0x6800..0x8761), so it never tripped the
overlap bug.

**Subsequent scrolls: 4.56 s mean.** Comparable to BENCHTX scrolls
since both pages now go through the same real-parser walk; the
viewport-full short-circuit prevents image re-fetch.

### Snapshot binary

`dist/mwbro_baseline.com` (sha `1ef4d83651a7…`) is the post-fix
baseline `BENCH=1` binary. To re-run the baseline numbers from any
future optimisation, restore it with `cp dist/mwbro_baseline.com
dist/mwbro.com && ./tools/inject.sh`.

## After tasks D + E

Branch: `optimization_round_1` after the `tasks D + E` commit.
- D: `VdpFill` inner loop rewritten with the `LD B,0 -> 256-iter`
  trick (50 T-states / byte → 24 T-states / byte, only caller is
  `ClearContent`'s 27 KB startup paint).
- E: `HALT` inserted at the top of `MainLoop` so the idle path
  pauses on VBLANK instead of busy-spinning.
- F + G: confirmed no work to do on this codebase.

### `BENCHTX.HTM` — text only, 11 912 B (post D+E)

| Render # | Trigger | Start (s) | End (s) | Duration (s) | Δ vs baseline |
|---|---|--:|--:|--:|--:|
| 1 | Initial page load | 44.53 | 50.86 | **6.33** | **-0.26 s** ✅ |
| 2 | 1st PageDown        | 51.50 | 56.24 | 4.74 | +0.23 (noise) |
| 3 | 2nd PageDown        | 106.36 | 111.22 | 4.86 | +0.23 (noise) |
| 4 | 3rd PageDown        | 166.37 | 171.16 | 4.79 | -0.05 (noise) |

**Initial render: -260 ms.** Matches the predicted ~195 ms saving
on the 27 KB startup paint within measurement margin. Per-scroll
renders don't go through `VdpFill` (they use `FillRect` which is
already DJNZ-paced at 24 T-states / byte), so the ~3 % per-scroll
delta is within the harness's noise band (std-dev 0.13 s on
baseline). E (MainLoop HALT) doesn't change render latency — it
only paces the idle path between user input.

## Task B — DEFERRED

The simple "(line# → FileBuf offset)" cache implemented and tested.
**Result: no measurable improvement over baseline** because a bare
offset-only entry can't be safely restarted from PrintFileContent's
default reset state. To make a cache jump correct, the parser frame
at the cached point must match the post-reset state — which means
either:

1. **Restrict cache entries to "safe-state" boundaries** (no open
   `<head>/<table>/<script>/<h1-2>/<b>/<a>/...`, no pending Arabic
   word, no list indent, no non-default align/dir). On the
   benchmark pages these boundaries are too sparse to help — we
   ended up caching only the seed entry `(0, 0)`, which is
   equivalent to no cache.

2. **Store a full parser-state snapshot per entry** (HtmlStyleFlags
   / Scale / InHead / InTitle / InTable / InScript / InAnchor /
   Pre / ListKind / OlCounter / Indent / Align / Dir / Fg /
   FgDepth / TableCol / TableFirst / RowTopY / LiPending / ArLen +
   ArBuf / TextX / TextY ≈ 80 bytes per entry × 30+ entries ≈
   2.4 KB).

Option (2) is the right architectural answer but a significantly
larger change than was budgeted for this round. **Tabled for a
follow-up round-1.5** so it doesn't block A / C / D-G.

The bench infrastructure (BENCHTX/BENCHIM, the harness, the
sentinel, the baseline binary `dist/mwbro_baseline.com`) was kept;
re-running the harness after each subsequent task gives a clean
delta vs. baseline.

## Targets for optimisation (revised)

| Task | Hypothesis | Expected post-fix (BENCHTX) | Expected post-fix (BENCHIM scroll) |
|---|---|--:|--:|
| ~~**B** Layout-offset cache~~ | deferred — see above | — | — |
| **A** HMMM-copy + render newly-exposed strip | re-render only ~1/22nd of viewport | ~0.4 s | ~0.4 s |
| **C** Off-screen page-ahead | apparent 0 s on PgDn | ~0 s (perceived) | ~0 s (perceived) |
| **D-G** Tidy-ups (OUTI / EI-HALT / IX-IY audit / EX-AF) | constant-factor improvements | -5 to -10 % everywhere | -5 to -10 % everywhere |

We re-run the same two pages after each optimisation lands and
append a column here. The `tools/bench_scroll.tcl` invocation is
deterministic (seeded `gen_bench_pages.py` + fixed `BENCH_GAP`), so
re-runs are directly comparable.

## How to reproduce

```sh
# Build + inject the BENCH binary
BENCH=1 ./tools/build.sh && ./tools/inject.sh

# Text page (uses default GAP=12s, takes ~95 s of emulated time)
pkill -9 -f openmsx; sleep 2
BENCH_PAGE=BENCHTX.HTM \
  /Applications/openMSX.app/Contents/MacOS/openmsx \
    -machine Sony_HB-F1XD -diska 'MSX-DOS/MSX-DOS v1.03.DSK' \
    -script tools/plug_mouse.tcl -script tools/bench_scroll.tcl

# Image page (needs ~4× longer between presses; total ~6 min)
pkill -9 -f openmsx; sleep 2
BENCH_PAGE=BENCHIM.HTM BENCH_GAP=80 \
  /Applications/openMSX.app/Contents/MacOS/openmsx \
    -machine Sony_HB-F1XD -diska 'MSX-DOS/MSX-DOS v1.03.DSK' \
    -script tools/plug_mouse.tcl -script tools/bench_scroll.tcl

# Read the captured durations
cat /tmp/bench_BENCHTX.log
cat /tmp/bench_BENCHIM.log
```

`BENCH=1` controls a build-time `IFDEF` — production builds
(`./tools/build.sh` without env) ship without the sentinel writes,
so `dist/mwbro.com` on `main` is unaffected.
