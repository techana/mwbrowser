# File-load architecture redesign

**Branch:** `file_load_architecture`. Tracks a multi-session refactor that
replaces the "load whole file into FileBuf, truncate at `FILE_BUF_SIZE`"
model with a streamed/chunked one. Document is the design plan; code
lands in subsequent commits on this branch.

## Why

`FILE_BUF_SIZE` is 14 KB after `fix_char_corruption` (down from 24 KB,
because runtime constraints below MSX-DOS HIMEM and the .COM stack
forced FileBuf into a 14 KB window). Any document larger than 14 KB
gets silently truncated. Wikipedia articles, long forum threads, our
own `BENCHTX` test pages — all hit this.

The current code has two file-load paths and both treat `FileBuf` as
the whole document:

- **Local (`LoadFile`):** opens via `BDOS_OPEN`, reads up to
  `FILE_BUF_SIZE / 128` records sequentially with `BDOS_READ` into
  `FileBuf` at offset 0…+128…+256… Truncates and forgets the rest.
- **Remote (`RemoteLoadFile` + `TryFetchMore`):** receives `OK HTM
  <len> <p>/<t>` chunks from the bridge, writes each chunk's bytes to
  `FileBuf[FileLen]…FileBuf[FileLen+chunk_len]`, bumps `FileLen`.
  Stops appending when the next chunk wouldn't fit; returns `CF=1` so
  scrolling past that point is silently capped.

Both assume the parser will eventually walk `FileBuf[0..FileLen)` from
byte 0. That assumption is what we need to break.

## Constraints

- **Physical `FileBuf` stays bounded** at the current ~14 KB — anything
  bigger collides with FontBuf, ImgBuf, the .COM stack, or DOS
  HIMEM scratch. The fix-char-corruption commit explains the bounds in
  detail.
- **Parser cannot easily restart from an arbitrary byte offset** without
  a parser-state snapshot — that's the same wall that Task B (layout-
  offset cache) hit in `optimization_round_1`. So redesigning streaming
  *and* solving Task B are entangled.
- **Local files** support random-record I/O via `BDOS_RDRND` (function
  `0x21`) with the FCB's random-record field. So we can read any 128-
  byte sector of the file on demand.
- **Bridge protocol** already supports `GET MORE` for sequential chunks.
  Adding "fetch chunk M" would need a new bridge-side command (not yet
  designed) — incremental over what exists.

## Design — "Sliding window with restart cache"

### Conceptual model

The document has a logical byte offset `0..N-1` where `N` is the full
document size. `FileBuf` holds a sliding *window* of that document:

```
        DocOffset                  DocOffset + WindowLen
            |                              |
            v                              v
            [..........FileBuf..........](14 KB)
            ^
            FileBuf[0] = document byte at DocOffset
```

- `DocOffset` is the document offset of `FileBuf[0]`.
- `WindowLen` is how many of the 14 KB are populated.
- `DocSize` is the total document size (known after the open / first
  HTM frame).

### Parser-side changes

`PrintFileContent` currently walks `FileBuf[0..FileLen)`. New
contract:

- Parser walks `FileBuf[0..WindowLen)`.
- When scroll math wants to start at line `N` and there's no cached
  restart point inside the current window, the loader **slides the
  window** so that line `N` lands inside it.
