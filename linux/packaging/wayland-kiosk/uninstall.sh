#!/bin/bash
# Usage: sudo ./uninstall.sh <kiosk user>
# Reverts install.sh: the machine boots to its normal login screen again.
# Installed packages (cage, grim, python3-evdev...) are left in place.
set -uo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root (sudo).' >&2; exit 1; }
kiosk_user="${1:?Specify the kiosk user}"
state=/var/lib/signagex-kiosk

systemctl disable --now signagex-wayland-kiosk.service 2>/dev/null
rm -f /etc/systemd/system/signagex-wayland-kiosk.service
rm -f /usr/local/libexec/signagex-wayland-session /usr/local/libexec/signagex-wayland-player
rm -f /etc/pam.d/signagex-kiosk /etc/signagex-kiosk.conf

rm -f /etc/udev/rules.d/60-signagex-uinput.rules /etc/modules-load.d/signagex-uinput.conf
udevadm control --reload-rules 2>/dev/null
gpasswd -d "$kiosk_user" signagex-input 2>/dev/null
getent group signagex-input >/dev/null && groupdel signagex-input 2>/dev/null

rm -f /etc/systemd/logind.conf.d/50-signagex-kiosk.conf
systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target ctrl-alt-del.target
rm -f /etc/sysctl.d/90-signagex-kiosk.conf
sysctl -q --system 2>/dev/null

if [[ -f "$state/copied-helpers" ]]; then
  helpers="$(cat "$state/copied-helpers")"
  [[ "$helpers" == /*/kiosk ]] && rm -rf "$helpers"
fi
if [[ -f "$state/display-manager" ]]; then
  systemctl enable "$(cat "$state/display-manager")" 2>/dev/null
fi
rm -rf "$state"
systemctl daemon-reload
# logind settings return to normal at the reboot (restarting it now would
# end the running session).

# signagex-reboot membership and its polkit rule are shared with the X11
# Openbox kiosk (kiosk/install.sh), so they stay.
echo 'Kiosk removed. Reboot to get the normal login screen back: sudo reboot'
