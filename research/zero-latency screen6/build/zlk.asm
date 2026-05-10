; ==============================================================================
; MSX2 ZERO-LATENCY TEXT MATERIALIZATION KERNEL
; Operating Environment: MSX-DOS 1 (.COM Executable)
; Display Target: V9938 Graphic 5 (Screen 6), 512x192, 4 Colors, 2bpp
; ==============================================================================

            ORG  0100H          ; Base execution address for Transient Program Area

            ; ------------------------------------------------------------------
            ; System Constants and BDOS Vectors
            ; ------------------------------------------------------------------
BDOS        EQU  0005H          ; Universal BDOS entry point
FOPEN       EQU  000FH          ; Open File via File Control Block
SETDTA      EQU  001AH          ; Define Disk Transfer Address
RDBLK       EQU  0027H          ; Random Block Read function
RDSLT       EQU  000CH          ; BIOS Inter-slot Read
EXPTBL      EQU  0FCC1H         ; Main ROM slot identification variable
CGTABL      EQU  0004H          ; Character Font Base pointer
VDP_PORT0   EQU  0098H          ; VRAM Data payload port
VDP_PORT1   EQU  0099H          ; VDP Register and Address port

            ; ------------------------------------------------------------------
            ; Topographical Memory Map Assignments (Page-Aligned)
            ; ------------------------------------------------------------------
LUT_HI      EQU  08000H         ; Left-half pixel lookup table base
LUT_LO      EQU  08100H         ; Right-half pixel lookup table base
FONT_TMP    EQU  08200H         ; Temporary linear font buffer (2048 bytes)
FONT_TRN    EQU  08A00H         ; Orthogonal transposed matrix (2048 bytes)
TEXT_BUF    EQU  09200H         ; Raw physical disk buffer (1536 bytes)
DISP_GRID   EQU  09800H         ; Spatial mapped text grid (1536 bytes)

            ; ==================================================================
            ; EXECUTION PHASE 1: MSX-DOS RANDOM BLOCK TRANSFER
            ; ==================================================================
Main:
            ; Phase 1 originally read SOME.TXT into TEXT_BUF via FCB
            ; random block read. To keep the experiment self-contained
            ; we use the embedded SampleText blob; the rendering
            ; pipeline being measured is identical.
            LD   HL, SampleText
            LD   DE, TEXT_BUF
            LD   BC, SampleTextEnd - SampleText
            LDIR
            ; Mark the rest of TEXT_BUF with EOF (1Ah) so the parser
            ; stops cleanly at the end of the embedded text.
            LD   HL, TEXT_BUF
            LD   B, 0
            ADD  HL, BC          ; HL = TEXT_BUF + textlen
            LD   (HL), 1AH

            ; ==================================================================
            ; EXECUTION PHASE 2: SPATIAL GRID RESOLUTION
            ; ==================================================================
            ; Initialize the spatial surrogate grid with ASCII spaces
            LD   HL, DISP_GRID
            LD   DE, DISP_GRID + 1
            LD   BC, 1535
            LD   (HL), 20H
            LDIR

            ; Parse TEXT_BUF to resolve physical control characters
            LD   HL, TEXT_BUF
            LD   DE, DISP_GRID
            LD   BC, 1536
ParseLoop:
            LD   A, (HL)
            INC  HL
            CP   1AH            ; Detect End of File marker (Ctrl-Z)
            JR   Z, ParseEnd
            CP   0DH            ; Bypass Carriage Return explicitly
            JR   Z, EvaluateNext
            CP   0AH            ; Detect Line Feed
            JR   Z, AdvanceRow
            ; Map standard printable ASCII character
            LD   (DE), A
            INC  DE
EvaluateNext:
            DEC  BC
            LD   A, B
            OR   C
            JR   NZ, ParseLoop
            JR   ParseEnd

AdvanceRow:
            ; Snap destination pointer forward to the next 64-byte row boundary
            LD   A, E
            AND  0C0H
            ADD  A, 64
            LD   E, A
            JR   NC, EvaluateNext
            INC  D
            JR   EvaluateNext
