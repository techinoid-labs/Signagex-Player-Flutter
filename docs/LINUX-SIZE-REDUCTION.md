# Linux package size reduction — 2026-10-29

Status: isolated candidate on `perf/linux-browser-size`; published v15 is
unchanged. Remove debugging data, not browser/video/offline functionality.

## Measured against the exact v15 production artifact

| Measurement | Original | Debug-trimmed candidate |
|---|---:|---:|
| CEF library bytes | 1,404,663,328 | 371,665,744 |
| Debian download bytes | 305,236,744 | 143,441,592 |
| Installed player directory | 1,548,296 KiB | 539,512 KiB |

The candidate reduces download size by about 53% and installed size by about
65%. The original CEF contains roughly 1 GB of non-allocated DWARF sections.
`trim_browser.py` uses GNU `strip --strip-debug`, retaining symbol tables and
runtime exports. It hashes and compares every SHF_ALLOC section, including
its flags, address and size; packaging fails if any of those change.
It operates on staged package copies and leaves original build outputs intact.
AppImage's general stripping remains disabled; it uses the same controlled
CEF-only trim before linuxdeploy. Native amd64 and ARM64 tools process their
own architectures. No system-browser dependency or feature removal is added.

## Evidence

- Audit run: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/40890583985
  Size-audit job installed the candidate successfully; original and trimmed
  CEF loaded in separate processes with identical `cef_api_hash(0)` values.
  Separate processes are required because loading two Chromium builds in one
  process exhausted static TLS in the initial audit harness.
- Full amd64 run: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/40889900136
  Passed analysis/tests, production/staging builds, packaging and installation.
- Native ARM64 run: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/40889905045
  Passed native compilation, production/staging packaging, architecture
  verification, Debian installation, checksums and artifact upload.
- v15-derived candidate version: `15+sizeaudit1`.
- Candidate SHA-256: `963c797f6ca6574c6dddda90e502250401921c18fbcd968b8e5c97a4cb88d4f7`.

## Byte bring-up observations

SSH access established on the Ubuntu 24.04.4 x86_64 live session, using X11.
Runtime hardware identification reports Intel Celeron N4020 and about 4 GB RAM;
do not assume this particular unit is the N150 model discussed earlier.

The original .deb installation into USB-backed storage stalled in kernel
block-I/O waits. A temporary writeback-throttle experiment did not resolve it;
the USB setting was restored to 75000. No internal disk was reformatted.
The smaller candidate was checksum-verified and extracted to temporary memory
storage, then launched under a user service with `SIGNAGEX_KIOSK=1`.
This proves application startup, not a completed persistent-device installation.

Using the user's SignageX connection, the device was claimed in MpMedia as
`MPM-LAB-LNX-01 | Azulle Byte USB Size Test`, code `112b1e`, player ID
`1d7eb993-c117-484b-84ff-4721b76dc55f`. It uses one player licence.
Only this test player received sample content. CMS reported content sync;
the device downloaded an image and video and initialized the local image.
The user was away and had last reported seeing a terminal, so visible image,
video, audio and web rendering are not accepted as physically verified.

Outstanding findings:

**Superseded by the broader [2026-10-29 QA report](LINUX-QA-2026-10-29.md).**
That report records visible image/video/clock screenshots, dependency fixes,
Home/Back and isolated-network checks, plus a current browser-runtime crash
and offline-widget failure. All 20 automated tests and fresh amd64/ARM64
packaging CI passed; these do not close hardware/runtime acceptance.

- Video remained in its initialization/loading state. No baseline comparison
  establishes whether this is specific to trimming; do not call playback passed.
- `scrot` was absent, preventing the player's remote screenshot feature.
- A location permission MissingPluginException appeared on Linux.
- Browser startup/ABI loaded, but a rendered web-widget check is still pending.
- Offline behavior, reboot, Home/Back and power-cycle persistence remain pending.

Do not overwrite production v15 or change its checksum. Promote a newly
versioned build only after the remaining playback and device checks pass.
