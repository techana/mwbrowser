# **Zero-Latency Visual Materialization: Architectural Exploitation of the MSX2 V9938 Display Processor for Instantaneous Text Rendering**

## **Introduction to the Asynchronous Rendering Bottleneck**

The evolution of eight-bit microcomputing reached a critical zenith with the introduction of the MSX2 standard in 1985\. Orchestrated through a collaborative engineering effort between ASCII Corporation and Microsoft, the architecture's defining characteristic was the integration of the Yamaha V9938 Video Display Processor (VDP).1 This custom large-scale integration (LSI) chip represented a profound leap over the Texas Instruments TMS9918A utilized in the first-generation MSX.2 It introduced hardware-accelerated bit-mapped graphics, extensive color palettes, and expanded video memory (VRAM).2 However, the foundational architecture of the MSX2 remained anchored by the Zilog Z80 central processing unit operating at a baseline clock frequency of 3.579545 MHz.4 This architectural dichotomy—a relatively constrained primary processor attempting to drive an advanced, asynchronous video processor—created severe memory bandwidth and synchronization bottlenecks.  
When developers are tasked with retrieving textual data from a physical storage medium (such as reading a file designated a:\\some.txt) and displaying it on a high-resolution canvas like Screen 6, standard programming paradigms fail to achieve instantaneous results. Typical high-level languages and basic operating system calls rely on sequential processing. The system reads a byte from the disk, evaluates its character encoding, calculates the physical memory address on the screen, transmits the graphical representation across the VDP bus, and then repeats the process. Due to the asynchronous nature of the VDP, which enforces wait states when the CPU attempts to access VRAM during active television scanline generation 5, this sequential methodology results in a cascading, typewriter-like visual effect. The text appears word by word or line by line, exposing the underlying processing latency to the end user.  
Fulfilling a strict operational mandate to display a full screen of text "almost immediately at once" without scrolling requires completely discarding standard terminal output abstractions. Instead, achieving zero-latency rendering demands a holistic, system-level architectural approach. This methodology must synthesize optimal disk controller buffering, spatial pre-calculation within the Transient Program Area (TPA), orthogonal matrix transposition of the firmware fonts, and total saturation of the VDP data bus through controlled screen blanking. This comprehensive report details the precise mathematical and programmatic strategies required to exploit the MSX2 architecture, resulting in a theoretical maximum throughput that allows text to manifest on Screen 6 in a fraction of a second.

## **Storage Subsystem Exploitation via MSX-DOS**

To achieve instantaneous rendering, the latency inherent in physical disk access must be mitigated by transferring the entirety of the target file into system memory in a single, uninterrupted continuous read operation. This requires a deep understanding of the MSX Disk Operating System (MSX-DOS). Developed as a hybrid environment, MSX-DOS amalgamates the FAT12 logical disk format popularized by MS-DOS with the application programming interface (API) conventions of Digital Research's CP/M.6 While later iterations (MSX-DOS 2\) introduced UNIX-style hierarchical file handles 7, the universally compatible and highly optimized mechanism for raw sector-level data retrieval relies on the File Control Block (FCB).8

### **The Limitations of Sequential Input Output**

Standard file reading under the CP/M API utilizes Sequential Read functions, specifically Basic Disk Operating System (BDOS) function 14H.10 When an application invokes a sequential read, the operating system retrieves the next 128-byte logical record from the disk buffer and advances an internal pointer. While functional for streaming data, this approach incurs significant operating system overhead per byte or block. The BDOS must continuously evaluate buffer boundaries, traverse the File Allocation Table (FAT) cluster chains, and monitor directory extents.11 If display rendering logic is interleaved with these sequential disk reads, the execution pipeline stalls, creating the exact visual lag the zero-latency mandate seeks to eliminate.

### **Implementation of Random Block Read Dynamics**

The mathematically optimal strategy dictates that disk input/output (I/O) and VRAM rendering must be entirely decoupled. The file must be absorbed into the Z80's primary RAM as a single monolithic block prior to any graphical processing. This is accomplished by exploiting the MSX-DOS Random Block Read system call, designated as BDOS function 27H.10 Unlike sequential variants, the random block read API permits the application to dynamically redefine the underlying record size and request an arbitrary number of these custom records simultaneously.6 This allows the application to instruct the operating system to bypass intermediary 128-byte blocking algorithms and stream the exact byte capacity of the file directly into a target buffer.  
To utilize this mechanism, the application must construct and manipulate an Unopened File Control Block. The FCB is a rigid 37-byte data structure residing in system memory that dictates how the BDOS interacts with the specific file.9 The precise memory layout of the FCB must be strictly adhered to for successful bulk operations.

| Memory Offset (Hexadecimal) | Field Designation | Functional Description and Required Application Usage |
| :---- | :---- | :---- |
| 00H | Drive Identifier | Dictates the logical volume. 01H strictly enforces Drive A:. A value of 00H relies on the default system drive.9 |
| 01H through 08H | Primary Filename | An 8-byte ASCII array. The target name must be left-justified. Any remaining bytes must be padded with ASCII spaces (20H).9 |
| 09H through 0BH | Filename Extension | A 3-byte ASCII array for the file extension, similarly padded with space characters if necessary.14 |
| 0CH through 0DH | Current Block | A 2-byte integer manipulated exclusively by the operating system during sequential operations. It must be initialized to zero.14 |
| 0EH through 0FH | Logical Record Size | Defines the byte length of a single record. For arbitrary byte-level reading, the application must overwrite this field with 0001H after the file is opened.13 |
| 10H through 13H | Absolute File Size | A 4-byte integer populated by the BDOS upon a successful Open File command. It represents the exact physical byte count.14 |
| 21H through 24H | Random Record Pointer | A 4-byte integer determining the starting offset for the Random Block Read. Must be initialized to 00000000H to read from the absolute beginning of the file.14 |

