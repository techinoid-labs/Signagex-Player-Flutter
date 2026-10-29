#!/bin/sh
set -eu
# Import the actual graphical session, never assume a display number.
systemctl --user import-environment DISPLAY
if [ -n "${XAUTHORITY:-}" ]; then
  systemctl --user import-environment XAUTHORITY
fi
xset s off 2>/dev/null || true
xset -dpms 2>/dev/null || true
exec systemctl --user start signagex-player.service
