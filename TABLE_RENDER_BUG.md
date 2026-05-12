# Table-render bug: handoff notes

Two related issues on `samples/benchtx.htm` page 8 (`A:BENCHTX.HTM`, press
PageDown 7 times — see `tools/shot_benchtx.tcl`). Repo head is at
`0203a25` ("Bump About-popup version to v0.8 Demo", the last online
push) with no uncommitted source changes. Multiple session attempts
landed partial fixes, then reverted because of regressions. This file
captures everything a fresh Claude/human needs to take over without
re-treading the same ground.

## Symptoms (current baseline, post-revert)

1. **Table corruption on page 8.** After seven PageDowns from a fresh
   load of `A:BENCHTX.HTM`, the Field/Value/Note table re-renders
   broken at the top of page 8: cells appear in wrong columns, no
   vertical borders. Page 7 (which shows the table partially at its
   bottom) renders correctly.
2. **Cell text truncated, no intra-cell wrap.** The Note column shows
   `Bridge pixel viewpo` instead of the full `Bridge pixel viewport
   form.`. A "proper" browser wraps long cell text inside the cell
   (growing row height); ours clips at `CellEndX - 6` via `EmitRaw`'s
   `.erDrop` branch.

The user's reference of a "proper" rendering is in
`/tmp/` (a screenshot they pasted in chat) — Field/Value narrow,
Note wide, multi-line cells, double outer border. We don't need to
match that pixel-for-pixel; the actionable target is "no shifted
cells, no clipped text".

## Test recipe (reproduce in ~2 min)

```sh
./tools/build.sh
./tools/inject.sh   # mcopy mwbro.com + benchtx.htm into the DSK
rm -f /tmp/vwr-bx-*.png
nohup /Applications/openMSX.app/Contents/MacOS/openmsx \
  -machine Sony_HB-F1XD \
  -diska "MSX-DOS/MSX-DOS v1.03.DSK" \
  -script tools/plug_mouse.tcl \
  -script tools/shot_benchtx.tcl \
  > /tmp/openmsx.out 2>&1 &
# wait ~130s, screenshots land at /tmp/vwr-bx-p1..p8-0001.png
```

Compare `vwr-bx-p7` (table at bottom, OK) vs `vwr-bx-p8` (table at top,
broken).

`samples/tbl1.htm` (standalone table) and `samples/tbl2.htm` (5 short
paragraphs + table + trailing text) are minimal reproducers — but **they
DON'T reproduce the bug** because both files fit in one `FILE_BUF_SIZE`
window so `SlideForwardLocal` never fires. The bug is benchtx-specific
because `benchtx.htm` is 11912 B > `FILE_BUF_SIZE` (6144) → slide is
required.

Add `samples/tbl1.htm` / `samples/tbl2.htm` back if you want them
(they were experimental; not committed). Sources are in this doc's
appendix.

## What's known

### 1. The bug class is "FileBuf window slides past `<table>` open"

- `benchtx.htm`: `<table>` opens at byte 5133, `</table>` closes at
  ~byte 5550. `FILE_BUF_SIZE = 6144`.
- After 7 PageDowns, `ScrollLine` reaches the clamp (= `HtmlLineCount -
  TEXT_MAX_LINES = 168 - 22 = 146`). At that point or the next
  PageDown, `PageDown` → `.pdAtMax` → `.pdLocalSlide` →
  `SlideForwardLocal`, which advances FileBuf to a new chunk and
  resets `ScrollLine = 0` in the new window.
- `SlideAlignTarget` cache-aligns the slide back to the nearest cached
  safe boundary. `LineCacheSnapshot` only fires when
  `IsLineCacheStateSafe` returns Z — which checks `HtmlInTable == 0`,
  so **cache entries only exist at pre-table offsets**. The slide
  therefore typically lands at a doc offset BEFORE byte 5133 (i.e.
  inside Section 6 paragraphs or earlier), and the new FileBuf window
  is e.g. bytes 4500..10643.
- In that "ideally aligned" case, the new FileBuf contains the full
  `<table>...</table>`, the parser walks it normally on page 8, and
  the table should render fine.

