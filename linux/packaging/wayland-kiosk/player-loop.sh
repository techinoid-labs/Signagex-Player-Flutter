#!/bin/sh
# cage's only client. If the player exits or crashes it starts again here, so
# the compositor never sits on a blank screen; if cage itself ends, systemd
# restarts the whole session (Restart=always).
set -u
player=${SIGNAGEX_KIOSK_PLAYER:?}
while :; do
  "$player"
  echo "signagex-kiosk: player exited ($?), restarting in 3 s" >&2
  sleep 3
done
