# Embedded font: `src/font_iso8859_6_ax370.bin`

This 2 KB blob is a one-time dump of the **AX-370 Al-Alamiah Arabic ROM
font** (256 glyphs × 8 rows, ISO-8859-6 layout). It is included into the
`.COM` image at link time via `INCBIN`; `FontBuf` aliases the start of
the embedded block, so the renderer reads glyph bytes directly from the
program image without copying.

## Why this exists

Earlier builds extracted the font at boot via per-byte `RDSLT` calls
into the slot that BIOS `CGPNT` (`0xF91F`) pointed at. That ran in
~90 ms on a cold boot and worked correctly on AX-370 — but on
non-Arabic machines (Sony HB-F1XD, Panasonic FS-A1, generic European
MSX2) `CGPNT` pointed at *that machine's* font ROM, which has katakana
/ kanji-radical / extended-Latin glyphs at code points 0xA0–0xFF.

The renderer (`IsoMap`, `IsoJoin`, `ShapePick`) is hardcoded around the
**AX-370 layout** — every byte position 0xA0+ is assumed to be a
specific Arabic glyph or diacritic. So on any non-AX-370 machine, the
runtime-extracted font produced garbage for every Arabic byte the page
contained.

Embedding the AX-370 font at link time:

* fixes Arabic rendering on every MSX2 machine, not just AX-370;
* deletes ~30 lines of boot-time code (`ExtractFont` + supporting
  scratch);
* eliminates the `0xC200` "haunted page" hardware quirk we used to
  document at `FontBuf equ 0xC200` (the BIOS / slot-3 expansion bug
  documented in `mwbrowser.asm` around the old FontBuf comment);
* saves the ~90 ms boot-time extraction.

The trade-off: **the local machine's ASCII font aesthetic is gone**.
ASCII glyphs (0x20–0x7E) now render with AX-370's letterforms on every
machine. They're still ASCII, just shaped slightly differently than
a Sony or Panasonic owner is used to from their other software.

## Why this is fine for "Japanese users", etc.

This program never could render Japanese HTML: there is no Shift-JIS
decoder, no JIS X 0208 lookup, no kanji shaping. The HTML parser only
honours `iso-8859-6` and ASCII. Embedding the AX-370 font does not
remove a capability; it simply removes the machine-dependent font
selection at boot. See the commit message + the inline comment by
`FontData` in `mwbrowser.asm` for a longer discussion.

## Regenerating the blob

The file should never need to change. If you ever need to capture a
fresh AX-370 dump (e.g. validating against a different ROM revision or
porting to a different Arabic-MSX font like Sakhr or Yamaha YIS):

1. Restore the runtime-extraction code path (see the commented-out
   `ExtractFont` block in `mwbrowser.asm` directly above `FontData:`).
2. Build + run on AX-370 in openMSX:
   `tools/run.sh -a` (or your normal AX-370 launch).
3. Pause the emulator any time after MWBRO has booted (boot is
   complete around MSX time ≈ 30 s) and dump RAM `0xC200..0xC9FF` to
   a file. The repo has `tools/dbg_dump_font.tcl` as a turnkey
   harness — it writes `/tmp/font_t30.bin` and a few neighbouring
   timepoints; pick any that is *not* all-zero or all-`0xFF`.
4. Copy that file over `src/font_iso8859_6_ax370.bin`.
5. Re-revert to the embedded path (drop `ExtractFont` again).

## Reverting completely (rare)

If a future version genuinely needs the BIOS-derived font (e.g. a
multi-machine variant that picks a different glyph layout per host),
the inline history comment block above `FontData:` in
`mwbrowser.asm` lists every change to undo:

* restore `BIOS_RDSLT` + `CGPNT` equates near the top;
* restore the `ExtractFont` routine;
* restore `FastCgSlot:` in the BSS block;
* restore the `call ExtractFont` between `Force212Lines` and
  `BuildFastLut`;
* turn `FontBuf` back into a 2 KB RAM region
  (`FontBuf equ 0xC200 ; ImgBuf equ FontBuf + FONT_BUF_SIZE`).

Total revert is ~50 lines.
