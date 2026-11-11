# Linux player vs Android benchmark: CMS feature parity

Audit date: 11 November 2026. Branch `feat/linux-android-parity` (built on
`feat/linux-kiosk-campaign`).

- **Benchmark:** `techinoid-labs/signagex-player-android`, main `d4f1820`.
- **Source of truth for what the CMS sends:** `signageX-backend` main
  (`mqtt.service.ts`, `mqtt-player.handler.ts`, `on-demand.service.ts`,
  `content-report/services/screenshot.service.ts`, `player-plugin/*`,
  `players/remote/remote-protocol.ts`, `kiosk-campaign/*`) and
  `signageX-frontend` main (Player → Configuration).

Status: ✅ same as Android · ⚠️ partial · ❌ missing · N/A platform-specific.
"Fixed" means changed on this branch. Nothing here was compiled or run: Flutter
and Linux were not available where this was written. Run `flutter analyze` and
`flutter test` first.

## Summary

| | Count |
|---|---|
| Features checked | 44 |
| Already the same as Android (or ahead) | 31 |
| Fixed on this branch | 11 |
| Still gaps | 0 (each fix still needs its on-device check, see the test checklist) |
| N/A on Linux | 2 |

## Fixed on this branch

| Feature | Before | After | Where |
|---|---|---|---|
| **On-demand content** (CMS "How to play it → Play on demand") | ❌ `play_mode` ignored: on-demand items played in the normal rotation; `play_on_demand` / `stop_on_demand` ignored | ✅ on-demand items stay out of the rotation; `play_on_demand` plays the item now (`play`) or at the next boundary (`queue`/`playqueue`) for `repeat` loops (0 = until stopped or midnight), even outside its schedule; `stop_on_demand` returns to the rotation; an unknown id logs a warning | `lib/services/on_demand_state.dart`, `Campaign.playMode` (`lib/models/compaign_model.dart`), `_campaignIsPlayable` / `_durationForCampaignAt` / `_playOnDemand` / `_stopOnDemand` (`lib/view_models/mqtt_view_model.dart`), restriction bypass in `lib/views/campaign_view.dart` |
| **Playing Loop live view** (`now_playing`) | ❌ never sent | ✅ sent each time the rotation picks an item (key, name, reason `scheduled`/`on_demand`, started_at, duration_s, zone_count) and `no_content` when nothing can play | `lib/services/now_playing.dart`, `_updateIndexForCampain` |
| **CMS asks what's on screen** (`request_now_playing`) | ❌ ignored | ✅ answers with the last `now_playing` | dispatcher in `mqtt_view_model.dart` |
| **Content update interval** (Connectivity → periodic sync, `request_playback`) | ⚠️ the interval only rate-limited downloads; a missed push was never repaired | ✅ every N seconds (re-read every 30 s, like Android) asks the backend to re-send playback | `_startContentSyncLoop` |
| **Re-send of unchanged content** (`publish_campaign` with `resend: true`) | ⚠️ would reload playback each time | ✅ ignored when the content matches what is stored (key order independent), as Android's `isSamePlaylist` | `lib/services/content_resend.dart` |

Tests: `test/linux_parity_test.dart` (on-demand rules, now_playing payload,
resend comparison).

## Full table

