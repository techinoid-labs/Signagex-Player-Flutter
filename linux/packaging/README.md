# Linux packaging

Two formats come out of `build-linux.yml`, because they answer different
questions.

| | Use it when |
|---|---|
| `.deb` | The screen runs Ubuntu or Debian. Installs properly, gets a launcher entry and an icon, apt resolves its dependencies, and `apt upgrade` can replace it later. |
| `.AppImage` | Anything else, or no root available. One executable file: `chmod +x`, run. No package manager, no dependency resolution, nothing to uninstall. |

The `.deb` is the default for the fleet. The AppImage exists for the screen
nobody anticipated — a different distribution, a locked-down machine, or a
support call where the fastest path to a working screen is one file.

## Installing

```bash
sudo apt install ./signagex-player_v137_amd64.deb
```

`apt install` rather than `dpkg -i`, so dependencies are pulled in rather
than leaving the package half-configured.

Then launch **SignageX Player** from the applications menu, or:

```bash
signagex-player
```

The AppImage needs no install:

```bash
chmod +x SignageX-Player-v137-x86_64.AppImage
./SignageX-Player-v137-x86_64.AppImage
```

## Starting automatically on a signage screen

Not enabled by the package, because a `.deb` installs system-wide and
switching it on by default would launch the player for every user of the
machine, including whoever is only there to fix it. For a dedicated screen,
turn it on for that screen's user:

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
and connection retries — none of which is visible otherwise, since a player
launched from the desktop or an autostart entry has no terminal attached.

It is capped at 8 MB and rotates once, keeping `signagex_debug.log.previous`.
The previous file is usually the interesting one after a crash, since it
holds the run leading up to it.

If the path above does not exist, the app has not written to it yet — start
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

`make_appimage.sh` needs `appimagetool` on `PATH`, or `APPIMAGETOOL` pointing
at it. CI fetches it; see `.github/workflows/build-linux.yml`.

## A note on where the packages are built

`build-linux.yml` pins the packaging job to `ubuntu-22.04`, not
`ubuntu-latest`. A binary links against the glibc of the machine that built
it and runs on anything newer, never anything older — so building on the
newest runner would produce a package that fails to start on every 22.04
screen in the field with a `GLIBC_2.39 not found` error and no other clue.
Building on the oldest release still supported is what makes one package
work everywhere. Raise the pin only when no 22.04 screens remain.
