# bench_scroll.tcl -- scroll-latency benchmark harness for the
# optimization_round_1 work.
#
# Two pieces:
#   1. Wall-clock screenshots at fixed offsets after each PageDown,
#      so the operator can eyeball "by which frame did the new page
#      stabilise?". The slowest-still-changing pair of consecutive
#      screenshots gives an upper bound on per-page latency.
#   2. (When the .COM was built with -DBENCH) write_io watchpoint
#      on the bench port (0x2E) records realtime stamps in
#      $::BENCH_LOG every time PrintFileContent enters/leaves. The
#      cycle harness reads that log to compute averages.
#
# Page choice: pass via the BENCH_PAGE TCL variable BEFORE -script,
# defaults to BENCHTX.HTM. Example invocation:
#   openmsx ... -command 'set BENCH_PAGE BENCHIM.HTM' \
#                -script tools/bench_scroll.tcl
#
# Output:
#   /tmp/vwr-bench-<page>-<phase>-<NNNN>.png
#   /tmp/bench_<page>.log              (only if -DBENCH was built in)

# ── Config ────────────────────────────────────────────────────────
# Page selection: BENCH_PAGE env var, ::BENCH_PAGE TCL global, or
# fall back to BENCHTX.HTM. The env-var path is the most reliable
# across openMSX versions because -command / -script run in
# different scopes on some builds.
if {[info exists ::env(BENCH_PAGE)] && [string length $::env(BENCH_PAGE)]} {
    set BENCH_PAGE $::env(BENCH_PAGE)
} elseif {[info exists ::BENCH_PAGE] && [string length $::BENCH_PAGE]} {
    set BENCH_PAGE $::BENCH_PAGE
} else {
    set BENCH_PAGE "BENCHTX.HTM"
}
set SHOT_DIR /tmp
set SHOT_PREFIX vwr-bench-
# Strip .HTM for the screenshot label.
regsub -nocase {\.htm$} $BENCH_PAGE "" PAGE_LABEL

# Number of PageDown presses to issue once the page has loaded.
set N_PAGEDOWNS 3
# Wall-clock seconds between consecutive PageDown presses. Must be
# *longer than the slowest current render* so each press starts
# from a stable state. Override per-page via env var BENCH_GAP.
#
# Default 60 s: with the FileBuf-overlap bug fixed (round 1), the
# parser actually does its full job (tag dispatch + Arabic shaping)
# instead of falling into the corrupted-state PlainTextMode
# fast-path. Real renders on a ~12 KB page are ~30-50 s of
# emulated time, so 60 s gives every PageDown a clean start.
set GAP_S 60
if {[info exists ::env(BENCH_GAP)] && [string length $::env(BENCH_GAP)]} {
    set GAP_S $::env(BENCH_GAP)
}

# ── Helpers ───────────────────────────────────────────────────────
proc shot {label} {
    global SHOT_DIR SHOT_PREFIX PAGE_LABEL
    screenshot -raw -size 640 \
        -prefix ${SHOT_DIR}/${SHOT_PREFIX}${PAGE_LABEL}-${label}-
}

# ── Benchmark port watchpoint (only fires when the .COM was built  ─
#    with -DBENCH; otherwise the watchpoint sits idle).
set BENCH_LOG /tmp/bench_${PAGE_LABEL}.log
file delete -force $BENCH_LOG
set BENCH_FH [open $BENCH_LOG w]
puts $BENCH_FH "# realtime  port  value  meaning"
flush $BENCH_FH

debug set_watchpoint write_io 0x2E {} {
    upvar #0 BENCH_FH fh
    set t [machine_info time]
    # openMSX exposes the byte being written as $::wp_last_value while
    # the watchpoint command runs (and $::wp_last_address as the port).
    set v "?"
    catch {set v $::wp_last_value}
    set tag "?"
    if {$v == 1} { set tag "render-start" }
    if {$v == 2} { set tag "render-end"   }
    puts $fh "$t 0x2E $v $tag"
    flush $fh
}

# ── Boot sequence ─────────────────────────────────────────────────
# (timing matches existing shot_*.tcl scripts: ~24s for MSX-DOS to be
#  ready at the prompt, ~30s by the time MWBRO has launched.)
#
# Use [list ...] (or double-quoted bodies) to defer-then-substitute
# $BENCH_PAGE; bare `{ ... }` is a literal block in TCL and would
# type the dollar sign + variable name into the address bar.
proc type_page {} {
    global BENCH_PAGE
    # IsLocalUrl in mwbrowser.asm requires a letter:filename pattern,
    # otherwise the URL is sent to the bridge -- which 404s when no
    # bridge is running. Prefix with the boot drive (A:).
    type "A:${BENCH_PAGE}\r"
}

after time 23 { shot dos-ready }
# Bumped to t=34 -- MWBRO.COM is now ~37 KB and the MSX-DOS 1 disk
# load takes about 8 emulated seconds, so an earlier shot caught
# the prompt mid-load and any keystrokes hit DOS instead of the
# browser. shot_lastline.tcl's t=30 worked back when the .COM was
# ~14 KB; this margin holds for the current binary.
after time 34 { shot mwbro-launched }
# Clear address bar (Ctrl-L) and type the test page filename. No
# drive prefix -- MWBRO opens relative names from the current DOS
# drive (matches shot_lastline.tcl's pattern).
after time 35 { type "\x0c" }
after time 36 { type_page }
after time 44 { shot page-loaded }

# ── Scroll loop: N_PAGEDOWNS presses, GAP_S apart ────────────────
# Schedule them statically so we don't depend on TCL after-callbacks
# resolving variables at fire time.
set start_t 46
for {set i 1} {$i <= $N_PAGEDOWNS} {incr i} {
    set press_t [expr {$start_t + ($i - 1) * $GAP_S}]
    set shot_t  [expr {$press_t + $GAP_S - 1}]   ;# 1s before next press
    after time $press_t [list type "M"]
    after time $shot_t  [list shot "p${i}"]
}

# Final shot + tidy.
set tail_t [expr {$start_t + $N_PAGEDOWNS * $GAP_S + 2}]
after time $tail_t [list shot "final"]
after time [expr {$tail_t + 1}] {
    if {[info exists BENCH_FH]} { close $BENCH_FH }
    exit
}
