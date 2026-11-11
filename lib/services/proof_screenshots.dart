import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'linux_pop.dart';

/// Takes a picture of the whole screen. The player passes its existing X11
/// capture; a Wayland build plugs in its own (grim) without changes here.
abstract class ScreenCapture {
  Future<Uint8List?> capture();
}

class CallbackScreenCapture implements ScreenCapture {
  final Future<Uint8List?> Function() _capture;
  CallbackScreenCapture(this._capture);
  @override
  Future<Uint8List?> capture() => _capture();
}

/// Proof-of-play screenshots, as Android's ProofScreenshotManager:
/// `capture_proof_screenshot` ({request_id, campaign_id}) takes one now;
/// `proof_screenshot_schedule` ({interval_minutes, until, campaign_id}) takes
/// one every interval until `until` (0 stops). The schedule is saved and
/// resumed after a restart. Each JPEG (longest edge 1280 px, at most 2 MB) is
/// uploaded to `POST player/screenshot` (multipart: player_code, reason
/// requested|interval, request_id, campaign_id, image; signed with
/// ts + HMAC(sha256(image)) when the proof-of-play key is known), 3 attempts.
class ProofScreenshots {
  ProofScreenshots._();
  static final ProofScreenshots instance = ProofScreenshots._();

  static const maxEdge = 1280;
  static const maxBytes = 2 * 1024 * 1024;
  static const maxAttempts = 3;
  static const retryDelay = Duration(seconds: 20);

  ScreenCapture? capture;
  String _baseUrl = '';
  String _playerCode = '';
  Timer? _timer;
  Directory? _dir;
  http.Client client = http.Client();

  Future<void> start({
    required String baseUrl,
    required String playerCode,
    required ScreenCapture screenCapture,
    Directory? directory,
  }) async {
    _baseUrl = baseUrl;
    _playerCode = playerCode;
    capture = screenCapture;
    _dir = directory ??
        Directory('${Platform.environment['HOME'] ?? '.'}/.local/share/signagex-player');
    // Resume a saved schedule.
    try {
      final f = File('${_dir!.path}/proof-screenshot-schedule.json');
      if (await f.exists()) {
        final s = jsonDecode(await f.readAsString());
        if (s is Map) {
          _run(ScreenshotSchedule.fromJson(s));
        }
      }
    } catch (_) {}
  }

  /// capture_proof_screenshot
  Future<void> takeNow(Object? data) async {
    final d = data is Map ? data : const {};
    await _shoot('requested', d['request_id']?.toString(), d['campaign_id']?.toString());
  }

  /// proof_screenshot_schedule
  Future<void> applySchedule(Object? data, {DateTime? now}) async {
    final d = data is Map ? data : const {};
    final s = ScreenshotSchedule.fromMessage(d);
    final f = File('${_dir?.path ?? '.'}/proof-screenshot-schedule.json');
    if (s == null) {
      _timer?.cancel();
      _timer = null;
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return;
    }
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(s.toJson()), flush: true);
    } catch (_) {}
    _run(s);
  }

  void _run(ScreenshotSchedule s) {
    _timer?.cancel();
    if (s.isOver(DateTime.now())) return;
    _timer = Timer.periodic(Duration(minutes: s.intervalMinutes), (t) {
      if (s.isOver(DateTime.now())) {
        t.cancel();
        return;
      }
      unawaited(_shoot('interval', null, s.campaignId));
    });
  }

  Future<void> _shoot(String reason, String? requestId, String? campaignId) async {
    final c = capture;
    if (c == null || _playerCode.isEmpty || _baseUrl.isEmpty) return;
    final raw = await c.capture();
    if (raw == null || raw.isEmpty) return;
    final jpeg = shrink(raw);
    if (jpeg == null) return;
    await _upload(jpeg, reason, requestId, campaignId);
  }

  /// Longest edge at most 1280 px, JPEG at most 2 MB (quality steps down).
  static Uint8List? shrink(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes.length <= maxBytes ? bytes : null;
    var image = decoded;
    final edge = image.width > image.height ? image.width : image.height;
    if (edge > maxEdge) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxEdge)
          : img.copyResize(image, height: maxEdge);
    }
    for (var q = 85; q >= 25; q -= 15) {
      final out = Uint8List.fromList(img.encodeJpg(image, quality: q));
      if (out.length <= maxBytes) return out;
    }
    return null;
  }

  Future<void> _upload(Uint8List jpeg, String reason, String? requestId, String? campaignId) async {
    final sha = PopSigning.sha256Hex(jpeg);
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final key = await LinuxPop.instance.signingKey();
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final req = http.MultipartRequest('POST', Uri.parse('${_baseUrl}player/screenshot'))
        ..fields['player_code'] = _playerCode
        ..fields['reason'] = reason;
      if (key != null) {
        req.fields['ts'] = '$ts';
        req.fields['signature'] = PopSigning.sign(key, ts, _playerCode, sha);
      }
      if (requestId != null && requestId.isNotEmpty) req.fields['request_id'] = requestId;
      if (campaignId != null && campaignId.isNotEmpty) req.fields['campaign_id'] = campaignId;
      req.files.add(http.MultipartFile.fromBytes('image', jpeg, filename: 'proof.jpg'));
      int? code;
      try {
        code = (await client.send(req).timeout(const Duration(seconds: 60))).statusCode;
      } catch (_) {}
      if (code == 200 || code == 201) return;
      if (code == 400 || code == 413) return;
      if (code == 401) LinuxPop.instance.recheckKey();
      if (attempt < maxAttempts) await Future<void>.delayed(retryDelay * attempt);
    }
  }
}

class ScreenshotSchedule {
  final int intervalMinutes;
  final DateTime? until;
  final String? campaignId;
  const ScreenshotSchedule(this.intervalMinutes, this.until, this.campaignId);

  /// Null when the message turns screenshots off (interval 0 or missing).
  static ScreenshotSchedule? fromMessage(Map d) {
    final minutes = int.tryParse('${d['interval_minutes'] ?? 0}') ?? 0;
    if (minutes <= 0) return null;
    final until = d['until'] == null ? null : DateTime.tryParse('${d['until']}');
    return ScreenshotSchedule(minutes < 1 ? 1 : minutes, until, d['campaign_id']?.toString());
  }

  static ScreenshotSchedule fromJson(Map d) => ScreenshotSchedule(
        int.tryParse('${d['interval_minutes'] ?? 5}') ?? 5,
        d['until'] == null ? null : DateTime.tryParse('${d['until']}'),
        d['campaign_id']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'interval_minutes': intervalMinutes,
        'until': until?.toUtc().toIso8601String(),
        'campaign_id': campaignId,
      };

  bool isOver(DateTime now) => until != null && !now.isBefore(until!);
}
