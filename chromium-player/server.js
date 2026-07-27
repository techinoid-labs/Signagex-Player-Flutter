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

// Serve html2canvas for DOM screenshot capture (used by remote view).
app.use('/vendor/html2canvas', express.static(path.join(__dirname, 'node_modules/html2canvas/dist')));

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
      // Some backends return 4xx (e.g. 409 "player already exists") but still
      // include player_code and paired in the body — pass those through so the
      // UI can still display the pairing code and detect pairing state.
      if (data.player_code) {
        return res.json({
          playerCode: data.player_code,
          paired: data.paired ?? false,
          deviceId,
          raw: data,
        });
      }
      return res.status(502).json({ error: 'backend_error', status: response.status, data });
    }
    res.json({
      playerCode: data.player_code ?? null,
      paired: data.paired ?? false,
      deviceId,
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

// Proxies remote SVG/sticker assets through the server so the browser gets
// a clean image/svg+xml response without CORS issues. Also normalises
// relative Next.js paths (/_next/…, /static/…) to the full CMS origin —
// mirrors the logic in Flutter's StickerHtmlWidget._resolveSource().
app.get('/api/svg-proxy', async (req, res) => {
  let url = (req.query.url || '').trim();
  if (!url) return res.status(400).json({ error: 'missing url parameter' });

  // Normalise relative Next.js / static paths
  if ((url.startsWith('/_next') || url.startsWith('/static')) && !url.startsWith('http')) {
    url = `https://signagexai.com${url}`;
  }

  // SSRF guard: only allow http/https
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    return res.status(400).json({ error: 'invalid url scheme' });
  }

  try {
    const upstream = await fetch(url, {
      headers: { 'User-Agent': 'SignageX-ChromiumPlayer/1.0' },
    });
    if (!upstream.ok) {
      console.warn('[svg-proxy] upstream', upstream.status, url);
      return res.status(502).json({ error: 'upstream_error', status: upstream.status });
    }

    // Not every "sticker" asset is actually SVG -- some are raster PNG/JPG.
    // Reading everything as .text() and forcing Content-Type: image/svg+xml
    // corrupted raster bytes (UTF-8 decode of binary data is lossy) and then
    // re-served that corrupted string even to the client's <img> fallback,
    // so non-SVG stickers silently failed to render. Buffer the raw bytes,
    // sniff for real SVG (by upstream content-type OR a text prefix check
    // that's safe for binary because it just won't match), and pass
    // everything else through untouched with its real content-type.
    const buffer = Buffer.from(await upstream.arrayBuffer());
    const upstreamType = upstream.headers.get('content-type') || '';
    const sniffed = buffer.subarray(0, 256).toString('utf8').trimStart();
    const isSvg = upstreamType.includes('svg') || sniffed.startsWith('<svg') ||
      (sniffed.startsWith('<?xml') && sniffed.includes('<svg'));

    res.set('Content-Type', isSvg ? 'image/svg+xml; charset=utf-8' : (upstreamType || 'application/octet-stream'));
    res.set('Cache-Control', 'public, max-age=3600');
    res.send(buffer);
  } catch (err) {
    console.error('[svg-proxy] fetch failed', url, err.message);
    res.status(502).json({ error: 'fetch_failed', message: String(err) });
  }
});

app.listen(PORT, () => {
  console.log(`SignageX chromium-player server running at http://localhost:${PORT}`);
  console.log(`Device id: ${deviceId}`);
});
