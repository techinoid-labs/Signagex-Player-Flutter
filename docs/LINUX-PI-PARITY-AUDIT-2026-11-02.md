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

No new production promotion is authorized by this audit. No full Linux parity or overnight stability claim is made. Hardware acceptance of the combined build remains open.