- The parser uses cached `(line, doc_offset, parser_state)` entries
  (Task B's deferred work) to know where to restart in `FileBuf` after
  a slide.

### Loader-side changes

A new `EnsureWindow(doc_offset)` primitive:

1. If `doc_offset` is already inside `[DocOffset, DocOffset+WindowLen)`,
   no-op.
2. Else, evict / shift bytes in `FileBuf` so `doc_offset` lands in the
   window. Strategy:
   - **Forward scroll** (target > current window): drop the oldest part
     of `FileBuf`, shift the rest left, fetch new bytes from offset
     `DocOffset+WindowLen` until the window covers `doc_offset`.
   - **Backward scroll**: drop the newest part, shift right, fetch
     bytes ending at `DocOffset` (so the window now ends at the old
     start). Backward fetch needs random-record I/O for local files
     and a new `GET CHUNK <offset>` command for the bridge.

For local files, `EnsureWindow` becomes a `BDOS_RDRND`-driven loop. For
bridge files, it's a `GET CHUNK` (new command) or fall back to
"reload from start" (slow but correct).

### Restart-point cache (revives deferred Task B)

A small array of `(rendered_line_no, doc_offset, parser_state)` entries
captured at "safe" boundaries during the initial render. On scroll:

1. Find the entry with the largest `rendered_line_no` ≤ target.
2. `EnsureWindow(entry.doc_offset)`.
3. Restore parser state from `entry.parser_state`.
4. Resume the parser at `FileBuf[entry.doc_offset - DocOffset]`.

The "safe parser state" needs to be properly snapshotted this time —
that was the wall in Task B. Likely 30–60 bytes per entry; with 30
entries we're at ~1.5 KB of cache RAM (vs the 1 KB FileBuf reduction
that's freed by no longer needing 14 KB of contiguous file data —
a wash).

## Phased implementation

This is multi-session work. Commits land one phase at a time:

### Phase 1 — Storage abstraction (1 commit)

- Introduce `DocOffset` and `WindowLen` globals; rename `FileLen` →
  `WindowLen` for clarity (or alias).
- `HtmlEnd = FileBuf + WindowLen`.
- All sites that read `FileLen` become `WindowLen`.
- Loader still does whole-file load (no semantic change yet); but now
  `WindowLen` is the working set, not file size. Sets the stage for
  later phases.

### Phase 2 — Local random-record fetch (1 commit)

- Add `BDOS_RDRND` (`0x21`) wrapper.
- New `LoadFileChunk(doc_offset, byte_count) -> WindowLen` primitive
  that fills `FileBuf` from `doc_offset`. Uses random-record math:
  `record = doc_offset / 128`, sector remainder is offset within
  the first read.
- `LoadFile` becomes `LoadFileChunk(0, FILE_BUF_SIZE)` initially —
  same observable behaviour as today.

### Phase 3 — Restart-point cache during initial render (1 commit)

