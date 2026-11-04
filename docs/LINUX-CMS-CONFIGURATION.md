# Linux / Raspberry Pi CMS configuration

This change implements protocol version 1 across the configuration form, backend and Flutter Linux player. It is additive to content sync: saving settings is not a content-publication acknowledgement.

## Delivery and confirmation

The backend increments `configuration_revision` atomically and clears the previous result when writable settings are saved. It sends the complete desired settings with `action_setup_player`. The player serializes application, persists accepted values, rejects stale revisions, and publishes a non-retained QoS 1 `settings_applied` response containing the revision and per-setting `applied`, `failed`, `pending`, or `unsupported` results. A result for an older revision cannot overwrite the latest result.

`playerConfigurationStatus(player_code)` is an organization-scoped, read-only GraphQL query. The CMS polls it while the configuration panel is open. Applied settings collapse under a disclosure; errors and pending requirements stay visible. Capabilities are reported in `player_details`. Telemetry is not re-sent as editable configuration. Null scalar schema defaults mean no change; explicit false, zero and rotation "0" are applied. Null compound policies reset to their documented defaults.

A successful device result means the validated OS operation completed. Physical speaker/display output and all hardware-specific combinations still require acceptance testing.

## Implemented settings

- Launch on graphical login through the supervised systemd user service. Disabling this affects future logins, not the current session.
- Volume/mute through WirePlumber's default audio sink. Zero is preserved, mute does not overwrite volume, and volume timeout restores the prior level. Timeout is armed by a volume change.
- Software HDMI image brightness, normalized from CMS percentages; manual timeout returns to full brightness. Scheduled brightness has no manual timeout.
- X11 output rotation, deterministic primary-output selection, and display metadata refresh after settings application.
- Working hours: a black surface outside the configured windows; video/audio are paused or muted while management remains connected. Hidden playback does not submit ad proof-of-play.
- Scheduled reboot: weekday or daily plus a device-local time. A persisted occurrence key prevents duplicate execution across application restarts and repeated clock hours.
- Content-update spacing, Wi-Fi/wired route restrictions, download windows and data-saving mode. Restricted publication pushes are deferred durably. Cached playback remains available; data saving pauses new downloads and periodic resource reports, not MQTT management. Transfers check routes for the destination host. Restrictions govern transfer starts; an already-running transfer is not forcibly killed.
- Hide empty-content messages, local touch feedback, global transition disabling and a bounded, validated cached custom logo.
- Safe video mode selects FFmpeg software decoding on the next player start. The CMS reports this as pending until startup applies it.
- Managed update preference, with explicit administrator opt-in and a supported installed updater.

The legacy Android HTML5 WebView engine is unavailable on Linux and is explicitly reported as unsupported. HDMI image dimming does not control a physical panel's backlight.

## Schedule semantics

All windows use the device's configured local time zone. Day masks are Sunday-first (`1000000` means Sunday), matching the CMS. Ends are exclusive. Overnight windows belong to their starting day. Equal start/end means a full selected day. Empty windows are unrestricted. The first matching brightness window wins; outside the windows, the configured default brightness applies. The backend validates times, masks, modes and ranges before publishing.

Missed reboot times are skipped rather than causing an unexpected late reboot. Device-local clock changes are evaluated on the next scheduler tick; the persisted reboot occurrence prevents repeated execution of the same local occurrence.

## Triggers

The Linux runtime consumes the current snake_case `create_interactivity` payload, persists definitions, prepares image/video/audio assets into a bounded cache, and acknowledges definitions after media preparation. A policy-blocked preparation stays pending and is retried. Trigger activation refuses unprepared remote assets.

Touch regions (absolute and relative), keys, on-demand activation, specific times, recurrence, idle timeout, play/stop/enqueue/enqueue-and-play and on-top rendering are implemented. Trigger rendering reuses the campaign zone media player. Base video controllers are paused while a replacement trigger is visible, then resumed. Restrictions are evaluated before activation and while active. Nested restriction groups fail closed if malformed or too deep.

