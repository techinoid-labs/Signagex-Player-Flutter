#!/bin/sh
# Started by signagex-wayland-kiosk.service on tty1. Runs the cage Wayland
# compositor with the SignageX player as its only client.
set -u
conf=/etc/signagex-kiosk.conf
PLAYER=
BACKEND=wayland
ROTATE=0
# The root-owned file is read as KEY=VALUE lines, never sourced as shell code.
if [ -r "$conf" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      PLAYER) PLAYER=$value ;;
      GDK_BACKEND) BACKEND=$value ;;
      ROTATE) ROTATE=$value ;;
    esac
  done < "$conf"
fi
case "$PLAYER" in /*) ;; *) echo "signagex-kiosk: PLAYER in $conf must be an absolute path" >&2; exit 1 ;; esac
[ -x "$PLAYER" ] || { echo "signagex-kiosk: $PLAYER is not executable" >&2; exit 1; }
case "$BACKEND" in wayland|x11) ;; *) BACKEND=wayland ;; esac

export SIGNAGEX_KIOSK=1
export SIGNAGEX_WAYLAND_KIOSK=1
export SIGNAGEX_KIOSK_PLAYER="$PLAYER"
# wayland: native Wayland client. x11: the player runs under XWayland inside
# cage (fallback if the embedded browser misbehaves on native Wayland).
export GDK_BACKEND="$BACKEND"
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=cage

# cage -r rotates the output 90 degrees clockwise per flag, where supported.
rotation=
case "$ROTATE" in
  90) rotation='-r' ;;
  180) rotation='-r -r' ;;
  270) rotation='-r -r -r' ;;
esac
if [ -n "$rotation" ] && ! cage -h 2>&1 | grep -q -- '-r'; then
  echo "signagex-kiosk: this cage build has no -r; ROTATE=$ROTATE ignored" >&2
  rotation=
fi

# -d: no client-side decorations. No -s: Ctrl+Alt+F<n> can't switch away to a console.
# shellcheck disable=SC2086
exec cage -d $rotation -- /usr/local/libexec/signagex-wayland-player