**Empirical observation (uncommitted diag from one of the runs):** of
the 7+ renders during the test, only 2 `TagTableTag.open` events fire —
once on page 1's initial render and once on the prerender for page 2.
After that, no more table-open events even though the table appears
visually re-rendered on later pages. That means later renders either
(a) skip the table because cache fast-forward jumps past it, or
(b) walk the table in skip-mode without the open handler running, or
(c) some other state-preservation path is being hit.

This needs to be re-verified with fresh diag in a future session.

### 2. `LineCache` interactions are important

Two restore paths in `PrintFileContent` (`src/mwbrowser.asm:4849` and
`:4915`):
- **`PendingRestoreSlot` post-slide restore** — applies the cached
  parser-state snapshot that matched the slide-aligned target.
- **`quick_screen_draw` fast-forward** — when `ScrollLine != 0`,
  `LineCacheLookupLine` finds the largest cached entry `<= ScrollLine`
  and jumps `HL` into FileBuf at that offset, charges the cached lines
  against `HtmlLineSkip`, and continues parsing from there.

Both call `LineCacheRestore`, which writes `HtmlScaleY / HtmlListKind /
HtmlOlCounter / HtmlIndent / HtmlAlign / HtmlDir / HtmlFg /
HtmlDefaultAlign / HtmlDefaultDir` — **but NOT `HtmlInTable`**. So a
priming write to `HtmlInTable` at PrintFileContent entry survives the
restore.

`LineCacheReset` is called in `EnsureWindowLocal` (the slide path),
so the cache is wiped post-slide. Subsequent fast-forwards on the new
window only see entries appended during this new render.

### 3. The fix shape that worked at one point (then regressed)

In one earlier iteration this rendered page 8 correctly (full table
with borders + Section 7 below):

1. **`ResumeTable` snapshot** at `TagTableTag.open` — 3 BSS bytes
   (`ResumeTableValid`, `ResumeTableColCount`, `ResumeTableBorder`),
   written right after `MeasureTableCols + SetTableColLayout`.
2. **Mid-table detector** `DetectMidTableStart` scans FileBuf for the
   first `<T*>` tag. Returns 1 if it's `<TR/<TD/<TH/<TB/<TF` or any
   `</T...` (i.e. inside a table); 0 if `<TABLE>` is seen first or no
   table tag found at all. **Must use the strict `ClassifyT2nd`
   helper** that only matches A/R/D/H/B/F as the 2nd letter — the loose
   "any `<T?` not `<TA`" check false-positives on `<TITLE>` at the top
   of benchtx (and triggers spurious mid-table prime → SmartWrap
   suppression → text-past-borders regression).
3. **Mid-table prime** at PrintFileContent entry (after the
   `PendingRestoreSlot` block, before the fast-forward block): if
   `ResumeTableValid` and `DetectMidTableStart` both fire, set
   `HtmlInTable = 2`, `HtmlTableCol = 0`, `HtmlTableFirst = 0`,
   `HtmlTableColCount = ResumeTableColCount`, `HtmlTableBorder =
   ResumeTableBorder`, then `call SetTableColLayout`.
4. **Reset block additions**: zero `CellStartX / CellEndX /
   HtmlTableColCount / HtmlTableBorder`, init `HtmlRowTopY =
   CONTENT_Y0` and `TableTopY = CONTENT_Y0` (the BSS-default 0 caused
   `DrawTableVerticals` to draw from y=0 through Section 7 text on the
   primed render).
5. **EmitRaw `.erCanvasWrap` guard**: when `HtmlInTable != 0`, skip the
   SmartWrap call so cell text doesn't break to next-row col-0. Cell
   text is then either clipped by `.erDrop` (when CellEndX is set) or
   accumulates in LineBuf until next FlushPendingCell.

This combination got page 8's table to render with correct columns and
borders in one test run. **But the next run of the same code rendered
page 8 with shifted cell data** (Field column showed Note's first
words, Value showed correct number, Note showed the previous row's
wrap continuation). It's not yet known whether the difference was
cache-align landing point variation, prerender timing, or something
state-dependent.

### 4. Other approaches tried (and reverted)

- **Atomic table skip** — `ScanTableRowsAhead` counts rows, computes
  `cost = rows + 2`, and clamps `HtmlLineSkip = 0` if `cost > skip`.
  Idea: a table that won't fit in the remaining skip should render
  from its top, never half-and-half. **Didn't fix the actual bug** —
  the cells still rendered with wrong column positioning on page 8.
