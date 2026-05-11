# MSX WBrowser — notes for future Claude Code sessions

This file is pre-context for anyone (human or agent) touching this repo. Read
it before editing `src/mwbrowser.asm` or the tools, it will save hours of
rediscovery.

## What the project is

- A minimal HTML browser for MSX2, written in Z80 assembly, built with
  **SjASMPlus** and run as a `.COM` under MSX-DOS 1. (Originally built
  with asMSX; see `tools/asmsx/` for the old pinned binary. The move to
  SjASMPlus was made after we started pushing binary size past the
  AX-370 TPA cap and wanted an actively-maintained open-source
  toolchain. At the size the migration happened both assemblers
  produced bit-identical .COM output.)
- Target video mode is **Screen 6** (512 × 212, 4 colours). All drawing
  goes through direct VDP I/O (`out [VDP_CMD]`, `out [VDP_DATA]`). The
  BIOS is not used for content rendering.
- Render target: `dist/mwbro.com`. Source-of-truth: `src/mwbrowser.asm`
  (~8.5 k lines) plus the generated table `src/iso8859_6.inc`.
- Released at `v0.5 demo build` (see `AboutFooter`).

## Repo layout

```
src/mwbrowser.asm       main source; everything lives here
src/iso8859_6.inc       ISO-8859-6 → glyph/joining table (generated)
dist/mwbro.com          assembled binary, committed alongside source
samples/                HTML + SC6/PCX/BMP used by the test pages
tools/build.sh          SjASMPlus wrapper, writes dist/mwbro.com + .sym
tools/sjasmplus/        bundled sjasmplus binary (macOS arm64)
tools/inject.sh         mcopy samples + binary into the MSX-DOS disk
tools/run.sh            openMSX launcher -- defaults to Sony HB-F1XD
                        (pass -a for the AX-370 when doing Arabic runs)
tools/dump_ax370_font.sh  extract the live AX-370 CGTABL to
                        resources/fonts/ax370_cgtabl.bin
tools/*.tcl             emulator driver scripts (screenshots, key injection)
tools/*.py              PNG→SC6, img_encode for data:msx;base64, test gens
tools/img_encode/       local scratch (ignored by git)
resources/fonts/        extracted ROM fonts (AX-370 Arabic CGTABL)
MSX-DOS/                boot disk image (not in repo)
```

## Day-to-day workflow

```sh
./tools/build.sh          # SjASMPlus src/mwbrowser.asm → dist/mwbro.com
./tools/inject.sh         # mcopy files into MSX-DOS/MSX-DOS v1.03.DSK
./tools/run.sh            # openMSX on HB-F1XD + autorun.tcl (-i interactive)
./tools/run.sh -a         # force AX-370 (only for Arabic-font regressions)
```

## Machine matrix

MWBRO targets MSX2 / MSX2+. Verified working on Sony HB-F1XD, Sony
HB-F700D, and Al-Alamiah AX-370. Day-to-day testing happens on
HB-F1XD (smallest config, fastest emulator boot); pivot to AX-370 for
Arabic-font regressions (the AX-370's CGTABL has the shaped glyphs).

### History note: the "AX-370 ~15565 B TPA cap" was a misdiagnosis

A pre-streaming-work theory held that AX-370's slot layout (ROMs in
every secondary of slot 0, external slots 1/2, cartridge ROMs on slot
3) capped the .COM size at ~15565 bytes, manifesting as a boot hang
with `Screen0Palette` appearing in the V9938 palette registers. Once
the binary grew past that threshold, openMSX started reporting
`warning: DI; HALT detected, which means a hang.` on AX-370 and on
Sony HB-F700D.

Root cause turned out to be the bare `halt` in `MainLoop` without a
preceding `ei`. The original code assumed "MSX-DOS leaves interrupts
enabled during a .COM session"; that holds on HB-F1XD but NOT on
HB-F700D / AX-370 (and likely a wider class of MSX2 BIOSes). With
IFF=0, `halt` waits forever for an interrupt that never fires; the
CPU eventually gets reset into our shutdown code (which restores the
Screen 0 palette) — explaining the original "Screen0Palette in
the registers" symptom that looked like a TPA collision. Fix: the
canonical MSX `ei / halt` vsync wait, which the Z80 architecture
guarantees won't take an interrupt before HALT executes.

