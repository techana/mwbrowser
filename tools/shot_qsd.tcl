# quick_screen_draw spike: load test.html (which exercises the four
# colour variants via <font color>) and capture the rendered view.
# Compare against the pre-spike screenshot to catch any glyph
# regression introduced by the bifurcated-LUT fast lane.
set SHOT_DIR /tmp
set SHOT_PREFIX vwr-qsd-

proc shot {label} {
    global SHOT_DIR SHOT_PREFIX
    screenshot -raw -size 640 -prefix ${SHOT_DIR}/${SHOT_PREFIX}${label}-
}

# AUTOEXEC.BAT runs MWBRO; default page is test.html.
after time 30 { shot test }
after time 32 { type "\x0c" }
after time 33 { type "A:BENCHTX.HTM\r" }
after time 50 { shot bench-p1 }
after time 52 { type " " }
after time 60 { shot bench-p2 }
after time 64 { exit }
