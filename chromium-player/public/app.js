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
  let deviceUuid = null;
  let playlist = [];
  let playIndex = 0;
  let advanceTimer = null;
  let remoteViewActive = false;
  let remoteViewTimer = null;

  async function pollPairStatus() {
    try {
      const res = await fetch('/api/pair-status');
      const data = await res.json();

      if (data.deviceId) deviceUuid = data.deviceId;

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
      uuid: deviceUuid || topic,
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

  // ─── SVG / Shape helpers ────────────────────────────────────────────────

  function isSvgContent(str) {
    if (!str) return false;
    const t = str.trim();
    return t.startsWith('<svg') || (t.includes('<svg') && t.includes('</svg>'));
  }

  // Mirrors Flutter's StickerHtmlWidget._resolveSource():
  // relative /_next/… and /static/… paths are Next.js CMS routes that must
  // be resolved against the CMS origin before fetching.
  function normalizeStickerUrl(url) {
    if (!url) return '';
    if ((url.startsWith('/_next') || url.startsWith('/static')) && !url.startsWith('http')) {
      return `https://signagexai.com${url}`;
    }
    return url;
  }

  // Render inline SVG by injecting it directly into the DOM — this avoids
  // the white-background artefact that appears when SVG is loaded via <img>,
  // and mirrors Flutter's SvgPicture.string() which renders inline too.
  function renderInlineSvg(container, svgContent) {
    container.innerHTML = svgContent;
    const svgEl = container.querySelector('svg');
    if (svgEl) {
      svgEl.style.width = '100%';
      svgEl.style.height = '100%';
      svgEl.style.display = 'block';
    }
  }

  // Render a remote sticker URL. Fetches SVG text via the local proxy (server
  // handles CORS + forces correct Content-Type) then injects it inline so
  // there is no white-background artefact. Mirrors Flutter's StickerHtmlWidget
  // which calls http.read() then renders with SvgPicture.string() (inline).
  async function renderRemoteStickerUrl(container, url) {
    const normalised = normalizeStickerUrl(url);
    const src = (normalised.startsWith('http://') || normalised.startsWith('https://'))
      ? `/api/svg-proxy?url=${encodeURIComponent(normalised)}`
      : normalised;
    try {
      const res = await fetch(src);
      const text = await res.text();
      if (isSvgContent(text)) {
        container.innerHTML = text;
        const svgEl = container.querySelector('svg');
        if (svgEl) {
          svgEl.style.width = '100%';
          svgEl.style.height = '100%';
          svgEl.style.display = 'block';
        }
        return;
      }
    } catch (e) {
      console.warn('[content] SVG proxy fetch failed, using img fallback', e);
    }
    // Fallback for non-SVG assets or fetch errors
    const img = document.createElement('img');
    img.src = src;
    img.style.objectFit = 'contain';
    styleFill(img);
    container.appendChild(img);
  }

  // Port of Flutter's MediaItem.svgFromShapeProperties — constructs an inline
  // SVG for editor shapes (rect, circle, etc.) when no SVG url is present.
  function svgFromShapeProperties(settings) {
    const w = 100, h = 100; // coordinate space; CSS stretches it via width/height 100%
    const fill   = settings.fill   || '#cccccc';
    const stroke = settings.stroke || settings.strokeColor || '';
    const strokeWidth = parseInt(settings.strokeWidth || settings.stroke_width, 10) || 0;
    const path   = settings.path   || settings.d      || '';
    const points = settings.points || '';
    const shapeType = (
      settings.kind || settings.shapeType || settings.shape ||
      settings.type || 'rect'
    ).toLowerCase();

    const strokeAttr = (stroke && stroke !== 'transparent')
      ? ` stroke="${stroke}" stroke-width="${strokeWidth}"`
      : (strokeWidth > 0 ? ` stroke-width="${strokeWidth}"` : '');

    const ns = 'xmlns="http://www.w3.org/2000/svg"';
    const vb = `viewBox="0 0 ${w} ${h}"`;
    const hdr = `<svg ${ns} width="100%" height="100%" ${vb} preserveAspectRatio="none">`;

    if (path)   return `${hdr}<path d="${path}" fill="${fill}"${strokeAttr}/></svg>`;
    if (points) return `${hdr}<polygon points="${points}" fill="${fill}"${strokeAttr}/></svg>`;

    switch (shapeType) {
      case 'circle': {
        const r = Math.min(w, h) / 2;
        return `${hdr}<circle cx="${w/2}" cy="${h/2}" r="${r}" fill="${fill}"${strokeAttr}/></svg>`;
      }
      case 'ellipse':
        return `${hdr}<ellipse cx="${w/2}" cy="${h/2}" rx="${w/2}" ry="${h/2}" fill="${fill}"${strokeAttr}/></svg>`;
      case 'line':
        return `${hdr}<line x1="0" y1="0" x2="${w}" y2="${h}" stroke="${
          stroke || fill}" stroke-width="${strokeWidth > 0 ? strokeWidth : 2}"/></svg>`;
      case 'triangle': {
        const p = `0,${h} ${w/2},0 ${w},${h}`;
        return `${hdr}<polygon points="${p}" fill="${fill}"${strokeAttr}/></svg>`;
      }
      case 'rect':
      case 'rectangle':
      default:
        return `${hdr}<rect width="${w}" height="${h}" fill="${fill}"${strokeAttr}/></svg>`;
    }
  }

  // ─── Remote view ────────────────────────────────────────────────────────

  function startRemoteView() {
    if (remoteViewActive) return;
    remoteViewActive = true;
    console.log('[remote-view] started');
    captureAndPublishFrame();
    remoteViewTimer = setInterval(captureAndPublishFrame, 1000);
  }

  function stopRemoteView() {
    remoteViewActive = false;
    clearInterval(remoteViewTimer);
    remoteViewTimer = null;
    console.log('[remote-view] stopped');
  }

  async function captureAndPublishFrame() {
    if (!remoteViewActive || !mqttClient || !mqttTopic) return;
    if (typeof html2canvas === 'undefined') {
      console.warn('[remote-view] html2canvas not loaded');
      return;
    }
    try {
      const canvas = await html2canvas(document.body, {
        // useCORS: true lets html2canvas attempt CORS-safe image loads;
        // cross-origin images that fail CORS are simply omitted rather than
        // tainting the canvas. Do NOT set allowTaint:true — it marks the
        // canvas as tainted, making canvas.toBlob() throw a SecurityError
        // which silently suppresses every frame and causes 'waiting for screen'.
        useCORS: true,
        scale: 0.25,
        logging: false,
        backgroundColor: '#000000',
        imageTimeout: 5000,
      });
      canvas.toBlob((blob) => {
        if (!blob || !remoteViewActive) return;
        const reader = new FileReader();
        reader.onloadend = () => {
          const base64 = reader.result.split(',')[1];
          const payload = JSON.stringify({
            action: 'image',
            img_url: base64,
            // CMS frontend expects the literal value 'mac' (not 'macos')
            // to route the frame to the correct renderer.
            sender: 'mac',
          });
          if (remoteViewActive && mqttClient) {
            mqttClient.publish(`${mqttTopic}/remote`, payload);
          }
        };
        reader.readAsDataURL(blob);
      }, 'image/jpeg', 0.3);
    } catch (e) {
      console.error('[remote-view] capture failed', e);
    }
  }

  // Handles MQTT messages received on <playerCode>/remote.
  // These are CMS commands (start/stop remote view, click, scroll, etc.).
  function handleRemoteViewMessage(data) {
    switch (data.action) {
      case 'start_remote_view':
      case 'low_res':
        startRemoteView();
        break;
      case 'stop_remote_view':
        stopRemoteView();
        break;
      case 'click': {
        const x = Number(data.x);
        const y = Number(data.y);
        if (!isNaN(x) && !isNaN(y)) {
          const el = document.elementFromPoint(x, y);
          if (el) {
            el.dispatchEvent(new MouseEvent('click', {
              bubbles: true, cancelable: true, clientX: x, clientY: y,
            }));
            console.log('[remote-view] click at', x, y);
          }
        }
        break;
      }
      case 'scroll': {
        const hold    = data.hold    || {};
        const release = data.release || {};
        const dx = (Number(release.x) || 0) - (Number(hold.x) || 0);
        const dy = (Number(release.y) || 0) - (Number(hold.y) || 0);
        window.scrollBy(dx, dy);
        console.log('[remote-view] scroll', dx, dy);
        break;
      }
      default:
        console.log('[remote-view] unhandled command', data.action);
    }
  }

  // ────────────────────────────────────────────────────────────────────────

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
      // Last Will: marks the player offline if the connection drops unexpectedly.
      // Mirrors the Flutter app's LWT so the CMS can detect disconnects.
      will: {
        topic: `${topic}/player_status`,
        payload: JSON.stringify({ status: 'offline' }),
        qos: 1,
        retain: true,
      },
    });

    mqttClient.on('connect', () => {
      console.log('[mqtt] connected, subscribing to', topic);
      // Subscribe to the player-code topic (campaign pushes) and the /remote
      // sub-topic (remote-view commands), matching the Flutter app's pattern.
      mqttClient.subscribe([topic, `${topic}/remote`], { qos: 0 }, (err) => {
        if (err) {
          console.error('[mqtt] subscribe failed', err);
          return;
        }
        console.log('[mqtt] subscribed, publishing online status and device info');
        // Publish retained online status to <playerCode>/player_status so the
        // CMS knows this player is reachable and triggers a campaign push.
        // This mirrors exactly what the Flutter app does.
        mqttClient.publish(
          `${topic}/player_status`,
          JSON.stringify({ status: 'online' }),
          { retain: true, qos: 1 },
        );
        // Also publish device info for CMS registration/identification.
        mqttClient.publish(topic, JSON.stringify(buildDeviceInfo(topic)));
      });
    });

    mqttClient.on('message', (recvTopic, payload) => {
      const raw = payload.toString();
      console.log('[mqtt] message on', recvTopic, raw.substring(0, 200));
      let data;
      try {
        data = JSON.parse(raw);
      } catch (err) {
        console.error('[mqtt] payload was not JSON', err);
        return;
      }
      // Route by topic AND by action name — mirrors the Flutter dispatcher
      // which handles remote-view actions on any subscribed topic.
      const action = data.action || '';
      const isRemoteViewAction = (
        recvTopic === `${topic}/remote` ||
        action === 'start_remote_view' ||
        action === 'stop_remote_view' ||
        action === 'low_res' ||
        action === 'click' ||
        action === 'scroll' ||
        action === 'send_text' ||
        action === 'press_home' ||
        action === 'press_back'
      );
      if (isRemoteViewAction) {
        handleRemoteViewMessage(data);
      } else {
        handleContentMessage(data);
      }
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
  // ]}}.
  function handleContentMessage(data) {
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
    // White background matches Flutter's Scaffold backgroundColor: Colors.white.
    // CMS campaign content is authored against a white stage — using black here
    // makes black text / shapes invisible.
    stage.style.background = '#fff';

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
    let url = item.mediaUrl || '';

    if (mediaType === 'ad_slot') {
      mediaType = (item.content_media_type || '').toLowerCase();
    } else if (mediaType === 'web_app_instance' || settings.kind === 'web-app-iframe') {
      url = settings.iframeSrc || item.mediaUrl || '';
      mediaType = 'iframe';
    }

    // ── shape ──────────────────────────────────────────────────────────────
    if (mediaType === 'shape') {
      let svgContent = isSvgContent(url) ? url : '';
      if (!svgContent) {
        // No inline SVG in mediaUrl — build one from fill/kind/stroke props.
        svgContent = svgFromShapeProperties(settings);
      }
      container.innerHTML = svgContent;
      container.style.overflow = 'hidden';
      // Make the generated/injected SVG fill its zone container.
      const svgEl = container.querySelector('svg');
      if (svgEl) {
        svgEl.style.width  = '100%';
        svgEl.style.height = '100%';
        svgEl.style.display = 'block';
      }
      return;
    }

    // ── text ───────────────────────────────────────────────────────────────
    if (mediaType === 'text') {
      container.innerHTML = settings.html || `<p>${settings.text || ''}</p>`;
      styleFill(container);
      return;
    }

    // ── sticker ────────────────────────────────────────────────────────────
    // Stickers can be: HTML snippets (settings.html), inline SVG, remote SVG
    // or raster image URLs. Mirrors the Flutter _buildStickerWidget priority.
    if (mediaType === 'sticker' || mediaType === 'image/svg+xml' || MediaItem_looksLikeSticker(item)) {
      // Priority 1: HTML sticker
      if (settings.html) {
        container.innerHTML = settings.html;
        styleFill(container);
        return;
      }
      // remoteSrc can come under several key names in the raw MQTT JSON
      const rawStickerUrl = (
        settings.remoteSrc || settings.remote_src ||
        settings.download_url || settings.downloadUrl ||
        url || ''
      ).trim();
      const stickerUrl = normalizeStickerUrl(rawStickerUrl);
      // Priority 2: inline SVG — render via Blob URL (handles embedded images,
      // avoids data-URI length limits, and doesn't require CORS)
      if (isSvgContent(stickerUrl)) {
        renderInlineSvg(container, stickerUrl);
        return;
      }
      // Priority 3: remote URL — proxy through the local server so the browser
      // always gets image/svg+xml with no CORS issues
      if (stickerUrl) {
        renderRemoteStickerUrl(container, stickerUrl);
        return;
      }
      console.warn('[content] sticker had no renderable content', item);
      return;
    }

    // ── video ──────────────────────────────────────────────────────────────
    if (mediaType.includes('video')) {
      const el = document.createElement('video');
      el.src = url;
      el.autoplay = true;
      el.muted = true;
      el.loop = !!settings.loop;
      styleFill(el);
      container.appendChild(el);
      return;
    }

    // ── iframe ─────────────────────────────────────────────────────────────
    if (mediaType === 'iframe') {
      const el = document.createElement('iframe');
      el.src = url;
      styleFill(el);
      container.appendChild(el);
      return;
    }

    // ── image / fallback ───────────────────────────────────────────────────
    if (url) {
      const el = document.createElement('img');
      el.src = url;
      styleFill(el);
      container.appendChild(el);
      return;
    }

    console.warn('[content] zone item had no renderable url', item);
  }

  // True for items that should use sticker rendering even if mediaType differs
  // (mirrors Flutter's MediaItem.looksLikeSticker and normalizeMediaType).
  // Key: CMS sends SVG stickers with mediaType='image/svg+xml' (not 'sticker');
  // Flutter normalises that → 'sticker' internally, we must replicate here.
  function MediaItem_looksLikeSticker(item) {
    const mt = (item.mediaType || '').toLowerCase();
    // Flutter normalises 'image/svg+xml' → 'sticker'
    if (mt === 'image/svg+xml') return true;
    const settings = item.settings || {};
    // remoteSrc can be any of these keys in the raw JSON
    const remoteSrc = (
      settings.remoteSrc || settings.remote_src ||
      settings.download_url || settings.downloadUrl || ''
    ).toLowerCase();
    if (remoteSrc.endsWith('.svg')) return true;
    const kind = (settings.kind || '').toLowerCase();
    if (kind.includes('sticker')) return true;
    return false;
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