There is no real .COM size cap below the MSX2 TPA boundary set by
MSX-DOS HIMEM (~0xDF94 on most machines). Build for size for the
sake of TPA budget, not for AX-370 specifically.

Automated testing is done by writing a TCL script in `tools/shot_*.tcl`
that `type`s keys and `screenshot -raw -size 640 -prefix ...`s at specific
`after time` marks, then launching openMSX with both `plug_mouse.tcl` and
the shot script. The emulator runs in wall-clock time; expect ~30-60 s per
run before the screenshots land in `/tmp/`.

## Coordinate system you WILL get wrong once

- MSX content area: **y = 29 .. 211** (183 px tall), **x = 0 .. 491**
  (492 px wide; content-width in bytes = 123 since Screen 6 packs 4 px
  per byte).
- openMSX `-raw -size 640` screenshots are 640 × 480. There is a ~68 px
  left overscan band, so:
  - `screen_x = 68 + msx_x`   (1:1 scale horizontally)
  - `screen_y = 28 + msx_y * 2` (2:1 scale vertically)
- If pixel-scanning screenshots, use this exact mapping — I've wasted
  real hours on incorrect offsets convincing myself the renderer was
  broken when it wasn't.

## Screen-6 palette quirks

Palette slots (`src/mwbrowser.asm` lines ~50):

| Value | Slot | Renders as |
|-------|------|------------|
| 0 | pal 0 | dgray (~RGB 73,73,73), pair-palette dithered with pal 2 → mid-grey |
| 1 | pal 1 | solid light grey (~182) |
| 2 | pal 2 | solid white (255) |
| 3 | pal 3 | solid black (0) |

External SC6/PCX images are authored assuming *slot 0 = black, slot 3 =
white*. The browser runs them through `ExtImgRemap` (built at startup in
`BuildExtImgRemap`) to permute pixel values onto our UI palette. BMP has
its own luminance quantiser and skips the remap.

## Z80 / SjASMPlus gotchas

- **I/O port addressing uses `( )` not `[ ]`**. `out (VDP_CMD), a` /
  `in a, (VDP_CMD)`. Memory addressing (`ld [addr], a`, `ld [hl], a`)
  keeps bracket syntax. asMSX accepted brackets for both; SjASMPlus
  errors on `out [...]`.
- **BIOS calls go through the `CALLBIOS` macro** defined near the
  top of `src/mwbrowser.asm`. It emits the same 11-byte sequence
  asMSX's builtin `.CALLBIOS NAME` did (load IY from EXPTBL, IX with
  the BIOS entry, `CALL CALSLT`). Entries are `BIOS_CHGMOD`,
  `BIOS_RDSLT`, `BIOS_GRPPRT` — extend with any new hook you need.
- `jr` is limited to ±128 bytes. When adding code to a renderer, branches
  to distant labels silently fail with "unreachable address" — switch to
  `jp` / `jp c` / `jp nc`.
- **Local-label scoping is stricter in SjASMPlus.** A `.foo` label lives
  under the preceding non-dot label; other non-dot labels can't see it
  (asMSX was loose about this). `FillExtField` used to be a local tail
  block inside `DetectPlainText` referenced from `BuildFcbFromHL` — we
  promoted it to a global during the migration. Do the same if you
  notice a similar cross-scope dot-label reference.
- **8-bit TextY traps.** Any `add a, pitch` that advances TextY without
  checking the carry flag can wrap a near-overflow value to 0..15 and
  start painting into the **titlebar** (VRAM rows 0..8). We hit this in
  `EmitNewline`, `EmitHalfLineGap`, and both `TagTr` / `TagTableTag`
  sites — see commit `7ee71d9`. The shared pattern is now:
  ```
  add a, pitch
  jr  c, .clamp          ; wrap past 255
  cp  CONTENT_Y1 + 1
  jr  c, .ok
  .clamp:
      ld a, CONTENT_Y1 + 1
  .ok:
      ld [TextY], a
  ```
  When adding new code that advances TextY, replicate this.