- **`+2 per CountTableRow`** to fix the under-count of pixel space
  (each `<tr>` advances `TextY` by `TEXT_LINE_H + TABLE_ROW_GAP = 10
  px`, but `CountTableRow` only bumps `HtmlLineCount` by 1). Made
  `ScrollLine` advance correctly but **didn't fix the visible
  rendering**. The bug isn't a line-count miscount.
- **Flavor-A** (skip `PrerenderNext` for local-file loads) — original
  diagnosis was wrong; the prerender isn't the cause. Reverted in
  commit `74aaa52`.
- **Deferred `PrerenderNext`** to MainLoop's idle slot — this is
  unrelated to the bug, was a separate user-requested task. Committed
  as `d311738` (no longer in tree after the v0.8 revert).
- **`DrawTableVerticals` BorderHeight clamp** to `[CONTENT_Y0,
  CONTENT_Y1+1]` — minor defensive fix, was in `f2ab021`. Useful
  hygiene, not bug-defining.

### 5. Diag instrumentation playbook

When picking this up, the first move is to put back instrumentation
and run the test. Patterns that worked:

- **Port 0x2E write watchpoint** + a TCL script that captures bursts.
  Burst format: a start marker byte (e.g. 0xAA), then N data bytes,
  then an end marker (0xBB). TCL `debug set_watchpoint write_io 0x2E
  {} { ... }` with `$::wp_last_value`.
- Site the diag at `TagTableTag.open` entry, `TagTd` entry (col,
  CellStartX, CellEndX), `EmitRaw .erDrop` entry, and at
  `PrintFileContent.eof` (ScrollLine + HtmlLineCount low bytes).
- Sample TCL skeleton (delete after diag run):

  ```tcl
  set ::fh [open "/tmp/diag.txt" "w"]
  set ::state idle; set ::buf [list]
  proc on_write {v} {
    if {$v == 0xAA} { set ::state cap; set ::buf [list]; return }
    if {$v == 0xBB} {
      if {$::state == "cap"} { puts $::fh $::buf; flush $::fh }
      set ::state idle; return
    }
    if {$::state == "cap"} { lappend ::buf $v }
  }
  debug set_watchpoint write_io 0x2E {} {
    if {[info exists ::wp_last_value]} { on_write $::wp_last_value }
  }
  ```

- Past diag scripts are gone (reverted). Recreate as needed in
  `tools/diag_*.tcl` — they're never committed.

### 6. Key code locations (`src/mwbrowser.asm`)

