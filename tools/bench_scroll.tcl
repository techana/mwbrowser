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
# defaults to BENCH_TX.HTM. Example invocation:
#   openmsx ... -command 'set BENCH_PAGE BENCH_IM.HTM' \
#                -script tools/bench_scroll.tcl
#
# Output:
#   /tmp/vwr-bench-<page>-<phase>-<NNNN>.png
#   /tmp/bench_<page>.log              (only if -DBENCH was built in)

# ── Config ────────────────────────────────────────────────────────
if {![info exists BENCH_PAGE]} { set BENCH_PAGE "BENCH_TX.HTM" }
set SHOT_DIR /tmp
set SHOT_PREFIX vwr-bench-
# Strip .HTM for the screenshot label.
regsub -nocase {\.htm$} $BENCH_PAGE "" PAGE_LABEL

# Number of PageDown presses to issue once the page has loaded. Six
# is enough to get past page 1 + page 2 (where parser-prefix-walk
# cost peaks) and into a "steady-state" later page.
set N_PAGEDOWNS 6
# Wall-clock seconds between consecutive PageDown presses. Has to be
# longer than the slowest current render so each press starts from
# a stable state. 4s is generous on the un-optimised baseline.
set GAP_S 4

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
    set v [debug read "I/O ports" 0x2E]
    set t [machine_info time]
    set tag "?"
    if {$v == 1} { set tag "render-start" }
    if {$v == 2} { set tag "render-end"   }
    puts $fh "$t 0x2E $v $tag"
    flush $fh
}

# ── Boot sequence ─────────────────────────────────────────────────
# (timing matches existing shot_*.tcl scripts: ~24s for MSX-DOS to be
#  ready at the prompt, ~30s by the time MWBRO has launched.)
after time 23 { shot dos-ready }
after time 24 { type "MWBRO\r" }
after time 30 { shot mwbro-launched }
# Clear address bar and type the test page name.
after time 31 { type "\x0c" }                ;# Ctrl-L = clear input
after time 32 { type "C:" }
after time 33 { type "$BENCH_PAGE\r" }
after time 40 { shot page-loaded }

# ── Scroll loop: N_PAGEDOWNS presses, GAP_S apart ────────────────
# Schedule them statically so we don't depend on TCL after-callbacks
# resolving variables at fire time.
set start_t 42
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
