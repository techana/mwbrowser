# Run SHOWTXT.COM (DOS-1 patched, embedded sample text). Keeps the
# original RAM-bitmap + LDIRVM page-flip flow.
set SHOT_DIR /tmp
set SHOT_PREFIX vwr-zlss-

proc shot {label} {
    global SHOT_DIR SHOT_PREFIX
    screenshot -raw -size 640 -prefix ${SHOT_DIR}/${SHOT_PREFIX}${label}-
}

after time 16 { shot boot }
after time 18 { type "SHOWTXT\r" }
after time 20 { shot showtxt-20 }
after time 22 { shot showtxt-22 }
after time 26 { shot showtxt-26 }
# SHOWTXT calls CHGET; press Enter to dismiss + return to DOS.
after time 28 { type "\r" }
after time 30 { shot dos-back }
after time 32 { exit }
