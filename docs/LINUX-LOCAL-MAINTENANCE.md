# Local device maintenance

Status: integrated into `linux`; release validation is recorded in LINUX-RELEASES.md.
Public player v81 does not gain these controls until a new Debian package and
the appliance provisioning change are installed. Do not assign a release ID by
hand; record the CI build ID and package checksum when a build is produced.

## Operator flow

1. On an opted-in Openbox appliance, press **Ctrl + Alt + M**. This launches a
   separate native console even when Flutter/CEF has exited or another window
   has keyboard focus. While SignageX has focus, typing **9700** (less than two
   seconds between digits) opens the same console. Neither sequence is a PIN.
   Use **Tab / Shift+Tab** to move between controls. The focused control has a
   thick yellow outline; buttons and checkboxes also receive a blue background
   and white text. **Enter** activates buttons; **Space** toggles options. Focus
   returns to the selected control after background work unless the operator
   moved elsewhere. Unlocking still moves focus into the Wi-Fi name field.
2. Read the hostname, addresses and network status without internet access.
3. Enter the **device maintenance PIN**. This is separate from Ubuntu, Wi-Fi,
   pairing codes and BIOS credentials. There is no shared/default PIN.
4. Scan nearby networks or type the SSID, enter the Wi-Fi password, and choose
   **Save and connect to Wi-Fi**. Hidden SSIDs are supported. The installed
   network helper validates the request and saves a root-only NetworkManager
   profile. Failed association/API verification restores the previous connection;
   existing profiles and device pairing are retained. Networks with a captive
   sign-in page or WPA Enterprise require a separate provisioning flow.
5. If needed, enable **local OpenSSH for 15 minutes**, explicitly turn it off,
   or open a **kiosk-account terminal**. Return with **Esc** or the return button.
6. For an interactive campaign, enable **Keep mouse cursor visible**, then
   return to the player. On X11 the preference applies within a few seconds
   and persists across player/session restarts. Turning it off restores hiding
   after two seconds without movement; mouse input is never disabled. Changing
   this preference requires the maintenance PIN. Wayland cursor control is not
   included in this change.

The controls relock after two minutes without input. Five wrong PIN attempts
cause a five-minute lockout persisted by the root helper. Wi-Fi passwords and
PINs are sent only over stdin, never command arguments, logs or CMS messages.
The terminal has a 15-minute timeout and grants no new sudo/root permissions.
An authenticated terminal is powerful: kiosk OS policy must continue to keep the
player account unprivileged. Existing narrowly scoped package policies still apply.

SSH ON does not enable a service at boot or change its authentication settings.
An existing key-only account stays key-only. Expiry stops only services started
by the lease, preserving a pre-existing administrator SSH service. Explicit OFF
stops local `ssh.socket` and `ssh.service`; **Tailscale SSH is separate**.
No port is opened in the firewall by these controls. A firewall may still prevent
SSH reachability; the console does not claim a successful remote connection.

## X11 cursor provisioning

The Debian package includes `signagex-cursor.service`, started alongside the
supervised player through its systemd user-service dependency. It runs the
unprivileged cursor manager, which owns only its own `unclutter` child. The
root helper stores the non-secret visibility preference in
`/var/lib/signagex-pointer/preference.json` in a root-owned, readable directory;
the separate PIN verifier and its directory remain private.
The packaged legacy X11 session also uses this manager when installed.

Older appliance images may independently start `unclutter-xfixes` and launch X
with `-nocursor`. Their provisioning must replace the old cursor-hiding command
with the managed service and remove `-nocursor` from the dedicated kiosk X-server
command. Apply the X-server change with one graphical-session restart. Merely
stopping `unclutter` cannot override `X -nocursor`. Preserve other LightDM and
Openbox settings; do not terminate unrelated desktop processes. Refresh the user
systemd manager after deploying the units. AppImage-only installs do not install
this protected service.

Lab validation, 2026-11-13: installed the cursor helper, GTK menu and user service
on TVM lab device `signage-x86-91a25e` as a local patch over player v87. Backups
are under `/var/backups/signagex/cursor-menu-20261113T170751Z`. Replaced its image's
independent `unclutter-xfixes` startup and removed `X -nocursor`, then restarted
LightDM once. The player returned with the same pairing. Verified the protected
helper switches the real hiding child on/off, the saved visible setting survives
a cursor-service restart, and a pointer appears over the player after idle.
Left visibility enabled. No payment, print, scan or customer-journey action was
executed; the latest CMS content message marked its campaign paused. This lab
patch is not a newly published production package or a full power-cycle test.

The Linux regression suite passed 96 checks with one unrelated runpath check
skipped because that container lacks patchelf/readelf. The GTK virtual-display
test passed, including the new switch. A further helper test covers a private
administrator umask: the public pointer preference remains readable while the
PIN verifier remains private.