ParseEnd:

            ; ==================================================================
            ; EXECUTION PHASE 3: INTER-SLOT FONT EXTRACTION AND TRANSPOSITION
            ; ==================================================================
            ; Acquire Main BIOS ROM Slot Identifier
            LD   A, (EXPTBL)
            LD   C, A

            ; Acquire absolute pointer to Character Font Base
            LD   HL, (CGTABL)

            ; Transfer 2,048 bytes of 1-bit font data into local TPA
            LD   DE, FONT_TMP
            LD   B, 8
CopyLoopOut:
            PUSH BC
            LD   B, 0
CopyLoopIn:
            PUSH BC
            PUSH DE
            PUSH HL
            LD   A, C
            CALL RDSLT
            POP  HL
            POP  DE
            LD   (DE), A
            INC  HL
            INC  DE
            POP  BC
            DJNZ CopyLoopIn
            POP  BC
            DJNZ CopyLoopOut

            ; Execute Orthogonal Matrix Transposition to enable row-major read
            LD   HL, FONT_TMP
            LD   B, 0
TransposeOut:
            LD   C, 0
TransposeIn:
            LD   A, (HL)
            INC  HL

            ; Calculate transposition coordinates
            LD   D, HIGH(FONT_TRN)
            LD   E, B
            PUSH HL
            LD   H, 0
            LD   L, C
            ADD  HL, HL
            ADD  HL, HL
            ADD  HL, HL
            ADD  HL, HL
            ADD  HL, HL
            ADD  HL, HL
            ADD  HL, HL
            ADD  HL, HL
            LD   A, D
            ADD  A, H
            LD   D, A
            POP  HL

            ; Restore overwritten byte from sequential stream
            DEC  HL
            LD   A, (HL)
            INC  HL
            LD   (DE), A

            INC  C
            LD   A, C
            CP   8
            JR   NZ, TransposeIn
            DJNZ TransposeOut

            ; ==================================================================
            ; EXECUTION PHASE 4: BIFURCATED LOOKUP TABLE GENERATION
            ; ==================================================================
            LD   HL, LUT_HI
            LD   DE, LUT_LO
            LD   B, 0
LUTLoop:
            LD   C, B
            LD   H, 0
            LD   L, 0

            ; Geometrically expand Bits 7-4 into LUT_HI array (H register)
            BIT  7, C
            JR   Z, $+4
            SET  7, H
            SET  6, H
            BIT  6, C
            JR   Z, $+4
            SET  5, H
            SET  4, H
            BIT  5, C
            JR   Z, $+4
            SET  3, H
            SET  2, H
            BIT  4, C
            JR   Z, $+4
            SET  1, H
            SET  0, H

            ; Geometrically expand Bits 3-0 into LUT_LO array (L register)
            BIT  3, C
            JR   Z, $+4
            SET  7, L
            SET  6, L
            BIT  2, C
            JR   Z, $+4
            SET  5, L
            SET  4, L
            BIT  1, C
            JR   Z, $+4
            SET  3, L
            SET  2, L
            BIT  0, C
            JR   Z, $+4
            SET  1, L
            SET  0, L

            ; Propagate expanded values to page-aligned arrays.
            ; Original used `LD A,(SP+1/0)` which is not a real Z80
            ; instruction; stash the expanded HI/LO bytes through D/E
            ; instead.
            LD   D, H               ; D = expanded HI byte
            LD   E, L               ; E = expanded LO byte
            LD   H, HIGH(LUT_HI)
            LD   L, B
            LD   (HL), D
            LD   H, HIGH(LUT_LO)
            LD   (HL), E

            DJNZ LUTLoop

            ; ==================================================================
            ; EXECUTION PHASE 5: VDP BUS SATURATION SETUP
            ; ==================================================================
            DI                  ; Disable external interrupts to secure bus timing

            ; Mode Register 0: Initialize Graphic 5 (M5=1)
            LD   A, 0AH
            OUT  (VDP_PORT1), A
            LD   A, 80H
            OUT  (VDP_PORT1), A

            ; Mode Register 1: Blank Display to liberate VRAM slots
            LD   A, 00H
            OUT  (VDP_PORT1), A
            LD   A, 81H
            OUT  (VDP_PORT1), A

            ; Base Address Register 2: Align Name Table to Page 0
            LD   A, 1FH
            OUT  (VDP_PORT1), A
            LD   A, 82H
            OUT  (VDP_PORT1), A

            ; Mode Register 2: Maximize bandwidth, deactivate sprites
            LD   A, 0AH
            OUT  (VDP_PORT1), A
            LD   A, 88H
            OUT  (VDP_PORT1), A

            ; Mode Register 3: Lock vertical dimension to 192 lines
            LD   A, 00H
            OUT  (VDP_PORT1), A
            LD   A, 89H
            OUT  (VDP_PORT1), A

            ; ==================================================================
            ; EXECUTION PHASE 6: PIPELINE-OPTIMIZED VRAM STREAMING
            ; ==================================================================
            ; Configure Alternate Registers for pure port multiplexing
            EXX
            LD   H, HIGH(LUT_HI)
            LD   C, VDP_PORT0
            EXX

            LD   IX, DISP_GRID  ; Base pointer anchoring the spatial grid
            LD   IY, 00000H     ; Initialized 17-bit physical VRAM address

            LD   A, 24          ; Lock outer loop to 24 character rows
