import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'linux_asset_cache.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Linux trigger runtime uses the CMS snake_case payload, independently of the
/// obsolete typed model. Network APIs are deliberately not opened on the Pi.
class LinuxInteractivity extends ChangeNotifier {
  static final instance = LinuxInteractivity();
  List<Map<String, dynamic>> items = [];
  Map<String, dynamic>? active;
  final List<Map<String, dynamic>> _queue = [];
  HttpServer? _api;
  HttpServer? _compatApi;
  String? _token;
  Timer? _clock;
  Timer? _end;
  DateTime _lastInput = DateTime.now();
  final Set<String> _fired = {};
  bool Function(Map<String, dynamic>) allowed = (_) => true;
  Future<void> Function(String, String)? event;
  bool get overlay => active?['item']?['play_on_top'] == true;

  Future<void> start() async {
    if (_clock != null) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      items =
          (jsonDecode(prefs.getString('linux_interactivity') ?? '[]') as List)
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
    } catch (_) {}
    _fired.addAll(prefs.getStringList('linux_trigger_fired') ?? []);
    await _startLocalApi();
    _clock =
        Timer.periodic(const Duration(seconds: 1), (_) => tick(DateTime.now()));
  }

  Future<void> _startLocalApi() async {
    try {
      final directory = Directory(
          '${Platform.environment['HOME']}/.local/share/signagex-player/control');
      await directory.create(recursive: true);
      await Process.run('chmod', ['700', directory.path]);
      final file = File('${directory.path}/api-token');
      _token = await file.exists()
          ? (await file.readAsString()).trim()
          : base64Url
              .encode(List.generate(32, (_) => Random.secure().nextInt(256)));
      await file.writeAsString(_token!);
      await Process.run('chmod', ['600', file.path]);
      _api = await HttpServer.bind(InternetAddress.loopbackIPv4, 1999);
      _api!.idleTimeout = const Duration(seconds: 10);
      _api!.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.method != 'POST' ||
            request.contentLength > 0 ||
            request.headers.value(HttpHeaders.authorizationHeader) !=
                'Bearer $_token') {
          request.response.statusCode = HttpStatus.forbidden;
        } else {
          final path = request.uri.path;
          final matches = items.where((item) =>
              (item['local_api'] as List? ?? []).any((name) =>
                  path ==
                  '/v1/interactivity/${Uri.encodeComponent(name.toString())}'));
          request.response.statusCode = matches.isNotEmpty &&
                  activate(matches.first['id'], source: 'local_api')
              ? HttpStatus.ok
              : HttpStatus.notFound;
        }
        request.response.write(jsonEncode(
            {'success': request.response.statusCode == HttpStatus.ok}));
        await request.response.close();
      });
    } catch (error) {
      await event?.call('Local trigger API unavailable: $error', 'warning');
    }
    await _startCompatApi();
  }

  /// The Local API address the CMS shows (and the Android player serves):
  /// `GET|POST http://127.0.0.1:5544/trigger/{value}`, loopback only, no token.
  /// Matching follows Android: a configured value fires when the received one
  /// contains it (case-insensitive), or when it is a regular expression that
  /// matches. The first allowed match plays; later ones only with `propagate`.
  Future<void> _startCompatApi() async {
    try {
      _compatApi = await HttpServer.bind(InternetAddress.loopbackIPv4, 5544);
      _compatApi!.idleTimeout = const Duration(seconds: 10);
      _compatApi!.listen((request) async {
        final response = request.response;
        response.headers.contentType = ContentType.json;
        final segments = request.uri.pathSegments;
        var fired = 0;
        if ((request.method == 'GET' || request.method == 'POST') &&
            segments.length >= 2 &&
            segments.first == 'trigger') {
          fired = triggerLocalApi(segments.skip(1).join('/'));
          response.statusCode = fired > 0 ? HttpStatus.ok : HttpStatus.notFound;
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        try {
          await request.drain<void>();
        } catch (_) {}
        response.write(jsonEncode({'success': fired > 0, 'fired': fired}));
        await response.close();
      });
    } catch (error) {
      await event?.call('Local trigger API on port 5544 unavailable: $error', 'warning');
    }
  }

  /// Fires the items whose Local API value matches [received]; returns how
  /// many ran.
  int triggerLocalApi(String received) {
    final value = received.trim();
    if (value.isEmpty) return 0;
    var fired = 0;
    for (final item in items) {
      final patterns = (item['local_api'] as List? ?? []).map((e) => '$e');
      if (!patterns.any((p) => localApiMatches(p, value))) continue;
      if (!activate(item['id'], source: 'local_api')) continue;
      fired++;
      if (item['propagate'] != true) break;
    }
    return fired;
  }

  int generation = 0;
  Future<bool> replace(List<dynamic> raw) async {
    final requestGeneration = ++generation;
    final next = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (next.length > 1000) throw const FormatException('Too many triggers');
    for (final item in next) {
      if (item['id'] is! String || item['triggers'] is! List)
        throw const FormatException('Invalid trigger definition');
      for (final trigger in item['triggers']) {
        if (!['play', 'stop', 'enqueue', 'enqueue_and_play']
            .contains(trigger['trigger_type']?.toString().toLowerCase()))
          throw const FormatException('Unsupported trigger action');
      }
    }
    items = next;
    _queue.clear();
    if (active != null) finish();
    await (await SharedPreferences.getInstance())
        .setString('linux_interactivity', jsonEncode(items));
    return await prepareMedia() && requestGeneration == generation;
  }

  Future<bool> prepareMedia() async {
    var ready = true;
    Future<void> visit(dynamic value) async {
      if (value is List) {
        for (final child in value) {
          await visit(child);
        }
      }
      if (value is Map) {
        final kind = (value['mediaType'] ?? value['media_type'] ?? '')
            .toString()
            .toLowerCase();
        if ((kind.contains('image') ||
                kind.contains('video') ||
                kind.contains('audio')) &&
            value['mediaUrl'] is String) {
          final original = value['_origin_url'] ?? value['mediaUrl'];
          final path = await LinuxAssetCache.instance.fetch(original);
          if (path == null)
            ready = false;
          else {
            value['_origin_url'] = original;
            value['mediaUrl'] = path;
          }
        }
        for (final key in ['triggers', 'content', 'zones', 'mediaItems']) {
          await visit(value[key]);
        }
      }
    }

    final urls = <String>{};
    void collect(dynamic value) {
      if (value is List) {
        for (final child in value) {
          collect(child);
        }
      }
      if (value is Map) {
        final kind = (value['mediaType'] ?? value['media_type'] ?? '')
            .toString()
            .toLowerCase();
        final url = value['_origin_url'] ?? value['mediaUrl'];
        if ((kind.contains('image') ||
                kind.contains('video') ||
                kind.contains('audio')) &&
            url is String &&
            url.startsWith('http')) urls.add(url);
        for (final key in ['triggers', 'content', 'zones', 'mediaItems']) {
          collect(value[key]);
        }
      }
    }

    collect(items);
    await LinuxAssetCache.instance.retain(urls);
    await visit(items);
    await (await SharedPreferences.getInstance())
        .setString('linux_interactivity', jsonEncode(items));
    return ready;
  }

  bool activate(String id, {String source = 'on_demand'}) {
    final matching =
        items.where((e) => e['id'] == id && e['pause'] != true && allowed(e));
    if (matching.isEmpty) return false;
    final item = matching.first;
    if (source == 'on_demand' && item['on_demand'] != true) return false;
    final triggers = item['triggers'] as List? ?? [];
    if (triggers.isEmpty) return false;
    final trigger = Map<String, dynamic>.from(triggers.first);
    bool pending(dynamic value) {
      if (value is List) return value.any(pending);
      if (value is Map) {
        final kind = (value['mediaType'] ?? '').toString().toLowerCase();
        if ((kind.contains('image') ||
                kind.contains('video') ||
                kind.contains('audio')) &&
            (value['mediaUrl']?.toString().startsWith('http') ?? false))
          return true;
        return ['content', 'zones', 'mediaItems']
            .any((key) => pending(value[key]));
      }
      return false;
    }

    if (pending(trigger)) {
      unawaited(event?.call('Trigger media waiting for download', 'warning') ??
          Future.value());
      return false;
    }
    final type = trigger['trigger_type'].toString().toLowerCase();
    unawaited(event?.call(
            'Interactivity ${item['name'] ?? id}: $source ($type)', 'info') ??
        Future.value());
    if (type == 'stop') {
      _queue.clear();
      finish();
      return true;
    }
    final activation = <String, dynamic>{'item': item, 'trigger': trigger};
    if (type == 'enqueue' || (active != null && type == 'enqueue_and_play')) {
      if (_queue.length < 100) _queue.add(activation);
      return true;
    }
    _show(activation);
    return true;
  }

  void _show(Map<String, dynamic> activation) {
    if (!allowed(Map<String, dynamic>.from(activation['item']))) {
      finish();
      return;
    }
    _end?.cancel();
    active = activation;
    final trigger = activation['trigger'] as Map;
    var seconds = int.tryParse(trigger['duration']?.toString() ?? '') ?? 30;
    if (seconds <= 0) seconds = 30;
    if (trigger['playing_loop'] != true)
      _end = Timer(Duration(seconds: seconds.clamp(1, 86400)), finish);
    notifyListeners();
  }

  void boundary() {
    if (active == null && _queue.isNotEmpty) _show(_queue.removeAt(0));
  }

  void finish() {
    _end?.cancel();
    active = null;
    if (_queue.isNotEmpty)
      _show(_queue.removeAt(0));
    else
      notifyListeners();
  }

  void input() {
    _lastInput = DateTime.now();
  }

  bool key(String key, {bool consumeOnly = false}) {
    input();
    for (final item in items) {
      if ((item['key_press'] as List? ?? [])
              .any((v) => _keyName(v.toString()) == _keyName(key)) &&
          activate(item['id'], source: 'key'))
        return consumeOnly ? item['propagate'] != true : true;
    }
    return false;
  }

  String _keyName(String value) => value == ' '
      ? 'space'
      : value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  List<List<double>> captureRegions(double width, double height) {
    final result = <List<double>>[];
    for (final item in items) {
      if (item['touch_region'] != true ||
          item['propagate'] == true ||
          item['pause'] == true ||
          !allowed(item)) continue;
      for (final region in item['control'] as List? ?? []) {
        if (region['any_region'] == true) {
          result.add([0, 0, width, height]);
          continue;
        }
        final relative = region['relative'] as Map?;
        final sx =
            width / (item['resolution_width'] as num? ?? width).clamp(1, 8192);
        final sy = height /
            (item['resolution_height'] as num? ?? height).clamp(1, 8192);
        final left = relative != null
            ? (relative['x'] as num).toDouble() * width
            : (region['x'] as num? ?? 0) * sx;
        final top = relative != null
            ? (relative['y'] as num).toDouble() * height
            : (region['y'] as num? ?? 0) * sy;
        final w = relative != null
            ? (relative['width'] as num).toDouble() * width
            : (region['width'] as num? ?? 0) * sx;
        final h = relative != null
            ? (relative['height'] as num).toDouble() * height
            : (region['height'] as num? ?? 0) * sy;
        if (w > 0 && h > 0) result.add([left, top, w, h]);
      }
    }
    return result;
  }

  bool touch(double x, double y, double width, double height) {
    input();
    if (width <= 0 || height <= 0) return false;
    for (final item in items) {
      if (item['touch_region'] != true) continue;
      for (final region in item['control'] as List? ?? []) {
        final relative = region['relative'] as Map?;
        final sx =
            width / ((item['resolution_width'] as num?)?.toDouble() ?? width);
        final sy = height /
            ((item['resolution_height'] as num?)?.toDouble() ?? height);
        final left = relative != null
            ? (relative['x'] as num).toDouble() * width
            : (region['x'] as num? ?? 0) * sx;
        final top = relative != null
            ? (relative['y'] as num).toDouble() * height
            : (region['y'] as num? ?? 0) * sy;
        final w = relative != null
            ? (relative['width'] as num).toDouble() * width
            : (region['width'] as num? ?? 0) * sx;
        final h = relative != null
            ? (relative['height'] as num).toDouble() * height
            : (region['height'] as num? ?? 0) * sy;
        if ((region['any_region'] == true ||
                x >= left && x < left + w && y >= top && y < top + h) &&
            activate(item['id'], source: 'touch')) return true;
      }
    }
    return false;
  }

  void tick(DateTime now) {
    if (active != null && !allowed(Map<String, dynamic>.from(active!['item'])))
      finish();
    for (final item in items) {
      for (final raw in item['specific_time'] as List? ?? []) {
        final at = DateTime.tryParse(raw.toString());
        final key = '${item['id']}:$raw';
        if (at != null &&
            !now.isBefore(at) &&
            now.difference(at).inSeconds < 2 &&
            _fired.add(key)) {
          activate(item['id'], source: 'specific_time');
          unawaited(SharedPreferences.getInstance().then((prefs) =>
              prefs.setStringList('linux_trigger_fired',
                  _fired.toList().reversed.take(1000).toList())));
        }
      }
      Iterable<Map> restrictions(Map group) sync* {
        yield* (group['restrictions'] as List? ?? []).whereType<Map>();
        for (final nested
            in (group['groups'] as List? ?? []).whereType<Map>()) {
          yield* restrictions(nested);
        }
      }

      for (final rule in (item['restriction_groups'] as List? ?? [])
          .whereType<Map>()
          .expand(restrictions)) {
        if (rule['type']?.toString().toLowerCase() != 'time') continue;
        final operator =
            rule['operator']?.toString().toLowerCase().replaceAll('_', '-');
        final boundary = now.second < 2 &&
            (operator == 'every-minute' ||
                operator == 'every-hour' && now.minute == 0 ||
                operator == 'every-day' && now.hour == 0 && now.minute == 0 ||
                operator == 'every-week' &&
                    now.weekday == DateTime.sunday &&
                    now.hour == 0 &&
                    now.minute == 0);
        final key =
            '${item['id']}:$operator:${now.year}-${now.month}-${now.day}-${now.hour}-${now.minute}';
        if (boundary && _fired.add(key)) {
          activate(item['id'], source: 'recurring');
          unawaited(SharedPreferences.getInstance().then((prefs) =>
              prefs.setStringList('linux_trigger_fired',
                  _fired.toList().reversed.take(1000).toList())));
        }
      }
      final idle = (item['interactivity_timeout'] as num?)?.toInt() ?? 0;
      if (idle > 0 && now.difference(_lastInput).inSeconds >= idle) {
        _lastInput = now;
        if (active != null)
          finish();
        else
          activate(item['id'], source: 'idle');
      }
    }
  }

  void close() {
    _clock?.cancel();
    _end?.cancel();
    _api?.close(force: true);
    _compatApi?.close(force: true);
  }
}

/// Android's Local API rule: the received value contains the configured one
/// (ignoring case), or the configured one is a regular expression that matches.
bool localApiMatches(String pattern, String received) {
  final p = pattern.trim();
  if (p.isEmpty) return false;
  if (received.toLowerCase().contains(p.toLowerCase())) return true;
  try {
    return RegExp(p, caseSensitive: false).hasMatch(received);
  } catch (_) {
    return false;
  }
}
