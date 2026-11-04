#!/bin/sh
set -eu
# Run explicitly as an administrator; installation alone grants no update access.
player_user=${1:?usage: sudo enable-managed-updates.sh <graphical-player-user>}
[ "$(id -u)" = 0 ] || { echo 'Administrator privileges required' >&2; exit 1; }
id "$player_user" >/dev/null
getent group signagex-updates >/dev/null || groupadd --system signagex-updates
usermod -a -G signagex-updates "$player_user"
printf '%s\n' 'Update permission enabled. Sign out and back in before enabling automatic app updates in the CMS.'