RenderRow:
            PUSH AF
            LD   C, 0           ; Initialize internal scanline counter (0-7)
RenderScanline:
            ; Prime VDP Internal Address Sequencer for streaming
            ; Assert A16-A14 explicitly to zero (Page 0\)
            XOR  A
            OUT  (VDP_PORT1), A
            LD   A, 8EH
            OUT  (VDP_PORT1), A

            ; Inject A7-A0 and A13-A8 while asserting Write Access Flag
            PUSH IY
            POP  HL
            LD   A, L
            OUT  (VDP_PORT1), A
            LD   A, H
            OR   40H
            OUT  (VDP_PORT1), A

            ; Configure Primary Registers for character traversal
            PUSH IX
            POP  HL
            LD   D, HIGH(FONT_TRN)
            LD   A, D
            ADD  A, C
            LD   D, A           ; Dynamic pointer mapping to matrix scanline

            LD   A, C
            LD   B, 64          ; Establish horizontal termination boundary

RenderChars:
            ; Inner micro-loop optimized to 99 T-States
            LD   E, (HL)
            INC  HL
            EX   AF, AF'
            LD   A, (DE)

            EXX
            LD   L, A

            LD   A, (HL)
            OUT  (C), A
            INC  H
            LD   A, (HL)
            OUT  (C), A
            DEC  H
            EXX

            EX   AF, AF'
            DJNZ RenderChars

            ; Step address sequencer to next physical scanline (128 bytes)
            LD   BC, 128
            ADD  IY, BC

            LD   C, A
            INC  C
            LD   A, C
            CP   8
            JR   NZ, RenderScanline

            ; Step spatial grid pointer to next physical row (64 bytes)
            LD   BC, 64
            ADD  IX, BC

            POP  AF
            DEC  A
            JR   NZ, RenderRow

            ; ==================================================================
            ; EXECUTION PHASE 7: VISUAL MANIFESTATION
            ; ==================================================================
            ; Re-assert Mode Register 1 to restore CRT rendering engine
            LD   A, 40H
            OUT  (VDP_PORT1), A
            LD   A, 81H
            OUT  (VDP_PORT1), A

            EI                  ; Lift external interrupt suppression

InfiniteHalt:
            JR   InfiniteHalt   ; Maintain visual state permanently

Terminate:
            RET

            ; ------------------------------------------------------------------
            ; Static Structural Definitions
            ; ------------------------------------------------------------------
FCB:
            DB   01H            ; Hardcoded Drive A: target
            DB   "SOME    TXT"  ; Padded identifier string
            DS   25, 0          ; Remaining fields initialized to absolute zero

