const express = require('express');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const PORT = process.env.PORT || 5757;
const BACKEND_BASE = process.env.BACKEND_BASE || 'https://stage.signagexai.com/v1/';
// Backend rejects platform "web" (and anything else it doesn't recognize)
// with "mac_addresses are required" -- only android/ios/windows/linux are
// accepted today. Defaulting to "windows" since it only needs a uuid, same
// as this player sends. Override via PLATFORM_ID if backend adds real
// support for a browser-based platform value.
const PLATFORM_ID = process.env.PLATFORM_ID || 'windows';

const DEVICE_FILE = path.join(__dirname, 'device.json');

function getDeviceId() {
  if (fs.existsSync(DEVICE_FILE)) {
    try {
      const { uuid } = JSON.parse(fs.readFileSync(DEVICE_FILE, 'utf8'));
      if (uuid) return uuid;
    } catch (_) {
      // fall through and regenerate
    }
  }
  const uuid = crypto.randomUUID();
  fs.writeFileSync(DEVICE_FILE, JSON.stringify({ uuid }, null, 2));
  return uuid;
}

const deviceId = getDeviceId();

const app = express();
app.use(express.json());

// Serve the mqtt.js browser bundle straight from node_modules so the
// frontend can talk to the MQTT-over-WSS broker directly.
app.use('/vendor/mqtt', express.static(path.join(__dirname, 'node_modules/mqtt/dist')));

app.use(express.static(path.join(__dirname, 'public')));

// Proxied so the pairing call happens server-side (no CORS, no exposed
// backend details to the page source).
app.get('/api/pair-status', async (req, res) => {
  try {
    const response = await fetch(`${BACKEND_BASE}player/connection/`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ platform: PLATFORM_ID, uuid: deviceId }),
    });
    const data = await response.json();
    if (!response.ok) {
      console.error('[pair-status] backend error', response.status, data);
      return res.status(502).json({ error: 'backend_error', status: response.status, data });
    }
    res.json({
      playerCode: data.player_code ?? null,
      paired: data.paired ?? false,
      raw: data,
    });
  } catch (err) {
    console.error('[pair-status] request failed', err);
    res.status(502).json({ error: 'request_failed', message: String(err) });
  }
});

app.post('/api/proof-of-play', async (req, res) => {
  try {
    const response = await fetch(`${BACKEND_BASE}player/ad-campaign-proof-of-play`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body),
    });
    const data = await response.json().catch(() => ({}));
    res.status(response.status).json(data);
  } catch (err) {
    console.error('[proof-of-play] request failed', err);
    res.status(502).json({ error: 'request_failed', message: String(err) });
  }
});

app.listen(PORT, () => {
  console.log(`SignageX chromium-player server running at http://localhost:${PORT}`);
  console.log(`Device id: ${deviceId}`);
});
