# Zero-latency Screen 6 — what we learned, and what MWBrowser can use

Branch: `quick_screen_draw`. Both samples (`SHOWTXT.ASM.txt` and the
"Zero-Latency Materialization Kernel" embedded in
`MSX2 Assembly Fast Screen Display.md`) were extracted, fixed, and
assembled with our SjASMPlus build (`build/SHOWTXT.COM`,
`build/ZLK.COM`).

## Sample status

Neither program runs cleanly out of the box. They hold up well as
*design notes*; as `.COM`s they have issues:

| Issue | SHOWTXT | ZLK kernel |
|------|---------|-----------|
| Uses MSX-DOS 2 handle calls (BDOS 0x43/0x48/0x45) instead of FCB | yes | no |
| Direct `call 0x000C / 0x005F / 0x005C` to BIOS — page 0 in MSX-DOS is RAM, not ROM | yes | n/a |
| `LD A, (SP+1)` — not a real Z80 instruction | no | yes |
| Sets only R0/R1/R2/R8/R9 — leaves color/pattern table base unset, so the V9938 can't display Graphic 5 cleanly | n/a | yes |
| `LD (FileHandle), B` and `LD B, (FileHandle)` — illegal; only A has direct mem load/store | yes | no |

After patching:
- `SHOWTXT.ASM` → embedded sample text (skip DOS file I/O), wrap
  every BIOS call in `CALLBIOS` (same `ld iy,(EXPTBL) / ld ix,name /
  call CALSLT` pattern MWBrowser uses).
- `ZLK.ASM` → embedded text, fixed `(SP+n)` via D/E stash.

`SHOWTXT.COM` still hangs in the RDSLT font-copy loop on the HB-F1XD
boot path (suspected `EI`-inside-tight-loop interaction with the DOS
timer ISR). `ZLK.COM` runs to completion but never enables Graphic 5
visibly because R3/R4/R5/R6 are left in their Screen-0 values, so
the V9938 can't generate a Graphic-5 raster from the bytes it
receives.

Conclusion: don't trust either as a runnable demo. The *ideas* are
sound and well-known MSX optimizations.

## The five ideas worth keeping

### 1. Compose into a RAM bitmap; one bulk transfer to VRAM

> "Move HTML rendering off the per-byte path. Build the whole frame
> in RAM, then push it across as a single LDIRVM / OUTI block."

Today MWBrowser parses HTML → emits glyphs into a *line buffer* →
flushes every line to VRAM separately. Each `LineFlush` re-asserts
the VDP write address and pays the per-cell wait-state tax.

**Win on MWBrowser:** the existing `RenderRemoteBitmap` path
(BITMAP pipeline) already does this for view-only mode. The
broader application: when re-rendering after a scroll, we could
pre-build the next viewport in a RAM scratch buffer and blit it
in one OUTI burst, instead of walking the line buffer and re-issuing
SetVramWritePos per row.

### 2. Display blanking during VRAM bursts (R1 BL=0)

> "Blank the screen, free up the VRAM bus, transmit at full Z80
> speed, un-blank."

The V9938 arbiter halves the VRAM bandwidth available to the CPU
during active rendering. With BL=0 the CPU gets ~100% of the bus.

**Win on MWBrowser:** measure first. Today's `LineFlush` and
`RenderSc6File` don't blank. For the SC6 file path that touches
~24 KB on a fresh page load, the speedup may be visible. But
blanking flickers the screen, so we'd only do it for the bulk
transfer phase of a fresh page load, not for incremental link-cursor
repaints.

Implementation: a small `BlankBegin` / `BlankEnd` pair that toggles
R1 bit 6 (BL), bracketing the OUTI loop in `RenderRemoteBitmap` and
`RenderSc6File`. ~6 bytes of code per pair.

### 3. Page-aligned LUTs to kill index math in the inner loop

> "LUT_HI at 0x8000, LUT_LO at 0x8100. Set H=0x80, L=index — no
> multiplication, no add. INC H to switch tables."

When you can afford 256-byte tables with a meaningful base address,
this technique compresses `(table + index*size)` into a single
register load.

**Win on MWBrowser:** the **font glyph fetch** in `LineDrawCells`
currently computes `font_base + char*8` for each glyph. If we move
the font into a page-aligned, transposed layout (byte 0 of all 256
glyphs in page A, byte 1 in page A+1, …), the inner glyph fetch
becomes `LD A,(HL)` with `H = row_page` and `L = char_code`. That's
*the* idea worth trying.

