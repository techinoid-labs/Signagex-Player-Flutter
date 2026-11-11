import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/constants.dart';
import '../utils/debug_log.dart' as debug;
import 'linux_diagnostics.dart';

/// Kiosk campaigns on Linux: interactive touch journeys built in Kiosk Studio.
///
/// The CMS publishes the running campaign on the retained topic
/// `{playerCode}/kiosk` (see the backend's docs/KIOSK_CAMPAIGN_CONTRACT.md).
/// While one is active it takes over the screen from scheduled signage and is
/// shown full screen in the CEF browser (`player_url`, the frontend's
/// /kiosk-play page). The page reports its state through its document title
/// (`sxk:<state>`), which this service uses to swap versions only between
/// customer sessions and to recover a page that stopped answering.
///
/// Nothing a customer enters ever reaches this side: the page keeps answers
/// in memory; only the published document and the payload are cached.

/// Page states reported by /kiosk-play.
enum KioskPageState { none, loading, ready, session, idle, error }

KioskPageState kioskPageStateFromTitle(String? title) {
  if (title == null || !title.startsWith('sxk:')) return KioskPageState.none;
  switch (title.substring(4).trim().toLowerCase()) {
    case 'loading':
      return KioskPageState.loading;
    case 'ready':
      return KioskPageState.ready;
    case 'session':
      return KioskPageState.session;
    case 'idle':
      return KioskPageState.idle;
    case 'error':
      return KioskPageState.error;
    default:
      return KioskPageState.none;
  }
}

/// One published version, as the CMS sent it.
class KioskPayload {
  final String campaignId;
  final String name;
  final String versionId;
  final int versionNo;
  final String publishedAt;
  final String url;
  final String playerUrl;

  const KioskPayload({
    required this.campaignId,
    required this.name,
    required this.versionId,
    required this.versionNo,
    required this.publishedAt,
    required this.url,
    required this.playerUrl,
  });

  /// Null when [data] isn't a usable publish: missing ids, or a runtime URL
  /// that isn't http(s).
  static KioskPayload? fromJson(Object? data, {String? frontendBase}) {
    if (data is! Map) return null;
    String text(String key) => (data[key] ?? '').toString().trim();
    final campaignId = text('campaign_id');
    final versionId = text('version_id');
    final url = text('url');
    final runtime = Uri.tryParse(url);
    if (campaignId.isEmpty ||
        versionId.isEmpty ||
        runtime == null ||
        !['https', 'http'].contains(runtime.scheme) ||
        runtime.host.isEmpty) {
      return null;
    }
    var playerUrl = text('player_url');
    final page = Uri.tryParse(playerUrl);
    if (playerUrl.isEmpty ||
        page == null ||
        !['https', 'http'].contains(page.scheme)) {
      playerUrl = kioskPageUrl(url, frontendBase ?? kioskFrontendBase);
    }
    final versionNo = data['version_no'];
    return KioskPayload(
      campaignId: campaignId,
      name: text('name'),
      versionId: versionId,
      versionNo: versionNo is num ? versionNo.toInt() : int.tryParse('$versionNo') ?? 0,
      publishedAt: text('published_at'),
      url: url,
      playerUrl: playerUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'campaign_id': campaignId,
        'name': name,
        'version_id': versionId,
        'version_no': versionNo,
        'published_at': publishedAt,
        'url': url,
        'player_url': playerUrl,
      };
}

/// The /kiosk-play page for a runtime document URL.
String kioskPageUrl(String runtimeUrl, String frontendBase) {
  final base = frontendBase.endsWith('/')
      ? frontendBase.substring(0, frontendBase.length - 1)
      : frontendBase;
  return '$base/kiosk-play?runtime=${Uri.encodeComponent(runtimeUrl)}';
}

/// A message on `{playerCode}/kiosk`.
class KioskMessage {
  final KioskPayload? publish;
  final bool clear;
  const KioskMessage._(this.publish, this.clear);