The local API binds only `127.0.0.1:1999`. It accepts authenticated, empty-body POST requests to `/v1/interactivity/<encoded-local-api-name>`. The bearer token is stored in `~/.local/share/signagex-player/control/api-token`, with a private directory and file permissions. It is never printed or sent to the CMS. There is no unauthenticated LAN listener. Applications needing another network topology require an explicitly configured gateway.

## Diagnostics and resources

Linux sends `resource_usage` samples with memory in MiB, disk in KiB, traffic in KiB per sample, CPU delta percentages, uptime in seconds and temperature in Celsius. Absent battery/GPS/connectivity measurements are omitted rather than fabricated.

Structured events use a bounded persistent spool. Web recovery and configuration failures reach CMS events. The event-loop monitor reports suspected stalls; the supervised unit uses a watchdog. Native crash journal entries are collected when available after restart. Existing debug-log upload is implemented for Linux and uses the existing player identity endpoint, not a release upload secret.

Version telemetry uses `APP_BUILD_ID`. CI uses a checked-in Linux dependency manifest and overrides with `flutter pub get --enforce-lockfile` so package resolution is reproducible.

## Managed updater

The root-owned, argument-free helper accepts only the packaged HTTPS manifest channel and expected package/architecture. It validates redirects, download host, checksum and package identity/version, creates a rollback installer, installs the candidate, and checks the new player's event-loop health file. Failure rolls back. A boot recovery unit handles an interrupted installation. Download size, disk space and concurrent updater locking are bounded.

ARM64 release metadata uses platform `linux-arm64`. Publish the exact Debian package version from `dpkg-deb -f <package> Version`; it must match the manifest version. Merely generating a GitHub artifact does not publish this feed.

Install the package and supervised user startup, then explicitly enable unattended update permission as an administrator:

```sh
sudo /opt/signagex-player/kiosk/enable-managed-updates.sh arsil
```

The player user must sign out and back in to acquire the new group before enabling the CMS preference. Installation alone grants no unattended root update access. Production and staging packages are mutually exclusive; their manifests and service executable paths are generated for the correct channel. Debian 13 dependencies use `polkitd` alternatives.

## Rollout order and acceptance

1. Deploy backend schema, validation, revision persistence, acknowledgement routing and configuration-status query.
2. Deploy the frontend confirmation panel and corrected controls.
3. Build a complete native ARM64 release from this source, inspect checksums/build identity and install the exact package on a test Pi. Configure supervised graphical startup. Do not describe a Dart AOT overlay as a complete native release.
4. Verify each setting from CMS save through device acknowledgement and physical result, including persistence across restart/reboot. Restore the original configuration after acceptance.
5. Test offline/reconnect, overnight/DST boundaries, simultaneous volume/mute/brightness changes, rotated input, trigger media readiness, route restrictions, permission failures and the updater's real install/rollback path.
6. Complete sustained playback and power-loss tests on a reliable power supply before fleet rollout.

Implementation verification includes Dart policy/device-adapter/trigger/cache tests, backend ownership/revision/validation tests, frontend confirmation tests, updater policy tests and production/staging package metadata fixtures. Those checks do not replace physical acceptance. The live Pi remains on the previously tested recovery build until the complete rollout is performed.

## Secure remote view (CMS protocol 2)

Linux publishes a persisted RSA device public identity on `<code>/remote/v2/hello`.
The unprivileged Python X11 adapter verifies the packaged production signing
public key, decrypts server commands, fences persisted revisions and leases,
and encrypts/signs frames and receipts using the existing CMS protocol. Identity
and revision files are private and never sent to the CMS. Retained, unsigned,
expired and stale-frame input is rejected; legacy unsigned remote commands are
ignored on Linux. A server signing-key rotation requires updating the packaged
public key. Staging must use its own matching signing identity before remote
view can be advertised there.

Supported controls are normalized taps, drags, long press, literal text typing,
Back, focus/resume, quality selection and confirmed supervised app restart.
Device reboot is advertised as unavailable in the secure session; the existing
CMS management reboot is separate. Frames include actual geometry, foreground
state and capture time. They stop at lease expiry, unpair/stop or disconnection.
The adapter requires X11, scrot, xdotool, Python cryptography and Pillow; Debian
packaging installs these dependencies. This does not provide Wayland capture.
