# SignageX Chromium Player

A Yodeck-style signage player: a Node/Express server + a plain-JS frontend, meant to be
displayed in a Chromium kiosk window. Shows a pairing-code screen until paired with the
SignageX dashboard, then plays content pushed over MQTT.

Reuses the same backend contract as the Flutter app in this repo (`lib/view_models/mqtt_view_model.dart`,
`lib/services/mqtt_client_service.dart`):

- Pairing: `POST https://stage.signagexai.com/v1/player/connection/` with `{platform, uuid}`,
  polled every 5s until the response has `paired: true`.
- Content: MQTT over WebSocket at `wss://signagexai.com:443/mqtt`, topic = the player code.

## Setup

```
npm install
```

## Run

```
npm start          # server only, then open http://localhost:5757 in any browser
npm run kiosk       # starts the server AND launches Chrome/Chromium in kiosk mode
```

Override the port with `PORT=xxxx`. `npm run kiosk` auto-detects Chrome on Windows/macOS/Linux;
set `CHROME_PATH` to override.

## Notes / things to verify against a live pairing

- `platform` sent to the backend defaults to `"windows"` (via `PLATFORM_ID` in `server.js`).
  Sending `"web"` gets rejected with `mac_addresses are required` — the backend doesn't have a
  browser-specific platform value yet. Worth checking with backend whether a real `"web"`/`"chromium"`
  platform should be added.
- The MQTT message → content mapping in `public/app.js` (`handleContentMessage`/`renderItem`) is a
  best-effort guess (looks for `items`/`playlist` arrays, `url`/`mediaUrl`/`content_url`/`src` fields,
  `type`/`contentType`/`mimeType`). It hasn't been checked against a real payload yet — once a screen
  is actually paired, open devtools and watch the `[mqtt] message on ...` console logs to confirm the
  real shape, then adjust `renderItem`/`handleContentMessage` accordingly.
- Proof-of-play (`maybeSendProofOfPlay`) only fires for items with `creative_url` or `ad_campaign_id`,
  mirroring the Flutter app's ad proof-of-play call — same caveat, unverified against real data.
- Device id is a random UUID persisted to `device.json` (gitignored) so the same browser instance
  keeps its pairing across restarts.
