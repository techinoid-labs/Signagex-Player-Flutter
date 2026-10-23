# Install and test on Azulle Byte — v15 staging

Use Ubuntu Desktop 22.04/24.04 amd64. Select Ubuntu on Xorg at login; remote
input currently requires X11. This package connects to the staging CMS.

Stable latest link (changes when a new staging version is published):
https://stage.signagexai.com/v1/player-releases/download?platform=linux

Pinned v15 package (remains v15 when latest advances):
https://norwin.sfo3.digitaloceanspaces.com/player-releases/staging/linux/signagex-player-staging-v15_amd64.deb

## Download and install v15

```bash
uname -m                       # must report x86_64
echo "$XDG_SESSION_TYPE"       # use x11
cd ~/Downloads
curl -fL 'https://norwin.sfo3.digitaloceanspaces.com/player-releases/staging/linux/signagex-player-staging-v15_amd64.deb' -o signagex-player-staging-v15_amd64.deb
echo '7e09cffaf5d868077ac81d362bb1de9f8e0d973340d2d5de87f14ce6d97a5e0b  signagex-player-staging-v15_amd64.deb' | sha256sum -c -
# Continue only after OK.
sudo apt update
sudo apt install ./signagex-player-staging-v15_amd64.deb
signagex-player-staging
```

Verify installed Debian version (`15` corresponds to CI release `v15`):

```bash
dpkg-query -W -f='${Package} ${Version}\n' signagex-player-staging
```

## Pair and validate

1. Claim the on-screen code through the staging CMS.
2. Publish images/video; check rotation and audio.
3. Test remote view, mouse/keyboard, Home then Back.
4. Disconnect networking; verify cached playback. Reconnect and verify online status.
5. Restart the app; verify pairing/content persist.

## Optional kiosk setup

Run as the ordinary screen user, not root:

```bash
sudo /opt/signagex-player-staging/kiosk/install.sh "$(id -un)" /usr/bin/signagex-player-staging
```

Log out, choose SignageX Kiosk and log in again. Test fullscreen, cursor hiding,
blanking prevention and CMS reboot. Configure display-manager automatic login
for that user/session separately, then verify startup after a power cycle.

Find diagnostic logs with:

```bash
find ~/.local/share -name signagex_debug.log
```

Record results against v15 in LINUX-RELEASES.md. For a new version, add a release
entry and update the pinned URL, filename and checksum together. Do not use a
latest URL with a historical checksum.
