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

## Status

Branch live, design doc committed. Phase 1 is the next code commit.
