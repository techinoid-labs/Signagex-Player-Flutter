# Linux / Raspberry Pi parity audit — 2026-11-02

Audit baseline: player `2d9567f` (includes Pi reference `bd749ec`); backend `32469db`; CMS `fa2e2681`. This audit precedes implementation on `fix/linux-pi-parity`. Preserve existing SignageX colours. Automatic updates remain OFF.

Evidence is scoped to the revision and device tested. Existing shared implementation is not equivalent to physical acceptance on the Byte. The Byte's v40 branch contains performance/recovery work absent from this Pi baseline; it must be reconciled, not replaced blindly.

| Feature | Current Linux implementation | Pi reference | Gap | Required change | Test evidence |
|---|---|---|---|---|---|
| Startup / first frame | Transparent initial browser texture and native error reporting already shared | Production 0.arm64-v12 boots automatically | Combined Byte build unverified | Preserve fixes; verify cold boot | Pi rollout doc; previous Byte crash fix tested separately |
| Small-screen pairing | Responsive pairing screen and zone scaling shared | 1024×600 physical display | Byte small viewport acceptance pending | Test pairing/QR and multi-zone layouts | Pairing widget tests; Pi physical acceptance |
| Health / supervision | Build/PID timestamp, 15-second health tick, 75-second watchdog | Active, zero restarts in inspected Pi window | Byte v40 predates this shared supervisor baseline | Deploy combined build; inspect health and restart behaviour | Source linux_diagnostics.dart and packaged user service |
| Offline campaign | Cached assets, durable deferred downloads, playback gate shared | Warm internet block retained campaign | Cold offline boot and per-content coverage unproven | Test warm/cold loss and recovery | Pi warm-loss evidence only |
| Web recovery | Periodic JavaScript status probe with four-second timeout | Repeated timeouts (~36 in inspected window) | Probe channel unreliable; warning alone does not prove page failure | Port Byte native main-frame load/error notifications and bounded retry, retain diagnostics | Byte native-event fault test passed on separate branch; combined build pending |
| CMS settings | Revisioned serialized application and per-setting outcomes shared | Revision 2; reboot/brightness/logo/schedule/interval accepted | Every additional control needs Byte acceptance | Validate inventory below; preserve false/zero values and stale-revision fencing | Existing configuration tests; Pi rollout |
| Secure remote view | Protocol 2 Python adapter, encrypted frames, signed/fenced input | Live view and signed Home accepted | Hardcoded /opt adapter lookup fails relocated bundles; broader command/session tests pending | Resolve adapter beside running executable; exercise reconnect/ownership/geometry | Python protocol tests; Pi signed Home only |
| Telemetry collection | CPU delta %, memory MiB, disk KiB, network KiB/sample, uptime seconds | Real 4h/24h charts | thermal_zone0 may not be CPU on x86; hardware units acceptance pending | Identify thermal sensor type; fixture tests and Byte readings | linux_telemetry.dart; Pi chart evidence |
| Telemetry API | GraphQL Float serialization fix already shared | Backend 32469db | No port required | Preserve regression coverage | Reference reports 2,157 backend tests; not rerun by this audit |
| CMS telemetry presentation | Shared refresh/error/empty states/full width already built | Frontend references already on main | Latest uptime divides seconds by 60 but labels hours | Correct conversion and test seconds-to-hours | ResourceUsageTab.tsx:280; collector explicitly emits seconds |
| CMS layout | Shared tab spacing, measured viewer, compact save feedback | Already deployed | No device-side port | Retain layout/theme | Reference reports 27 focused checks and TypeScript pass; not rerun here |
| Audio | wpctl volume/mute/timeout controls shared | Speaker “Front Center” confirmed | Byte sink/tools/media audio unverified | Verify dependencies, default output, mute/restore and real media | Pi speaker evidence does not establish Byte audio |
| Packaging | Separate amd64/arm64 Debian pipelines, versions/checksums | Exact ARM64 package installed | Combined amd64 and arm64 artifacts need build validation | Native architecture CI and exact artifact checksum checks | Pi rollout contains package hash and promotion run |
| Updates | Opt-in privileged helper, independent service, health/rollback checks | Independent invocation up-to-date; automatic updates OFF | Destructive rollback and upgrade persistence unproven | Preserve identity/cache/config; lab upgrade/recovery test | No destructive rollback acceptance claimed |
| Production logs | MQTT wire logging enabled and full publish payload printed | Encrypted remote frame payload logging observed | Excess disk/CPU and unnecessary payload exposure | Disable wire dumps; remove payload logging; inspect higher-level logs | Direct source inspection, mqtt_client_service.dart |
| Video performance | Byte branch has duplicate-decoder fix and optional render limits | Pi acceptance is different hardware/display | Byte 1080p visibly stuttered; 720p source clearly smoother | Reconcile fixes with playback gate/safe-video settings; repeat visual acceptance | Byte feedback; frame counters alone do not prove smoothness |
| Power / thermals | OS hardware metrics | Pi historical undervoltage flags, inactive at ~56.5°C | Hardware finding distinct from app defect | Check supply and active flags during soak | Inspected Pi window only; no blanket power-health claim |

