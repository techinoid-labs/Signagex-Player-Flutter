(function () {
  const MQTT_URL = 'wss://signagexai.com:443/mqtt';
  const PAIR_POLL_MS = 5000;
  const DEFAULT_ITEM_DURATION_MS = 8000;

  const pairingScreen = document.getElementById('pairing-screen');
  const playerScreen = document.getElementById('player-screen');
  const pairingCodeEl = document.getElementById('pairing-code');
  const pairingStatusEl = document.getElementById('pairing-status');
  const contentRoot = document.getElementById('content-root');

  let paired = false;
  let mqttClient = null;
  let playlist = [];
  let playIndex = 0;
  let advanceTimer = null;

  async function pollPairStatus() {
    if (paired) return;
    try {
      const res = await fetch('/api/pair-status');
      const data = await res.json();

      if (data.playerCode) {
        pairingCodeEl.textContent = data.playerCode;
      }

      if (data.paired) {
        pairingStatusEl.textContent = 'Paired! Starting player…';
        paired = true;
        showPlayerScreen();
        connectMqtt(data.playerCode);
        return;
      }

      pairingStatusEl.textContent = 'Waiting for pairing…';
    } catch (err) {
      console.error('[pair-status] failed', err);
      pairingStatusEl.textContent = 'Could not reach server, retrying…';
    } finally {
      if (!paired) setTimeout(pollPairStatus, PAIR_POLL_MS);
    }
  }

  function showPlayerScreen() {
    pairingScreen.classList.add('hidden');
    playerScreen.classList.remove('hidden');
  }

  function connectMqtt(topic) {
    if (!topic) {
      console.error('No player code to subscribe with, cannot connect MQTT');
      return;
    }

    mqttClient = mqtt.connect(MQTT_URL, {
      reconnectPeriod: 3000,
      connectTimeout: 15000,
    });

    mqttClient.on('connect', () => {
      console.log('[mqtt] connected, subscribing to', topic);
      mqttClient.subscribe(topic, (err) => {
        if (err) console.error('[mqtt] subscribe failed', err);
      });
    });

    mqttClient.on('message', (recvTopic, payload) => {
      const raw = payload.toString();
      console.log('[mqtt] message on', recvTopic, raw);
      let data;
      try {
        data = JSON.parse(raw);
      } catch (err) {
        console.error('[mqtt] payload was not JSON', err);
        return;
      }
      handleContentMessage(data);
    });

    mqttClient.on('error', (err) => console.error('[mqtt] error', err));
    mqttClient.on('reconnect', () => console.log('[mqtt] reconnecting…'));
    mqttClient.on('close', () => console.log('[mqtt] connection closed'));
  }

  // Best-effort normalizer: the exact payload shape hasn't been confirmed
  // against a live MQTT message yet, so this accepts a few common shapes
  // and logs anything it can't recognize instead of throwing.
  function handleContentMessage(data) {
    let items = null;

    if (Array.isArray(data)) {
      items = data;
    } else if (Array.isArray(data.items)) {
      items = data.items;
    } else if (Array.isArray(data.playlist)) {
      items = data.playlist;
    } else if (data.url || data.mediaUrl || data.content_url || data.src) {
      items = [data];
    }

    if (!items || items.length === 0) {
      console.warn('[content] message did not contain a recognizable playlist/item', data);
      return;
    }

    playlist = items;
    playIndex = 0;
    playCurrentItem();
  }

  function playCurrentItem() {
    clearTimeout(advanceTimer);
    if (playlist.length === 0) return;

    const item = playlist[playIndex];
    renderItem(item);

    const durationMs = Number(item.duration_ms || (item.duration ? item.duration * 1000 : 0)) || DEFAULT_ITEM_DURATION_MS;
    advanceTimer = setTimeout(() => {
      playIndex = (playIndex + 1) % playlist.length;
      playCurrentItem();
    }, durationMs);

    maybeSendProofOfPlay(item);
  }

  function renderItem(item) {
    const url = item.url || item.mediaUrl || item.content_url || item.src;
    const type = (item.type || item.contentType || item.mimeType || guessTypeFromUrl(url) || 'image').toLowerCase();

    contentRoot.innerHTML = '';
    if (!url) {
      console.warn('[content] item had no url', item);
      return;
    }

    let el;
    if (type.includes('video')) {
      el = document.createElement('video');
      el.src = url;
      el.autoplay = true;
      el.muted = true;
      el.loop = false;
    } else if (type.includes('web') || type.includes('html') || type.includes('iframe')) {
      el = document.createElement('iframe');
      el.src = url;
    } else {
      el = document.createElement('img');
      el.src = url;
    }
    contentRoot.appendChild(el);
  }

  function guessTypeFromUrl(url) {
    if (!url) return null;
    if (/\.(mp4|webm|mov)$/i.test(url)) return 'video';
    if (/\.(jpg|jpeg|png|gif|webp)$/i.test(url)) return 'image';
    if (/^https?:\/\//i.test(url)) return 'webpage';
    return null;
  }

  function maybeSendProofOfPlay(item) {
    if (!item.creative_url && !item.ad_campaign_id) return; // not an ad item
    fetch('/api/proof-of-play', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(item),
    }).catch((err) => console.error('[proof-of-play] failed', err));
  }

  pollPairStatus();
})();
