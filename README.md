# MSX WBrowser

[العربية](README-ar.md)

A minimal HTML browser for the MSX2, written in Z80 assembly. Runs as an
MSX-DOS 1 `.COM` program on Screen 6 (512×212, 4 colours) and renders
plain HTML files from a floppy disk, with Arabic shaping, lam-alef
ligatures, and basic bidirectional text support.

## Features

- **Screen-6 chrome** — title bar, back/forward/refresh toolbar, address
  bar, scrollable content area, and a pixel-aligned scrollbar.
- **HTML subset** — `<h1>`–`<h6>`, `<p>`, `<b>`, `<i>`, `<u>`, `<s>`,
  `<font color>`, `<a href>`, `<img alt>`, `<hr>`, `<br>`, `<pre>`,
  `<ul>`/`<ol>`/`<li>`, `<blockquote>`, `<table>`/`<tr>`/`<td>`/`<th>`,
  `&nbsp;`/`&amp;`/`&lt;`/`&gt;`/`&quot;` entities.
- **Arabic** — ISO-8859-6 input, joining-form shaping (isolated / initial
  / medial / final), lam-alef ligatures, Arabic-Indic digits.
- **BiDi (L2)** — multi-word Arabic runs reorder correctly inside
  left-to-right paragraphs; `dir="rtl"` flips paragraph direction.
- **Alignment** — `align="left|right|center"` on block tags.
- **Keyboard & mouse** — Tab navigation, Enter/Space activation, arrow
  and Page keys for scrolling, mouse click through direct PSG reads.

## Layout

```
src/mwbrowser.asm        main source
src/iso8859_6.inc        generated ISO-8859-6 → glyph + joining table
dist/mwbrowser.com       assembled binary (Screen-6 .COM)
```

## Building

Requires [asMSX](https://github.com/gflorez/asmsx) and `mtools` (for the
MSX-DOS disk injection).

```sh
./tools/build.sh          # assembles src/mwbrowser.asm → dist/mwbrowser.com
./tools/inject.sh         # writes dist/mwbrowser.com into the boot disk
./tools/run.sh            # launches openMSX with the disk inserted
```

From the MSX-DOS prompt:

```
A> mwbrowsr
```

Type a filename in the address bar (e.g. `a:\test.htm`) and press Enter.

## Keyboard

| Key             | Action                          |
| --------------- | ------------------------------- |
| Tab / Shift+Tab | Cycle focus                     |
| Enter / Space   | Activate focused button / link  |
| Arrow keys      | Scroll / move focus             |
| Space, M        | Page down                       |
| B               | Page up                         |
| F1              | About                           |
| Esc             | Close dialog / quit             |

## License

All rights reserved. This is a private research project.
