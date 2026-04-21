# Serial web bridge — notes for the next cut

## What's landed on `Serial_Comm`

- **`tools/web_bridge.py`** — TCP listener on 127.0.0.1:2323. Speaks a
  line-oriented protocol:

  ```
  MSX -> bridge:  GET <target>\r\n
  bridge -> MSX:  OK HTM <length>\r\n<body>
                  OK PCX <length>\r\n<body>
                  ERR 404\r\n
                  ERR 500\r\n
  ```

  - `GET http://...` — fetches, renders via Playwright (native 492-wide,
    BOX halve, readability CSS), slices into full-viewport PCX chunks,
    stashes them keyed by `pgNN.pcx`, returns an MSX-friendly HTM
    wrapper referencing those names.
  - `GET http://.../foo.jpg` (or other image URL) — downloads, converts
    to 2 bpp PCX, returns.
  - `GET pgNN.pcx` (bare filename) — returns the cached chunk from the
    most recently rendered page.
  - Anything else — `ERR 404`.

  Verified end-to-end against `example.com`: bridge sends a 227 B HTM,
  then a 2 680 B PCX with the expected ZSoft magic `0A 05 01 02`.

- **`tools/serial_host.py`** — interactive terminal bridge from the
  earlier POC (still works if you want to drive `SERPOC.COM` by hand).

- **`tools/plug_rs232.tcl`** — openMSX TCL that wires the cart UART to
  the bridge (`plug msx-rs232 rs232-net` at 127.0.0.1:2323).

## What's NOT yet landed (blocked)

The MSX-side integration — teaching the browser to route URL loads and
`<img>` streams through the UART when the address bar doesn't start
with a drive letter. The intended diff adds:

- A `ContainsColonSlashSlash` helper + a dispatch at the top of
  `LoadFile` that flips a new `IsRemoteSession` byte and jumps to
  `RemoteLoadFile` for "http://..." URLs.
- A `RemoteLoadFile` that sends `GET <UrlBuf>\r\n`, parses the
  `OK HTM <n>` status line, and drains the body into `FileBuf` (with
  overflow tail-drain so the next GET finds a clean socket).
- Parallel dispatchers on `ImgStreamOpenName` / `ImgStreamByte` /
  `ImgStreamClose` that, when `IsRemoteSession != 0`, fetch each
  `<img src="pgNN.pcx">` over the UART.
- Raw-8251 I/O helpers at ports 0x80/0x81.

Each of those pieces compiles fine, and manual inspection of the
emitted bytes looks right. But adding the full ~450 bytes to
`src/mwbrowser.asm` pushes the binary from 15 138 B to ~15 583 B, and
somewhere in that range asMSX 1.2.0 starts emitting a .COM that hangs
before `DrawTitlebar`. Bisected: under ~15 538 B MWBRO still paints
chrome, at 15 588 B it hangs with a black screen. No extra asMSX
warnings appear, so it's not an obvious truncation — likely a forward-
reference or phasing bug. Suspects:

- `DataMsxPrefixLen equ $ - DataMsxPrefix` on line 5738. That `equ`
  is 1 300+ lines removed from `DataMsxPrefix`, so its value depends
  on whatever sits between them at assembly time. A single-pass asMSX
  could resolve it to a different offset in pass 1 vs pass 2.
- The `.MSXDOS` / `.bios` directive combination with large trailing
  `ds` blocks. `FileBuf equ $` sits at EOF and is how the heap is
  calculated; if asMSX truncates a `ds` mid-stream when over a size
  threshold the label math drifts.

## How to unblock

Two directions:

1. **Move the `equ`-at-current-$ computations adjacent to their string
   literal** so forward references stay small. Specifically:
   `NotFoundHtmlLen equ $ - NotFoundHtml` at line 5737 should be on
   the line right after the last `db` of the `NotFoundHtml` string;
   same for `DataMsxPrefixLen`. These used to match; the hundreds of
   lines of <map>/<area> / 16-bit scroll code added on `image_maps`
   may have pushed them past a magic distance.

2. **Build the serial transport as a separate .COM** loaded via
   `exec()` from the browser, so the browser's own binary doesn't
   grow. That sidesteps asMSX entirely, but needs an IPC bridge
   (BDOS-style call vector) — heavier.

Once the size issue is fixed, the only remaining MSX work is the diff
sketched in `src/mwbrowser.asm.backup1` (kept on disk as reference,
untracked by git).

## Quick demo you can run today

```sh
# Terminal 1
python3 tools/web_bridge.py --verbose

# Terminal 2 — a manual client that simulates what the MSX will do
python3 - <<'PY'
import socket
s = socket.socket(); s.connect(("127.0.0.1", 2323))
s.sendall(b"GET http://example.com\r\n")
# read status line
buf = b""
while not buf.endswith(b"\r\n"): buf += s.recv(1)
print(buf)
# read HTM body using the length from the status
_, _, n = buf.rstrip(b"\r\n").split()
body = b""; n = int(n)
while len(body) < n: body += s.recv(n - len(body))
print(body.decode("iso-8859-6"))
# pull chunk 1
s.sendall(b"GET pg01.pcx\r\n")
...
PY
```
