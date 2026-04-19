#!/bin/bash
# Copy dist/mwbro.com and the sample HTML / text files into the MSX-DOS
# boot disk (overwriting any existing copies). MSX-DOS 1 uses 8.3 filenames.
set -euo pipefail
cd "$(dirname "$0")/.."
DISK="MSX-DOS/MSX-DOS v1.03.DSK"
# mtools refuses to write a read-only file; make it writable the first time.
chmod u+w "$DISK" 2>/dev/null || true
mcopy -i "$DISK" -o dist/mwbro.com ::/MWBRO.COM
mcopy -i "$DISK" -o samples/test.html  ::/TEST.HTM
mcopy -i "$DISK" -o samples/test1.html ::/TEST1.HTM
mcopy -i "$DISK" -o samples/test2.htm  ::/TEST2.HTM
mcopy -i "$DISK" -o samples/test3.htm  ::/TEST3.HTM
mcopy -i "$DISK" -o samples/test4.htm  ::/TEST4.HTM
mcopy -i "$DISK" -o samples/test5.htm  ::/TEST5.HTM
mcopy -i "$DISK" -o samples/test6.htm  ::/TEST6.HTM
mcopy -i "$DISK" -o samples/test7.htm  ::/TEST7.HTM
mcopy -i "$DISK" -o samples/test8.htm  ::/TEST8.HTM
mcopy -i "$DISK" -o samples/test9.htm  ::/TEST9.HTM
mcopy -i "$DISK" -o samples/test10.htm ::/TEST10.HTM
mcopy -i "$DISK" -o samples/imgs2.html ::/IMGS2.HTM
mcopy -i "$DISK" -o samples/headings.html  ::/HEAD.HTM
mcopy -i "$DISK" -o samples/sc6test.html   ::/SC6TEST.HTM
mcopy -i "$DISK" -o samples/pcxtest.html   ::/PCXTEST.HTM
mcopy -i "$DISK" -o samples/bmptest.html   ::/BMPTEST.HTM
mcopy -i "$DISK" -o samples/imgfail.html   ::/IMGFAIL.HTM
mcopy -i "$DISK" -o samples/logos.html     ::/LOGOS.HTM
mcopy -i "$DISK" -o samples/IMAGE5.SC6     ::/IMAGE5.SC6
mcopy -i "$DISK" -o samples/LENA8.PCX      ::/LENA8.PCX
mcopy -i "$DISK" -o samples/BMP24.BMP      ::/BMP24.BMP
mcopy -i "$DISK" -o samples/SAKHR.SC6      ::/SAKHR.SC6
mcopy -i "$DISK" -o samples/MSXLOGO.SC6    ::/MSXLOGO.SC6
mcopy -i "$DISK" -o samples/MSXLOGO.BMP    ::/MSXLOGO.BMP
mcopy -i "$DISK" -o samples/center.html    ::/CENTER.HTM
mcopy -i "$DISK" -o samples/rtlimg.htm     ::/RTLIMG.HTM
mcopy -i "$DISK" -o samples/rtltab.htm     ::/RTLTAB.HTM
mcopy -i "$DISK" -o samples/txt.txt    ::/TXT.TXT
mcopy -i "$DISK" -o samples/imgonly.html   ::/IMGONLY.HTM
