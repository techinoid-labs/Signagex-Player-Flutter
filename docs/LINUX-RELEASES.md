# Linux player releases

Version IDs are assigned by Linux CI (`v15`, `v16`, ...). A publication retry
keeps the same version and binary checksum. A new player build receives a new
version. Staging and production are separate channels; promotion does not mean
a new player build. Record tested hardware and outstanding issues per release.

The release feed carries the package's Debian `Version` (`15`), not the CI id
(`v15`): `update-player` compares it with dpkg, where `v15` sorts above every
number. Feeds published before 2026-11-04 carried `v15`; the updater now accepts
either form. A release that fails on a device is retried with per-release backoff
(1 h doubling to 24 h, ±20 % jitter), so a bad release does not make the fleet
re-download it every hour.

The bundled mdk video SDK is pinned (`linux/packaging/pin_mdk_sdk.sh`, currently
v0.39.0, checksummed). fvp otherwise downloads SourceForge's nightly SDK on every
build, which is how v51 shipped an unloadable `libmdk`. Raise the pin deliberately
and soak-test the new SDK on real hardware before releasing.

Release gate for every build: on the lab Azulle and Pi, the player idling on its
pairing or content screen must not hold a core (`top -H`: the main thread well
under 10 %). Before v58 the GTK loop spun at 100 % of one core because Chromium's
GLib work source was attached but never run; CEF now runs the loop itself.

## v87 — 2026-11-12 — production (amd64)

- Source: `e5799ed92882f17937b468e75f1366960d35078b`, branch `linux`.
- [Build/test run](https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/43324702592)
  and [production promotion](https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/43327980306) passed.
- Exact production artifact installed and tested on **MPM-LAB-LNX-03 | Azulle
  Byte 91A2B2** before promotion. Paired kiosk and configuration retained.
- Download: https://norwin.sfo3.digitaloceanspaces.com/player-releases/production/linux/signagex-player-production-87_amd64.deb
- SHA-256: `11262632b9aa3161c8f064ff84e6fcb220d04a1fd94382af9edd1b44277a29a1`.
- [Validation evidence and remaining acceptance](LINUX-QA-2026-11-12.md).

- Independent offline Wi-Fi console, including relocation with an old SSID saved.
- Openbox Ctrl+Alt+M entry; focused-player 9700 entry.
- Device-specific PIN, persistent attempt lockout, timed local OpenSSH access,
  and a protected kiosk-account terminal. No root shell or shared default PIN.
- Debian packaging and tests added for amd64/ARM64. Administrator opt-in and
  per-device PIN provisioning are required; the USB-image repository still needs
  offline dependencies and provisioning integration. See `LINUX-LOCAL-MAINTENANCE.md`.
- Includes the previously merged Linux parity, hotspot, OTA, responsive pairing,
  kiosk campaigns and Fiza's Wayland kiosk/session fixes (PR #64).
- Reconciled the older first-frame branch with newer browser load/frame gating;
  repaired V8 native declarations, added opt-in video timing diagnostics and an
  optional Intel video/display preset. Existing decoder and size limits retained.
- Production publication uses api.signagex.ai, retaining source-run, version and
  checksum verification. No unrelated Windows/macOS feature branches merged.
- Byte preflight found Twin Lake GPU 8086:46d4 unsupported by the installed
  non-free 24.1.0 driver. Ubuntu's 24.1.0+dfsg1-1ubuntu0.2 free driver passed
  VA-API initialization/codec checks; optional Intel preset now selects it and
  validates real decoding/VideoProc before changing service settings.
- Linux no longer requests unsupported mobile GPS/location permission channels.
- Linux MQTT now requires a broker ping response within 15 seconds (30-second
  keepalive), recovering sockets stranded on the previous Wi-Fi address.
- Configuration revisions are scoped to the authoritative environment/player
  registration ID. Migrated or re-paired disks no longer ignore portrait and
  other settings because an older registration had a higher revision. Stale
  commands within the current registration remain rejected.
