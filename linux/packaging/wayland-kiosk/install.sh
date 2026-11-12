#!/bin/bash
# Usage: sudo ./install.sh <existing kiosk user> <absolute player path>
#
# Turns this Ubuntu 22.04/24.04 machine into a Wayland kiosk: at power-on the
# user is logged straight into cage on tty1 with the SignageX player as the
# only thing on screen. No display manager, desktop or taskbar; console
# switching and Ctrl+Alt+Del are disabled; the player restarts if it exits;
# the machine never blanks, sleeps or suspends. Undo with ./uninstall.sh.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run as root (sudo).' >&2; exit 1; }
kiosk_user="${1:?Specify an existing kiosk user}"
player="${2:?Specify the absolute path of the player executable}"
id "$kiosk_user" >/dev/null
[[ "$kiosk_user" != root ]] || { echo 'Use an ordinary user, not root.' >&2; exit 1; }
[[ "$player" == /* && -x "$player" && "$player" != *$'\n'* && "$player" != *=* ]] || {
  echo "Player must be an absolute path to an executable: $player" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
state=/var/lib/signagex-kiosk
mkdir -p "$state"

echo '== Packages'
apt-get update
apt-get install -y cage grim xwayland pipewire wireplumber pipewire-pulse \
  python3 python3-evdev python3-cryptography python3-pil

echo '== Remote-view helpers next to the player'
# Packaged players already carry kiosk/ (make_deb.sh, make_appimage.sh); a
# `flutter build linux` bundle does not, so copy it from this source tree.
player_dir="$(dirname "$player")"
if [[ ! -f "$player_dir/kiosk/wayland_input.py" && -d "$here/../kiosk" ]]; then
  mkdir -p "$player_dir/kiosk"
  cp "$here/../kiosk/"*.py "$player_dir/kiosk/"
  chown -R "$kiosk_user": "$player_dir/kiosk"
  echo "$player_dir/kiosk" > "$state/copied-helpers"
fi

echo '== Configuration'
if [[ ! -f /etc/signagex-kiosk.conf ]]; then
  cat > /etc/signagex-kiosk.conf <<CONF
# SignageX Wayland kiosk. KEY=VALUE lines only (read, never executed).
# Absolute path of the player executable.
PLAYER=$player
# wayland (default) or x11: run the player under XWayland inside cage if the
# embedded browser misbehaves on native Wayland.
GDK_BACKEND=wayland
# 0, 90, 180 or 270 (clockwise). Applied at the next session start.
ROTATE=0
CONF
else
  # Keep the operator's other choices; only point at this player.
  sed -i "s|^PLAYER=.*|PLAYER=$player|" /etc/signagex-kiosk.conf
fi
chmod 644 /etc/signagex-kiosk.conf

echo '== Session'
install -D -m 755 "$here/session.sh" /usr/local/libexec/signagex-wayland-session
install -D -m 755 "$here/player-loop.sh" /usr/local/libexec/signagex-wayland-player
install -D -m 644 "$here/signagex-kiosk.pam" /etc/pam.d/signagex-kiosk
sed "s/@KIOSK_USER@/$kiosk_user/" "$here/signagex-wayland-kiosk.service" \
  > /etc/systemd/system/signagex-wayland-kiosk.service
chmod 644 /etc/systemd/system/signagex-wayland-kiosk.service

echo '== Remote input (uinput)'
getent group signagex-input >/dev/null || groupadd --system signagex-input
usermod -aG signagex-input,video,input,render "$kiosk_user"
install -D -m 644 "$here/60-signagex-uinput.rules" /etc/udev/rules.d/60-signagex-uinput.rules
echo uinput > /etc/modules-load.d/signagex-uinput.conf
modprobe uinput || true
udevadm control --reload-rules
udevadm trigger --subsystem-match=misc --sysname-match=uinput || true

echo '== Restart permission (CMS reboot)'
rule="$here/../kiosk/49-signagex-reboot.rules"
[[ -f "$rule" ]] || rule="$here/../49-signagex-reboot.rules"
if [[ -f "$rule" ]]; then
  install -D -m 644 "$rule" /etc/polkit-1/rules.d/49-signagex-reboot.rules
fi
getent group signagex-reboot >/dev/null || groupadd --system signagex-reboot
usermod -aG signagex-reboot "$kiosk_user"

echo '== Never blank, sleep or suspend'
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/50-signagex-kiosk.conf <<'LOGIND'
[Login]
IdleAction=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKey=ignore
LOGIND
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo '== No way out'
systemctl mask ctrl-alt-del.target
# Magic SysRq off (Alt+SysRq combinations).
echo 'kernel.sysrq = 0' > /etc/sysctl.d/90-signagex-kiosk.conf
sysctl -q -p /etc/sysctl.d/90-signagex-kiosk.conf || true

echo '== Boot straight into the kiosk'
# Remember and disable the display manager (GDM etc.) so it can't take tty1.
if [[ -L /etc/systemd/system/display-manager.service ]]; then
  dm="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
  [[ -f "$state/display-manager" ]] || echo "$dm" > "$state/display-manager"
  systemctl disable "$dm" || true
fi
systemctl set-default graphical.target
systemctl daemon-reload
systemctl enable signagex-wayland-kiosk.service
# Not restarting systemd-logind here: that ends the desktop session the
# installer is running in (blank console). The new logind settings apply at
# the reboot below.

echo
echo "Done. Reboot to start the kiosk: sudo reboot"
echo "Settings: /etc/signagex-kiosk.conf   Logs: journalctl -u signagex-wayland-kiosk -b"
echo "Remove everything again: sudo $here/uninstall.sh $kiosk_user"