Keyboard-focus follow-up, 2026-11-13: the GTK test traversed the actual focus
chain forward/backward, skipped the hidden PIN field after unlock, checked
visible outlines and preserved checkbox focus after an authenticated operation.
Installed the menu-only patch on `signage-x86-91a25e` and visually verified the
highlight after a real Tab keypress on the player. Rollback copy:
`/var/backups/signagex/focus-menu-20261113T172010Z/signagex-maintenance`.
Playback was not restarted for this follow-up. Source/package publication is
still pending.

## Provisioning once, as an administrator

Install the Debian package and ensure NetworkManager and OpenSSH are present in
the appliance's offline dependency repository. The package now also requires
`python3-gi`, `gir1.2-gtk-3.0` and `xterm`; bundle these in the ISO's offline
repository before rebuilding the image. Installing only a player AppImage does
not install privileged system helpers or a local maintenance console.

For the graphical kiosk user (normally `signagex` on our images), run:

```sh
sudo python3 /opt/signagex-player/kiosk/enable-maintenance.py signagex
```

The script prompts privately twice for a unique 8–12 digit device PIN, stores a
salted scrypt verifier in root-only `/etc/signagex-player/maintenance.json`, binds
it to that user's UID, and grants the `signagex-maintenance` group. It adds the
Openbox shortcut to system and existing user configurations, preserving other
bindings. Sign out/in or reboot once for group and shortcut changes to apply.
Use the corresponding `/opt/signagex-player-staging/` path for staging.

Keep each PIN in the operator's password manager, mapped to device identity.
Do not bake a common PIN, verifier or post-provisioned device identity into a
golden image. Provision each device after cloning. A locked Ubuntu password is
compatible with this console: PIN verification does not use the Ubuntu account
password. If the PIN is lost, an authorized SSH-key administrator can rerun the
same command to replace it. The console cannot reset its own PIN.

The separate device-image source was last located at
`/home/arsalan/usman-player-access/images/` on the Linux build laptop. That
repository must integrate per-device PIN delivery and these offline dependencies
before claiming the feature ships in a fresh USB install. It is not present in
this player checkout and has not been changed here.

## Scope and validation

- `.deb`: shared, architecture-neutral helpers for amd64 and ARM64.
- Openbox/X11: independent shortcut, full keyboard navigation, scrollable layout.
- Other desktops: launch `/usr/bin/signagex-maintenance` or configure an OS shortcut.
- Cage/Wayland: the focused-player shortcut can launch the console, but cage is a
  single-application compositor. A crash-independent global shortcut and switching
  between the player/console require compositor integration; not claimed here.
- This adds direct local Wi-Fi configuration. It does not change the automatic
  phone-hotspot policy or replace its server with an independent daemon.
- Independent of internet, MQTT and Flutter for entry and local controls. A
  functioning graphical session is required. It does not replace firmware/GRUB
  recovery when the OS cannot boot or graphics cannot start.

Tests: `test/linux_maintenance_shortcut_test.dart`,
`linux/packaging/tests/test_maintenance_helper.py`, the package contract fixture,
and the GTK smoke test. Existing Linux CI runs the GTK test under Xvfb:

```sh
python3 -m unittest discover -s linux/packaging/tests -v
dbus-run-session -- xvfb-run -a python3 linux/packaging/tests/maintenance_console_smoke.py
flutter test test/linux_maintenance_shortcut_test.dart
```

Local validation, 2026-11-11: Ubuntu 22.04 ARM64 container passed all 89 Python
packaging/helper tests. The real GTK console passed its virtual-display test
with simulated offline network/helper responses: locked entry, PIN unlock,
network selection, connection request, SSH action, kiosk terminal invocation,
and idle relock. This is software validation, not an on-device Wi-Fi test.
Flutter 3.27.4 passed all six shortcut tests, including real keyboard dispatch,
scanner-speed input, editable-text exclusion and missing-launcher handling.
Focused analysis of the shortcut and provider integration reported no errors;
the provider retains one existing unused-handler warning and two existing
RawKeyEvent deprecation notices. No native release bundle or hardware deployment
was performed for this change.

Release acceptance still requires the actual Byte and Pi: change location with
an old SSID saved, open console while offline, wrong PIN lockout, correct/incorrect
Wi-Fi passwords and rollback, hidden SSID, lost player process, unrelated window
focus, SSH timer and explicit OFF, terminal timeout, reboot, and verify saved
Wi-Fi reconnects without manual login. Record device identity, package version,
checksum and results; unit/virtual-display tests do not prove Wi-Fi hardware.

Design references: [Openbox key bindings](https://openbox.org/help/Bindings),
[polkit pkexec environment and input validation](https://www.freedesktop.org/software/polkit/docs/latest/pkexec.1.html),
[GTK application lifecycle](https://docs.gtk.org/gtk3/class.Application.html).