- Native ARM64-v52 CI passed from the same source; not promoted in this run.
  Physical Pi, AppImage and Wayland acceptance remain separate from this
  AMD64/X11 Byte validation. The live CMS four-orientation cycle, final portrait
  app restart, mute/restore and remote Home/Back passed on the Byte. Physical
  cold-boot and remaining acceptance cases are listed in the validation report.

## v15 — 2026-10-23 — staging

- Added xdotool dependency to Debian packaging and bundled it in AppImage.
- Fixed Home/Back restoration to match the SignageX Player window title.
- Added optional Openbox kiosk session, fullscreen startup, restart loop,
  cursor hiding and screen blanking prevention.
- Added restricted, opt-in kiosk reboot authorization.
- Fixed Dart raw-string syntax in the window-title regular expression.
- CI analysis/tests, amd64 production/staging builds, package generation and
  Debian installation passed. Staging publication passed.
- Server follow-up: raised upload limits/timeouts and corrected Linux download
  naming to versioned .deb files. This does not change the v15 binary.
- Still to validate: Azulle Byte playback, pairing, offline operation, remote
  input, kiosk power-on startup and unattended reboot. ARM64 is not included.

v15 staging SHA-256:
`7e09cffaf5d868077ac81d362bb1de9f8e0d973340d2d5de87f14ce6d97a5e0b`

## New release entry template

- Version / date / channel / commit / CI run:
- Changes:
- Package filename and SHA-256:
- Checks passed:
- Hardware tested:
- Known issues / remaining work:

## v15 production promotion — 2026-10-23

Promoted the existing production artifact from CI run 40011248815 without
rebuilding the player. Production promotion run: 40023379283.

- Package: `signagex-player-production-v15_amd64.deb`
- Channel: production; pairs with production CMS.
- SHA-256: `095b0766f82ed34ce5987212a059d6367713a9ea2ea5cb3634aabf7d2c50b041`
- Download: https://norwin.sfo3.digitaloceanspaces.com/player-releases/production/linux/signagex-player-production-v15_amd64.deb
- API backend rolled out on DOKS to image `424ddf5` with 512 MiB upload support
  and versioned Debian filenames; both API replicas ready. Promotion passed.
- Hardware validation remains pending. Staging v15 is a separate package with
  its own checksum; do not mix staging and production pairing or installers.

## arm64-v9 — withdrawn configuration candidate — 2026-11-02

- Source: `0300b15026c818696c8748b3bdd7e53a8d43fd6a`.
- Native ARM64 CI: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41513597098
- Adds device-confirmed CMS settings, Linux schedules/controls, triggers,
  diagnostics, asset caching and an administrator-enabled managed updater.
- Update transactions run independently of the player service so restarts
  cannot terminate the installer or rollback check.
- Local verification: 43 Flutter tests and ARM64 AOT compilation passed.
- Native CI, complete-package installation, production feed publication and
  hardware acceptance are tracked separately in this release's rollout record.

The v9 latest manifest was withdrawn after the physical Pi exposed a native
browser first-paint crash. The candidate was not retained as the production
latest release. See `ARM64-CONFIGURATION-ROLLOUT-2026-11-02.md` for the fixes,
rollback and replacement release evidence.

## arm64-v12 — configuration and secure remote view — 2026-11-02

- Source: `bd749ec2763b141565e7d4cab4c1f704e7377158`.
- Native CI: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41519481230 (successful).
- Package: `signagex-player_arm64-v12_arm64.deb`; Debian version `0.arm64-v12`.
- SHA-256: `86f86001b2992ecc1831187f928e92360df148039f398f83c423efb580c865ce`.
- Includes first-paint browser safety, null-default handling and signed/encrypted
  CMS remote-view support in addition to the configuration implementation.
- Full source, native build, physical installation and production promotion
  evidence are recorded in the rollout document.

- Production promotion passed: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41523199417
- Live production ARM64 feed verified at `0.arm64-v12` with the checksum above.
- Physical Pi installation, graphical autostart after reboot, retained settings,
  secure live remote view and signed Home confirmation passed.
- Restricted updater check passed (`up-to-date`); automatic updates remain off.
