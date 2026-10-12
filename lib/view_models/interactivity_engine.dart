import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:digital_signage/models/compaign_model.dart';

// Interactivity ("Triggers" in the CMS): the player's list arrives whole in
// `create_interactivity` on every create, update and delete, and
// `run_interactivity` fires one on demand. Content is shown on top of
// whatever the player is doing, using the normal campaign renderer -- see
// InteractivityOverlay in campaign_view.dart.
//
// The previous handling listened for `publish_interactivity`, which the
// backend never sends, and only logged key matches, so no trigger ever ran.

double? _ixDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

bool _ixBool(dynamic v) => v == true || v == 'true' || v == 1;

List<String> _ixStrings(dynamic v) {
  if (v is! List) return const [];
  return v
      .where((e) => e != null)
      .map((e) => e.toString().trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

Map<String, dynamic> _ixMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// One touch region. `relative` (0..1 of the screen) is preferred; the
/// pixel values are in the interactivity's resolution and are the fallback.
class IxControl {
  final bool anyRegion;
  final double? x, y, width, height;
  final double? relX, relY, relWidth, relHeight;

  IxControl({
    required this.anyRegion,
    this.x,
    this.y,
    this.width,
    this.height,
    this.relX,
    this.relY,
    this.relWidth,
    this.relHeight,
  });

  factory IxControl.fromJson(Map<String, dynamic> json) {
    final rel = _ixMap(json['relative']);
    return IxControl(
      anyRegion: _ixBool(json['any_region']),
      x: _ixDouble(json['x']),
      y: _ixDouble(json['y']),
      width: _ixDouble(json['width']),
      height: _ixDouble(json['height']),
      relX: _ixDouble(rel['x']),
      relY: _ixDouble(rel['y']),
      relWidth: _ixDouble(rel['width']),
      relHeight: _ixDouble(rel['height']),
    );
  }

  /// [rx]/[ry] are the tap as fractions of the interactivity's stage.
  bool contains(double rx, double ry, double resW, double resH) {
    if (anyRegion) return true;
    double? l = relX, t = relY, w = relWidth, h = relHeight;
    if (l == null || t == null || w == null || h == null) {
      if (x == null || y == null || width == null || height == null) {
        return false;
      }
      l = x! / resW;
      t = y! / resH;
      w = width! / resW;
      h = height! / resH;
    }
    return rx >= l && rx <= l + w && ry >= t && ry <= t + h;
  }
}

class IxRestrictionGroup {
  final String operator;
  final List<Restriction> restrictions;
  final List<IxRestrictionGroup> groups;

  IxRestrictionGroup(this.operator, this.restrictions, this.groups);

  factory IxRestrictionGroup.fromJson(Map<String, dynamic> json) =>
      IxRestrictionGroup(
        (json['operator'] ?? 'AND').toString().toUpperCase(),
        (json['restrictions'] is List ? json['restrictions'] as List : const [])
            .whereType<Map>()
            .map((r) => Restriction.fromJson(Map<String, dynamic>.from(r)))
            .toList(),
        (json['groups'] is List ? json['groups'] as List : const [])
            .whereType<Map>()
            .map((g) => IxRestrictionGroup.fromJson(Map<String, dynamic>.from(g)))
            .toList(),
      );
}

class IxTrigger {
  final String type;
  final int durationSeconds;
  final int? volume;

  /// Each content entry, converted to the campaign model the renderer
  /// already draws. Media URLs are rewritten to local files once
  /// downloaded, in place.
  final List<Campaign> campaigns;

  IxTrigger(this.type, this.durationSeconds, this.volume, this.campaigns);

  factory IxTrigger.fromJson(Map<String, dynamic> json, String ownerId) {
    final volume = _ixDouble(json['volume'])?.round();
    final duration = _ixDouble(json['duration'])?.round() ?? 0;
    final content = json['content'] is List ? json['content'] as List : const [];
    final campaigns = <Campaign>[];
    for (var i = 0; i < content.length; i++) {
      final c = content[i];
      if (c is! Map) continue;
      final campaign =
          _contentToCampaign(Map<String, dynamic>.from(c), ownerId, i, volume);
      if (campaign != null) campaigns.add(campaign);
    }
    return IxTrigger(
      (json['trigger_type'] ?? '').toString().toLowerCase(),
      duration > 0 ? duration : 10,
      volume,
      campaigns,
    );
  }

  /// Trigger content carries zones/mediaItems in exactly the shape a
  /// publish_campaign campaign does, so it becomes one. Its coordinate
  /// space is the zones' bounding box: a campaign brings its own layout
  /// (e.g. 1280x720), a playlist/composition/web app fills 1920x1080.
  static Campaign? _contentToCampaign(
    Map<String, dynamic> content,
    String ownerId,
    int index,
    int? volume,
  ) {
    var zones = content['zones'] is List ? content['zones'] as List : const [];
    final url = content['mediaUrl']?.toString() ?? '';
    if (zones.isEmpty && url.isNotEmpty) {
      // Older plain-media content: one full-screen zone.
      zones = [
        {
          'id': 1,
          'x': 0,
          'y': 0,
          'width': 1920,
          'height': 1080,
          'mediaItems': [content],
        }
      ];
    }
    if (zones.isEmpty) return null;

    double maxW = 0, maxH = 0;
    final zoneJson = <Map<String, dynamic>>[];
    for (final z in zones) {
      if (z is! Map) continue;
      final zone = Map<String, dynamic>.from(z);
      maxW = math.max(maxW,
          (_ixDouble(zone['x']) ?? 0) + (_ixDouble(zone['width']) ?? 0));
      maxH = math.max(maxH,
          (_ixDouble(zone['y']) ?? 0) + (_ixDouble(zone['height']) ?? 0));
      final items = (zone['mediaItems'] is List
              ? zone['mediaItems'] as List
              : const [])
          .whereType<Map>()
          .map((m) {
        final item = Map<String, dynamic>.from(m);
        final settings = _ixMap(item['settings']);
        if (volume != null) settings['volume'] = volume;
        item['settings'] = settings;
        item['schedule'] ??= {'always_play': true};
        return item;
      }).toList();
      zone['mediaItems'] = items;
      zoneJson.add(zone);
    }

    try {
      return Campaign.fromJson({
        'playback_type': 'campaign',
        'campaign_id': 'interactivity_${ownerId}_${content['id'] ?? index}',
        'campaign_name': content['name']?.toString() ?? 'Interactivity',
        'resolution': {
          'width': maxW > 0 ? maxW.round() : 1920,
          'height': maxH > 0 ? maxH.round() : 1080,
        },
        'campaign_schedule': {'always_play': true},
        'campaign_settings': {'transition': 'none', 'loop': false},
        'zones': zoneJson,
      });
    } catch (_) {
      return null;
    }
  }

  /// How long a content entry runs on its own: the longest zone's total.
  static int naturalSeconds(Campaign c) {
    var longest = 0;
    for (final z in c.zones ?? const <CampaignZone>[]) {
      var sum = 0;
      for (final m in z.mediaItems ?? const <MediaItem>[]) {
        final d = m.settings?.duration ?? 0;
        sum += d > 0 ? d : 10;
      }
      longest = math.max(longest, sum);
    }
    return longest > 0 ? longest : 10;
  }
}

class IxInteractivity {
  final String id;
  final String name;
  final bool pause;
  final List<String> keyPress;
  final bool touchRegion;
  final List<IxControl> controls;
  final List<String> localApi;
  final bool onDemand;
  final double? timeoutSeconds;
  final List<String> specificTimes;
  final bool alwaysPlay;
  final Map<String, dynamic> period;
  final List<IxRestrictionGroup> restrictionGroups;
  final double? resolutionWidth;
  final double? resolutionHeight;
  final List<IxTrigger> triggers;

  IxInteractivity({
    required this.id,
    required this.name,
    required this.pause,
    required this.keyPress,
    required this.touchRegion,
    required this.controls,
    required this.localApi,
    required this.onDemand,
    required this.timeoutSeconds,
    required this.specificTimes,
    required this.alwaysPlay,
    required this.period,
    required this.restrictionGroups,
    required this.resolutionWidth,
    required this.resolutionHeight,
    required this.triggers,
  });

  factory IxInteractivity.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString();
    final schedule = _ixMap(json['schedule']);
    return IxInteractivity(
      id: id,
      name: (json['name'] ?? '').toString(),
      pause: _ixBool(json['pause']),
      keyPress: _ixStrings(json['key_press']),
      touchRegion: _ixBool(json['touch_region']),
      controls: (json['control'] is List ? json['control'] as List : const [])
          .whereType<Map>()
          .map((c) => IxControl.fromJson(Map<String, dynamic>.from(c)))
          .toList(),
      localApi: _ixStrings(json['local_api']),
      onDemand: _ixBool(json['on_demand']),
      timeoutSeconds: _ixDouble(json['interactivity_timeout']),
      specificTimes: _ixStrings(json['specific_time']),
      alwaysPlay: _ixBool(schedule['always_play']),
      period: _ixMap(schedule['period']),
      restrictionGroups: (json['restriction_groups'] is List
              ? json['restriction_groups'] as List
              : const [])
          .whereType<Map>()
          .map((g) =>
              IxRestrictionGroup.fromJson(Map<String, dynamic>.from(g)))
          .toList(),
      resolutionWidth: _ixDouble(json['resolution_width']),
      resolutionHeight: _ixDouble(json['resolution_height']),
      triggers: (json['triggers'] is List ? json['triggers'] as List : const [])
          .whereType<Map>()
          .map((t) => IxTrigger.fromJson(Map<String, dynamic>.from(t), id))
          .toList(),
    );
  }
}

class InteractivityEngine extends ChangeNotifier {
  /// Same port as the Chromium player's server, so every player answers
  /// the local API at the same address.
  static const int localApiPort = 5757;

  InteractivityEngine({
    required this.evaluateRestriction,
    required this.prepareMedia,
    required this.log,
  }) {
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _startLocalApi();
  }

  final bool Function(Restriction restriction) evaluateRestriction;
  final Future<void> Function(List<Campaign> campaigns) prepareMedia;
  final void Function(String message) log;

  List<IxInteractivity> _items = const [];
  List<IxInteractivity> get items => _items;

  // -- what is on screen --
  Campaign? _activeCampaign;
  Campaign? get activeCampaign => _activeCampaign;

  /// Changes on every show, so showing the same content twice in a row
  /// still rebuilds (and restarts) its renderer.
  int _showToken = 0;
  int get showToken => _showToken;

  IxTrigger? _activeTrigger;
  int _contentIndex = 0;
  DateTime? _deadline;
  Timer? _showTimer;
  final List<IxTrigger> _queue = [];

  // -- conditions that are not input events --
  Timer? _tick;
  DateTime? _lastInput;
  final Set<String> _timeoutFired = {};
  final Set<String> _specificFired = {};
  HttpServer? _server;

  /// Replaces the whole list -- create_interactivity always carries it all.
  void setList(dynamic raw, {String source = 'mqtt'}) {
    final list = raw is List ? raw : const [];
    final parsed = <IxInteractivity>[];
    for (final item in list) {
      if (item is! Map) continue;
      try {
        parsed.add(IxInteractivity.fromJson(Map<String, dynamic>.from(item)));
      } catch (e) {
        log('could not read an interactivity ($e) -- skipped');
      }
    }
    _items = parsed;
    _queue.clear();
    log('list from $source: ${parsed.length} '
        '[${parsed.map((i) => i.name).join(", ")}]');

    final campaigns = <Campaign>[
      for (final i in parsed)
        for (final t in i.triggers) ...t.campaigns,
    ];
    if (campaigns.isNotEmpty) {
      prepareMedia(campaigns).then((_) {
        log('content media ready (${campaigns.length} content item(s))');
        notifyListeners();
      }).catchError((Object e) {
        log('content media download failed: $e');
      });
    }
    notifyListeners();
  }

  void clear() {
    _items = const [];
    _queue.clear();
    _endActive(playQueued: false);
  }

  // ---------------------------------------------------------------- gate --

  static const _weekdays = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];

  bool _passesGate(IxInteractivity it) {
    if (it.pause) {
      log('"${it.name}" not fired: paused');
      return false;
    }
    final now = DateTime.now();
    if (!it.alwaysPlay && !_periodAllows(it.period, now)) {
      log('"${it.name}" not fired: outside its schedule');
      return false;
    }
    for (final group in it.restrictionGroups) {
      if (!_groupPasses(group)) {
        log('"${it.name}" not fired: restrictions not met');
        return false;
      }
    }
    return true;
  }

  bool _periodAllows(Map<String, dynamic> period, DateTime now) {
    final days = period['days'];
    if (days is Map && days.isNotEmpty) {
      if (!_ixBool(days[_weekdays[now.weekday - 1]])) return false;
    }
    final date = _ixMap(period['date']);
    final start = DateTime.tryParse(
        (date['start'] ?? date['from'] ?? date['start_date'] ?? '').toString());
    final end = DateTime.tryParse(
        (date['end'] ?? date['to'] ?? date['end_date'] ?? '').toString());
    final today = DateTime(now.year, now.month, now.day);
    if (start != null &&
        today.isBefore(DateTime(start.year, start.month, start.day))) {
      return false;
    }
    if (end != null && today.isAfter(DateTime(end.year, end.month, end.day))) {
      return false;
    }
    final time = _ixMap(period['time']);
    final from = _minutes(time['start'] ?? time['from'] ?? time['start_time']);
    final to = _minutes(time['end'] ?? time['to'] ?? time['end_time']);
    final nowMin = now.hour * 60 + now.minute;
    if (from != null && to != null) {
      return from <= to
          ? nowMin >= from && nowMin <= to
          : nowMin >= from || nowMin <= to; // crosses midnight
    }
    if (from != null && nowMin < from) return false;
    if (to != null && nowMin > to) return false;
    return true;
  }

  static int? _minutes(dynamic value) {
    final s = value?.toString().trim() ?? '';
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(s);
    if (m == null) return null;
    return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
  }

  bool _groupPasses(IxRestrictionGroup group) {
    final results = <bool>[
      for (final r in group.restrictions) evaluateRestriction(r),
      for (final g in group.groups) _groupPasses(g),
    ];
    if (results.isEmpty) return true;
    return group.operator == 'OR'
        ? results.any((r) => r)
        : results.every((r) => r);
  }

  // ----------------------------------------------------------- conditions --

  /// [labels] are every name the key goes by (character, key label, ...).
  void onKey(List<String> labels) {
    _markInput();
    final pressed = labels
        .map((l) => l.trim().toLowerCase())
        .where((l) => l.isNotEmpty)
        .toSet();
    if (pressed.contains(' ')) pressed.add('space');
    for (final it in _items) {
      if (it.keyPress.any((k) => pressed.contains(k.toLowerCase()))) {
        _fire(it, 'key ${labels.first}');
      }
    }
  }

  /// [position] and [window] in the same logical pixels. The regions are
  /// laid out on the interactivity's resolution fitted to the window --
  /// the same fit-and-letterbox the campaign stage uses.
  void onTap(double x, double y, double windowW, double windowH) {
    _markInput();
    for (final it in _items) {
      if (!it.touchRegion || it.controls.isEmpty) continue;
      final resW = (it.resolutionWidth ?? 0) > 0 ? it.resolutionWidth! : windowW;
      final resH =
          (it.resolutionHeight ?? 0) > 0 ? it.resolutionHeight! : windowH;
      final scale = math.min(windowW / resW, windowH / resH);
      final offX = (windowW - resW * scale) / 2;
      final offY = (windowH - resH * scale) / 2;
      final rx = (x - offX) / (resW * scale);
      final ry = (y - offY) / (resH * scale);
      if (it.controls.any((c) => c.contains(rx, ry, resW, resH))) {
        _fire(it, 'touch ${x.round()},${y.round()}');
      }
    }
  }

  /// run_interactivity from the CMS.
  void runById(String id) {
    final matches = _items.where((i) => i.id == id).toList();
    if (matches.isEmpty) {
      log('run_interactivity: no interactivity with id $id on this player');
      return;
    }
    _fire(matches.first, 'on demand');
  }

  /// Names of the interactivities a local API request fired.
  List<String> onLocalApi(String pathAndQuery) {
    final fired = <String>[];
    for (final it in _items) {
      if (it.localApi.any((a) => pathAndQuery.contains(a))) {
        if (_fire(it, 'local api $pathAndQuery')) fired.add(it.name);
      }
    }
    return fired;
  }

  void _markInput() {
    _lastInput = DateTime.now();
    _timeoutFired.clear();
  }

  void _onTick() {
    final now = DateTime.now();
    for (final it in _items) {
      final timeout = it.timeoutSeconds;
      if (timeout != null &&
          timeout > 0 &&
          _lastInput != null &&
          !_timeoutFired.contains(it.id) &&
          now.difference(_lastInput!).inMilliseconds >= timeout * 1000) {
        _timeoutFired.add(it.id);
        _fire(it, 'no input for ${timeout.round()}s');
      }
      for (final s in it.specificTimes) {
        final at = DateTime.tryParse(s);
        if (at == null) continue;
        final key = '${it.id}|$s';
        final overdue = now.difference(at);
        if (!_specificFired.contains(key) &&
            !overdue.isNegative &&
            overdue.inSeconds < 60) {
          _specificFired.add(key);
          _fire(it, 'specific time $s');
        }
      }
    }
  }

  Future<void> _startLocalApi() async {
    try {
      final server = await HttpServer.bind(
          InternetAddress.anyIPv4, localApiPort,
          shared: true);
      _server = server;
      log('local API listening on port $localApiPort');
      server.listen((request) async {
        final target = request.uri.toString();
        final fired = onLocalApi(target);
        log('local API ${request.method} $target -> '
            '${fired.isEmpty ? "no match" : fired.join(", ")}');
        final response = request.response;
        response.headers
          ..set('Access-Control-Allow-Origin', '*')
          ..contentType = ContentType.json;
        response.statusCode =
            fired.isEmpty ? HttpStatus.notFound : HttpStatus.ok;
        response.write(jsonEncode(fired.isEmpty
            ? {'ok': false}
            : {'ok': true, 'fired': fired}));
        await response.close();
      }, onError: (Object e) => log('local API error: $e'));
    } catch (e) {
      log('local API could not start on port $localApiPort: $e');
    }
  }

  // ------------------------------------------------------------- actions --

  bool _fire(IxInteractivity it, String why) {
    if (!_passesGate(it)) return false;
    log('fired "${it.name}" by $why (${it.triggers.length} trigger(s))');
    for (final trigger in it.triggers) {
      switch (trigger.type) {
        case 'play':
        case 'enqueue_and_play':
          _play(trigger);
          break;
        case 'enqueue':
          _queue.add(trigger);
          log('enqueued "${it.name}" (queue ${_queue.length})');
          break;
        case 'stop':
          log('stop');
          _queue.clear();
          _endActive(playQueued: false);
          break;
        default:
          log('unknown trigger type "${trigger.type}" -- ignored');
      }
    }
    return true;
  }

  void _play(IxTrigger trigger) {
    if (trigger.campaigns.isEmpty) {
      log('trigger has no content to show');
      return;
    }
    _showTimer?.cancel();
    _activeTrigger = trigger;
    _contentIndex = 0;
    _deadline =
        DateTime.now().add(Duration(seconds: trigger.durationSeconds));
    log('playing for ${trigger.durationSeconds}s '
        '(${trigger.campaigns.length} content item(s))');
    _showNext();
  }

  void _showNext() {
    final trigger = _activeTrigger;
    final deadline = _deadline;
    if (trigger == null || deadline == null) return;
    final remaining = deadline.difference(DateTime.now());
    if (_contentIndex >= trigger.campaigns.length || remaining.inSeconds <= 0) {
      _endActive(playQueued: true);
      return;
    }
    final campaign = trigger.campaigns[_contentIndex];
    final isLast = _contentIndex == trigger.campaigns.length - 1;
    _contentIndex++;
    final slot = isLast
        ? remaining
        : Duration(
            seconds: math.min(
                IxTrigger.naturalSeconds(campaign), remaining.inSeconds));
    _activeCampaign = campaign;
    _showToken++;
    notifyListeners();
    _showTimer = Timer(slot, _showNext);
  }

  void _endActive({required bool playQueued}) {
    _showTimer?.cancel();
    _showTimer = null;
    _activeTrigger = null;
    _deadline = null;
    final wasShowing = _activeCampaign != null;
    _activeCampaign = null;
    if (playQueued && _queue.isNotEmpty) {
      _play(_queue.removeAt(0));
      return;
    }
    if (wasShowing) {
      log('interactivity content ended');
      notifyListeners();
    }
  }

  /// The normal loop moved to its next campaign: enqueued content waiting
  /// for a gap gets its turn now.
  void onCampaignAdvanced() {
    if (_activeCampaign == null && _queue.isNotEmpty) {
      _play(_queue.removeAt(0));
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _showTimer?.cancel();
    _server?.close(force: true);
    super.dispose();
  }
}
