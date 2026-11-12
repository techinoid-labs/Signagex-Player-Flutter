import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Player attributes (backend docs/PLAYER_PLUGIN_CONTRACT.md): values like
/// `temperature` or `promo_mode`, set by hand in the CMS (`{code}/attrs`,
/// `update_player_attributes`, and the pairing response's `attrs`) or by a
/// plugin page. Kept on disk so they survive a reboot, evaluated by the
/// `player_attribute` restriction, and reported upstream with
/// `player_attributes` when a plugin sets them.
class AttrValue {
  final Object value; // String | num | bool
  final DateTime updatedAt;
  final String source;
  const AttrValue(this.value, this.updatedAt, this.source);

  Map<String, dynamic> toJson() =>
      {'value': value, 'updated_at': updatedAt.toUtc().toIso8601String(), 'source': source};

  static AttrValue? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final v = raw['value'];
    if (v is! String && v is! num && v is! bool) return null;
    final at = DateTime.tryParse('${raw['updated_at'] ?? ''}');
    if (at == null) return null;
    return AttrValue(v as Object, at, '${raw['source'] ?? 'manual'}');
  }
}

class PlayerAttributes {
  PlayerAttributes._();
  static final PlayerAttributes instance = PlayerAttributes._();

  static final keyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static const maxKeys = 100;
  static const maxText = 500;

  final Map<String, AttrValue> values = {};
  Directory? _dir;
  bool _loaded = false;

  /// Called after any change (restrictions re-checked by the player).
  void Function()? onChanged;

  Future<void> load({Directory? directory}) async {
    _dir = directory ??
        Directory('${Platform.environment['HOME'] ?? '.'}/.local/share/signagex-player');
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File('${_dir!.path}/attrs.json');
      if (!await f.exists()) return;
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map) {
        raw.forEach((k, v) {
          final a = AttrValue.fromJson(v);
          if (a != null && keyPattern.hasMatch('$k')) values['$k'] = a;
        });
      }
    } catch (_) {}
  }

  /// `update_player_attributes` / the pairing response: for each key keep the
  /// newer `updated_at`; delete every key in `removed`. Returns true if changed.
  bool applyFromCms(Object? data) {
    if (data is! Map) return false;
    var changed = false;
    final attrs = data['attrs'];
    if (attrs is Map) {
      attrs.forEach((k, v) {
        final key = '$k';
        final incoming = AttrValue.fromJson(v);
        if (!keyPattern.hasMatch(key) || incoming == null) return;
        final mine = values[key];
        if (mine == null || incoming.updatedAt.isAfter(mine.updatedAt)) {
          values[key] = _clip(incoming);
          changed = true;
        }
      });
    }
    final removed = data['removed'];
    if (removed is List) {
      for (final k in removed) {
        if (values.remove('$k') != null) changed = true;
      }
    }
    _enforceCap();
    if (changed) _changed();
    return changed;
  }

  /// A plugin page's setAttributes: returns the accepted plain values (what
  /// to report upstream as `player_attributes`).
  Map<String, Object> setFromPlugin(String instanceId, Map attrs, {DateTime? now}) {
    final at = (now ?? DateTime.now()).toUtc();
    final accepted = <String, Object>{};
    attrs.forEach((k, v) {
      final key = '$k';
      if (!keyPattern.hasMatch(key)) return;
      if (v is! String && v is! num && v is! bool) return;
      final a = _clip(AttrValue(v as Object, at, instanceId));
      values[key] = a;
      accepted[key] = a.value;
    });
    _enforceCap();
    if (accepted.isNotEmpty) _changed();
    return accepted;
  }

  /// Unpair / account_deleted.
  void clear() {
    if (values.isEmpty) return;
    values.clear();
    _changed();
  }

  AttrValue _clip(AttrValue a) => a.value is String && (a.value as String).length > maxText
      ? AttrValue((a.value as String).substring(0, maxText), a.updatedAt, a.source)
      : a;

  void _enforceCap() {
    if (values.length <= maxKeys) return;
    final keys = values.keys.toList()
      ..sort((a, b) => values[a]!.updatedAt.compareTo(values[b]!.updatedAt));
    for (final k in keys.take(values.length - maxKeys)) {
      values.remove(k);
    }
  }

  void _changed() {
    unawaited(_persist());
    onChanged?.call();
  }

  Future<void> _persist() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      await dir.create(recursive: true);
      final tmp = File('${dir.path}/attrs.json.part');
      await tmp.writeAsString(jsonEncode(values.map((k, v) => MapEntry(k, v.toJson()))), flush: true);
      await tmp.rename('${dir.path}/attrs.json');
    } catch (_) {}
  }

  /// The `player_attribute` restriction: `values[0]` is the key, then operands.
  bool matches(String? operator, List<String>? args) =>
      evaluate(operator, args, (key) => values[key]?.value);

  static bool evaluate(String? operator, List<String>? args, Object? Function(String key) lookup) {
    if (args == null || args.isEmpty) return true; // not evaluable: pass, like other unknowns
    final op = (operator ?? '').toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
    final stored = lookup(args[0]);
    final present = stored != null && '$stored'.isNotEmpty;
    final operands = args.sublist(1);
    double? n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    switch (op) {
      case 'empty':
      case 'isempty':
        return !present;
      case 'notempty':
      case 'isnotempty':
        return present;
    }
    if (!present || operands.isEmpty) return false;
    final text = '$stored';
    switch (op) {
      case 'is':
        return text.toLowerCase() == operands[0].toLowerCase();
      case 'isnot':
        return text.toLowerCase() != operands[0].toLowerCase();
      case 'contains':
        return text.toLowerCase().contains(operands[0].toLowerCase());
      case 'notcontains':
      case 'doesnotcontain':
        return !text.toLowerCase().contains(operands[0].toLowerCase());
      case 'greaterthan':
        final a = n(stored), b = n(operands[0]);
        return a != null && b != null && a > b;
      case 'lessthan':
        final a = n(stored), b = n(operands[0]);
        return a != null && b != null && a < b;
      case 'isbetween':
        if (operands.length < 2) return false;
        final a = n(stored), lo = n(operands[0]), hi = n(operands[1]);
        return a != null && lo != null && hi != null && lo <= a && a <= hi;
    }
    return true; // unknown operator: pass, like the other restriction types
  }
}
