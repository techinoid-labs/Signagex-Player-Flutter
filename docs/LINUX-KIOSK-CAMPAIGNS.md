# Kiosk campaigns on Linux

Interactive touch journeys built in Kiosk Studio (CMS `/campaign/kiosk`). The
backend contract is `signageX-backend/docs/KIOSK_CAMPAIGN_CONTRACT.md`.

## How it works

| Piece | Where |
|---|---|
| Messages, download, cache, version swap, health | `lib/services/linux_kiosk_campaign.dart` |
| Full-screen browser over signage | `lib/widgets/linux_kiosk_surface.dart` |
| Topic routing | `lib/services/mqtt_client_service.dart` (`/kiosk` → `onKioskMessageReceived`) |
| Subscription | `lib/view_models/mqtt_view_model.dart` `subsibeMessage` (Linux only) |
| Restart resume | `lib/main.dart` (`KioskCampaignService.instance.restore()`) |

1. Once paired the player subscribes to the retained topic `{playerCode}/kiosk` (QoS 1).
2. `publish_kiosk_campaign`: the player downloads `data.url` (3 retries, 30 s
   timeouts, max 10 MB), checks `version_id` and `document.schemaVersion`, and
   caches payload + document in `~/.local/share/signagex-player/kiosk/`
   (`current.json`, `previous.json`; written to `.part` and renamed). A failed
   download keeps the running version and retries every minute.
3. The kiosk covers scheduled signage: a full-screen CEF browser on
   `data.player_url` (the CMS `/kiosk-play` page). If the message has no
   `player_url`, the player builds `{frontend}/kiosk-play?runtime=<url>` from
   `kioskFrontendBase` in `lib/utils/constants.dart`. Signage keeps running
   offstage underneath, the mouse cursor is hidden over the kiosk.
4. The page reports its state in its document title: `sxk:loading|ready|session|idle|error`.
   - A **new version** is applied only when the page is not in `session`.
     After 15 minutes of one session the player calls
     `window.__sxKioskEndSession()`; if the page still reports `session` 60 s
     later the swap happens anyway.
   - The **same version** published again does nothing.
   - **`clear_kiosk_campaign`** waits for the session to end, removes the cache
     and returns to scheduled signage.
5. Health: a load failure, `sxk:error`, or no state for 60 s reloads the page
   (5 s, 10 s). After 3 failures the player shows scheduled signage for 2
   minutes, then tries the kiosk again. Each failure also posts
   `{state:'error'}` to `/v1/kiosk-runtime/{version}/status?player={code}`.
6. After a restart the cached campaign is shown immediately, before MQTT
   reconnects. The `/kiosk-play` page itself needs the network to load; while
   offline the reload/fallback cycle above applies.
7. Nothing a customer types is stored or logged by the player. Logs (debug log
   and diagnostics) name versions and states only.

Not done here: Epson/Zebra device connectors (payment, print and scan follow
each action's failure path until they exist).

## Run locally on a Linux machine

Ubuntu 22.04/24.04, **Ubuntu on Xorg** session, Flutter 3.27.4, clang 18:

```bash
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libnss3 libgbm1 libxss1
wget -qO llvm.sh https://apt.llvm.org/llvm.sh && chmod +x llvm.sh && sudo ./llvm.sh 18
export CC=clang-18 CXX=clang++-18
git checkout feat/linux-kiosk-campaign
cp linux/packaging/pubspec.lock pubspec.lock
cp linux/packaging/pubspec_overrides.yaml pubspec_overrides.yaml
flutter config --enable-linux-desktop
flutter pub get --enforce-lockfile
flutter test test/linux_kiosk_campaign_test.dart
flutter run -d linux --dart-define=APP_ENV=staging   # leave out APP_ENV for production
```

Pair the screen in the CMS of the same environment. Logs:
`find ~/.local/share -name signagex_debug.log` (lines tagged `Kiosk`).

## Lab test plan

Use a user with "Allow user to use kiosk campaigns" (sign in again after it is granted).

| # | Do | Expect |
|---|---|---|
| 1 | Publish a 3-screen kiosk campaign to the lab player | Within a few seconds the kiosk covers signage, cursor hidden; log `starting version 1` |
| 2 | Tap through every button, type in a text field | Touch lands on the right control; keyboard works; Back/Home work |
| 3 | Leave it alone past the idle time | Idle warning, then reset to home (`page idle`) |
| 4 | Start a session, publish version 2 from the CMS | Session is not interrupted; log `version 2 ready; waits`; after the session ends (idle) it switches |
| 5 | Publish version 3 while idle | Switches at once |
| 6 | Publish the same version again | Nothing changes |
| 7 | Mid-session, unpublish / clear | Customer finishes; then signage returns; `~/.local/share/signagex-player/kiosk` is empty |
| 8 | Publish, then restart the app (and reboot) | Kiosk comes back without waiting for MQTT |
| 9 | Unplug network, restart the app | Page can't load: reloads, then signage after 3 failures, kiosk again after 2 min once the network is back |
| 10 | Make the page fail (wrong frontend, or stop the frontend) | Same recovery as 9; CMS status shows `error` |
| 11 | Rotate the display (portrait), 1080p and 4K | Layout fits; taps still hit the controls |
| 12 | Interactivity triggers on another campaign | Still launch/stop when no kiosk is active |
| 13 | Leave it running overnight with repeated sessions | No memory growth, no stuck page |

Record the player build, campaign version and results in `LINUX-RELEASES.md`.
