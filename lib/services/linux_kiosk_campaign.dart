import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/constants.dart';
import '../utils/debug_log.dart' as debug;
import 'linux_diagnostics.dart';

/// Kiosk campaigns on Linux: interactive touch journeys built in Kiosk Studio.
///
/// The CMS sends this screen's kiosk schedule on the retained topic
/// `{playerCode}/kiosk` (see the backend's docs/KIOSK_CAMPAIGN_CONTRACT.md):
/// every kiosk campaign assigned to it, each with a schedule (always, a date
/// range, daily hours, days of the week) read on the screen's own clock.
/// Whichever campaign is scheduled now takes over the screen from signage and
/// is shown full screen in the CEF browser (`player_url`, the frontend's
/// /kiosk-play page); outside every window the screen plays signage.
///
/// The page reports its state through its document title (`sxk:<state>`).
/// Switching campaigns or versions waits for the customer session to end;
/// a page that stopped answering is reloaded, then set aside for signage.
///
/// Nothing a customer enters ever reaches this side: the page keeps answers
/// in memory; only the schedule and the published documents are cached.

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
        !['https', 'http'].contains(page.scheme) ||
        // The page is served by the frontend, never by the API. A backend
        // without KIOSK_PLAYER_BASE_URL falls back to its own address, which
        // answers 404 for /kiosk-play: use the known frontend instead.
        page.host == runtime.host) {
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

  /// "Visitor check-in v3" for logs.
  String get label => '${name.isEmpty ? campaignId : name} v$versionNo';
}

/// The /kiosk-play page for a runtime document URL.
String kioskPageUrl(String runtimeUrl, String frontendBase) {
  final base = frontendBase.endsWith('/')
      ? frontendBase.substring(0, frontendBase.length - 1)
      : frontendBase;
  return '$base/kiosk-play?runtime=${Uri.encodeComponent(runtimeUrl)}';
}

// ─── Schedules ─────────────────────────────────────────────────────────────

final RegExp _dateFormat = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// Minutes since midnight for "HH:MM" (or "H:MM"); null when it isn't a time.
int? _minutesOf(Object? value) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${value ?? ''}'.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return h * 60 + min;
}

