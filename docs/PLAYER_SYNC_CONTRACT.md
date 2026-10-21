# Sync acknowledgement: what the player sends back after each push

**For:** the player teams (Android, Chrome/web, Mac, Linux, Windows)
**Channel:** MQTT, the screen's own topic `<player_code>`
**Status:** additive. The CMS already accepts it. A build that doesn't send it keeps working exactly as today.

---

## TL;DR

The CMS now shows a real sync state for every screen and player group:

- **Synced**: the screen confirmed the latest thing the CMS sent it.
- **Syncing**: sent less than 20 seconds ago, and no confirmation yet.
- **Sync Issue**: no confirmation after 20 seconds, or the screen reported a failure.

To get this right for your player, do **one new thing**. After you have handled a push (see the table below), publish one message:

```json
{
  "action": "content_synced",
  "status": "ok",
  "received_action": "publish_campaign",
  "sync_id": "<copy it from the push, only if the push had one>",
  "sender": "player"
}
```

Everything else stays as it is: the messages you receive, the messages you already send, and your existing log lines.

---

## The three rules that keep playback safe

These matter more than anything else in this document.

1. **Publish with `retain = false`.** The CMS keeps its playback message retained on `<player_code>`, which is how your screen gets its content back after a reconnect. A broker keeps only one retained message per topic. A retained `content_synced` would replace the playback message, and the screen would come back from its next reconnect with nothing to play.
2. **Never put `"online"` or `"offline"` in `status`.** The CMS treats any message with those values as a heartbeat. Use only `"ok"` or `"error"`.
3. **Ignore your own `content_synced` when it comes back to you.** You subscribe to `<player_code>`, so the broker hands you your own message too. This is the same as with `player_logs` today: if `action` is `content_synced`, do nothing.

---

## Which pushes to acknowledge

| You receive `action` | What it is | Acknowledge? |
|---|---|---|
| `publish_campaign` | Everything that changes playback: publish, edit, pause/play, restrictions, schedules, a group's content, data-feed refreshes. It is always the full playback state. | **Yes** |
| `remove_campaign` | A campaign was unpublished | **Yes** |
| `remove_playlist` | A playlist was unpublished | **Yes** |
| `remove_content` | A content item was unpublished | **Yes** |
| `remove_composition` | A composition was unpublished | **Yes** |
| `remove_web_app_instance` | A web app / widget was unpublished | **Yes** |
| `create_interactivity` | Triggers created, edited or deleted. It is always the screen's full trigger list. | **Yes** |
| `run_interactivity` | Run an on-demand trigger now (a command) | No |
| `action_setup_player`, `action_reboot`, `action_send_logs`, `action_delete`, `action_stop_player` | Device commands | No |

If you receive an action that is not in this table, don't acknowledge it.

---

## The message

Publish it on the topic `<player_code>` (the same topic you use for `player_logs`), with QoS 1 and **retain = false**.

| Field | Required | Value |
|---|---|---|
| `action` | yes | `"content_synced"` |
| `status` | no | `"ok"` (the default when missing) or `"error"` |
| `received_action` | yes | The `action` of the push you handled, for example `"publish_campaign"` or `"create_interactivity"`. The CMS uses it to tell content from triggers when there is no `sync_id`. |
| `sync_id` | only if the push had one | Copy the push's `sync_id` exactly. Leave the field out if the push had none. |
| `error` | with `"error"` | A short human-readable reason, up to 500 characters, for example `"download failed: video_12.mp4 (HTTP 404)"`. |
| `sender` | recommended | Whatever your build already uses for its own messages. Never `"signagex_web"`. |

Fields the CMS doesn't know are ignored. You may add your own, such as `player_time` or `app_version`.

### When to send it

- **After the push has been applied**, not when it arrives. For `publish_campaign`, that means the files it needs are downloaded and the new schedule is live. For a removal, the item is gone from the schedule. For `create_interactivity`, the new trigger list is active.
- **If applying takes longer than 20 seconds** (a large download), the CMS shows Sync Issue in the meantime. It changes to Synced as soon as your `ok` arrives. Late is fine. Never is not.
- **Send one acknowledgement per push.** Duplicates are harmless (the CMS ignores them), but don't send them in a loop.
- **If several pushes arrive close together,** acknowledge each one. With `sync_id`, each acknowledgement carries its own id.

### Failures

If you received the push but could not apply it, send:

```json
{ "action": "content_synced", "status": "error", "received_action": "publish_campaign",
  "error": "download failed: video_12.mp4 (HTTP 404)", "sender": "player" }
```

The screen shows Sync Issue. If a retry later succeeds, send `"status": "ok"` for the same push, and the screen changes to Synced. Once you have sent `ok` for a push, a later `error` about that same push is ignored.