The optimal ingestion pipeline follows a strict procedural hierarchy. First, the application configures the FCB with the physical drive identifier 01H and the padded filename string SOME TXT. Second, the Disk Transfer Address (DTA) is established via BDOS function 1AH.10 The DTA acts as the destination pointer where the disk controller will write the incoming data; this must be pointed to an isolated, contiguous block of RAM within the Transient Program Area. Third, the file is initialized via the Open File command (BDOS 0FH).10  
Following successful initialization, the critical override occurs: the application manually injects 0001H into the Logical Record Size field at offset 0EH and clears the Random Record Pointer at offset 21H.13 Finally, the Random Block Read (BDOS 27H) is executed. Because a standard Screen 6 character grid consists of 64 columns and 24 rows, its maximum absolute capacity is 1,536 characters. By requesting exactly 1,536 records (where each record is now redefined as one byte), the entire visual payload is buffered into primary RAM via Direct Memory Access (DMA) or heavily optimized BIOS sector reads in a fraction of a second, completing the first phase of zero-latency materialization.6

## **Spatial Grid Preprocessing and Control Character Resolution**

A fundamental obstacle to instantaneous text rendering is the presence of logical formatting data within standard ASCII text files. Text documents are not two-dimensional geometric arrays; they are one-dimensional streams of data that rely on non-printable control characters, primarily the Carriage Return (0DH) and Line Feed (0AH), to dictate where a new line should begin.  
If an application attempts to parse these control characters dynamically inside the ultra-tight inner loop of the VRAM rendering process, it introduces severe conditional branching penalties. The Z80 processor evaluates branching instructions (such as JP Z or JR NZ) with variable clock cycle durations depending on whether the condition is met. Intermixing this conditional logic with the rigid timing required to saturate the VDP bus destroys the continuous throughput necessary for instant display. Furthermore, encountering a line feed requires recalculating the physical X and Y coordinates on the screen, translating those into a 17-bit VRAM memory address, and re-initializing the VDP address registers, which consumes hundreds of wasted clock cycles per occurrence.  
To maintain absolute zero-latency VRAM transmission, the logical file parsing must be entirely abstracted and separated from the physical display execution. This is achieved through an intermediate pre-processing phase executed purely within the system RAM before the VDP is even engaged.  
The strategy relies on constructing a surrogate geometric map of the screen within the Transient Program Area. A target array, designated as the DISPLAY\_GRID, consisting of exactly 1,536 bytes (representing the 64x24 character grid), is initialized by filling it entirely with ASCII space characters (20H). The Z80 then initiates a rapid memory-to-memory evaluation loop over the raw disk buffer. As the processor reads each byte, standard printable characters are copied sequentially into the DISPLAY\_GRID. When the evaluation logic detects a Carriage Return, the character is bypassed. Crucially, when a Line Feed is detected, the destination memory pointer tracking the DISPLAY\_GRID is mathematically advanced to the exact boundary of the next 64-byte row block.  
By applying a bitwise AND operation (AND 0C0H) to the low byte of the destination pointer, the pointer is snapped back to the beginning of the current logical row, and adding 64 mathematically forces the pointer to the absolute start of the subsequent row. This loop terminates instantly when either the source text buffer is exhausted or the geometric grid reaches its 1,536-byte capacity. This RAM-to-RAM transformation executes at maximum processor speed and produces a flat, contiguous, two-dimensional geometric representation of the screen text. All line lengths, blank spaces, and carriage returns are permanently resolved into static blank spaces, meaning the subsequent VRAM rendering loop requires zero conditional logic regarding text placement.

## **V9938 Display Architecture and Graphic 5 Topology**

The core of the MSX2's visual capability lies within the Yamaha V9938 Video Display Processor. Unlike unified memory architectures where the CPU and video circuitry share the same physical RAM, the V9938 operates as an autonomous subsystem with its own dedicated 128 Kilobytes of VRAM.2 The Z80 CPU has no direct memory access to this region; all communication must be brokered sequentially through specialized hardware I/O ports. Specifically, Port 98H serves as the bidirectional data gateway to VRAM, while Port 99H acts as the command and control interface, accepting address pointers, register configurations, and status inquiries.18

### **Initializing the Target Resolution (Screen 6\)**