  /// Null for anything that isn't a publish or a clear (or isn't JSON).
  static KioskMessage? parse(String raw, {String? frontendBase}) {
    Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    switch (json['action']) {
      case 'clear_kiosk_campaign':
        return const KioskMessage._(null, true);
      case 'publish_kiosk_campaign':
        final payload =
            KioskPayload.fromJson(json['data'], frontendBase: frontendBase);
        return payload == null ? null : KioskMessage._(payload, false);
      default:
        return null;
    }
  }
}

/// Checks a downloaded runtime document against the payload it was fetched
/// for. Returns the reason it is unusable, or null when it is fine.
String? validateKioskDocument(KioskPayload payload, String body,
    {int maxBytes = 10 * 1024 * 1024}) {
  if (utf8.encode(body).length > maxBytes) return 'document is over 10 MB';
  Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    return 'document is not JSON';
  }
  if (json is! Map) return 'document is not an object';
  if ('${json['version_id']}' != payload.versionId) {
    return 'document is for another version';
  }
  final document = json['document'];
  if (document is! Map || document['schemaVersion'] == null) {
    return 'document has no schemaVersion';
  }
  return null;
}

/// When a waiting version (or a clear) may take over the screen.
///
/// Never in the middle of a customer session. A session that has been
/// running for [maxWait] is asked to end (the page's own idle reset should
/// have done so; a stuck page must not block updates forever), and the swap
/// happens once the page reports idle, or [forceAfter] later if it doesn't.
class KioskSwapPolicy {
  static const maxWait = Duration(minutes: 15);
  static const forceAfter = Duration(seconds: 60);

  /// What to do now for something that has been waiting since [waitingSince].
  static KioskSwapDecision decide({
    required KioskPageState state,
    required DateTime waitingSince,
    required DateTime now,
    DateTime? endRequestedAt,
  }) {
    if (state != KioskPageState.session) return KioskSwapDecision.apply;
    if (endRequestedAt != null) {
      return now.difference(endRequestedAt) >= forceAfter
          ? KioskSwapDecision.apply
          : KioskSwapDecision.wait;
    }
    return now.difference(waitingSince) >= maxWait
        ? KioskSwapDecision.requestEnd
        : KioskSwapDecision.wait;
  }
}

enum KioskSwapDecision { apply, wait, requestEnd }

/// On-disk copy of the running payload and its document, plus the previous
/// good one. Writes go to a temporary file renamed into place, so a power
/// cut mid-write never leaves a half file as "current".
class KioskCache {
  final Directory directory;
  KioskCache(this.directory);

  static KioskCache standard() => KioskCache(Directory(
      '${Platform.environment['HOME'] ?? '.'}/.local/share/signagex-player/kiosk'));

  File get _current => File('${directory.path}/current.json');
  File get _previous => File('${directory.path}/previous.json');

  /// Saves [payload] and [document] as current; the old current becomes
  /// previous (unless it is the same version).
  Future<void> save(KioskPayload payload, String document) async {
    await directory.create(recursive: true);
    final entry = jsonEncode({'payload': payload.toJson(), 'document': document});
    final existing = await readCurrent();
    if (existing != null && existing.payload.versionId != payload.versionId) {
      await _write(_previous, await _current.readAsString());
    }
    await _write(_current, entry);
  }

  Future<void> _write(File target, String contents) async {
    final temporary = File('${target.path}.part');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  }

  Future<KioskCacheEntry?> readCurrent() => _read(_current);
  Future<KioskCacheEntry?> readPrevious() => _read(_previous);

  Future<KioskCacheEntry?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      final payload = KioskPayload.fromJson(json['payload']);
      final document = json['document'];
      if (payload == null || document is! String) return null;
      return KioskCacheEntry(payload, document);
    } catch (_) {
      return null;
    }
  }

  /// After a clear: nothing runs on the next start.
  Future<void> clear() async {
    for (final file in [_current, _previous]) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }
}

class KioskCacheEntry {
  final KioskPayload payload;
  final String document;
  const KioskCacheEntry(this.payload, this.document);
}

/// Runs kiosk campaigns on a Linux player. See the file comment.
class KioskCampaignService extends ChangeNotifier {
  KioskCampaignService({KioskCache? cache, HttpClient Function()? httpClient})
      : _cache = cache ?? KioskCache.standard(),
        _httpClient = httpClient ?? HttpClient.new;

  static final KioskCampaignService instance = KioskCampaignService();

  final KioskCache _cache;
  final HttpClient Function() _httpClient;

  String _playerCode = '';

  /// What is on screen (null: scheduled signage).
  KioskPayload? _active;
  KioskPayload? get active => _active;

