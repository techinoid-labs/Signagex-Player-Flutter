#!/bin/sh
set -eu
# Run explicitly as an administrator; installation alone grants no network access.
player_user=${1:?usage: sudo enable-managed-network.sh <graphical-player-user>}
[ "$(id -u)" = 0 ] || { echo 'Administrator privileges required' >&2; exit 1; }
id "$player_user" >/dev/null
command -v nmcli >/dev/null || { echo 'NetworkManager (nmcli) is required for CMS Wi-Fi management' >&2; exit 1; }
getent group signagex-network >/dev/null || groupadd --system signagex-network
usermod -a -G signagex-network "$player_user"
printf '%s\n' 'Network permission enabled. Sign out and back in to manage Wi-Fi from the CMS.'
