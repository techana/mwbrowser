# Section 6 stuck / garbage — investigation handoff

## What's already fixed this session

| File | Change | Why |
|---|---|---|
| `src/mwbrowser.asm` `TagUl` / `TagOl` / `TagBlockquote` open | Set `HtmlListKind`/`HtmlIndent` BEFORE `EmitBlankLine` | Snapshot taken by `EmitBlankLine→EmitNewline→LineCacheMaybeAppend` now matches its own `doc_offset` (which already points past the `<ul>`); previously the slot stored `HtmlIndent=0` and a later scrolled render's `</ul>` did `sub 16` → `0xF0` underflow → "section 3 list collapses into a narrow right column" |
| `tools/web_bridge.py:4173` | `<h1>` → `<h2>` for the bridge root path heading | user-requested |
| `tools/root/MSX_Story.htm` | + 6–7 page essay; section 7 rewritten in Arabic / RTL (ISO-8859-6 bytes via `tools/patch_msx_story_ar.py`); `<meta http-equiv="Content-Type" content="text/html; charset=ISO-8859-6">` added | user-requested |
| `tools/root/MSXCOMP.SC6` | new — stylized home computer line-drawing rendered via `tools/gen_msx_computer.py` → `png_to_sc6.py` | image for section 2 of the essay |

These changes are unstaged in the worktree.

## What's still broken (issues 3 + 4 in the user's report)

The user's screenshots: `/Users/mans/.openMSX/screenshots/scrolbar_thump_sec6.png` (stuck) and `/Users/mans/.openMSX/screenshots/total_garbage_after_sec6.png` (garbage).

Reproduced post-fix at `/tmp/vwr-s62-p09-0001.png` (stuck at "inside the game ROM. Tra"), `p10` (identical — first Space no-op), `p11` (full glyph-soup garbage on second Space). Same TCL harness: `tools/dbg_sec6.tcl` + `MSX-DOS/MSX-DOS v1.03.DSK` (which already has the right `MWBRO.COM` + `STORY.HTM` + `MSXLOGO.SC6` + `MSXCOMP.SC6` + `SAKHR.SC6`).

## What the trace shows

`/tmp/sec6_trace2.log` watches every write to `ScrollLine` (0x63F4), `TotalLines` (0x63F6), `DocLinesBefore` (0x63F8), `HtmlLineCount` (0x6446) and snaps the full scroll-state tuple at each. Filtered around the slide:

```
135.93 ScrollLow=0     SL=0   TL=370  DLB=185  HLC=185      ← pdLocalSlide after CF=0 slide
                                                                from chunk 1 → chunk 2; DLB just bumped
                                                                by chunk-1 HLC=185
140.38 TotalLow=255    SL=0   TL=511→255  DLB=185  HLC=70   ← Extrapolate after chunk 2's full
                                                                walk: ratio=1, TL = DLB+HLC = 255
140.42 ScrollLow=21    SL=21  TL=255  DLB=185  HLC=70       ← PrerenderNext sets candidate=21
                                                                (=0 + PAGE_SCROLL_STEP); PFC then
                                                                renders SL=21 onto the back page
143.77 ScrollLow=0     SL=0   TL=255  DLB=185  HLC=70       ← PrerenderNext.pnSkipMark restore
                                                                (PrerenderSaved.ScrollLine=0)
143.78 ScrollLow=21    SL=21  TL=255  DLB=185  HLC=70       ← user's queued Space @142s finally
                                                                processed: PageDown.pdStore SL=0→21
143.81 ScrollLow=42    SL=42  TL=255  DLB=185  HLC=70       ← next PrerenderNext: candidate=42
146.90 ScrollLow=21    SL=21  TL=255  DLB=185  HLC=70       ← that prerender's restore
```

State math is internally consistent — `TotalLines=255 = DocLinesBefore(185) + HtmlLineCount(70)`. The arithmetic is fine.

## Where the garbage comes from (working hypothesis)

The fast-path flip in `RefreshAfterScroll` (asm line 15187) requires `PrerenderValid=1` AND `PrerenderScrollLine == ScrollLine`. When the user's Space lands and PageDown bumps SL to 21, both hold → atomic VDP-page swap to the back page, which contains whatever the prerender PFC drew there. That's what the user sees in p11.

So the garbage IS the prerender PFC's output at SL=21 of chunk 2. The question is why the same SL=21 walk that works on the foreground (we see it briefly at p10, which is at SL=0 of chunk 2 = section 5 tail + section 6 first paragraph cut at "Tra") produces glyph-soup on the back.

The bullet-shaped chars in the garbage (`*`, `**`, `(J*`, `**a`) strongly suggest `EmitListBullet` firing repeatedly on bytes that weren't `<li>` — i.e., the parser walked through stale state where `HtmlLiPending` keeps re-arming, OR mistreats a long run of bytes as list items.