- BC is the djnz counter in every `colRender`-style loop. Wrap sub-calls
  that trash BC in `push bc / call X / pop bc` (seen in SC6/PCX/BMP
  renderers).
- **MSX-DOS 1 zero-pads the last record** when the file isn't a multiple
  of 128 bytes. The `ImgStream` reader caps refills at the 32-bit remaining
  byte count (snapshotted from `Fcb+16` at `ImgStreamOpenName`) so the pad
  never reaches the decoders. Any new streaming reader must do the same.

## Register-allocation conventions (read before "optimizing")

LLM-written Z80 tends to shuffle state through memory bytes or `push`/`pop`
pairs where the shadow bank would be the idiomatic move. This codebase has
been audited once; keep it that way.

- **Shadow bank (AF', BC', DE', HL') is reserved for leaf helpers** that
  need to preserve a register across internal HL/DE math. `FormGetNamePtr`
  and `FormGetValuePtr` use `ex af, af'` to preserve A for the caller;
  don't introduce a second consumer of AF' higher in the call chain
  without auditing those leaves. BC'/DE'/HL' are currently free — use
  `exx` before reaching for `push bc` / `push de` / `push hl` around a
  call, as long as the callee doesn't also `exx`.
- **IX/IY are banned outside two sites.** `CursorPaint` reads two parallel
  byte arrays in lock-step (IX=`CursorBg`, IY=`CursorMask`) and the title
  BiDi reverse-swap needs a descending pointer alongside ascending HL.
  Both are textbook cases. Everywhere else: use HL/DE. IY in particular
  must stay free for the `CALLBIOS` macro's `CALSLT` dance.
- **Don't preserve A across a sub-call with `push af`/`pop af`** if the
  slot already has a scratch byte (`FormSlotTmp`, etc.) — the memory
  stash is cheaper *and* leaves the stack clean for debugging. Reserve
  `push af` for cases where you genuinely need CF preserved across a
  `call nc, X`.
- **Don't run a big structural refactor and a register-allocation pass
  in the same query.** The agent loses track of which registers are
  live by the time it's rewriting the math. Ship the structure change,
  then do a dedicated EX/EXX pass as its own commit.

## HTML subset implemented

Block: `<h1>…<h6>`, `<p>`, `<pre>`, `<blockquote>`, `<center>`, `<hr>`,
`<br>`, `<ul>`/`<ol>`/`<li>`, `<table>`/`<tr>`/`<td>`/`<th>`, `<a href>`,
`<img src alt>`, `<font color>`.

Inline style: `<b>` (`STYLE_BOLD`), `<i>` (`STYLE_ITALIC`), `<u>`
(`STYLE_UNDERLINE`), `<s>`/`<strike>`/`<del>` (`STYLE_STRIKE`). All four
share `StyleBitDispatch` — a single bit mask in C. Headings similarly
share `HxDispatch` with (B, C) = (scale, style-mask).

Alignment: `align="left|right|center"` on block tags; `<center>` sets
`HtmlAlign = 2` with the same half-line gap above as other blocks.

Entities: `&nbsp; &amp; &lt; &gt; &quot; &apos;` and `&#NN;`.

## Image pipeline

Four `<img src>` paths, all streaming (no full-image RAM buffers):

1. `data:msx;base64,...` — base64 of `[width_bytes][height_rows][pixels…]`.
   Generated by `tools/img_encode/img_encode.py`.
2. `*.sc6` — 7-byte BSAVE header + 128 B / row raw Screen-6 pixels.
   Convert with `tools/png_to_sc6.py -c` (the `-c` splits the padding
   evenly so narrow logos *look* centred when the HTML wraps them in
   `<center>`).
3. `*.pcx` — 2 bpp / 1 plane PCX (RLE) only. Other variants fall back to
   `[alt]`.
4. `*.bmp` — 4 bpp (16-colour palette) and 24 bpp only. Rows are
   bottom-up on disk; the renderer consumes off-screen bottom rows
   without drawing, then renders top-down into VRAM.