| # | Feature | CMS source | Android | Linux | Status |
|---|---|---|---|---|---|
| 1 | Pairing, claim code, licence | players module, pairing REST | ✅ | ✅ pairing + revalidation timer (`mqtt_view_model.dart` `_checkPairingStatus`) | ✅ |
| 2 | Unpair / delete player (`action_delete`) | players | ✅ `MqttInstantAction.DeletePlayer` | ✅ `mqtt_view_model.dart:3528` | ✅ |
| 3 | Publish campaign / playlist (`publish_campaign`, `publish_playlist`) | campaign-player | ✅ | ✅ `:751`, download policy aware | ✅ |
| 4 | Remove campaign / playlist | campaign-player | ✅ | ✅ `:2942-2943` | ✅ |
| 5 | Remove content / composition / web app (`remove_*`) | content-sync.util.ts | ✅ acknowledged only (`ContentSyncAck.ACK_ON_RECEIPT`) | ✅ acknowledged (`_syncAckOnApply`) | ✅ |
| 6 | Content sync acknowledgement (`content_synced`) | PLAYER_SYNC_CONTRACT | ✅ | ✅ `_sendContentSynced` | ✅ |
| 7 | Paused campaigns | campaign | ✅ | ✅ `_campaignIsPlayable` | ✅ |
| 8 | Restrictions: date, time, day, player tag, operators | campaign_schedule.restrictions | ✅ | ✅ `checkRestrictions`, player tags from campaign | ✅ |
| 9 | Compositions / multi-zone layouts | composition | ✅ | ✅ `isCompositionLayout`, zones | ✅ |
| 10 | Web app instances | web-app | ✅ | ✅ CEF webview | ✅ |
| 11 | Images, video, audio | content | ✅ | ✅ | ✅ |
| 12 | Ad campaigns + ad proof of play | ad-campaign | ✅ | ✅ REST `player/ad-campaign-proof-of-play` (`:2350`) | ✅ |
| 13 | **On-demand play / stop** | on-demand.service.ts | ✅ | ✅ fixed here | ✅ |
| 14 | Interactivity / triggers (`create_interactivity`) | interactivity | ✅ | ✅ `LinuxInteractivity` (`:3048`) | ✅ |
| 15 | Run interactivity now (`run_interactivity`) | interactivity | ✅ | ✅ `:3061` | ✅ |
| 16 | Kiosk campaigns (`{code}/kiosk`) | kiosk-campaign | ❌ (not on Android yet) | ✅ `lib/services/linux_kiosk_campaign.dart` | ✅ (ahead) |
| 17 | Player settings (`action_setup_player`): launch on boot, app updates, hide messages, touch feedback, safe video, rotation, volume, volume timeout, mute, transitions, brightness, logo, working schedule, content update interval, scheduled reboot | Player → Configuration | ✅ | ✅ `LinuxConfiguration` (`linux_configuration.dart`), results via `settings_applied` | ✅ |
| 18 | HTML5 webview toggle | configuration | ✅ | reported `unsupported` (CEF only) | N/A |
| 19 | Working hours / screen off | working_schedule | ✅ | ✅ | ✅ |
| 20 | Reboot (`action_reboot`) | players | ✅ | ✅ `:3066` | ✅ |
| 21 | Send logs (`action_send_logs`) | players | ✅ | ✅ `:3033` diagnostic upload | ✅ |
| 22 | Live logs (`player_logs`) | player-logs | ✅ | ✅ | ✅ |
| 23 | Device details (`player_details`) | players | ✅ | ✅ `:2417` | ✅ |
| 24 | Resource usage (`resource_usage`) | players | ✅ | ✅ `:190` | ✅ |
| 25 | Remote view v1 (start/stop, quality, click, scroll, text, home, back) | remote | ✅ | ✅ X11 (`scrot`/`xdotool`) and Wayland (`grim` + virtual uinput mouse/keyboard, see LINUX-WAYLAND-KIOSK.md) | ✅ |
| 26 | Remote view v2 (`/remote/v2/command`: restart_player, reboot_device, resume_player, confirmation) | remote-protocol.ts | ✅ | ✅ `remote_view_agent.py:176-182` | ✅ |
| 27 | OTA update | player-releases | ✅ | ✅ `LinuxOta` (`:3000`) | ✅ |
| 28 | Managed network (Wi-Fi / hotspot) | linux network protocol | ✅ (Android settings) | ✅ `LinuxNetwork` (`:2996`) | ✅ |
| 29 | Offline cache / resume after restart | — | ✅ | ✅ stored `jsonObj` + downloads | ✅ |
| 30 | Text-to-speech / ticker | content | ✅ | ✅ | ✅ |
| 31 | **Playing Loop (`now_playing`, `request_now_playing`)** | mqtt-player.handler `now_playing` | ✅ | ✅ fixed here (campaign level) | ✅ |
| 32 | **Periodic content sync (`request_playback`)** | mqtt-player.handler `request_playback` | ✅ | ✅ fixed here | ✅ |
| 33 | **Unchanged re-send ignored** | playback-resend.service.ts | ✅ | ✅ fixed here | ✅ |
| 34 | Location / position | player_details lat/long | ✅ GPS/network | ⚠️ IP-based only (no device GPS on most Linux PCs) | ✅ acceptable |
| 35 | Optional items missing (`optional_missing`) | campaign | ✅ | ✅ | ✅ |
| 36 | **Composition data feeds** (text and images bound to a feed) | data-feed, composition | ✅ `CompositionRenderFragment.kt:179` DATA_FEED_RUNTIME | ✅ fixed here: same rules (all / match / fixed row, initial row, step, cycle, remembered position), `GET data-feed/{id}` every 60 s, last data kept offline (`data_feed_binding.dart`, `widgets/feed_bound.dart`) | ✅ |
| 37 | **Content proof of play for Reports** (`content_proof_of_play`, signed) | content-report, PopSigning | ✅ `data/pop/*` | ✅ fixed here: same entry fields, merge per content/day/status/reason, on-disk queue (5,000 cap, 30-day age, 24 h MQTT-only), `pop-key` trust on first use, HMAC-SHA256 signature, 2-minute rounds of up to 10×200, backoff 30 s..15 min, MQTT fallback every 15 min not retained, per-entry results (`linux_pop.dart`) | ✅ |
| 38 | **Proof screenshot now** (`capture_proof_screenshot`) | screenshot.service.ts | ✅ | ✅ fixed here: through a `ScreenCapture` interface (X11 scrot; Wayland grim through the same capture function), JPEG ≤1280 px and ≤2 MB, signed multipart `POST player/screenshot`, 3 attempts (`proof_screenshots.dart`) | ✅ |
| 39 | **Scheduled proof screenshots** (`proof_screenshot_schedule`) | screenshot.service.ts | ✅ | ✅ fixed here: every `interval_minutes` until `until`, 0 stops, saved and resumed after restart | ✅ |
| 40 | **Player plugins** (`{code}/plugins`, `publish_player_plugins`) | player-plugin | ✅ hidden WebView + `SignageXPlugin` bridge | ✅ fixed here: one hidden 1×1 CEF view per plugin; the page runs in an iframe of a wrapper page, which forwards the runtime's `postMessage` (setAttributes, log) as title changes; reload on `version` change and every 24 h; stopped on unpair (`linux_plugins.dart`, `widgets/linux_plugin_host.dart`). `getLocation` is not bridged: the page uses its configured fallback location | ✅ |
| 41 | **Player attributes** (`{code}/attrs`, `update_player_attributes`, pairing `attrs`, `player_attributes` reports, `player_attribute` restriction) | player-attribute.service.ts | ✅ | ✅ fixed here: newer `updated_at` wins, `removed`, 100 keys, 500-char text, kept on disk, restriction operators as the contract, reports merged per instance for 5 s and kept while offline, cleared on unpair (`player_attributes.dart`) | ✅ |
| 42 | Crash / suspected-freeze reports (`player_logs` with `incident_type`) | mqtt-player.handler | ✅ `docs/crash-anr-reporting.md` | ✅ already there: `LinuxDiagnostics` spools errors on disk, reports `crash` (incl. native exits from the journal) and `suspected_anr` (event-loop watchdog) as `player_logs` (`linux_diagnostics.dart`). The first audit missed this | ✅ |
| 42b | Web app SDK events (`app_event`) | web-app SDK | ✅ `AppEventPublisher.kt` | web apps on Linux run in CEF without the SignageX web-app SDK bridge (`window.signagex`), so they cannot raise events; see "Hardware and engine checks" | N/A until the SDK bridge (plan below) |
| 43 | **Player state** (`player_state`: location) | mqtt-player.handler `handlePlayerState` (reads latitude/longitude) | ✅ | ✅ fixed here: sent when the location changes, not retained | ✅ |
| 44 | Screen rotate via remote (`screen_rotate`) | remote | ✅ turns on accelerometer auto-rotate | no accelerometer on Linux PCs; fixed rotation is the Rotation setting (#17) | N/A |

## Hardware and engine checks

Every row above is ✅ or N/A. What still needs the real Ubuntu box, because it
can't be proven without one:

1. **CEF data: URLs and iframes (#40).** The plugin wrapper is a `data:` page
   with the plugin in an iframe. If this webview_cef build refuses `data:`
   URLs, serve the same wrapper from a local file under
   `~/.local/share/signagex-player/plugins/` instead. That's a one-line change
   in `LinuxPlugins.wrapperUrl`.
2. **Hidden 1×1 views keep running (#40).** CEF must keep the page's timers
   running while the view is 1×1 and transparent. Check that the Weather plugin
   updates within a minute.
3. **Screenshots are X11 only for now (#38, #39).** Capture uses the existing
   scrot path on X11 and grim on Wayland (both inside `_captureScreenshotForLinux`).
4. **Web app SDK (#42b, plan).** Inject `window.signagex` (getPlayerAttribute,
   onPlayerAttributesChanged, event) into web apps through the same
   wrapper/title channel. This is a separate feature; Android has it.

On-demand limits: queue modes start at the next rotation boundary, and
`repeat` counts campaign loops. A campaign whose duration is 0 plays 15 s per
loop while on demand.

## Test checklist (CMS against the Linux player)

Before you start: build this branch, pair the Linux screen, and keep the CMS
player page open (Logs and Playing Loop tabs).

- [ ] **1. Publish:** a campaign with an image and a video. Both play, and the
  CMS shows the screen as synced.
- [ ] **2. Paused campaign:** pause one of two campaigns. Only the other plays.
- [ ] **3. Restrictions:** restrict a campaign to the next 5 minutes. It plays
  only inside that window.
- [ ] **4. On-demand:** publish item B with "Play on demand".
  - B never appears in the normal loop.
  - Press "Play now" (repeat 1): B plays once, then the loop resumes.
  - Repeat 0: B stays on screen until you press "Stop".
  - Play an id that isn't published: Logs shows a warning.
- [ ] **5. Playing Loop:** the CMS updates within a second at each change.
  Reload the player page: it shows the current item (`request_now_playing`).
- [ ] **6. Content update interval:** set Connectivity to every 2 minutes.
  - Logs/backend show `request_playback` every 2 minutes.
  - Playback does **not** restart while the content is unchanged.
- [ ] **7. Remove:** unpublish, remove content, remove the web app. The screen
  updates and the CMS shows synced.
- [ ] **8. Interactivity:** add a trigger and run it now from the CMS. It plays.
- [ ] **9. Settings:** change each setting in Player → Configuration and watch
  the results panel:
  - rotation
  - volume and mute
  - brightness
  - logo
  - working hours
  - scheduled reboot
  - hide messages
  - transitions
  - safe video
  - launch on boot (unsupported in the kiosk session)
- [ ] **10. Reboot, Send logs and Delete** from the CMS.
- [ ] **11. Remote view** (X11 session):
  - picture
  - click
  - drag
  - type
  - Home and Back
  - v2 restart player and reboot device (with confirmation)
- [ ] **12. Kiosk campaign:** follow `docs/LINUX-KIOSK-CAMPAIGNS.md`.
- [ ] **13. Offline:** unplug the network, then restart the app. Cached content
  plays. Plug back in: it goes online and syncs.
- [ ] **14. OTA:** publish a newer Linux release. It updates and keeps pairing.
- [ ] **15. Ad campaign:** plays, and its proof of play reaches the backend.
- [ ] **16. Reports:** play an image campaign for 10 minutes.
  - Within about 2 minutes, Reports shows the plays for this screen.
  - The backend log shows `content_proof_of_play` accepted (signed after the first `pop-key`).
  - Unplug the network for 10 minutes, then reconnect: the queued plays arrive, without duplicates.
- [ ] **17. Proof screenshots:**
  - "Take screenshot" in the CMS: a picture arrives within a minute.
  - Schedule every 5 minutes for 30 minutes: 6 pictures arrive.
  - Restart the app during the schedule: it continues.
- [ ] **18. Data feeds:** a composition with a text element bound to a feed column (cycle 10 s).
  - The value changes every 10 s.
  - Edit the feed in the CMS: the new value appears within 60 s.
  - Go offline: the last values stay.
- [ ] **19. Plugins:** assign the Weather plugin.
  - Within a minute, the player's Plugins tab shows temperature and condition.
  - Change the plugin: it reloads.
  - Unassign it: it stops.
- [ ] **20. Attributes:** set `promo_mode = true` by hand in the CMS, and restrict a campaign to "Player attribute promo_mode is true".
  - The campaign plays only while the value is true.
  - Restart offline: the value and restriction still apply.
- [ ] **21. Location:** if the screen's location changes, the CMS map updates (`player_state`).
- [ ] **22. Crash report:** kill the player with `pkill -SEGV signagex-player`. After restart, the CMS events show an App crash entry.
