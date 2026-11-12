#!/bin/sh
# Optional Intel VA-API/GLX setup for the graphical player user. No sudo needed.
# Uses the distribution's authenticated package indexes, not a third-party URL.
set -eu
umask 077
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ "$(uname -m)" = x86_64 ] || { echo 'This preset is for Intel x86_64 players.' >&2; exit 1; }
intel=false
render=
driver_package=intel-media-va-driver-non-free
for vendor in /sys/class/drm/renderD*/device/vendor; do
  if [ -r "$vendor" ] && [ "$(cat "$vendor")" = 0x8086 ]; then
    intel=true
    render=/dev/dri/$(basename "$(dirname "$(dirname "$vendor")")")
    case "$(cat "$(dirname "$vendor")/device")" in
      # Noble's non-free 24.1.0 lacks Twin Lake IDs; the Ubuntu free driver
      # has the supported backport in 24.1.0+dfsg1-1ubuntu0.2 and newer.
      0x46d3|0x46d4) driver_package=intel-media-va-driver ;;
    esac
    break
  fi
done
$intel || { echo 'No Intel render device found; leaving settings unchanged.' >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cd "$work"
# The full Intel driver includes VideoProc, required by DRI3 texture import.
# Some Ubuntu installations need the multiverse repository enabled first.
command -v vainfo >/dev/null || { echo 'Install vainfo before applying this preset.' >&2; exit 1; }
apt-get download "$driver_package"
set -- ./*.deb
version=$(dpkg-deb -f "$1" Version)
package=$(dpkg-deb -f "$1" Package)
destination="$HOME/.local/opt/signagex-intel-video/$package-$version"
mkdir -p "$destination"
dpkg-deb -x "$1" "$destination"
drivers="$destination/usr/lib/x86_64-linux-gnu/dri"
[ -f "$drivers/iHD_drv_video.so" ]
if ldd "$drivers/iHD_drv_video.so" | grep -q 'not found'; then
  echo 'Intel driver dependencies are missing; service settings unchanged.' >&2
  exit 1
fi
# Library presence is not hardware support. Check the real GPU before changing
# startup settings; unsupported devices leave the working configuration intact.
if ! LIBVA_DRIVERS_PATH="$drivers" LIBVA_DRIVER_NAME=iHD \
    vainfo --display drm --device "$render" > "$work/vainfo.log" 2>&1 ||
   ! grep -q VAEntrypointVLD "$work/vainfo.log" ||
   ! grep -q VAEntrypointVideoProc "$work/vainfo.log"; then
  echo 'Driver did not validate hardware decoding and video processing; settings unchanged.' >&2
  exit 1
fi
mkdir -p "$HOME/.config/systemd/user/signagex-player.service.d"
mkdir -p "$HOME/.local/bin"
install -m 755 "$source_dir/prepare-display.sh" "$HOME/.local/bin/signagex-kiosk-display"
printf '[Service]\nEnvironment="LIBVA_DRIVERS_PATH=%s"\nEnvironment=LIBVA_DRIVER_NAME=iHD\nEnvironment=VAAPI_GL=dri3\n' "$drivers" \
  > "$HOME/.config/systemd/user/signagex-player.service.d/30-intel-video.conf"
printf 'ExecStartPost=-%%h/.local/bin/signagex-kiosk-display\n' \
  >> "$HOME/.config/systemd/user/signagex-player.service.d/30-intel-video.conf"
systemctl --user daemon-reload
echo 'Intel video preset installed for this account. Restart signagex-player.service to apply.'
