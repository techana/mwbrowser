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

## Baseline (pre-optimisation)

Branch: `optimization_round_1` at the infra-only commit (no
renderer changes yet — same `PrintFileContent` walk-from-FileBuf-byte-0
on every scroll).

### `BENCHTX.HTM` — text only, 23 402 B

| Render # | Trigger | Start (s) | End (s) | Duration (s) |
|---|---|--:|--:|--:|
| 1 | 1st PageDown | 49.40 | 58.91 |  **9.51** |
| 2 | 2nd PageDown | 59.55 | 69.71 | **10.16** |
| 3 | 3rd PageDown | 70.38 | 80.92 | **10.54** |
| 4 | 4th PageDown | 82.36 | 92.62 | **10.26** |

**Mean: 10.12 s per scroll. Std dev: 0.39 s.**

The first PageDown is essentially the same cost as the others —
expected, because the prefix walk cost is `O(FileLen)` regardless of
which target line we're skipping to. Each render re-parses all
23 402 bytes.

### `BENCHIM.HTM` — 12 inline PCX images, 5 298 B markup

| Render # | Trigger | Start (s) | End (s) | Duration (s) |
|---|---|--:|--:|--:|
| 1 | Initial load (page render including 12 image fetches) | 41.83 | 93.46 | **51.63** |
| 2 | 1st PageDown (re-render; images cached as already-painted? no — re-fetched) | 94.09 |  98.77 | **4.68** |
| 3 | 2nd PageDown | 126.38 | 131.07 | **4.69** |

**Initial load: 51.63 s** — dominated by 12 × disk-read PCX + RLE
decode + VRAM blit. About 4.3 s per inline image.

**Subsequent scrolls: 4.69 s mean.** Faster than BENCHTX scrolls
because the markup is only 5 KB (1/4.5× the prefix-walk cost), and
the `PrintFileContent` viewport-full short-circuit kicks in once
`HtmlLineSkip` drains and the render Y has crossed `CONTENT_Y1` —
so most images aren't re-fetched on a scrolled pass.

## Targets for optimisation

Per the analysis in the project handover note:

| Task | Hypothesis | Expected post-fix (BENCHTX) | Expected post-fix (BENCHIM scroll) |
|---|---|--:|--:|
| **B** Layout-offset cache | drops O(FileLen) prefix walk to O(1) lookup | ~3.0 s | ~1.5 s |
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
