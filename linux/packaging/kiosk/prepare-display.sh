#!/bin/sh
# Called after the supervised X11 player starts. Optional hints must not fail it.
set -u
[ "${SIGNAGEX_KIOSK:-0}" = 1 ] || exit 0
if command -v xset >/dev/null 2>&1; then
  xset s off 2>/dev/null || true
  xset dpms force on 2>/dev/null || true
  xset -dpms 2>/dev/null || true
fi
if [ -n "${SIGNAGEX_DISPLAY_OUTPUT:-}" ] && [ -n "${SIGNAGEX_DISPLAY_REFRESH:-}" ]; then
  if [ -n "${SIGNAGEX_DISPLAY_MODE:-}" ]; then
    xrandr --output "$SIGNAGEX_DISPLAY_OUTPUT" --mode "$SIGNAGEX_DISPLAY_MODE" --rate "$SIGNAGEX_DISPLAY_REFRESH" 2>/dev/null || true
  fi
fi
command -v xdotool >/dev/null 2>&1 || exit 0
command -v xprop >/dev/null 2>&1 || exit 0
pid=$(systemctl --user show signagex-player.service -p MainPID --value)
case "$pid" in ''|0|*[!0-9]*) exit 0 ;; esac
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  window=$(xdotool search --onlyvisible --pid "$pid" --name '^SignageX Player$' 2>/dev/null | head -n 1)
  if [ -n "$window" ]; then
    xprop -id "$window" -f _NET_WM_BYPASS_COMPOSITOR 32c -set _NET_WM_BYPASS_COMPOSITOR 1 2>/dev/null || true
    exit 0
  fi
  sleep 1
done
exit 0
