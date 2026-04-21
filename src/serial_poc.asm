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

            .MSXDOS                     ; asMSX: produce .COM output
            .bios                       ;   (matches src/mwbrowser.asm's header)
            org 0x0100

Start:
            ; Banner to the MSX screen so the user sees we're alive.
            ld      hl, MsgStart
            call    PrintZ

            ; Banner over the UART to the host.
            ld      hl, MsgUart
            call    UartSendZ

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
            in      a, [UART_STA]
            and     ST_RXRDY
            jr      z, Loop
            in      a, [UART_DAT]

            ; Show the byte on the MSX screen.
            ld      e, a
            push    af
            ld      c, BDOS_CONOUT
            call    BDOS
            pop     af

            ; Echo it back to the host so we can see the round trip.
            call    UartSendByte
            jr      Loop

Exit:
            ld      hl, MsgExit
            call    PrintZ
            ld      c, BDOS_EXIT
            jp      BDOS

; UartSendByte: block until TxRDY, then write A to the UART. Preserves A.
UartSendByte:
            push    af
.wait:      in      a, [UART_STA]
            and     ST_TXRDY
            jr      z, .wait
            pop     af
            out     [UART_DAT], a
            ret

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
