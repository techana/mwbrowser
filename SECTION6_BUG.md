# Section 6 stuck / garbage -- resolved

The "section 6 cuts off at 'Tra', second Space repaints with glyph
soup" repro turned out to be unrelated to LineCache state (the
previous-session hypothesis pointed at `PendingRestoreSlot` /
stale snapshot bytes). The real cause was upstream of the parser.

## Root cause

`<img src="MSXCOMP.SC6">` and friends reuse the same `Fcb` the
document was opened with -- `ImgStreamOpenName` -> `BuildFcbFromHL`
overwrites the FCB filename bytes with `ImgNameBuf`. After
chunk-1's section-2 image streams in, `Fcb` points at
`MSXCOMP.SC6`, not `STORY.HTM`.

`EnsureWindowLocal.ewlSlide`'s reopen sequence was just
`ResetFcbTail` + `DOS_OPEN`, so the chunk-1 -> chunk-2 slide reopened
the image file. `LoadFileChunk` then read 4100 bytes of Screen-6
pixel data from offset 6144 into `FileBuf`, and the parser walked
those bitmap bytes as HTML -- producing the repeated `**(J*` /
`[ @ é ]` glyph pattern that's literally the byte content of
`MSXCOMP.SC6[6144..]`.

## Fix

`EnsureWindowLocal.ewlSlide` now calls `BuildFcbFromUrl` (UrlBuf
still holds the doc URL; `<img>` loads write `ImgNameBuf`, not
`UrlBuf`) before the `DOS_OPEN`. Covers both
`SlideForwardLocal` and `SlideBackwardLocal` (shared code).

## What the earlier hypothesis got wrong

Once the FCB is restored, the trace shows `SlideAlignTarget` /
`PendingRestoreSlot` / `LineCacheLookupLine` are not on the failure
path -- the slide loads the right bytes and the parser walks the
right text. There IS a separate latent bug in `Cmp24`: its `Z` flag
reflects only the high-byte subtract, not whole-value equality, so
`LineCacheLookupOffset`'s "slot == best" check wrongly rejects every
chunk-1 slot in the common case (all hi bytes 0). That leaves the
Phase-7 cross-slide cache alignment effectively dead, but doesn't
cause the visible glyph soup. Worth a separate fix the next time
that path is exercised.