TagImg dispatches by `data:msx` prefix or file extension. If a render
path fails before the line is flushed, it returns CF=0 and TagImg falls
through to the `[alt]` / `[img]` placeholder — so a missing file never
produces a blank line.

## Memory map at runtime (MSX-DOS 1 TPA)

```
0x0100 ..            .COM image (~14.3 KB)
~0x3995              FileBuf      (FILE_BUF_SIZE = 36 KB)
~0xC995              FontBuf      (2 KB — BIOS font pulled at startup)
~0xD195              ImgBuf       (128 B DMA scratch for ImgStream)
        ...          globals, tables (BmpPal16, ImgNameBuf, ExtImgRemap…)
~0xF380              BDOS         (HIMEM)
```

The `.sym` file SjASMPlus emits alongside the binary has exact
addresses — consult it when you need to trace a bug.

## Code-style expectations the user has stated

- **Minimal UI labels** — prefer single-glyph / drawn icons over
  multi-word button text.
- **Always keep `screenshot -raw -size 640`** — 640 is the cap the
  screenshot API enforces per image dimension.
- **Comments explain why, not what.** Existing renderers include prose
  like "MSX-DOS pads partial records…" — continue that voice.
- **Commit messages favour why over what**, first line under 70 chars,
  bullet list in the body describing each logical change.
- Never create `*.md` or documentation files unless asked; treat this
  `CLAUDE.md` itself as the exception.

## Things it's easy to break

- Adding a new tag handler and forgetting to list it in `TagLookup`
  (search for the `dw Tag...` block near the bottom of the parser).
- Editing the heading styles without updating `HxDispatch`'s close-path
  mask clearing. The "clear only bits we enabled" rule matters because
  users can nest `<b>` inside `<h3>`, etc.
- Forgetting that `ArFlush` emits *into the line buffer*, not VRAM — the
  actual paint is `LineFlush → LineDrawCells`. If Arabic goes missing,
  suspect a missing flush at a block boundary, not the VDP.
- Pixel art files: SC6 is 128 B / row *by spec*, even if the image is
  narrower. The browser cannot re-centre a full-width SC6; that's why
  `png_to_sc6.py --center` handles centring at author time.

### Never sweep `ld a, N → ld a, M` (or any code-wide replace) without auditing each hit

Commit `91b9011` mentioned a single one-line typo fix in `HxDispatch`
(`ld a, 2` should have been `ld a, 1`) and "fixed" it with what looks
like an editor-wide search-and-replace. The replacement landed on
**six unrelated sites**, two of which silently broke Arabic for ~99
commits:

- `ShapePick`'s form return values: `End` flipped from `1` to `2`
  (so it returned "Initial" instead of "End"), `Mid` from `3` to `2`
  (so it returned "Initial" instead of "Middle"). Every Arabic
  letter that should have rendered in End or Middle form silently
  fell through to Initial — visible as letter-cluster disconnection
  on TEST9.HTM (BEH at end-of-word came out medial, etc).
- The auto-RTL detection block: `HtmlDir` and `HtmlAlign` setters
  flipped from `1` (RTL / right-align) to `2` (which `HtmlAlign`
  treats as CENTER, and which `LineBidiReorder`'s `and CELL_RTL`
  bit-0 mask reads as LTR). RTL flow stopped reversing whole lines
  so embedded Latin runs landed in the wrong slot — visible as
  word-order garbage in mixed Arabic/Latin paragraphs.
- The `dir="rtl"` attribute parser: same `1 → 2` regression for
  pages that explicitly opt into RTL.

The HB-F1XD-only test loop hid both regressions because that ROM has
no Arabic glyphs to compare against. The misshaping and misordering
both rendered as "weird Latin garbage" indistinguishable from each
other on the wrong machine.

**Rule:** when fixing a typo of the form `ld a, N` (or any
literal-value typo), edit the **single specific site** by surrounding
context, not via project-wide find-and-replace. Z80 immediates are
extremely high-traffic — `ld a, 1` and `ld a, 2` each appear hundreds
of times for unrelated semantic purposes (form indices, mode flags,
palette slots, alignment values, R14 page selectors, etc). Replacing
all of them at once is guaranteed to break things that aren't the
thing you're trying to fix.

