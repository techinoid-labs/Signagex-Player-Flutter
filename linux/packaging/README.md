# Linux packaging

Two formats come out of `build-linux.yml`, because they answer different
questions.

| | Use it when |
|---|---|
| `.AppImage` | **Default.** One executable file that needs nothing installed first: `chmod +x`, run. No root, no package manager, no dependency resolution, nothing to uninstall. |
| `.deb` | The screen runs Ubuntu or Debian *and* you want system integration: a launcher entry, apt-managed upgrades, a package the machine knows about. |

The AppImage carries every shared library the player links against,
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