## Configuration inventory and owners

Owner roles identify responsibility, not named assignments. All controls below already have shared device-side handlers; physical acceptance remains separate.

| Settings | Owner | Status / validation needed |
|---|---|---|
| launch_on_boot | Linux platform | Built; verify installed Byte cold boot |
| apply_app_updates | Release engineering | Built, opt-in; keep OFF; verify permissions and up-to-date result |
| hide_no_campaign_messages, touch_feedback, disable_transitions | Player / QA | Built; validate empty state, touch and transitions |
| use_html5_webview | Player / CMS | Unsupported; verify honest unavailable outcome |
| safe_video_mode | Player / QA | Built, next-start decoder setting; verify pending then applied |
| screen_rotation | Linux platform / QA | Built X11; validate viewport and remote coordinates after rotation |
| reboot | Linux platform / QA | Built; verify opt-in authorization and actual restart (separate from unavailable secure-session device reboot) |
| volume, volume_timeout, mute_audio | Linux platform / QA | Built wpctl; validate actual sink and audible output |
| brightness | Linux platform / QA | Built xrandr image dimming; not physical HDMI backlight control |
| logo | Player / QA | Built validated cached logo; verify persistence/offline |
| working_schedule | Player / QA | Built local-time gate; verify timezone, overnight and boundary behaviour |
| content_update_interval | Player / QA | Built network/download policy; verify deferred sync and cached playback |

All settings: verify stale revision, null scalar, false/zero, mixed failures, unsupported and pending outcomes. CMS must not summarize mixed failure as success.

## Implementation sequence

1. Linux owner: reconcile native browser recovery from Byte `1b53ab2`, preserving configuration diagnostics; add failure/subframe/aborted-load regression coverage.
2. Linux owner: remove production wire/payload dumps; resolve secure adapter relative to executable; regression-test relocated production/staging bundles.
3. Player owner: reconcile duplicate video decoder removal and optional render limits with latest playback gate and safe-video semantics. Do not force Pi-specific render limits globally.
4. CMS owner: fix uptime hours conversion with focused regression. Backend Float change and shared frontend layout require no duplication.
5. Linux / QA: sensor-type-aware temperature readings and unit fixtures, then native amd64/arm64 build/test runs.
6. QA: deploy exact combined artifact to Byte, preserve identity/cache/settings; test every matrix row, ownership handover, audio, offline cold boot, upgrade persistence and a 24-hour soak. Record build/hash/time/results and user-visible video acceptance.

## Device-specific boundaries

Portable Linux: X11 commands, secure protocol, cache/configuration, telemetry schema, supervision, updater and UI. Pi-specific: ARM64 binary/dependencies, Raspberry Pi OS provisioning, power flags, 1024×600 display and actual audio path. Byte-specific: amd64, Intel media driver/DRI3, HDMI timing and measured decode/render limits. Wayland parity is not established.

## Build, deployment and rollback protocol

Record commit, CI run, architecture, Debian version and SHA256 before deployment. Run native amd64 and ARM64 CI separately; preserve existing test counts as historical evidence until rerun. Pi reference package/version/hash and production promotion are in ARM64-CONFIGURATION-ROLLOUT-2026-11-02.md.

Back up player identity, credentials, cached assets and configuration privately before upgrading. Install only the matching architecture artifact; verify reported build, health PID/timestamp, service status, settings revision and CMS identity after restart. Keep automatic updates disabled. Retain the previous known-good package and service configuration; on failure restore that package/configuration without deleting application state, restart and verify health/identity/cache again. A successful up-to-date check is not a rollback test.

This work does not change production release feeds. No full Linux parity or overnight stability claim is made. Hardware acceptance of the combined build remains open.


## Implementation and current validation update

Player implementation commits: `f01fee8` (native main-frame recovery, no duplicate hidden Linux video decoder, optional per-device render limits, MQTT wire/payload logging disabled), `4d4affb` (bundle-relative secure adapter with missing-adapter diagnostic, CPU sensor selection and regression tests), `33594cc` (management-message payload logging removed). Recovery diagnostics remain attached to CMS events. Safe-video decoder selection remains effective; no global 720p limit is imposed.

