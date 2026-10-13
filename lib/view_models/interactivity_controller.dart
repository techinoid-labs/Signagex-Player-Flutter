import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:digital_signage/models/compaign_model.dart'
    show Campaign, CampaignZone, MediaItem, Period, Restriction;
import 'package:digital_signage/models/intractivity_model.dart';
import 'package:digital_signage/utils/interactivity_hit_test.dart';
import 'package:digital_signage/utils/time_range_utils.dart';

/// Port of the player's local API. The same on every SignageX player
/// (Windows, macOS, the Chromium player's own server), so one URL shape
/// works everywhere: http://<player-ip>:5757/<anything containing the
/// configured text>.
const int interactivityLocalApiPort = 5757;

/// Runs the interactivities the CMS sends in `create_interactivity`.
///
/// Owns the conditions (key, touch, local API, timeout, specific time, on
/// demand), the gate (pause, schedule, restriction groups) and the actions
/// (play, enqueue, enqueue_and_play, stop). What to show is exposed as
/// [activeCampaign]: trigger content converted to compaign_model's
/// Campaign, so the screen renders it with the same zone renderer as any
/// published campaign -- video, compositions, web apps and playlists all
/// work because that renderer already handles them.
///
/// Kept out of MqttViewModel deliberately: that class already carries the
/// whole MQTT/download/device surface. It hands in the three things this
/// needs from it -- the restriction evaluator, the media download, and a way
/// to repaint -- and nothing else.
class InteractivityController {
  final bool Function(List<Restriction> restrictions) checkRestrictions;

  /// Downloads every media item in [campaigns] with the campaign download
  /// machinery and points the items at the local copies.
  final Future<void> Function(List<Campaign> campaigns) localizeMedia;
  final void Function() onChanged;
  final void Function(String message) log;

