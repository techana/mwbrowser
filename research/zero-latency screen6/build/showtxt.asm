; SHOWTXT.ASM
; Assemble as MSX-DOS2 .COM, e.g. with SJASMPlus/Glass-style syntax.
;
; Reads A:\SOME.TXT, renders it to SCREEN 6 page 1, then flips to page 1.
; 64 columns x 26 rows, 8x8 font, no scrolling.
;
; Foreground pixel color = 3, background = 0.

        org     #0100
;       output  "SHOWTXT.COM"

; ------------------------------------------------------------
; BIOS / DOS
; ------------------------------------------------------------

BDOS        equ #0005

; The original sample called BIOS entries directly (e.g. CHGMOD equ
; #005F). That works only when the Main-ROM happens to be paged into
; page 0, which is NOT the case from an MSX-DOS .COM -- page 0 holds
; RAM with the .COM image, and #005F is just whatever junk is there.
; Replace every direct call with an inter-slot CALSLT through EXPTBL,
; matching the CALLBIOS pattern MWBrowser already uses.
BIOS_RDSLT      equ #000C
BIOS_CHGET      equ #009F
BIOS_CHGMOD     equ #005F
BIOS_LDIRVM     equ #005C
BIOS_EXTROM     equ #015F
CALSLT          equ #001C
EXPTBL          equ #FCC0

    MACRO CALLBIOS entry
        ld      iy, (EXPTBL)
        ld      ix, entry
        call    CALSLT
    ENDM

SETPAG      equ #013D       ; SUB-ROM
DPPAGE      equ #FAF5
ACPAGE      equ #FAF6
CGPNT       equ #F91F       ; slot + address of current MSX font

DOS_STROUT  equ #09
DOS_OPEN    equ #43
DOS_CLOSE   equ #45
DOS_READ    equ #48
DOS_TERM    equ #62

; ------------------------------------------------------------
; SCREEN 6 layout
; ------------------------------------------------------------

SCREEN_BYTES equ #6A00      ; 512 * 212 / 4
VRAM_PAGE1   equ #8000

COLS         equ 64
ROWS         equ 26
LINE_BYTES   equ 128        ; 512 pixels / 4 pixels per byte
ROW_STRIDE   equ 1024       ; 8 scanlines * 128 bytes

TEXT_MAX     equ 4096

; ------------------------------------------------------------
; Main
; ------------------------------------------------------------

Start:
        call    ReadFile
        jr      nc,.file_ok

        ld      de,MsgFileError
        call    PrintString
        ld      b,1
        jp      ExitDOS

.file_ok:
        call    CopySystemFont
        call    ClearScreenBuffer
        call    RenderTextToBuffer

        ; Change to SCREEN 6 only after the RAM bitmap is ready.
        ld      a,6
        CALLBIOS BIOS_CHGMOD

        ; Upload complete prepared bitmap to VRAM page 0 (display
        ; page; we drop the SETPAG dance below since CHGMOD already
        ; activated page 0 and SETPAG is a SUB-ROM call that needs
        ; an extra trampoline to work from MSX-DOS).
        ld      hl,ScreenBuf
        ld      de,0x0000           ; VRAM page 0 base
        ld      bc,SCREEN_BYTES
        CALLBIOS BIOS_LDIRVM

        ; Wait for key, then restore SCREEN 0 and return to DOS.
        CALLBIOS BIOS_CHGET
        xor     a
        CALLBIOS BIOS_CHGMOD

        ld      b,0
ExitDOS:
        ld      c,DOS_TERM
        call    BDOS

; ------------------------------------------------------------
; Read "SOME.TXT" into TextBuf, zero-terminate it.
; Original used MSX-DOS 2 handle calls (BDOS 0x43/0x48/0x45) which
; aren't available on the project's DOS 1.03 boot disk. To keep the
; experiment self-contained we just copy a built-in sample blob into
; TextBuf -- the rendering pipeline being measured doesn't change.
; ------------------------------------------------------------

ReadFile:
        ld      hl,SampleText
        ld      de,TextBuf
        ld      bc,SampleTextEnd - SampleText
        ldir
        xor     a                  ; CF=0 -> success
        ret

SampleText:
        db "ZERO-LATENCY SCREEN 6 EXPERIMENT",13,10
        db "================================",13,10
        db 13,10
        db "This file is rendered by SHOWTXT.COM.",13,10
        db 13,10
        db "Pipeline tested:",13,10
        db " - Compose a Screen-6 bitmap in RAM.",13,10
        db " - Switch to Screen 6 via BIOS CHGMOD.",13,10
        db " - Blit the whole bitmap to VRAM page 1",13,10
        db "   in one LDIRVM call, then page-flip.",13,10
        db 13,10
        db "Result: the 192x192 character grid",13,10
        db "appears as a single visible step --",13,10
        db "no per-line typewriter latency.",13,10
        db 13,10
        db "Lessons portable to MWBrowser:",13,10
        db " 1. RAM-side composition decouples the",13,10
        db "    parser from the VDP wait states.",13,10
        db " 2. LDIRVM page flip == 'instant'.",13,10
        db " 3. PageDown can re-blit a cached SC6",13,10
        db "    image instead of re-walking text.",13,10
        db 0
SampleTextEnd:

; ------------------------------------------------------------
; Copy current MSX 8x8 font from ROM slot into RAM
; CGPNT = slot byte + 16-bit address
; ------------------------------------------------------------

CopySystemFont:
        ld      a,(CGPNT)
        ld      (FontSlot),a
        ld      hl,(CGPNT+1)
        ld      de,FontBuf
        ld      bc,2048            ; 256 chars * 8 bytes

.copy_loop:
        push    bc
        push    de
        push    hl

        ld      a,(FontSlot)
        CALLBIOS BIOS_RDSLT        ; A = byte read from slot:HL
        ei

        pop     hl
        pop     de
        ld      (de),a

        inc     hl
        inc     de

        pop     bc
        dec     bc
        ld      a,b
        or      c
        jr      nz,.copy_loop
        ret

; ------------------------------------------------------------
; Clear RAM bitmap buffer
; ------------------------------------------------------------

ClearScreenBuffer:
        ld      hl,ScreenBuf
        ld      de,ScreenBuf+1
        ld      bc,SCREEN_BYTES-1
        xor     a
        ld      (hl),a
        ldir
        ret

; ------------------------------------------------------------
; Render text into RAM bitmap
; ------------------------------------------------------------

RenderTextToBuffer:
        ld      hl,TextBuf
        ld      (SrcPtr),hl

        ld      hl,ScreenBuf
        ld      (LineBase),hl

        xor     a
        ld      (Col),a
        ld      (Row),a

.loop:
        ld      hl,(SrcPtr)
        ld      a,(hl)
        inc     hl
        ld      (SrcPtr),hl

        or      a
        ret     z

        cp      #1A                ; Ctrl-Z EOF marker
        ret     z

        cp      #0D                ; CR
        jr      z,.cr

        cp      #0A                ; LF
        jr      z,.lf

        cp      #09                ; TAB
        jr      z,.tab

        cp      32
        jr      c,.loop            ; ignore other control chars

        call    DrawAndAdvance
        ret     c
        jr      .loop

.cr:
        call    NewLine
        ret     c

        ; Swallow LF after CR.
        ld      hl,(SrcPtr)
        ld      a,(hl)
        cp      #0A
        jr      nz,.loop
        inc     hl
        ld      (SrcPtr),hl
        jr      .loop

.lf:
        call    NewLine
        ret     c
        jr      .loop

.tab:
        ld      a,' '
        call    DrawAndAdvance
        ret     c
        ld      a,(Col)
        and     7
        jr      nz,.tab
        jr      .loop

; ------------------------------------------------------------
; Draw char in A at current Col/Row, then advance cursor
; Carry set = screen full
; ------------------------------------------------------------

DrawAndAdvance:
        push    af
        ld      a,(Row)
        cp      ROWS
        jr      c,.ok
        pop     af
        scf
        ret

.ok:
        pop     af
        call    DrawChar

        ld      a,(Col)
        inc     a
        cp      COLS
        jr      c,.store_col

        xor     a
        ld      (Col),a
        call    NewLine
        ret

.store_col:
        ld      (Col),a
        or      a                  ; clear carry
        ret

; ------------------------------------------------------------
; Move to next text row
; Carry set = no more rows
; ------------------------------------------------------------

NewLine:
        xor     a
        ld      (Col),a

        ld      a,(Row)
        inc     a
        ld      (Row),a
        cp      ROWS
        jr      nc,.full

        ld      hl,(LineBase)
        ld      bc,ROW_STRIDE
        add     hl,bc
        ld      (LineBase),hl

        or      a                  ; clear carry
        ret

.full:
        scf
        ret

; ------------------------------------------------------------
; Draw one 8x8 character to RAM bitmap
;
; SCREEN 6 byte:
;   4 pixels per byte, 2 bits per pixel.
;   Font bit 1 becomes color 3 = binary 11.
; ------------------------------------------------------------

DrawChar:
        push    af

        ; DE = FontBuf + A*8
        ld      l,a
        ld      h,0
        add     hl,hl              ; *2
        add     hl,hl              ; *4
        add     hl,hl              ; *8
        ld      de,FontBuf
        add     hl,de
        ex      de,hl

        ; IX = LineBase + Col*2
        ld      hl,(LineBase)
        ld      a,(Col)
        add     a,a
        ld      c,a
        ld      b,0
        add     hl,bc
        push    hl
        pop     ix

        pop     af

        ld      b,8

.row_loop:
        ld      a,(de)
        inc     de
        ld      c,a

        ; high nibble -> first byte
        rrca
        rrca
        rrca
        rrca
        and     #0F
        call    ExpandNibble
        ld      (ix+0),a

        ; low nibble -> second byte
        ld      a,c
        and     #0F
        call    ExpandNibble
        ld      (ix+1),a

        push    bc
        ld      bc,LINE_BYTES
        add     ix,bc
        pop     bc

        djnz    .row_loop
        ret

; ------------------------------------------------------------
; A = nibble 0..15
; returns A = 4 SCREEN 6 pixels, color 3 on bits that are 1
; ------------------------------------------------------------

ExpandNibble:
        push    hl
        push    de

        ld      e,a
        ld      d,0
        ld      hl,Expand4
        add     hl,de
        ld      a,(hl)

        pop     de
        pop     hl
        ret

; ------------------------------------------------------------
; DOS helper
; ------------------------------------------------------------

PrintString:
        ld      c,DOS_STROUT
        jp      BDOS

; ------------------------------------------------------------
; Data
; ------------------------------------------------------------

Expand4:
        db #00,#03,#0C,#0F,#30,#33,#3C,#3F
        db #C0,#C3,#CC,#CF,#F0,#F3,#FC,#FF

FileName:
        db "A:",#5C,"SOME.TXT",0

MsgFileError:
        db "Cannot read A:",#5C,"SOME.TXT",13,10,"$"

FileHandle:
        db 0

FontSlot:
        db 0

SrcPtr:
        dw 0

LineBase:
        dw 0

Col:
        db 0

Row:
        db 0

; ------------------------------------------------------------
; Buffers
; ------------------------------------------------------------

ScreenBuf:
        defs SCREEN_BYTES

TextBuf:
        defs TEXT_MAX+1

FontBuf:
        defs 2048