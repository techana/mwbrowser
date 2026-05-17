# Plug a mouse into joystick port A so the host pointer drives the MSX mouse.
# Shared by run.sh in both interactive and scripted modes.
catch { plug joyporta mouse }

# Optional host-pointer capture. Off by default because grabinput=true
# "steals" the host mouse the moment the openMSX window has focus and
# pointer_hide_delay=0 makes the host pointer disappear -- both surprise
# new users who just want to try the demo. Set MWBRO_GRAB_MOUSE=1 in
# the environment to enable (gives better tracking when actually using
# the in-browser mouse cursor; F10 toggles the grab off when you need
# to switch apps).
if {[info exists ::env(MWBRO_GRAB_MOUSE)] && $::env(MWBRO_GRAB_MOUSE) ne "" && $::env(MWBRO_GRAB_MOUSE) ne "0"} {
    catch { set grabinput true }
    catch { set pointer_hide_delay 0 }
}