String _hhmm(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const _monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// Day of week with 0 = Sunday, as the CMS sends it.
int _weekday0(DateTime wall) => wall.weekday % 7;

String _dateKey(DateTime wall) =>
    '${wall.year.toString().padLeft(4, '0')}-${wall.month.toString().padLeft(2, '0')}-${wall.day.toString().padLeft(2, '0')}';

/// When one kiosk campaign plays on this screen. Read on the screen's local
/// wall clock. Empty fields mean "no limit": no dates = every date, no days =
/// every day, no times = all day. An end time before the start time runs past
/// midnight, and that window belongs to the day it starts on. End times are
/// exclusive; dates are inclusive.
class KioskSchedule {
  final String? startDate;
  final String? endDate;
  final int? startMinute;
  final int? endMinute;

  /// 0 = Sunday … 6 = Saturday. Empty = every day.
  final List<int> days;

  const KioskSchedule({
    this.startDate,
    this.endDate,
    this.startMinute,
    this.endMinute,
    this.days = const [],
  });

  static const always = KioskSchedule();

  static KioskSchedule fromJson(Object? json) {
    if (json is! Map) return always;
    String? date(String key) {
      final v = '${json[key] ?? ''}'.trim();
      return _dateFormat.hasMatch(v) ? v : null;
    }

    final rawDays = json['days'];
    final days = <int>{};
    if (rawDays is List) {
      for (final d in rawDays) {
        final n = d is num ? d.toInt() : int.tryParse('$d');
        if (n != null && n >= 0 && n <= 6) days.add(n);
      }
    }
    var start = _minutesOf(json['startTime']);
    var end = _minutesOf(json['endTime']);
    // Only one end of the window, or an empty one: treat as all day.
    if (start == null || end == null || start == end) {
      start = null;
      end = null;
    }
    return KioskSchedule(
      startDate: date('startDate'),
      endDate: date('endDate'),
      startMinute: start,
      endMinute: end,
      // All seven days is the same as "every day".
      days: days.length == 7 ? const [] : (days.toList()..sort()),
    );
  }

  Map<String, dynamic> toJson() => {
        'startDate': startDate,
        'endDate': endDate,
        'startTime': startMinute == null ? null : _hhmm(startMinute!),
        'endTime': endMinute == null ? null : _hhmm(endMinute!),
        'days': days,
      };

  bool get hasTimes => startMinute != null && endMinute != null;
  bool get overnight => hasTimes && endMinute! < startMinute!;

  bool _dayAllowed(DateTime day) {
    final key = _dateKey(day);
    if (startDate != null && key.compareTo(startDate!) < 0) return false;
    if (endDate != null && key.compareTo(endDate!) > 0) return false;
    return days.isEmpty || days.contains(_weekday0(day));
  }

  /// Whether this schedule is on at [wall], the screen's local wall clock
  /// (only its date and time fields are read).
  bool activeAt(DateTime wall) {
    final today = DateTime.utc(wall.year, wall.month, wall.day);
    if (!hasTimes) return _dayAllowed(today);
    final minute = wall.hour * 60 + wall.minute;
    if (!overnight) {
      return _dayAllowed(today) && minute >= startMinute! && minute < endMinute!;
    }
    // Overnight, e.g. Fri 22:00–02:00: the evening part belongs to today,
    // the early-morning part to the window that started yesterday.
    if (minute >= startMinute!) return _dayAllowed(today);
    if (minute < endMinute!) {
      return _dayAllowed(today.subtract(const Duration(days: 1)));
    }
    return false;
  }

  /// "Mon–Fri 06:00–11:00", "every day", "always", with dates when set.
  String describe() {
    if (startDate == null && endDate == null && days.isEmpty && !hasTimes) {
      return 'always';
    }
    final parts = <String>[];
    parts.add(_describeDays());
    parts.add(hasTimes ? '${_hhmm(startMinute!)}–${_hhmm(endMinute!)}' : 'all day');
    var text = parts.join(' ');
    if (startDate != null || endDate != null) {
      text += ' (${startDate == null ? '…' : _prettyDate(startDate!)}–${endDate == null ? '…' : _prettyDate(endDate!)})';
    }
    return text;
  }

  String _describeDays() {
    if (days.isEmpty) return 'every day';
    if (_listEquals(days, const [1, 2, 3, 4, 5])) return 'Mon–Fri';
    if (_listEquals(days, const [0, 6])) return 'Sat–Sun';
    return days.map((d) => _dayNames[d]).join(', ');
  }

  static String _prettyDate(String key) {
    final p = key.split('-');
    final month = int.tryParse(p[1]) ?? 1;
    final index = month < 1 ? 0 : (month > 12 ? 11 : month - 1);
    return '${int.tryParse(p[2]) ?? p[2]} ${_monthNames[index]}';
  }

  /// Minutes of the day where this schedule can switch on or off.
  Iterable<int> get _edges sync* {
    yield 0;
    if (hasTimes) {
      yield startMinute!;
      yield endMinute!;
    }
  }
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One kiosk campaign assigned to this screen, with its schedule.
class KioskScheduleEntry {
  final KioskPayload payload;
  final KioskSchedule schedule;

  /// 'player' (assigned to this screen) or 'group' (through a screen group).
  final String source;

  const KioskScheduleEntry(this.payload, this.schedule, {this.source = 'player'});

  static KioskScheduleEntry? fromJson(Object? json, {String? frontendBase}) {
    if (json is! Map) return null;
    final payload = KioskPayload.fromJson(json, frontendBase: frontendBase);
    if (payload == null) return null;
    final source = '${json['source'] ?? 'player'}' == 'group' ? 'group' : 'player';
    return KioskScheduleEntry(payload, KioskSchedule.fromJson(json['schedule']), source: source);
  }

  Map<String, dynamic> toJson() => {
        ...payload.toJson(),
        'schedule': schedule.toJson(),
        'source': source,
      };
}

/// Everything scheduled on this screen, as last received.
class KioskScheduleSet {
  /// IANA zone of the screen's clock (null: the device's own zone).
  final String? timeZone;
  final List<KioskScheduleEntry> entries;
  const KioskScheduleSet(this.timeZone, this.entries);

  static const empty = KioskScheduleSet(null, []);

  Set<String> get versionIds => {for (final e in entries) e.payload.versionId};

  Map<String, dynamic> toJson() => {
        'time_zone': timeZone,
        'campaigns': [for (final e in entries) e.toJson()],
      };

  static KioskScheduleSet fromJson(Object? json, {String? frontendBase}) {
    if (json is! Map) return empty;
    final zone = '${json['time_zone'] ?? ''}'.trim();
    final list = json['campaigns'];
    final entries = <KioskScheduleEntry>[];
    final seen = <String>{};
    if (list is List) {
      for (final item in list) {
        final entry = KioskScheduleEntry.fromJson(item, frontendBase: frontendBase);
        // One entry per campaign: a repeated campaign keeps its first copy.
        if (entry != null && seen.add(entry.payload.campaignId)) entries.add(entry);
      }
    }
    return KioskScheduleSet(zone.isEmpty ? null : zone, entries);
  }
}

/// A message on `{playerCode}/kiosk`.
///
/// The current message is `kiosk_schedule` with every campaign assigned to the
/// screen. The older single-campaign messages are still understood:
/// `publish_kiosk_campaign` is a schedule of one campaign that always plays,
/// and `clear_kiosk_campaign` is an empty schedule.
class KioskMessage {
  final KioskScheduleSet schedule;

  /// The legacy single publish, when that is what arrived.
  final KioskPayload? publish;

  const KioskMessage._(this.schedule, this.publish);

  /// No kiosk on this screen any more.
  bool get clear => schedule.entries.isEmpty;

  /// Null for anything that isn't a kiosk message (or isn't JSON).
  static KioskMessage? parse(String raw, {String? frontendBase}) {
    Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (json is! Map) return null;
    switch (json['action']) {
      case 'kiosk_schedule':
        final data = json['data'];
        if (data != null && data is! Map) return null;
        return KioskMessage._(
            KioskScheduleSet.fromJson(data, frontendBase: frontendBase), null);
      case 'clear_kiosk_campaign':
        return const KioskMessage._(KioskScheduleSet.empty, null);
      case 'publish_kiosk_campaign':
        final payload =
            KioskPayload.fromJson(json['data'], frontendBase: frontendBase);
        if (payload == null) return null;
        return KioskMessage._(
            KioskScheduleSet(null, [KioskScheduleEntry(payload, KioskSchedule.always)]),
            payload);
      default:
        return null;
    }
  }
}

/// The screen's wall clock in an IANA zone. Dart has no time-zone database,
/// so the zone's current UTC offset is read from the system (`date +%z` with
/// TZ set, which uses /usr/share/zoneinfo and so follows daylight saving) and
/// cached for 10 minutes. An unknown zone, or a system without zoneinfo,
/// falls back to the device's own local time.
class KioskClock {
  static final Map<String, (Duration, DateTime)> _offsets = {};

  /// Replaceable in tests: the offset of [zone] at [utc], or null if unknown.
  static Duration? Function(String zone, DateTime utc) offsetOf = _systemOffset;

  /// The wall clock at [utcNow] (a UTC DateTime whose fields are local time).
  static DateTime wall(DateTime utcNow, String? zone) {
    final utc = utcNow.toUtc();
    if (zone != null && zone.isNotEmpty) {
      final offset = offsetOf(zone, utc);
      if (offset != null) {
        final t = utc.add(offset);
        return DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
      }
    }
    final local = utc.toLocal();
    return DateTime.utc(local.year, local.month, local.day, local.hour, local.minute, local.second);
  }

  static Duration? _systemOffset(String zone, DateTime utc) {
    if (!Platform.isLinux) return null;
    // `date` quietly uses UTC for an unknown zone, so check it exists first.
    if (zone.contains('..') || !File('/usr/share/zoneinfo/$zone').existsSync()) {
      return null;
    }
    final cached = _offsets[zone];
    if (cached != null && utc.difference(cached.$2).abs() < const Duration(minutes: 10)) {
      return cached.$1;
    }
    try {
      final result = Process.runSync('date', ['+%z'], environment: {'TZ': zone});
      final m = RegExp(r'^([+-])(\d{2})(\d{2})').firstMatch('${result.stdout}'.trim());
      if (result.exitCode != 0 || m == null) return null;
      final minutes = int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!);
      final offset = Duration(minutes: m.group(1) == '-' ? -minutes : minutes);
      _offsets[zone] = (offset, utc);
      return offset;
    } catch (_) {
      return null;
    }
  }
}

/// Picks the campaign that should be on screen.
class KioskScheduleResolver {
  /// The campaign scheduled at [utcNow] on the screen's clock in [timeZone].
  static KioskScheduleEntry? activeAt(
      DateTime utcNow, String? timeZone, List<KioskScheduleEntry> entries) {
    return activeAtWall(KioskClock.wall(utcNow, timeZone), entries);
  }

  /// The same, for a wall-clock time already in the screen's zone.
  /// The CMS prevents overlaps; if two are on anyway, one assigned to this
  /// screen beats one from a group, then the most recently published wins.
  static KioskScheduleEntry? activeAtWall(DateTime wall, List<KioskScheduleEntry> entries) {
    KioskScheduleEntry? best;
    for (final entry in entries) {
      if (!entry.schedule.activeAt(wall)) continue;
      if (best == null || _beats(entry, best)) best = entry;
    }
    return best;
  }

  static bool _beats(KioskScheduleEntry a, KioskScheduleEntry b) {
    if (a.source != b.source) return a.source == 'player';
    return a.payload.publishedAt.compareTo(b.payload.publishedAt) > 0;
  }

  /// The next wall-clock minute (within 8 days) where the campaign on screen
  /// changes, or null when nothing will change in that time.
  static DateTime? nextChangeWall(DateTime wall, List<KioskScheduleEntry> entries) {
    final now = DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute);
    final current = activeAtWall(now, entries)?.payload.campaignId;
    final candidates = <DateTime>{};
    final midnight = DateTime.utc(wall.year, wall.month, wall.day);
    for (var d = 0; d <= 8; d++) {
      final day = midnight.add(Duration(days: d));
      for (final entry in entries) {
        for (final edge in entry.schedule._edges) {
          final at = day.add(Duration(minutes: edge));
          if (at.isAfter(now)) candidates.add(at);
        }
      }
      if (day.isAfter(now)) candidates.add(day);
    }
    final ordered = candidates.toList()..sort();
    for (final at in ordered) {
      if (activeAtWall(at, entries)?.payload.campaignId != current) return at;
    }
    return null;
  }

  /// "11:00", or "Sat 06:00" when it isn't today.
  static String describeChange(DateTime wall, DateTime change) {
    final time = _hhmm(change.hour * 60 + change.minute);
    final sameDay = change.year == wall.year && change.month == wall.month && change.day == wall.day;
    return sameDay ? time : '${_dayNames[_weekday0(change)]} $time';
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

/// When a different campaign/version (or signage) may take over the screen.
///
/// Never in the middle of a customer session. A session that has been
/// running for [maxWait] is asked to end (the page's own idle reset should
/// have done so; a stuck page must not block changes forever), and the swap
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

// ─── Cache ─────────────────────────────────────────────────────────────────

/// On-disk copy of the schedule and of each scheduled version's document, so
/// the screen keeps running offline and after a restart. Writes go to a
/// temporary file renamed into place, so a power cut mid-write never leaves a
/// half file. Documents of campaigns no longer scheduled are removed.
class KioskCache {
  final Directory directory;
  KioskCache(this.directory);

  static KioskCache standard() => KioskCache(Directory(
      '${Platform.environment['HOME'] ?? '.'}/.local/share/signagex-player/kiosk'));

  File get _schedule => File('${directory.path}/schedule.json');
  Directory get _docs => Directory('${directory.path}/docs');

  /// Files written by players before schedules existed.
  File get _legacyCurrent => File('${directory.path}/current.json');
  File get _legacyPrevious => File('${directory.path}/previous.json');

  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9_-]{1,80}$');

  File _doc(String versionId) => File('${_docs.path}/$versionId.json');

  Future<void> _write(File target, String contents) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.part');
    await temporary.writeAsString(contents, flush: true);
    await temporary.rename(target.path);
  }

  Future<void> saveSchedule(KioskScheduleSet schedule) =>
      _write(_schedule, jsonEncode(schedule.toJson()));

  /// The saved schedule. A cache from before schedules (current.json only)
  /// reads as that one campaign, always on.
  Future<KioskScheduleSet?> readSchedule() async {
    try {
      if (await _schedule.exists()) {
        return KioskScheduleSet.fromJson(jsonDecode(await _schedule.readAsString()));
      }
      final legacy = await _readEntry(_legacyCurrent);
      if (legacy == null) return null;
      return KioskScheduleSet(null, [KioskScheduleEntry(legacy.payload, KioskSchedule.always)]);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDocument(KioskPayload payload, String document) async {
    if (!_safeId.hasMatch(payload.versionId)) {
      throw ArgumentError('unsafe version id');
    }
    await _write(_doc(payload.versionId),
        jsonEncode({'payload': payload.toJson(), 'document': document}));
  }

  Future<bool> hasDocument(String versionId) async {
    if (_safeId.hasMatch(versionId) && await _doc(versionId).exists()) return true;
    final legacy = await _readEntry(_legacyCurrent);
    return legacy?.payload.versionId == versionId;
  }

  Future<KioskCacheEntry?> readDocument(String versionId) async {
    if (_safeId.hasMatch(versionId)) {
      final entry = await _readEntry(_doc(versionId));
      if (entry != null) return entry;
    }
    final legacy = await _readEntry(_legacyCurrent);
    return legacy?.payload.versionId == versionId ? legacy : null;
  }

  Future<KioskCacheEntry?> _readEntry(File file) async {
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

  /// Keeps only the documents in [versionIds]; removes leftover temp files
  /// and the pre-schedule files once the schedule has been saved.
  Future<void> prune(Set<String> versionIds) async {
    try {
      if (await _docs.exists()) {
        await for (final file in _docs.list()) {
          final name = file.uri.pathSegments.last;
          final id = name.endsWith('.json') ? name.substring(0, name.length - 5) : null;
          if (name.endsWith('.part') || id == null || !versionIds.contains(id)) {
            await file.delete();
          }
        }
      }
      if (await _schedule.exists()) {
        for (final file in [_legacyCurrent, _legacyPrevious]) {
          if (await file.exists()) await file.delete();
        }
      }
    } catch (_) {}
  }

  /// Saves one campaign as an always-on schedule (as a legacy publish does).
  Future<void> save(KioskPayload payload, String document) async {
    await saveDocument(payload, document);
    await saveSchedule(
        KioskScheduleSet(null, [KioskScheduleEntry(payload, KioskSchedule.always)]));
  }

  /// Nothing scheduled: nothing runs on the next start.
  Future<void> clear() async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {}
  }
}

class KioskCacheEntry {
  final KioskPayload payload;
  final String document;
  const KioskCacheEntry(this.payload, this.document);
}

// ─── Service ───────────────────────────────────────────────────────────────

/// Runs kiosk campaigns on a Linux player. See the file comment.
class KioskCampaignService extends ChangeNotifier {
  KioskCampaignService({
    KioskCache? cache,
    HttpClient Function()? httpClient,
    DateTime Function()? clock,
  })  : _cache = cache ?? KioskCache.standard(),
        _httpClient = httpClient ?? HttpClient.new,
        _clock = clock ?? DateTime.now;

  static final KioskCampaignService instance = KioskCampaignService();

  final KioskCache _cache;
  final HttpClient Function() _httpClient;
  final DateTime Function() _clock;

  String _playerCode = '';

  /// Everything scheduled on this screen.
  KioskScheduleSet _schedule = KioskScheduleSet.empty;
  KioskScheduleSet get schedule => _schedule;

  /// Versions downloaded, checked and on disk.
  final Set<String> _ready = {};

  /// What is on screen (null: scheduled signage).
  KioskPayload? _active;
  KioskPayload? get active => _active;

  /// What should be on screen, waiting for the session to end. Either a
  /// campaign/version, or nothing ([_pendingClear]) when no window is open.
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
  Timer? _reloadTimer;
  bool _started = false;
  bool _disposed = false;
  String _lastHandledRaw = '';

  /// Set while downloads are running; a newer schedule waits for it.
  Future<void>? _downloading;

  /// When a failed download is tried again.
  DateTime? _retryAt;

  /// Last summary logged, so the log isn't repeated every tick.
  String _lastSummary = '';

  /// True while the kiosk should cover scheduled signage.
  bool get showing =>
      _active != null &&
      (_fallbackUntil == null || _clock().isAfter(_fallbackUntil!));

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

  /// On app start: run the cached schedule straight away, even before MQTT
  /// reconnects. The page itself still needs the network to load.
  Future<void> restore() async {
    if (_active != null) return;
    final saved = await _cache.readSchedule();
    if (saved == null || saved.entries.isEmpty) return;
    _schedule = saved;
    for (final id in saved.versionIds) {
      if (await _cache.hasDocument(id)) _ready.add(id);
    }
    _log('resuming cached schedule: ${saved.entries.length} campaign(s)');
    _startTimer();
    _evaluate();
    // Versions that were missing (a crash mid-download) are fetched again.
    if (_ready.length < saved.versionIds.length) _retryAt = _clock();
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
    _schedule = message.schedule;
    _lastSummary = '';
    _log(message.clear
        ? 'schedule cleared: no kiosk campaigns on this screen'
        : 'schedule received: ${message.schedule.entries.length} campaign(s)');
    try {
      await _cache.saveSchedule(_schedule);
    } catch (error) {
      _log('could not save the schedule: $error');
    }
    // Fetch what isn't on disk yet, then decide what shows.
    await _downloadMissing();
    _evaluate();
  }

  /// Downloads every scheduled version that isn't on disk yet.
  Future<void> _downloadMissing() async {
    final running = _downloading;
    if (running != null) {
      await running;
    }
    final completer = Completer<void>();
    _downloading = completer.future;
    try {
      var failed = false;
      for (final entry in List.of(_schedule.entries)) {
        final id = entry.payload.versionId;
        if (_ready.contains(id)) continue;
        if (await _cache.hasDocument(id)) {
          _ready.add(id);
          continue;
        }
        final body = await _download(entry.payload);
        if (body == null) {
          failed = true;
          continue;
        }
        try {
          await _cache.saveDocument(entry.payload, body);
          _ready.add(id);
          _log('${entry.payload.label} downloaded (${entry.schedule.describe()})');
        } catch (error) {
          failed = true;
          _log('could not save ${entry.payload.label}: $error');
        }
      }
      _retryAt = failed ? _clock().add(const Duration(minutes: 1)) : null;
      // Keep scheduled versions and the one on screen; drop the rest.
      final keep = {..._schedule.versionIds, if (_active != null) _active!.versionId};
      if (_schedule.entries.isEmpty && _active == null) {
        await _cache.clear();
      } else {
        await _cache.prune(keep);
      }
      _ready.removeWhere((id) => !keep.contains(id));
    } finally {
      completer.complete();
      if (identical(_downloading, completer.future)) _downloading = null;
    }
  }

  Future<String?> _download(KioskPayload payload) async {
    const delays = [Duration(seconds: 2), Duration(seconds: 5), Duration(seconds: 10)];
    for (var attempt = 0; attempt <= delays.length; attempt++) {
      final client = _httpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.getUrl(Uri.parse(payload.url));
        final response = await request.close().timeout(const Duration(seconds: 30));
        if (response.statusCode == 404) {
          await response.drain<void>();
          _log('${payload.label} is not for this player (404)');
          return null;
        }
        if (response.statusCode != 200) {
          await response.drain<void>();
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
          _log('${payload.label} rejected: $problem');
          return null;
        }
        return body;
      } catch (error) {
        _log('download of ${payload.label} failed (attempt ${attempt + 1}): $error');
        if (attempt < delays.length) await Future.delayed(delays[attempt]);
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// Works out what should be on screen now and sets it as the target.
  void _evaluate() {
    final nowUtc = _clock().toUtc();
    final wall = KioskClock.wall(nowUtc, _schedule.timeZone);

    // Only downloaded versions can show. A campaign whose new version is
    // still downloading keeps showing the version already on screen.
    final eligible = <KioskScheduleEntry>[];
    for (final entry in _schedule.entries) {
      if (_ready.contains(entry.payload.versionId)) {
        eligible.add(entry);
      } else if (_active != null && entry.payload.campaignId == _active!.campaignId) {
        eligible.add(KioskScheduleEntry(_active!, entry.schedule, source: entry.source));
      }
    }
    // The campaign due now is still downloading: decide once it is ready,
    // rather than dropping to signage for the length of the download.
    if (_downloading != null && _active != null) {
      final wanted = KioskScheduleResolver.activeAtWall(wall, _schedule.entries);
      if (wanted != null &&
          !_ready.contains(wanted.payload.versionId) &&
          wanted.payload.campaignId != _active!.campaignId) {
        return;
      }
    }
    final desired = KioskScheduleResolver.activeAtWall(wall, eligible);
    _logSummary(wall, desired, eligible);
    final target = desired?.payload;

    if (target?.versionId == _active?.versionId) {
      _pending = null;
      _pendingClear = false;
      return;
    }
    if (_active == null) {
      // Nothing on screen, so nobody is in a session: show it now.
      if (target != null) {
        _log('starting ${target.label} at ${_pageWhere(target.playerUrl)}');
        _show(target);
      }
      return;
    }
    if (target == null) {
      if (!_pendingClear) {
        _pendingClear = true;
        _pending = null;
        _waitingSince = _clock();
        _endRequestedAt = null;
        _log('${_active!.label} is not scheduled now; signage once the session ends');
      }
    } else if (_pending?.versionId != target.versionId) {
      _pending = target;
      _pendingClear = false;
      _waitingSince = _clock();
      _endRequestedAt = null;
      _log('${target.label} is due; switches once the session ends');
    }
  }

  void _logSummary(DateTime wall, KioskScheduleEntry? desired, List<KioskScheduleEntry> entries) {
    final next = KioskScheduleResolver.nextChangeWall(wall, entries);
    final nextText = next == null ? '' : '; next change ${KioskScheduleResolver.describeChange(wall, next)}';
    final summary = desired == null
        ? 'schedule: ${_schedule.entries.length} campaign(s); nothing scheduled now; signage$nextText'
        : 'schedule: ${_schedule.entries.length} campaign(s); now showing ${desired.payload.label} (${desired.schedule.describe()})$nextText';
    if (summary == _lastSummary) return;
    _lastSummary = summary;
    _log(summary);
  }

  void _show(KioskPayload payload) {
    _active = payload;
    _pending = null;
    _pendingClear = false;
    _state = KioskPageState.none;
    _shownAt = _clock();
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

  /// Host and path of the kiosk page, for logs (the query holds the player code).
  static String _pageWhere(String url) {
    final u = Uri.tryParse(url);
    return u == null ? 'an invalid address' : '${u.scheme}://${u.host}${u.path}';
  }

  /// From the page: the main frame failed to load (offline, DNS, 5xx...).
  void onPageLoadFailed([String? detail]) {
    _recover(detail == null || detail.isEmpty
        ? 'page failed to load'
        : 'page failed to load ($detail)');
  }

  void _recover(String reason) {
    _failures++;
    unawaited(_postStatus('error'));
    if (_failures >= 3) {
      _log('$reason; back to scheduled signage, retrying in 2 minutes');
      _fallbackUntil = _clock().add(const Duration(minutes: 2));
      _failures = 0;
      notifyListeners();
      return;
    }
    _log('$reason; reloading (${_failures}x)');
    final delay = Duration(seconds: 5 * _failures);
    _reloadTimer?.cancel();
    _reloadTimer = Timer(delay, () {
      if (!_disposed) reloadRequests.value++;
    });
  }

  void _tick() {
    if (_disposed) return;
    final now = _clock();
    final retry = _retryAt;
    if (retry != null && now.isAfter(retry)) {
      _retryAt = null;
      unawaited(_downloadMissing().then((_) {
        if (!_disposed) _evaluate();
      }));
    }
    // Window opens or closes, a clock or time-zone change: re-check.
    _evaluate();

    // Back from a fallback with nothing else to do: try the page again.
    if (_fallbackUntil != null && now.isAfter(_fallbackUntil!) && _pending == null && !_pendingClear) {
      _fallbackUntil = null;
      _state = KioskPageState.none;
      _shownAt = now;
      notifyListeners();
      return;
    }
    // Fallen back to signage because the page kept failing: nobody can be in
    // a session, so a change applies now instead of waiting behind it.
    if (!showing && _active != null && (_pending != null || _pendingClear)) {
      _fallbackUntil = null;
      _state = KioskPageState.none;
      _shownAt = now; // so the 60 s "no state" check below doesn't fire first
    } else if (!showing) {
      return;
    }

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
        if (_endRequestedAt == null) {
          _log('session running ${KioskSwapPolicy.maxWait.inMinutes} min; asking the page to end it');
          _endRequestedAt = now;
          endSessionRequests.value++;
        }
        return;
      case KioskSwapDecision.apply:
        break;
    }
    final leaving = _active;
    if (leaving != null) unawaited(_postStatus('idle', payload: leaving));
    if (_pendingClear) {
      _log('${leaving?.label ?? 'kiosk'} ended; back to scheduled signage');
      _pendingClear = false;
      _active = null;
      _pending = null;
      _state = KioskPageState.none;
      _fallbackUntil = null;
      if (_schedule.entries.isEmpty) {
        _ready.clear();
        unawaited(_cache.clear());
      }
      notifyListeners();
      return;
    }
    final next = _pending!;
    _log('switching to ${next.label} at ${_pageWhere(next.playerUrl)}');
    _show(next);
  }

  /// Tells the CMS the page's state even when the page can't say so itself.
  Future<void> _postStatus(String state, {KioskPayload? payload}) async {
    final version = payload ?? _active;
    if (version == null || !_started || _playerCode.isEmpty) return;
    final client = _httpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final uri = Uri.parse(
          '${baseurl}kiosk-runtime/${Uri.encodeComponent(version.versionId)}/status?player=${Uri.encodeQueryComponent(_playerCode)}');
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
    _disposed = true;
    _timer?.cancel();
    _reloadTimer?.cancel();
    reloadRequests.dispose();
    endSessionRequests.dispose();
    super.dispose();
  }
}
