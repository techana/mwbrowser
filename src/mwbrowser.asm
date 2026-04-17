; ============================================================================
; MSX WBrowser -- MSX2 Screen-6 HTML browser with Arabic support.
; MSX2, Screen 6, 512x212, 4 colours, MSX-DOS 1 .COM
;
; On top of the chrome layout, this pass adds keyboard handling and focus:
;   - Tab cycles focus through Back, Refresh, Forward, Address, Content.
;   - Focused element's 1-px border turns black; unfocused borders are dark
;     gray. (The plan called for a 2-px dark-gray ring, but Screen 6's
;     4-pixel byte alignment makes a true 2-px ring impractical on horizontal
;     edges -- the colour change is immediately distinguishable anyway.)
;   - Enter/Space on Refresh toggles Busy; the icon swaps between a
;     circular-arrow refresh glyph and a prohibition-sign stop glyph (both
;     packed from resources/*.png by tools/icons_gen.py).
;   - Address bar: printable chars append (up to 96), Backspace deletes. URL
;     is redrawn live.
;   - ESC exits (plan said F12; MSX-DOS extended-key byte sequences are not
;     wired in Step 1 -- ESC is a single byte every MSX-DOS kernel returns).
;
; Button labels were dropped at user request: Back/Forward show "<"/">",
; Refresh/Stop uses a blitted icon. Content area stays blank white,
; Back/Forward are disabled and swallow Enter/Space.
; ============================================================================

    .MSXDOS
    .bios

; ---- DOS / VDP / BIOS equates ----
BDOS_ENTRY     equ 0x0005
DOS_TERM       equ 0x00
DOS_DIRIN      equ 0x07        ; blocking read, no echo, no CTRL-C
DOS_CONST      equ 0x0B        ; console status (non-blocking peek)
DOS_OPEN       equ 0x0F        ; open file via FCB
DOS_CLOSE      equ 0x10        ; close file via FCB
DOS_READ       equ 0x14        ; sequential read (128-byte record)
DOS_SETDMA     equ 0x1A        ; set disk transfer address

VDP_DATA       equ 0x98
VDP_CMD        equ 0x99
VDP_PAL        equ 0x9A

; Work-area pointer CGPNT (0xF91F) is a 3-byte record that tells us where the
; live MSX font lives: byte 0 = slot specifier, bytes 1..2 = address in that
; slot. Using CGPNT instead of hardcoding 0x1BBF keeps ExtractFont portable
; across MSX variants (each machine's BIOS sets CGPNT during init).
CGPNT          equ 0xF91F      ; slot (1B) + address (2B, LE) of font table

; ---- palette slots ----
; MSX2 Screen 6 has a quirk: pixel value 0 renders with pair-palette dithering
; (alternating pal 0 + pal 2), but values 1/2/3 render as solid pal 1/2/3.
; We assign pixel values and palette entries so each semantic colour lands on
; a SOLID render path:
;   value 0 -> pair (pal 0 = dgray, pal 2 = white) -> mid-gray dither (DGRAY)
;   value 1 -> solid pal 1 = light gray                                (LGRAY)
;   value 2 -> solid pal 2 = white                                     (WHITE)
;   value 3 -> solid pal 3 = black                                     (BLACK)
; Content uses COL_WHITE (value 2) for pure solid white. Titlebar/toolbar
; background is LGRAY (value 1) for solid light-gray. Focused borders/text
; are BLACK (value 3) for pure black. Separator, thumb, and unfocused
; borders use DGRAY (value 0), which dithers pal 0+pal 2 into a mid-gray
; visibly darker than LGRAY.
COL_DGRAY      equ 0       ; pair (pal 0 dgray + pal 2 white) -> dither
COL_LGRAY      equ 1       ; solid pal 1 = light gray
COL_WHITE      equ 2       ; solid pal 2 = white
COL_BLACK      equ 3       ; solid pal 3 = black

; ---- layout (see tools/mockup_annotated.png) ----
WIDTH          equ 512

TITLE_Y0       equ 0
TITLE_Y1       equ 8
SEP1_Y         equ 9
TOOL_Y0        equ 10
TOOL_Y1        equ 27
SEP2_Y         equ 28
CONTENT_Y0     equ 29
CONTENT_Y1     equ 211

BTN_Y0         equ 12
BTN_W          equ 60
BTN_H          equ 15
; Toolbar layout (left to right): Back, Forward, Address bar, Refresh.
; Refresh sits at the far right of the toolbar; Address bar fills the middle.
BTN1_X         equ 4                    ; Back,    byte col 1
BTN3_X         equ 68                   ; Forward, byte col 17
ADDR_X0        equ 132                  ; byte col 33
ADDR_X1        equ 427                  ; byte col 106 (ADDR width = 296 px)
BTN2_X         equ 432                  ; Refresh, byte col 108 (ends at x=491)

; Scrollbar is 20 wide (5 bytes) -- 1 byte wider than before. An 8-wide arrow
; icon (2 bytes) sits inside 1-byte (4-px) left/right track borders.
SCROLL_X0      equ 492                  ; byte col 123
SCROLL_X1      equ 511
SCROLL_ICN_X   equ 496                  ; icon 1 byte inside left track border
SCROLL_UP_Y1   equ 40
SCROLL_DN_Y0   equ 200
THUMB_Y0       equ 42
THUMB_Y1       equ 198

; ---- focus IDs ----
; Tab cycles focus in this numeric order:
;   Back -> Forward -> Address -> Refresh -> Content -> Back ...
FOC_BACK       equ 0
FOC_FORWARD    equ 1
FOC_ADDRESS    equ 2
FOC_REFRESH    equ 3
FOC_CONTENT    equ 4
FOC_COUNT      equ 5

; ---- keys ----
KEY_ESC        equ 0x1B
KEY_BACKSPACE  equ 0x08
KEY_TAB        equ 0x09
KEY_ENTER      equ 0x0D
KEY_SPACE      equ 0x20
KEY_UP         equ 0x1E        ; MSX DIRIN returns 0x1E for up arrow
KEY_DOWN       equ 0x1F        ; 0x1F for down arrow
KEY_CLS        equ 0x0C        ; MSX CLS / Ctrl+L -- clears address bar
KEY_F1         equ 0xF1        ; MSX F1 key (opens About popup)

; ---- URL / file state ----
URL_MAX        equ 96
FILE_BUF_SIZE  equ 4096        ; 4 KB — enough for Step 2 test files
FONT_BUF_SIZE  equ 2048        ; 256 glyphs * 8 rows
CONTENT_X_END  equ 491         ; scrollbar now starts at x=492
TEXT_LINE_H    equ 8           ; MSX font row height
TEXT_MAX_LINES equ (CONTENT_Y1 - CONTENT_Y0 + 1) / TEXT_LINE_H  ; 22 lines
CONTENT_W_BYTES equ (CONTENT_X_END + 1) / 4                     ; 124 bytes

; ---- About popup geometry (must be byte-aligned: X and W multiples of 4) ----
ABOUT_X        equ 128
ABOUT_Y        equ 50
ABOUT_W        equ 256
ABOUT_H        equ 120

; ---- button state bits ----
BTN_DISABLED   equ 0x01
BTN_FOCUSED    equ 0x02

; ============================================================================
; Entry
; ============================================================================

Main:
    ld      [EntrySP], sp               ; remember caller's SP for clean Esc exit
    ld      a, 6
    .CALLBIOS CHGMOD                    ; Screen 6

    call    ExtractFont                 ; pull BIOS font into FontBuf (once)
    call    SetPalette
    call    SetBorder
    call    ClearContent                ; VRAM all white (colour 0)
    call    InitState

    call    DrawTitlebar
    call    DrawSeparators
    call    DrawScrollbar
    call    DrawTitleLabel
    call    PaintToolbar

MainLoop:
    call    PollMouse

    ; Non-blocking keyboard check. If no key, loop again (keeps polling mouse).
    ld      c, DOS_CONST
    call    BDOS_ENTRY
    or      a
    jp      z, MainLoop

    call    EraseCursor                 ; keyboard actions may repaint UI
    ld      c, DOS_DIRIN
    call    BDOS_ENTRY                  ; A = char, no echo
    ld      b, a                        ; save key in B for dispatch

    ; When the About popup is open everything except Esc is swallowed.
    ld      a, [AboutOpen]
    or      a
    jr      z, .noPopup
    ld      a, b
    cp      KEY_ESC
    jr      nz, .popupSwallow
    call    CloseAbout
.popupSwallow:
    jp      MainLoop

.noPopup:
    ld      a, b
    cp      KEY_ESC
    jp      z, Shutdown

    cp      KEY_F1                      ; F1 opens About popup
    jr      z, .openAboutFromKey
    cp      '?'                         ; "?" also opens it
    jr      nz, .notOpenAbout
.openAboutFromKey:
    call    OpenAbout
    jp      MainLoop
.notOpenAbout:

    cp      KEY_TAB
    jr      nz, NotTab
    ; Tab in Content sub-cycles through visible links (dotted underline
    ; marks the active one) before rolling back to the toolbar via the
    ; normal CycleFocus path.
    ld      a, [Focus]
    cp      FOC_CONTENT
    jr      nz, .tabCycle
    ld      a, [LinkCount]
    or      a
    jr      z, .tabCycle                ; no links -> normal cycle
    ld      a, [HtmlFocusLink]
    cp      0xFF
    jr      nz, .tabAdv
    ; First Tab in Content: focus link 0.
    xor     a
    ld      [HtmlFocusLink], a
    call    RefreshAfterScroll
    jp      MainLoop
.tabAdv:
    ; Already focused on a link -- advance to the next one.
    ld      b, a                        ; B = current focus
    ld      a, [LinkCount]
    dec     a
    cp      b
    jr      c, .tabExit                 ; focus past the last link
    jr      z, .tabExit
    inc     b
    ld      a, b
    ld      [HtmlFocusLink], a
    call    RefreshAfterScroll
    jp      MainLoop
.tabExit:
    ld      a, 0xFF
    ld      [HtmlFocusLink], a
    call    RefreshAfterScroll
.tabCycle:
    call    CycleFocus
    call    PaintToolbar
    jp      MainLoop
NotTab:

    ; Dispatch by current focus. B already holds the key.
    ld      a, [Focus]
    cp      FOC_BACK
    jp      z, OnBack
    cp      FOC_FORWARD
    jp      z, OnForward
    cp      FOC_REFRESH
    jp      z, OnRefresh
    cp      FOC_ADDRESS
    jp      z, OnAddress
    cp      FOC_CONTENT
    jp      z, OnContent
    jp      MainLoop

OnBack:
    ld      a, b
    cp      KEY_ENTER
    jr      z, DoBack
    cp      KEY_SPACE
    jp      nz, MainLoop
DoBack:
    call    GoBack
    jp      MainLoop

OnForward:
    ld      a, b
    cp      KEY_ENTER
    jr      z, DoForward
    cp      KEY_SPACE
    jp      nz, MainLoop
DoForward:
    call    GoForward
    jp      MainLoop

OnRefresh:
    ld      a, b
    cp      KEY_ENTER
    jr      z, DoGo
    cp      KEY_SPACE
    jr      z, DoGo
    jp      MainLoop
DoGo:
    ; Refresh acts as a Go button: load URL then shift focus to the view.
    call    NavigateAndFocusContent
    jp      MainLoop

OnAddress:
    ld      a, b
    cp      KEY_ENTER
    jr      nz, NotAddrEnter
    call    NavigateAndFocusContent
    jp      MainLoop
NotAddrEnter:
    cp      KEY_BACKSPACE
    jr      nz, NotBackspace
    call    UrlBackspace
    call    PaintToolbar
    jp      MainLoop
NotBackspace:
    cp      KEY_CLS                     ; Ctrl+L / MSX CLS
    jr      nz, NotCls
    call    UrlClear
    call    PaintToolbar
    jp      MainLoop
NotCls:
    cp      0x20                        ; printable range 0x20..0x7E
    jp      c, MainLoop
    cp      0x7F
    jp      nc, MainLoop
    call    UrlAppend
    call    PaintToolbar
    jp      MainLoop

OnContent:
    ld      a, b
    cp      KEY_ENTER
    jp      z, DoLinkEnter              ; if a link is Tab-focused, open it
    cp      KEY_UP
    jr      z, DoScrollUp
    cp      'k'                         ; vim-style line-up
    jr      z, DoScrollUp
    cp      'K'
    jr      z, DoScrollUp
    cp      KEY_DOWN
    jr      z, DoScrollDn
    cp      'j'                         ; vim-style line-down
    jr      z, DoScrollDn
    cp      'J'
    jr      z, DoScrollDn
    cp      ' '                         ; Space = page down
    jr      z, DoPageDn
    cp      'm'
    jr      z, DoPageDn
    cp      'M'
    jr      z, DoPageDn
    cp      'n'
    jr      z, DoPageUp
    cp      'N'
    jp      nz, MainLoop
DoPageUp:
    call    PageUp
    jp      MainLoop
DoPageDn:
    call    PageDown
    jp      MainLoop
DoScrollDn:
    call    ScrollDown
    jp      MainLoop
DoScrollUp:
    call    ScrollUp
    jp      MainLoop

; DoLinkEnter: Enter pressed while Focus=Content. If a link is currently
; Tab-focused, copy its href into UrlBuf and navigate. Otherwise fall
; through so Enter just returns to MainLoop.
DoLinkEnter:
    ld      a, [HtmlFocusLink]
    cp      0xFF
    jp      z, MainLoop
    ld      c, a
    ld      a, [LinkCount]
    cp      c
    jp      c, MainLoop                 ; stale focus index (defensive)
    jp      z, MainLoop
    ld      a, c
    call    GetLinkUrlPtr
    call    CopyHrefToUrlBuf
    ld      a, 0xFF
    ld      [HtmlFocusLink], a
    call    NavigateAndFocusContent
    jp      MainLoop

; Shutdown: restore Screen 0 defaults then BDOS TERM. We reset the
; palette ourselves (the viewer's custom Screen 6 palette would otherwise
; make Screen 0 bg appear white/black), then hand over to CHGMOD(0) and
; TERM. INITXT is avoided because it hangs on this machine after a
; lengthy Screen 6 session.
Shutdown:
    ld      sp, [EntrySP]

    di
    xor     a
    out     [VDP_CMD], a                ; palette index 0
    ld      a, 0x80 | 16
    out     [VDP_CMD], a
    ld      hl, Screen0Palette
    ld      b, 32
.palLoop:
    ld      a, [hl]
    out     [VDP_PAL], a
    inc     hl
    djnz    .palLoop
    ei

    xor     a
    .CALLBIOS CHGMOD

    ; Explicitly restore R7 = 0xF4 (fg=15 white, bg=4 dark blue). CHGMOD
    ; does not reset this register, so the Screen 6 value lingers.
    di
    ld      a, 0xF4
    out     [VDP_CMD], a
    ld      a, 0x80 | 7
    out     [VDP_CMD], a
    ei

    ld      c, DOS_TERM
    jp      BDOS_ENTRY

; MSX2 Screen 0 default palette. Each entry: byte1 = (R<<4)|B, byte2 = G.
Screen0Palette:
    db 0x00, 0x00      ; 0 transparent
    db 0x00, 0x00      ; 1 black
    db 0x11, 0x06      ; 2 medium green
    db 0x33, 0x07      ; 3 light green
    db 0x27, 0x02      ; 4 dark blue
    db 0x47, 0x03      ; 5 light blue
    db 0x51, 0x01      ; 6 dark red
    db 0x26, 0x07      ; 7 cyan
    db 0x71, 0x01      ; 8 red
    db 0x73, 0x03      ; 9 light red
    db 0x61, 0x06      ; 10 dark yellow
    db 0x63, 0x06      ; 11 light yellow
    db 0x11, 0x04      ; 12 dark green
    db 0x65, 0x02      ; 13 magenta
    db 0x55, 0x05      ; 14 gray
    db 0x77, 0x07      ; 15 white

; ============================================================================
; State
; ============================================================================

; Initialise Focus / Busy / Url. Called once from Main.
InitState:
    ld      a, FOC_REFRESH
    ld      [Focus], a
    xor     a
    ld      [Busy], a
    ld      hl, UrlInit
    ld      de, UrlBuf
    ld      b, 0
.copy:
    ld      a, [hl]
    ld      [de], a
    or      a
    jr      z, .done
    inc     hl
    inc     de
    inc     b
    jr      .copy
.done:
    ld      a, b
    ld      [UrlLen], a
    ret

; Advance Focus by 1 modulo FOC_COUNT.
CycleFocus:
    ld      a, [Focus]
    inc     a
    cp      FOC_COUNT
    jr      c, .ok
    xor     a
.ok:
    ld      [Focus], a
    ret

; UrlAppend: A (on entry) = char to append (printable). NUL-terminates.
UrlAppend:
    ld      c, a
    ld      a, [UrlLen]
    cp      URL_MAX
    ret     nc
    ld      e, a
    ld      d, 0
    ld      hl, UrlBuf
    add     hl, de
    ld      [hl], c
    inc     hl
    xor     a
    ld      [hl], a
    ld      a, [UrlLen]
    inc     a
    ld      [UrlLen], a
    ret

; UrlClear: zero the address bar (UrlLen=0, UrlBuf[0]=NUL).
UrlClear:
    xor     a
    ld      [UrlLen], a
    ld      [UrlBuf], a
    ret

; UrlBackspace: decrement UrlLen, NUL-terminate at new length.
UrlBackspace:
    ld      a, [UrlLen]
    or      a
    ret     z
    dec     a
    ld      [UrlLen], a
    ld      e, a
    ld      d, 0
    ld      hl, UrlBuf
    add     hl, de
    xor     a
    ld      [hl], a
    ret

; ComputeFocusState: A (on entry) = focus index to check.
; Returns A = BTN_FOCUSED if [Focus] == A, else A = 0.
ComputeFocusState:
    ld      hl, Focus
    cp      [hl]
    ld      a, 0
    ret     nz
    ld      a, BTN_FOCUSED
    ret

; ============================================================================
; Palette + border
; ============================================================================

SetPalette:
    di
    xor     a
    out     [VDP_CMD], a                ; index 0
    ld      a, 0x80 | 16
    out     [VDP_CMD], a
    ei

    ld      hl, PaletteData
    ld      b, 8
.loop:
    ld      a, [hl]
    out     [VDP_PAL], a
    inc     hl
    djnz    .loop
    ret

PaletteData:
    db  0x22, 0x02      ; 0 = dark gray   RGB(2,2,2)   (pair-partner for pal 2)
    db  0x55, 0x05      ; 1 = light gray  RGB(5,5,5)   (solid)
    db  0x77, 0x07      ; 2 = white       RGB(7,7,7)   (solid, pair-partner for pal 0)
    db  0x00, 0x00      ; 3 = black       RGB(0,0,0)   (solid)

; R#7 = border colour byte. Screen 6 uses bits 1..0 as a 2-bit palette index.
SetBorder:
    di
    ld      a, COL_LGRAY
    out     [VDP_CMD], a
    ld      a, 0x80 | 7
    out     [VDP_CMD], a
    ei
    ret

; ============================================================================
; VDP primitives (direct I/O; no BIOS)
; ============================================================================

; VdpSetWriteAddr: HL = 16-bit VRAM address (A0..A13). Assumes R#14 preset.
VdpSetWriteAddr:
    di
    ld      a, l
    out     [VDP_CMD], a
    ld      a, h
    and     0x3F
    or      0x40                        ; write mode
    out     [VDP_CMD], a
    ei
    ret

; VdpSetReadAddr: HL = 14-bit VRAM address; selects read mode (no 0x40 bit).
VdpSetReadAddr:
    di
    ld      a, l
    out     [VDP_CMD], a
    ld      a, h
    and     0x3F                        ; mode = 00 (read)
    out     [VDP_CMD], a
    ei
    ret

; VdpFill: DE bytes of value A, starting at VRAM addr in HL.
VdpFill:
    push    af
    call    VdpSetWriteAddr
    pop     af
.loop:
    out     [VDP_DATA], a
    dec     de
    ld      b, a
    ld      a, d
    or      e
    ld      a, b
    jr      nz, .loop
    ret

; ============================================================================
; Graphics primitives (byte-aligned: x%4==0, w%4==0)
; ============================================================================

; PackColour: A = palette index 0..3 -> A = replicated packed byte.
PackColour:
    and     0x03
    ld      b, a
    add     a, a
    add     a, a
    or      b
    ld      b, a
    add     a, a
    add     a, a
    add     a, a
    add     a, a
    or      b
    ret

; SetVramWritePos: B = x/4, C = y. Handles the A14 boundary at y>=128.
SetVramWritePos:
    ld      a, c
    rlca                                ; CF = bit 7 of y
    ld      a, 0
    adc     a, 0                        ; A = 0 or 1
    call    VdpSetR14

    ld      a, c
    and     0x7F
    ld      h, a
    ld      l, 0
    srl     h
    rr      l                           ; HL = (y & 0x7F) * 128
    ld      a, l
    add     a, b
    ld      l, a
    jp      VdpSetWriteAddr

; SetVramReadPos: same layout as above but points VDP at read mode.
SetVramReadPos:
    ld      a, c
    rlca
    ld      a, 0
    adc     a, 0
    call    VdpSetR14
    ld      a, c
    and     0x7F
    ld      h, a
    ld      l, 0
    srl     h
    rr      l
    ld      a, l
    add     a, b
    ld      l, a
    jp      VdpSetReadAddr

; FillRect(B=x/4, C=y, D=w/4, E=h, A=colour). Byte-aligned.
FillRect:
    push    bc
    call    PackColour
    pop     bc
    ld      [PackedColour], a
.nextRow:
    push    bc
    push    de
    call    SetVramWritePos
    pop     de
    push    de
    ld      a, [PackedColour]
    ld      b, d
.rowLoop:
    out     [VDP_DATA], a
    djnz    .rowLoop
    pop     de
    pop     bc
    inc     c
    dec     e
    jr      nz, .nextRow
    ret

PackedColour:  db 0

DrawHLine:
    ld      e, 1
    jr      FillRect

DrawVLine:
    ld      d, 1
    jr      FillRect

; DrawRectBorder(B=x/4, C=y, D=w/4, E=h, A=colour): 1-px outline.
DrawRectBorder:
    ld      [BorderColour], a
    ld      a, b
    ld      [RectX], a
    ld      a, c
    ld      [RectY], a
    ld      a, d
    ld      [RectW], a
    ld      a, e
    ld      [RectH], a

    ld      a, [BorderColour]
    call    DrawHLine                   ; top

    ld      a, [RectX]
    ld      b, a
    ld      a, [RectY]
    ld      c, a
    ld      a, [RectH]
    add     a, c
    dec     a
    ld      c, a
    ld      a, [RectW]
    ld      d, a
    ld      a, [BorderColour]
    call    DrawHLine                   ; bottom

    ld      a, [RectX]
    ld      b, a
    ld      a, [RectY]
    ld      c, a
    ld      a, [RectH]
    ld      e, a
    ld      a, [BorderColour]
    call    DrawVLine                   ; left

    ld      a, [RectX]
    ld      b, a
    ld      a, [RectW]
    add     a, b
    dec     a
    ld      b, a
    ld      a, [RectY]
    ld      c, a
    ld      a, [RectH]
    ld      e, a
    ld      a, [BorderColour]
    jp      DrawVLine                   ; right

BorderColour: db 0
RectX:        db 0
RectY:        db 0
RectW:        db 0
RectH:        db 0

; ============================================================================
; Initial VRAM fill
; ============================================================================

; Fill the whole 512x212 bitmap with white (colour 0).
; Pages split at 0x4000 because R#14 does not auto-increment past the 14-bit
; internal VRAM pointer; each 16 KB slab is filled separately.
ClearContent:
    ld      a, COL_WHITE
    call    PackColour
    ld      [PackedColour], a

    call    VdpSetR14Zero
    ld      hl, 0x0000
    ld      de, 0x4000
    ld      a, [PackedColour]
    call    VdpFill

    ld      a, 1
    call    VdpSetR14
    ld      hl, 0x0000
    ld      de, 212 * 128 - 0x4000
    ld      a, [PackedColour]
    call    VdpFill

    jp      VdpSetR14Zero

VdpSetR14Zero:
    xor     a
VdpSetR14:
    di
    out     [VDP_CMD], a
    ld      a, 0x80 | 14
    out     [VDP_CMD], a
    ei
    ret

; ============================================================================
; High-level GUI painting
; ============================================================================

; Titlebar band (light gray y=0..8).
DrawTitlebar:
    ld      b, 0
    ld      c, TITLE_Y0
    ld      d, WIDTH / 4
    ld      e, TITLE_Y1 - TITLE_Y0 + 1
    ld      a, COL_LGRAY
    jp      FillRect

DrawSeparators:
    ld      b, 0
    ld      c, SEP1_Y
    ld      d, WIDTH / 4
    ld      a, COL_DGRAY
    call    DrawHLine
    ld      b, 0
    ld      c, SEP2_Y
    ld      d, WIDTH / 4
    ld      a, COL_DGRAY
    jp      DrawHLine

DrawScrollbar:
    ; Track background.
    ld      b, SCROLL_X0 / 4
    ld      c, CONTENT_Y0
    ld      d, (SCROLL_X1 - SCROLL_X0 + 1) / 4
    ld      e, CONTENT_Y1 - CONTENT_Y0 + 1
    ld      a, COL_LGRAY
    call    FillRect

    ; Full track outline (dark-gray frame, softer than the black thumb).
    ld      b, SCROLL_X0 / 4
    ld      c, CONTENT_Y0
    ld      d, (SCROLL_X1 - SCROLL_X0 + 1) / 4
    ld      e, CONTENT_Y1 - CONTENT_Y0 + 1
    ld      a, COL_DGRAY
    call    DrawRectBorder

    ; Thumb at computed position + size (solid black so it stands out).
    ; Inset by 1 byte on each side so it sits inside the dark-gray frame
    ; instead of overlapping it. ComputeThumb must be called whenever
    ; ScrollLine or TotalLines changes; here we just read the current values.
    ld      a, [ThumbTop]
    ld      c, a
    ld      a, [ThumbHeight]
    ld      e, a
    ld      b, SCROLL_X0 / 4 + 1
    ld      d, (SCROLL_X1 - SCROLL_X0 + 1) / 4 - 3
    ld      a, COL_BLACK
    call    FillRect

    ; Shave 1 MSX pixel off the right side of the thumb: the byte adjacent
    ; to the 2-byte solid block gets pattern 11_11_11_01 = 0xFD (3 pixels
    ; black, 1 pixel LGRAY on the right).
    ld      a, [ThumbTop]
    ld      c, a
    ld      a, [ThumbHeight]
    ld      e, a
.thumbCapLoop:
    push    bc
    push    de
    ld      b, SCROLL_X0 / 4 + 3
    call    SetVramWritePos
    ld      a, 0xFD
    out     [VDP_DATA], a
    pop     de
    pop     bc
    inc     c
    dec     e
    jr      nz, .thumbCapLoop

    ; Arrow icons sit directly on the track.
    call    DrawUpArrow
    jp      DrawDownArrow

; CountTotalLines: walk FileBuf[0..FileLen-1] counting LF bytes; stores into
; TotalLines (saturated at 255). Called after every successful load so the
; thumb math has a fresh denominator.
CountTotalLines:
    ld      hl, FileBuf
    ld      bc, [FileLen]
    ld      d, 0
.loop:
    ld      a, b
    or      c
    jr      z, .done
    ld      a, [hl]
    inc     hl
    dec     bc
    cp      0x0A
    jr      nz, .loop
    inc     d
    jr      nz, .loop                   ; saturate at 255
    dec     d
    jr      .loop
.done:
    ld      a, d
    ld      [TotalLines], a
    ret

; ComputeThumb: set ThumbTop + ThumbHeight from ScrollLine and TotalLines.
;   If TotalLines <= TEXT_MAX_LINES, thumb fills track.
;   Else:
;     ThumbHeight = max(4, TEXT_MAX_LINES * TRACK_H / TotalLines)
;     ThumbTop    = THUMB_Y0 + (ScrollLine * TRACK_H / TotalLines)
ComputeThumb:
    ld      a, [TotalLines]
    cp      TEXT_MAX_LINES + 1
    jr      c, .fullThumb

    ld      c, a                        ; C = divisor (TotalLines)

    ; ThumbHeight = TEXT_MAX_LINES * TRACK_H / TotalLines
    ld      hl, TEXT_MAX_LINES * (THUMB_Y1 - THUMB_Y0 + 1)
    call    DivU16By8
    ld      a, l
    cp      4
    jr      nc, .h_ok
    ld      a, 4
.h_ok:
    ld      [ThumbHeight], a

    ; ThumbTop = THUMB_Y0 + (ScrollLine * TRACK_H / TotalLines)
    ld      a, [ScrollLine]
    or      a
    jr      z, .topAtZero
    ld      b, a                        ; B = ScrollLine (multiplier)
    ld      hl, 0
    ld      de, THUMB_Y1 - THUMB_Y0 + 1
.mulLoop:
    add     hl, de
    djnz    .mulLoop
    ld      a, [TotalLines]
    ld      c, a
    call    DivU16By8
    ld      a, l
    add     a, THUMB_Y0
    ld      [ThumbTop], a

    ; Clamp ThumbTop so ThumbTop + ThumbHeight <= THUMB_Y1 + 1. The add can
    ; overflow the byte (e.g. ThumbTop=192, Height=138 -> 330) in which case
    ; the silent wrap would defeat a plain `cp` threshold check and leave
    ; the thumb drawing past row 255 back into the titlebar. Detect the
    ; overflow via the carry flag and clamp unconditionally in that case.
    ld      a, [ThumbHeight]
    ld      b, a
    ld      a, [ThumbTop]
    add     a, b
    jr      c, .clampTop                ; byte overflow -> always clamp
    cp      THUMB_Y1 + 2
    jr      c, .topOk
.clampTop:
    ld      a, THUMB_Y1 + 1
    sub     b
    ld      [ThumbTop], a
.topOk:
    ret

.topAtZero:
    ld      a, THUMB_Y0
    ld      [ThumbTop], a
    ret

.fullThumb:
    ld      a, THUMB_Y0
    ld      [ThumbTop], a
    ld      a, THUMB_Y1 - THUMB_Y0 + 1
    ld      [ThumbHeight], a
    ret

; DivU16By8: HL / C  ->  HL = quotient, A = remainder.
; Standard shift-subtract; iterates 16 times.
DivU16By8:
    xor     a
    ld      b, 16
.loop:
    add     hl, hl
    rla
    jr      c, .sub
    cp      c
    jr      c, .noSub
.sub:
    sub     c
    inc     l
.noSub:
    djnz    .loop
    ret

; ============================================================================
; Toolbar -- state-driven repaint of 3 buttons + address bar
; ============================================================================

; PaintToolbar: full redraw of the toolbar band based on Focus / Busy.
PaintToolbar:
    ; Background.
    ld      b, 0
    ld      c, TOOL_Y0
    ld      d, WIDTH / 4
    ld      e, TOOL_Y1 - TOOL_Y0 + 1
    ld      a, COL_LGRAY
    call    FillRect

    ; --- Back button: enabled iff HasPrev is set ---
    ld      a, FOC_BACK
    call    ComputeFocusState           ; A = BTN_FOCUSED or 0
    ld      c, a
    ld      a, [HasPrev]
    or      a
    ld      a, c
    jr      nz, .backEnabled
    or      BTN_DISABLED
.backEnabled:
    ld      [ButtonState], a
    ld      a, BTN1_X / 4
    call    PaintButtonBox
    ; "<" glyph: dark gray if disabled, black if enabled.
    ld      a, [ButtonState]
    and     BTN_DISABLED
    jr      z, .backFgOn
    ld      a, COL_DGRAY
    jr      .backFgSet
.backFgOn:
    ld      a, COL_BLACK
.backFgSet:
    ld      l, COL_LGRAY
    call    SetTextColours
    ld      de, BTN1_X + 26
    ld      c, BTN_Y0 + 4
    ld      hl, CharLess
    call    DrawString

    ; --- Refresh button (enabled + possibly focused) ---
    ld      a, FOC_REFRESH
    call    ComputeFocusState
    ld      [ButtonState], a
    ld      a, BTN2_X / 4
    call    PaintButtonBox
    ; Busy flag picks an uppercase 'X' (stop) instead of the right-arrow
    ; (refresh). Both are tiny routines so we skip the old bitmap pair.
    ld      a, [Busy]
    or      a
    jr      nz, .refBusy
    ld      a, BTN2_X / 4
    call    DrawRefreshGlyph
    jr      .refDone
.refBusy:
    ld      a, COL_BLACK
    ld      l, COL_LGRAY
    call    SetTextColours
    ld      de, BTN2_X + 26
    ld      c, BTN_Y0 + 4
    ld      hl, CharX
    call    DrawString
.refDone:

    ; --- Forward button: enabled iff HasNext is set ---
    ld      a, FOC_FORWARD
    call    ComputeFocusState
    ld      c, a
    ld      a, [HasNext]
    or      a
    ld      a, c
    jr      nz, .fwdEnabled
    or      BTN_DISABLED
.fwdEnabled:
    ld      [ButtonState], a
    ld      a, BTN3_X / 4
    call    PaintButtonBox
    ld      a, [ButtonState]
    and     BTN_DISABLED
    jr      z, .fwdFgOn
    ld      a, COL_DGRAY
    jr      .fwdFgSet
.fwdFgOn:
    ld      a, COL_BLACK
.fwdFgSet:
    ld      l, COL_LGRAY
    call    SetTextColours
    ld      de, BTN3_X + 26
    ld      c, BTN_Y0 + 4
    ld      hl, CharGreater
    call    DrawString

    ; --- Address bar ---
    ld      a, FOC_ADDRESS
    call    ComputeFocusState
    ld      [ButtonState], a
    jp      PaintAddressBar

; PaintButtonBox: draw the 60x15 button background + border at (A=byteCol,
; BTN_Y0). A holds the button's left byte column (== pixelX / 4) so the
; caller can reach x > 255 pixel positions. Uses [ButtonState] for focus.
; After the border, the four corner bytes are patched so the outermost corner
; pixel matches the bg (LGRAY) -- 1-pixel arched look.
PaintButtonBox:
    ld      [ButtonByteCol], a
    ld      b, a
    ld      c, BTN_Y0
    ld      d, BTN_W / 4
    ld      e, BTN_H
    ld      a, COL_LGRAY
    call    FillRect

    ld      a, [ButtonByteCol]
    ld      b, a
    ld      c, BTN_Y0
    ld      d, BTN_W / 4
    ld      e, BTN_H
    ld      a, [ButtonState]
    and     BTN_FOCUSED
    jr      z, .dgrayBorder             ; unfocused: dark-gray border
    ld      a, COL_BLACK                ; focused: black border
    call    DrawRectBorder
    ; Corner bytes become fully bg (LGRAY, pair 01 -> 0x55) so the 4 corners
    ; are symmetric regardless of dither phase.
    ld      hl, 0x5555
    jr      .btnCorners
.dgrayBorder:
    ld      a, COL_DGRAY
    call    DrawRectBorder
    ld      hl, 0x5555
.btnCorners:
    ld      a, [ButtonByteCol]
    ld      b, a
    add     a, BTN_W / 4 - 1
    ld      d, a
    ld      c, BTN_Y0
    ld      e, BTN_Y0 + BTN_H - 1
    jp      RoundCorners

ButtonByteCol: db 0
ButtonState:   db 0

; RoundCorners(B=leftByteCol, D=rightByteCol, C=topY, E=bottomY,
;              H=leftCornerByte, L=rightCornerByte).
; Patches the four corner bytes of a just-drawn rectangle border so the
; outermost pixel of each corner shows the bg colour -- giving a subtle
; 1-pixel arched look. All inputs saved to scratch since SetVramByte
; clobbers A.
RoundCorners:
    ld      a, h
    ld      [RC_LB], a
    ld      a, l
    ld      [RC_RB], a
    ld      a, b
    ld      [RC_LC], a
    ld      a, d
    ld      [RC_RC], a
    ld      a, c
    ld      [RC_TY], a
    ld      a, e
    ld      [RC_BY], a

    ; Top-left
    ld      a, [RC_LC]
    ld      b, a
    ld      a, [RC_TY]
    ld      c, a
    ld      a, [RC_LB]
    call    SetVramByte
    ; Top-right
    ld      a, [RC_RC]
    ld      b, a
    ld      a, [RC_TY]
    ld      c, a
    ld      a, [RC_RB]
    call    SetVramByte
    ; Bottom-left
    ld      a, [RC_LC]
    ld      b, a
    ld      a, [RC_BY]
    ld      c, a
    ld      a, [RC_LB]
    call    SetVramByte
    ; Bottom-right
    ld      a, [RC_RC]
    ld      b, a
    ld      a, [RC_BY]
    ld      c, a
    ld      a, [RC_RB]
    ; fall through to SetVramByte

; SetVramByte(B=byteCol, C=y, A=byteValue): write a single byte to VRAM.
SetVramByte:
    ld      [SVB_TMP], a
    call    SetVramWritePos
    ld      a, [SVB_TMP]
    out     [VDP_DATA], a
    ret

RC_LB: db 0
RC_RB: db 0
RC_LC: db 0
RC_RC: db 0
RC_TY: db 0
RC_BY: db 0
SVB_TMP: db 0

; DrawRefreshGlyph: center the 8x8 right-arrow bitmap inside the refresh
; button. A = button byte col on entry. The icon is 2 bytes wide and 8 rows
; tall; we place it at byte col + 7 (button is 15 bytes wide, (15-2)/2 ~= 6,
; bumped to 7 so it reads centred given the button's left padding) and
; y = BTN_Y0 + 4 so it sits vertically centred.
DrawRefreshGlyph:
    add     a, 7
    ld      b, a                        ; B = byte column
    ld      c, BTN_Y0 + 4               ; C = top row
    ld      d, 2                        ; D = 2 bytes/row
    ld      e, 8                        ; E = 8 rows
    ld      hl, IconArrowRight
    jr      DrawBitmap

; DrawUpArrow: up-arrow at (SCROLL_ICN_X, CONTENT_Y0+3). The icon bitmap is
; 12x5 (3 bytes x 5 rows) -- an 8x5 arrow shifted right by 1 MSX pixel with
; LGRAY padding so it lines up nicely inside the widened scrollbar.
DrawUpArrow:
    ld      b, SCROLL_ICN_X / 4
    ld      c, CONTENT_Y0 + 3
    ld      d, 3
    ld      e, 5
    ld      hl, IconUpArrow
    jr      DrawBitmap

; DrawDownArrow: same bitmap, flipped vertically. Last row offset = 4 * 3 = 12.
DrawDownArrow:
    ld      b, SCROLL_ICN_X / 4
    ld      c, SCROLL_DN_Y0 + 3
    ld      d, 3
    ld      e, 5
    ld      hl, IconUpArrow + 12
    ; fall through to DrawBitmapReverse

; DrawBitmapReverse: like DrawBitmap but iterates rows in reverse memory order.
; Caller sets HL to the LAST row. After writing each row (HL advances D bytes
; forward within the row), we rewind HL by 2*D (saved pre-loop copy - D).
DrawBitmapReverse:
.nextRow:
    push    bc
    push    de
    push    hl
    call    SetVramWritePos
    pop     hl                          ; HL = current row start
    push    hl                          ; save for post-write rewind
    ld      b, d
.rowLoop:
    ld      a, [hl]
    out     [VDP_DATA], a
    inc     hl
    djnz    .rowLoop
    pop     hl                          ; restore current row start
    ld      a, l                        ; HL -= D (previous row start)
    sub     d
    ld      l, a
    jr      nc, .noBorrow
    dec     h
.noBorrow:
    pop     de
    pop     bc
    inc     c
    dec     e
    jr      nz, .nextRow
    ret

; DrawBitmap: blit packed Screen-6 bitmap to VRAM at (B*4, C), D bytes * E rows.
;   B = byte column (x/4)
;   C = first row
;   D = bytes per row
;   E = rows
;   HL = data pointer (D*E bytes)
DrawBitmap:
.nextRow:
    push    bc
    push    de
    push    hl
    call    SetVramWritePos             ; clobbers HL; uses B, C
    pop     hl
    ld      b, d                        ; bytes/row counter
.rowLoop:
    ld      a, [hl]
    out     [VDP_DATA], a
    inc     hl
    djnz    .rowLoop
    pop     de
    pop     bc
    inc     c
    dec     e
    jr      nz, .nextRow
    ret

; PaintAddressBar: white interior + focus-coloured border + URL text.
; Uses [ButtonState] for focus bit.
PaintAddressBar:
    ld      b, ADDR_X0 / 4
    ld      c, BTN_Y0
    ld      d, (ADDR_X1 - ADDR_X0 + 1) / 4
    ld      e, BTN_H
    ld      a, COL_WHITE
    call    FillRect

    ld      b, ADDR_X0 / 4
    ld      c, BTN_Y0
    ld      d, (ADDR_X1 - ADDR_X0 + 1) / 4
    ld      e, BTN_H
    ld      a, [ButtonState]
    and     BTN_FOCUSED
    jr      z, .addrDgray               ; unfocused: dark-gray border
    ld      a, COL_BLACK                ; focused: black border
    call    DrawRectBorder
    ; Full-bg corner bytes (WHITE pair 10 -> 0xAA) so rounding is symmetric.
    ld      hl, 0xAAAA
    jr      .addrRound
.addrDgray:
    ld      a, COL_DGRAY
    call    DrawRectBorder
    ld      hl, 0xAAAA
.addrRound:
    ld      b, ADDR_X0 / 4
    ld      a, ADDR_X0 / 4 + (ADDR_X1 - ADDR_X0 + 1) / 4 - 1
    ld      d, a
    ld      c, BTN_Y0
    ld      e, BTN_Y0 + BTN_H - 1
    call    RoundCorners

    ; URL text.
    ld      a, COL_BLACK
    ld      l, COL_WHITE
    call    SetTextColours
    ld      de, ADDR_X0 + 4
    ld      c, BTN_Y0 + 4
    ld      hl, UrlBuf
    call    DrawString

    ; Clear-button glyph at right edge of the address bar (visual hint for
    ; Ctrl+L = MSX CLS). Dark-gray so it doesn't compete with the URL.
    ld      a, COL_DGRAY
    ld      l, COL_WHITE
    call    SetTextColours
    ld      de, ADDR_X1 - 12
    ld      c, BTN_Y0 + 3
    ld      hl, CharLowerX
    jp      DrawString

; ============================================================================
; Text rendering via BIOS GRPPRT
;   GRPPRT (0x008D) draws A at graphic cursor (GRPACX, GRPACY) using FORCLR/
;   BAKCLR. CALSLT is invoked via .CALLBIOS.
; ============================================================================

FORCLR          equ 0xF3E9
BAKCLR          equ 0xF3EA
GRPACX          equ 0xFCB7
GRPACY          equ 0xFCB9

; DrawString(DE=x pixel, C=y pixel, HL=NUL-terminated string).
DrawString:
    ld      [GRPACX], de
    ld      a, c
    ld      [GRPACY], a
    xor     a
    ld      [GRPACY + 1], a
.loop:
    ld      a, [hl]
    or      a
    ret     z
    push    hl
    .CALLBIOS GRPPRT
    pop     hl
    inc     hl
    jr      .loop

; SetTextColours(A=fg, L=bg).
SetTextColours:
    ld      [FORCLR], a
    ld      a, l
    ld      [BAKCLR], a
    ret

; ============================================================================
; Step 2: Font extraction + direct-blit text rendering
;
; The BIOS GRPPRT path is slot-switched per character (CALSLT on every glyph)
; and runs at roughly 40 K cycles/char under openMSX. We replace it with:
;
;   1. ExtractFont  -- one-off byte-by-byte copy of the main-ROM's CGTABL
;                      (256 glyphs * 8 rows = 2 KB) into FontBuf.
;   2. DrawCharFast -- per glyph, set the VRAM write pointer once per row and
;                      emit two packed Screen-6 bytes straight to port 0x98.
;                      A 16-entry LUT expands a 4-bit font nibble to one
;                      2bpp byte (01 = bg/lgray, 11 = fg/black).
;
; No BIOS calls in the hot path; just port I/O and a LUT lookup per nibble.
; ============================================================================

; FontLUT: nibble -> Screen-6 byte. Each 2-bit pair has its high bit always
; set so bg renders as COL_WHITE (value 10) and set pixels as COL_BLACK
; (value 11). The low bit of each pair is the matching font bit (1 = set).
; This matches the content area's white fill.
; 4-bit nibble -> 2bpp Screen 6 byte, with fg pixels set to the chosen
; palette pair and bg pixels kept at pair 10 (WHITE). DrawCharFast
; dereferences CurrentFontLUT to pick one of the variants below.
FontLUT:                                ; fg = BLACK (pair 11)
    db  0xAA, 0xAB, 0xAE, 0xAF, 0xBA, 0xBB, 0xBE, 0xBF
    db  0xEA, 0xEB, 0xEE, 0xEF, 0xFA, 0xFB, 0xFE, 0xFF

FontLUT_LGray:                          ; fg = LGRAY (pair 01)
    db  0xAA, 0xA9, 0xA6, 0xA5, 0x9A, 0x99, 0x96, 0x95
    db  0x6A, 0x69, 0x66, 0x65, 0x5A, 0x59, 0x56, 0x55

FontLUT_DGray:                          ; fg = DGRAY (pair 00)
    db  0xAA, 0xA8, 0xA2, 0xA0, 0x8A, 0x88, 0x82, 0x80
    db  0x2A, 0x28, 0x22, 0x20, 0x0A, 0x08, 0x02, 0x00

; ExtractFont: copy the 2 KB font into FontBuf using the live CGPNT pointer.
; CGPNT[0]   = slot specifier holding the font
; CGPNT[1..2] = address of the font within that slot (little-endian)
; One RDSLT call per byte; the ~60 ms total is a one-time startup cost.
ExtractFont:
    ld      a, [CGPNT]                  ; CGPNT[0] = slot
    ld      [FastCgSlot], a
    ld      hl, [CGPNT + 1]             ; CGPNT[1..2] = font address in slot
    ld      de, FontBuf
    ld      bc, FONT_BUF_SIZE
.loop:
    push    bc
    push    de
    push    hl
    ld      a, [FastCgSlot]
    .CALLBIOS RDSLT
    pop     hl
    pop     de
    ld      [de], a
    inc     hl
    inc     de
    pop     bc
    dec     bc
    ld      a, b
    or      c
    jr      nz, .loop
    ret

; DrawCharFast: blit an 8x8 glyph to Screen-6 VRAM.
;   A = character code (0..255)
;   B = byte column (x / 4)   -- pixel x must be a multiple of 4
;   C = y pixel (0..211)
; Writes 2 VRAM bytes * 8 rows. Clobbers A, DE, HL.
DrawCharFast:
    ld      l, a
    ld      h, 0
    add     hl, hl
    add     hl, hl
    add     hl, hl                      ; HL = char * 8
    ld      de, FontBuf
    add     hl, de
    ld      [FastFontPtr], hl

    ld      a, 8
    ld      [FastRowsLeft], a

.rowLoop:
    ld      hl, [FastFontPtr]
    ld      a, [hl]
    inc     hl
    ld      [FastFontPtr], hl

    ; ---- Style: bold (OR with self shifted right 1) ----
    push    bc
    ld      c, a
    ld      b, a
    ld      a, [HtmlStyleFlags]
    and     STYLE_BOLD
    ld      a, c
    jr      z, .sNoBold
    srl     a
    or      b
.sNoBold:

    ; ---- Style: italic. Rows 0-1 shift right 1, rows 6-7 shift left 1.
    ; Rows count down 8..1 in FastRowsLeft.
    ld      b, a
    ld      a, [HtmlStyleFlags]
    and     STYLE_ITALIC
    ld      a, b
    jr      z, .sNoItalic
    ; Determine shift based on row.
    push    af
    ld      a, [FastRowsLeft]
    cp      7                           ; RowsLeft >= 7 -> rows 0..1
    jr      nc, .iTop
    cp      3                           ; RowsLeft < 3 -> rows 6..7
    jr      c, .iBottom
    ; Middle rows (RowsLeft 3..6): no shift.
    pop     af
    jr      .sNoItalic
.iTop:
    pop     af
    srl     a                           ; shift pixels right by 1
    jr      .sNoItalic
.iBottom:
    pop     af
    sla     a                           ; shift pixels left by 1
.sNoItalic:

    ; ---- Strike on row 3 (RowsLeft == 5) ----
    ld      b, a
    ld      a, [FastRowsLeft]
    cp      5
    ld      a, b
    jr      nz, .sNoStrike
    ld      c, a
    ld      a, [HtmlStyleFlags]
    and     STYLE_STRIKE
    ld      a, c
    jr      z, .sNoStrike
    ld      a, 0xFF
.sNoStrike:

    ; ---- Underline on row 7 (RowsLeft == 1) ----
    ; Solid (0xFF) normally; dotted (0xEE = BLACK WHITE BLACK WHITE per
    ; byte) when STYLE_FOCUSED is set -- marks the Tab-focused link.
    ld      b, a
    ld      a, [FastRowsLeft]
    cp      1
    ld      a, b
    jr      nz, .sNoUL
    ld      c, a
    ld      a, [HtmlStyleFlags]
    and     STYLE_UNDERLINE
    ld      a, c
    jr      z, .sNoUL
    ld      a, [HtmlStyleFlags]
    and     STYLE_FOCUSED
    jr      nz, .sDottedUL
    ld      a, 0xFF
    jr      .sNoUL
.sDottedUL:
    ld      a, 0xEE
.sNoUL:

    pop     bc
    ld      [FastFontByte], a

    ; ---- Output the styled row to VRAM ----
    push    bc
    call    SetVramWritePos
    pop     bc
    ld      a, [FastFontByte]
    call    EmitStyledByte
    inc     c

    ; ---- Scale 2x: output the same row again one pixel-row lower ----
    ld      a, [HtmlScaleY]
    cp      2
    jr      nz, .rowDone
    push    bc
    call    SetVramWritePos
    pop     bc
    ld      a, [FastFontByte]
    call    EmitStyledByte
    inc     c

.rowDone:
    ld      a, [FastRowsLeft]
    dec     a
    ld      [FastRowsLeft], a
    jp      nz, .rowLoop
    ret

; EmitStyledByte: split A (= 2bpp pixel byte) into high/low nibble, map each
; through FontLUT, and send both bytes to the VDP data port. HL and A are
; clobbered; BC, DE preserved.
EmitStyledByte:
    push    af
    and     0xF0
    rrca
    rrca
    rrca
    rrca
    ld      hl, [CurrentFontLUT]
    ld      d, 0
    ld      e, a
    add     hl, de
    ld      a, [hl]
    out     [VDP_DATA], a
    pop     af
    and     0x0F
    ld      hl, [CurrentFontLUT]
    ld      d, 0
    ld      e, a
    add     hl, de
    ld      a, [hl]
    out     [VDP_DATA], a
    ret

; ============================================================================
; Step 2: URL parsing + file I/O
; ============================================================================

; BuildFcbFromUrl: parse UrlBuf into Fcb. Accepted forms:
;   "A:\TEST.HTM", "a:test.htm", "test.htm", "TEST.HTML" (ext truncated to 3).
; Letters uppercased; other chars pass through. Always returns.
BuildFcbFromUrl:
    ld      hl, Fcb
    ld      b, 12
    xor     a
.zf:
    ld      [hl], a
    inc     hl
    djnz    .zf

    ld      hl, UrlBuf
    ld      a, [hl]
    or      a
    ret     z                           ; empty URL

    ; Optional drive letter: check for "X:" prefix.
    inc     hl
    ld      b, a                        ; B = first char
    ld      a, [hl]
    cp      ':'
    jr      nz, .noDrive
    ld      a, b
    and     0x5F                        ; uppercase
    sub     'A' - 1                     ; A=1, B=2, ...
    ld      [Fcb], a
    inc     hl
    jr      .checkSlash
.noDrive:
    dec     hl                          ; back to first char

.checkSlash:
    ld      a, [hl]
    cp      0x5C                        ; backslash
    jr      z, .skipSlash
    cp      '/'
    jr      nz, .copyName
.skipSlash:
    inc     hl

.copyName:
    ld      de, Fcb + 1
    ld      b, 8
.cn:
    ld      a, [hl]
    or      a
    jr      z, .padName
    cp      '.'
    jr      z, .padName
    call    UpperCaseA
    ld      [de], a
    inc     de
    inc     hl
    djnz    .cn
.skipExtra:
    ld      a, [hl]
    or      a
    jr      z, .fillExt
    cp      '.'
    jr      z, .afterDot
    inc     hl
    jr      .skipExtra

.padName:
    ld      a, ' '
.pn:
    ld      [de], a
    inc     de
    dec     b
    jr      nz, .pn
    ld      a, [hl]
    or      a
    jr      z, .fillExt
    cp      '.'
    jr      nz, .fillExt

.afterDot:
    inc     hl
    ld      b, 3
.ce:
    ld      a, [hl]
    or      a
    jr      z, .padExt
    call    UpperCaseA
    ld      [de], a
    inc     de
    inc     hl
    djnz    .ce
    ret

.padExt:
    ld      a, ' '
.pe:
    ld      [de], a
    inc     de
    dec     b
    jr      nz, .pe
    ret

; DetectPlainText: set PlainTextMode = 1 when the FCB's extension is
; "TXT", else 0. Must be called AFTER BuildFcbFromUrl so the three
; extension bytes at Fcb+9..11 are populated (uppercased, space-padded).
DetectPlainText:
    xor     a
    ld      [PlainTextMode], a
    ld      a, [Fcb + 9]
    cp      'T'
    ret     nz
    ld      a, [Fcb + 10]
    cp      'X'
    ret     nz
    ld      a, [Fcb + 11]
    cp      'T'
    ret     nz
    ld      a, 1
    ld      [PlainTextMode], a
    ret

.fillExt:
    ld      a, ' '
    ld      b, 3
.fe:
    ld      [de], a
    inc     de
    dec     b
    jr      nz, .fe
    ret

; UpperCaseA: if A is 'a'..'z', subtract 32.
UpperCaseA:
    cp      'a'
    ret     c
    cp      'z' + 1
    ret     nc
    sub     32
    ret

; LoadFile: open via Fcb, read up to FILE_BUF_SIZE bytes into FileBuf, close.
;   On success A=0, FileLen = bytes actually read (capped at buffer size).
;   On failure A!=0 (file not found etc.).
LoadFile:
    ld      hl, Fcb + 12                ; zero FCB internal state
    ld      b, 24
    xor     a
.z:
    ld      [hl], a
    inc     hl
    djnz    .z

    ld      c, DOS_OPEN
    ld      de, Fcb
    call    BDOS_ENTRY
    or      a
    ret     nz

    ; FileLen = min(file size from FCB+16, FILE_BUF_SIZE).
    ld      hl, [Fcb + 16]
    ld      [FileLen], hl
    ld      de, FILE_BUF_SIZE
    or      a
    sbc     hl, de
    jr      c, .sizeOk
    ld      hl, FILE_BUF_SIZE
    ld      [FileLen], hl
.sizeOk:

    ld      hl, FileBuf
    ld      b, FILE_BUF_SIZE / 128
.rl:
    push    bc
    push    hl
    ex      de, hl                      ; DE = DMA target
    ld      c, DOS_SETDMA
    call    BDOS_ENTRY
    ld      c, DOS_READ
    ld      de, Fcb
    call    BDOS_ENTRY
    or      a
    pop     hl
    pop     bc
    jr      nz, .done
    ld      de, 128
    add     hl, de
    djnz    .rl

.done:
    ld      c, DOS_CLOSE
    ld      de, Fcb
    call    BDOS_ENTRY
    xor     a
    ret

; ============================================================================
; Step 2: Content area rendering
; ============================================================================

; ClearContentArea: white fill of content region (x=0..495, y=29..211).
ClearContentArea:
    ld      b, 0
    ld      c, CONTENT_Y0
    ld      d, (CONTENT_X_END + 1) / 4
    ld      e, CONTENT_Y1 - CONTENT_Y0 + 1
    ld      a, COL_WHITE
    jp      FillRect

; ============================================================================
; Step 3: HTML 2.0 parser + renderer
;
; One pass over FileBuf. For each byte:
;   '<'  -> parse a tag (comment / open / close), dispatch
;   '&'  -> parse an entity, emit the decoded char
;   else -> emit as display character (with whitespace collapse)
;
; Style and document-state flags (see HtmlStyleFlags, HtmlInHead, etc. below)
; drive EmitText / EmitGlyph so inline formatting turns into visible output.
; ============================================================================

; Style bits packed into HtmlStyleFlags.
STYLE_BOLD      equ 0x01
STYLE_ITALIC    equ 0x02
STYLE_UNDERLINE equ 0x04
STYLE_STRIKE    equ 0x08
STYLE_FOCUSED   equ 0x10                ; active link -> dotted underline

TITLE_BUF_MAX   equ 31                  ; chars captured from <title>
LINK_MAX        equ 8                   ; max <a> rects per rendered page
LINK_URL_MAX    equ 32                  ; max chars per href (plus NUL)

PrintFileContent:
    ld      a, [FileLen]
    ld      b, a
    ld      a, [FileLen + 1]
    or      b
    ret     z

    ; --- Reset HTML parser state ---
    xor     a
    ld      [HtmlInHead], a
    ld      [HtmlInTitle], a
    ld      [HtmlStyleFlags], a
    ld      [HtmlWsPending], a
    ld      a, 1
    ld      [HtmlLineEmpty], a          ; trim leading whitespace
    xor     a
    ld      [HtmlTitleLen], a
    ld      [HtmlTitleSeen], a
    ld      [HtmlLineCount], a
    ld      [HtmlInAnchor], a
    ld      [LinkCount], a
    ld      [LineLen], a                ; drop any cells left from previous render
    ld      [ArLen], a
    ld      [EmitCellAttr], a
    ld      [HtmlAlign], a
    ld      [HtmlDir], a
    ; .txt files: enable <pre>-style whitespace preservation so LF/CR
    ; produce real newlines and spaces/tabs aren't collapsed.
    ld      a, [PlainTextMode]
    ld      [HtmlPre], a
    ld      [HtmlLiPending], a
    ld      [HtmlListKind], a
    ld      [HtmlOlCounter], a
    ld      [HtmlIndent], a
    ld      [HtmlInTable], a
    ld      [HtmlTableCol], a
    ld      [HtmlTableFirst], a
    ld      [HtmlRowTopY], a
    ld      [HtmlFgDepth], a
    ld      a, COL_BLACK
    ld      [HtmlFg], a
    ld      a, [ScrollLine]             ; skip this many rendered lines
    ld      [HtmlLineSkip], a
    ld      a, 1
    ld      [HtmlScaleY], a

    ; Reset cursor to content top-left.
    xor     a
    ld      [TextX], a
    ld      [TextX + 1], a
    ld      a, CONTENT_Y0
    ld      [TextY], a

    ; HtmlEnd = FileBuf + FileLen
    ld      hl, FileBuf
    ld      de, [FileLen]
    add     hl, de
    ld      [HtmlEnd], hl

    ld      hl, FileBuf

.loop:
    ; End-of-buffer check.
    push    hl
    ld      de, [HtmlEnd]
    and     a
    sbc     hl, de
    pop     hl
    jr      nc, .eof                    ; hl >= end -> flush final line

    ld      a, [hl]
    inc     hl

    ; Plain-text mode bypasses tag and entity parsing; every byte is text.
    ld      b, a
    ld      a, [PlainTextMode]
    or      a
    ld      a, b
    jr      nz, .emit

    cp      '<'
    jr      z, .tag
    cp      '&'
    jr      z, .entity
    jr      .emit

.emit:
    ; EmitText / TitleAppend / EmitRaw all clobber HL for VRAM or buffer
    ; work; the main loop needs HL to stay on the source stream.
    push    hl
    call    EmitText
    pop     hl
    jr      .loop

.eof:
    ; Drain any trailing Arabic word and pending line cells so content
    ; that doesn't end with a block tag still reaches VRAM. Without this
    ; the buffer would leak into the top of the next rendered page.
    call    ArFlush
    call    LineFlush
    ret

.tag:
    ; Flush any pending Arabic word BEFORE the tag handler runs so that
    ; style/scale changes in </h1> etc. don't catch the buffer mid-word
    ; and emit its trailing letters at the post-tag scale.
    push    hl
    call    ArFlush
    pop     hl
    call    ParseTag
    jr      .loop

.entity:
    push    hl
    call    ArFlush
    pop     hl
    call    ParseEntity                 ; returns A = char (0 if invalid)
    push    hl
    or      a
    jr      z, .entityDone
    call    EmitText
.entityDone:
    pop     hl
    jr      .loop

; ----------------------------------------------------------------------------
; EmitText: consume one source character (or entity result) into the output
; stream, applying whitespace collapse and <head>/<title> routing.
;   A  = char
;   HL preserved.
; ----------------------------------------------------------------------------
EmitText:
    ; <pre>: preserve whitespace verbatim. LF / CR drive an EmitNewline,
    ; other chars pass straight through EmitSink without collapse.
    ld      b, a
    ld      a, [HtmlPre]
    or      a
    ld      a, b
    jr      z, .normal
    cp      0x0A
    jp      z, EmitNewline
    cp      0x0D
    ret     z
    jp      EmitSink

.normal:
    ; Normalize whitespace: space / tab / CR / LF all map to ' '.
    cp      ' '
    jr      z, .ws
    cp      0x09
    jr      z, .ws
    cp      0x0A
    jr      z, .ws
    cp      0x0D
    jr      z, .ws

    ; Non-whitespace path. A bullet / number prefix (from <li>) fires
    ; before the real glyph and before any pending-space flush, so each
    ; list item is introduced with exactly one bullet.
    ld      b, a
    ld      a, [HtmlLiPending]
    or      a
    jr      z, .noLi
    xor     a
    ld      [HtmlLiPending], a
    push    bc
    call    EmitListBullet
    pop     bc
.noLi:

    ; Flush a pending space (collapse rule). Route the flushed space through
    ; EmitSink so a space inside <title> lands in the title buffer.
    ld      a, [HtmlWsPending]
    or      a
    jr      z, .noFlush
    xor     a
    ld      [HtmlWsPending], a
    push    bc
    ld      a, ' '
    call    EmitSink
    pop     bc
.noFlush:
    xor     a
    ld      [HtmlLineEmpty], a
    ld      a, b
    jp      EmitSink

.ws:
    ; Leading whitespace on a fresh line is dropped.
    ld      a, [HtmlLineEmpty]
    or      a
    ret     nz
    ld      a, 1
    ld      [HtmlWsPending], a
    ret

; EmitListBullet: print "* " for <ul> / "N. " for <ol>, then the caller
; continues with the item's own text. Consumes HtmlOlCounter for ordered
; lists. Preserves HL.
EmitListBullet:
    push    hl
    ld      a, [HtmlListKind]
    cp      1
    jr      z, .bul
    cp      2
    jr      z, .num
    pop     hl
    ret

.bul:
    ld      a, '*'
    call    EmitSink
    ld      a, ' '
    call    EmitSink
    pop     hl
    ret

.num:
    ld      a, [HtmlOlCounter]
    inc     a
    ld      [HtmlOlCounter], a
    ; Print decimal digits (1..99 supported; higher shows as 2-digit mod).
    cp      10
    jr      c, .num1
    push    af
    ld      b, '0'
.tens:
    inc     b
    sub     10
    cp      10
    jr      nc, .tens
    push    af
    ld      a, b
    call    EmitSink
    pop     af
    add     a, '0'
    call    EmitSink
    pop     bc
    jr      .numTail
.num1:
    add     a, '0'
    call    EmitSink
.numTail:
    ld      a, '.'
    call    EmitSink
    ld      a, ' '
    call    EmitSink
    pop     hl
    ret

; EmitSink: route the single character in A to wherever the current state
; says it should go -- title buffer, nowhere (inside <head>), or the canvas
; (via the Arabic shaper). Must preserve nothing.
EmitSink:
    ld      b, a
    ld      a, [HtmlInTitle]
    or      a
    jr      nz, .toTitle
    ld      a, [HtmlInHead]
    or      a
    ld      a, b
    ret     nz
    ld      a, b
    jp      EmitIsoByte                 ; canvas: shape + mirror per-word
.toTitle:
    ; Title: flat ISO->isolated glyph lookup (no shaping/mirroring).
    ld      a, b
    cp      0x80
    jp      c, TitleAppend
    sub     0x80
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl                      ; *4
    ld      de, IsoMap
    add     hl, de
    ld      a, [hl]
    jp      TitleAppend

; ----------------------------------------------------------------------------
; Step 5A: ISO-8859-6 byte gateway.
;
; EmitIsoByte buffers Arabic bytes (IsoJoin != 0) into ArBuf and only
; spills to EmitRaw on a word boundary, passing the whole reshaped word
; through ArFlush in reversed (visual) order. Boundary bytes (ASCII and
; Arabic punctuation / digits) first flush any pending Arabic word, then
; go straight to EmitRaw as a single glyph (ASCII stays as-is; upper ISO
; bytes are looked up in IsoMap[.Isolated]).
; ----------------------------------------------------------------------------
EmitIsoByte:
    push    bc
    push    hl
    push    de
    ld      c, a                        ; save raw ISO byte

    cp      0x80
    jr      c, .isBoundary              ; ASCII always a boundary
    sub     0x80
    ld      h, 0
    ld      l, a
    ld      de, IsoJoin
    add     hl, de
    ld      a, [hl]                     ; A = join flags of current byte
    and     IS_ARABIC
    jr      z, .isBoundary              ; not an Arabic letter -> boundary

    ; Arabic-joining byte: try to fuse a preceding lam (E4) with the
    ; incoming alef-variant into one ligature ISO code. The ligatures
    ; (F3..F6) resolve to the single font glyph EC/ED/EE/EF via IsoMap.
    ;   E4 (ل) + C2 (آ) -> F3 ﻵ
    ;   E4 (ل) + C3 (أ) -> F4 ﻷ
    ;   E4 (ل) + C5 (إ) -> F5 ﻹ
    ;   E4 (ل) + C7 (ا) -> F6 ﻻ
    ld      a, c
    call    LamAlefLigature             ; A = ligature ISO code, or 0 if none
    or      a
    jr      z, .append                  ; incoming byte isn't an alef-variant
    ld      b, a                        ; stash ligature code
    ld      a, [ArLen]
    or      a
    jr      z, .append                  ; buffer empty -> no lam to fuse
    dec     a
    ld      h, 0
    ld      l, a
    ld      de, ArBuf
    add     hl, de                      ; HL -> ArBuf[last]
    ld      a, [hl]
    cp      0xE4
    jr      nz, .append                 ; last byte isn't lam -> normal append
    ld      [hl], b                     ; overwrite lam with ligature code
    pop     de
    pop     hl
    pop     bc
    ret

.append:
    ld      a, [ArLen]
    cp      AR_BUF_MAX
    jr      c, .hasRoom
    call    ArFlush
.hasRoom:
    ld      a, [ArLen]
    ld      h, 0
    ld      l, a
    ld      de, ArBuf
    add     hl, de
    ld      [hl], c                     ; append
    ld      a, [ArLen]
    inc     a
    ld      [ArLen], a
    pop     de
    pop     hl
    pop     bc
    ret

.isBoundary:
    call    ArFlush                     ; flush any pending Arabic word
    ld      a, c
    cp      0x80
    jr      c, .emit                    ; ASCII passes through unchanged
    ; Upper ISO byte with JOIN=0: look up isolated glyph.
    sub     0x80
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl                      ; *4
    ld      de, IsoMap
    add     hl, de
    ld      a, [hl]
.emit:
    call    EmitRaw
    pop     de
    pop     hl
    pop     bc
    ret

; ArFlush: shape each byte in ArBuf and emit it to the per-line buffer in
; LOGICAL left-to-right order, flagged CELL_RTL. Actual visual reversal
; happens later at LineFlush time (so paragraph-level BiDi can also reorder
; multi-word Arabic runs). Re-entrant: marks the buffer empty before the
; emit loop so an EmitRaw->EmitNewline->ArFlush path sees ArLen=0.
ArFlush:
    ld      a, [ArLen]
    or      a
    ret     z
    push    bc
    push    de
    push    hl

    ld      b, a                        ; B = count N
    xor     a
    ld      [ArLen], a

    ld      c, 0                        ; C walks 0..N-1 (logical order)
.loop:
    ld      a, c
    cp      b
    jr      z, .done

    ld      a, c
    call    ShapePick                   ; A = form, ArCurr = current byte
    ld      e, a
    ld      a, [ArCurr]
    sub     0x80
    ld      h, 0
    ld      l, a
    add     hl, hl
    add     hl, hl                      ; *4
    ld      a, e
    ld      d, 0
    ld      e, a
    add     hl, de                      ; + form
    ld      de, IsoMap
    add     hl, de
    ld      a, [hl]                     ; glyph

    push    bc
    ld      b, a
    ld      a, CELL_RTL
    ld      [EmitCellAttr], a
    ld      a, b
    call    EmitRaw
    xor     a
    ld      [EmitCellAttr], a
    pop     bc

    inc     c
    jr      .loop
.done:
    pop     hl
    pop     de
    pop     bc
    ret

; ShapePick: given A = index and B = count, return the form for ArBuf[A].
; Out: A = form (0=Isolated, 1=End, 2=Initial, 3=Middle)
;      ArCurr = ArBuf[index]  (current byte, for the caller's glyph lookup)
; Preserves B and C; freely uses DE, HL, and the ArConnect scratch byte.
SHAPE_MASK_PREV equ 0x10                ; prev letter connects to curr's right
SHAPE_MASK_NEXT equ 0x20                ; curr connects forward to next letter

ShapePick:
    ; Stash the index in C (also the live value the caller passed in, but
    ; belt-and-braces so we can overwrite A freely).
    ld      c, a

    ; Clear the connect accumulator.
    xor     a
    ld      [ArConnect], a

    ; curr = ArBuf[C]; save in ArCurr for the caller's glyph lookup.
    ld      h, 0
    ld      l, c
    ld      de, ArBuf
    add     hl, de
    ld      a, [hl]
    ld      [ArCurr], a

    ; currFlags = IsoJoin[curr - 0x80]
    sub     0x80
    ld      h, 0
    ld      l, a
    ld      de, IsoJoin
    add     hl, de
    ld      a, [hl]
    ld      [ArCurrFlags], a            ; stash — prev-neighbor's `ld de, ArBuf` clobbers E
    ld      e, a                        ; E = curr flags (JOIN_LEFT/RIGHT)

    ; --- prev neighbor ---------------------------------------------------
    ;   prev connects if  (C > 0)
    ;                && (curr & JOIN_RIGHT)
    ;                && (IsoJoin[prev-0x80] & JOIN_LEFT).
    ld      a, c
    or      a
    jr      z, .prevDone
    ld      a, e
    and     JOIN_RIGHT
    jr      z, .prevDone
    ld      a, c
    dec     a
    ld      h, 0
    ld      l, a
    ld      d, 0                        ; DE = ArBuf (already loaded above? no -- reload)
    ld      de, ArBuf
    add     hl, de
    ld      a, [hl]                     ; prev byte
    sub     0x80
    ld      h, 0
    ld      l, a
    ld      de, IsoJoin
    add     hl, de
    ld      a, [hl]
    and     JOIN_LEFT
    jr      z, .prevDone
    ld      a, [ArConnect]
    or      SHAPE_MASK_PREV
    ld      [ArConnect], a
.prevDone:

    ; --- next neighbor ---------------------------------------------------
    ;   next connects if  (C+1 < B)
    ;                && (curr & JOIN_LEFT)
    ;                && (IsoJoin[next-0x80] & JOIN_RIGHT).
    ld      a, c
    inc     a
    cp      b
    jr      nc, .nextDone
    ld      a, [ArCurrFlags]            ; reload: E was clobbered by prev-neighbor branch
    and     JOIN_LEFT
    jr      z, .nextDone
    ld      a, c
    inc     a
    ld      h, 0
    ld      l, a
    ld      de, ArBuf
    add     hl, de
    ld      a, [hl]                     ; next byte
    sub     0x80
    ld      h, 0
    ld      l, a
    ld      de, IsoJoin
    add     hl, de
    ld      a, [hl]
    and     JOIN_RIGHT
    jr      z, .nextDone
    ld      a, [ArConnect]
    or      SHAPE_MASK_NEXT
    ld      [ArConnect], a
.nextDone:

    ; --- map connect bits to form ---------------------------------------
    ;   prev & next -> 3 (Middle)
    ;   prev only   -> 1 (End)
    ;   next only   -> 2 (Initial)
    ;   neither     -> 0 (Isolated)
    ld      a, [ArConnect]
    cp      SHAPE_MASK_PREV | SHAPE_MASK_NEXT
    jr      z, .formMid
    cp      SHAPE_MASK_PREV
    jr      z, .formEnd
    cp      SHAPE_MASK_NEXT
    jr      z, .formIni
    xor     a                           ; Isolated
    ret
.formEnd:
    ld      a, 1
    ret
.formIni:
    ld      a, 2
    ret
.formMid:
    ld      a, 3
    ret

; LamAlefLigature: if A is an alef-variant that can fuse with a preceding
; ل, return the matching ligature ISO code in A; else return A = 0.
;   C2 (آ) -> F3   C3 (أ) -> F4   C5 (إ) -> F5   C7 (ا) -> F6
; Preserves BC, DE, HL.
LamAlefLigature:
    cp      0xC2
    jr      z, .aF3
    cp      0xC3
    jr      z, .aF4
    cp      0xC5
    jr      z, .aF5
    cp      0xC7
    jr      z, .aF6
    xor     a
    ret
.aF3:
    ld      a, 0xF3
    ret
.aF4:
    ld      a, 0xF4
    ret
.aF5:
    ld      a, 0xF5
    ret
.aF6:
    ld      a, 0xF6
    ret

; EmitRaw: feed one glyph into the per-line buffer (drawn later by LineFlush).
;   A  = char
; Wraps at CONTENT_X_END and is a no-op while HtmlLineSkip > 0 (scrolled lines).
; Picks up the cell attr byte from EmitCellAttr (ArFlush sets CELL_RTL there).
EmitRaw:
    push    hl
    push    bc

    ld      b, a                        ; B = glyph
    ld      a, [HtmlLineSkip]
    or      a
    jr      nz, .done                   ; suppressed: no buffer, no wrap, no advance

    ; Wrap: if TextX > CONTENT_X_END - 6, newline (flushes buffer) then retry.
    ld      hl, [TextX]
    ld      de, CONTENT_X_END - 6
    and     a
    sbc     hl, de
    jr      c, .posOk
    push    bc
    call    EmitNewline                 ; flushes line + advances TextY
    pop     bc
.posOk:

    ; Bottom check: past canvas bottom -> advance cursor silently (no append).
    ld      a, [HtmlScaleY]
    add     a, a
    add     a, a
    add     a, a                        ; A = 8 * ScaleY
    ld      c, a
    ld      a, [TextY]
    add     a, c
    cp      CONTENT_Y1 + 2
    jr      nc, .advance

    ; --- Append (glyph, attr) to line buffer ---
    ld      a, [LineLen]
    cp      LINE_BUF_MAX
    jr      nc, .advance                ; full: drop glyph (wrap should prevent)
    ld      e, a
    ld      d, 0
    ld      hl, LineGlyph
    add     hl, de
    ld      [hl], b                     ; glyph
    ld      hl, LineAttr
    add     hl, de
    ld      a, [EmitCellAttr]
    ld      c, a                        ; keep attr for neutral fixup
    ; Space glyph (0x20) in an LTR cell -> mark as Neutral (takes direction
    ; of surrounding strong cells during BiDi neutral resolution).
    and     CELL_RTL
    jr      nz, .storeAttr              ; RTL cell: trust caller
    ld      a, b
    cp      0x20
    jr      nz, .storeAttr
    ld      a, c
    or      CELL_NEUTRAL
    ld      c, a
.storeAttr:
    ld      [hl], c
    ld      a, [LineLen]
    inc     a
    ld      [LineLen], a

.advance:
    ld      hl, [TextX]
    ld      de, 8
    add     hl, de
    ld      [TextX], hl

.done:
    pop     bc
    pop     hl
    ret

; ----------------------------------------------------------------------------
; LineFlush: resolve neutrals, apply BiDi L2 reordering, then draw cells
; with horizontal alignment. Clears the buffer on exit. Uses current global
; style state (HtmlStyleFlags, HtmlFg, HtmlScaleY) for every cell — mid-line
; style switches degrade to "last style wins" for this step.
; ----------------------------------------------------------------------------
LineFlush:
    ld      a, [LineLen]
    or      a
    ret     z

    call    LineResolveNeutrals
    call    LineBidiReorder
    call    LineDrawCells

    xor     a
    ld      [LineLen], a
    ret

; --- Per-cell accessors. A = index on entry (for Get) or index+value (Set). ---
; All preserve BC/DE/HL except as documented.

; LGet_Attr: A = LineAttr[A]. Preserves all regs except A/F.
LGet_Attr:
    push    hl
    push    de
    ld      e, a
    ld      d, 0
    ld      hl, LineAttr
    add     hl, de
    ld      a, [hl]
    pop     de
    pop     hl
    ret

; LGet_Glyph: A = LineGlyph[A]. Preserves all regs except A/F.
LGet_Glyph:
    push    hl
    push    de
    ld      e, a
    ld      d, 0
    ld      hl, LineGlyph
    add     hl, de
    ld      a, [hl]
    pop     de
    pop     hl
    ret

; LSet_Attr: LineAttr[A] = B. Preserves all regs except A/F.
LSet_Attr:
    push    hl
    push    de
    ld      e, a
    ld      d, 0
    ld      hl, LineAttr
    add     hl, de
    ld      a, b
    ld      [hl], a
    pop     de
    pop     hl
    ret

; SwapCells: swap LineGlyph[i]<->LineGlyph[j] and LineAttr[i]<->LineAttr[j].
; Inputs via scratch bytes SW_i and SW_j. Clobbers A, B, flags.
SwapCellsAtIJ:
    ; glyph[i] -> SW_gi
    ld      a, [SW_i]
    call    LGet_Glyph
    ld      [SW_gi], a
    ; glyph[j] -> SW_gj
    ld      a, [SW_j]
    call    LGet_Glyph
    ld      [SW_gj], a
    ; attr[i] -> SW_ai
    ld      a, [SW_i]
    call    LGet_Attr
    ld      [SW_ai], a
    ; attr[j] -> SW_aj
    ld      a, [SW_j]
    call    LGet_Attr
    ld      [SW_aj], a
    ; Write back swapped.
    ld      a, [SW_gj]
    ld      b, a
    ld      a, [SW_i]
    call    LSet_Glyph
    ld      a, [SW_gi]
    ld      b, a
    ld      a, [SW_j]
    call    LSet_Glyph
    ld      a, [SW_aj]
    ld      b, a
    ld      a, [SW_i]
    call    LSet_Attr
    ld      a, [SW_ai]
    ld      b, a
    ld      a, [SW_j]
    call    LSet_Attr
    ret

SW_i:           db 0
SW_j:           db 0
SW_gi:          db 0
SW_gj:          db 0
SW_ai:          db 0
SW_aj:          db 0

; LSet_Glyph: LineGlyph[A] = B. Preserves all regs except A/F.
LSet_Glyph:
    push    hl
    push    de
    ld      e, a
    ld      d, 0
    ld      hl, LineGlyph
    add     hl, de
    ld      a, b
    ld      [hl], a
    pop     de
    pop     hl
    ret

; LineResolveNeutrals: each CELL_NEUTRAL cell adopts the direction of its
; surrounding strong (non-neutral) cells — if both sides agree, use that;
; otherwise use HtmlDir. Works entirely off static scratch vars so the
; nested loops don't fight for BC/DE/HL.
LineResolveNeutrals:
    xor     a
    ld      [LN_i], a
.lnLoop:
    ld      a, [LN_i]
    ld      b, a
    ld      a, [LineLen]
    cp      b
    ret     z
    ld      a, [LN_i]
    call    LGet_Attr
    and     CELL_NEUTRAL
    jp      z, .lnAdvance

    ; Start of a neutral run at s = LN_i.
    ld      a, [LN_i]
    ld      [LN_s], a
.lnFind:
    ld      a, [LN_i]
    inc     a
    ld      [LN_i], a
    ld      b, a
    ld      a, [LineLen]
    cp      b
    jr      z, .lnAtEnd
    ld      a, [LN_i]
    call    LGet_Attr
    and     CELL_NEUTRAL
    jr      nz, .lnFind
.lnAtEnd:
    ; LN_s = start, LN_i = end-exclusive.
    ; prev dir: HtmlDir if s==0 else LineAttr[s-1] & CELL_RTL.
    ld      a, [LN_s]
    or      a
    jr      z, .lnPrevPara
    dec     a
    call    LGet_Attr
    and     CELL_RTL
    jr      .lnHavePrev
.lnPrevPara:
    ld      a, [HtmlDir]
    and     CELL_RTL
.lnHavePrev:
    ld      [LN_prev], a

    ; next dir: HtmlDir if e==len else LineAttr[e] & CELL_RTL.
    ld      a, [LN_i]
    ld      b, a
    ld      a, [LineLen]
    cp      b
    jr      z, .lnNextPara
    ld      a, [LN_i]
    call    LGet_Attr
    and     CELL_RTL
    jr      .lnHaveNext
.lnNextPara:
    ld      a, [HtmlDir]
    and     CELL_RTL
.lnHaveNext:
    ld      b, a
    ld      a, [LN_prev]
    cp      b
    jr      z, .lnAdopt
    ld      a, [HtmlDir]
    and     CELL_RTL
.lnAdopt:
    ld      [LN_dir], a

    ; Stamp cells [s..e): OR LN_dir into each LineAttr.
    ld      a, [LN_s]
    ld      [LN_k], a
.lnStamp:
    ld      a, [LN_k]
    ld      b, a
    ld      a, [LN_i]
    cp      b
    jr      z, .lnLoop                  ; done; LN_i already = e
    ld      a, [LN_k]
    call    LGet_Attr
    ld      c, a
    ld      a, [LN_dir]
    or      c
    ld      b, a
    ld      a, [LN_k]
    call    LSet_Attr
    ld      a, [LN_k]
    inc     a
    ld      [LN_k], a
    jr      .lnStamp

.lnAdvance:
    ld      a, [LN_i]
    inc     a
    ld      [LN_i], a
    jp      .lnLoop

LN_i:           db 0
LN_s:           db 0
LN_k:           db 0
LN_prev:        db 0
LN_dir:         db 0

; LineBidiReorder: UAX#9 L2 at a single level.
;   HtmlDir = 0 (LTR): reverse each contiguous CELL_RTL run.
;   HtmlDir = 1 (RTL): reverse whole line, then reverse each non-RTL run
;     to restore logical LTR order of embedded Latin text.
LineBidiReorder:
    ld      a, [HtmlDir]
    and     CELL_RTL
    jr      nz, .rtlPara
    ; LTR: reverse each RTL run.
    xor     a
    ld      [BR_i], a
.ltrScan:
    ld      a, [BR_i]
    ld      b, a
    ld      a, [LineLen]
    cp      b
    ret     z
    ld      a, [BR_i]
    call    LGet_Attr
    and     CELL_RTL
    jr      z, .ltrAdv
    ; start of RTL run.
    ld      a, [BR_i]
    ld      [BR_s], a
.ltrFind:
    ld      a, [BR_i]
    inc     a
    ld      [BR_i], a
    ld      b, a
    ld      a, [LineLen]
    cp      b
    jr      z, .ltrRev
    ld      a, [BR_i]
    call    LGet_Attr
    and     CELL_RTL
    jr      nz, .ltrFind
.ltrRev:
    ld      a, [BR_s]
    ld      [BR_lo], a
    ld      a, [BR_i]
    ld      [BR_hi], a
    call    ReverseRangeStatic
    jr      .ltrScan
.ltrAdv:
    ld      a, [BR_i]
    inc     a
    ld      [BR_i], a
    jr      .ltrScan

.rtlPara:
    ; Reverse whole line.
    xor     a
    ld      [BR_lo], a
    ld      a, [LineLen]
    ld      [BR_hi], a
    call    ReverseRangeStatic
    ; Reverse each non-RTL run.
    xor     a
    ld      [BR_i], a
.rScan:
    ld      a, [BR_i]
    ld      b, a
    ld      a, [LineLen]
    cp      b
    ret     z
    ld      a, [BR_i]
    call    LGet_Attr
    and     CELL_RTL
    jr      nz, .rAdv
    ld      a, [BR_i]
    ld      [BR_s], a
.rFind:
    ld      a, [BR_i]
    inc     a
    ld      [BR_i], a
    ld      b, a
    ld      a, [LineLen]
    cp      b
    jr      z, .rRev
    ld      a, [BR_i]
    call    LGet_Attr
    and     CELL_RTL
    jr      z, .rFind
.rRev:
    ld      a, [BR_s]
    ld      [BR_lo], a
    ld      a, [BR_i]
    ld      [BR_hi], a
    call    ReverseRangeStatic
    jr      .rScan
.rAdv:
    ld      a, [BR_i]
    inc     a
    ld      [BR_i], a
    jr      .rScan

BR_i:           db 0
BR_s:           db 0
BR_lo:          db 0
BR_hi:          db 0

; ReverseRangeStatic: reverse LineGlyph[BR_lo..BR_hi) and LineAttr too.
; BR_hi is end-exclusive. No-op for runs of 0 or 1 cell.
ReverseRangeStatic:
    ld      a, [BR_hi]
    ld      b, a
    ld      a, [BR_lo]
    cp      b
    ret     z
    inc     a
    cp      b
    ret     z                           ; single cell
    ; i = lo, j = hi-1
    ld      a, [BR_lo]
    ld      [LN_k], a                   ; reuse LN_k as "i"
    ld      a, [BR_hi]
    dec     a
    ld      [LN_s], a                   ; reuse LN_s as "j"
.rrsLoop:
    ld      a, [LN_k]
    ld      b, a
    ld      a, [LN_s]
    cp      b
    ret     c                           ; j < i, done
    ret     z                           ; meeting point, done
    ; Swap LineGlyph/Attr at i=LN_k, j=LN_s.
    ld      a, [LN_k]
    ld      [SW_i], a
    ld      a, [LN_s]
    ld      [SW_j], a
    call    SwapCellsAtIJ
    ld      a, [LN_k]
    inc     a
    ld      [LN_k], a
    ld      a, [LN_s]
    dec     a
    ld      [LN_s], a
    jr      .rrsLoop

; LineDrawCells: draw each cell in LineGlyph[0..LineLen) at a start byte-
; column computed from HtmlAlign. Works entirely in /4-byte columns so the
; 492-px canvas edge (= byte-col 123) fits in an 8-bit register -- an
; earlier attempt at pixel math silently truncated CONTENT_X_END+1 (=0x1EC)
; to 0xEC, pinning "right" to the middle of the page.
RIGHT_EDGE_COL equ (CONTENT_X_END + 1) / 4          ; 123

LineDrawCells:
    ld      a, [LineLen]
    or      a
    ret     z

    ; Width in byte-cols = len * 2.
    add     a, a
    ld      c, a                        ; C = width (byte-cols)

    ld      a, [HtmlAlign]
    cp      1
    jr      z, .alRight
    cp      2
    jr      z, .alCenter
    ; Left: indent in pixels, convert to byte-cols.
    ld      a, [HtmlIndent]
    srl     a
    srl     a
    jr      .alHave
.alRight:
    ld      a, RIGHT_EDGE_COL
    sub     c                           ; byte-col = 123 - width
    jr      nc, .alHave
    xor     a                           ; guard: if width > canvas, clamp
    jr      .alHave
.alCenter:
    ld      a, [HtmlIndent]
    srl     a
    srl     a
    ld      b, a                        ; B = indent byte-cols
    ld      a, RIGHT_EDGE_COL
    sub     c                           ; 123 - width
    jr      c, .alCenterClamp
    sub     b                           ; - indent
    jr      c, .alCenterClamp
    srl     a                           ; /2
    add     a, b                        ; + indent
    jr      .alHave
.alCenterClamp:
    ld      a, b
.alHave:
    ld      [LineStartCol], a

    xor     a
    ld      [LineDrawI], a
.dLoop:
    ld      a, [LineDrawI]
    ld      b, a
    ld      a, [LineLen]
    cp      b
    ret     z

    ; byteCol = startCol + i*2
    ld      a, [LineStartCol]
    ld      c, a
    ld      a, [LineDrawI]
    add     a, a
    add     a, c
    ld      b, a                        ; B = byteCol

    ld      a, [TextY]
    ld      c, a                        ; C = y

    ld      a, [LineDrawI]
    call    LGet_Glyph                  ; A = glyph

    push    bc
    call    DrawCharFast
    pop     bc

    ld      a, [LineDrawI]
    inc     a
    ld      [LineDrawI], a
    jr      .dLoop

LineStartCol:   db 0
LineDrawI:      db 0

; EmitNewline: start a new rendered line. We always bump the line counter
; (for the scrollbar); we only advance TextY after the skip quota for
; scrolling is exhausted. TextY clamps at the bottom so further emissions
; fail the canvas bounds check silently.
EmitNewline:
    ; Drain the Arabic word buffer into the line buffer first (so its last
    ; letter's "next" context is resolved as end-of-word), then flush the
    ; full line to VRAM with BiDi + alignment applied. Both are safe no-ops
    ; at ArLen/LineLen = 0 and are guarded against re-entrance via the
    ; EmitRaw wrap path.
    call    ArFlush
    call    LineFlush
    ; Count this rendered line in units of 8-pixel rows so H1/H2 (scale 2)
    ; contribute 2. This keeps scroll-by-page math in sync with actual VRAM
    ; pixels -- otherwise a page of scaled headings would scroll more than
    ; one visual page worth of content.
    ld      a, [HtmlScaleY]
    ld      b, a                        ; B = rows to add (1 or 2)
    ld      a, [HtmlLineCount]
    add     a, b
    jr      nc, .lcStore
    ld      a, 0xFF                     ; saturate
.lcStore:
    ld      [HtmlLineCount], a

    ; Start of new line: reset TextX to the current indent.
    ld      a, [HtmlIndent]
    ld      [TextX], a
    xor     a
    ld      [TextX + 1], a

    ; If we're still skipping, decrement by the line's row count and stay
    ; pinned at the top-of-canvas.
    ld      a, [HtmlLineSkip]
    or      a
    jr      z, .advance
    sub     b
    jr      nc, .skStore
    xor     a                           ; don't underflow past 0
.skStore:
    ld      [HtmlLineSkip], a
    jr      .flagsDone

.advance:
    ; Row pitch depends on current HtmlScaleY (1 or 2).
    ld      a, [HtmlScaleY]
    add     a, a                        ; A = scale*2
    add     a, a                        ; A = scale*4
    add     a, a                        ; A = scale*8 = pitch
    ld      b, a
    ld      a, [TextY]
    add     a, b                        ; A = proposed new TextY
    cp      CONTENT_Y1 + 1
    jr      nc, .flagsDone              ; new line wouldn't fit -> stop
    ld      [TextY], a

.flagsDone:
    ld      a, 1
    ld      [HtmlLineEmpty], a
    xor     a
    ld      [HtmlWsPending], a
    ret

; EmitBlankLine: ensure we're at start of a line and leave one blank line
; above whatever we emit next. Idempotent if the previous tag already did it.
EmitBlankLine:
    ld      a, [HtmlLineEmpty]
    or      a
    jr      nz, .skipBreak
    call    EmitNewline
.skipBreak:
    jp      EmitNewline

; ----------------------------------------------------------------------------
; TitleAppend: append a char to HtmlTitleBuf, capped at TITLE_BUF_MAX.
;   A = char
; Preserves HL.
; ----------------------------------------------------------------------------
TitleAppend:
    ld      b, a
    ld      a, [HtmlTitleLen]
    cp      TITLE_BUF_MAX
    ret     nc
    ld      e, a
    ld      d, 0
    ld      hl, HtmlTitleBuf
    add     hl, de
    ld      [hl], b
    inc     a
    ld      [HtmlTitleLen], a
    ret

; ----------------------------------------------------------------------------
; ParseTag: HL points at first char *after* '<'. Recognizes comments,
; open tags, and close tags; advances HL past the closing '>'.
; ----------------------------------------------------------------------------
ParseTag:
    ld      a, [hl]
    cp      0x21                        ; bang -> comment or doctype
    jp      z, ParseBangTag

    ; Open vs. close.
    xor     a
    ld      [HtmlIsClose], a
    ld      a, [hl]
    cp      '/'
    jr      nz, .nameStart
    inc     hl
    ld      a, 1
    ld      [HtmlIsClose], a

.nameStart:
    ld      de, HtmlTagName
    ld      b, 7
.copyName:
    ld      a, [hl]
    ; Stop at whitespace or '>'.
    cp      '>'
    jr      z, .nameEnd
    cp      ' '
    jr      z, .nameEnd
    cp      0x09
    jr      z, .nameEnd
    cp      0x0A
    jr      z, .nameEnd
    cp      0x0D
    jr      z, .nameEnd
    cp      '/'
    jr      z, .nameEnd
    ; Uppercase a-z
    cp      'a'
    jr      c, .notLower
    cp      'z' + 1
    jr      nc, .notLower
    sub     'a' - 'A'
.notLower:
    ld      [de], a
    inc     de
    inc     hl
    djnz    .copyName
.nameEnd:
    xor     a
    ld      [de], a                     ; NUL-terminate

    ; Pre-scan for block-level attrs (align=, dir=). Result lands in
    ; HtmlNextAlign / HtmlNextDir which the tag handler consumes. Preserves
    ; HL so the subsequent href/alt/color pass re-walks the same attrs.
    push    hl
    call    ScanBlockAttrs
    pop     hl

    ; Tags that carry captured attribute values: <a href>, <img alt>,
    ; <font color>. All three share HtmlCurHref (one value max per tag).
    push    hl
    call    TagNeedsAttrScan
    pop     hl
    or      a
    jr      z, .skipRaw
    call    ScanHrefAttr
    jr      .attrsDone
.skipRaw:
.skipAttr:
    ld      a, [hl]
    inc     hl
    cp      '>'
    jr      nz, .skipAttr
.attrsDone:

    ; DispatchTag clobbers HL to walk the tag table; preserve the source
    ; pointer so PrintFileContent resumes at the right byte.
    push    hl
    call    DispatchTag
    pop     hl
    ret

; TagNeedsAttrScan: returns A=1 if the current HtmlTagName is "A", "IMG",
; or "FONT"; A=0 otherwise. Clobbers HL, DE, BC.
TagNeedsAttrScan:
    ld      hl, HtmlTagName
    ld      a, [hl]
    cp      'A'
    jr      z, .tn_oneCharCheck
    ld      de, TnIMG
    call    TnCompare
    ret     nz
    ld      de, TnFONT
    call    TnCompare
    ret     nz
    xor     a
    ret

.tn_oneCharCheck:
    inc     hl
    ld      a, [hl]
    or      a
    jr      nz, .tn_no                  ; "A<X>..." not lone "A"
    ld      a, 1
    ret
.tn_no:
    xor     a
    ret

; TnCompare: DE = target name (NUL-terminated). Compare against HtmlTagName.
; Returns A=1 (and NZ) on match, A=0 (and Z) on mismatch.
TnCompare:
    ld      hl, HtmlTagName
.tc_loop:
    ld      a, [de]
    ld      c, a
    ld      a, [hl]
    or      a
    jr      z, .tc_endName
    cp      c
    jr      nz, .tc_miss
    inc     hl
    inc     de
    jr      .tc_loop
.tc_endName:
    ld      a, [de]
    or      a
    jr      nz, .tc_miss
    ld      a, 1
    or      a
    ret
.tc_miss:
    xor     a
    ret

TnIMG:  db "IMG", 0
TnFONT: db "FONT", 0

; ScanBlockAttrs: walks HL from first char after the tag name through '>',
; looking for align=<value> and dir=<value> (case-insensitive). Parses
; align into HtmlNextAlign (0=left, 1=right, 2=center, 0xFF=unset) and dir
; into HtmlNextDir (0=ltr, 1=rtl, 0xFF=unset). Values may be bare or quoted.
; Restores HL to caller; the caller's own attr-scan then re-walks to '>'.
ScanBlockAttrs:
    ld      a, 0xFF
    ld      [HtmlNextAlign], a
    ld      [HtmlNextDir], a
.sba_loop:
    ld      a, [hl]
    cp      '>'
    ret     z
    or      a
    ret     z
    and     0xDF                        ; uppercase
    cp      'A'
    jr      z, .sba_tryA
    cp      'D'
    jr      z, .sba_tryD
    inc     hl
    jp      .sba_loop

.sba_tryA:
    ; Match ALIGN=
    push    hl
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'L'
    jr      nz, .sba_missA
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'I'
    jr      nz, .sba_missA
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'G'
    jr      nz, .sba_missA
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'N'
    jr      nz, .sba_missA
    inc     hl
    ld      a, [hl]
    cp      '='
    jr      nz, .sba_missA
    inc     hl
    ld      a, [hl]
    cp      0x22                        ; "
    jr      nz, .sba_aVal
    inc     hl
.sba_aVal:
    ld      a, [hl]
    and     0xDF
    cp      'L'
    jr      z, .sba_aL
    cp      'R'
    jr      z, .sba_aR
    cp      'C'
    jr      z, .sba_aC
    jr      .sba_missA
.sba_aL:
    xor     a
    jr      .sba_aStore
.sba_aR:
    ld      a, 1
    jr      .sba_aStore
.sba_aC:
    ld      a, 2
.sba_aStore:
    ld      [HtmlNextAlign], a
    pop     af                          ; drop saved HL; keep current
    inc     hl
    jp      .sba_loop
.sba_missA:
    pop     hl
    inc     hl
    jp      .sba_loop

.sba_tryD:
    ; Match DIR=
    push    hl
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'I'
    jr      nz, .sba_missD
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'R'
    jr      nz, .sba_missD
    inc     hl
    ld      a, [hl]
    cp      '='
    jr      nz, .sba_missD
    inc     hl
    ld      a, [hl]
    cp      0x22                        ; "
    jr      nz, .sba_dVal
    inc     hl
.sba_dVal:
    ld      a, [hl]
    and     0xDF
    cp      'R'
    jr      z, .sba_dR
    xor     a                           ; anything else -> LTR
    jr      .sba_dStore
.sba_dR:
    ld      a, 1
.sba_dStore:
    ld      [HtmlNextDir], a
    pop     af
    inc     hl
    jp      .sba_loop
.sba_missD:
    pop     hl
    inc     hl
    jp      .sba_loop

; ScanHrefAttr: HL points at first char after the tag name. Scans to '>'
; (inclusive). If a `href=` / `alt=` / `color=` attribute is seen
; (case-insensitive), its value is copied into HtmlCurHref. The three
; attributes share the buffer since <a>, <img>, and <font> never co-occur
; with each other's attribute. After return HL points just past '>'.
ScanHrefAttr:
    xor     a
    ld      [HtmlCurHrefLen], a
    ld      [HtmlCurHref], a            ; default = empty string
.sh_scan:
    ld      a, [hl]
    cp      '>'
    jp      z, .sh_consumeEnd
    ; Try matching "HREF=" (for <a>), "ALT=" (for <img>), or "COLOR="
    ; (for <font>) starting here. They share HtmlCurHref since no tag uses
    ; more than one of them.
    cp      'h'
    jr      z, .sh_tryHref
    cp      'H'
    jr      z, .sh_tryHref
    cp      'a'
    jr      z, .sh_tryAlt
    cp      'A'
    jr      z, .sh_tryAlt
    cp      'c'
    jr      z, .sh_tryColor
    cp      'C'
    jr      z, .sh_tryColor
    inc     hl
    jr      .sh_scan

.sh_tryHref:
    push    hl
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'R'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'E'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'F'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    cp      '='
    jr      nz, .sh_noMatch
    inc     hl
    pop     bc
    jr      .sh_readValue

.sh_tryAlt:
    push    hl
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'L'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'T'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    cp      '='
    jr      nz, .sh_noMatch
    inc     hl
    pop     bc
    jr      .sh_readValue

.sh_tryColor:
    push    hl
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'O'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'L'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'O'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    and     0xDF
    cp      'R'
    jr      nz, .sh_noMatch
    inc     hl
    ld      a, [hl]
    cp      '='
    jr      nz, .sh_noMatch
    inc     hl
    pop     bc
    jr      .sh_readValue

.sh_noMatch:
    pop     hl
    inc     hl
    jp      .sh_scan

.sh_readValue:
    ld      a, [hl]
    cp      0x22                        ; double quote
    jr      z, .sh_quoted
    cp      0x27                        ; apostrophe
    jr      z, .sh_quoted
    ; Bare (no quotes): read until whitespace, '>', or '/'.
    ld      c, 0                        ; delimiter = any of the above
    jr      .sh_copy
.sh_quoted:
    ld      c, a                        ; delimiter = this quote char
    inc     hl

.sh_copy:
    ld      de, HtmlCurHref
    ld      b, LINK_URL_MAX
.sh_copyLoop:
    ld      a, [hl]
    or      a
    jr      z, .sh_doneValue            ; end-of-buffer safety
    ld      a, c
    or      a
    jr      z, .sh_bareDelim
    ld      a, [hl]
    cp      c
    jr      z, .sh_doneValue
    jr      .sh_store
.sh_bareDelim:
    ld      a, [hl]
    cp      '>'
    jr      z, .sh_doneValueNoInc
    cp      ' '
    jr      z, .sh_doneValue
    cp      0x09
    jr      z, .sh_doneValue
    cp      '/'
    jr      z, .sh_doneValue
.sh_store:
    ld      [de], a
    inc     de
    inc     hl
    ld      a, [HtmlCurHrefLen]
    inc     a
    ld      [HtmlCurHrefLen], a
    djnz    .sh_copyLoop

.sh_doneValue:
    inc     hl                          ; consume closing quote or ws
.sh_doneValueNoInc:
    xor     a
    ld      [de], a                     ; NUL-terminate
    ; Skip remaining attrs to '>'.
.sh_tailSkip:
    ld      a, [hl]
    inc     hl
    cp      '>'
    jr      nz, .sh_tailSkip
    ret

.sh_consumeEnd:
    inc     hl                          ; skip '>'
    ret

; ParseBangTag: handles <!-- .. --> and <!DOCTYPE ..> alike.
ParseBangTag:
    inc     hl                          ; past '!'
    ld      a, [hl]
    cp      '-'
    jr      nz, .doctype
    inc     hl
    ld      a, [hl]
    cp      '-'
    jr      nz, .doctype
    inc     hl
.cmt:
    ld      a, [hl]
    inc     hl
    cp      '-'
    jr      nz, .cmt
    ld      a, [hl]
    cp      '-'
    jr      nz, .cmt
    inc     hl
    ld      a, [hl]
    cp      '>'
    jr      nz, .cmt
    inc     hl
    ret
.doctype:
    ld      a, [hl]
    inc     hl
    cp      '>'
    jr      nz, .doctype
    ret

; ----------------------------------------------------------------------------
; DispatchTag: HtmlTagName contains the uppercased tag name. HtmlIsClose
; indicates open vs. close. Linear search against TagTbl entries of
; the form (name\0, handler_lo, handler_hi).
; ----------------------------------------------------------------------------
DispatchTag:
    ld      hl, TagTbl
.next:
    ld      a, [hl]
    or      a
    ret     z                           ; end of table -> unknown tag

    push    hl
    ld      de, HtmlTagName
.cmp:
    ld      a, [de]
    ld      c, a
    ld      a, [hl]
    or      a
    jr      z, .endTbl
    cp      c
    jr      nz, .mismatch
    inc     hl
    inc     de
    jr      .cmp
.endTbl:
    ld      a, [de]
    or      a
    jr      nz, .mismatch
    ; Match -- read handler pointer just past the NUL.
    inc     hl
    ld      e, [hl]
    inc     hl
    ld      d, [hl]
    pop     af                          ; discard saved HL
    ex      de, hl
    jp      [hl]

.mismatch:
    pop     hl
.skipName:
    ld      a, [hl]
    inc     hl
    or      a
    jr      nz, .skipName
    inc     hl                          ; skip handler lo
    inc     hl                          ; skip handler hi
    jr      .next

; ----------------------------------------------------------------------------
; Tag handlers. Each reads HtmlIsClose to decide open vs. close behaviour.
; ----------------------------------------------------------------------------

TagHead:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    ld      a, 1
    ld      [HtmlInHead], a
    ret
.close:
    xor     a
    ld      [HtmlInHead], a
    ret

TagBody:
    xor     a
    ld      [HtmlInHead], a
    ret

TagTitle:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    ld      a, 1
    ld      [HtmlInTitle], a
    ret
.close:
    xor     a
    ld      [HtmlInTitle], a
    ; NUL-terminate captured title and repaint the titlebar.
    ld      a, [HtmlTitleLen]
    ld      e, a
    ld      d, 0
    ld      hl, HtmlTitleBuf
    add     hl, de
    xor     a
    ld      [hl], a
    ld      a, 1
    ld      [HtmlTitleSeen], a
    jp      DrawTitleLabel

TagNoOp:
    ret

; <ul>: bullet list. Open indents by 16 px and switches bullet style.
; Close restores. No nesting state beyond a single level.
TagUl:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    call    EmitBlankLine
    ld      a, 1
    ld      [HtmlListKind], a
    ld      a, [HtmlIndent]
    add     a, 16
    ld      [HtmlIndent], a
    ret
.close:
    xor     a
    ld      [HtmlListKind], a
    ld      a, [HtmlIndent]
    sub     16
    ld      [HtmlIndent], a
    jp      EmitBlankLine

; <ol>: ordered list. Same as <ul> but bullet style 2 and a counter.
TagOl:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    call    EmitBlankLine
    ld      a, 2
    ld      [HtmlListKind], a
    xor     a
    ld      [HtmlOlCounter], a
    ld      a, [HtmlIndent]
    add     a, 16
    ld      [HtmlIndent], a
    ret
.close:
    xor     a
    ld      [HtmlListKind], a
    ld      a, [HtmlIndent]
    sub     16
    ld      [HtmlIndent], a
    jp      EmitBlankLine

; <li>: newline, then tell EmitText to prepend a bullet / number to the
; next non-whitespace char.
TagLi:
    ld      a, [HtmlIsClose]
    or      a
    ret     nz
    call    EmitNewline
    ld      a, 1
    ld      [HtmlLiPending], a
    ret

; <pre>: preformatted block. Whitespace is preserved verbatim; LF drives a
; real newline in EmitText. Blank line above/below.
TagPre:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    call    EmitBlankLine
    ld      a, 1
    ld      [HtmlPre], a
    ret
.close:
    xor     a
    ld      [HtmlPre], a
    jp      EmitBlankLine

; <blockquote>: widen the left indent by 32 px for the block.
TagBlockquote:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    call    EmitBlankLine
    ld      a, [HtmlIndent]
    add     a, 32
    ld      [HtmlIndent], a
    ret
.close:
    ld      a, [HtmlIndent]
    sub     32
    ld      [HtmlIndent], a
    jp      EmitBlankLine

; <img>: stub -- prints "[alt]" using the captured alt attribute (or "[img]"
; when no alt). Uses a shared ScanAltAttr populated during ParseTag in the
; same style as href. Self-closing; no matching close tag needed.
TagImg:
    ; Open a bracket, then print HtmlCurHref (we repurpose the href buffer
    ; for the alt text capture below), then close bracket.
    ld      a, '['
    call    EmitSink
    ld      a, [HtmlCurHref]
    or      a
    jr      nz, .copyAlt
    ; Empty alt -> print "img"
    ld      hl, TagImgWord
    jr      .loop
.copyAlt:
    ld      hl, HtmlCurHref
.loop:
    ld      a, [hl]
    or      a
    jr      z, .done
    push    hl
    call    EmitSink
    pop     hl
    inc     hl
    jr      .loop
.done:
    ld      a, ']'
    jp      EmitSink

TagImgWord: db "img", 0

; <font color="name">: push current fg, set new fg + CurrentFontLUT from
; the color name stored in HtmlCurHref (ScanHrefAttr captured it via the
; href/alt path). </font> pops. Only a small set of names maps to our 4
; palette entries; anything else falls through to the default (BLACK).
TagFont:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close

    ; Push current fg onto the 4-deep stack.
    ld      a, [HtmlFgDepth]
    cp      4
    jr      nc, .openSetColor           ; stack full, just overwrite
    ld      e, a
    ld      d, 0
    ld      hl, HtmlFgStack
    add     hl, de
    ld      a, [HtmlFg]
    ld      [hl], a
    ld      a, [HtmlFgDepth]
    inc     a
    ld      [HtmlFgDepth], a

.openSetColor:
    ; Match HtmlCurHref against the color-name table.
    ld      hl, ColorTable
.ct_next:
    ld      a, [hl]
    or      a
    jr      z, .ct_default
    push    hl
    ld      de, HtmlCurHref
.ct_cmp:
    ld      a, [de]
    and     0xDF                        ; uppercase for compare
    ld      c, a
    ld      a, [hl]
    or      a
    jr      z, .ct_endname
    cp      c
    jr      nz, .ct_skip
    inc     hl
    inc     de
    jr      .ct_cmp
.ct_endname:
    ld      a, [de]
    or      a
    jr      nz, .ct_skip
    ; Match; next byte in table is palette index.
    inc     hl
    ld      a, [hl]
    pop     bc
    jp      SetHtmlFg
.ct_skip:
    pop     hl
.ct_adv:
    ld      a, [hl]
    inc     hl
    or      a
    jr      nz, .ct_adv
    inc     hl                          ; skip palette byte
    jr      .ct_next

.ct_default:
    ld      a, COL_BLACK
    jp      SetHtmlFg

.close:
    ld      a, [HtmlFgDepth]
    or      a
    ret     z
    dec     a
    ld      [HtmlFgDepth], a
    ld      e, a
    ld      d, 0
    ld      hl, HtmlFgStack
    add     hl, de
    ld      a, [hl]
    jp      SetHtmlFg

; SetHtmlFg: A = palette index (0..3). Updates HtmlFg + CurrentFontLUT.
SetHtmlFg:
    ld      [HtmlFg], a
    ld      hl, FontLUT                 ; default = BLACK
    cp      COL_BLACK
    jr      z, .sfDone
    ld      hl, FontLUT_LGray
    cp      COL_LGRAY
    jr      z, .sfDone
    ld      hl, FontLUT_DGray
    cp      COL_DGRAY
    jr      z, .sfDone
    ld      hl, FontLUT                 ; fallback (WHITE invisible anyway)
.sfDone:
    ld      [CurrentFontLUT], hl
    ret

; ColorTable: upper-case name (NUL-terminated) + palette index byte.
; Ends with a 0-length entry.
ColorTable:
    db  "BLACK", 0
    db  COL_BLACK
    db  "GRAY", 0
    db  COL_LGRAY
    db  "GREY", 0
    db  COL_LGRAY
    db  "SILVER", 0
    db  COL_LGRAY
    db  "LIGHTGRAY", 0
    db  COL_LGRAY
    db  "DIMGRAY", 0
    db  COL_DGRAY
    db  "DARKGRAY", 0
    db  COL_DGRAY
    db  "RED", 0
    db  COL_DGRAY                       ; no red -> fall back to DGRAY dither
    db  "GREEN", 0
    db  COL_DGRAY
    db  "BLUE", 0
    db  COL_DGRAY
    db  "WHITE", 0
    db  COL_WHITE
    db  0

; ----------------------------------------------------------------------------
; Tables — fixed 3-column layout, one text line per cell.
;
; Layout (pixel x):
;   0..3    : left margin
;   4..155  : col 0 content
;   156..163: divider (4 px, 1 byte DGRAY)
;   164..315: col 1 content
;   316..323: divider
;   324..475: col 2 content
;   476..491: right margin
;
; Rules:
;   - <TABLE> draws a horizontal DGRAY rule on the row above the first row
;     of cells, then leaves a 2-px gap before cell text starts.
;   - <TR> after the first draws another horizontal rule between rows.
;   - <TD>/<TH> positions TextX to the column's start and draws the vertical
;     divider (spanning the row's text height) before the second+ columns.
;   - </TABLE> draws the final horizontal rule and emits a trailing blank.
;
; Cells that overflow their column width are not clipped; the user should
; keep cells short. This is a pragmatic middle ground given the Screen 6
; pixel budget.
; ----------------------------------------------------------------------------

TABLE_LEFT_PAD  equ 4
TABLE_ROW_GAP   equ 2                   ; vertical pixels between rule and text

TagTableTag:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close

    ; Leading blank line + top rule + row-gap before the first cell text.
    call    EmitBlankLine
    ld      a, 1
    ld      [HtmlInTable], a
    ld      [HtmlTableFirst], a
    xor     a
    ld      [HtmlTableCol], a

    call    DrawTableRuleHere
    ld      a, [TextY]
    add     a, TABLE_ROW_GAP
    ld      [TextY], a
    ld      [HtmlRowTopY], a
    ret

.close:
    ; Close the last row's bottom rule + blank line.
    ld      a, [HtmlRowTopY]
    add     a, TEXT_LINE_H
    ld      [TextY], a
    call    DrawTableRuleHere
    xor     a
    ld      [HtmlInTable], a
    jp      EmitBlankLine

; <tr>: close the previous row (if any) with a rule + gap, and open a new
; row by resetting state and caching the new RowTopY.
TagTr:
    ld      a, [HtmlIsClose]
    or      a
    ret     nz

    ld      a, [HtmlTableFirst]
    or      a
    jr      nz, .newRow

    ; Close previous row: advance TextY past its text, draw rule, gap.
    ld      a, [HtmlRowTopY]
    add     a, TEXT_LINE_H
    ld      [TextY], a
    call    DrawTableRuleHere
    ld      a, [TextY]
    add     a, TABLE_ROW_GAP
    ld      [TextY], a

.newRow:
    xor     a
    ld      [HtmlTableFirst], a
    ld      [HtmlTableCol], a

    ; Reset pen state for the new row.
    xor     a
    ld      [TextX], a
    ld      [TextX + 1], a
    ld      a, 1
    ld      [HtmlLineEmpty], a
    xor     a
    ld      [HtmlWsPending], a

    ld      a, [TextY]
    ld      [HtmlRowTopY], a
    ret

; <td>/<th>: position TextX at the column's start pixel. For col > 0 also
; drop a vertical rule between the previous column and this one.
TagTd:
    ld      a, [HtmlIsClose]
    or      a
    ret     nz

    ; Compute cell start X from TableColStartX[HtmlTableCol]. Entries are
    ; 16-bit because col 2 sits past 255 px. Overflow clamps to last slot.
    ld      a, [HtmlTableCol]
    cp      3
    jr      c, .okCol
    ld      a, 2
.okCol:
    ld      e, a
    ld      d, 0
    ld      hl, TableColStartX
    add     hl, de
    add     hl, de                      ; *2 for word-sized entries
    ld      e, [hl]
    inc     hl
    ld      d, [hl]                     ; DE = cell start X (2 bytes)
    ld      a, e
    ld      [TextX], a
    ld      a, d
    ld      [TextX + 1], a

    ; Draw the vertical divider for non-first columns. The divider sits
    ; 4 px before the cell's content X.
    ld      a, [HtmlTableCol]
    or      a
    jr      z, .noDivider
    ld      hl, -4
    add     hl, de                      ; HL = divider X = content X - 4
    call    DrawCellDividerAt_HL

.noDivider:
    ld      a, [HtmlTableCol]
    inc     a
    ld      [HtmlTableCol], a
    ret

; Content-start X per column (16-bit: col 2 sits past 255). The three-column
; layout leaves 4 px of padding before the first cell and 4 px after the
; last divider.
TableColStartX:
    dw  4, 164, 324

; DrawTableRuleHere: horizontal DGRAY rule at the current TextY across the
; content width. Skipped while LineSkip is non-zero.
DrawTableRuleHere:
    ld      a, [HtmlLineSkip]
    or      a
    ret     nz
    ld      a, [TextY]
    cp      CONTENT_Y1 - TEXT_LINE_H + 2
    ret     nc
    ld      c, a
    ld      b, 0
    ld      d, (CONTENT_X_END + 1) / 4
    ld      a, COL_DGRAY
    jp      DrawHLine

; DrawCellDividerAt_HL: HL = pixel X (16-bit, multiple of 4). Draws a
; 1-byte (4 px) DGRAY vertical line at that X across the current row
; (HtmlRowTopY for TEXT_LINE_H rows). Skipped while LineSkip is non-zero.
DrawCellDividerAt_HL:
    push    hl
    ld      a, [HtmlLineSkip]
    or      a
    pop     hl
    ret     nz
    srl     h
    rr      l
    srl     h
    rr      l                           ; HL = byte col (X / 4)
    ld      b, l                        ; B = byte col (top byte is 0 for X < 512)
    ld      a, [HtmlRowTopY]
    ld      c, a
    ld      d, 1
    ld      e, TEXT_LINE_H
    ld      a, COL_DGRAY
    jp      FillRect

; <th>: like <td> but toggles bold around the cell.
TagTh:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .thClose
    ld      a, [HtmlStyleFlags]
    ld      [HtmlSavedBold], a
    or      STYLE_BOLD
    ld      [HtmlStyleFlags], a
    jp      TagTd
.thClose:
    ld      a, [HtmlSavedBold]
    and     STYLE_BOLD
    ld      b, a
    ld      a, [HtmlStyleFlags]
    and     0xFE
    or      b
    ld      [HtmlStyleFlags], a
    ret

TagP:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .pClose
    call    EmitBlankLine
    call    ApplyBlockAttrs
    ret
.pClose:
    ; </p>: terminate the line but don't add a blank row below. The next
    ; block tag will produce its own leading blank via EmitBlankLine, so
    ; a double-spaced layout would inflate the rendered line count and
    ; throw off scroll-by-page.
    call    EmitNewline
    call    ResetBlockAttrs
    ret

; ApplyBlockAttrs: copy HtmlNextAlign / HtmlNextDir (if set) into the live
; HtmlAlign / HtmlDir globals. Called from block-tag open handlers right
; after the tag's blank-line break, so the new state affects the content
; that follows. dir="rtl" implies align=right unless align= explicitly says
; otherwise.
ApplyBlockAttrs:
    ld      a, [HtmlNextDir]
    cp      0xFF
    jr      z, .abaDirDone
    ld      [HtmlDir], a
    ; If no explicit align, dir=rtl defaults to right-align.
    or      a
    jr      z, .abaDirDone
    ld      a, [HtmlNextAlign]
    cp      0xFF
    jr      nz, .abaDirDone
    ld      a, 1
    ld      [HtmlAlign], a
.abaDirDone:
    ld      a, [HtmlNextAlign]
    cp      0xFF
    ret     z
    ld      [HtmlAlign], a
    ret

; ResetBlockAttrs: clear alignment/dir at block-tag close so the next
; block starts with defaults.
ResetBlockAttrs:
    xor     a
    ld      [HtmlAlign], a
    ld      [HtmlDir], a
    ret

TagBr:
    jp      EmitNewline

TagHr:
    call    EmitBlankLine
    ; Only draw the rule when the current pen is actually inside the visible
    ; content band. When ScrollLine > 0 the first HR tags are above the top
    ; of the viewport, and EmitNewline keeps TextY pinned at CONTENT_Y0
    ; while LineSkip is non-zero. Drawing then would leave a stray rule at
    ; the top of the page after any scroll.
    ld      a, [HtmlLineSkip]
    or      a
    jp      nz, EmitBlankLine
    ld      a, [TextY]
    cp      CONTENT_Y1 - TEXT_LINE_H + 2
    ret     nc
    ; Draw dgray rule across content width at TextY + 3.
    ld      a, [TextY]
    add     a, 3
    ld      c, a
    ld      b, 0
    ld      d, (CONTENT_X_END + 1) / 4
    ld      a, COL_DGRAY
    call    DrawHLine
    jp      EmitBlankLine

; H1 and H2 render with vertical 2x scale and bold. Normal glyph height
; comes back at </H1>/</H2>. Close: terminate the line only -- the next
; block tag will supply its own leading blank via EmitBlankLine, matching
; the </p> behavior so rendered line counts stay tight for scroll math.
TagH1:
TagH2:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    call    EmitBlankLine
    call    ApplyBlockAttrs
    ld      a, [HtmlStyleFlags]
    or      STYLE_BOLD
    ld      [HtmlStyleFlags], a
    ld      a, 2
    ld      [HtmlScaleY], a
    ret
.close:
    call    EmitNewline
    call    ResetBlockAttrs
    ld      a, [HtmlStyleFlags]
    and     0xFE
    ld      [HtmlStyleFlags], a
    ld      a, 1
    ld      [HtmlScaleY], a
    ret

; H3..H6 stay at normal glyph height but keep the bold flag + blank line.
TagH3:
TagH4:
TagH5:
TagH6:
    ld      a, [HtmlIsClose]
    or      a
    jr      nz, .close
    call    EmitBlankLine
    call    ApplyBlockAttrs
    ld      a, [HtmlStyleFlags]
    or      STYLE_BOLD
    ld      [HtmlStyleFlags], a
    ret
.close:
    call    EmitNewline
    call    ResetBlockAttrs
    ld      a, [HtmlStyleFlags]
    and     0xFE
    ld      [HtmlStyleFlags], a
    ret

TagB:
    ld      a, [HtmlStyleFlags]
    ld      b, a
    ld      a, [HtmlIsClose]
    or      a
    ld      a, b
    jr      nz, .close
    or      STYLE_BOLD
    ld      [HtmlStyleFlags], a
    ret
.close:
    and     0xFE
    ld      [HtmlStyleFlags], a
    ret

TagI:
    ld      a, [HtmlStyleFlags]
    ld      b, a
    ld      a, [HtmlIsClose]
    or      a
    ld      a, b
    jr      nz, .close
    or      STYLE_ITALIC
    ld      [HtmlStyleFlags], a
    ret
.close:
    and     0xFD
    ld      [HtmlStyleFlags], a
    ret

TagU:
    ld      a, [HtmlStyleFlags]
    ld      b, a
    ld      a, [HtmlIsClose]
    or      a
    ld      a, b
    jr      nz, .close
    or      STYLE_UNDERLINE
    ld      [HtmlStyleFlags], a
    ret
.close:
    and     0xFB
    ld      [HtmlStyleFlags], a
    ret

TagS:
    ld      a, [HtmlStyleFlags]
    ld      b, a
    ld      a, [HtmlIsClose]
    or      a
    ld      a, b
    jr      nz, .close
    or      STYLE_STRIKE
    ld      [HtmlStyleFlags], a
    ret
.close:
    and     0xF7
    ld      [HtmlStyleFlags], a
    ret

; DebugShowScrollState: print 'sNN/tNN tYY hYY' at upper-right of content
; area where values are ScrollLine / TotalLines / ThumbTop / ThumbHeight.
DebugShowScrollState:
    ld      hl, DebugTmpBuf
    ld      [hl], 's'
    inc     hl
    ld      a, [ScrollLine]
    call    DbgFmtHex
    ld      [hl], '/'
    inc     hl
    ld      [hl], 't'
    inc     hl
    ld      a, [TotalLines]
    call    DbgFmtHex
    ld      [hl], ' '
    inc     hl
    ld      [hl], 'T'
    inc     hl
    ld      a, [ThumbTop]
    call    DbgFmtHex
    ld      [hl], 'H'
    inc     hl
    ld      a, [ThumbHeight]
    call    DbgFmtHex
    ld      [hl], 0

    ld      de, 4
    ld      c, CONTENT_Y0 + 1
    ld      a, COL_BLACK
    push    de
    ld      l, COL_WHITE
    call    SetTextColours
    pop     de
    ld      hl, DebugTmpBuf
    jp      DrawString

; DbgFmtHex: A = value, HL = dest. Writes 2 hex chars; HL advances by 2.
DbgFmtHex:
    push    af
    rrca
    rrca
    rrca
    rrca
    and     0x0F
    call    .nyb
    pop     af
    and     0x0F
    ; fall through
.nyb:
    cp      10
    jr      c, .dig
    add     a, 'A' - 10 - '0'
.dig:
    add     a, '0'
    ld      [hl], a
    inc     hl
    ret

; <a>: anchor / link. Open sets underline + begins a LinkTable entry using
; the current pen position and the href captured by ScanHrefAttr. Close
; stores the end position; the entry is committed even if the rendered text
; was entirely off-screen (caller checks the Y band in HandleClick so off-
; screen links are harmless).
TagA:
    ld      a, [HtmlIsClose]
    or      a
    jp      nz, .close

    ; --- open ---
    ld      a, [HtmlStyleFlags]
    or      STYLE_UNDERLINE
    ld      [HtmlStyleFlags], a
    ld      a, 1
    ld      [HtmlInAnchor], a

    ; If this link's index matches HtmlFocusLink, light up the dotted-
    ; underline bit so the user can see their keyboard focus.
    ld      a, [HtmlFocusLink]
    ld      b, a
    ld      a, [LinkCount]
    cp      b
    jr      nz, .notFocused
    ld      a, [HtmlStyleFlags]
    or      STYLE_FOCUSED
    ld      [HtmlStyleFlags], a
.notFocused:

    ; If table is already full, skip recording (still style-track).
    ld      a, [LinkCount]
    cp      LINK_MAX
    ret     nc

    ; Stash current pen position into slot [LinkCount]. X is 2 bytes, Y is 1.
    ld      e, a
    ld      d, 0
    ld      hl, LinkStartY
    add     hl, de
    ld      a, [TextY]
    ld      [hl], a

    ld      hl, LinkStartX
    add     hl, de
    add     hl, de
    ld      a, [TextX]
    ld      [hl], a
    inc     hl
    ld      a, [TextX + 1]
    ld      [hl], a

    ; Copy HtmlCurHref into the slot's url buffer.
    ld      a, [LinkCount]
    ; URL offset = LinkCount * (LINK_URL_MAX + 1). Multiply by 33 via adds.
    ld      l, a
    ld      h, 0
    ld      d, h
    ld      e, l
    add     hl, hl                      ; *2
    add     hl, hl                      ; *4
    add     hl, hl                      ; *8
    add     hl, hl                      ; *16
    add     hl, hl                      ; *32
    add     hl, de                      ; *33
    ld      de, LinkUrls
    add     hl, de
    ex      de, hl                      ; DE = dest
    ld      hl, HtmlCurHref
    ld      b, LINK_URL_MAX + 1
.copyUrl:
    ld      a, [hl]
    ld      [de], a
    inc     hl
    inc     de
    or      a
    jr      z, .copyUrlDone
    djnz    .copyUrl
.copyUrlDone:
    ret

.close:
    ld      a, [HtmlStyleFlags]
    and     0xEB                        ; clear underline + focused bits
    ld      [HtmlStyleFlags], a
    xor     a
    ld      [HtmlInAnchor], a

    ld      a, [LinkCount]
    cp      LINK_MAX
    ret     nc

    ; Store end position and bump the count.
    ld      e, a
    ld      d, 0
    ld      hl, LinkEndY
    add     hl, de
    ld      a, [TextY]
    ld      [hl], a

    ld      hl, LinkEndX
    add     hl, de
    add     hl, de
    ld      a, [TextX]
    ld      [hl], a
    inc     hl
    ld      a, [TextX + 1]
    ld      [hl], a

    ld      a, [LinkCount]
    inc     a
    ld      [LinkCount], a
    ret

; Tag dispatch table. Names are already uppercased. Aliases share a handler.
TagTbl:
    db  "HEAD", 0
    dw  TagHead
    db  "BODY", 0
    dw  TagBody
    db  "TITLE", 0
    dw  TagTitle
    db  "HTML", 0
    dw  TagNoOp
    db  "P", 0
    dw  TagP
    db  "BR", 0
    dw  TagBr
    db  "HR", 0
    dw  TagHr
    db  "H1", 0
    dw  TagH1
    db  "H2", 0
    dw  TagH2
    db  "H3", 0
    dw  TagH3
    db  "H4", 0
    dw  TagH4
    db  "H5", 0
    dw  TagH5
    db  "H6", 0
    dw  TagH6
    db  "B", 0
    dw  TagB
    db  "STRONG", 0
    dw  TagB
    db  "I", 0
    dw  TagI
    db  "EM", 0
    dw  TagI
    db  "U", 0
    dw  TagU
    db  "S", 0
    dw  TagS
    db  "STRIKE", 0
    dw  TagS
    db  "DEL", 0
    dw  TagS
    db  "A", 0
    dw  TagA
    db  "UL", 0
    dw  TagUl
    db  "OL", 0
    dw  TagOl
    db  "LI", 0
    dw  TagLi
    db  "PRE", 0
    dw  TagPre
    db  "BLOCKQUOTE", 0
    dw  TagBlockquote
    db  "IMG", 0
    dw  TagImg
    db  "TABLE", 0
    dw  TagTableTag
    db  "TR", 0
    dw  TagTr
    db  "TD", 0
    dw  TagTd
    db  "TH", 0
    dw  TagTh
    db  "FONT", 0
    dw  TagFont
    db  0                               ; end marker

; ----------------------------------------------------------------------------
; ParseEntity: HL points after '&'. Decodes &amp; &lt; &gt; &quot; &apos;
; &nbsp; and numeric &#NN;. Returns char in A (0 if unrecognised). On success
; HL is advanced past the closing ';'; on failure HL is left at '&'+1 so the
; caller sees the original stream.
; ----------------------------------------------------------------------------
ParseEntity:
    ; Save entry HL so we can bail out if this isn't a real entity.
    push    hl
    ld      a, [hl]
    cp      '#'
    jr      z, .numeric

    ; Read up to 5 letters into scratch.
    ld      de, HtmlEntityName
    ld      b, 5
.letLoop:
    ld      a, [hl]
    cp      0x3B                        ; semicolon
    jr      z, .letDone
    call    IsAsciiLetter
    jr      nc, .fail
    ; Uppercase.
    cp      'a'
    jr      c, .letUp
    cp      'z' + 1
    jr      nc, .letUp
    sub     'a' - 'A'
.letUp:
    ld      [de], a
    inc     de
    inc     hl
    djnz    .letLoop
    ; If we ran out of space without hitting ';', it's not an entity.
    ld      a, [hl]
    cp      0x3B                        ; semicolon
    jr      nz, .fail
.letDone:
    xor     a
    ld      [de], a
    inc     hl                          ; consume ';'
    ; Drop the start-of-entity save; use the stack slot to stash the *new*
    ; source pointer while LookupEntity walks EntityTable (which clobbers HL).
    pop     de                          ; discard saved start
    push    hl                          ; save source pointer
    call    LookupEntity                ; returns A = char (or 0); clobbers HL
    pop     hl                          ; restore source pointer
    ret

.numeric:
    inc     hl                          ; past '#'
    ld      bc, 0                       ; accumulator
.numLoop:
    ld      a, [hl]
    cp      0x3B                        ; semicolon
    jr      z, .numDone
    cp      '0'
    jr      c, .fail
    cp      '9' + 1
    jr      nc, .fail
    sub     '0'
    ld      e, a
    ; BC = BC * 10 + E, clamped to a byte.
    ld      a, c
    add     a, a                        ; *2
    ld      c, a
    add     a, a                        ; *4
    add     a, a                        ; *8
    add     a, c                        ; *10
    add     a, e
    ld      c, a
    inc     hl
    jr      .numLoop
.numDone:
    inc     hl                          ; consume ';'
    pop     de                          ; discard saved start; HL = source now
    ld      a, c
    ; Only pass printable ASCII through.
    cp      0x20
    jr      c, .numFail
    cp      0x7F
    jr      nc, .numFail
    ret
.numFail:
    ; Numeric entity was syntactically valid but out of range. HL is already
    ; past ';' so we just return 0 and let the caller skip.
    xor     a
    ret

.fail:
    pop     hl                          ; restore to just after '&'
    xor     a
    ret

IsAsciiLetter:
    cp      'A'
    jr      c, .no
    cp      'Z' + 1
    jr      c, .yes
    cp      'a'
    jr      c, .no
    cp      'z' + 1
    jr      c, .yes
.no:
    and     a                           ; clear carry
    ret
.yes:
    scf
    ret

; LookupEntity: HtmlEntityName holds the NUL-terminated uppercase name.
; Returns A = char, or 0 if unknown.
LookupEntity:
    ld      hl, EntityTable
.el:
    ld      a, [hl]
    or      a
    jr      z, .unknown
    push    hl
    ld      de, HtmlEntityName
.eCmp:
    ld      a, [de]
    ld      c, a
    ld      a, [hl]
    or      a
    jr      z, .eEnd
    cp      c
    jr      nz, .eMismatch
    inc     hl
    inc     de
    jr      .eCmp
.eEnd:
    ld      a, [de]
    or      a
    jr      nz, .eMismatch
    ; Match.
    inc     hl
    ld      a, [hl]                     ; char
    pop     bc
    ret
.eMismatch:
    pop     hl
.eSk:
    ld      a, [hl]
    inc     hl
    or      a
    jr      nz, .eSk
    inc     hl                          ; skip char byte
    jr      .el
.unknown:
    xor     a
    ret

EntityTable:
    db  "AMP", 0, 0x26                  ; ampersand
    db  "LT", 0, 0x3C                   ; less-than
    db  "GT", 0, 0x3E                   ; greater-than
    db  "QUOT", 0, 0x22                 ; double quote
    db  "APOS", 0, 0x27                 ; apostrophe
    db  "NBSP", 0, 0x20                 ; space
    db  0                               ; end marker

; TryLinkClick: if MouseX/MouseY sits on any link rect recorded in
; LinkTable, copy its URL into UrlBuf and tail-jump into navigation
; (never returns). Otherwise returns normally so the caller can continue
; with focus/scrollbar handling. Only single-line links are matched.
TryLinkClick:
    ld      a, [LinkCount]
    or      a
    ret     z
    ld      b, a                        ; B = loop counter
    ld      c, 0                        ; C = index

.tlc_loop:
    call    CheckLinkHit                ; Z if hit
    jr      z, .tlc_hit
    inc     c
    djnz    .tlc_loop
    ret

.tlc_hit:
    ; C = hit index. Copy LinkUrls[C] -> UrlBuf and navigate.
    ld      a, c
    call    GetLinkUrlPtr               ; HL = URL ptr
    call    CopyHrefToUrlBuf
    jp      NavigateAndFocusContent

; CheckLinkHit: C = link index. Z flag set on hit, NZ otherwise.
; Preserves B and C. Each rendered line is 8 px tall. For a multi-line
; link the hit rect is:
;   first row  y=startY..startY+7         x=startX..CONTENT_X_END
;   mid rows   y=startY+8..endY-1         any x in [0, CONTENT_X_END]
;   last row   y=endY..endY+7             x=0..endX
; Because every row is eight pixels, "mid rows" only exist when
; endY >= startY + 16.
CheckLinkHit:
    push    bc
    ld      d, 0
    ld      e, c

    ; MouseY must fit a single byte.
    ld      a, [MouseY + 1]
    or      a
    jr      nz, .clh_miss
    ld      a, [MouseY]
    ld      b, a                        ; B = mouseY

    ld      hl, LinkStartY
    add     hl, de
    ld      a, [hl]                     ; A = startY
    cp      b
    jr      z, .clh_firstRow
    jr      nc, .clh_miss               ; mouseY < startY -> miss

    ld      hl, LinkEndY
    add     hl, de
    ld      a, [hl]                     ; A = endY
    cp      b
    jr      z, .clh_lastRow
    jr      c, .clh_belowEnd            ; mouseY >= endY + 1 -> check endY band
    ; mouseY is strictly between startY+1..endY-1: full-row hit.
    jr      .clh_full

.clh_firstRow:
    ; mouseY == startY (top row of link). Require mouseX >= startX.
    ; (TOS still holds original (b,c).)
    pop     bc
    push    bc
    ld      d, 0
    ld      e, c
    ld      hl, LinkStartX
    add     hl, de
    add     hl, de
    ld      c, [hl]
    inc     hl
    ld      b, [hl]
    ld      hl, [MouseX]
    ld      d, b
    ld      e, c
    and     a
    sbc     hl, de
    jr      c, .clh_miss                ; mouseX < startX

    ; Single-line link: also enforce mouseX < endX.
    pop     bc
    push    bc
    ld      d, 0
    ld      e, c
    ld      hl, LinkStartY
    add     hl, de
    ld      a, [hl]
    ld      b, a
    ld      hl, LinkEndY
    add     hl, de
    ld      a, [hl]
    cp      b
    jr      nz, .clh_hit                ; multi-line -> top row accepts any x
    ; Single line: apply endX upper bound.
    jr      .clh_checkEndX

.clh_belowEnd:
    ; MouseY > endY. Require mouseY within endY..endY+7. A holds endY.
    ld      c, a
    ld      a, b                        ; mouseY
    sub     c
    cp      TEXT_LINE_H
    jr      nc, .clh_miss
    ; Treat as last-row band.

.clh_lastRow:
    ; mouseY == endY (or just below). Require mouseX < endX.
.clh_checkEndX:
    pop     bc
    push    bc
    ld      d, 0
    ld      e, c
    ld      hl, LinkEndX
    add     hl, de
    add     hl, de
    ld      c, [hl]
    inc     hl
    ld      b, [hl]
    ld      hl, [MouseX]
    ld      d, b
    ld      e, c
    and     a
    sbc     hl, de
    jr      nc, .clh_miss               ; mouseX >= endX
    jr      .clh_hit

.clh_full:
    ; mouseY is strictly between startY and endY -> any x is a hit.

.clh_hit:
    pop     bc
    xor     a                           ; set Z
    ret

.clh_miss:
    pop     bc
    or      1                           ; clear Z
    ret

; GetLinkUrlPtr: A = link index -> HL = pointer to url string in LinkUrls.
GetLinkUrlPtr:
    ld      l, a
    ld      h, 0
    ld      d, h
    ld      e, l
    add     hl, hl                      ; *2
    add     hl, hl                      ; *4
    add     hl, hl                      ; *8
    add     hl, hl                      ; *16
    add     hl, hl                      ; *32
    add     hl, de                      ; *33 (LINK_URL_MAX + 1)
    ld      de, LinkUrls
    add     hl, de
    ret

; CopyHrefToUrlBuf: HL = NUL-terminated URL. Copies into UrlBuf + updates
; UrlLen. Caller guarantees length <= URL_MAX.
CopyHrefToUrlBuf:
    ld      de, UrlBuf
    xor     a
    ld      [UrlLen], a
    ld      b, URL_MAX
.chb_loop:
    ld      a, [hl]
    ld      [de], a
    or      a
    ret     z
    inc     hl
    inc     de
    ld      a, [UrlLen]
    inc     a
    ld      [UrlLen], a
    djnz    .chb_loop
    xor     a
    ld      [de], a                     ; ensure NUL terminator on overflow
    ret

; ============================================================================
; Step 2: Navigation + 1-step history
; ============================================================================

; NavigateAndFocusContent: load UrlBuf then shift focus to the content
; area so the user can scroll immediately. Used by Enter in the address
; bar, Refresh button, link clicks, and Enter on a Tab-focused link.
NavigateAndFocusContent:
    call    NavigateToCurrentUrl
    ld      a, FOC_CONTENT
    ld      [Focus], a
    jp      PaintToolbar

; NavigateToCurrentUrl: load whatever is in UrlBuf and, on success, push
; it onto the ring-buffered history. Uses Busy to flip the toolbar to
; "stop" while the file is streaming in.
NavigateToCurrentUrl:
    ld      a, 0xFF
    ld      [HtmlFocusLink], a

    ld      a, 1
    ld      [Busy], a
    call    PaintToolbar

    call    BuildFcbFromUrl
    call    DetectPlainText
    call    LoadFile
    or      a
    jr      nz, .err

    call    HistoryPush                 ; records UrlBuf -> history[cursor]
    call    HistoryUpdateFlags
    ld      a, 1
    ld      [HasLoaded], a

    xor     a
    ld      [ScrollLine], a
    call    ClearContentArea
    call    PrintFileContent
    ld      a, [HtmlLineCount]
    ld      [TotalLines], a
    call    ComputeThumb
    call    DrawScrollbar
    xor     a
    ld      [Busy], a
    jp      PaintToolbar

.err:
    xor     a
    ld      [Busy], a
    call    ClearContentArea
    jp      PaintToolbar

; GoBack / GoForward walk the history cursor. They do not push a new
; entry; they re-load whatever URL sits at the new cursor position.
GoBack:
    ld      a, [HistoryCursor]
    or      a
    ret     z
    dec     a
    ld      [HistoryCursor], a
    call    HistoryLoadAtCursor
    call    HistoryUpdateFlags
    jr      ReloadCurrent

GoForward:
    ld      a, [HistoryCount]
    or      a
    ret     z
    dec     a
    ld      b, a                        ; B = count-1
    ld      a, [HistoryCursor]
    cp      b
    ret     nc                          ; already at newest
    inc     a
    ld      [HistoryCursor], a
    call    HistoryLoadAtCursor
    call    HistoryUpdateFlags

; ReloadCurrent: re-open UrlBuf, re-render, repaint. Shows the Stop glyph
; during the load by toggling Busy; restores Refresh when the load ends.
ReloadCurrent:
    ld      a, 0xFF
    ld      [HtmlFocusLink], a
    ld      a, 1
    ld      [Busy], a
    call    PaintToolbar
    call    BuildFcbFromUrl
    call    DetectPlainText
    call    LoadFile
    xor     a
    ld      [ScrollLine], a
    call    ClearContentArea
    call    PrintFileContent
    ld      a, [HtmlLineCount]
    ld      [TotalLines], a
    call    ComputeThumb
    call    DrawScrollbar
    xor     a
    ld      [Busy], a
    jp      PaintToolbar

; ----------------------------------------------------------------------------
; Ring-buffered navigation history (HISTORY_MAX = 8 slots).
; ----------------------------------------------------------------------------

; HistorySlotPtr: A = slot index (0..7), returns HL = HistoryBuf + A*HISTORY_SLOT.
HistorySlotPtr:
    ld      hl, HistoryBuf
    or      a
    ret     z
    ld      b, a
    ld      de, HISTORY_SLOT
.loop:
    add     hl, de
    djnz    .loop
    ret

; HistoryPush: copy UrlBuf into the next history slot, truncating any
; forward history first. If the ring is full, overwrite the oldest entry
; and slide HistoryOldest forward.
HistoryPush:
    ; Truncate forward history: count = cursor + 1.
    ld      a, [HistoryCursor]
    inc     a
    ld      b, a
    ld      a, [HistoryCount]
    cp      b
    jr      c, .noTrunc                 ; count already <= cursor+1
    ld      a, b
    ld      [HistoryCount], a
.noTrunc:

    ; Pick a slot to write into. If count < MAX, append a new slot.
    ; Otherwise overwrite the oldest and slide oldest forward.
    ld      a, [HistoryCount]
    cp      HISTORY_MAX
    jr      z, .rollOldest
    ld      b, a
    ld      a, [HistoryOldest]
    add     a, b
    and     HISTORY_MAX - 1
    ld      b, a                        ; B = slot
    ld      a, [HistoryCount]
    inc     a
    ld      [HistoryCount], a
    jr      .doCopy

.rollOldest:
    ld      a, [HistoryOldest]
    ld      b, a                        ; B = slot = current oldest
    inc     a
    and     HISTORY_MAX - 1
    ld      [HistoryOldest], a
    ; count stays at HISTORY_MAX

.doCopy:
    ld      a, b
    call    HistorySlotPtr
    ex      de, hl                      ; DE = dst slot
    ld      hl, UrlBuf
    ld      bc, HISTORY_SLOT
    ldir

    ; Cursor points to the entry we just wrote (newest).
    ld      a, [HistoryCount]
    dec     a
    ld      [HistoryCursor], a
    ret

; HistoryLoadAtCursor: copy HistoryBuf[cursor] into UrlBuf; recompute
; UrlLen by scanning for NUL; repaint the toolbar so the address bar
; shows the restored URL.
HistoryLoadAtCursor:
    ld      a, [HistoryOldest]
    ld      b, a
    ld      a, [HistoryCursor]
    add     a, b
    and     HISTORY_MAX - 1
    call    HistorySlotPtr
    ld      de, UrlBuf
    ld      bc, HISTORY_SLOT
    ldir
    ; Rescan for NUL to derive UrlLen.
    ld      hl, UrlBuf
    ld      b, 0
.scan:
    ld      a, [hl]
    or      a
    jr      z, .scanDone
    inc     hl
    inc     b
    jr      .scan
.scanDone:
    ld      a, b
    ld      [UrlLen], a
    jp      PaintToolbar

; HistoryUpdateFlags: refresh HasPrev / HasNext from cursor+count so the
; toolbar's existing enable logic keeps working unchanged.
HistoryUpdateFlags:
    ld      a, [HistoryCursor]
    or      a
    ld      a, 0
    jr      z, .noPrev
    ld      a, 1
.noPrev:
    ld      [HasPrev], a

    ld      a, [HistoryCount]
    or      a
    jr      z, .noNext
    dec     a
    ld      b, a
    ld      a, [HistoryCursor]
    cp      b
    jr      nc, .noNext                 ; cursor >= count-1
    ld      a, 1
    ld      [HasNext], a
    ret
.noNext:
    xor     a
    ld      [HasNext], a
    ret

; ============================================================================
; Step 2: Scrolling
; ============================================================================

; RefreshAfterScroll: recompute thumb, redraw content + scrollbar.
RefreshAfterScroll:
    call    ComputeThumb
    call    ClearContentArea
    call    PrintFileContent
    jp      DrawScrollbar

; ScrollUp: decrement ScrollLine if > 0, refresh.
ScrollUp:
    ld      a, [ScrollLine]
    or      a
    ret     z
    dec     a
    ld      [ScrollLine], a
    jp      RefreshAfterScroll

; PageUp: subtract TEXT_MAX_LINES from ScrollLine (clamping to 0), refresh.
PageUp:
    ld      a, [ScrollLine]
    sub     TEXT_MAX_LINES
    jr      nc, .store
    xor     a
.store:
    ld      [ScrollLine], a
    jp      RefreshAfterScroll

; PageDown: add TEXT_MAX_LINES to ScrollLine, clamped to (TotalLines - 1).
PageDown:
    ld      a, [TotalLines]
    or      a
    ret     z
    ld      d, a                        ; D = TotalLines
    ld      a, [ScrollLine]
    add     a, TEXT_MAX_LINES
    cp      d
    jr      c, .pdStore
    ld      a, d
    dec     a                           ; clamp to TotalLines - 1
.pdStore:
    ld      [ScrollLine], a
    jp      RefreshAfterScroll

; ScrollDown: if there's more content below, bump ScrollLine and refresh.
ScrollDown:
    ld      a, [TotalLines]
    ld      d, a
    ld      a, [ScrollLine]
    inc     a
    cp      d
    ret     nc                          ; ScrollLine + 1 >= TotalLines
    ld      [ScrollLine], a
    jp      RefreshAfterScroll

; ============================================================================
; Step 2.5: Mouse (direct PSG reads on joyporta) + click dispatch
;
; Mouse is read through PSG registers 14 (data in, port 0xA2) and 15 (data
; out, port 0xA1). Reg 15 configures which port + which nibble is sampled;
; reg 14 returns the 4-bit axis delta plus button bits. Two GetMouseAxis
; calls yield (dX in H, dY in L); A holds the raw PSG reg-14 byte so bits
; 4/5 = right/left button. See resources/MSX Mouse/ for the source ref.
; ============================================================================

PSG_ADDR_PORT  equ 0xA0
PSG_DATA_WR    equ 0xA1
PSG_DATA_RD    equ 0xA2
MOUSE1_HI_CFG  equ 0x93                 ; binary 10010011 -- mouse 1, high nibble
MOUSE1_LO_CFG  equ 0x83                 ; binary 10000011 -- mouse 1, low nibble
MOUSE_BTN_MASK equ 0x30                 ; PSG reg 14 bits 4+5 = L/R buttons (active low); accept either

; GetMouse: HL = (dX, dY) signed 8-bit deltas, A = raw button byte.
GetMouse:
    call    GetMouseAxis
    ld      h, a
    call    GetMouseAxis
    ld      l, a
    ld      a, b                        ; button byte captured in B
    or      0xCF                        ; force unused bits high
    ret

GetMouseAxis:
    ld      d, MOUSE1_HI_CFG
    call    GetMouseNibble
    and     0x0F
    rlca
    rlca
    rlca
    rlca
    ld      c, a                        ; C = top nibble in high 4 bits

    ld      d, MOUSE1_LO_CFG
    call    GetMouseNibble
    ld      b, a                        ; keep raw byte (button bits 4/5)
    and     0x0F
    or      c
    ret

; GetMouseNibble: PSG reg 15 <- D; short delay; A <- PSG reg 14.
; DI to avoid racing with the vsync ISR that also scans the PSG for the
; keyboard matrix.
GetMouseNibble:
    di
    ld      a, 15
    out     [PSG_ADDR_PORT], a
    ld      a, d
    out     [PSG_DATA_WR], a
    ld      b, 10
.wait:
    djnz    .wait
    ld      a, 14
    out     [PSG_ADDR_PORT], a
    in      a, [PSG_DATA_RD]
    ei
    ret

; EraseCursor: if the cursor is currently visible, restore the 16 VRAM bytes
; under it from CursorBg and clear the visible flag. Safe to call any time.
EraseCursor:
    ld      a, [CursorVisible]
    or      a
    ret     z

    ld      hl, [CursorX]
    srl     h
    rr      l
    srl     h
    rr      l                           ; HL = CursorX / 4
    ld      a, l
    ld      [CursorByteCol], a
    ld      a, [CursorY]
    ld      [CursorRowY], a
    ld      hl, CursorBg
    ld      [CursorBgPtr], hl

    ld      e, 8                        ; 8 rows
.rowLoop:
    ld      a, [CursorByteCol]
    ld      b, a
    ld      a, [CursorRowY]
    ld      c, a
    push    de
    call    SetVramWritePos
    pop     de
    ld      hl, [CursorBgPtr]
    ld      a, [hl]
    out     [VDP_DATA], a
    inc     hl
    ld      a, [hl]
    out     [VDP_DATA], a
    inc     hl
    ld      [CursorBgPtr], hl

    ld      a, [CursorRowY]
    inc     a
    ld      [CursorRowY], a
    dec     e
    jr      nz, .rowLoop

    xor     a
    ld      [CursorVisible], a
    ret

; DrawCursor: save VRAM under (MouseX, MouseY), then paint an 8x8 black
; square there. Assumes the cursor is NOT already visible (EraseCursor is
; idempotent and safe to call first).
DrawCursor:
    call    EraseCursor                 ; ensure clean state

    ; Record the position we're drawing at so EraseCursor restores correctly.
    ld      hl, [MouseX]
    ld      [CursorX], hl
    ld      a, [MouseY]
    ld      [CursorY], a

    ld      hl, [MouseX]
    srl     h
    rr      l
    srl     h
    rr      l
    ld      a, l
    ld      [CursorByteCol], a
    ld      a, [MouseY]
    ld      [CursorRowY], a

    ; --- Save 2 VRAM bytes * 8 rows into CursorBg ---
    ld      hl, CursorBg
    ld      [CursorBgPtr], hl
    ld      e, 8
.saveLoop:
    ld      a, [CursorByteCol]
    ld      b, a
    ld      a, [CursorRowY]
    ld      c, a
    push    de
    call    SetVramReadPos
    pop     de
    in      a, [VDP_DATA]
    ld      hl, [CursorBgPtr]
    ld      [hl], a
    inc     hl
    in      a, [VDP_DATA]
    ld      [hl], a
    inc     hl
    ld      [CursorBgPtr], hl

    ld      a, [CursorRowY]
    inc     a
    ld      [CursorRowY], a
    dec     e
    jr      nz, .saveLoop

    ; --- Paint 2 bytes per row: new = saved_bg OR cursor_mask.
    ld      a, [MouseY]
    ld      [CursorRowY], a
    ld      ix, CursorBg
    ld      iy, CursorMask
    ld      e, 8
.drawLoop:
    ld      a, [CursorByteCol]
    ld      b, a
    ld      a, [CursorRowY]
    ld      c, a
    push    de
    call    SetVramWritePos
    pop     de

    ld      a, [ix + 0]
    or      [iy + 0]
    out     [VDP_DATA], a
    ld      a, [ix + 1]
    or      [iy + 1]
    out     [VDP_DATA], a

    inc     ix
    inc     ix
    inc     iy
    inc     iy
    ld      a, [CursorRowY]
    inc     a
    ld      [CursorRowY], a
    dec     e
    jr      nz, .drawLoop

    ld      a, 1
    ld      [CursorVisible], a
    ret

; CursorMask: 8 rows x 2 bytes. Each byte has 11-pair for opaque pixels, 00
; elsewhere. OR'd with saved bg to produce the final cursor row. Shape from
; resources/mouse_pointer.bmp (top-left anchored arrow, 8x8 MSX pixels).
CursorMask:
    db  0xF0, 0x00
    db  0xFC, 0x00
    db  0xFF, 0xC0
    db  0xFF, 0xF0
    db  0xFF, 0xFC
    db  0xFC, 0x00
    db  0xF0, 0x00
    db  0xC0, 0x00

; PollMouse: called every main-loop iteration. Reads mouse, clamps position,
; detects a press edge (prev=0 -> now=1) and dispatches to HandleClick.
PollMouse:
    call    EraseCursor                 ; clear old cursor before we move
    call    GetMouse
    ld      [MouseRaw], a
    ; Raw axis deltas are inverted vs screen axes on the MSX mouse (per
    ; Lesson P64 "NEG added to GetMouseNibble"). Negate both before storing.
    ld      a, h
    neg
    ld      [MouseDx], a
    ld      a, l
    neg
    ld      [MouseDy], a

    ; --- button state (bits 4/5 of MouseRaw are L/R buttons, active low) ---
    ld      a, [MouseBtnNow]
    ld      [MouseBtnPrev], a
    ld      a, [MouseRaw]
    and     MOUSE_BTN_MASK
    cp      MOUSE_BTN_MASK              ; both high => no button pressed
    ld      c, 0
    jr      z, .btnStore
    ld      c, 1
.btnStore:
    ld      a, c
    ld      [MouseBtnNow], a

    ; --- MouseX += sign-extended dX, clamped to [0, 511] ---
    ld      a, [MouseDx]
    ld      e, a
    ld      d, 0
    bit     7, a
    jr      z, .xPos
    dec     d                           ; sign-extend negative delta
.xPos:
    ld      hl, [MouseX]
    add     hl, de
    bit     7, h
    jr      nz, .xZero
    ld      a, h
    cp      2
    jr      c, .xStore                  ; HL < 512
    ld      hl, 511
    jr      .xStore
.xZero:
    ld      hl, 0
.xStore:
    ld      [MouseX], hl

    ; --- MouseY += sign-extended dY, clamped to [0, CONTENT_Y1] ---
    ld      a, [MouseDy]
    ld      e, a
    ld      d, 0
    bit     7, a
    jr      z, .yPos
    dec     d
.yPos:
    ld      hl, [MouseY]
    add     hl, de
    bit     7, h
    jr      nz, .yZero
    ld      a, h
    or      a
    jr      nz, .yMax                   ; HL >= 256 -> clamp
    ld      a, l
    cp      CONTENT_Y1 + 1
    jr      c, .yStore
.yMax:
    ld      hl, CONTENT_Y1
    jr      .yStore
.yZero:
    ld      hl, 0
.yStore:
    ld      [MouseY], hl

    ; --- edge detect: prev=0, now=1 -> new click ---
    ld      a, [MouseBtnNow]
    or      a
    jr      z, .noClick
    ld      a, [MouseBtnPrev]
    or      a
    jr      nz, .noClick
    call    HandleClick                 ; may redraw UI; cursor still erased
.noClick:
    jp      DrawCursor

; HandleClick: dispatch the just-pressed mouse to whatever UI region sits
; under (MouseX, MouseY). Either returns (no-op) or jumps into an existing
; keyboard-handler routine; MainLoop is the shared return point.
HandleClick:
    ; Popup mode: only the popup's X-glyph closes the dialog.
    ld      a, [AboutOpen]
    or      a
    jp      nz, ClickInPopup

    ; Out-of-screen clicks (shouldn't happen with our clamp) are ignored.
    ld      a, [MouseY + 1]
    or      a
    ret     nz
    ld      a, [MouseY]

    ; Y-band dispatch.
    cp      9
    jp      c, ClickTitle               ; titlebar (y 0..8)
    cp      TOOL_Y0
    ret     c                           ; separator
    cp      BTN_Y0 + BTN_H
    jp      c, ClickToolbar             ; toolbar (y 12..26)
    cp      CONTENT_Y0
    ret     c                           ; separator
    jp      ClickContent                ; content + scrollbar

; CpHL: sets flags from HL-DE (C if HL < DE, Z if equal). Cheaper than SBC
; since it doesn't need OR A beforehand and doesn't modify HL.
CpHL:
    ld      a, h
    cp      d
    ret     nz
    ld      a, l
    cp      e
    ret

; ---- titlebar: "?" glyph opens About, "X" glyph exits ----
ClickTitle:
    ld      hl, [MouseX]
    ld      de, WIDTH - 24
    call    CpHL
    ret     c                           ; left of "?" -- just text
    ld      de, WIDTH - 16
    call    CpHL
    jp      c, OpenAbout                ; "?" glyph
    ld      de, WIDTH - 12
    call    CpHL
    ret     c                           ; between glyphs
    ld      de, WIDTH
    call    CpHL
    ret     nc
    jp      Shutdown                    ; "X" glyph

; ---- toolbar: Back / Forward / Address-bar + clear-X / Refresh(Go) ----
; Regions are tested left-to-right; the `ret c` guards mean any click that
; falls into a gap between regions is silently ignored.
ClickToolbar:
    ld      hl, [MouseX]

    ; Back button rect: [BTN1_X, BTN1_X + BTN_W)
    ld      de, BTN1_X
    call    CpHL
    ret     c
    ld      de, BTN1_X + BTN_W
    call    CpHL
    jr      c, .tBack

    ; Forward button rect: [BTN3_X, BTN3_X + BTN_W)
    ld      de, BTN3_X
    call    CpHL
    ret     c
    ld      de, BTN3_X + BTN_W
    call    CpHL
    jr      c, .tFwd

    ; Address bar rect: [ADDR_X0, ADDR_X1 + 1)
    ld      de, ADDR_X0
    call    CpHL
    ret     c
    ld      de, ADDR_X1 + 1
    call    CpHL
    jr      c, .tAddr

    ; Refresh button rect: [BTN2_X, BTN2_X + BTN_W)
    ld      de, BTN2_X
    call    CpHL
    ret     c
    ld      de, BTN2_X + BTN_W
    call    CpHL
    jp      c, NavigateAndFocusContent  ; Refresh = Go + focus view
    ret

.tAddr:
    ; In address bar. Check if over clear-x glyph (ADDR_X1 - 8..ADDR_X1).
    ld      de, ADDR_X1 - 8
    call    CpHL
    jr      c, .addrMain
    ; Clear-x click
    call    UrlClear
    jp      PaintToolbar

.addrMain:
    ; Focus the address bar so subsequent typing goes there.
    ld      a, FOC_ADDRESS
    ld      [Focus], a
    jp      PaintToolbar

.tBack:
    ld      a, [HasPrev]
    or      a
    ret     z
    jp      GoBack

.tFwd:
    ld      a, [HasNext]
    or      a
    ret     z
    jp      GoForward

; ---- content area + scrollbar ----
ClickContent:
    ld      hl, [MouseX]
    ld      de, SCROLL_X0
    call    CpHL
    jr      nc, .cScroll                ; x >= 496 -> scrollbar
    ; Click inside the text. First check for a link hit, otherwise focus
    ; the content area so scroll keys work.
    call    TryLinkClick                ; navigates + returns if hit
    ld      a, FOC_CONTENT
    ld      [Focus], a
    jp      PaintToolbar

.cScroll:
    ld      a, [MouseY]
    cp      SCROLL_UP_Y1 + 1
    jp      c, ScrollUp                 ; up-arrow zone -> 1 line up
    cp      SCROLL_DN_Y0
    jp      nc, ScrollDown              ; down-arrow zone -> 1 line down
    ; Track zone: above thumb -> PageUp; on/below thumb -> PageDown.
    ; (Clicking the thumb itself pages down, matching typical OS behaviour.)
    ; Suppress paging on short pages (thumb fills track): nothing to scroll,
    ; and PageDown would otherwise push the view past the end leaving only the
    ; last line visible.
    ld      b, a                        ; B = click Y
    ld      a, [TotalLines]
    cp      TEXT_MAX_LINES + 1
    ret     c                           ; <= TEXT_MAX_LINES -> no-op
    ld      a, [ThumbTop]
    cp      b
    jp      nc, PageUp                  ; ThumbTop > click -> click is above thumb
    jp      PageDown

; ---- popup's X-glyph closes the About dialog ----
ClickInPopup:
    ld      a, [MouseY]
    cp      ABOUT_Y
    ret     c
    cp      ABOUT_Y + 16
    ret     nc
    ld      hl, [MouseX]
    ld      de, ABOUT_X + ABOUT_W - 16
    call    CpHL
    ret     c
    ld      de, ABOUT_X + ABOUT_W
    call    CpHL
    ret     nc
    jp      CloseAbout

; ============================================================================
; Step 2.5: About popup (opened via F1, closed via Esc)
;   The popup sits entirely inside the content area so closing it only costs
;   a content repaint; titlebar/toolbar/scrollbar remain untouched.
; ============================================================================

; Both OpenAbout and CloseAbout end with `ret` so HandleClick's `jp` to them
; unwinds back through PollMouse correctly. Keyboard-path callers wrap each
; in `call OpenAbout / jp MainLoop`.
OpenAbout:
    ld      a, 1
    ld      [AboutOpen], a
    jp      DrawAboutPopup              ; DrawAboutPopup ends with `ret`

CloseAbout:
    xor     a
    ld      [AboutOpen], a
    call    ClearContentArea
    jp      PrintFileContent            ; PrintFileContent ends with `ret`

DrawAboutPopup:
    ; Popup body: 256 x 120 centred in the content area, at (128, 50).
    ld      b, ABOUT_X / 4
    ld      c, ABOUT_Y
    ld      d, ABOUT_W / 4
    ld      e, ABOUT_H
    ld      a, COL_WHITE
    call    FillRect

    ld      b, ABOUT_X / 4
    ld      c, ABOUT_Y
    ld      d, ABOUT_W / 4
    ld      e, ABOUT_H
    ld      a, COL_BLACK
    call    DrawRectBorder

    ; Black-on-white body text (we're on the content area which is white).
    ld      a, COL_BLACK
    ld      l, COL_WHITE
    call    SetTextColours

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + 4
    ld      hl, AboutTitleMsg
    call    DrawString

    ld      de, ABOUT_X + ABOUT_W - 12  ; X glyph in the popup's top-right
    ld      c, ABOUT_Y + 4
    ld      hl, CharX
    call    DrawString

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + 24
    ld      hl, AboutLine1
    call    DrawString

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + 36
    ld      hl, AboutLine2
    call    DrawString

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + 48
    ld      hl, AboutLine3
    call    DrawString

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + 72
    ld      hl, AboutLine4
    call    DrawString

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + 84
    ld      hl, AboutLine5
    call    DrawString

    ld      de, ABOUT_X + 8
    ld      c, ABOUT_Y + ABOUT_H - 12
    ld      hl, AboutFooter
    jp      DrawString

; ============================================================================
; Labels (title only; buttons now use icons/chars, not text labels)
; ============================================================================

DrawTitleLabel:
    ; Repaint the titlebar band so an updated <title> erases the old caption.
    ld      b, 0
    ld      c, 0
    ld      d, WIDTH / 4
    ld      e, SEP1_Y
    ld      a, COL_LGRAY
    call    FillRect

    ld      a, COL_BLACK
    ld      l, COL_LGRAY
    call    SetTextColours

    ; Lead text: captured <title> (or "(no title)").
    ld      de, 4
    ld      c, 1
    ld      a, [HtmlTitleSeen]
    or      a
    jr      z, .useDefault
    ld      a, [HtmlTitleLen]
    or      a
    jr      z, .useDefault
    ld      hl, HtmlTitleBuf
    ld      a, [HtmlTitleLen]
    jr      .drawLead
.useDefault:
    ld      hl, TitleNone
    ld      a, 10                       ; strlen("(no title)")
.drawLead:
    push    af                          ; save lead length
    call    DrawString
    pop     af

    ; Suffix at DE = 4 + leadLen * 8.
    ld      l, a
    ld      h, 0
    add     hl, hl
    add     hl, hl
    add     hl, hl                      ; HL = leadLen * 8
    ld      de, 4
    add     hl, de
    ex      de, hl                      ; DE = pixel X
    ld      c, 1
    ld      hl, TitleSuffix
    call    DrawString

    ; "?" button (About popup; shortcut F1). Placed left of the X.
    ld      de, WIDTH - 24
    ld      c, 1
    ld      hl, CharHelp
    call    DrawString

    ; "X" button (close; shortcut Esc). Rightmost glyph in the titlebar.
    ld      de, WIDTH - 12
    ld      c, 1
    ld      hl, CharX
    jp      DrawString

; ============================================================================
; Data
; ============================================================================

TitleNone:      db "(no title)", 0
TitleSuffix:    db " - MSX WBrowser", 0
CharLess:       db "<", 0
CharGreater:    db ">", 0
CharX:          db "X", 0
CharLowerX:     db "x", 0
CharHelp:       db "?", 0
UrlInit:        db "a:\test.html", 0

AboutTitleMsg:  db "About", 0
AboutLine1:     db "MSX WBrowser", 0
AboutLine2:     db "MSX2 Screen 6 HTML browser.", 0
AboutLine3:     db "github.com/techana/mwbrowser", 0
AboutLine4:     db "F1 shows this dialog.", 0
AboutLine5:     db "Esc closes / quits.", 0
AboutFooter:    db "v0.3 demo build", 0

; Screen-6 icon bitmaps (4 px/byte, 11=black, 01=bg/lgray).

; Right-pointing arrow = up-arrow rotated 90 deg CW. 8 px wide x 8 rows.
; Used as the Refresh-button glyph; the "stop" (busy) case renders an 'X'
; via DrawCharFast so we don't need a separate bitmap.
IconArrowRight:
    db  0xD5, 0x55
    db  0xF5, 0x55
    db  0xFD, 0x55
    db  0xFF, 0x55
    db  0xFF, 0x55
    db  0xFD, 0x55
    db  0xF5, 0x55
    db  0xD5, 0x55

; resources/up.png -> 8x5 MSX pixels. DrawDownArrow reuses this by reading
; rows in reverse (DrawBitmapReverse), so no separate down-arrow bitmap.
IconUpArrow:
    ; 12-wide (3 bytes) x 5 rows. The 8x5 arrow shape shifted right by 1 MSX
    ; pixel; 1 px LGRAY padding on the left, 3 px LGRAY padding on the right.
    db  0x55, 0xF5, 0x55
    db  0x55, 0xF5, 0x55
    db  0x57, 0xFD, 0x55
    db  0x5F, 0xFF, 0x55
    db  0x7F, 0xFF, 0xD5

; Mutable state (initialised by InitState).
Focus:          db 0
Busy:           db 0
UrlLen:         db 0
UrlBuf:         ds URL_MAX + 1          ; 96 chars + NUL

; Mouse state -- driven by PSG reg 14/15 via ports 0xA0/0xA1/0xA2. Port A
; (joyporta on openMSX) is used; the GetMouse routine adapts the technique
; from resources/MSX Mouse/MSX_MouseText.asm.
MouseX:         dw 256
MouseY:         dw 100
MouseDx:        db 0
MouseDy:        db 0
MouseBtnNow:    db 0
MouseBtnPrev:   db 0
MouseRaw:       db 0                    ; raw button byte from last GetMouse

; Cursor rendering state -- VRAM save/restore so we can paint an 8x8 black
; square on top of whatever's under the mouse, and put it back before the
; next frame / UI redraw.
CursorX:        dw 0                    ; pixel X of the currently-drawn cursor
CursorY:        db 0                    ; pixel Y of the currently-drawn cursor
CursorVisible:  db 0
CursorBg:       ds 16                   ; 2 bytes * 8 rows VRAM backup
CursorByteCol:  db 0                    ; scratch (byte col during erase/draw)
CursorRowY:     db 0                    ; scratch (current y during loops)
CursorBgPtr:    dw 0                    ; scratch (pointer into CursorBg)
CursorMaskPtr:  dw 0                    ; scratch (pointer into CursorMask)
EntrySP:        dw 0                    ; SP at Main entry (restored on Shutdown)

; File I/O and navigation state.
Fcb:            ds 37                   ; MSX-DOS 1 FCB (36 bytes + 1 pad)
FileLen:        dw 0                    ; bytes actually loaded (clamped to buffer)
ScrollLine:     db 0                    ; first visible line (0 = top of file)
TotalLines:     db 0                    ; LF count in loaded file (for thumb math)
ThumbTop:       db THUMB_Y0             ; current thumb top y (set by ComputeThumb)
ThumbHeight:    db THUMB_Y1 - THUMB_Y0 + 1
HasLoaded:      db 0                    ; 1 once first successful load has happened
AboutOpen:      db 0                    ; 1 while the About popup is on screen

; Text cursor for DrawCharFast-based rendering.
TextX:          dw 0
TextY:          db 0

; DrawCharFast persists font pointer / row counter in RAM so SetVramWritePos
; can freely clobber HL/A between rows.
FastFontPtr:    dw 0
FastFontByte:   db 0
FastRowsLeft:   db 0

; Step 3: HTML parser state.
HtmlEnd:        dw 0                    ; end-of-buffer sentinel (FileBuf+FileLen)
HtmlInHead:     db 0                    ; 1 while inside <head>...</head>
HtmlInTitle:    db 0                    ; 1 while inside <title>...</title>
HtmlStyleFlags: db 0                    ; STYLE_BOLD / STYLE_ITALIC / etc.
HtmlWsPending:  db 0                    ; 1 = emit a space before next non-ws char
HtmlLineEmpty:  db 1                    ; 1 = cursor at start of a line (trim leading ws)
HtmlIsClose:    db 0                    ; scratch: 1 inside a closing tag
HtmlTitleSeen:  db 0                    ; 1 once <title>..</title> has resolved
HtmlTitleLen:   db 0                    ; bytes stored in HtmlTitleBuf
HtmlLineSkip:   db 0                    ; rendered lines still to skip (scroll)
HtmlLineCount:  db 0                    ; total rendered lines (for thumb math)
HtmlScaleY:     db 1                    ; 1 = normal glyph height, 2 = H1/H2
HtmlInAnchor:   db 0                    ; 1 while inside an <a>..</a>
HtmlFocusLink:  db 0xFF                 ; index of Tab-focused link (0xFF = none)
HtmlPre:        db 0                    ; 1 while inside <pre>
HtmlLiPending:  db 0                    ; 1 = next text emits a bullet first
HtmlListKind:   db 0                    ; 0=none, 1=ul, 2=ol
HtmlOlCounter:  db 0                    ; next <li> number in an <ol>
HtmlIndent:     db 0                    ; left indent in pixels for new lines
HtmlInTable:    db 0                    ; 1 while inside <table>
HtmlTableCol:   db 0                    ; current cell index within a row
HtmlTableFirst: db 0                    ; 1 if this is the very first row of the table
HtmlRowTopY:    db 0                    ; TextY at the top of the current row (for vertical rules)
HtmlSavedBold:  db 0                    ; scratch: STYLE_BOLD state before <th>
HtmlFg:         db 3                    ; current text fg palette index (default BLACK=3)
HtmlFgStack:    ds 4                    ; <font> stack of previous fg values
HtmlFgDepth:    db 0                    ; current <font> nesting depth
HtmlColorName:  ds 12                   ; scratch for color name lookup
CurrentFontLUT: dw FontLUT              ; pointer to active LUT (updated by <font>)
HtmlCurHrefLen: db 0                    ; length of the current href being captured
HtmlCurHref:    ds LINK_URL_MAX + 1     ; NUL-terminated href of the *open* <a>
LinkCount:      db 0                    ; number of live link rects
LinkStartX:     ds 2 * LINK_MAX
LinkStartY:     ds LINK_MAX
LinkEndX:       ds 2 * LINK_MAX
LinkEndY:       ds LINK_MAX
LinkUrls:       ds (LINK_URL_MAX + 1) * LINK_MAX
HtmlTitleBuf:   ds TITLE_BUF_MAX + 1    ; NUL-terminated
HtmlTagName:    ds 8                    ; up to 7 chars + NUL
HtmlEntityName: ds 6                    ; up to 5 chars + NUL
DebugTmpBuf:    ds 10                   ; scratch for debug labels
FastCgSlot:     db 0                    ; cached CGPNT[0] for ExtractFont

; Multi-step back/forward history. Ring buffer of HISTORY_MAX URL slots.
; The cursor points at the "current" entry; new navigations push at
; cursor+1 (after truncating any forward history) and roll out the oldest
; entry when the ring is full. HasPrev / HasNext are derived flags updated
; via HistoryUpdateFlags so the toolbar's enable logic keeps working.
HISTORY_MAX     equ 8                   ; must be a power of two (for `and` mask)
HISTORY_SLOT    equ URL_MAX + 1         ; bytes per slot

HistoryBuf:     ds HISTORY_SLOT * HISTORY_MAX
HistoryOldest:  db 0
HistoryCount:   db 0
HistoryCursor:  db 0
HasPrev:        db 0
HasNext:        db 0

; Arabic word buffer for Step 5A reshaping. EmitIsoByte appends bytes with
; IsoJoin != 0 here; on any boundary char (or newline) the buffer is
; shape-resolved and emitted reversed to EmitRaw.
AR_BUF_MAX      equ 32
ArBuf:          ds AR_BUF_MAX
ArLen:          db 0
ArCurr:         db 0                    ; ShapePick scratch: byte being shaped
ArCurrFlags:    db 0                    ; ShapePick scratch: curr's IsoJoin flags
ArConnect:      db 0                    ; ShapePick scratch: SHAPE_MASK_* accum
PlainTextMode:  db 0                    ; 1 when current file is .txt (no HTML)

; Step 5B: per-line glyph buffer (BiDi reorder + alignment). EmitRaw appends
; cells; LineFlush (called from EmitNewline) resolves neutrals, reorders
; RTL runs per UAX#9 L2, pads for alignment, and draws to VRAM.
LINE_BUF_MAX    equ 64                  ; ~492px / 8px per cell
CELL_RTL        equ 0x01                ; Arabic letter (already shaped)
CELL_NEUTRAL    equ 0x02                ; space/punct — direction from context
LineLen:        db 0
LineGlyph:      ds LINE_BUF_MAX
LineAttr:       ds LINE_BUF_MAX
EmitCellAttr:   db 0                    ; attr byte EmitRaw applies to next cell
HtmlAlign:      db 0                    ; 0=left, 1=right, 2=center
HtmlDir:        db 0                    ; 0=LTR paragraph, 1=RTL paragraph
HtmlNextAlign:  db 0xFF                 ; scratch: align= parsed on current tag (0xFF = unset)
HtmlNextDir:    db 0xFF                 ; scratch: dir= parsed on current tag

; ISO-8859-6 -> MSX font mapping + joining flags. Generated from
; `ISO-8859-6 font mapping/ISO-8859-6-font-mapping.csv` by
; tools/gen_iso8859_6.py. Kept as a separate include so the table stays
; machine-derived and can be regenerated without touching this source.
    include "iso8859_6.inc"

; FileBuf and FontBuf both live in free TPA memory past the .COM image.
; Declaring them as pure label equates avoids emitting any bytes, so the disk
; binary stays small; at runtime we read/write into the free RAM that
; MSX-DOS leaves above the program.
FileBuf         equ $
FontBuf         equ FileBuf + FILE_BUF_SIZE