If a refactor really does need to change every occurrence (e.g.
renaming an enum constant), introduce a named `equ` first, change
the literal sites to use the `equ`, then change the `equ`'s value.
That isolates the semantic change from the syntactic edit and lets
the assembler complain if the change reaches a site that shouldn't
be touched.

### Cursor flicker at low Y (open, partially diagnosed)

User-reported bug, observed live on HB-F1XD:

- Cursor tip at MSX-y=47: only mask row 7 (bottom-right pixel of
  the arrow) flickers. All other 7 rows render stably.
- Tip at y=46: mask rows 6 + 7 flicker. Rows 0–5 stable.
- Tip at y=Y for 40 ≤ Y ≤ 47: rows `(Y - 40)..7` flicker; rows
  `0..(Y - 40 - 1)` stable.
- Tip at y ≤ 40: all 8 mask rows flicker, frequency rises until
  the cursor is visually invisible.

Decoded threshold: **mask index i flickers iff Y ≤ 40 + i.** Each
mask row has its own Y threshold spaced exactly 1 MSX-y apart.

That spacing is too precise for a uniform V9938 raster-write race
(tried it: commit `e6e6b4d` moved `PollMouse` to before `halt`,
zero observable improvement, reverted in `01fe341`). The per-row
threshold suggests one of:

1. The save-loop reading VRAM via the VDP read prefetch returns
   stale bytes when raster is scanning the same Y range — the
   prefetch state being raster-line dependent.
2. The cursor mask bytes encode a row-dependent offset (e.g.
   reading from `CursorBg[i]` but writing to a position offset by
   `i`) and the bug only surfaces at the threshold where some
   wrap-around boundary is crossed.
3. The MSX mouse delta (signed nibble per axis) gets sign-
   extended differently for certain Y values, causing the cursor
   position to oscillate frame-to-frame between two adjacent Y
   values; the visible "flicker" is the cursor moving 1 pixel up
   and back every other frame, painting on two row sets.

Theory #3 fits the per-row precision best: if MouseY oscillates
between Y and Y-1 each frame, the cursor's mask rows render at
Y..Y+7 one frame and Y-1..Y+6 the next, so each mask row's pixel
appears alternately at Y+i and Y+i-1. The "bottom row only flicker
at Y=47" would be the case where Y is at exactly the boundary
where the oscillation amplitude only affects row 7's visible
position.

Next-session test: instrument `MouseY` writes to log frame-by-frame
values and confirm whether MouseY oscillates. If yes, fix the
sign-extension or delta accumulator. If no, the bug is in the
cursor save/restore path and the V9938 hardware sprite is probably
the cleanest fix.

### Never write a bare `halt` — always `ei / halt`

This bug bit us *hard* and the misdiagnosis lived in the source for
months. Document, don't repeat:

- The Z80's `halt` waits for an interrupt to wake the CPU. If `IFF=0`
  when HALT executes, no interrupt can fire and the CPU hangs forever.
- MSX-DOS does NOT uniformly leave interrupts enabled when handing
  control to a `.COM`. **HB-F1XD does**, but **HB-F700D, AX-370, and
  likely several other MSX2 BIOSes do NOT** — boot lands with `IFF=0`.
- Symptom on emulators: `openMSX` warns
  `warning: DI; HALT detected, which means a hang.` On real hardware
  the machine just freezes; eventually a reset / NMI runs our shutdown
  code and the V9938 palette winds up holding `Screen0Palette`. That
  trailing-edge symptom is what fooled the original CLAUDE.md into
  hypothesising an "AX-370 ~15565 B TPA cap." There is no such cap.
- The Z80 architecture guarantees `EI` doesn't enable interrupts
  *until after the next instruction*, so `ei / halt` is safe (no
  interrupt can fire between EI and HALT). This is the canonical MSX
  vsync wait — emit it whenever you HALT.
- The fix that landed in commit `ae55bb7`: literally just one `ei`
  before `MainLoop`'s `halt`. Don't optimise it out.

