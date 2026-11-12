# Linux Wayland kiosk (cage)

The Linux equivalent of Windows assigned access. At power-on the machine logs
the kiosk user straight into **cage**, a Wayland compositor that shows one
app full screen, and that app is the SignageX player. There is no login
screen, desktop, taskbar or window to close, and no way to switch to a
console. If the player exits it starts again; if cage ends, systemd starts
the session again. The screen never blanks and the machine never sleeps.

Target: Ubuntu 22.04 or 24.04, amd64. Files: `linux/packaging/wayland-kiosk/`.

## Install

1. Make an ordinary user for the kiosk (not root), or use your own.
2. Build or install the player, then run the installer with the player's
   absolute path:

```bash
# from a source checkout (flutter build)
cd ~/signagex-player
flutter build linux --release --dart-define=APP_ENV=staging
sudo linux/packaging/wayland-kiosk/install.sh "$(id -un)" \
  "$HOME/signagex-player/build/linux/x64/release/bundle/signagex-player"

# or from an installed .deb
sudo /opt/signagex-player/wayland-kiosk/install.sh "$(id -un)" /usr/bin/signagex-player
```

3. `sudo reboot`. The screen goes straight to the player.

What the installer does:

| Area | Change |
|---|---|
| Packages | `cage grim xwayland pipewire wireplumber pipewire-pulse espeak-ng python3-evdev python3-cryptography python3-pil` |
| Boot | `signagex-wayland-kiosk.service` logs the user into cage on tty1 (PAM `signagex-kiosk`, a real logind session). The display manager (GDM) is disabled and remembered for uninstall. |
| Session | `/usr/local/libexec/signagex-wayland-session` runs `cage -d` (no `-s`, so Ctrl+Alt+F1..F12 can't switch away). `signagex-wayland-player` restarts the player 3 s after it exits. |
| Settings | `/etc/signagex-kiosk.conf`: `PLAYER`, `GDK_BACKEND`, `ROTATE`. Read as `KEY=VALUE`, never executed. |
| Remote input | group `signagex-input`, udev rule for `/dev/uinput`, `uinput` module at boot |
| Power | logind ignores idle, lid, suspend/hibernate and power keys; sleep/suspend/hibernate targets masked |
| Escape keys | `ctrl-alt-del.target` masked, Magic SysRq off |
| CMS reboot | `signagex-reboot` group and polkit rule (shared with the X11 kiosk) |

A `flutter build` bundle has no `kiosk/` folder, so the installer copies the
remote-view helpers next to the player. Packaged players already have them.

## Uninstall

```bash
sudo linux/packaging/wayland-kiosk/uninstall.sh "$(id -un)"   # or /opt/signagex-player/wayland-kiosk/uninstall.sh
sudo reboot
```

Everything above is reverted and the display manager is enabled again.
Installed packages stay.

## Switching modes

| Mode | How |
|---|---|
| Wayland kiosk (this) | `install.sh`, reboot |
| X11 Openbox kiosk | `uninstall.sh`, reboot, then `linux/packaging/kiosk/install.sh` and pick **SignageX Kiosk** at login |
| Normal desktop | `uninstall.sh`, reboot, choose **Ubuntu on Xorg** (remote input needs X11 there) |

For maintenance on a running kiosk, connect over SSH: `sudo systemctl stop signagex-wayland-kiosk`
frees the screen, and `start` brings it back.

## Settings (/etc/signagex-kiosk.conf)

| Key | Values | Notes |
|---|---|---|
| `PLAYER` | absolute path | set by the installer |
| `GDK_BACKEND` | `x11` (default), `wayland` | `x11` runs the player under XWayland inside cage. Use it if web pages, web apps or kiosk campaigns misbehave on native Wayland (see below). |
| `ROTATE` | `0`, `90`, `180`, `270` | clockwise, via `cage -r`; needs a cage build with `-r` |

Apply with `sudo systemctl restart signagex-wayland-kiosk`. CMS rotation and
brightness are reported as **unsupported** on this kiosk: they use `xrandr`,
which only drives X11 outputs.

## Remote view on Wayland

The player picks its tools when it starts:

| | X11 (unchanged) | Wayland (`WAYLAND_DISPLAY` set) |
|---|---|---|
| Screen picture | `scrot` | `grim` (wlr-screencopy, which cage implements). It captures the composited output, so the embedded browser region is visible too. |
| Click, drag, long press | `xdotool` | `kiosk/wayland_input.py`: a virtual absolute pointer through uinput. The compositor maps it straight onto the output, so a click lands on the exact pixel at any resolution or scale, with no pointer acceleration. |
| Typing | `xdotool type` | the same helper's virtual keyboard (US layout; characters it can't type are skipped). Text goes on stdin, never on a command line. |
| Back | Alt+Left | Alt+Left |
| Home | minimise the player | no-op: the player is the only app and is always in front |
| Restart player (remote-v2) | `systemctl --user restart` | the player is stopped and the session loop starts it again |