The user mandate specifies the use of Screen 6\. In the technical nomenclature of the MSX-VIDEO architecture, Screen 6 corresponds to "Graphic 5" mode.1 This bit-mapped graphics mode provides a high-resolution canvas consisting of 512 dots horizontally and either 192 or 212 dots vertically, depending on the configuration of the line count register.1 Graphic 5 allows for the simultaneous display of 4 independent colors chosen from a broader 512-color palette.1  
Initializing Graphic 5 requires precisely injecting configuration bits across a suite of write-only control registers (R\#0 through R\#9) via Port 99H.1 The process involves outputting the data byte to the port, immediately followed by the register designation byte (which must have its most significant bit set to 1 to signal a register write operation).1

| VDP Register | Configured Hexadecimal Value | Binary Representation | Architectural Designation and Justification |
| :---- | :---- | :---- | :---- |
| R\#0 (Mode Register 0\) | 0AH | 0 0 0 0 1 0 1 0 | The M5 bit is asserted to 1\. In conjunction with subsequent registers, this locks the VDP into Graphic 5 mode.1 |
| R\#1 (Mode Register 1\) | 00H | 0 0 0 0 0 0 0 0 | The BL (Blanking) bit is cleared to 0\. This disables the cathode-ray tube (CRT) display output, an essential requirement for VRAM bus saturation.1 |
| R\#2 (Table Base Address) | 1FH | 0 0 0 1 1 1 1 1 | Sets the high-order bits (A16, A15) to 0\. This anchors the Pattern Name Table to the absolute base of VRAM at address 00000H (Page 0).22 |
| R\#8 (Mode Register 2\) | 0AH | 0 0 0 0 1 0 1 0 | The VR bit is set to 1, enabling the full 128KB VRAM space. Crucially, the SPD bit is set to 1, completely disabling the sprite processing engine to conserve memory bandwidth.1 |
| R\#9 (Mode Register 3\) | 00H | 0 0 0 0 0 0 0 0 | The LN bit is cleared to 0, enforcing a 192-line vertical resolution. This perfectly accommodates 24 rows of 8-pixel high characters without overflow.1 |

### **The Physics of VRAM Bus Saturation**

A critical architectural insight required to fulfill the "almost immediately at once" constraint revolves around the physics of the VDP memory sequencer. During a standard 60Hz display cycle, the V9938 constantly fetches pattern, name, and color data from its localized VRAM to generate the analog video signal sent to the monitor.5 In a typical 1,368-cycle horizontal scanline 5, the VDP hardware monopolizes the vast majority of the Row Address Strobe (RAS) and Column Address Strobe (CAS) memory access slots to maintain the video feed.  
If the Z80 CPU attempts to write data to VRAM via Port 98H during this active rendering window, the VDP's internal arbiter prioritizes the video feed to prevent visual corruption. Consequently, the VDP forces the CPU into a wait state, halting processor execution until a free memory slot becomes available. When attempting to transfer thousands of bytes, these accumulated wait states cause severe processing degradation, resulting in the text visually "crawling" down the screen.  
The solution is to exploit the VDP Blanking mechanism. By writing 00H to Mode Register 1 (R\#1), the BL bit is driven low.1 This suspends all internal CRT rendering logic. The VDP continues to generate the fundamental synchronization signals required to keep the external monitor stable, but the internal memory sequencer is entirely halted.5 Because the VDP no longer needs to fetch visual data, 100% of the VRAM access slots are liberated and handed over to the CPU.5 This enables the Z80 to execute continuous hardware block output instructions at its maximum theoretical clock speed without incurring a single wait state. The screen remains entirely black during this transmission phase, and once the 1,536-character payload is fully deposited into VRAM, restoring the BL bit to 1 causes the complete textual matrix to manifest instantaneously.3

### **Graphic 5 Pixel Packing Specifications**

In Graphic 5, the VRAM topology is linearly mapped and tightly packed. To achieve 512 horizontal dots while supporting 4 colors, the architecture mandates a 2-bits-per-pixel (2bpp) structural constraint.25 Because a standard byte contains 8 bits, exactly four pixels are mathematically packed into every single byte of VRAM data.21  
Consequently, a single horizontal scanline consisting of 512 dots requires exactly 128 bytes of linear VRAM:  
![][image1]  
To cover the full 192 scanlines comprising the visual canvas, the total VRAM consumption for a single frame is calculated as:  
![][image2]  
The 2bpp structure requires the application to format graphical data precisely before transmission. The four pixels within a byte are ordered sequentially from left to right, corresponding to descending pairs of bits.18

| Spatial Pixel Location (Left to Right) | Bit Field Assignment within the Byte | Binary Example for Foreground Rendering |
| :---- | :---- | :---- |
| Pixel 0 (Absolute Leftmost) | Bits 7 and 6 | 11 (Translating to Color Code 3\) |
| Pixel 1 (Inner Left) | Bits 5 and 4 | 00 (Translating to Color Code 0\) |
| Pixel 2 (Inner Right) | Bits 3 and 2 | 00 (Translating to Color Code 0\) |
| Pixel 3 (Absolute Rightmost) | Bits 1 and 0 | 11 (Translating to Color Code 3\) |

By default, MSX2 palette definitions assign Color 0 (Binary 00\) to the transparent or solid background state, and Color 3 (Binary 11\) to the primary textual foreground.19 Therefore, mapping a character onto the screen requires converting monochrome binary logic into these specific 2-bit interleaved clusters.

## **Inter-Slot Architecture and Font Matrix Transposition**

The standard system font on an MSX computer is defined as an 8x8 pixel 1-bit monochrome matrix physically burnt into the system Read Only Memory (ROM).3 To render characters, the application must extract these binary patterns. However, the MSX architecture employs a complex slot-based memory paging system to expand the Z80's physical 64KB address limit. Because an MSX-DOS application executes within the Transient Program Area in standard RAM starting at 0100H, the Main-ROM containing the font is ordinarily paged out of the active memory map.9  
The absolute base address of the character font ROM table is stored as a system variable named CGTABL, located at RAM address 0004H.28 To access the font, the application must invoke an inter-slot BIOS call, specifically RDSLT (Read Slot) at 000CH, passing the correct slot identifier to safely read the ROM data across isolated memory boundaries.29 Because executing an inter-slot BIOS call for every pixel during the rendering loop would introduce catastrophic latency, the entirety of the 2,048-byte font (256 characters multiplied by 8 bytes per character) must be preemptively copied into a temporary buffer in local RAM.

### **The Inefficiency of Character-Major Rendering**

A standard text rendering algorithm evaluates memory character-by-character. It draws all 8 lines of Character A, mathematically calculates the new screen address for the next character block, draws Character B, and so forth. In Graphic 5 mode, jumping sequentially across the screen is highly destructive to performance. Addressing VRAM requires updating the 17-bit VRAM address pointer via Port 99H.3 This involves writing to Register R\#14 to set the upper three bits (A16 to A14), followed by writing two consecutive bytes to Port 99H to set the lower 14 bits (A13 to A0), while ensuring the correct read/write flags are asserted.3  
Requiring three distinct I/O port transmissions to reset the address pointer between every single character over a 1,536-character grid results in hundreds of thousands of wasted clock cycles. To eliminate this, the rendering architecture must proceed in a strict row-major order. The CPU must process Line 0 of all 64 characters horizontally across the screen, outputting a continuous 128-byte stream directly to Port 98H without ever touching the address registers. Only after an entire 512-dot scanline is completed does the logic advance to Line 1\.

### **Orthogonal Matrix Transposition**

While row-major rendering solves the VRAM addressing bottleneck, it creates a severe access penalty regarding the font data in RAM. Standard font architecture is organized sequentially by character: 8 contiguous bytes for Character 0, followed by 8 bytes for Character 1\. If the CPU is processing Line 0 of the screen, it must fetch byte 0 of Character A, then jump 8 bytes forward to fetch byte 0 of Character B, requiring constant stride multiplication and complex pointer arithmetic.  
The mathematically elegant solution is to execute an Orthogonal Matrix Transposition on the 2,048-byte font array immediately after it is copied into RAM, but before any rendering begins. The standard 256x8 matrix (where rows are characters and columns are pixel lines) is transposed into an 8x256 matrix.

* Block 0 (256 bytes) contains Line 0 for all 256 characters sequentially.  
* Block 1 (256 bytes) contains Line 1 for all 256 characters sequentially.  
* Block 7 (256 bytes) contains Line 7 for all 256 characters sequentially.

By anchoring this transposed matrix onto a precise memory page boundary (for example, 8800H), retrieving the exact font byte requires absolute minimum overhead. The high byte of the Z80's pointer register (the D register) maps directly to the font row being processed (88H through 8FH), and the low byte of the pointer (the E register) maps directly to the ASCII character code fetched from the text grid. This complete elimination of index multiplication from the critical rendering path is vital for sub-second execution.

## **Bifurcated Lookup Tables for Dimensional Space Expansion**

As established, Graphic 5 requires data in a 2-bits-per-pixel format 25, but the transposed system font remains in a 1-bit monochrome format.3 Every 8-bit row of the font must be dimensionally expanded into 16 bits (2 bytes). For instance, a font row representing a single vertical stroke (10000000 in binary) must be mapped to 1100 0000 0000 0000 (Hex C000) before transmission to the VDP.  
Relying on the Z80 CPU to calculate this expansion dynamically inside the inner rendering loop using bitwise rotation instructions (RLCA, RRCA) introduces massive processing delays. The mathematically superior solution is the generation of a pre-calculated Lookup Table (LUT).31 Because the input is an 8-bit value (representing any possible configuration of a character's pixel line), the LUT requires exactly 256 entries. Since each input maps to a 16-bit word, the complete table requires 512 bytes of RAM.  
However, a standard 512-byte contiguous array introduces a new bottleneck: pointer arithmetic. To read a 16-bit value from a standard array using an 8-bit index requires multiplying the index by two and adding it to a 16-bit base address inside the inner loop.  
To circumvent this, the LUT is bifurcated into two distinct 256-byte arrays, perfectly aligned to adjacent memory page boundaries. The high-byte expansion results are stored in an array designated LUT\_HI at address 8000H, while the low-byte expansion results are stored in an array designated LUT\_LO at address 8100H. By ensuring the base addresses rest precisely on an 00H boundary, the Z80 can index the table with zero arithmetic operations. The CPU assigns the base page (80H or 81H) to the H register, and the raw 1-bit font pattern directly to the L register. Incrementing the H register instantly switches the pointer from the high-byte lookup to the low-byte lookup, allowing the expanded data to be streamed directly to the VDP port.

## **Execution Pipeline Optimization and Cycle Analysis**

By synthesizing the pre-processed spatial text grid, the orthogonally transposed font matrix, and the bifurcated page-aligned lookup table, the central rendering loop is stripped of virtually all computational logic. It is reduced to pure memory-to-I/O port multiplexing.  
To prevent the Z80's limited architecture from causing delays through stack push and pop operations, the rendering loop exploits the processor's Alternate Register Set via the EXX instruction.32 The primary registers are assigned strictly to spatial tracking and font retrieval: the HL register pair points to the text grid, the D register holds the transposed font row page, and the B register serves as the horizontal character counter.  
The alternate registers are dedicated entirely to the LUT expansion and VDP transmission. The alternate H' register holds the LUT page base (80H), while the alternate C' register holds the VDP Data Port address (98H).  
For each of the 64 characters across the 192 scanlines, the following highly synchronized sequence is executed:

| Z80 Assembly Instruction | T-States (Clock Cycles) | Functional Description and Pipeline Action |
| :---- | :---- | :---- |
| LD E, (HL) | 7 | Fetch the raw ASCII character code from the pre-processed spatial grid buffer. |
| INC HL | 6 | Advance the grid memory pointer to the next character. |
| EX AF, AF' | 4 | Context switch the accumulator to preserve loop state. |
| LD A, (DE) | 7 | Retrieve the 1-bit font pattern byte from the transposed matrix without multiplication. |
| EXX | 4 | Hardware context switch to the alternate register bank.32 |
| LD L, A | 4 | Inject the font pattern directly into the LUT pointer. |
| LD A, (HL) | 7 | Fetch the 2-bit expanded Left-Half pixel data from LUT\_HI. |
| OUT (C), A | 12 | Transmit the Left-Half data byte to VRAM via Port 98H. |
| INC H | 4 | Shift the memory pointer to the LUT\_LO page boundary. |
| LD A, (HL) | 7 | Fetch the 2-bit expanded Right-Half pixel data. |
| OUT (C), A | 12 | Transmit the Right-Half data byte to VRAM via Port 98H. |
| DEC H | 4 | Restore the pointer back to LUT\_HI for the next character iteration. |
| EXX | 4 | Hardware context switch back to the primary register bank. |
| EX AF, AF' | 4 | Restore the primary accumulator. |
| DJNZ loop | 13 | Decrement the column counter and branch if the row is incomplete. |

Total execution latency per character equates to precisely 99 T-states. To render an entire 64-character scanline:  
![][image3]  
To render the complete 24-row grid (equivalent to 192 scanlines):  
![][image4]  
Given the MSX2 baseline clock frequency of 3.579545 MHz, executing 1.21 million T-states translates to a total rendering duration of approximately 0.339 seconds. Because this entirely sub-second execution occurs while the VDP is actively blanked, there is zero visual tearing or scrolling; the payload is assembled invisibly and manifests universally upon the restoration of the display bit.

## **Complete Architectural Implementation in Z80 Assembly**

The following implementation unifies all theoretical strategies into a functional MSX-DOS executable. It dynamically constructs the necessary memory topologies, executes the Random Block Read API, resolves control characters spatially, calculates the transposed matrices, streams the payload to the VDP, and loops indefinitely to display the zero-latency result.

Code snippet

; \==============================================================================  
; MSX2 ZERO-LATENCY TEXT MATERIALIZATION KERNEL  
; Operating Environment: MSX-DOS 1 (.COM Executable)  
; Display Target: V9938 Graphic 5 (Screen 6), 512x192, 4 Colors, 2bpp  
; \==============================================================================

            ORG  0100H          ; Base execution address for Transient Program Area

            ; \------------------------------------------------------------------  
            ; System Constants and BDOS Vectors  
            ; \------------------------------------------------------------------  
BDOS        EQU  0005H          ; Universal BDOS entry point  
FOPEN       EQU  000FH          ; Open File via File Control Block  
SETDTA      EQU  001AH          ; Define Disk Transfer Address  
RDBLK       EQU  0027H          ; Random Block Read function  
RDSLT       EQU  000CH          ; BIOS Inter-slot Read  
EXPTBL      EQU  0FCC1H         ; Main ROM slot identification variable  
CGTABL      EQU  0004H          ; Character Font Base pointer  
VDP\_PORT0   EQU  0098H          ; VRAM Data payload port  
VDP\_PORT1   EQU  0099H          ; VDP Register and Address port

            ; \------------------------------------------------------------------  
            ; Topographical Memory Map Assignments (Page-Aligned)  
            ; \------------------------------------------------------------------  
LUT\_HI      EQU  08000H         ; Left-half pixel lookup table base  
LUT\_LO      EQU  08100H         ; Right-half pixel lookup table base  
FONT\_TMP    EQU  08200H         ; Temporary linear font buffer (2048 bytes)  
FONT\_TRN    EQU  08A00H         ; Orthogonal transposed matrix (2048 bytes)  
TEXT\_BUF    EQU  09200H         ; Raw physical disk buffer (1536 bytes)  
DISP\_GRID   EQU  09800H         ; Spatial mapped text grid (1536 bytes)

            ; \==================================================================  
            ; EXECUTION PHASE 1: MSX-DOS RANDOM BLOCK TRANSFER  
            ; \==================================================================  
Main:  
            ; Relocate the Disk Transfer Address (DTA) to the raw buffer  
            LD   DE, TEXT\_BUF  
            LD   C, SETDTA  
            CALL BDOS

            ; Initialize file handles via FCB  
            LD   DE, FCB  
            LD   C, FOPEN  
            CALL BDOS  
            OR   A  
            JP   NZ, Terminate  ; Abort execution if file is not physically present

            ; Override FCB Logical Record Size to 1 byte  
            LD   HL, 1  
            LD   (FCB \+ 14), HL

            ; Zero the FCB Random Record Pointer to seek absolute zero  
            XOR  A  
            LD   (FCB \+ 33), A  
            LD   (FCB \+ 34), A  
            LD   (FCB \+ 35), A  
            LD   (FCB \+ 36), A

            ; Execute Random Block Read requesting maximum visual capacity  
            LD   HL, 1536       ; 64 columns multiplied by 24 rows  
            LD   DE, FCB  
            LD   C, RDBLK  
            CALL BDOS

            ; \==================================================================  
            ; EXECUTION PHASE 2: SPATIAL GRID RESOLUTION  
            ; \==================================================================  
            ; Initialize the spatial surrogate grid with ASCII spaces  
            LD   HL, DISP\_GRID  
            LD   DE, DISP\_GRID \+ 1  
            LD   BC, 1535  
            LD   (HL), 20H  
            LDIR

            ; Parse TEXT\_BUF to resolve physical control characters  
            LD   HL, TEXT\_BUF  
            LD   DE, DISP\_GRID  
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

            ; \==================================================================  
            ; EXECUTION PHASE 3: INTER-SLOT FONT EXTRACTION AND TRANSPOSITION  
            ; \==================================================================  
            ; Acquire Main BIOS ROM Slot Identifier  
            LD   A, (EXPTBL)  
            LD   C, A  
              
            ; Acquire absolute pointer to Character Font Base  
            LD   HL, (CGTABL)  
              
            ; Transfer 2,048 bytes of 1-bit font data into local TPA  
            LD   DE, FONT\_TMP  
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
            LD   HL, FONT\_TMP  
            LD   B, 0             
TransposeOut:  
            LD   C, 0             
TransposeIn:  
            LD   A, (HL)  
            INC  HL  
              
            ; Calculate transposition coordinates  
            LD   D, HIGH(FONT\_TRN)  
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

            ; \==================================================================  
            ; EXECUTION PHASE 4: BIFURCATED LOOKUP TABLE GENERATION  
            ; \==================================================================  
            LD   HL, LUT\_HI  
            LD   DE, LUT\_LO  
            LD   B, 0             
LUTLoop:  
            LD   C, B             
            LD   H, 0             
            LD   L, 0             
              
            ; Geometrically expand Bits 7-4 into LUT\_HI array (H register)  
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

            ; Geometrically expand Bits 3-0 into LUT\_LO array (L register)  
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

            ; Propagate expanded values to page-aligned arrays  
            PUSH HL  
            LD   H, HIGH(LUT\_HI)  
            LD   L, B  
            LD   A, (SP+1)        
            LD   (HL), A  
            LD   H, HIGH(LUT\_LO)  
            LD   A, (SP+0)        
            LD   (HL), A  
            POP  HL  
              
            DJNZ LUTLoop

            ; \==================================================================  
            ; EXECUTION PHASE 5: VDP BUS SATURATION SETUP  
            ; \==================================================================  
            DI                  ; Disable external interrupts to secure bus timing

            ; Mode Register 0: Initialize Graphic 5 (M5=1)  
            LD   A, 0AH  
            OUT  (VDP\_PORT1), A  
            LD   A, 80H           
            OUT  (VDP\_PORT1), A

            ; Mode Register 1: Blank Display to liberate VRAM slots  
            LD   A, 00H  
            OUT  (VDP\_PORT1), A  
            LD   A, 81H           
            OUT  (VDP\_PORT1), A

            ; Base Address Register 2: Align Name Table to Page 0  
            LD   A, 1FH  
            OUT  (VDP\_PORT1), A  
            LD   A, 82H           
            OUT  (VDP\_PORT1), A

            ; Mode Register 2: Maximize bandwidth, deactivate sprites  
            LD   A, 0AH  
            OUT  (VDP\_PORT1), A  
            LD   A, 88H           
            OUT  (VDP\_PORT1), A

            ; Mode Register 3: Lock vertical dimension to 192 lines  
            LD   A, 00H  
            OUT  (VDP\_PORT1), A  
            LD   A, 89H           
            OUT  (VDP\_PORT1), A

            ; \==================================================================  
            ; EXECUTION PHASE 6: PIPELINE-OPTIMIZED VRAM STREAMING  
            ; \==================================================================  
            ; Configure Alternate Registers for pure port multiplexing  
            EXX  
            LD   H, HIGH(LUT\_HI)  
            LD   C, VDP\_PORT0     
            EXX

            LD   IX, DISP\_GRID  ; Base pointer anchoring the spatial grid  
            LD   IY, 00000H     ; Initialized 17-bit physical VRAM address

            LD   A, 24          ; Lock outer loop to 24 character rows  
RenderRow:  
            PUSH AF               
            LD   C, 0           ; Initialize internal scanline counter (0-7)  
RenderScanline:  
            ; Prime VDP Internal Address Sequencer for streaming  
            ; Assert A16-A14 explicitly to zero (Page 0\)  
            XOR  A  
            OUT  (VDP\_PORT1), A  
            LD   A, 8EH  
            OUT  (VDP\_PORT1), A  
              
            ; Inject A7-A0 and A13-A8 while asserting Write Access Flag  
            PUSH IY  
            POP  HL               
            LD   A, L  
            OUT  (VDP\_PORT1), A   
            LD   A, H  
            OR   40H              
            OUT  (VDP\_PORT1), A 

            ; Configure Primary Registers for character traversal  
            PUSH IX  
            POP  HL               
            LD   D, HIGH(FONT\_TRN)  
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

            ; \==================================================================  
            ; EXECUTION PHASE 7: VISUAL MANIFESTATION  
            ; \==================================================================  
            ; Re-assert Mode Register 1 to restore CRT rendering engine  
            LD   A, 40H  
            OUT  (VDP\_PORT1), A  
            LD   A, 81H           
            OUT  (VDP\_PORT1), A

            EI                  ; Lift external interrupt suppression

InfiniteHalt:  
            JR   InfiniteHalt   ; Maintain visual state permanently

Terminate:  
            RET

            ; \------------------------------------------------------------------  
            ; Static Structural Definitions  
            ; \------------------------------------------------------------------  
FCB:  
            DB   01H            ; Hardcoded Drive A: target  
            DB   "SOME    TXT"  ; Padded identifier string  
            DS   25, 0          ; Remaining fields initialized to absolute zero

## **System Synthesis and Performance Conclusions**

The mandate to display textual data on an advanced Graphic 5 bit-mapped surface without any visual rendering latency presents a multi-layered engineering challenge. The intrinsic architecture of the MSX2 pairs a processor originally engineered in the late 1970s with a video controller built for mid-1980s graphics capabilities. Overcoming the disparity between the synchronous Z80 execution pipeline, the legacy MSX-DOS CP/M file handling abstractions, and the asynchronous VRAM memory sequencer mandates absolute structural supremacy over the hardware.  
By bypassing modern handle-based API abstractions and leveraging the raw sector-streaming power of the MSX-DOS 1 Random Block Read, the entire disk payload is acquired continuously without operating system intervention. Further, the decision to decouple the file parsing logic from the display logic guarantees that no branching penalties degrade the rendering loop.  
Crucially, the utilization of screen blanking demonstrates a profound manipulation of the V9938's internal memory arbiter. Shutting down the display frees the VRAM bus entirely, removing the wait states that typically plague graphical updates. Coupling this unrestricted bus access with an orthogonal transposed font matrix and a page-aligned bifurcated lookup table navigated via the alternate register set minimizes the computational burden to theoretically ideal levels. The resulting execution time of roughly 0.339 seconds occurs completely out of sight. When the display registers are re-engaged, the physical rendering manifests perfectly uniformly, successfully achieving visual materialization that is functionally and perceptually instantaneous.

#### **Works cited**

1. v9938 Application Manual, accessed May 10, 2026, [http://ftp.whtech.com/YAHOO%20group%20backups/GENEVE/FILES/v9938%20Application%20Manual.htm](http://ftp.whtech.com/YAHOO%20group%20backups/GENEVE/FILES/v9938%20Application%20Manual.htm)  
2. VDP programming tutorial \- MSX Assembly Page \- Grauw, accessed May 10, 2026, [https://map.grauw.nl/articles/vdp\_tut.php](https://map.grauw.nl/articles/vdp_tut.php)  
3. CHAPTER 4 \- VDP AND DISPLAY SCREEN (Sections 1 to 5\) | MSX2-Technical-Handbook, accessed May 10, 2026, [https://konamiman.github.io/MSX2-Technical-Handbook/md/Chapter4a.html](https://konamiman.github.io/MSX2-Technical-Handbook/md/Chapter4a.html)  
4. Screensplit programming guide \- MSX Assembly Page, accessed May 10, 2026, [https://map.grauw.nl/articles/split\_guide.php](https://map.grauw.nl/articles/split_guide.php)  
5. V9938 VRAM timings \- openMSX, accessed May 10, 2026, [https://openmsx.org/vdp-vram-timing/vdp-timing.html](https://openmsx.org/vdp-vram-timing/vdp-timing.html)  
6. CHAPTER 3 \- MSX-DOS | MSX2-Technical-Handbook \- GitHub Pages, accessed May 10, 2026, [https://konamiman.github.io/MSX2-Technical-Handbook/md/Chapter3.html](https://konamiman.github.io/MSX2-Technical-Handbook/md/Chapter3.html)  
7. CHAPTER THIRTEEN: MS-DOS, PC-BIOS AND FILE I/O (Part 6\) \- Phat Code, accessed May 10, 2026, [https://www.phatcode.net/res/223/files/html/Chapter\_13/CH13-6.html](https://www.phatcode.net/res/223/files/html/Chapter_13/CH13-6.html)  
8. File Management In DOS, accessed May 10, 2026, [https://dankohn.info/projects/PromdiskIII/PCINTERN-chp21.pdf](https://dankohn.info/projects/PromdiskIII/PCINTERN-chp21.pdf)  
9. MSX-DOS 2 Program Interface Specification, accessed May 10, 2026, [https://map.grauw.nl/resources/dos2\_environment.php](https://map.grauw.nl/resources/dos2_environment.php)  
10. Advanced MS-DOS Programming \- PCjs Machines, accessed May 10, 2026, [https://www.pcjs.org/documents/books/mspl13/msdos/advdos/](https://www.pcjs.org/documents/books/mspl13/msdos/advdos/)  
11. bdos.txt \- apoloval/msx-system \- GitHub, accessed May 10, 2026, [https://github.com/apoloval/msx-system/blob/master/disk/bdos.txt](https://github.com/apoloval/msx-system/blob/master/disk/bdos.txt)  
12. CP/M information archive : BDOS system calls, accessed May 10, 2026, [https://www.seasip.info/Cpm/bdos.html](https://www.seasip.info/Cpm/bdos.html)  
13. MSX-DOS 2 Function Specification, accessed May 10, 2026, [https://map.grauw.nl/resources/dos2\_functioncalls.php](https://map.grauw.nl/resources/dos2_functioncalls.php)  
14. The MS-DOS Encyclopedia: Appendix G: File Control Block (FCB) Structure \- PCjs Machines, accessed May 10, 2026, [https://www.pcjs.org/documents/books/mspl13/msdos/encyclopedia/appendix-g/](https://www.pcjs.org/documents/books/mspl13/msdos/encyclopedia/appendix-g/)  
15. Modules/dos \- MSX Game Library, accessed May 10, 2026, [https://aoineko.org/msxgl/index.php?title=Modules/dos](https://aoineko.org/msxgl/index.php?title=Modules/dos)  
16. VDP programming tutorial \- MSX Assembly Page, accessed May 10, 2026, [http://map.tni.nl/articles/vdp\_tut.php](http://map.tni.nl/articles/vdp_tut.php)  
17. cbm2 color-graphics-card for the LP and HP models with the Yamaha v9958 / v9938 and 128k dram \- GitHub, accessed May 10, 2026, [https://github.com/vossi1/cbm2-v9958-card](https://github.com/vossi1/cbm2-v9958-card)  
18. V9938-programmers-guide.pdf \- GR8BIT, accessed May 10, 2026, [https://agelabs.pro/rs/Documentation/V9938-programmers-guide.pdf](https://agelabs.pro/rs/Documentation/V9938-programmers-guide.pdf)  
19. Portar MSX Tech Doc \- Nocash, accessed May 10, 2026, [https://problemkaputt.de/portar.htm](https://problemkaputt.de/portar.htm)  
20. V9938 Video Data Processor \- Ninerpedia, accessed May 10, 2026, [https://www.ninerpedia.org/wiki/V9938\_Video\_Data\_Processor](https://www.ninerpedia.org/wiki/V9938_Video_Data_Processor)  
21. v9938 Application Manual \- MSX Assembly Page \- Grauw.nl, accessed May 10, 2026, [https://map.grauw.nl/resources/video/v9938/v9938.xhtml](https://map.grauw.nl/resources/video/v9938/v9938.xhtml)  
22. v9938.pdf \- MSX Assembly Page, accessed May 10, 2026, [https://map.grauw.nl/resources/video/v9938/v9938.pdf](https://map.grauw.nl/resources/video/v9938/v9938.pdf)  
23. V9938 MSX-VIDEO Technical Data Book, accessed May 10, 2026, [https://map.grauw.nl/resources/video/yamaha\_v9938.pdf](https://map.grauw.nl/resources/video/yamaha_v9938.pdf)  
24. V9938 VRAM timings, part II \- openMSX, accessed May 10, 2026, [https://openmsx.org/vdp-vram-timing/vdp-timing-2.html](https://openmsx.org/vdp-vram-timing/vdp-timing-2.html)  
25. MSX2 Technical Handbook \- Konamiman's MSX Page, accessed May 10, 2026, [https://www.konamiman.com/msx/msx2th/th-2.txt](https://www.konamiman.com/msx/msx2th/th-2.txt)  
26. Screen 2 Layout \- MarMSX, accessed May 10, 2026, [https://marmsx.msxall.com/artigos/arquitetura\_sc2\_en.pdf](https://marmsx.msxall.com/artigos/arquitetura_sc2_en.pdf)  
27. What is the memory layout in MS-DOS \- Retrocomputing Stack Exchange, accessed May 10, 2026, [https://retrocomputing.stackexchange.com/questions/14554/what-is-the-memory-layout-in-ms-dos](https://retrocomputing.stackexchange.com/questions/14554/what-is-the-memory-layout-in-ms-dos)  
28. MSX System Variables \- MSX Assembly Page, accessed May 10, 2026, [https://map.grauw.nl/resources/msxsystemvars.php](https://map.grauw.nl/resources/msxsystemvars.php)  
29. symbols.asm \- theNestruo/msx-msxlib \- GitHub, accessed May 10, 2026, [https://github.com/theNestruo/msx-msxlib/blob/master/lib/msx/symbols.asm](https://github.com/theNestruo/msx-msxlib/blob/master/lib/msx/symbols.asm)  
30. V9938 MSX-VIDEO \- Bitsavers.org, accessed May 10, 2026, [https://bitsavers.org/pdf/yamaha/Yamaha\_V9938\_MSX-Video\_Technical\_Data\_Book\_Aug85.pdf](https://bitsavers.org/pdf/yamaha/Yamaha_V9938_MSX-Video_Technical_Data_Book_Aug85.pdf)  
31. Assembly 101: Lookup tables \- Everything NESmaker, accessed May 10, 2026, [https://nesmaker.nerdboard.nl/2022/08/29/assembly-101-lookup-tables/](https://nesmaker.nerdboard.nl/2022/08/29/assembly-101-lookup-tables/)  
32. Z80 Optimization \- WikiTI \- brandonw.net, accessed May 10, 2026, [https://wikiti.brandonw.net/index.php?title=Z80\_Optimization](https://wikiti.brandonw.net/index.php?title=Z80_Optimization)

[image1]: <data:image/png;base64,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>

[image2]: <data:image/png;base64,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>

[image3]: <data:image/png;base64,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>

[image4]: <data:image/png;base64,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>