  InteractivityController({
    required this.checkRestrictions,
    required this.localizeMedia,
    required this.onChanged,
    required this.log,
  }) {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  List<Interactivity> _items = const [];

  /// Trigger content as campaigns, built once per list so the downloads run
  /// as soon as the list arrives. Keyed by "<interactivity id>#<trigger>".
  final Map<String, List<Campaign>> _prepared = {};

  Timer? _ticker;

  // -- What is on screen --

  Campaign? _activeCampaign;

  /// Interactivity content to show full-screen on top of the normal
  /// playback, or null when there is none.
  Campaign? get activeCampaign => _activeCampaign;

  int _activeSerial = 0;

  /// Changes every time new content goes on screen, even when it is the same
  /// campaign again -- the overlay keys on it so a re-fire restarts the
  /// content rather than leaving it mid-way.
  int get activeSerial => _activeSerial;

  _Playback? _playback;
  Timer? _playbackTimer;
  final List<_Playback> _queue = [];

  // -- Conditions that need state --

  DateTime _lastInput = DateTime.now();

  /// Interactivity ids whose timeout is armed: there has been input since
  /// they last fired.
  final Set<String> _timeoutArmed = {};

  /// "<id>|<time>" for every specific time already fired.
  final Set<String> _specificTimesFired = {};

  HttpServer? _server;
  bool _serverStarting = false;
  Timer? _serverRetry;

  /// Replaces the whole list -- `create_interactivity` always carries the
  /// player's full current set, on create, update and delete alike.
  void setList(InteractivityModel model) {
    _items = model.interactivity;
    log('list received: ${_items.length} interactivit(y/ies) '
        '[${_items.map((i) => i.name).join(", ")}]');

    // Whatever was playing or waiting belonged to the previous list.
    _stopPlayback(notify: false);
    _timeoutArmed.clear();
    _specificTimesFired.clear();

    _prepared.clear();
    final allCampaigns = <Campaign>[];
    for (final it in _items) {
      for (var t = 0; t < it.triggers.length; t++) {
        final trigger = it.triggers[t];
        final campaigns = <Campaign>[];
        for (var c = 0; c < trigger.content.length; c++) {
          final campaign =
              _campaignFromContent(it, t, trigger, trigger.content[c], c);
          if (campaign != null) campaigns.add(campaign);
        }
        _prepared['${it.id}#$t'] = campaigns;
        allCampaigns.addAll(campaigns);
      }
    }
    if (allCampaigns.isNotEmpty) unawaited(_localize(allCampaigns));

    if (_items.any((it) => it.localApi.isNotEmpty)) {
      unawaited(_ensureServer());
    }
    onChanged();
  }

  Future<void> _localize(List<Campaign> campaigns) async {
    try {
      await localizeMedia(campaigns);
      log('trigger content media ready (${campaigns.length} item(s))');
    } catch (error) {
      log('trigger content media download failed: $error');
    }
  }

  // -- Conditions --

  /// A key went down. [labels] are the different spellings the platform
  /// gives one key (character, key label, debug name); any of them matching
  /// a configured key counts.
  void onKey(List<String> labels) {
    _registerInput();
    final normalized = labels
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((l) => l.toLowerCase().startsWith('key ') ? l.substring(4) : l)
        .toSet();
    if (normalized.isEmpty) return;
    for (final it in _items) {
      if (it.keyPress.isEmpty) continue;
      if (normalized.any((label) => keyMatches(it.keyPress, label))) {
        _fire(it, 'key_press ${normalized.join("/")}');
      }
    }
  }

  /// A tap at ([x], [y]) on a screen of [screenWidth] x [screenHeight].
  ///
  /// Regions are drawn on the interactivity's resolution, fitted to the
  /// screen the same way a campaign is (one uniform scale, centred), so the
  /// tap is mapped into that space before the hit test.
  void onTap(double x, double y, double screenWidth, double screenHeight) {
    _registerInput();
    if (screenWidth <= 0 || screenHeight <= 0) return;
    for (final it in _items) {
      if (!it.touchRegion || it.control.isEmpty) continue;
      final scale = math.min(
        screenWidth / it.resolutionWidth,
        screenHeight / it.resolutionHeight,
      );
      final stageWidth = it.resolutionWidth * scale;
      final stageHeight = it.resolutionHeight * scale;
      final rx = (x - (screenWidth - stageWidth) / 2) / stageWidth;
      final ry = (y - (screenHeight - stageHeight) / 2) / stageHeight;
      final hit = it.control.any((c) => _controlHit(c, it, rx, ry));
      if (hit) {
        _fire(it,
            'touch_region at ${rx.toStringAsFixed(3)},${ry.toStringAsFixed(3)}');
      }
    }
  }

  bool _controlHit(
      InteractivityControl c, Interactivity it, double rx, double ry) {
    if (c.anyRegion) return true;
    if (c.relX != null &&
        c.relY != null &&
        c.relWidth != null &&
        c.relHeight != null) {
      return isPointInRegion(
        x: rx,
        y: ry,
        regionX: c.relX!,
        regionY: c.relY!,
        regionWidth: c.relWidth!,
        regionHeight: c.relHeight!,
      );
    }
    if (c.x != null && c.y != null && c.width != null && c.height != null) {
      return isPointInRegion(
        x: rx * it.resolutionWidth,
        y: ry * it.resolutionHeight,
        regionX: c.x!,
        regionY: c.y!,
        regionWidth: c.width!,
        regionHeight: c.height!,
      );
    }
    return false;
  }

  /// `run_interactivity` -- the CMS's "On demand" button.
  void runById(String id) {
    final matches = _items.where((it) => it.id == id).toList();
    if (matches.isEmpty) {
      log('run_interactivity: no interactivity with id $id on this player');
      return;
    }
    _fire(matches.first, 'on_demand');
  }

  /// The normal loop moved to its next campaign: the moment an enqueued
  /// trigger waits for when nothing interactive is on screen.
  void onCampaignAdvance() {
    if (_playback == null && _queue.isNotEmpty) {
      log('campaign changed -> playing enqueued "${_queue.first.label}"');
      _start(_queue.removeAt(0));
    }
  }

  void _registerInput() {
    _lastInput = DateTime.now();
    for (final it in _items) {
      if (it.interactivityTimeout != null) _timeoutArmed.add(it.id);
    }
  }

  void _tick() {
    final now = DateTime.now();
    for (final it in _items) {
      final timeout = it.interactivityTimeout;
      if (timeout != null &&
          _timeoutArmed.contains(it.id) &&
          now.difference(_lastInput).inSeconds >= timeout) {
        // Once per idle stretch: the next input re-arms it.
        _timeoutArmed.remove(it.id);
        _fire(it, 'interactivity_timeout ${timeout}s');
      }
      for (final at in it.specificTime) {
        final key = '${it.id}|${at.toIso8601String()}';
        if (_specificTimesFired.contains(key)) continue;
        final overdue = now.difference(at);
        if (overdue.isNegative) continue;
        _specificTimesFired.add(key);
        // A time already well past when the list arrived (or while the
        // player was off) is history, not something to play now.
        if (overdue.inSeconds < 60) {
          _fire(it, 'specific_time ${at.toIso8601String()}');
        }
      }
    }
  }

  // -- Local API --

  Future<void> _ensureServer() async {
    if (_server != null || _serverStarting) return;
    _serverStarting = true;
    try {
      final server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        interactivityLocalApiPort,
        shared: true,
      );
      _server = server;
      log('local API listening on port $interactivityLocalApiPort');
      server.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error) => log('local API server error: $error'),
        cancelOnError: false,
      );
    } catch (error) {
      log('local API could not listen on port $interactivityLocalApiPort: '
          '$error -- retrying in 30s');
      _serverRetry?.cancel();
      _serverRetry =
          Timer(const Duration(seconds: 30), () => unawaited(_ensureServer()));
    } finally {
      _serverStarting = false;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      response.headers
        ..set('Access-Control-Allow-Origin', '*')
        ..set('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        ..set('Access-Control-Allow-Headers', '*');
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        await response.close();
        return;
      }
      await request.drain<void>();

      // Path and query, both as sent and decoded, so a configured value
      // with spaces matches whether the caller encoded it or not.
      final raw = request.uri.toString();
      String decoded;
      try {
        decoded = Uri.decodeFull(raw);
      } catch (_) {
        decoded = raw;
      }
      final fired = <String>[];
      for (final it in _items) {
        final matches = it.localApi
            .any((api) => raw.contains(api) || decoded.contains(api));
        if (matches && _fire(it, 'local_api ${request.method} $raw')) {
          fired.add(it.name);
        }
      }
      log('local API ${request.method} $raw -> '
          '${fired.isEmpty ? "no match" : "fired $fired"}');

      response.statusCode =
          fired.isEmpty ? HttpStatus.notFound : HttpStatus.ok;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(
          fired.isEmpty ? {'ok': false} : {'ok': true, 'fired': fired}));
      await response.close();
    } catch (error) {
      log('local API request failed: $error');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  // -- Gate --

  /// Fires [it] if its gate passes. Returns whether it fired.
  bool _fire(Interactivity it, String condition) {
    final rejection = _gateRejection(it);
    if (rejection != null) {
      log('"${it.name}" via $condition not fired: $rejection');
      return false;
    }
    log('"${it.name}" fired via $condition '
        '(${it.triggers.length} trigger(s))');
    for (var i = 0; i < it.triggers.length; i++) {
      _runTrigger(it, i);
    }
    return true;
  }

  String? _gateRejection(Interactivity it) {
    if (it.pause) return 'paused';
    final schedule = it.schedule;
    if (schedule != null && schedule.alwaysPlay != true) {
      final reason = _periodRejection(schedule.period);
      if (reason != null) return reason;
    }
    for (var i = 0; i < it.restrictionGroups.length; i++) {
      if (!_groupPasses(it.restrictionGroups[i])) {
        return 'restriction group ${i + 1} failed';
      }
    }
    return null;
  }

  String? _periodRejection(Period? period) {
    if (period == null) return null;
    final now = DateTime.now();

    final days = period.days;
    if (days != null) {
      final byWeekday = <int, bool?>{
        DateTime.monday: days.monday,
        DateTime.tuesday: days.tuesday,
        DateTime.wednesday: days.wednesday,
        DateTime.thursday: days.thursday,
        DateTime.friday: days.friday,
        DateTime.saturday: days.saturday,
        DateTime.sunday: days.sunday,
      };
      // A days object that names no day at all is no limit.
      final anyConfigured = byWeekday.values.any((v) => v != null);
      if (anyConfigured && byWeekday[now.weekday] != true) {
        return 'not scheduled on this weekday';
      }
    }

    final from = period.time?.from?.trim() ?? '';
    final to = period.time?.to?.trim() ?? '';
    if (from.isNotEmpty && to.isNotEmpty) {
      try {
        if (!isNowInTimeRange(from, to, now: now)) {
          return 'outside scheduled time $from-$to';
        }
      } catch (error) {
        log('schedule time $from-$to unreadable ($error) -> not limiting');
      }
    }

    final start = DateTime.tryParse(period.date?.start?.trim() ?? '');
    final end = DateTime.tryParse(period.date?.end?.trim() ?? '');
    final today = DateTime(now.year, now.month, now.day);
    if (start != null &&
        today.isBefore(DateTime(start.year, start.month, start.day))) {
      return 'before scheduled start date';
    }
    if (end != null && today.isAfter(DateTime(end.year, end.month, end.day))) {
      return 'after scheduled end date';
    }
    return null;
  }

  bool _groupPasses(InteractivityRestrictionGroup group) {
    final results = <bool>[
      for (final r in group.restrictions) checkRestrictions([r]),
      for (final sub in group.groups) _groupPasses(sub),
    ];
    if (results.isEmpty) return true;
    return group.operator == 'OR'
        ? results.any((pass) => pass)
        : results.every((pass) => pass);
  }

  // -- Actions --

  void _runTrigger(Interactivity it, int index) {
    final trigger = it.triggers[index];
    final label = '${it.name} / ${trigger.triggerType}';
    if (trigger.triggerType == 'stop') {
      log('stop: clearing interactivity content and queue');
      _stopPlayback();
      return;
    }
    final playback = _playbackFor(it, index, label);
    if (playback == null) return;
    if (trigger.triggerType == 'enqueue') {
      _queue.add(playback);
      log('enqueued "$label" (queue ${_queue.length})');
      return;
    }
    // play, enqueue_and_play, and anything newer the CMS may add: show now.
    _start(playback);
  }

  _Playback? _playbackFor(Interactivity it, int index, String label) {
    final campaigns = _prepared['${it.id}#$index'] ?? const <Campaign>[];
    if (campaigns.isEmpty) {
      log('"$label" has no content to show');
      return null;
    }
    return _Playback(
      label: label,
      campaigns: campaigns,
      duration: Duration(seconds: it.triggers[index].duration),
    );
  }

  void _start(_Playback playback) {
    _playbackTimer?.cancel();
    _playback = playback;
    playback.deadline = DateTime.now().add(playback.duration);
    playback.index = 0;
    log('play "${playback.label}" for ${playback.duration.inSeconds}s '
        '(${playback.campaigns.length} content item(s))');
    _showCurrent();
  }

  /// Shows the playback's current content item. Several items play one
  /// after another, each for its own length; the trigger duration caps the
  /// total.
  void _showCurrent() {
    final playback = _playback;
    if (playback == null) return;
    final remaining = playback.deadline!.difference(DateTime.now());
    if (playback.index >= playback.campaigns.length ||
        remaining <= Duration.zero) {
      _finishPlayback();
      return;
    }
    final campaign = playback.campaigns[playback.index];
    final slot = playback.campaigns.length == 1
        ? remaining
        : _minDuration(Duration(seconds: _naturalSeconds(campaign)), remaining);
    _activeCampaign = campaign;
    _activeSerial++;
    onChanged();
    _playbackTimer = Timer(slot, () {
      playback.index++;
      _showCurrent();
    });
  }

  void _finishPlayback() {
    log('finished "${_playback?.label}"');
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _playback = null;
    _activeCampaign = null;
    if (_queue.isNotEmpty) {
      _start(_queue.removeAt(0));
      return;
    }
    onChanged();
  }

  void _stopPlayback({bool notify = true}) {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _playback = null;
    _queue.clear();
    final hadContent = _activeCampaign != null;
    _activeCampaign = null;
    if (notify && hadContent) onChanged();
  }

  static Duration _minDuration(Duration a, Duration b) => a < b ? a : b;

  /// The longest zone's run through its items, at the items' own durations.
  static int _naturalSeconds(Campaign campaign) {
    var longest = 0;
    for (final zone in campaign.zones ?? const <CampaignZone>[]) {
      var total = 0;
      for (final item in zone.mediaItems ?? const <MediaItem>[]) {
        final int seconds = item.settings?.duration ?? 0;
        total += seconds > 0 ? seconds : 10;
      }
      longest = math.max(longest, total);
    }
    return longest > 0 ? longest : 10;
  }

  // -- Content -> campaign --

  /// One trigger content entry as a Campaign the zone renderer understands.
  ///
  /// The content's zones/mediaItems are already in publish_campaign shape;
  /// what is missing is the campaign envelope, and the resolution -- taken
  /// as the bounding box of the zones (a campaign's own layout, e.g.
  /// 1280x720, or 1920x1080 for a playlist, composition or web app).
  Campaign? _campaignFromContent(
    Interactivity it,
    int triggerIndex,
    InteractivityTrigger trigger,
    Map<String, dynamic> content,
    int contentIndex,
  ) {
    // Deep copy: the renderer's download pass rewrites media URLs in place,
    // and the received JSON should stay as it arrived.
    final zones = jsonDecode(jsonEncode(content['zones'] ?? const []));
    if (zones is! List || zones.isEmpty) {
      log('"${it.name}" content "${content['name']}" has no zones -- skipped');
      return null;
    }

    double extentX = 0;
    double extentY = 0;
    for (final zone in zones) {
      if (zone is! Map) continue;
      final x = _num(zone['x']);
      final y = _num(zone['y']);
      extentX = math.max(extentX, x + _num(zone['width']));
      extentY = math.max(extentY, y + _num(zone['height']));
      final items = zone['mediaItems'];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          if (item['settings'] is! Map) item['settings'] = <String, dynamic>{};
          (item['settings'] as Map)['volume'] = trigger.volume;
        }
      }
    }
    final width = extentX > 0 ? extentX : it.resolutionWidth;
    final height = extentY > 0 ? extentY : it.resolutionHeight;

    try {
      return Campaign.fromJson({
        'playback_type': 'campaign',
        'campaign_id':
            'interactivity_${it.id}_${triggerIndex}_$contentIndex',
        'campaign_name': content['name']?.toString() ?? it.name,
        'resolution': {'width': width.round(), 'height': height.round()},
        'campaign_schedule': {'always_play': true},
        'campaign_settings': {
          'transition': trigger.transition,
          'duration': trigger.duration,
          'loop': false,
        },
        'zones': zones,
        'is_paused': false,
      });
    } catch (error) {
      log('"${it.name}" content "${content['name']}" unreadable: $error');
      return null;
    }
  }

  static double _num(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0;
  }

  void dispose() {
    _ticker?.cancel();
    _playbackTimer?.cancel();
    _serverRetry?.cancel();
    unawaited(_server?.close(force: true));
    _server = null;
  }
}

class _Playback {
  final String label;
  final List<Campaign> campaigns;
  final Duration duration;
  DateTime? deadline;
  int index = 0;

  _Playback({
    required this.label,
    required this.campaigns,
    required this.duration,
  });
}