CMS branch `fix/linux-uptime-units`: `91a5dc3e`, `4e4c1594`. The summary now converts seconds to hours; the chart converts seconds to its labelled minutes. Missing uptime samples remain unavailable. TypeScript passed; 25 focused resource tests passed. Backend `32469db` real GraphQL decimal/large-counter serialization regression rerun: 1 test passed. No backend change required.

Local native frame-store ASan/UBSan test passed. Python packaging/protocol/updater suite: 14 passed, 1 skipped because this Mac lacks Linux dpkg-deb. Native CI must cover the skipped contract. Latest player CI: amd64 `41531661040` and ARM64 `41531664939` both succeeded, source `33594cc`. Both ran 51 Flutter tests; ARM64 ran all 15 Python tests successfully. Both architectures built production/staging Debian and AppImage artifacts; package installation checks passed.

Byte read-only check on 2026-11-02: SSH reachable, running v40 process 19488, service active, NRestarts=0, uptime ~2h29m, root filesystem 39GB available. wpctl exists. CPU x86_pkg_temp=84°C, TCPU=83°C, ACPI zone0=83°C; these demonstrate why zone0 alone is not a portable CPU metric. Current v40 has no new shared health.json; it is not the combined parity build. This is not a 24-hour acceptance result.

Remaining: all target-specific acceptance rows not covered below (including cold offline boot, full secure-session ownership/control, configuration inventory, audio, upgrades/rollback), video visual acceptance and a 24-hour soak. Pi historical test counts above are reference evidence and have not been represented as current reruns.


## Byte v43 lab deployment and bounded acceptance

- Native AMD64 run: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41531661040
- Native ARM64 run: https://github.com/techinoid-labs/Signagex-Player-Flutter/actions/runs/41531664939
- Source `33594cc`; AMD64 filename `signagex-player_v43_amd64.deb`, Debian version `43`, ~137 MiB. SHA256 `2289421219a4b68d58d62fbd588bd9a14284829d42707507b1c396d7fb7aa196`, independently matched on Mac and Byte.
- ARM64 test package `signagex-player_arm64-v19_arm64.deb`, Debian `0.arm64-v19`; CI records SHA256SUMS in its artifact. It has not been installed on a Pi by this task; this historical deployment did not change the Pi. Subsequent Pi work is tracked separately.
- v43 was extracted into `/home/techinoid/.local/opt/signagex-v43`. This is a supervised user-bundle lab deployment, not a root Debian upgrade; system dpkg still holds the older package.
- User service updated to the packaged watchdog unit; existing Intel driver/display/render-limit overrides retained. Existing v40 bundle retained. Private pre-upgrade unit/drop-in/preferences backup: `/home/techinoid/signagex-diagnostics/pre-v43`, created with restrictive permissions.
- Service MainPID 23161, watchdog 75 seconds, NRestarts=0 across the inspected startup window. Fresh health.json reports v43 and PID23161. Secure protocol Python adapter runs from the v43 bundle (not the old system package).
- Pairing player_code retained; all five existing preference fields retained. Cached `flutter.jsonObj` exists and is byte-for-byte unchanged. Screenshots confirm the existing image and clock render. This does not establish offline cold-start acceptance.
- Forced browser proxy failure: native failure detected, retry logged, proxy restored exactly to its prior settings, page recovered. Old JavaScript probe timeout count=0 in the inspected v43 window. No native crash markers observed there. Browser recovery test is narrower than full Internet/MQTT outage testing.
- A sampled web-load frame was white; a subsequent screenshot rendered the clock. Visual loading/transitions remain an open acceptance issue. Neither screenshot sampling nor previous frame counters establishes smooth 1080p video.
- Configuration revision remains 0 with no per-setting hardware acknowledgement yet. Automatic-update setting is not true; the updater gate therefore remains disabled. No update helper provisioning or production feed promotion was performed.
- Connected SignageX MCP lookup returned no player for the known Byte ID; this task has not established CMS live-view/controller handover or settings acceptance for the combined build.

### Exact lab rollback

On the Byte, restore the previous service and path override; leave current application state in place:

```sh
systemctl --user stop signagex-player
cp ~/signagex-diagnostics/pre-v43/signagex-player.service ~/.config/systemd/user/signagex-player.service
cp ~/signagex-diagnostics/pre-v43/validated-build.conf ~/.config/systemd/user/signagex-player.service.d/validated-build.conf
systemctl --user daemon-reload
systemctl --user start signagex-player
systemctl --user show signagex-player -p MainPID -p NRestarts
```

