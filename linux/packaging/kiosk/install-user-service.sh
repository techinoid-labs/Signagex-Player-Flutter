#!/bin/sh
# Run as the ordinary graphical player user after installing the Debian package.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HOME/.config/systemd/user" "$HOME/.config/autostart" "$HOME/.local/bin"
install -m 644 "$base/signagex-player.service" "$HOME/.config/systemd/user/signagex-player.service"
install -m 755 "$base/start-supervised.sh" "$HOME/.local/bin/signagex-start-supervised"
desktop="$HOME/.config/autostart/signagex-player.desktop"
if [ -f "$desktop" ] && [ ! -e "$desktop.before-supervision" ]; then
  cp -p "$desktop" "$desktop.before-supervision"
fi
cat > "$desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=SignageX Player
Exec="$HOME/.local/bin/signagex-start-supervised"
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP
systemctl --user daemon-reload
printf '%s\n' 'Supervised SignageX startup installed. Start from the graphical session or log in again.'
