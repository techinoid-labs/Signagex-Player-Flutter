import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/constants.dart' as constants;

/// Composition elements bound to a SignageX data feed
/// (`properties.dataFeed` = {feedId, columnId, rowMode, matchColumnId,
/// matchValue, initialRow, step, cycleDuration, enableCycleReset}).
///
/// The same rules as Android's composition runtime (CompositionRenderFragment
/// DATA_FEED_RUNTIME) and the editor preview: pick the active rows ("all", or
/// "match" on a column), start at the initial row (or the remembered position
/// when cycle reset is off), advance by `step` every `cycleDuration` seconds
/// and wrap; a numeric rowMode always shows that row. Feeds load from
/// `GET {base}data-feed/{id}` now and every 60 s; offline keeps the last data
/// (or the element's saved text).
class FeedBinding {
  final String feedId;
  final String columnId;
  final String rowMode; // 'all' | 'match' | '<n>'
  final String? matchColumnId;
  final String? matchValue;
  final int initialRow;
  final int step;
  final int cycleSeconds;
  final bool enableCycleReset;

  const FeedBinding({
    required this.feedId,
    required this.columnId,
    this.rowMode = 'all',
    this.matchColumnId,
    this.matchValue,
    this.initialRow = 1,
    this.step = 1,
    this.cycleSeconds = 30,
    this.enableCycleReset = true,
  });

  /// Null unless the element is really bound (feed and column set).
  static FeedBinding? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final feed = raw['feedId']?.toString() ?? '';
    final column = raw['columnId']?.toString() ?? '';
    if (feed.trim().isEmpty || column.trim().isEmpty) return null;
    int n(Object? v, int d) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? d;
    return FeedBinding(
      feedId: feed,
      columnId: column,
      rowMode: raw['rowMode']?.toString() ?? 'all',
      matchColumnId: raw['matchColumnId']?.toString(),
      matchValue: raw['matchValue']?.toString(),
      initialRow: n(raw['initialRow'], 1),
      step: n(raw['step'], 1) <= 0 ? 1 : n(raw['step'], 1),
      cycleSeconds: n(raw['cycleDuration'], 30) < 1 ? 1 : n(raw['cycleDuration'], 30),
      enableCycleReset: raw['enableCycleReset'] == true,
    );
  }

  /// A numeric rowMode: always that (1-based) row.
  int? get fixedRow {
    if (rowMode == 'all' || rowMode == 'match') return null;
    return int.tryParse(rowMode);
  }
}

class FeedRules {
  static Map? _feedOf(Object? response) {
    if (response is! Map) return null;
    final inner = response['dataFeed'];
    return inner is Map ? inner : response;
  }

  static List<Map> columns(Object? response) =>
      [for (final c in (_feedOf(response)?['columns'] as List? ?? const [])) if (c is Map) c];

  static Map? column(Object? response, String id) {
    for (final c in columns(response)) {
      if (c['id']?.toString() == id) return c;
    }
    return null;
  }

  static Object? _cell(Map row, Map col) {
    final values = row['column_values'];
    if (values is! Map) return null;
    return values.containsKey(col['name']) ? values[col['name']] : values[col['id']];
  }

  /// The display value of a cell: text, or for a stored object its URL.
  static String valueOf(Map? row, Map? col) {
    if (row == null || col == null) return '';
    var v = _cell(row, col);
    if (v == null) return '';
    if (v is String) {
      // A local copy: `v` is reassigned below, so Dart can't keep it promoted to String.
      final text = v;
      try {
        final p = jsonDecode(text);
        if (p is Map) {
          v = p;
        } else {
          return text;
        }
      } catch (_) {
        return text;
      }
    }
    if (v is Map) {
      for (final k in const ['dataUrl', 'url', 'src', 'fileUrl', 'link']) {
        if (v[k] != null && '${v[k]}'.isNotEmpty) return '${v[k]}';
      }
      return jsonEncode(v);
    }
    return '$v';
  }

  static List<Map> activeRows(Object? response, FeedBinding b) {
    final rows = [for (final r in (_feedOf(response)?['rows'] as List? ?? const [])) if (r is Map) r]
      ..sort((a, c) => ((a['order_index'] as num?) ?? 0).compareTo((c['order_index'] as num?) ?? 0));
    if (b.rowMode == 'match' && (b.matchColumnId ?? '').isNotEmpty && (b.matchValue ?? '').isNotEmpty) {
      final mc = column(response, b.matchColumnId!);
      if (mc != null) {
        return rows.where((r) => '${_cell(r, mc)}' == b.matchValue).toList();
      }
    }
    return rows;
  }

  /// The row index to start at (0-based), honouring a remembered position.
  static int startIndex(FeedBinding b, int? remembered) {
    if (!b.enableCycleReset && remembered != null && remembered >= 0) return remembered;
    return b.initialRow - 1 < 0 ? 0 : b.initialRow - 1;
  }

  /// The value to show at [index] (wrapped), or the fixed row's.
  static String valueAt(Object? response, FeedBinding b, int index) {
    final col = column(response, b.columnId);
    if (col == null) return '';
    final rows = activeRows(response, b);
    if (rows.isEmpty) return '';
    final fixed = b.fixedRow;
    if (fixed != null) {
      final i = fixed - 1 < 0 ? 0 : fixed - 1;
      return i < rows.length ? valueOf(rows[i], col) : '';
    }
    return valueOf(rows[index % rows.length], col);
  }

  static int next(Object? response, FeedBinding b, int index) {
    final count = activeRows(response, b).length;
    return count == 0 ? index : (index + b.step) % count;
  }
}

/// Loads bound feeds and refreshes them every 60 s while something shows them.
class DataFeedStore {
  DataFeedStore._();
  static final DataFeedStore instance = DataFeedStore._();
  static const refresh = Duration(seconds: 60);

  String baseUrl = constants.baseurl;
  http.Client client = http.Client();
  final Map<String, Object?> _latest = {};
  final Map<String, StreamController<Object?>> _streams = {};
  final Map<String, int> _users = {};
  final Map<String, Timer> _timers = {};

  Object? latest(String feedId) => _latest[feedId];

  /// Updates for [feedId]; the first listener starts loading and refreshing.
  Stream<Object?> watch(String feedId) {
    final c = _streams.putIfAbsent(feedId, () => StreamController<Object?>.broadcast(
          onListen: () => _start(feedId),
          onCancel: () => _stop(feedId),
        ));
    return c.stream;
  }

  void _start(String feedId) {
    _users[feedId] = (_users[feedId] ?? 0) + 1;
    if (_timers.containsKey(feedId)) return;
    unawaited(_load(feedId));
    _timers[feedId] = Timer.periodic(refresh, (_) => unawaited(_load(feedId)));
  }

  void _stop(String feedId) {
    _users[feedId] = 0;
    _timers.remove(feedId)?.cancel();
  }

  Future<void> _load(String feedId) async {
    if (baseUrl.isEmpty) return;
    try {
      final res = await client
          .get(Uri.parse('${baseUrl}data-feed/${Uri.encodeComponent(feedId)}'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode < 200 || res.statusCode > 299) return;
      final body = jsonDecode(res.body);
      _latest[feedId] = body;
      _streams[feedId]?.add(body);
    } catch (_) {
      // Offline: keep showing the last data (or the saved text).
    }
  }
}