This returns execution to the retained v40 bundle. Preference backup is private recovery material, not something to publish or restore routinely over newer state. Root-installed upgrades, destructive updater rollback, boot after power loss, cold offline startup, full CMS controls, audio listening and 24-hour soak remain unvalidated. Historical review status at v43: player PR51 and CMS PR535 were drafts. See the current update below.


## Current acceptance update — v50, 2026-11-02

This section supersedes historical v40/v43 status above. Owner names below refer to responsible roles; hardware acceptance is not implied by implementation completion.

| Area | Owner | Status | Validation evidence / remaining work |
| --- | --- | --- | --- |
| Browser recovery and page paint gate | Linux player | Implemented; bounded Byte validation passed on v46 | Native main-frame failure recovery; last-good-frame gate; C++ sanitizer checks. Proxy fault restored cleanly. No JavaScript polling health probes. |
| Configuration via production CMS | CMS/backend + Linux | Four live settings passed | Org-scoped ownership fix is deployed. Byte revision 1 acknowledged volume 35, mute true, brightness 90/manual and touch feedback true. wpctl and xrandr independently confirmed volume/mute/brightness. Revision 2 restored volume 100, unmuted, brightness 100/manual, touch feedback false; all acknowledged applied. |
| CMS uptime | CMS | Merged and deployed | PR535, main 6f000f94166d22240e0fc4fa766b0abdd276e9a0; both Vercel checks passed; 25 focused tests and TypeScript passed. |
| Backend ownership/configuration | Backend | Production deployment passed | Run 41545021288; API 2/2 and worker 1/1 use dafb983. Integrates upstream main e0623ab ownership fix while preserving the already-running Android pilot. Previous image bae39a0 retained as rollout rollback reference. |
| Cold offline player start | Linux QA | Passed on v46 | Player-only systemd AF_UNIX restriction denied Internet sockets; host/SSH networking stayed available. Fresh health, retained pairing and campaign, screenshot shows cached content. Restriction removed and normal startup verified. This is not a whole-machine offline boot. Report: ~/signagex-diagnostics/v46-offline-start/report.json. |
| Remote control | Linux QA | Partial hardware acceptance | v43 production live view, Home and Back acknowledged (412/363 ms); reconnect observed. Epoch/observer/handover/geometry regression tests implemented. Full simultaneous-viewer physical acceptance still open. |
| Hardware audio/display adapters | Linux QA | Adapter checks passed | Volume, mute, brightness and reversible rotation tested; speaker-test completed. Listener confirmation of audible output remains open. |
| Video | Linux + hardware QA | Implemented; visual acceptance open | Duplicate decoder removed, callback generation fenced, Intel full driver retained, optional render limit preserved. Earlier user reported 1080p stutter and 720p improvement; do not claim smooth 1080p acceptance. |
| Updater/startup contracts | Linux | Implemented and regression tested | Debian build-name normalization, fresh health verification, interrupted-update rollback fixtures, relocated user-service paths and quoting. Root-installed upgrade/reboot acceptance needs local administrator step. Automatic updates remain OFF. |
| Latest amd64 package | Linux CI | Built and deployed to lab user bundle | Source 658cb54; run 41545466100 passed. signagex-player_v50_amd64.deb SHA256 9556b4345481921260989ef9cb377ff9a26bd3c94034c9800dbf53293dee6fd3 matched on Mac and Byte. Fresh v50 health PID43574, cached campaign unchanged. |
| Latest ARM64 package | Linux CI | Native build running | Run 41545469815; record final result before declaring this combined build ready for Pi hardware testing. Existing Pi release work is separate and untouched. |
| 24-hour stability | Linux QA | RUNNING, not passed | Unit signagex-soak-v50; private report ~/signagex-diagnostics/v50-24h-soak/report.json. Tracks health, restart/PID changes, resource usage and error markers without storing raw payloads. |
| Internal OS package and boot/reboot | Device administrator + Linux QA | Pending local administrator action | System dpkg remains v25; v50 currently runs as a supervised extracted bundle. Prepared finish-byte-setup.sh verifies and installs v50 and provisions limited reboot/update groups; no automatic reboot or auto-update enablement. |

Additional implementation f7c2984 adds page-frame gating, updater/startup/telemetry and controller fencing tests; 863341b/555cb18 add the bounded soak runner and empty-journal handling. Merge 658cb54 retains upstream Pi logging/recovery work and avoids competing CEF patch pipelines mutating the shared dependency cache.

v50 rollback: stop the user service, restore ~/signagex-diagnostics/pre-v50/validated-build.conf to ~/.config/systemd/user/signagex-player.service.d/validated-build.conf, daemon-reload and start. The retained v46 bundle is the previous execution target; preserve current pairing/cache. No release-feed promotion is performed by this validation update.