| Symbol / region | Approx line | What |
|-----------------|-------------|------|
| `PrintFileContent` | 4759 | Render entry; resets parser state, sets `HtmlEnd`, walks `FileBuf`. |
| Reset block | 4780–4860 | Zeroes parser globals. Add ResumeTable prime here, after `.pfcNoRestore`. |
| `.pfcNoRestore` | 4859 | Where `PendingRestoreSlot` (post-slide cache restore) is consumed. Insert mid-table prime just below this. |
| `.pfcNoFastFwd` | 4958 | LineCache fast-forward that may jump `HL` into FileBuf at a cached doc-offset. Sets `HtmlLineSkip = ScrollLine - cached_line`. |
| `EmitRaw` | 5617 | Per-glyph cell-edge clip (`.erDrop`) + canvas-edge SmartWrap (`.erCanvasWrap`). |
| `.erDrop` | 5647 | Where in-cell glyphs past `CellEndX - 6` are dropped. |
| `SmartWrap` | 6735 | Breaks `LineBuf` at last space, calls `EmitNewline`, re-emits tail. |
| `EmitNewline` | 6832 | `LineFlush` + `HtmlLineCount++` + `HtmlLineSkip--` (or `TextY +=` row pitch). |
| `IsLineCacheStateSafe` | 7141 | Only allows snapshot when `HtmlInTable == 0`. |
| `LineCacheSnapshot` | 7184 | Captures `ScaleY/ListKind/OlCounter/Indent/Align/Dir/Fg/DefAlign+DefDir`. NOT `HtmlInTable`. |
| `LineCacheRestore` | 7242 | Restores the 8 fields above. |
| `TagTableTag` | 11561 | `<table>` open/close. `MeasureTableCols + SetTableColLayout` here. ResumeTable snapshot goes after these. |
| `TagTr` | 11630 | Row close (`.close`) + new row (`.newRow`). |
| `CountTableRow` | 11605 | `HtmlLineCount += 1`, `HtmlLineSkip -= 1`. Bump to 2 if you want per-row pixel-cost match. |
| `TagTd` | 11696 | Sets `CellStartX/CellEndX/TextX` from `TableColStartXPtr/EndXPtr[HtmlTableCol]`, increments `HtmlTableCol`. |
| `FlushPendingCell` | 11810 | Drains `LineBuf` at `CellStartX` (LTR) or `CellEndX - LineLen*8` (RTL). |
| `SetTableColLayout` | 12051 | Points `TableColStartXPtr / TableColEndXPtr` at `TblLayout<ColCount>`. |
| `MeasureTableCols` | 12059 | Forward-scans from `ParserCursor` for `<td>/<th>` count in first `<tr>`. Walks until `</tr>`/`</table>`/EOF. |
| `TblLayout3` | 12029 | 3-col layout: starts `12,168,324`, ends `164,320,480`. (Hard-coded; auto-layout isn't implemented.) |
| `TableColStartXPtr` / `TableColEndXPtr` | 12045 | Live layout pointers. Default to `TblLayout5` so degenerate paths still render. |
| `PageDown` | 15245 | `.pdAtMax` → `.pdMaybeFetch` → `.pdLocalSlide` on local files at end-of-buffer. |
| `SlideForwardLocal` | 15449 | Sets `SlideTarget = DocOffset + WindowLen`, calls `SlideAlignTarget` (cache-align), then `EnsureWindowLocal`. Resets `ScrollLine = 0` post-slide. |
| `LineCacheReset` | 7302 | Called by `EnsureWindowLocal` (slide invalidates cache). |

### 7. Constants / layout numbers

- `CONTENT_Y0` = 29, `CONTENT_Y1` = 211 → 183-px content area.
- `WIDTH` = 512 px (Screen 6), `CONTENT_X_END+1` = 492 px → 123 byte-cols.
- `TEXT_MAX_LINES` = 22, `TEXT_LINE_H` = 8, `TABLE_ROW_GAP` = 2.
- `PAGE_SCROLL_STEP` = `TEXT_MAX_LINES - 1` = 21.
- `FILE_BUF_SIZE` = 0x1800 = 6144 B.
- `TABLE_LEFT_PX` = 12, `TABLE_RIGHT_PX` = 480.
- `TblLayout3` (3 columns): starts `12, 168, 324`; ends `164, 320, 480`.

## Recommended next-session plan

1. **Instrument and observe before patching.** Put back diag at
   `TagTableTag.open`, `TagTd`, `PrintFileContent.eof`, and a "did
   slide fire?" stamp around `SlideForwardLocal`. Run shot_benchtx.
   Capture: (a) does slide fire between page 7 and page 8?
   (b) what doc-offset does slide land at?  (c) is `TagTableTag.open`
   reached on page 8's render?  (d) at `TagTd` for the broken row,
   what are `HtmlTableCol`, `CellStartX`, `CellEndX`?
2. **Branch on findings:**
   - If slide fires AND lands past `<table>`: implement ResumeTable
     prime exactly as described in §3 above. Run the suite, confirm
     the regression you hit (shifted cells on page 8) doesn't return.
     If it does, the next layer to investigate is `LineCache
     fast-forward` (line 4892) — it may need to be inhibited when
     mid-table-prime activates, because cached entries from this
     render's earlier path may not be valid for the primed-state
     parser walk.
   - If slide DOESN'T fire (skip exhausts mid-table in original
     window): implement atomic table skip — at `TagTableTag.open`,
     count remaining rows, compute `cost`, clamp `HtmlLineSkip = 0` if
     `cost > skip`, OR seek past `</table>` if `cost <= skip`. (Either
     render whole or skip whole.)
3. **Verify against `tbl1.htm` + `tbl2.htm`** (recreate from appendix
   below if needed) to make sure standalone-table and small-doc-with-
   table cases still render correctly.
