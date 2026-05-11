# Run ZLK.COM on the DOS 1.03 disk. ZLK uses FCB-style file I/O
# (BDOS 0x0F open + 0x27 random block read), both DOS-1 compatible.
# Ends in `JR $` infinite loop after rendering.
set SHOT_DIR /tmp
set SHOT_PREFIX vwr-zlss-

proc shot {label} {
    global SHOT_DIR SHOT_PREFIX
    screenshot -raw -size 640 -prefix ${SHOT_DIR}/${SHOT_PREFIX}${label}-
}

after time 16 { shot boot }
after time 18 { type "ZLK\r" }
after time 22 { shot zlk-22 }
after time 26 { shot zlk-26 }
after time 30 { shot zlk-30 }
after time 32 { exit }
