# Linux reliability release: implementation and release gates

This work follows the v87 audit. It is a release candidate, not evidence that
all enterprise deployment blockers have been closed. Push target: `linux`;
production promotion remains gated on the outstanding checks below.

## Implemented in this change

- CMS updates pass their approved version and SHA-256 to the root-owned
  updater. The root updater still uses only its packaged HTTPS channel and
  host allowlist. If the channel changes, the request fails rather than
  installing another artifact. Success requires the exact installed version.
  This constrains the existing adapter-verified CMS approval; it does **not**
  add independent artifact signing or root-side CMS signature verification.
- APT dependency resolution is simulated before touching the installed
  package. Status includes a safe stage and reason, so an installation error
  is not mislabeled as a new-player health failure.
- A locally generated rollback has a root-owned checksum, package identity,
  architecture and version record. Automatic and boot-time recovery verify
  these before installation. A missing record fails closed. The installed
  rollback version is checked before reporting restoration. This protects
  local rollback integrity; it is not a publisher signature or a mutable-data
  rollback transaction. Old in-flight transactions without that record need
  operator recovery rather than silently trusting an unrecorded archive.
- Linux campaign and playlist downloads use a URL-hashed cache rather than
  basenames. Transfers are serialized for quota accounting, bounded in size,
  written to temporary files, checked for length and committed by rename.
  A sidecar digest detects altered/truncated cached files. A persisted publication identity
  refreshes a reused URL on a new publish and reuses verified files on restart.
  Each publication has separate files so it cannot overwrite active old bytes. Failed refreshes preserve the last complete file
  and do not claim that it is fresh. Trigger cache reads also verify digests.
  Digests establish local integrity, not authenticity against a publisher hash.
- Video controllers track position progress using a monotonic clock. Stalled
  playback emits a diagnostic and attempts pause/seek/resume, with a 45-second
  progress deadline, 180-second buffering grace and a 10-second recovery wait.
  Paused, inactive and completed non-looping content is excluded. This is
  position evidence, not decoded-frame proof. Generic web content and a
  persistently failed decoder still require stronger recovery validation.
- Proof-of-play file snapshots are serialized and flushed before rename.
  Persistence failures are reported without printing keys or payloads.
  This fixes concurrent temporary-file races, not MQTT end-to-end delivery.

## Lab configuration changes verified over SSH

- Byte `signage-x86-91a2b2`: boot order changed from
  `0005,0007,0001,0002,0003,0004,0000` to
  `0007,0005,0001,0002,0003,0004,0000`. Ubuntu is first; all fallback entries
  remain. Previous values are backed up under `/var/lib/signagex-player/`.
  Kiosk service remained active, PID 22771, zero automatic restarts.
  A subsequent controlled reboot did **not** establish recovery: the user
  reported that the Byte loaded the other OS again, with no USB connected,
  and Tailscale did not reconnect. The saved order alone is insufficient.
  F7 -> Ubuntu (KINGSTON ...) remains the recovery route. Persistent firmware
  entry/disk selection must be investigated after the correct Ubuntu is online.
  Manual recovery confirmed two internal drives: the correct Ubuntu root is
  `/dev/nvme0n1p2` (Kingston); the old UEFI OS entry points to `/dev/mmcblk0p1`.
  The firmware order had reverted to eMMC first. The standard inactive-entry
  command failed despite that entry being readable. A guarded update cleared
  only its EFI load-option active bit, backed up the original bytes to
  `/var/lib/signagex-player/Boot0005-before-inactive.bin`, and verified readback.
  **A second automatic reboot still loaded the other OS**, confirmed by the
  user. BIOS boot-device/BBS priorities and another automatic-boot check are
  required at that stage. No partitions or bootloader files were erased.
  **Subsequent operator fix:** BIOS FIXED BOOT ORDER had Hard Disk/UEFI OS
  ahead of NVMe/Ubuntu. The operator selected Kingston/Ubuntu as Boot Option
  #1 and saved with F4. Automatic normal reboots then passed, including a
  further v87 reboot and the installed v91 reboot. A power-loss cold start
  remains open. See [v91 device QA](LINUX-QA-v91-2026-11-13.md).
- Player `signage-x86-d1a1d8` (LNX-02): replaced the confirmed offline-ISO
  `http://127.0.0.1:9/ubuntu` source with the Ubuntu HTTPS archive and changed
  the security source to HTTPS, keeping the original source file backup.
  APT refresh completed. `xterm` and `gir1.2-gtk-3.0` now have candidates.
  Player remains v81, active PID 1833, zero automatic restarts. This does not
  by itself upgrade the player or repair the external ISO builder.

## Required before broad production promotion

1. Browser isolation and patch maintenance: upgrade/review the pinned CEF
   distribution and enable the Linux sandbox with tested kernel/AppArmor and
   subprocess behavior. Do not remove `--no-sandbox` blindly and strand kiosks.
   Reference: https://chromiumembedded.github.io/cef/sandbox_setup
2. Independently signed artifacts: provision release-signing keys separately
   from upload credentials, add signed metadata to the release publishing
   pipeline and verify it in the privileged installer. At inspection, this
   repository exposes only the release upload secret, not an artifact-signing
   secret. Key custody/rotation and a bootstrap trust deployment remain open.
3. Root-side verification of operator approval, replay protection, last-known
   good mutable application-state backup, and restored-version health checks.
4. Atomic last-known-good campaign manifest activation, cache garbage
   collection across campaign/playlist transitions, publisher checksums and
   complete offline recovery acceptance. The pre-existing manifest persistence
   and partial-campaign behavior are not solved by atomic individual files.
5. Playback acceptance with actual video/frame progress, frozen decoder and
   web-content fault injection, sustained 1080p/4K performance, offline recovery,
   cold starts and power interruption during each update phase. Test both
   architectures and supported X11/Wayland sessions. Do not infer these from
   unit tests or the v87 zero-restart observation.
6. Proof-of-play crash/receipt durability, log delivery acknowledgements,
   support-access expiry/least privilege, offline Wi-Fi operator acceptance,
   and factory-image source/boot enrollment fixes.

## Validation

Linux privileged-helper regression tests run in the existing isolated QA
container. Added coverage includes approval mismatch, corrupt rollback,
dependency failure before installation, cache collision/corruption/refresh,
position-progress deadlines and concurrent proof-of-play snapshots.
Source commit: `03ed248dd7fc012c921937ee70407624481f9d0f`.

- [AMD64 CI](https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/43351031937): success, including production/staging packages and staging publication.
- [ARM64 CI](https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/43351031986): success, including native compilation, package installation and staging publication.
- Final AMD64 test job: **214 Flutter tests passed; 93 Python tests passed**.
  GTK maintenance smoke and browser frame ASan/UBSan checks also passed.
- Analyzer error gate passed with **635 findings**; this is not lint-clean.
  The production feed was separately checked and still serves v87.
- Superseded candidates were cancelled. A subsequent controlled rollout
  installed v91 only on the Byte; the other player remains unchanged.
  See [v91 device QA](LINUX-QA-v91-2026-11-13.md) for recovery fault injection,
  remaining tests and the in-progress 24-hour kiosk monitor. No fleet-wide
  production promotion was performed.

Green CI does not complete the outstanding audit gates. The BIOS change passed
normal boot checks, while electrical power-loss acceptance, completed endurance
results and the other security/reliability gates above remain open.
