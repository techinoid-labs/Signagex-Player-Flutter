import 'dart:async';
import 'linux_atomic_json.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Content proof of play for Reports, as the Android player sends it
/// (signagex-player-android data/pop/*; backend PLAYER_PROOF_OF_PLAY_V2):
///
/// * every finished media item that is library content (`item_id`) is counted
///   per content / UTC day / status / reason in an on-disk queue;
/// * every 2 minutes up to 10 batches of 200 go to
///   `POST player/content-proof-of-play`, signed with the key from
///   `POST player/pop-key` (HMAC-SHA256 of `ts.player_code.contents_json`);
/// * on 5xx / network errors the batch stays queued, backs off 30 s .. 15 min
///   and is also sent over MQTT (not retained) at most every 15 minutes;
/// * 400 drops the batch, 401 keeps it and re-checks the key, per-entry
///   results drop permanent errors and retry the rest.
///
/// Only declared fields are sent; no customer data.
class PopSigning {
  static final _hexKey = RegExp(r'^[0-9a-fA-F]{64}$');

  static bool isValidKey(String? key) => key != null && _hexKey.hasMatch(key);

  /// hex(HMAC_SHA256(key bytes, "$ts.$playerCode.$payload")).
  static String sign(String keyHex, int ts, String playerCode, String payload) {
    final mac = Hmac(sha256, _hexToBytes(keyHex));
    return mac.convert(utf8.encode('$ts.$playerCode.$payload')).toString();
  }

  static String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  static List<int> _hexToBytes(String hex) {
    if (hex.length.isOdd) throw const FormatException('odd hex length');
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ];
  }
}

class PopReasons {
  static const scheduled = 'scheduled';
  static const _contract = {
    'scheduled', 'interactivity', 'trigger', 'geofence', 'fallback', 'on_demand', 'api'
  };

  /// Any internal reason mapped onto what the CMS accepts; unknown = scheduled.
  static String normalize(String? reason) {
    final r = (reason ?? '').trim().toLowerCase();
    if (_contract.contains(r)) return r;
    if (const {'touch_region', 'key_press', 'queue', 'touch', 'key'}.contains(r)) {
      return 'interactivity';
    }
    return scheduled;
  }
}

/// One play as it happened.
class PopPlay {
  final String contentId;
  final DateTime playedAt;
  final int seconds;
  final String status; // completed | failed | partial
  final String reason;
  final bool userTouched;
  final String? campaignId;
  final int? zoneId;
  final String? zoneName;

  const PopPlay({
    required this.contentId,
    required this.playedAt,
    required this.seconds,
    this.status = 'completed',
    this.reason = PopReasons.scheduled,
    this.userTouched = false,
    this.campaignId,
    this.zoneId,
    this.zoneName,
  });
}

/// A queued `contents[]` entry (counts merged per content/day/status/reason).
class PopEntry {
  String contentId;
  String utcDay;
  String status;
  String reason;
  int playCount;
  int playbackTime;
  int lastPlayedAtMs;
  String clientEventId;
  bool userTouched;
  String? campaignId;
  int? zoneId;
  String? zoneName;
  bool sealed;
  int? firstMqttAtMs;
  int? lastMqttAtMs;

  PopEntry({
    required this.contentId,
    required this.utcDay,
    required this.status,
    required this.reason,
    required this.playCount,
    required this.playbackTime,
    required this.lastPlayedAtMs,
    required this.clientEventId,
    this.userTouched = false,
    this.campaignId,
    this.zoneId,
    this.zoneName,
    this.sealed = false,
    this.firstMqttAtMs,
    this.lastMqttAtMs,
  });

  /// The wire entry: declared fields only, nulls left out (REST rejects unknown keys).
  Map<String, dynamic> toReport() => {
        'content_id': contentId,
        'play_count': playCount,
        'played_at': DateTime.fromMillisecondsSinceEpoch(lastPlayedAtMs, isUtc: true)
            .toIso8601String(),
        'playback_time': playbackTime,
        'status': status,
        'playback_reason': reason,
        'client_event_id': clientEventId,
        if (userTouched) 'user_touched': true,
        if (campaignId != null) 'campaign_id': campaignId,
        if (zoneId != null) 'zone_id': zoneId,
        if (zoneName != null) 'zone_name': zoneName,
      };