4. **Intra-cell wrap is task 2 — keep it for AFTER task 1 lands.** It's
   a separate, larger feature: per-cell wrap counter (5 bytes BSS for
   up to 5 cols), row-max-wrap accumulator, `</tr>` advances `TextY`
   by `(max_wrap + 1) * TEXT_LINE_H`, `CountTableRow` adds `max_wrap +
   1` to `HtmlLineCount`, `EmitRaw .erDrop` becomes "cell-edge
   SmartWrap": flush current `LineBuf` at `CellStartX`/current TextY,
   advance TextY by `TEXT_LINE_H`, reset TextX to `CellStartX`,
   continue appending to fresh `LineBuf`. Vertical borders already
   extend full table height via `DrawTableVerticals` so they don't need
   per-row segmentation.

## What to NOT do

- **Don't change `CountTableRow` to +2** as a blanket fix. It shifts
  `ScrollLine` clamp but doesn't fix the visible rendering, and it
  changes scroll math for every table in every doc.
- **Don't reintroduce flavor-A** (skipping PrerenderNext for local
  files). The user reverted it twice. Original diagnosis was wrong.
- **Don't run a project-wide find/replace on `ld a, N`-style
  immediates.** Commit `91b9011`'s sed-replace damage cost ~99 commits
  of regressions; the CLAUDE.md explicitly warns against this.
- **Don't put `<title>`-detection logic into the loose `<T?` matcher.**
  The strict `ClassifyT2nd` (A/R/D/H/B/F only) is the right shape.

## Appendix: minimal test samples

Recreate these in `samples/` if needed for regression testing. They
were experimental this session and aren't committed.

`samples/tbl1.htm` — standalone table, fits in one buffer, no slide:

```html
<html><body>
<table border="1" cellpadding="2">
<tr><th>Field</th><th>Value</th><th>Note</th></tr>
<tr><td>ligature</td><td>955</td><td>Bridge pixel viewport form.</td></tr>
<tr><td>table</td><td>467</td><td>Layout hmmm dither line layout page.</td></tr>
<tr><td>dither</td><td>348</td><td>Chunk msx ligature viewport palette join.</td></tr>
</table>
</body></html>
```

`samples/tbl2.htm` — 5 short paragraphs + the same table + trailing
paragraph. Forces the table onto page 2 of the rendering but stays
under `FILE_BUF_SIZE` so no slide:

```html
<html><body>
<h2>Leading content</h2>
<p>Line one of paragraph one filler text filler text filler text filler text filler text filler text filler text.</p>
<p>Line two of paragraph two filler text filler text filler text filler text filler text filler text filler text.</p>
<p>Line three of paragraph three filler text filler text filler text filler text filler text filler text filler text.</p>
<p>Line four of paragraph four filler text filler text filler text filler text filler text filler text filler text.</p>
<p>Line five of paragraph five filler text filler text filler text filler text filler text filler text filler text.</p>
<table border="1" cellpadding="2">
<tr><th>Field</th><th>Value</th><th>Note</th></tr>
<tr><td>ligature</td><td>955</td><td>Bridge pixel viewport form.</td></tr>
<tr><td>table</td><td>467</td><td>Layout hmmm dither line layout page.</td></tr>
<tr><td>dither</td><td>348</td><td>Chunk msx ligature viewport palette join.</td></tr>
</table>
<p>After-table text alpha bravo charlie.</p>
</body></html>
```

Companion shot scripts:

`tools/shot_tbl1.tcl`:

```tcl
proc shot {label} {
    screenshot -raw -size 640 -prefix /tmp/vwr-tbl1-${label}-
}
after time 30 { type "\x0c" }
after time 31 { type "A:TBL1.HTM\r" }
after time 50 { shot p1 }
after time 52 { exit }
```

`tools/shot_tbl2.tcl`:

```tcl
proc shot {label} {
    screenshot -raw -size 640 -prefix /tmp/vwr-tbl2-${label}-
}
after time 30 { type "\x0c" }
after time 31 { type "A:TBL2.HTM\r" }
after time 50 { shot p1 }
after time 52 { type " " }
after time 62 { shot p2 }
after time 64 { type " " }
after time 74 { shot p3 }
after time 76 { exit }
```

Disk slot pressure: `inject.sh` doesn't auto-ship `tbl1.htm`/`tbl2.htm`.
Add `mcopy ... samples/tbl1.htm ::/TBL1.HTM` lines, or just
`mcopy -i "MSX-DOS/MSX-DOS v1.03.DSK" -o samples/tbl1.htm ::/TBL1.HTM`
manually before the test. If the floppy is full, `mdel` an unused
file first.
