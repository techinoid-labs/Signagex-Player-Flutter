# Linux packaging

Two formats come out of `build-linux.yml`, because they answer different
questions.

| | Use it when |
|---|---|
| `.AppImage` | **Default.** One executable file that needs nothing installed first: `chmod +x`, run. No root, no package manager, no dependency resolution, nothing to uninstall. |
| `.deb` | The screen runs Ubuntu or Debian *and* you want system integration: a launcher entry, apt-managed upgrades, a package the machine knows about. |

The AppImage bundles xdotool for X11 remote input and carries every shared library the player links against,
including the embedded browser's, so a bare machine with a desktop session
and nothing else on it will run it.

Two things it deliberately does not carry, because it cannot:

* **glibc.** A binary links against the glibc of the machine that built it
  and runs on anything newer, never anything older. That is why CI builds
  on the oldest Ubuntu still in the fleet rather than the newest runner.
  Bundling removes package dependencies, not this one.

* **The graphics driver stack** (libGL, libEGL, the X11/Wayland client
  libraries). These have to match the host's kernel and driver, so bundling
  them breaks hardware acceleration rather than helping.

## Running it

The AppImage needs no install and no root:

```bash
chmod +x SignageX-Player-v137-x86_64.AppImage
./SignageX-Player-v137-x86_64.AppImage
```

Copy it to the screen, make it executable, run it. That is the whole
procedure.

The .deb, if you want the machine to know about the app:

```bash
sudo apt install ./signagex-player_v137_amd64.deb
```

`apt install` rather than `dpkg -i`, so dependencies are pulled in instead
of leaving the package half-configured. Then launch **SignageX Player**
from the applications menu, or run `signagex-player`.

## Starting automatically on a signage screen

Not enabled by either package. The .deb installs system-wide, and switching
it on by default would launch the player for every user of the machine,
including whoever is only there to fix it. Turn it on for the screen's own
user.

For the AppImage, point an autostart entry at wherever you put the file:

```bash
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/signagex-player.desktop <<EOF
[Desktop Entry]
Type=Application
Name=SignageX Player
Exec=$HOME/SignageX-Player.AppImage
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
```

For the .deb:

```bash
mkdir -p ~/.config/autostart
cp /usr/share/applications/ai.signagex.player.desktop ~/.config/autostart/
```

The screen also needs to not blank. On a GNOME desktop:

```bash
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
```

## Diagnostics

```
~/.local/share/signagex-player/signagex_debug.log
```

This is the file to ask for when a screen misbehaves. It records pairing,
every restriction decision and why, campaign rotation, playlist downloads
and connection retries, none of which is visible otherwise, since a player
launched from the desktop or an autostart entry has no terminal attached.

It is capped at 8 MB and rotates once, keeping `signagex_debug.log.previous`.
The previous file is usually the interesting one after a crash, since it
holds the run leading up to it.

If the path above does not exist, the app has not written to it yet. Start
the player, give it a few seconds, then:

```bash
find ~/.local/share -name 'signagex_debug.log'
```

## Building the packages by hand

Both scripts expect a release build to already exist:

```bash
flutter build linux --release
./linux/packaging/make_deb.sh v0 dist/signagex-player_v0_amd64.deb
./linux/packaging/make_appimage.sh v0 dist/SignageX-Player-v0-x86_64.AppImage
```

`make_appimage.sh` needs `linuxdeploy` on `PATH`, or `LINUXDEPLOY` pointing
at it, plus `patchelf`. Set `LINUXDEPLOY_PLUGINS=gtk` and put
`linuxdeploy-plugin-gtk.sh` on `PATH` to bundle the GTK runtime parts too.
CI fetches all of it; see `.github/workflows/build-linux.yml`.

## Reproducibility

`pubspec.lock` is committed on purpose, and should stay committed.

Ignoring it is right for a published library, where consumers resolve their
own versions. This is an application, and ignoring it meant every machine
resolved its own dependency set. That is not a theoretical problem here: it
produced a build that failed in CI on an API that existed on a developer's
machine and not on the runner, and took three rounds to track down.

If a dependency needs updating, do it deliberately, run `flutter pub get`,
and commit the resulting lock alongside the change.

## A note on where the packages are built

`build-linux.yml` pins the packaging job to `ubuntu-22.04`, not
`ubuntu-latest`, for the glibc reason above: building on the newest runner
would produce a package that fails to start on every 22.04 screen in the
field with a `GLIBC_2.39 not found` error and no other clue. Raise the pin
only when no 22.04 screens remain.

## CMS network status and Wi-Fi management

Players report their network to the CMS (connection type, Wi-Fi name and signal,
addresses, MACs, saved Wi-Fi networks; never passwords) as a device-signed
`capabilities.linux_network` report (`linux_network_v1`). Reading it needs only
NetworkManager (`nmcli`); without it the CMS still gets interfaces and addresses.

Adding or removing Wi-Fi networks from the CMS is administrator opt-in, like
managed updates:

```sh
sudo /opt/signagex-player/kiosk/enable-managed-network.sh <graphical-player-user>
```