  Map<String, dynamic> toJson() => {
        'content_id': contentId,
        'utc_day': utcDay,
        'status': status,
        'reason': reason,
        'play_count': playCount,
        'playback_time': playbackTime,
        'last_played_at_ms': lastPlayedAtMs,
        'client_event_id': clientEventId,
        'user_touched': userTouched,
        'campaign_id': campaignId,
        'zone_id': zoneId,
        'zone_name': zoneName,
        'sealed': sealed,
        'first_mqtt_at_ms': firstMqttAtMs,
        'last_mqtt_at_ms': lastMqttAtMs,
      };

  static PopEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['content_id'], event = raw['client_event_id'];
    if (id is! String || id.isEmpty || event is! String || event.isEmpty) return null;
    int? n(Object? v) => v is num ? v.toInt() : null;
    return PopEntry(
      contentId: id,
      utcDay: raw['utc_day']?.toString() ?? '',
      status: raw['status']?.toString() ?? 'completed',
      reason: PopReasons.normalize(raw['reason']?.toString()),
      playCount: n(raw['play_count']) ?? 1,
      playbackTime: n(raw['playback_time']) ?? 0,
      lastPlayedAtMs: n(raw['last_played_at_ms']) ?? 0,
      clientEventId: event,
      userTouched: raw['user_touched'] == true,
      campaignId: raw['campaign_id']?.toString(),
      zoneId: n(raw['zone_id']),
      zoneName: raw['zone_name']?.toString(),
      sealed: raw['sealed'] == true,
      firstMqttAtMs: n(raw['first_mqtt_at_ms']),
      lastMqttAtMs: n(raw['last_mqtt_at_ms']),
    );
  }
}

/// The queue rules of Android's ContentPopQueue (pure, unit-tested).
class PopQueue {
  static const maxPlayCount = 86400;
  static const maxEntries = 5000;
  static const mqttResendMs = 15 * 60 * 1000;
  static const mqttOnlyRetentionMs = 24 * 60 * 60 * 1000;
  static const maxAgeMs = 30 * 24 * 60 * 60 * 1000;

  final List<PopEntry> items;
  PopQueue([List<PopEntry>? initial]) : items = [...?initial];

  bool get isEmpty => items.isEmpty;

  static String utcDay(DateTime t) => t.toUtc().toIso8601String().substring(0, 10);

  void record(PopPlay play, String Function() newId) {
    final day = utcDay(play.playedAt);
    final reason = PopReasons.normalize(play.reason);
    final seconds = max(0, play.seconds);
    final at = play.playedAt.millisecondsSinceEpoch;
    final i = items.indexWhere((e) =>
        !e.sealed &&
        e.contentId == play.contentId &&
        e.utcDay == day &&
        e.status == play.status &&
        e.reason == reason &&
        e.playCount < maxPlayCount);
    if (i >= 0) {
      final e = items[i];
      e.playCount += 1;
      e.playbackTime += seconds;
      e.lastPlayedAtMs = max(e.lastPlayedAtMs, at);
      e.userTouched = e.userTouched || play.userTouched;
      e.campaignId = play.campaignId ?? e.campaignId;
      e.zoneId = play.zoneId ?? e.zoneId;
      e.zoneName = play.zoneName ?? e.zoneName;
    } else {
      items.add(PopEntry(
        contentId: play.contentId,
        utcDay: day,
        status: play.status,
        reason: reason,
        playCount: 1,
        playbackTime: seconds,
        lastPlayedAtMs: at,
        clientEventId: newId(),
        userTouched: play.userTouched,
        campaignId: play.campaignId,
        zoneId: play.zoneId,
        zoneName: play.zoneName,
      ));
    }
    if (items.length > maxEntries) {
      items.sort((a, b) => a.lastPlayedAtMs.compareTo(b.lastPlayedAtMs));
      items.removeRange(0, items.length - maxEntries);
    }
  }

