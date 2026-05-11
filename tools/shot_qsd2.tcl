# Spike validation: load BENCHIM (image-heavy page) and PageDown
# multiple times to verify scroll past page 2 works after the
# extrapolation fix. Also captures spinner state at known moments.
set SHOT_DIR /tmp
set SHOT_PREFIX vwr-qsd2-

proc shot {label} {
    global SHOT_DIR SHOT_PREFIX
    screenshot -raw -size 640 -prefix ${SHOT_DIR}/${SHOT_PREFIX}${label}-
}

# AUTOEXEC starts MWBRO. Default page (test.html) auto-loads on Enter.
after time 30 { type "\x0c" }
after time 31 { type "A:BENCHIM.HTM\r" }

# Probe spinner during initial parse: at 33s expect mid-render,
# spinner should be advancing.
after time 33 { shot busy-mid }
after time 36 { shot busy-late }

# Initial render should be done by ~38s.
after time 40 { shot p1 }

# PageDown 5 times to verify scroll past page 2 works.
after time 42 { type " " }
after time 47 { shot p2 }
after time 49 { type " " }
after time 54 { shot p3 }
after time 56 { type " " }
after time 61 { shot p4 }
after time 63 { type " " }
after time 68 { shot p5 }
after time 72 { exit }