The CMS signs each command, and encrypts the Wi-Fi password to this device's key,
so neither MQTT nor logs carry it. The remote-view adapter verifies the command
(player, key, 60 s freshness, replay fence) and decrypts the password; the root
`/usr/lib/signagex-player/network-helper` (polkit group `signagex-network`) writes a
root-only NetworkManager profile and never puts the password on a command line.
"Connect now" switches to the network and must reach the SignageX API within 45 s,
otherwise it restores the previous connection and deletes the new profile. Removing
the network that carries the player's only connection is refused.

### Setup hotspot

With the same opt-in, a player with Wi-Fi hardware that has had no default route
or no SignageX API for 3 minutes, and is unpaired or has no saved Wi-Fi, asks the
helper for a temporary WPA2 hotspot `SignageX-Setup-XXXX` (last 4 of the player
code, else of the Wi-Fi MAC). The screen shows a QR code to join it and one for the
setup page, `http://10.42.0.1:8080/`, which the player serves on that address only
(Host and Origin checked, JSON only, 60 requests/min per phone, 10 attempts). The
page's Wi-Fi goes through the same "connect now" path; on failure the helper's
rollback reopens the hotspot. The helper refuses to start it while the API is
reachable, keeps the profile and a random per-boot password root-only in `/run`,
opens DHCP, DNS and 8080 in ufw on the hotspot interface only, turns IPv4
forwarding off on it, and arms a root timer that closes it after 15 minutes. The
player also closes it as soon as a default route appears (cable, saved Wi-Fi).
Needs `dnsmasq-base` (NetworkManager shared mode) and `wpasupplicant`. While the
player is online the cost is one read of `/proc/net/route` per 30 s tick.

## Offline local maintenance

The Debian package includes an independent native console for changing Wi-Fi
after moving a paired player, plus protected local SSH and kiosk-user terminal
controls. An administrator must configure a unique device PIN and enable it:

```sh
sudo python3 /opt/signagex-player/kiosk/enable-maintenance.py <graphical-player-user>
```

After signing out/in, **Ctrl+Alt+M** opens it through Openbox even if the player
has crashed. **9700** also opens it while the updated player has keyboard focus.
These only open the console; operations require the device PIN. There is no
default PIN or change to Ubuntu passwords. See
[local maintenance and image provisioning](../../docs/LINUX-LOCAL-MAINTENANCE.md)
for prerequisites, security boundaries, Wayland limitations and validation.

## Optional dedicated kiosk session

On Ubuntu/Debian, after installing the .deb, run:

```bash
sudo /opt/signagex-player/kiosk/install.sh kiosk /usr/bin/signagex-player
```

Create the ordinary `kiosk` user first. The script installs Openbox, unclutter,
X11 screen controls and a selectable **SignageX Kiosk** login session. It starts
and restarts the player fullscreen, hides the cursor and disables blanking.
Select that session at graphical login. For appliance power-on startup, configure
your display manager to automatically log in that user into this session; the
script deliberately does not rewrite an unknown display manager's settings.
Only run one kiosk session per machine. Run provisioning while online.

For AppImage, extract it (`./SignageX-Player.AppImage --appimage-extract`), then
run `sudo ./squashfs-root/usr/bin/kiosk/install.sh kiosk /absolute/path/SignageX-Player.AppImage`.
Keep the AppImage at that persistent path. The administrator-installed session
and policy remain on the host when the AppImage is replaced or deleted.

Provisioning opts the named user into the `signagex-reboot` group. The supplied
polkit rule permits only login1's ordinary reboot action for a member of that administrator-managed group, including a supervised user service; it does not authorize arbitrary commands or bypass
inhibitors/other sessions. Log out and in after changing group membership.
The player uses `systemctl --no-ask-password reboot` so authorization failures
are reported without waiting for a password dialog. Desktop installations can
opt in separately by creating this group and adding the intended user; AppImage
also needs the supplied rule installed by an administrator and systemd/logind
with polkit available. Reboot privileges are not granted just by opening it.

To remove kiosk provisioning, remove the SignageX xsessions entry,
/usr/local/libexec/signagex-kiosk-session, /etc/signagex-kiosk-player and the
administrator-installed /etc/polkit-1/rules.d/49-signagex-reboot.rules; remove
the user's signagex-reboot group membership and undo automatic login.


## Supervised startup on a Raspberry Pi desktop

For an installed Debian package, run as the ordinary graphical player user:

```bash
sh /opt/signagex-player/kiosk/install-user-service.sh
```

This replaces that user's SignageX desktop autostart entry with a launcher for
`signagex-player.service`, a systemd user service. It imports the graphical
session's DISPLAY and XAUTHORITY, starts fullscreen under X11, and restarts the
whole player process group three seconds after an exit. The existing autostart
entry is backed up once with `.before-supervision`. Start from the graphical
session or log in again after provisioning. This does not switch the desktop
from Wayland to X11; configure that separately on the device.

The optional reboot policy grants only login1's ordinary reboot action to the
administrator-enrolled `signagex-reboot` group. It deliberately supports a
supervised service without an interactive session. It does not grant arbitrary
root commands, ignore-inhibitor actions or multiple-session reboot actions.

For diagnostics, use `systemctl --user status signagex-player` and the system
journal filtered by `_SYSTEMD_USER_UNIT=signagex-player.service`. To remove
supervision, stop the service, restore the saved desktop autostart entry, remove
`~/.config/systemd/user/signagex-player.service` and
`~/.local/bin/signagex-start-supervised`, then run `systemctl --user daemon-reload`.