If the helper can't run (no `python3-evdev`, or `/dev/uinput` not writable),
the player says so in its log and the remote-v2 frames report
`can_tap: false`, so the CMS doesn't offer input that would silently fail.

`ydotool` isn't used: the 22.04 package (v0.1) has no absolute moves, and
relative moves are bent by pointer acceleration, which cage can't turn off.

## Troubleshooting

| Problem | Check |
|---|---|
| Boots to a black screen or a console | `journalctl -u signagex-wayland-kiosk -b`. A wrong `PLAYER` path is logged there. Check `systemctl is-enabled signagex-wayland-kiosk`. |
| GDM login screen still shows | `systemctl status display-manager`; disable it: `sudo systemctl disable gdm3` |
| Remote view picture is black | `grim` missing (`sudo apt install grim`), or not running under cage. GNOME's Wayland session doesn't implement wlr-screencopy; use this kiosk or Ubuntu on Xorg. |
| Remote clicks do nothing | `ls -l /dev/uinput` should show group `signagex-input`; `id` should list it (log in again after install); `python3 /path/to/kiosk/wayland_input.py check` prints the reason. |
| Clicks land in the wrong place | Make sure the player is full screen (it is, under cage). With rotation, check `ROTATE` matches the screen. |
| Web pages, web apps or kiosk campaigns don't show or don't react | Set `GDK_BACKEND=x11` in `/etc/signagex-kiosk.conf`, then restart the service. The player runs under XWayland; the lockdown and the Wayland remote view stay the same. |
| No sound | `wpctl status` as the kiosk user; PipeWire starts with the logind session. |
| Player logs | `find ~/.local/share -name signagex_debug.log` |

## Known risks to verify

- **Embedded browser (webview_cef) on native Wayland.** CEF renders off-screen
  into a texture, so it should be compositor-independent, but this build has
  only been run on X11. If anything misbehaves, use `GDK_BACKEND=x11`.
- **Touch on a real touchscreen** is handled by cage and GTK. Check that the
  player and kiosk campaign pages react to touch, not only to a mouse.
- **cage `-r`** availability varies by version; without it `ROTATE` is
  ignored (logged).
- The kiosk user can create input devices (uinput). That's needed for remote
  input, and acceptable on a single-purpose kiosk.

## Test checklist (record results with the version, OS and hardware)

1. Power on: the player appears without any login screen or desktop.
2. No escape: Ctrl+Alt+F1..F12, Ctrl+Alt+Del, Alt+F4, Alt+Tab and Super do nothing.
3. Crash restart: `pkill -f signagex-player` over SSH; the player is back within about 5 s.
4. Session restart: `sudo systemctl kill signagex-wayland-kiosk`; it comes back.
5. No blanking: leave it for 2 hours with no input; the screen stays on, no sleep.
6. Lid closed (laptop): keeps running.
7. CMS pairing, content, playlists and campaigns play as on X11.
8. Remote view: the picture shows the whole screen, including web content.
9. Remote click, drag/scroll, long press, typing in a field, Back.
10. CMS restart player (remote-v2) and CMS reboot.
11. Kiosk campaign: touch navigation, idle reset, typing in fields.
12. `ROTATE=90` and `270`: picture rotated, remote clicks land correctly.
13. 4K output: picture sharp, clicks land correctly.
14. Uninstall: the normal login screen is back after reboot.
