# Raspberry Pi / Linux ARM64 bring-up

Status: dedicated build path added; native CI compilation and Pi hardware
acceptance are not yet recorded. This is not a production support claim.

## Dependency audit (2026-10-23)

- `webview_cef` **0.2.2**, `third/download.cmake`, selects CEF
  130.1.2 / Chromium 130.0.6723.44 `linuxarm64` on native `aarch64` hosts.
  Its official Spotify CDN archive returned HTTP 200. No upgrade is required
  merely to select ARM64. This older Chromium still needs a separate security
  maintenance plan; ARM support does not make it current.
- `fvp` **0.37.2**, `cmake/deps.cmake`, selects `mdk-sdk-linux.tar.xz` for
  aarch64 rather than the x64-only SDK. MDK upstream documents Raspberry Pi
  support. Actual SDK download/link success is a native-build gate.
- MDK describes system FFmpeg/EGL as a route to Pi hardware decoding. Do not
  remove bundled libraries automatically: codec availability and acceleration
  need measurement on the intended Pi/OS. Successful compilation proves neither.
- Flutter 3.27.4 source bootstrap detects ARM64 for Dart. Build natively on
  `ubuntu-22.04-arm`; keep the same baseline as amd64. No x64 emulation.

Sources:
https://pub.dev/api/archives/webview_cef-0.2.2.tar.gz
https://pub.dev/api/archives/fvp-0.37.2.tar.gz
https://github.com/wang-bin/mdk-sdk#readme
https://docs.github.com/en/actions/reference/runners/github-hosted-runners

## Dedicated build

`.github/workflows/build-linux-arm64.yml` builds production and staging flavours
on a native ARM64 runner. It analyzes/tests, creates separate `_arm64.deb` and
`-aarch64.AppImage` artifacts, checks ELF/package architecture, installs the
production Debian package and records SHA256SUMS plus commit identity.
Pi packages exclude MDK’s optional `libmdk-rockchip.so` backend: it requires
Rockchip-specific `librockchip_mpp.so.1`, which a Pi does not provide. The core
MDK/FFmpeg runtime remains bundled.
Failures fail this workflow. It does not publish to either amd64 release feed.
Build identifiers use `arm64-vN`, independent of the amd64 v15 release.

Packaging scripts map arm64 to Flutter's `build/linux/arm64/release/bundle`.
Do not rename an amd64 package or serve an ARM64 package as `platform=linux`:
the current backend treats that feed as amd64. Architecture-aware publication
and promotion are separate work after native builds are proven.

## Target and acceptance

Initial target: Pi 4/5 with 64-bit Ubuntu Desktop and an X11 session.
Raspberry Pi OS is not certified; 32-bit armhf is excluded. Record exact Pi,
RAM, OS/kernel, graphics driver and display settings before testing.

- [ ] Native CI: Dart analysis/tests, CEF/MDK compilation, ELF architecture,
      .deb install, AppImage creation and checksums.
- [ ] Launch each format as an ordinary user on the Pi.
- [ ] Pair the correct channel, play image/video/web content and verify audio.
- [ ] Measure CPU, temperature, memory, dropped frames and decoder choice with
      the intended resolution, codecs and multizone workload.
- [ ] Test offline cache, reconnect, app restart and persisted pairing.
- [ ] Test remote screenshots/input and Home/Back under X11.
- [ ] Provision the kiosk, log in again, test authorized reboot and power cycle.
- [ ] Record failures/limitations before adding a public Pi download/support claim.