  /// Oldest [maxCount] entries, sealed so later plays start new entries.
  List<PopEntry> takeBatch(int maxCount) {
    final sorted = [...items]..sort((a, b) => a.lastPlayedAtMs.compareTo(b.lastPlayedAtMs));
    final batch = sorted.take(maxCount).toList();
    for (final e in batch) {
      e.sealed = true;
    }
    return batch;
  }

  int remove(Set<String> ids) {
    final before = items.length;
    items.removeWhere((e) => ids.contains(e.clientEventId));
    return before - items.length;
  }

  List<PopEntry> dueForMqtt(List<PopEntry> batch, int nowMs) => batch
      .where((e) => items.contains(e))
      .where((e) => e.lastMqttAtMs == null || nowMs - e.lastMqttAtMs! >= mqttResendMs)
      .toList();

  void markMqttSent(Set<String> ids, int nowMs) {
    for (final e in items.where((e) => ids.contains(e.clientEventId))) {
      e.sealed = true;
      e.firstMqttAtMs ??= nowMs;
      e.lastMqttAtMs = nowMs;
    }
  }

  /// Drops entries sent only over MQTT for 24 h, and anything older than 30 days.
  int prune(int nowMs) {
    final before = items.length;
    items.removeWhere((e) =>
        (e.firstMqttAtMs != null && nowMs - e.firstMqttAtMs! >= mqttOnlyRetentionMs) ||
        nowMs - e.lastPlayedAtMs >= maxAgeMs);
    return before - items.length;
  }
}

enum PopOutcomeKind { processed, drop, unauthorized, retry }

class PopOutcome {
  final PopOutcomeKind kind;
  final Set<String> done;
  final Set<String> retry;
  const PopOutcome(this.kind, [this.done = const {}, this.retry = const {}]);
}

/// Android PopDeliveryPolicy.
class PopDelivery {
  static const firstBackoffMs = 30000;
  static const maxBackoffMs = 15 * 60 * 1000;

  /// 30 s, 1 m, 2 m, 4 m, 8 m, then 15 m.
  static int backoffMs(int failures) {
    if (failures <= 0) return 0;
    return min(firstBackoffMs << min(failures - 1, 10), maxBackoffMs);
  }

  static PopOutcome classify(int? httpCode, String? body, List<String> sentIds) {
    if (httpCode == null) return const PopOutcome(PopOutcomeKind.retry);
    if (httpCode >= 200 && httpCode < 300) {
      return _perEntry(body, sentIds) ??
          PopOutcome(PopOutcomeKind.processed, sentIds.toSet());
    }
    if (httpCode == 400) return _perEntry(body, sentIds) ?? const PopOutcome(PopOutcomeKind.drop);
    if (httpCode == 401) return const PopOutcome(PopOutcomeKind.unauthorized);
    return const PopOutcome(PopOutcomeKind.retry);
  }

  static PopOutcome? _perEntry(String? body, List<String> sentIds) {
    List? results;
    try {
      final parsed = jsonDecode(body ?? '');
      if (parsed is Map && parsed['results'] is List) results = parsed['results'] as List;
    } catch (_) {}
    if (results == null || results.length != sentIds.length) return null;
    final done = <String>{}, retry = <String>{};
    for (var i = 0; i < sentIds.length; i++) {
      final r = results[i];
      final error = r is Map && r['error'] != null ? r['error'].toString() : null;
      if (error == null || isPermanentError(error)) {
        done.add(sentIds[i]);
      } else {
        retry.add(sentIds[i]);
      }
    }
    return PopOutcome(PopOutcomeKind.processed, done, retry);
  }

  static bool isPermanentError(String error) {
    final e = error.toLowerCase();
    return e.startsWith('content not found') || e.contains('content_id is required');
  }
}

/// REST body and MQTT message: signed (v2) with a key, else the v1 body.
class PopEnvelope {
  static const action = 'content_proof_of_play';
  static const sender = 'linux';

  static String contentsJson(List<Map<String, dynamic>> entries) => jsonEncode(entries);

  static String restBody(String playerCode, List<Map<String, dynamic>> entries,
      String? keyHex, int tsSec) {
    final body = <String, dynamic>{'player_code': playerCode};
    if (keyHex != null) {
      _sign(body, playerCode, contentsJson(entries), keyHex, tsSec);
    } else {
      // v1: no `sender` (an older CMS rejects unknown REST fields).
      body['contents'] = entries;
    }
    return jsonEncode(body);
  }

