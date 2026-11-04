#!/bin/sh
# Run as the ordinary graphical player user after installing the Debian package.
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$HOME/.config/systemd/user" "$HOME/.config/autostart" "$HOME/.local/bin"
# APPIMAGE is the persistent file, unlike its temporary mounted executable.
player=${APPIMAGE:-"$base/../signagex-player"}
[ -x "$player" ] || { echo 'Player executable is missing' >&2; exit 1; }
python3 - "$base/signagex-player.service" "$HOME/.config/systemd/user/signagex-player.service" "$player" <<'PYTHON'
import json, pathlib, sys
source, destination, executable = sys.argv[1:]
executable = str(pathlib.Path(executable).resolve())
# Escape unit specifiers and ExecStart environment interpolation as literals.
quoted = json.dumps(executable.replace('%', '%%').replace('$', '$$'), ensure_ascii=False)
lines = pathlib.Path(source).read_text().splitlines()
pathlib.Path(destination).write_text('\n'.join('ExecStart=' + quoted if line.startswith('ExecStart=') else line for line in lines) + '\n')
PYTHON
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
