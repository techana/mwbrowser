; serial_poc.asm -- Proof-of-concept UART ping-pong for the openMSX
; "Generic MSX RS-232C" cartridge. Assemble with asMSX; runs under
; MSX-DOS 1 as SERPOC.COM. Pairs with tools/plug_rs232.tcl (which
; bridges the cartridge UART to tcp://127.0.0.1:2323) and
; tools/serial_host.py (the listener on the other end).
;
; UART chip: Intel 8251 USART at base port 0x80 (see openMSX
; src/serial/MSXRS232.cc). The cartridge ROM has already configured
; the chip at boot; we just poll status and push/pull bytes.
;
;   port 0x80 : TxD (write) / RxD (read)
;   port 0x81 : command/mode (write) / status (read)
;               status bit 0 = TxRDY (transmitter ready)
;               status bit 1 = RxRDY (byte available)
;
; Behaviour:
;   1. Write a banner ("MSX serial POC\r\n") to the UART.
;   2. Loop forever:
;       - read a byte from the UART (blocking poll)
;       - echo it to the console (BDOS 2 CONOUT) so the user sees
;         what the host sent
;       - echo it back to the UART so the host can see the round-trip
;       - ESC on the local keyboard exits to DOS
;   Press Esc at the MSX keyboard to return to the command prompt.

UART_DAT    equ 0x80
UART_STA    equ 0x81
ST_TXRDY    equ 0x01
ST_RXRDY    equ 0x02

BDOS        equ 0x0005
BDOS_CONOUT equ 0x02                ; E = char
BDOS_DIRIO  equ 0x06                ; E = 0xFF: read kb (no-wait), else write E
BDOS_EXIT   equ 0x00

EOT_BYTE    equ 0x04                ; end-of-transmission marker; host sends
                                    ; this at the end of a payload, MSX
                                    ; prints a "[EOT: N bytes]" status line.

            DEVICE NOSLOT64K        ; SjASMPlus: full 64 KB address space
            ORG 0x0100              ; MSX-DOS 1 .COM

Start:
            ; Explicit 8251 init so the RxEN bit is set regardless of
            ; what the cartridge ROM did at boot. Three dummy writes
            ; flush any pending mode-byte expectation, then IR (internal
            ; reset), then mode (8-N-1 /16), then command (RxEN | TxEN
            ; | DTR | RTS | ErrRst).
            xor     a
            out     (UART_STA), a
            out     (UART_STA), a
            out     (UART_STA), a
            ld      a, 0x40
            out     (UART_STA), a       ; IR: internal reset
            ld      a, 0x4E
            out     (UART_STA), a       ; mode: 8 data, no parity, 1 stop, /16
            ld      a, 0x37
            out     (UART_STA), a       ; cmd: RTS | ErrRst | RxEN | DTR | TxEN

            ; Banner to the MSX screen so the user sees we're alive.
            ld      hl, MsgStart
            call    PrintZ

            ; Banner over the UART to the host.
            ld      hl, MsgUart
            call    UartSendZ

            ; Byte counter for the "[EOT: N bytes]" status line.
            xor     a
            ld      [RxCount], a
            ld      [RxCount + 1], a

Loop:
            ; Keyboard: Esc returns to DOS. DIRIO with E=0xFF is a
            ; non-blocking read; returns 0 if no key pressed.
            ld      c, BDOS_DIRIO
            ld      e, 0xFF
            call    BDOS
            cp      0x1B                ; Esc
            jr      z, Exit
            cp      0
            jr      z, .noKey
            ; Any other local key: forward it out over the UART too so
            ; the user can type to the host from the MSX keyboard.
            call    UartSendByte
.noKey:

            ; UART: poll for an incoming byte (non-blocking so the
            ; keyboard stays responsive).
            in      a, (UART_STA)
            and     ST_RXRDY
            jr      z, Loop
            in      a, (UART_DAT)

            ; EOT marker: print "[EOT: N bytes]\r\n" to the screen, do
            ; NOT echo back, reset the counter. Lets the host confirm
            ; each transmission landed intact.
            cp      EOT_BYTE
            jr      z, HandleEot

            ; Normal byte: show on screen, increment counter, echo back.
            ld      e, a
            push    af
            ld      c, BDOS_CONOUT
            call    BDOS
            pop     af

            push    af
            ld      hl, [RxCount]
            inc     hl
            ld      [RxCount], hl
            pop     af

            call    UartSendByte
            jr      Loop

HandleEot:
            ld      hl, MsgEotLead
            call    PrintZ
            ld      hl, [RxCount]
            call    PrintDecHL
            ld      hl, MsgEotTail
            call    PrintZ
            xor     a
            ld      [RxCount], a
            ld      [RxCount + 1], a
            jr      Loop

Exit:
            ld      hl, MsgExit
            call    PrintZ
            ld      c, BDOS_EXIT
            jp      BDOS

; UartSendByte: block until TxRDY, then write A to the UART. Preserves A.
UartSendByte:
            push    af
.wait:      in      a, (UART_STA)
            and     ST_TXRDY
            jr      z, .wait
            pop     af
            out     (UART_DAT), a
            ret

; PrintDecHL: print HL as a 1..5 digit decimal via BDOS CONOUT.
; Leading zeros are suppressed except for the ones digit, so 0 -> "0"
; but 42 -> "42" (not "00042"). Uses HasDigit as sticky state across
; the place-value loops; reset on entry.
PrintDecHL:
            xor     a
            ld      [HasDigit], a
            ld      de, 10000
            call    .pdDigit
            ld      de, 1000
            call    .pdDigit
            ld      de, 100
            call    .pdDigit
            ld      de, 10
            call    .pdDigit
            ; Ones digit always prints (so HL=0 emits "0").
            ld      a, l
            add     a, '0'
            push    hl
            ld      e, a
            ld      c, BDOS_CONOUT
            call    BDOS
            pop     hl
            ret
.pdDigit:
            ; Count how many times DE fits into HL; emit that many as
            ; an ASCII digit (or skip if leading zero and nothing
            ; non-zero has been emitted yet).
            ld      b, 0                 ; B = digit count (0..9)
.pdSub:
            push    bc
            push    de
            and     a
            sbc     hl, de
            pop     de
            pop     bc
            jr      c, .pdOver
            inc     b
            jr      .pdSub
.pdOver:    add     hl, de               ; undo the over-subtraction
            ld      a, b
            or      a
            jr      nz, .pdEmit
            ld      a, [HasDigit]
            or      a
            ret     z                    ; leading-zero suppression
            xor     a
            jr      .pdEmitA
.pdEmit:
            ld      a, 1
            ld      [HasDigit], a
            ld      a, b
.pdEmitA:
            add     a, '0'
            push    hl
            ld      e, a
            ld      c, BDOS_CONOUT
            call    BDOS
            pop     hl
            ret

HasDigit:   db 0
RxCount:    dw 0                         ; bytes received since last EOT

; UartSendZ: HL -> NUL-terminated string; writes each char through the UART.
UartSendZ:
            ld      a, [hl]
            or      a
            ret     z
            push    hl
            call    UartSendByte
            pop     hl
            inc     hl
            jr      UartSendZ

; PrintZ: HL -> NUL-terminated string; BDOS CONOUT every char.
PrintZ:
            ld      a, [hl]
            or      a
            ret     z
            push    hl
            ld      e, a
            ld      c, BDOS_CONOUT
            call    BDOS
            pop     hl
            inc     hl
            jr      PrintZ

MsgStart:   db "Serial POC ready. Type to send; Esc to quit.", 0x0D, 0x0A, 0
MsgUart:    db "MSX serial POC", 0x0D, 0x0A, 0
MsgExit:    db 0x0D, 0x0A, "bye.", 0x0D, 0x0A, 0
; Framing for the EOT-arrived status line.
MsgEotLead: db 0x0D, 0x0A, "[EOT: ", 0
MsgEotTail: db " bytes]", 0x0D, 0x0A, 0

            SAVEBIN "dist/serpoc.com", 0x0100, $-0x0100