`PrerenderSaved` (BSS line 15481) only stows 5 fields: `ScrollLine`, `HtmlLineCount`, `TotalLines`, `HtmlLineCountSaved`, `HtmlLineCountAccurate`. It does NOT save `HtmlIndent` / `HtmlListKind` / `HtmlOlCounter` / `HtmlScaleX` / `HtmlScaleY` / `HtmlDir` / `HtmlAlign` / `HtmlFg` / `HtmlLiPending`. These are stomped fresh by every PFC's reset block (asm 4893–4962), so the OUTGOING leak isn't the problem — but the prerender PFC's reset runs and then `LineCacheRestore` is allowed to fire from `PendingRestoreSlot` or `LineCacheLookupLine`'s match, both of which can overwrite the reset defaults with whatever a cached slot stored. That's the same surface as issue #2, just now in the prerender path with a cache that the slide-forward only *partially* invalidated (count is reset to 0 in `LineCacheReset` at asm 4807, but the slot bytes are NOT zeroed — comment at asm 4981 explicitly says they survive because `PendingRestoreSlot` is supposed to read them post-slide).

So the next-session bet:

> A chunk-1 snapshot's bytes still live at `LineCacheState[slot*8]`. After the slide to chunk 2, the prerender PFC's reset wipes parser state to defaults, then either `PendingRestoreSlot != 0xFF` (set by `SlideAlignTarget` from chunk-1 cache) or `LineCacheLookupLine` returns a stale chunk-1 entry whose `doc_offset` is now nonsensical relative to chunk 2's `DocOffset=6144`. Either path calls `LineCacheRestore` which loads chunk-1 state bytes (HtmlListKind=1, HtmlIndent=16, etc.) onto the parser, and then HL is computed as `FileBuf + (cached_doc_off - DocOffset)` which underflows (chunk-1 offsets are now < DocOffset), pointing HL into the BSS / VRAM mirror / font area. The parser walks that, finds incidental `<li>` patterns, emits bullets.

To confirm, the next instrumentation step is:

1. Watch `PendingRestoreSlot` (find its address via `dist/mwbro.sym`) and log every read + write across the chunk-2 prerender at SL=21.
2. Watch `LineCacheCount` to confirm it's 0 going into the prerender's lookup.
3. Watch the value of HL passed to `LineCacheRestore` (PC=`0x237C`) — if it's the slot index 0..15, fine; the issue is what gets read.
4. After the prerender's `PFC` reset, snap `HtmlIndent`/`HtmlListKind`/`HtmlScaleY`/`HtmlAlign`/`HtmlDir` and compare against what `LineCacheRestore` writes a few µs later.

If the hypothesis holds, the fix is either:
- (a) `EnsureWindowLocal`'s `.ewlSlide` path: after `LineCacheReset`, also zero the byte arrays (`LineCacheState`, `LineCacheLineNo`, `LineCacheDocOff`) so a stale `PendingRestoreSlot` reads zeros (== safe defaults) instead of chunk-1 leftovers. Cheap — three `ld bc, N` + `ldir` blocks.
- (b) Same path: explicitly `xor a; ld [PendingRestoreSlot], a` (note: 0 ≠ 0xFF; the right invalidation is `ld a, 0xFF; ld [PendingRestoreSlot], a`) BEFORE returning so PFC's `PendingRestoreSlot != 0xFF` check short-circuits cleanly.
- (c) Make `LineCacheLookupLine` validate the slot's `doc_offset` against `[DocOffset, DocOffset+WindowLen)` and reject mismatches — defends against any stale read, not just post-slide.

Likely combine (b) for the invalidation hygiene with (c) for the defense in depth.

## Reproduction one-liner

```bash
cd .claude/worktrees/exciting-bouman-5900e1
tools/build.sh && \
  DISK="MSX-DOS/MSX-DOS v1.03.DSK"; chmod u+w "$DISK"; \
  mcopy -i "$DISK" -o dist/mwbro.com ::/MWBRO.COM && \
  /Applications/openMSX.app/Contents/MacOS/openmsx \
    -machine Al_Alamiah_AX370 \
    -diska "$DISK" \
    -script tools/dbg_sec6.tcl
# wait ~150s emulated (~90s wall); check /tmp/vwr-s62-*.png and /tmp/sec6_trace2.log
```

## Open question for the user

The TCL harness assumed Space presses were processed immediately. The trace shows the user's Space @ time 132s wasn't seen by `PageDown.pdStore` until 143.78s — the prior render + prerender PFC took ~10 emulated seconds and keystrokes queued. On real-hardware AX-370 with a serial bridge this is probably visible as a noticeable lag; worth confirming with the user that they're seeing the same dead-key behavior they describe ("Press Space scroll down 1 line"), or whether it's specifically the second press they meant — the screenshots match "second Space causes garbage" cleanly.
