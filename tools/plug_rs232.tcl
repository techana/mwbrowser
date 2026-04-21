# Plug the Generic MSX RS-232C cartridge's UART into a TCP socket so a
# Python host running on 127.0.0.1:2323 can bridge the link. openMSX
# acts as the TCP CLIENT (it dials out), so the Python side must
# listen() on that port before the emulator fires this script.
#
# The extension ("RS232_Generic_MSX", aka "openMSX Team Generic MSX
# RS-232C") is expected to already be attached via the emulator's
# settings or an earlier `-ext rs232` flag. This script only wires up
# the host-side endpoint. Connector name "msx-rs232" comes from the
# extension's hardwareconfig.xml; the host pluggable "rs232-net" is
# one of openMSX's built-in serial bridges.

set rs232-net-address "127.0.0.1:2323"
set rs232-net-ip232 false

if {[catch {plug msx-rs232 rs232-net} err]} {
    puts stderr "plug rs232 failed: $err"
} else {
    puts "rs232: bridged msx-rs232 <-> tcp 127.0.0.1:2323"
}