- `LineCache` array (line# → doc_offset) populated by `LineFlush` at
  block-tag boundaries (the safe-state predicate from `optimization_
  round_1`'s deferred Task B).
- Cache stays empty by default; populate only when `HtmlLineSkip == 0`
  (the initial-render pass).
- Cache invalidated by `LoadFile` and any in-place form edit.

### Phase 4 — Parser-state snapshot (1–2 commits)

- Pack the live parser state (`HtmlScaleY`, `HtmlStyleFlags`,
  `HtmlInTable`, `HtmlAlign`, `HtmlIndent`, `HtmlListKind`, ar buffer
  state, etc.) into a fixed-size struct.
- Snapshot at cache-population sites; restore at cache-jump sites.
- This is the part Task B couldn't get right last time. Land it
  *after* Phase 3 so we can verify against actual cached offsets
  before adding the complication.

### Phase 5 — Sliding window (1 commit)

- `EnsureWindow(target_doc_offset)` for scroll handlers.
- Update scroll dispatch (`PageDown`, `ScrollDown`, etc.) to call
  `EnsureWindow` before re-rendering.
- Cache lookup decides target_doc_offset; loader fetches.

### Phase 6 — Bridge `GET CHUNK <offset>` command (1 commit, web_bridge.py
+ MSX side)

- Bridge: serve a specific byte range of the cached document on
  request. Requires keeping the full document around bridge-side
  (instead of streaming it once and discarding).
- MSX: `EnsureWindow` fallback path uses `GET CHUNK` for remote pages.

### Phase 7 — Validation (1 commit)

- Wikipedia article (50+ KB) loads and scrolls cleanly.
- BENCHTX/BENCHIM render unchanged.
- Backward scroll across a window boundary works.
- `BENCHMARKS.md` gets a "post-streaming" column.

## What this does NOT solve

- **Random in-page seek** (anchor links, `#section` URLs) — same problem
  as scroll, would use the same primitive once we have it.
- **Form post-back** — already handled by re-fetching the page; no
  change.
- **Image loading mid-document** — already streams via `ImgStream`,
  unaffected.

## Risk register

- **Phase 4 (parser-state snapshot)** is the highest risk; if we can't
  snapshot/restore correctly, the whole sliding-window scheme collapses
  back to "scroll from doc start". Mitigation: ship Phase 1–3 first as
  pure plumbing wins (local random-record support) so the partial
  refactor still has value if Phase 4 is hard.
- **Bridge `GET CHUNK` requires bridge-side state**: the bridge has to
  keep the document around between requests. The current bridge
  discards after streaming. Phase 6 needs a small per-session cache
  on the bridge side.
- **Backward fetch on local files** is slow if it forces a re-seek and
  re-read every time (BDOS file I/O isn't fast). Mitigation: keep
  *some* of the prior window in `FileBuf` after a forward slide, so
  small backward scrolls don't trigger fetch.

## Bridge ↔ browser pagination (already implemented; preserve through phases)

The remote-load path already has a streaming protocol that runs in
parallel to (and pre-dates) this design doc. The sliding-window work
must not regress it.

**Bridge side (`tools/web_bridge.py`):**

- `_serial_split_into_chunks(body)` mirrors the on-MSX renderer's
  pixel-driven block-end advances: every `</p>`, `</tr>`, `<br>`,
  `</li>`, `</hN>`, `</div>`, `</center>` advances a virtual TextY
  (8 px standard, 10 px for `</tr>`, doubled inside `<h1>`/`<h2>`),
  and a text run that wraps past 60 chars spills onto another line.
  When `used_px >= 175 px` the chunk cuts at the last safe block
  boundary. Falls back to `MAX_CHUNK_BYTES + last '>'` for pages
  with no usable line markers.
- `MsxSession.serve(url)` builds the body, splits into chunks, stores
  `pending_chunks`, sets `page_total = len(chunks)`.
- First `GET <url>` and subsequent `GET MORE` invocations consume
  chunks one at a time via `_serve_next_chunk()`, returning
  `("HTMP", (chunk_bytes, page_served, page_total))`.
- `_serial_send_response` formats the wire header:
    - `OK HTM <bytes> <page>/<total>\r\n` if `total > 1`
    - `OK HTM <bytes>\r\n` if `total == 1` (legacy single-frame format)

**Browser side (`src/mwbrowser.asm`):**

- `RemoteGet` parses the bytes count, then on space it parses
  `<page>/<total>` into `SerialPage` and `SerialPageTotal`. On bare
  CRLF it defaults both to 2 so `remaining = total - page == 0`
  collapses to "no more chunks" cleanly.
- `RemoteLoadFile` drains the first chunk's body into FileBuf, sets
  `WindowLen = chunk_size`, then renders.
- `StoreTotalLinesWithPages` runs after every render that follows a
  remote fetch. It computes
  `TotalLines = HtmlLineCount + (SerialPageTotal - SerialPage) * TEXT_MAX_LINES`,
  i.e. extends the rendered line count with a 22-line-per-pending-chunk
  estimate. `ComputeThumb` then sizes the scrollbar against the
  *full* document so the user sees the document's true size before
  the trailing chunks have actually been fetched.
- `TryFetchMore` fires when scroll dispatch crosses past the current
  WindowLen on a remote session. Sends `GET MORE\r\n`, appends the
  next chunk to FileBuf at the current `WindowLen`, bumps
  `WindowLen += SerialLen`, and re-runs `StoreTotalLinesWithPages`
  so the thumb proportions catch up.
- `TryFetchMore` refuses to append when the chunk wouldn't fit
  (drains the wire to keep the bridge in sync, sets `TfmRefused=2`)
  rather than corrupting FileBuf with a partial frame. Today this
  hard-stops scroll at the FILE_BUF_SIZE boundary; Phase 5 will
  replace the refusal with a "slide the window forward by one chunk"
  eviction so MORE can keep flowing.

**Phase compatibility checklist:**

- Phases 1–3 are bridge-transparent: `WindowLen` rename matches the
  field TryFetchMore already wrote, `LoadFileChunk` is local-only,
  `LineCacheReset` fires at the top of `RemoteLoadFile` so a fresh
  remote document invalidates the cache.
- Phase 4 (parser-state snapshot) is also bridge-transparent — it
  only changes what `LineCacheMaybeAppend` stores, not when.
- **Phase 5 has to interact with TryFetchMore**: today TryFetchMore
  appends to a fixed FileBuf and refuses overflow; Phase 5's
  EnsureWindow needs to evict the oldest portion of FileBuf when a
  new chunk arrives, OR teach TryFetchMore to call EnsureWindow
  before appending. The bridge protocol itself doesn't change.
- Phase 6 (`GET CHUNK <offset>`) is additive on the bridge side: the
  current `MsxSession` already keeps `pending_chunks` for `GET MORE`;
  add an offset-indexed cache so the MSX can ask for "the chunk
  containing doc byte N" for backward-scroll fetches that the
  forward-only `GET MORE` can't satisfy.
- Phase 7 should benchmark a multi-chunk wiki page (`page_total >= 5`)
  to confirm pagination + sliding-window cooperate correctly.

## Status

**Phases 1–7 shipped on `file_load_architecture`.**

| Phase | Status | What it delivered |
|---|---|---|
| 1 | ✅ committed | `WindowLen` rename + `DocOffset` global. Pure plumbing. |
| 2 | ✅ committed | `LoadFileChunk(doc_offset, byte_count)` + `DOS_RDRND` wrapper. |
| 3 | ✅ committed | `LineCache` 32-slot (line_no, doc_offset) cache; populated at every `EmitNewline` during initial render; reset at every load. |
| 4 | ✅ committed | `LineCacheSnapshot` / `LineCacheRestore` + `IsLineCacheStateSafe` predicate. Snapshot half wired into the cache append; restore half built but no live caller yet. |
| 5 | ✅ committed | `EnsureWindowLocal` + `SlideForwardLocal`. PageDown / ScrollDown's `.pdMaybeFetch` slide forward for local docs > 13 KB. Verified on a 30 KB synthetic fixture. |
| 6 | ✅ committed | Bridge `GET CHUNK <offset>` + on-MSX `EnsureWindowRemote` + `Format5Decimal`. Plumbing-only. |
| 7 | ✅ committed | `SlideForwardRemote` wired into PageDown / ScrollDown's remote path. Phase 6's primitive now has live callers; multi-chunk remote pages can keep streaming after `TryFetchMore` exhausts. |

**Memory budget after Phase 7:**

| | Value |
|---|---|
| FILEBUF_BASE | 0x9900 |
| FILE_BUF_SIZE | 0x3300 (12.75 KB) |
| FontBuf | 0xCC00 |
| ImgBuf | 0xD400 |
| ImgBuf+128 cap | 0xD480 (≤ 0xD500 ✓) |

**Status updates (commits ad8904d..1a0ab98 + 720c822 + 97c2307):**

- ✅ **Cross-chunk render glitch fixed** — `SlideAlignTarget` now snaps the slide target to the closest cached safe boundary (`LineCacheLookupOffset`) and `PendingRestoreSlot` carries the slot through to `PrintFileContent`'s post-reset hook, where `LineCacheRestore` rebuilds the persistent parser state. (Commit `f81552d`.)
- ✅ **Backward slide shipped** — `ScrollUp` / `PageUp` at `ScrollLine == 0` of a non-zero-`DocOffset` window now triggers `SlideBackward{Local,Remote}` and lands the viewport at the *bottom* of the previous window (continuity with where the user was). 2-pass render needed because the new window's `HtmlLineCount` is unknown at slide time. (Commit `1a0ab98`.)
- ✅ **EI/HALT bug fixed (separate from this branch's scope)** — bare `halt` in MainLoop was hanging on HB-F700D / AX-370. Fix: canonical `ei / halt`. The whole "AX-370 ~15565 B TPA cap" theory in the original CLAUDE.md was a misdiagnosis. (Commit `ae55bb7`, see CLAUDE.md.)
- ✅ **17 KB shrink** — moved 44 inline `ds` reservations past `FileEnd:` so SAVEBIN doesn't carry their zero bytes. .COM 39 KB → 22 KB. Independent of the EI/HALT fix; smaller binaries are good hygiene. (Commit `ad8904d`.)
- ✅ **Cache eviction policy** — `LineCacheMaybeAppend` now uses ring-buffer eviction so the cache holds the **latest** 32 safe boundaries instead of the **first** 32. `SlideAlignTarget` snaps forward-slide targets to entries near the slide boundary instead of forcing the user to re-read from doc start. (Commit `97c2307`.)

**Still deferred:**

- **24-bit `DocOffset` / `DocSize` for docs > 64 KB.** Today both are 16-bit so docs cap at 64 KB. Wikipedia articles routinely run past that. The widening is mechanically straightforward but touches ~20 sites, with each requiring careful 16→24-bit upgrade. Storage was tentatively widened during the file_load_architecture session (`db 0,0,0` instead of `dw 0`) but reverted because the inline math sites stayed 16-bit and would have been a half-fix. **Inventory of sites to update when we pick this up:**

  Storage (already laid out, just toggle from `dw` to 3-byte `db`):
  - `DocOffset`, `DocSize`, `LcloTarget`, `LcloBestOff` in the runtime-RAM block.
  - `LineCacheDocOff: ds LineCacheMax * 2` → `ds LineCacheMax * 3` (+32 B RAM).

  Code (every `ld hl, [DocOffset]` / `ld [DocOffset], hl` becomes a 3-byte load/store):
  - `LoadFile` (DocSize from FCB+16, DocOffset = 0).
  - `LoadFileChunk` (`Fcb+33..35` random-record seed: 24-bit shift right 7 instead of 16-bit).
  - `RemoteLoadFile` (DocOffset = 0 init).
  - `EnsureWindowLocal` / `EnsureWindowRemote` (target compare; 24-bit no-op fast-path).
  - `SlideForwardLocal` / `SlideForwardRemote` (DocOffset+WindowLen vs DocSize).
  - `SlideBackwardLocal` / `SlideBackwardRemote` (DocOffset − FILE_BUF_SIZE, clamp at 0).
  - `SlideAlignTarget` (24-bit target passed down).
  - `LineCacheMaybeAppend` (24-bit doc_offset write per slot).
  - `LineCacheLookupOffset` (24-bit comparison loop using `LcloTarget` / `LcloBestOff`).

  Wire format:
  - `EnsureWindowRemote` builds `"CHUNK <decimal_offset>"` via `Format5Decimal` (5 digits, 99999 max). Replace with `Format6Hex` (24-bit → 6 hex digits + NUL, ~20 B). Bridge accepts hex via `int(target[6:].strip(), 16)`.

  Estimated cost: ~250 B of new MSX code + ~32 B RAM (LineCacheDocOff stride). Tight against the ImgBuf+128 ≤ 0xD500 cap — likely needs another `FILE_BUF_SIZE` shrink (0x3100 → 0x3000 or 0x2F00).

- **Live wiki bridge validation.** Local 30 KB BIGBENCH path is verified end-to-end via `tools/shot_slide_trace.tcl`. The remote slide path (TryFetchMore-refused → `SlideForwardRemote` → bridge `GET CHUNK`) is wired but has no automated test — needs a running `tools/web_bridge.py` against a real wiki article. Useful with the current 16-bit limit only for articles < 64 KB; full validation with long Featured Articles waits on the 24-bit widening above.