If you ever introduce another HALT in this codebase, the same rule
applies: precede it with `ei` unless you can prove `IFF=1` at that
point on every MSX2 BIOS we target. The cost is 4 T-states. The
debugging cost of getting it wrong is days.

## Debugging tools we haven't wired up yet

[openMSX/debugger](https://github.com/openMSX/debugger) is a Qt GUI
that attaches to a running openMSX over its debug port. Worth pulling
out of the toolbox the next time we hit a *corruption-class* bug
(memory smashed by a stray `push`/`pop` mismatch, V9938 palette
holding `Screen0Palette` mid-render, AX-370 hang with no idea what
PC the CPU was at). Loads our `.sym` directly so labels appear in
the disasm pane.

Cheaper for the 80% case: openMSX already exposes the same
primitives via its built-in Tcl `debug` command. A `tools/dbg.tcl`
helper that converts SjASMPlus's `.sym` into Tcl `set` statements
and wraps `debug set_watchpoint write_mem $HtmlScaleY {…}` would
have caught the `ld a, 2` parser-init typo on first write. Same
trick for the AX-370 hang: watch `out (0x9A)` (V9938 palette
command port) and dump the call site. Build the helper the next
time a similar bug shows up — don't pre-emptively.

The screenshot-driven `tools/shot_*.tcl` flow stays the right tool
for visible/rendering regressions; the debugger sits *next to* it,
not over it.

## Nice-to-have: local directory listing for `A:` URLs

Idea: typing just a drive letter ("A:", "B:") into the address bar
would render a 3-column listing (Name / Size / Modified) of the
disk, with known-displayable extensions wired as `<a>` links and
binaries wired through the existing Save-popup auto-route. Same
visual style as the bridge root listing.

**Why parked:** the cmdline arg (`MWBRO foo.htm`, `MWBRO a:test.htm`)
covers the immediate "I want to open a file on disk" workflow, and
implementing in-browser disk navigation would force tightening the
TPA budget (FILE_BUF_SIZE drops from 6 KB to 5.5 KB, and
SERIAL_CHUNK_RANGE_BYTES has to drop in lockstep — the
`FILE_BUF_SIZE >= SERIAL_CHUNK_RANGE_BYTES` invariant in
EnsureWindowRemote is load-bearing; if FileBuf is smaller, save
streams silently lose chunk tails). Roughly +235 B of code:

- `IsDriveOnlyUrl` (~25 B): match "X:" / "X:\" / "X:/" with no
  trailing filename.
- `LocalDirList` (~180 B): BDOS `F_SFIRST` (0x11) + `F_SNEXT` (0x12)
  with a wildcard FCB ("????????.???"), emit one row of synthesised
  HTML into FileBuf per match.
- Per-row HTML ≈ 40 B (`<a href="A:FOO.HTM">FOO.HTM</a> 0.2KB<br>`).

**MSX-DOS 1 wrinkle:** `F_SFIRST` / `F_SNEXT` return name + ext +
size + cluster only — no mtime field. The listing would be
2-column (or 3-col with a blank Modified placeholder). Raw sector
reads via `_DSKF` would give the date, but the complexity and
brittleness of bypassing BDOS isn't worth it for a parked feature.

If/when we pick this up: branch in `LoadFile` for `IsDriveOnlyUrl`
to `LocalDirList`, bypassing `BuildFcbFromUrl` + `DOS_OPEN`.
Synthesised HTML flows through the existing parser + scrollbar +
link-click handling for free. The `[]` save glyph stays dimmed
(local URL, already handled by `IsLocalUrl`).

## Good first bug-report workflow

1. Reproduce with the smallest possible HTML — `samples/rtlimg.htm` and
   `samples/rtltab.htm` exist for exactly this.
2. If the emulator layout breaks in ways that aren't obvious (e.g.
   "titlebar is scrambled"), suspect TextY wrap, VDP auto-increment
   crossing a row boundary without a fresh `SetVramWritePos`, or
   `ImgStream` reading padding bytes past EOF.
3. Before committing, rerun the most affected `shot_*.tcl` driver and
   compare with the current screenshot. openMSX is slow — budget 45+ s
   per run.

Good luck.
