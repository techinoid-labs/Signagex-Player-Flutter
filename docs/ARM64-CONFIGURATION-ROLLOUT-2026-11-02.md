# Raspberry Pi configuration and secure remote-view rollout — 2026-11-02

## Source and production services

- Player implementation: `bd749ec2763b141565e7d4cab4c1f704e7377158` on `perf/linux-browser-size`.
- Backend configuration implementation: `9aa4d80`; production API and worker image `77cf097`.
- Backend deployment: https://github.com/techinoid-labs/signageX-backend/actions/runs/41512630274 (successful).
- CMS production source: `a3a6eebe1b563706a3b75ef0522dec9c4d26e01f`, production Vercel deployment `7501705952` (successful).
- Final native ARM64 build (successful): https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41519481230 (`arm64-v12`).

## Release checks and corrections

The initial v9 package passed CI and package installation but crashed when the
physical Pi opened a browser texture before its first paint. It was briefly
published, then withdrawn from the ARM64 latest feed. Its manifest was preserved
and the installer retained for diagnosis. The Pi was restored from the private
application/settings backup. Manifest hold run:
https://github.com/techinoid-labs/signageX-backend/actions/runs/41517909054

The replacement includes the first-frame texture fallback, explicit texture
error reporting and unattended kiosk browser startup fixes. The independent
updater service prevents a player restart from killing its installer transaction.
A real CMS save also exposed null defaults for unconfigured scalar settings;
these now leave the control unchanged while explicit false and zero still apply.

## Verification evidence

- Backend full CI: 174 suites passed, one skipped; 2,156 tests passed, five skipped.
- Frontend focused checks: 41 tests passed, TypeScript and production build passed.
- Player preflight: 43 Flutter tests passed; null-default regression suite then passed all 10 tests. The final native CI passed all 44 Flutter tests, including that regression.
- Linux packaging/security checks: all 15 Python tests passed on ARM64.
- Native C++ frame-store test passed, including first-paint fallback.
- Physical X11 capture: 1024 × 600, encrypted/signed frame received by production CMS.
- Integrated preflight: fresh health file, campaign rendered, no service restarts.
- Production CMS displayed device-confirmed configuration revision 2 with all configured policies applied and no failed scalar defaults.
- Integrated secure remote view displayed Live frames and confirmed a signed Home command in 296 ms.

Preflight combined the tested first-frame native bundle from CI run 41512544745
with an ARM64 AOT/asset build of the final Dart source. This is recorded as a
preflight, not as the final native installer. Final package installation, reboot,
remote reconnection, checksum and feed verification are recorded below when done.

## Scope and limits

See `LINUX-CMS-CONFIGURATION.md` for settings, schedules, triggers, diagnostics,
update policy and protocol details. Linux remote-view commands/frames use the
existing signed/encrypted CMS protocol. Unsigned legacy Linux remote commands
are ignored. X11 is required. Secure remote-view device reboot is advertised as
unavailable; CMS management reboot is separate. HDMI brightness dims the image,
not the panel backlight. The Android legacy HTML5 engine is unsupported on Linux.

Automatic updates require the restricted updater permission and an enabled CMS
preference. A working update check does not by itself prove a destructive
install/rollback or power-loss test. Historical errors from the failed candidate
are retained in the player audit history rather than hidden.

## Final installer

- File: `signagex-player_arm64-v12_arm64.deb`.
- Debian version/architecture: `0.arm64-v12`, `arm64`.
- SHA-256: `86f86001b2992ecc1831187f928e92360df148039f398f83c423efb580c865ce`.
- Downloaded CI artifact identity was checked against the expected source commit
  and the installer SHA-256 against the artifact manifest.
- Exact installer installed on the Pi; production `/usr/bin/signagex-player`
  runs directly, with the temporary preflight service override removed.
- Installed startup health: build `arm64-v12`, fresh event-loop heartbeat,
  active service, zero restarts, 75-second watchdog, configuration revision 2
  and zero failed settings.
- Restricted updater group provisioned for the player account. Automatic update
  preference remains off. A reboot was initiated to validate graphical autostart,
  persistence, remote reconnection and the refreshed group membership.

## Final production verification

- Production promotion succeeded:
  https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41523199417
- Live feed reports `0.arm64-v12` and the exact verified SHA-256 above.
- Download: https://norwin.sfo3.digitaloceanspaces.com/player-releases/production/linux-arm64/signagex-player-production-0.arm64-v12_arm64.deb
- Physical reboot succeeded. LightDM autologin started the packaged supervised
  `/usr/bin/signagex-player` without the acceptance override. Fresh health reports
  `arm64-v12`; service active, zero restarts, watchdog configured.
- Configuration revision 2 persisted across reboot with zero failed settings.
- The CMS displayed Version arm64-v12, Online and Synced. Secure remote view
  reconnected and displayed Live frames; a signed Home command was confirmed by
  the final production player in 417 ms. Control was released and the remote tab
  closed after testing. The CMS was left on the confirmed configuration panel.
- Refreshed updater group membership was verified. Calling the restricted
  installed updater launched its independent system service, exited successfully,
  and reported `up-to-date`. The automatic-update preference remains off.
- The initial post-boot web-page connection warning recovered automatically in
  the same second. No persistent browser or service restart failure was observed.
- The campaign has an unpopulated Zone 1 (`No media items`); the
  assigned departures widget renders in the other zone. This is content state,
  not a player startup failure.

Remaining acceptance limits: no destructive updater rollback/power-loss test was
performed on this production Pi. Secure-session device reboot remains unavailable
and the legacy HTML5 engine remains unsupported, as advertised in capabilities.
Historical candidate-test errors are retained in the CMS event history.
