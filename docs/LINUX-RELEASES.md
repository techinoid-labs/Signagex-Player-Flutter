# Linux player releases

Version IDs are assigned by Linux CI (`v15`, `v16`, ...). A publication retry
keeps the same version and binary checksum. A new player build receives a new
version. Staging and production are separate channels; promotion does not mean
a new player build. Record tested hardware and outstanding issues per release.

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