### After a reconnect

On reconnect the broker gives you the retained playback message again, and when the screen comes online the CMS may also resend the current state. Handle and acknowledge these like any other push. Resends never carry a `sync_id`, so acknowledge them without one.

---

## `sync_id`: matching a reply to its push

The CMS can attach a `sync_id` (a UUID string) to every push in the "Yes" rows above. **It is switched off today** (`MQTT_SYNC_ID_ENABLED=false` on the backend). Until it is turned on, the pushes you receive are byte-for-byte what they are now.

Before it is switched on, every player build in use must:

1. **Ignore unknown fields in the messages it receives.** The only change to an incoming push is one extra top-level field, `sync_id`. If your parser rejects unknown fields (a strict schema, Kotlin serialization without `ignoreUnknownKeys`, a strict Codable model and so on), make it tolerant first, or the screen will drop the push.
2. **Copy `sync_id` back unchanged** in the `content_synced` for that push. Never reuse an id from an earlier message.

Why it helps: without an id, a late reply to an older push can mark a newer push as done. With an id, the CMS only accepts a reply for the push it names, and ignores replies to older ones.

Once every build has confirmed both points, the backend team turns the switch on, on stage first and then in production. Nothing else changes for you.

---

## What must not change

The CMS still reads these as the fallback for builds that don't send `content_synced`. Please keep them exactly as they are, with the same text and the same `action`:

- `player_status` heartbeats (`{"status":"online"}` / `{"status":"offline"}` on `<player_code>/player_status`)
- `player_logs`, especially the lines the CMS reads as acknowledgements: `Publish Campaign`, `Publish Playlist`, `Remove Campaign`, `Remove Playlist`, `Action Delete` and `Loaded N campaign(s)`
- `player_details`, `resource_usage`, `content_proof_of_play`

If a build sends both a log line and `content_synced`, that's fine. `content_synced` wins: an `error` replaces a log-line confirmation of the same push, and a later log line cannot hide an `error`.

---

## Per platform

| Player | Today | To do |
|---|---|---|
| **Android** | Logs `Loaded N campaign(s)` after loading, which the CMS reads as an acknowledgement of every content push. | Send `content_synced` after the download finishes, and also for `create_interactivity`. Report download failures as `"error"`. |
| **Chrome / web** | Varies by build. | Send `content_synced` after assets are cached or loaded. If the tab was closed when a push arrived, the retained message on reopening counts as the push: acknowledge it. |
| **Mac** | Not yet confirmed which log lines it sends. | Send `content_synced` for every "Yes" row. Until it does, removals it doesn't log in a recognised form show Sync Issue. |
| **Linux** | Not yet confirmed. | Same as Mac. |
| **Windows** | Not yet confirmed. | Same as Mac. |
| **All** | | Publish with retain = false; never use `online`/`offline` in `status`; ignore your own echo; ignore unknown incoming fields (needed before `sync_id`). |

Triggers: no player acknowledges `create_interactivity` today, so the CMS leaves triggers out of the sync state for every screen. A screen's trigger sync starts counting from the first trigger acknowledgement it sends.

---

## How to test on stage

1. Open the screen in **Players**. Its **Sync** column, Status tab and Information tab show the state.
2. Publish a campaign to it: **Syncing**, then **Synced** within seconds of your `ok`.
3. Pause and play it, edit a restriction, and unpublish it. Each one should go Syncing, then Synced.
4. Add, edit and delete a trigger. Once your build acknowledges triggers, each one goes Syncing, then Synced.
5. Make a download fail on purpose (a broken file URL) and send `"error"`: **Sync Issue**. Fix it and send `ok`: **Synced**.
6. Disconnect the screen, publish, then reconnect: it shows **Sync Issue** while offline, and **Synced** once it acknowledges after reconnecting.
7. After the reconnect, check that the screen still plays its content. This proves your `content_synced` is not retained.
8. Put the screen in a player group: the group shows the worst state of its screens.

---

## Reference: what the CMS does with it

- **Stored per screen** (playersettings): `content_change_at`, `content_change_id`, `content_sync_at`, `content_sync_source`, `content_sync_error_at`, `content_sync_error`, and the same `trigger_*` fields.
- **The 20-second window** is `CONTENT_SYNC_GRACE_MS` (backend `common/utils/content-sync.util.ts`, frontend `lib/contentSync.ts`).
- **A screen that has never acknowledged** anything on a channel is left out of that channel. When neither channel is known, the old answer applies: online = Synced, offline = Sync Issue.
- **Backend code:** `MqttService.publish` (stamps and `sync_id`), `MqttPlayerHandler` (`content_synced`) and `PlayerService.recordSyncAck`.
