#!/bin/bash
# Usage: sudo ./install.sh <existing kiosk user> <absolute player/AppImage path>
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root.' >&2; exit 1; }
kiosk_user="${1:?Specify an existing kiosk user}"
player="${2:?Specify an absolute installed player path}"
id "$kiosk_user" >/dev/null
[[ "$kiosk_user" != root && "$player" == /* && -x "$player" && "$player" != *$'\n'* ]] || exit 1
source_dir="$(cd "$(dirname "$0")" && pwd)"
apt-get update
apt-get install -y openbox unclutter x11-xserver-utils xdotool policykit-1
install -D -m 755 "$source_dir/session.sh" /usr/local/libexec/signagex-kiosk-session
printf '%s\n' "$player" > /etc/signagex-kiosk-player
chmod 644 /etc/signagex-kiosk-player
mkdir -p /usr/share/xsessions /etc/polkit-1/rules.d
cat > /usr/share/xsessions/signagex-kiosk.desktop <<'SESSION'
[Desktop Entry]
Name=SignageX Kiosk
Exec=/usr/local/libexec/signagex-kiosk-session
Type=Application
SESSION
rule="$source_dir/49-signagex-reboot.rules"
[[ -f "$rule" ]] || rule="$source_dir/../49-signagex-reboot.rules"
# Installed .deb stores the rule under /usr/share/polkit-1/rules.d.
if [[ -f "$rule" ]]; then
  install -m 644 "$rule" /etc/polkit-1/rules.d/49-signagex-reboot.rules
fi
getent group signagex-reboot >/dev/null || groupadd --system signagex-reboot
usermod -aG signagex-reboot "$kiosk_user"
echo 'Log out, then select SignageX Kiosk at the graphical login screen.'
echo 'Configure automatic login for this user in your display manager if required.'