  static String mqttMessage(String playerCode, List<Map<String, dynamic>> entries,
      String? keyHex, int tsSec) {
    final body = <String, dynamic>{'action': action};
    if (keyHex != null) {
      _sign(body, playerCode, contentsJson(entries), keyHex, tsSec);
    } else {
      body['sender'] = sender;
      body['contents'] = entries;
    }
    return jsonEncode(body);
  }

  static void _sign(Map<String, dynamic> body, String playerCode, String contents,
      String keyHex, int tsSec) {
    body['sender'] = sender;
    body['ts'] = tsSec;
    body['contents_json'] = contents;
    body['signature'] = PopSigning.sign(keyHex, tsSec, playerCode, contents);
  }
}

/// The running reporter: queue on disk, signing key, periodic delivery.
class LinuxPop {
  LinuxPop._();
  static final LinuxPop instance = LinuxPop._();

  static const publishIntervalMs = 120000;
  static const maxBatchSize = 200;
  static const maxBatchesPerRound = 10;
  static const batchGapMs = 500;
  static const _retryKeyFailedMs = 15 * 60 * 1000;
  static const _retryNoKeyMs = 60 * 60 * 1000;

  String _baseUrl = '';
  String _playerCode = '';
  void Function(String message)? _publishMqtt;
  bool Function()? _mqttConnected;
  Directory? _dir;
  final LinuxAtomicJson _storage = LinuxAtomicJson();
  PopQueue _queue = PopQueue();
  bool _loaded = false;
  Timer? _timer;
  int _failures = 0;
  bool _sending = false;
  String? _key;
  int _nextKeyRequestAtMs = 0;
  bool _recheckKey = false;
  final _random = Random.secure();
  http.Client _http = http.Client();

