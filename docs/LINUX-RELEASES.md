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