  /// A newer version, downloaded and cached, waiting for the session to end.
  KioskPayload? _pending;
  bool _pendingClear = false;
  DateTime? _waitingSince;
  DateTime? _endRequestedAt;

  KioskPageState _state = KioskPageState.none;
  KioskPageState get pageState => _state;
  DateTime _shownAt = DateTime.now();

  int _failures = 0;
  DateTime? _fallbackUntil;

  /// Bumped to make the page reload (health recovery).
  final ValueNotifier<int> reloadRequests = ValueNotifier(0);

  /// Bumped to ask the page to end its session (before a forced swap).
  final ValueNotifier<int> endSessionRequests = ValueNotifier(0);

  Timer? _timer;
  bool _started = false;
  String _lastHandledRaw = '';

  /// A publish whose download failed; tried again every minute.
  String? _retryRaw;
  DateTime? _retryAt;

  /// True while the kiosk should cover scheduled signage.
  bool get showing =>
      _active != null &&
      (_fallbackUntil == null || DateTime.now().isAfter(_fallbackUntil!));

  void _log(String message) {
    unawaited(debug.debugLog('Kiosk', message));
    if (Platform.isLinux) {
      unawaited(LinuxDiagnostics.instance
          .record('Kiosk: $message', 'info')
          .catchError((_) {}));
    }
  }

  void _startTimer() {
    _timer ??= Timer.periodic(const Duration(seconds: 5), (_) => _tick());
  }

  /// On app start: show the cached campaign straight away, even before MQTT
  /// reconnects. The page itself still needs the network to load.
  Future<void> restore() async {
    if (_active != null) return;
    final entry = await _cache.readCurrent();
    if (entry == null) return;
    _log('resuming cached version ${entry.payload.versionNo} of ${entry.payload.campaignId}');
    _show(entry.payload);
    _startTimer();
  }

  /// Once paired, with the player code that names the topics.
  void start(String playerCode) {
    _playerCode = playerCode;
    _started = true;
    _startTimer();
  }

  /// A message on `{playerCode}/kiosk`.
  Future<void> handleMessage(String raw) async {
    if (raw == _lastHandledRaw) return; // retained copy after a reconnect
    final message = KioskMessage.parse(raw);
    if (message == null) {
      _log('ignored an unreadable kiosk message');
      return;
    }
    _lastHandledRaw = raw;
    if (message.clear) {
      _log('clear received');
      _retryRaw = null;
      _pending = null;
      if (_active == null) {
        await _cache.clear();
        return;
      }
      _pendingClear = true;
      _waitingSince = DateTime.now();
      _endRequestedAt = null;
      _tick();
      return;
    }
    final payload = message.publish!;
    _pendingClear = false;
    if (payload.versionId == _active?.versionId) {
      _pending = null;
      return; // same version: nothing to do
    }
    if (payload.versionId == _pending?.versionId) return;
    final body = await _download(payload);
    if (body == null) {
      // Keep running what we have, and try this version again later.
      _lastHandledRaw = '';
      _retryRaw = raw;
      _retryAt = DateTime.now().add(const Duration(minutes: 1));
      return;
    }
    _retryRaw = null;
    await _cache.save(payload, body);
    if (_active == null) {
      _log('starting version ${payload.versionNo} of ${payload.campaignId}');
      _show(payload);
      return;
    }
    _log('version ${payload.versionNo} ready; waits for the session to end');
    _pending = payload;
    _waitingSince = DateTime.now();
    _endRequestedAt = null;
    _tick();
  }

