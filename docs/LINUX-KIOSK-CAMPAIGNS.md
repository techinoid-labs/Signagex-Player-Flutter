# Kiosk campaigns on Linux

Interactive touch journeys built in Kiosk Studio (CMS `/campaign/kiosk`). The
backend contract is `signageX-backend/docs/KIOSK_CAMPAIGN_CONTRACT.md`.

## How it works

| Piece | Where |
|---|---|
| Messages, schedules, download, cache, swaps, health | `lib/services/linux_kiosk_campaign.dart` |
| Full-screen browser over signage | `lib/widgets/linux_kiosk_surface.dart` |
| Topic routing | `lib/services/mqtt_client_service.dart` (`/kiosk` → `onKioskMessageReceived`) |
| Subscription | `lib/view_models/mqtt_view_model.dart` `subsibeMessage` (Linux only) |
| Restart resume | `lib/main.dart` (`KioskCampaignService.instance.restore()`) |

1. Once paired the player subscribes to the retained topic `{playerCode}/kiosk` (QoS 1).
2. `kiosk_schedule` lists **every kiosk campaign assigned to this screen**
   (directly or through a screen group), each with a schedule:
   `{startDate, endDate, startTime, endTime, days}` plus `data.time_zone`.
   - Empty fields mean no limit (no dates = every date, no days = every day,
     no times = all day). Days are 0 = Sunday … 6 = Saturday.
   - An end time before the start time runs past midnight and belongs to the
     day it starts: "Fri 22:00–02:00" covers Saturday 01:30. End times are
     exclusive, dates inclusive.
   - Read on the **screen's clock** in `time_zone` (its current offset comes
     from `date +%z` with `TZ` set, so daylight saving is followed); an
     unknown zone uses the device's own local time.
   - An empty list means no kiosk: back to signage. The older
     `publish_kiosk_campaign` (one campaign, always on) and
     `clear_kiosk_campaign` (empty) are still understood.
   - Every scheduled version is downloaded (`data.url`, 3 retries, 30 s
     timeouts, max 10 MB), checked (`version_id`, `document.schemaVersion`)
     and cached in `~/.local/share/signagex-player/kiosk/`: `schedule.json`
     and `docs/<version>.json` (written to `.part` and renamed). Documents
     of campaigns no longer scheduled are deleted. A failed download keeps
     what is running and retries every minute.
   - The player re-checks every 5 s which campaign is due (so window edges,
     clock and time-zone changes are picked up) and logs one line when that
     changes, e.g. `schedule: 2 campaign(s); now showing Breakfast v3
     (Mon–Fri 06:00–11:00); next change 11:00` or `nothing scheduled now;
     signage; next change Mon 06:00`.
   - If two campaigns are due at once (the CMS prevents this), one assigned to
     the screen beats one from a group, then the most recently published.
3. The kiosk covers scheduled signage: a full-screen CEF browser on
   `data.player_url` (the CMS `/kiosk-play` page). If the message has no
   `player_url`, the player builds `{frontend}/kiosk-play?runtime=<url>` from
   `kioskFrontendBase` in `lib/utils/constants.dart`. Signage keeps running
   offstage underneath, the mouse cursor is hidden over the kiosk.
4. The page reports its state in its document title: `sxk:loading|ready|session|idle|error`.
   - A **different campaign or version** (a window opening or closing, a new
     publish) is applied only when the page is not in `session`.
     After 15 minutes of one session the player calls
     `window.__sxKioskEndSession()`; if the page still reports `session` 60 s
     later the swap happens anyway.
   - The **same version** published again does nothing.
   - **No campaign due** (a window ends, or the screen was unpublished) waits
     for the session to end, posts `{state:'idle'}` for the version it leaves
     and returns to scheduled signage. An empty schedule also removes the cache.
   - While the page has fallen back to signage (below), changes apply at once:
     nobody can be in a session.
5. Health: a load failure, `sxk:error`, or no state for 60 s reloads the page
   (5 s, 10 s). After 3 failures the player shows scheduled signage for 2
   minutes, then tries the kiosk again. Each failure also posts
   `{state:'error'}` to `/v1/kiosk-runtime/{version}/status?player={code}`.
6. After a restart the cached schedule is evaluated immediately, before MQTT
   reconnects, so the campaign due now shows (a cache from before schedules
   reads as one always-on campaign). The `/kiosk-play` page itself needs the network to load; while
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

### Schedules

Use two kiosk campaigns, A and B, and one lab screen. Set the windows a few
minutes ahead so the edges can be watched.

| # | Do | Expect |
|---|---|---|
| S1 | Schedule A 10:00–10:05 and B 10:05–10:10 on the screen | A at 10:00, B at 10:05, signage at 10:10; log shows each `now showing` and `next change` |
| S2 | Be in a session (tap through) when A's window ends | A stays until you stop; then B (or signage); log `switches once the session ends` |
| S3 | Overnight: A 23:58–00:03 | Shows across midnight, ends 00:03 |
| S4 | A on weekdays only, test on a Saturday (or set today's day off) | Signage; log `nothing scheduled now` with the next weekday start |
| S5 | Date range ending yesterday / starting tomorrow | Signage until the start date |
| S6 | Unpublish A from this screen only (B stays) | A leaves after the session; B shows in its window; A's document gone from `docs/` |
| S7 | Unpublish everything | Signage; `~/.local/share/signagex-player/kiosk` removed |
| S8 | Mid-window: disconnect the network, restart the app | The campaign due now shows again from the cache (page load needs network: see 9) |
| S9 | Change the screen's time zone in the CMS (or `timedatectl set-timezone` with no zone in the message) | Within 5 s the campaign due on the new clock shows |
| S10 | Add the screen's group to campaign C at a time that clashes with A | The CMS warns before publishing; the screen never shows two at once |

Record the player build, campaign version and results in `LINUX-RELEASES.md`.
