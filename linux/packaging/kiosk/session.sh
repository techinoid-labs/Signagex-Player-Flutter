#!/bin/sh
# Selected through the display manager's SignageX Kiosk session.
export SIGNAGEX_KIOSK=1
xset s off
xset s noblank
xset -dpms
unclutter -idle 2 -root &
openbox &
wm_pid=$!
trap 'kill "$wm_pid" 2>/dev/null || true' EXIT HUP INT TERM
# The root-owned file contains one absolute executable path, not shell code.
IFS= read -r player < /etc/signagex-kiosk-player
while :; do
  "$player"
  sleep 3
done