  /// Starts delivery for [playerCode]. [baseUrl] ends with `/v1/`.
  Future<void> start({
    required String baseUrl,
    required String playerCode,
    required void Function(String message) publishMqtt,
    required bool Function() mqttConnected,
    Directory? directory,
    http.Client? client,
  }) async {
    _baseUrl = baseUrl;
    _playerCode = playerCode;
    _publishMqtt = publishMqtt;
    _mqttConnected = mqttConnected;
    if (client != null) _http = client;
    _dir = directory ??
        Directory('${Platform.environment['HOME'] ?? '.'}/.local/share/signagex-player/pop');
    await _load();
    _schedule(5000);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The proof-of-play signing key (also signs proof screenshots).
  Future<String?> signingKey() => _ensureKey();

  /// A 401 elsewhere: check the key again on the next use.
  void recheckKey() => _recheckKey = true;

  /// A media item finished (or failed / ended early). Items without a library
  /// content id (web apps, compositions, text) are not reported.
  Future<void> record(PopPlay play) async {
    if (play.contentId.trim().isEmpty) return;
    await _load();
    _queue.record(play, _newId);
    await _persist();
  }

  String _newId() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  void _schedule(int ms) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: ms), () async {
      final next = await _publishPending();
      _schedule(next);
    });
  }

  Future<int> _publishPending() async {
    if (_sending) return publishIntervalMs;
    _sending = true;
    try {
      if (_playerCode.isEmpty || _baseUrl.isEmpty) return publishIntervalMs;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_queue.prune(now) > 0) await _persist();
      if (_queue.isEmpty) {
        _failures = 0;
        return publishIntervalMs;
      }
      for (var round = 0; round < maxBatchesPerRound; round++) {
        if (round > 0) await Future<void>.delayed(const Duration(milliseconds: batchGapMs));
        final batch = _queue.takeBatch(maxBatchSize);
        if (batch.isEmpty) return publishIntervalMs;
        await _persist();
        final key = await _ensureKey();
        final reports = [for (final e in batch) e.toReport()];
        final ids = [for (final e in batch) e.clientEventId];
        final outcome = await _postRest(reports, key, ids);
        switch (outcome.kind) {
          case PopOutcomeKind.processed:
            _failures = 0;
            _queue.remove(outcome.done);
            await _persist();
            if (outcome.retry.isNotEmpty) return publishIntervalMs;
          case PopOutcomeKind.drop:
            _failures = 0;
            _queue.remove(ids.toSet());
            await _persist();
          case PopOutcomeKind.unauthorized:
            _failures++;
            _recheckKey = true;
            return PopDelivery.backoffMs(_failures);
          case PopOutcomeKind.retry:
            _failures++;
            await _mqttFallback(batch, key);
            return PopDelivery.backoffMs(_failures);
        }
      }
      return publishIntervalMs;
    } catch (_) {
      _failures++;
      return PopDelivery.backoffMs(_failures);
    } finally {
      _sending = false;
    }
  }

  int get _nowSec => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<PopOutcome> _postRest(
      List<Map<String, dynamic>> reports, String? key, List<String> ids) async {
    try {
      final res = await _http
          .post(Uri.parse('${_baseUrl}player/content-proof-of-play'),
              headers: {'Content-Type': 'application/json'},
              body: PopEnvelope.restBody(_playerCode, reports, key, _nowSec))
          .timeout(const Duration(seconds: 30));
      return PopDelivery.classify(res.statusCode, res.body, ids);
    } catch (_) {
      return const PopOutcome(PopOutcomeKind.retry);
    }
  }

  /// Fallback only, not retained: a retained message would replace the CMS's
  /// retained playback message on this topic. Entries stay queued for REST.
  Future<void> _mqttFallback(List<PopEntry> batch, String? key) async {
    if (_mqttConnected?.call() != true) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = _queue.dueForMqtt(batch, now);
    if (due.isEmpty) return;
    _publishMqtt?.call(PopEnvelope.mqttMessage(
        _playerCode, [for (final e in due) e.toReport()], key, _nowSec));
    _queue.markMqttSent({for (final e in due) e.clientEventId}, now);
    await _persist();
  }

  /// Trust on first use: the CMS hands the key out once (201). A 409 means it
  /// already gave one; without it stored, an admin must reset the reporting
  /// key in the CMS. Until then plays go unsigned (v1).
  Future<String?> _ensureKey() async {
    if (_key != null && !_recheckKey) return _key;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _nextKeyRequestAtMs && !_recheckKey) return _key;
    try {
      final res = await _http
          .post(Uri.parse('${_baseUrl}player/pop-key'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'player_code': _playerCode}))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 200 || res.statusCode == 201) {
        String? key;
        try {
          final body = jsonDecode(res.body);
          if (body is Map) key = body['key']?.toString();
        } catch (_) {}
        if (PopSigning.isValidKey(key)) {
          _key = key!.toLowerCase();
          _recheckKey = false;
          await _writeJson('key.json', {'key': _key, 'player_code': _playerCode});
        } else {
          _nextKeyRequestAtMs = now + _retryKeyFailedMs;
        }
      } else if (res.statusCode == 409) {
        _recheckKey = false;
        _nextKeyRequestAtMs = now + (_key == null ? _retryNoKeyMs : _retryKeyFailedMs);
      } else {
        _nextKeyRequestAtMs = now + _retryKeyFailedMs;
      }
    } catch (_) {
      _nextKeyRequestAtMs = now + _retryKeyFailedMs;
    }
    return _key;
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final q = await _readJson('queue.json');
    if (q is List) {
      _queue = PopQueue([for (final e in q.map(PopEntry.fromJson)) if (e != null) e]);
    }
    final k = await _readJson('key.json');
    if (k is Map && k['player_code'] == _playerCode && PopSigning.isValidKey(k['key']?.toString())) {
      _key = k['key'].toString().toLowerCase();
    }
  }

  Future<void> _persist() =>
      _writeJson('queue.json', [for (final e in _queue.items) e.toJson()]);

  Future<Object?> _readJson(String name) async {
    try {
      final f = File('${_dir!.path}/$name');
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Atomic: write a temp file, then rename over the old one.
  Future<void> _writeJson(String name, Object value) async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await _storage.write(File('${dir.path}/$name'), value);
    } catch (error) {
      // Report persistence failures without logging the signing key or payload.
      stderr.writeln('SignageX proof-of-play persistence failed: ${error.runtimeType}');
    }
  }
}
