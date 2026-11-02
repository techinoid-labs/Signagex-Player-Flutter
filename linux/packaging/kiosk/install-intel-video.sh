#!/bin/sh
# Optional Intel VA-API/GLX setup for the graphical player user. No sudo needed.
# Uses the distribution's authenticated package indexes, not a third-party URL.
set -eu
umask 077
[ "$(uname -m)" = x86_64 ] || { echo 'This preset is for Intel x86_64 players.' >&2; exit 1; }
intel=false
for vendor in /sys/class/drm/renderD*/device/vendor; do
  if [ -r "$vendor" ] && [ "$(cat "$vendor")" = 0x8086 ]; then intel=true; fi
done
$intel || { echo 'No Intel render device found; leaving settings unchanged.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$work"
# The full Intel driver includes VideoProc, required by DRI3 texture import.
# Some Ubuntu installations need the multiverse repository enabled first.
apt-get download intel-media-va-driver-non-free
set -- ./*.deb
version=$(dpkg-deb -f "$1" Version)
destination="$HOME/.local/opt/signagex-intel-video/$version"
mkdir -p "$destination"
dpkg-deb -x "$1" "$destination"
drivers="$destination/usr/lib/x86_64-linux-gnu/dri"
[ -f "$drivers/iHD_drv_video.so" ]
if ldd "$drivers/iHD_drv_video.so" | grep -q 'not found'; then
  echo 'Intel driver dependencies are missing; service settings unchanged.' >&2
  exit 1
fi
mkdir -p "$HOME/.config/systemd/user/signagex-player.service.d"
printf '[Service]\nEnvironment="LIBVA_DRIVERS_PATH=%s"\nEnvironment=LIBVA_DRIVER_NAME=iHD\nEnvironment=VAAPI_GL=dri3\n' "$drivers" \
  > "$HOME/.config/systemd/user/signagex-player.service.d/30-intel-video.conf"
systemctl --user daemon-reload
echo 'Intel video preset installed for this account. Restart signagex-player.service to apply.'