Cost: 8 × 256 = 2048 bytes of font, plus we'd need to keep both the
linear and transposed forms (some sites still want the linear walk).
TPA is tight but recoverable — we already moved 44 reservations to
RuntimeRamBase to free .COM space.

### 4. Transposed font for row-major rendering

> "Process line 0 of all 64 chars in one pass, then line 1, then
> line 2. Need the font laid out row-first."

Same idea as (3), and the natural pair to it. Today MWBrowser's
glyph loop iterates 8 rows per glyph and re-asserts the VDP write
address every time it advances down a line. With row-major rendering
plus a transposed font, we could emit a whole row of 64 glyphs in
one continuous `OUT (C),A` stream — no per-glyph address resets.

**Win on MWBrowser:** This is the biggest potential speedup for
the *HTML* (non-bitmap) path. The current per-line emission is
exactly the slow case described in the design note. Combine with
(2) blanking and (3) page-aligned expansion LUT and a full
viewport repaint becomes a tight ~99 T-state-per-char inner loop
instead of the dozens of cycles of pointer math we do today.

### 5. Decouple parsing from rendering

> "Run the parser to completion to a flat 2D grid in RAM. Then run
> the renderer over the grid. No conditionals in the inner emit."

This is the deepest architectural lesson. MWBrowser currently
interleaves: parse a tag → set style state → emit glyphs → flush
line → parse next tag. Each style change makes the inner emit
slower because the dispatch has to look at the live style flags.

**Win on MWBrowser:** in *bitmap* mode we already do this (the
bridge pre-renders, MSX just blits). In *HTML* mode we'd need an
intermediate buffer of `(char, style_byte, x, y)` tuples or a
parallel "style mask" plane — and then a second pass to emit with
no branching. That's a much bigger refactor; the easier wins (1–4)
should ship first.

## Recommended order of exploitation on `quick_screen_draw`

1. **Page-aligned bifurcated LUT for glyph expansion** (lesson 3).
   ~512 bytes of LUT. Self-contained: change only `LineDrawCells` /
   the equivalent glyph emission site. Easy to A/B with the current
   code via a `USE_FAST_GLYPH` `IFDEF`.
2. **Display blanking around bulk VRAM writes** (lesson 2). Wrap
   `RenderSc6File` and `RenderRemoteBitmap`'s OUTI bodies. Measure
   page-load time before/after with `tools/shot_benchtx.tcl`.
3. **Transposed font + row-major repaint of one viewport row**
   (lesson 4). Bigger; needs both the transposed font in RAM and
   a refactor of the glyph-emit inner loop. Probably worth its own
   sub-branch off `quick_screen_draw`.
4. **Full RAM-side viewport composition** (lesson 1). Compose the
   next 192-row Screen-6 frame in a 24 KB scratch buffer, blit in
   one burst on PageDown. This is essentially "BITMAP mode but
   on-MSX" and overlaps with the BITMAP_PIPELINE_DESIGN — defer
   until after 1–3 land and we can measure the remaining gap.
5. **Two-phase parser** (lesson 5). Don't ship until 1–4 have
   visibly shipped a faster scroll. May not be needed if 1–3 close
   the gap.

## What we will NOT lift

- The "VDP_PORT1 0AH 80H 00H 81H 1FH 82H ..." sequence in ZLK.
  CHGMOD 6 (BIOS) gets all the registers right; doing it manually
  saves 30 T-states once and risks half-configured displays
  forever. MWBrowser already uses CHGMOD via `CALLBIOS BIOS_CHGMOD`
  — keep it.
- `ld a, (SP+n)` — not a real Z80 op. Whoever wrote the kernel was
  confused with HD64180 / eZ80.
- Direct `call #000C / #005F / #015F` from a `.COM`. Page 0 isn't
  the BIOS in MSX-DOS. Use `CALLBIOS`.
- "LD HL, 1 / LD (FCB+14), HL" mid-program to override record size
  — fine for the toy but we already use FCB record-size=1 throughout
  MWBrowser; nothing new.

## Files in this branch

```
research/zero-latency screen6/
  MSX2 Assembly Fast Screen Display.md   original write-up + kernel
  SHOWTXT.ASM.txt                        original simpler sample
  LESSONS.md                             this file
  build/
    showtxt.asm  zlk.asm                 patched, assemblable sources
    SHOWTXT.COM  ZLK.COM                 .COM outputs (do not run as-is)
    SOME.TXT                             sample text (only used if you
                                         restore the file-loading path)
tools/
  shot_zlss.tcl                          openMSX driver for SHOWTXT
  shot_zlk.tcl                           openMSX driver for ZLK
```
