# Plug a mouse into joystick port A so the host pointer drives the MSX mouse.
# Shared by run.sh in both interactive and scripted modes.
catch { plug joyporta mouse }

# Sync host (macOS / X11) pointer with the MSX cursor:
#   * grabinput=true tells openMSX to capture the host pointer and feed
#     raw relative deltas to the joyport mouse without going through the
#     host's acceleration curve. Without this the macOS pointer "runs
#     ahead" of the MSX cursor on flick gestures and pointing at small
#     UI elements turns into a chase.
#   * pointer_hide_delay=0 hides the host pointer immediately so the
#     visible cursor is the MSX-side one only -- no confusing dual
#     pointers in the same screen area.
# Press F10 (default) or whatever's bound to "toggle grab input" if you
# need to release the pointer (e.g. switch to Cmd-Tab away from openMSX).
catch { set grabinput true }
catch { set pointer_hide_delay 0 }
