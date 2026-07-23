(function () {
  const MQTT_URL = 'wss://signagexai.com:443/mqtt';
  const PAIR_POLL_MS = 5000;
  const DEFAULT_ITEM_DURATION_MS = 8000;

  const pairingScreen = document.getElementById('pairing-screen');
  const playerScreen = document.getElementById('player-screen');
  const pairingCodeEl = document.getElementById('pairing-code');
  const pairingStatusEl = document.getElementById('pairing-status');
  const contentRoot = document.getElementById('content-root');
  const noContentEl = document.getElementById('no-content');

  let paired = false;
  let mqttClient = null;
  let mqttTopic = null;
  let playlist = [];
  let playIndex = 0;
  let advanceTimer = null;

  async function pollPairStatus() {
    try {
      const res = await fetch('/api/pair-status');
      const data = await res.json();

      if (data.playerCode) {
        pairingCodeEl.textContent = data.playerCode;

        // Match the Flutter app: connect + subscribe + publish device info
        // as soon as we have a player_code, *before* pairing is confirmed.
        // The CMS/MQTT view only sees a device once it has published
        // something on its topic -- waiting for `paired` first meant we
        // never showed up as reachable.
        if (!mqttClient || mqttTopic !== data.playerCode) {
          connectMqtt(data.playerCode);
        }
      }

      if (data.paired && !paired) {
        pairingStatusEl.textContent = 'Paired! Starting player…';
        paired = true;
        showPlayerScreen();
      } else if (!data.paired) {
        pairingStatusEl.textContent = 'Waiting for pairing…';
      }
    } catch (err) {
      console.error('[pair-status] failed', err);
      pairingStatusEl.textContent = 'Could not reach server, retrying…';
    } finally {
      setTimeout(pollPairStatus, PAIR_POLL_MS);
    }
  }

  function showPlayerScreen() {
    pairingScreen.classList.add('hidden');
    playerScreen.classList.remove('hidden');
    if (playlist.length === 0) noContentEl.classList.remove('hidden');
  }

  function buildDeviceInfo(topic) {
    let timeZone = '';
    try {
      timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
    } catch (_) {}

    return {
      platform: 'windows',
      uuid: topic,
      sender: 'chromium_web',
      last_seen: new Date().toISOString(),
      device_model: navigator.userAgent,
      time_zone: timeZone,
      device_resolution: {
        resolution: `${window.screen.width}x${window.screen.height}`,
        density: window.devicePixelRatio || 1,
      },
    };
  }

  function connectMqtt(topic) {
    if (!topic) {
      console.error('No player code to subscribe with, cannot connect MQTT');
      return;
    }

    if (mqttClient) {
      mqttClient.end(true);
    }
    mqttTopic = topic;

    mqttClient = mqtt.connect(MQTT_URL, {
      reconnectPeriod: 3000,
      connectTimeout: 15000,
    });

    mqttClient.on('connect', () => {
      console.log('[mqtt] connected, subscribing to', topic);
      mqttClient.subscribe(topic, (err) => {
        if (err) {
          console.error('[mqtt] subscribe failed', err);
          return;
        }
        console.log('[mqtt] subscribed, publishing device info to register presence');
        mqttClient.publish(topic, JSON.stringify(buildDeviceInfo(topic)));
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

  // Real shape, confirmed from a live payload:
  // {action:"publish_campaign", sender:"signagex_web", data:{playerCampaigns:[
  //   {playback_type, campaign_id, campaign_name, is_paused, resolution:{width,height},
  //    campaign_settings:{transition,duration,loop}, zones:[{id,x,y,width,height,
  //    mediaItems:[{id, mediaType, mediaUrl, content_media_type, settings, schedule, ad_slot}]}]}
  // ]}}, or {action:"stop_remote_view", ...}.
  function handleContentMessage(data) {
    if (data.action === 'stop_remote_view') {
      console.log('[content] stop_remote_view received (no-op, remote view not implemented)');
      return;
    }

    if (data.action !== 'publish_campaign' || !data.data || !Array.isArray(data.data.playerCampaigns)) {
      console.warn('[content] unrecognized message shape', data);
      return;
    }

    const campaigns = data.data.playerCampaigns.filter((c) => !c.is_paused);
    if (campaigns.length === 0) {
      console.warn('[content] no active (non-paused) campaigns in payload', data);
      playlist = [];
      clearTimeout(advanceTimer);
      contentRoot.innerHTML = '';
      noContentEl.classList.remove('hidden');
      return;
    }

    playlist = campaigns;
    playIndex = 0;
    playCurrentCampaign();
  }

  function playCurrentCampaign() {
    clearTimeout(advanceTimer);
    if (playlist.length === 0) return;

    noContentEl.classList.add('hidden');
    const campaign = playlist[playIndex];
    renderCampaign(campaign);

    const durationMs = Number(campaign.campaign_settings && campaign.campaign_settings.duration) * 1000 || DEFAULT_ITEM_DURATION_MS;
    advanceTimer = setTimeout(() => {
      playIndex = (playIndex + 1) % playlist.length;
      playCurrentCampaign();
    }, durationMs);

    sendProofOfPlayForCampaign(campaign);
  }

  function renderCampaign(campaign) {
    contentRoot.innerHTML = '';

    const resW = Number(campaign.resolution && campaign.resolution.width) || window.innerWidth;
    const resH = Number(campaign.resolution && campaign.resolution.height) || window.innerHeight;
    const scale = Math.min(window.innerWidth / resW, window.innerHeight / resH);
    const left = (window.innerWidth - resW * scale) / 2;
    const top = (window.innerHeight - resH * scale) / 2;

    const stage = document.createElement('div');
    stage.style.position = 'absolute';
    stage.style.width = `${resW}px`;
    stage.style.height = `${resH}px`;
    stage.style.left = `${left}px`;
    stage.style.top = `${top}px`;
    stage.style.transform = `scale(${scale})`;
    stage.style.transformOrigin = 'top left';
    stage.style.background = '#000';

    (campaign.zones || []).forEach((zone) => {
      const zoneEl = document.createElement('div');
      zoneEl.style.position = 'absolute';
      zoneEl.style.left = `${Number(zone.x) || 0}px`;
      zoneEl.style.top = `${Number(zone.y) || 0}px`;
      zoneEl.style.width = `${Number(zone.width) || 0}px`;
      zoneEl.style.height = `${Number(zone.height) || 0}px`;
      zoneEl.style.overflow = 'hidden';

      const item = (zone.mediaItems || []).find((mi) => !(mi.ad_slot && mi.ad_slot.skip_playback));
      if (item) renderZoneItem(zoneEl, item);

      stage.appendChild(zoneEl);
    });

    contentRoot.appendChild(stage);
  }

  function renderZoneItem(container, item) {
    const settings = item.settings || {};
    let mediaType = (item.mediaType || '').toLowerCase();
    let url = item.mediaUrl;

    if (mediaType === 'ad_slot') {
      mediaType = (item.content_media_type || '').toLowerCase();
    } else if (mediaType === 'sticker') {
      url = settings.remoteSrc || item.mediaUrl;
      mediaType = 'image';
    } else if (mediaType === 'web_app_instance' || settings.kind === 'web-app-iframe') {
      url = settings.iframeSrc || item.mediaUrl;
      mediaType = 'iframe';
    }

    let el;
    if (mediaType === 'shape') {
      container.innerHTML = item.mediaUrl || ''; // raw inline <svg>…</svg>
      styleFill(container);
      return;
    } else if (mediaType === 'text') {
      container.innerHTML = settings.html || `<p>${settings.text || ''}</p>`;
      styleFill(container);
      return;
    } else if (mediaType.includes('video')) {
      el = document.createElement('video');
      el.src = url;
      el.autoplay = true;
      el.muted = true;
      el.loop = !!settings.loop;
    } else if (mediaType === 'iframe') {
      el = document.createElement('iframe');
      el.src = url;
    } else if (url) {
      el = document.createElement('img');
      el.src = url;
    } else {
      console.warn('[content] zone item had no renderable url', item);
      return;
    }

    styleFill(el);
    container.appendChild(el);
  }

  function styleFill(el) {
    el.style.width = '100%';
    el.style.height = '100%';
    el.style.border = 'none';
    el.style.display = 'block';
  }

  function sendProofOfPlayForCampaign(campaign) {
    (campaign.zones || []).forEach((zone) => {
      (zone.mediaItems || []).forEach((item) => {
        if (item.mediaType === 'ad_slot' && item.ad_slot && !item.ad_slot.skip_playback) {
          fetch('/api/proof-of-play', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(item),
          }).catch((err) => console.error('[proof-of-play] failed', err));
        }
      });
    });
  }

  window.addEventListener('resize', () => {
    if (playlist.length > 0) renderCampaign(playlist[playIndex]);
  });

  pollPairStatus();
})();
