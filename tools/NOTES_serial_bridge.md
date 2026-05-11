# Serial web bridge — status + handover

## What's working on `Serial_Comm`

### Python side (`tools/web_bridge.py`)

Complete + smoke-tested. Line-oriented protocol over TCP 127.0.0.1:2323:

```
MSX -> bridge:  GET <target>\r\n
bridge -> MSX:  OK HTM <length>\r\n<body>
                OK PCX <length>\r\n<body>
                ERR 404\r\n
                ERR 500\r\n
```

- `GET http://...` → Playwright render → PCX slices; returns HTM
  wrapper that the MSX browser renders as any other HTML page.
- `GET http://.../foo.jpg` (image URL) → download + on-the-fly PCX
  conversion → returns `OK PCX`.
- `GET pgNN.pcx` (bare name) → serves the cached chunk belonging to
  the most recently rendered page.
- Unknown target → `ERR 404`.

### MSX side (`src/mwbrowser.asm`, integrated)

- `LoadFile` dispatcher: URL starting with `<scheme>://` routes to
  the serial bridge; anything else opens a local file via MSX-DOS.
- `IsRemoteSession` flag propagates through the whole render so
  `<img src="pgNN.pcx">` tags in a bridge-served HTM also fetch via
  the UART.
- Parallel dispatchers on `ImgStreamOpenName`, `ImgStreamByte`,
  `ImgStreamRefill`, `ImgStreamClose`.
- **`SerialInit` at boot**: the cartridge ROM leaves the 8251
  receiver disabled; we write three dummy bytes, an Internal Reset,
  mode `0x4E` (8-N-1 ×16), and command `0x37` (RTS | ErrRst | RxEN |
  DTR | TxEN). Without this the first `in a,(0x81)` loop hangs
  forever.
- 404 path: previous 108-byte built-in HTML was replaced with a
  single-line `DrawString` call into a freshly cleared content area
  (-90 bytes). URL-load errors are expected to come back from the
  bridge as `ERR`; local-file errors display "404 File Not Found".

End-to-end verified:

- `MSX types http://example.com` → bridge receives `GET
  http://example.com` → responds `OK HTM 227\r\n<body>`.
- MSX parses the HTM, title bar updates to `Example Domain - MSX
  WBrowser`, `<img src="PG01.PCX">` tag fires.
- MSX sends `GET PG01.PCX` → bridge responds `OK PCX 2680\r\n<body>`.
- **First 140 bytes of the PCX response arrive** (12 status +
  128-byte header). `RemoteImgRefill` copies them into `ImgBuf`, the
  PCX header validates (magic 0x0A, 2 bpp, 1 plane).

## What's still broken

**PCX image rendering hangs after ~128 body bytes.** After the 128-byte
header is consumed, the PCX decoder starts its RLE loop. `ImgBytesLeft`
goes from 2680 → 2552 (one refill's worth) and then **never
decrements further** — the MSX is parked in `SerialRead`'s
`in a,(0x81)` poll with RxRDY never asserting again.

Memory snapshot after a 90 s run on `http://example.com`:

```
SerialKind = 2           (PCX)
SerialLen  = 2680        (bytes bridge promised)
FileLen    = 227         (HTM body that already rendered)
IsRemoteSession = 1
ImgBytesLeft = 2552      (2552 bytes still queued host-side)
```

The bridge has the remaining ~2540 bytes buffered on the TCP socket;
openMSX should be streaming them into the 8251 at the programmed baud
rate. Either the emulator's RS232Net implementation stops feeding the
shift register mid-burst, or the 8251 enters a state (framing error,
overrun with a non-obvious clear sequence, DSR latch?) that `SerialRead`
doesn't unblock from.

Things I tried that didn't help:

- `bit 4, a` check on Overrun in the status and re-issuing command
  `0x37` to clear. After that the status read still reports
  RxRDY=0 indefinitely.
- Replaced the 128-byte `RemoteImgRefill` with a per-byte
  `RemoteImgByte` loop that doesn't hold any extra state — same hang.

Likely next moves:

1. Probe openMSX's `RS232Net::recvByte` — maybe the shift register
   only advances when the host side calls `transmitData`, and there's
   a pacing bug with larger bursts.
2. Try issuing `plug msx-rs232 rs232-tester` with two FIFOs instead
   of `rs232-net` — if FIFOs work, it's an RS232Net pacing issue.
3. Inspect the 8251 mode byte interpretation: x16 clock divider
   might be wrong given whatever baud the 8254 is pinned at. A
   stopped baud clock would stop shift progression.

## Quick test procedure

Terminal 1:
```
python3 tools/web_bridge.py --verbose
```

Terminal 2 (openMSX config: Generic MSX RS-232C in Slot A):
```
openmsx -machine Al_Alamiah_AX370 \
        -diska "MSX-DOS/MSX-DOS v1.03.DSK" \
        -exta rs232 \
        -script tools/plug_rs232.tcl
A> MWBRO
address bar: http://example.com
```

Title updates within a couple of seconds; image fails to paint,
content area stays blank, and `Busy` stays on because `RenderPcxFile`
never returns.

## Binary budget

- Baseline (before this cut): 15 138 B. Anything above 15 538 B
  produced a .COM that hangs before DrawTitlebar (asMSX 1.2.0
  phasing quirk; not yet root-caused).
- After the NotFoundHtml removal + transport + dispatch + SerialInit:
  **15 517 B** — 21 bytes of headroom.
- The transport module itself compiled to ~380 B. Removing
  NotFoundHtml freed ~90 B and the 404 path rewrite adds ~30 B.

If we need more space later: the `HTML <map>`/`<area>` parsing
stubs in `tools/web_to_sc6.py`'s HTM wrapper are harmless to the
browser but eat a few bytes of parse time; other size wins remain in
the `TagH1..TagH6` unification the earlier scan flagged.