  Future<String?> _download(KioskPayload payload) async {
    const delays = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      final client = _httpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse(payload.url));
        final response = await request.close().timeout(const Duration(seconds: 30));
        if (response.statusCode == 404) {
          _log('version ${payload.versionNo} is not for this player (404)');
          return null;
        }
        if (response.statusCode != 200) {
          throw HttpException('HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(const Duration(seconds: 30))) {
          bytes.addAll(chunk);
          if (bytes.length > 10 * 1024 * 1024) {
            throw const FormatException('document is over 10 MB');
          }
        }
        final body = utf8.decode(bytes);
        final problem = validateKioskDocument(payload, body);
        if (problem != null) {
          _log('version ${payload.versionNo} rejected: $problem');
          return null;
        }
        return body;
      } catch (error) {
        _log('download of version ${payload.versionNo} failed (attempt ${attempt + 1}): $error');
        if (attempt < delays.length) await Future.delayed(delays[attempt]);
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  void _show(KioskPayload payload) {
    _active = payload;
    _state = KioskPageState.none;
    _shownAt = DateTime.now();
    _failures = 0;
    _fallbackUntil = null;
    notifyListeners();
  }

  /// From the page: its title changed.
  void onPageTitle(String title) {
    final state = kioskPageStateFromTitle(title);
    if (state == KioskPageState.none) return;
    if (state != _state) _log('page ${state.name}');
    _state = state;
    if (state == KioskPageState.error) {
      _recover('page reported an error');
    } else if (state != KioskPageState.loading) {
      _failures = 0;
    }
    _tick();
  }

  /// From the page: the main frame failed to load (offline, DNS, 5xx...).
  void onPageLoadFailed() {
    _recover('page failed to load');
  }

  void _recover(String reason) {
    _failures++;
    unawaited(_postStatus('error'));
    if (_failures >= 3) {
      _log('$reason; back to scheduled signage, retrying in 2 minutes');
      _fallbackUntil = DateTime.now().add(const Duration(minutes: 2));
      _failures = 0;
      notifyListeners();
      return;
    }
    _log('$reason; reloading (${_failures}x)');
    final delay = Duration(seconds: 5 * _failures);
    Timer(delay, () => reloadRequests.value++);
  }

  void _tick() {
    final now = DateTime.now();
    final retry = _retryRaw;
    if (retry != null && _retryAt != null && now.isAfter(_retryAt!)) {
      _retryRaw = null;
      unawaited(handleMessage(retry));
    }
    // Back from a fallback: try showing the page again.
    if (_fallbackUntil != null && now.isAfter(_fallbackUntil!)) {
      _fallbackUntil = null;
      _state = KioskPageState.none;
      _shownAt = now;
      notifyListeners();
      return;
    }
    if (!showing) return;

    // A page that never says anything is as stuck as one reporting errors.
    if (_state == KioskPageState.none && now.difference(_shownAt) > const Duration(seconds: 60)) {
      _shownAt = now;
      _recover('page sent no state in 60 s');
      return;
    }

    if (_pending == null && !_pendingClear) return;
    final decision = KioskSwapPolicy.decide(
      state: _state,
      waitingSince: _waitingSince ?? now,
      now: now,
      endRequestedAt: _endRequestedAt,
    );
    switch (decision) {
      case KioskSwapDecision.wait:
        return;
      case KioskSwapDecision.requestEnd:
        _log('session running ${KioskSwapPolicy.maxWait.inMinutes} min; asking the page to end it');
        _endRequestedAt = now;
        endSessionRequests.value++;
        return;
      case KioskSwapDecision.apply:
        break;
    }
    if (_pendingClear) {
      _log('cleared; back to scheduled signage');
      _pendingClear = false;
      _active = null;
      _pending = null;
      unawaited(_cache.clear());
      notifyListeners();
      return;
    }
    final next = _pending!;
    _pending = null;
    _log('switching to version ${next.versionNo}');
    _show(next);
  }

  /// Tells the CMS the page is broken even when the page can't say so itself.
  Future<void> _postStatus(String state) async {
    final payload = _active;
    if (payload == null || !_started || _playerCode.isEmpty) return;
    final client = _httpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse(
          '${baseurl}kiosk-runtime/${Uri.encodeComponent(payload.versionId)}/status?player=${Uri.encodeQueryComponent(_playerCode)}');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'state': state, 'sessionActive': false}));
      final response = await request.close().timeout(const Duration(seconds: 10));
      await response.drain<void>();
    } catch (_) {
      // Best effort: the CMS also sees the page's own reports.
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  void debugSetState(KioskPageState state) {
    _state = state;
  }

  @visibleForTesting
  KioskPayload? get debugPending => _pending;

  @visibleForTesting
  bool get debugPendingClear => _pendingClear;

  @visibleForTesting
  void debugTick() => _tick();

  @override
  void dispose() {
    _timer?.cancel();
    reloadRequests.dispose();
    endSessionRequests.dispose();
    super.dispose();
  }
}
