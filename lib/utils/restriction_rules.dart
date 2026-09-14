import 'dart:math' as math;

import 'package:digital_signage/models/compaign_model.dart';

// Pure evaluation of campaign playback restrictions.
//
// Extracted from MqttViewModel so the full operator/type matrix can actually
// be unit-tested. The logic previously lived inline in a ChangeNotifier that
// needs an MQTT connection and several platform plugins to construct, so
// none of it was reachable from a test -- which is why a wrong operator
// (see `on` below) survived in shipped builds.
//
// Two rules govern every decision here:
//
//  * A restriction the player can EVALUATE is evaluated honestly, even when
//    the answer is "don't play". That is the whole point of a restriction.
//  * A restriction the player CANNOT evaluate -- an unknown type, a
//    nonsensical type/operator pairing, or a device attribute the backend
//    never sent -- fails OPEN (plays) and says so loudly in the trace.
//    Failing closed on a rule we don't understand would blank every screen
//    in a fleet at once, which is a far worse outcome on signage than
//    showing content that should have been withheld.
//
// The distinction between "unknown" and "empty" matters for tags/groups: a
// device that is KNOWN to carry no tags legitimately fails `tags on [x]`,
// whereas a device whose tags were never sent by the backend cannot be
// judged at all and must fail open. Null means unknown, empty list means
// known-empty.

/// Everything about the device a restriction can be evaluated against.
class RestrictionContext {
  final DateTime now;

  /// 'windows', 'android', 'linux', 'macos', 'ios'.
  final String? os;

  /// Null means the backend never told us; empty means known to have none.
  final List<String>? tags;
  final List<String>? playerGroups;
  final String? locationName;
  final double? latitude;
  final double? longitude;

  const RestrictionContext({
    required this.now,
    this.os,
    this.tags,
    this.playerGroups,
    this.locationName,
    this.latitude,
    this.longitude,
  });
}

/// Result of evaluating a restriction set, with a trace for the debug log.
class RestrictionOutcome {
  final bool allowed;
  final List<String> trace;

  const RestrictionOutcome(this.allowed, this.trace);
}

/// Canonical operator name. Accepts isBetween / is_between / IS-BETWEEN /
/// "is between" and the `is`/`is not` spellings some rules use.
String normalizeOperator(String? op) {
  if (op == null) return '';
  final compact = op
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('_', '')
      .replaceAll('-', '');
  switch (compact) {
    case 'isbetween':
    case 'between':
      return 'is-between';
    case 'isbefore':
    case 'before':
      return 'is-before';
    case 'isafter':
    case 'after':
      return 'is-after';
    case 'noton':
    case 'isnot':
    case 'not':
    case 'isnoton':
      return 'not-on';
    case 'on':
    case 'is':
    case 'ison':
    case 'equals':
      return 'on';
    default:
      return compact;
  }
}

/// Canonical restriction type.
String normalizeType(String? type) {
  if (type == null) return '';
  final compact = type
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('_', '')
      .replaceAll('-', '');
  switch (compact) {
    case 'date':
      return 'date';
    case 'time':
      return 'time';
    case 'location':
    case 'locationname':
    case 'site':
      return 'location';
    case 'tag':
    case 'tags':
      return 'tags';
    case 'group':
    case 'groups':
    case 'playergroup':
    case 'playergroups':
      return 'groups';
    case 'os':
    case 'playeros':
    case 'platform':
    case 'devicetype':
      return 'os';
    default:
      return compact;
  }
}

/// Evaluates every restriction with AND semantics: all must pass.
RestrictionOutcome evaluateRestrictions(
  List<Restriction>? restrictions,
  RestrictionContext context,
) {
  final trace = <String>[];
  if (restrictions == null || restrictions.isEmpty) {
    return RestrictionOutcome(true, ['no restrictions -> allowed']);
  }

  for (final restriction in restrictions) {
    final type = normalizeType(restriction.type);
    final op = normalizeOperator(restriction.operator);
    final values = restriction.values ?? const <String>[];

    if (type.isEmpty || op.isEmpty) {
      trace.add('SKIP malformed (type=${restriction.type} '
          'operator=${restriction.operator}) -> fail open');
      continue;
    }

    bool? pass;
    switch (type) {
      case 'date':
        pass = _checkDate(op, values, context.now);
        break;
      case 'time':
        pass = _checkTime(op, values, context.now);
        break;
      case 'os':
        pass = _checkSet(op, values, _one(context.os));
        break;
      case 'tags':
        pass = _checkSet(op, values, context.tags);
        break;
      case 'groups':
        pass = _checkSet(op, values, context.playerGroups);
        break;
      case 'location':
        pass = _checkLocation(op, values, context);
        break;
      default:
        pass = null;
    }

    if (pass == null) {
      // Could not be evaluated -- unknown type, unusable operator, or the
      // device attribute was never provided. Fail open, but make it visible:
      // a restriction silently treated as "always play" is exactly how
      // location/tag rules appeared to do nothing at all.
      trace.add('UNEVALUATED type=$type operator=$op values=$values '
          '-> fail open (see restriction_rules.dart)');
      continue;
    }

    trace.add('$type/$op/$values -> ${pass ? "PASS" : "FAIL"}');
    if (!pass) return RestrictionOutcome(false, trace);
  }

  return RestrictionOutcome(true, trace);
}

List<String>? _one(String? value) =>
    value == null ? null : <String>[value];

/// Case/whitespace-insensitive membership, used by os/tags/groups.
///
/// `on` passes when the device carries ANY of the listed values (targeting
/// "show on players tagged lobby OR retail"), and `not-on` is its exact
/// inverse. Returns null when the device's own values are unknown.
bool? _checkSet(String op, List<String> values, List<String>? deviceValues) {
  if (deviceValues == null) return null;
  if (values.isEmpty) return null;
  final wanted = values.map(_norm).where((v) => v.isNotEmpty).toSet();
  final have = deviceValues.map(_norm).where((v) => v.isNotEmpty).toSet();
  final intersects = have.any(wanted.contains);
  switch (op) {
    case 'on':
      return intersects;
    case 'not-on':
      return !intersects;
    default:
      // is-between / is-before / is-after are meaningless for a set.
      return null;
  }
}

bool? _checkLocation(
    String op, List<String> values, RestrictionContext context) {
  // Coordinate form: ["lat", "lon", "radiusMetres"].
  final asCoords = _tryCoordinates(values);
  if (asCoords != null) {
    final lat = context.latitude;
    final lon = context.longitude;
    if (lat == null || lon == null) return null;
    final within =
        _metresBetween(lat, lon, asCoords[0], asCoords[1]) <= asCoords[2];
    switch (op) {
      case 'on':
        return within;
      case 'not-on':
        return !within;
      default:
        return null;
    }
  }
  // Otherwise treat the values as location names.
  return _checkSet(op, values, _one(context.locationName));
}

/// [lat, lon, radiusMetres] when the values look like coordinates.
List<double>? _tryCoordinates(List<String> values) {
  if (values.length < 2) return null;
  final lat = double.tryParse(values[0].trim());
  final lon = double.tryParse(values[1].trim());
  if (lat == null || lon == null) return null;
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  final radius =
      values.length > 2 ? double.tryParse(values[2].trim()) ?? 500 : 500;
  return <double>[lat, lon, radius];
}

/// Great-circle distance in metres (haversine).
double _metresBetween(double lat1, double lon1, double lat2, double lon2) {
  const earthRadius = 6371000.0;
  final dLat = _radians(lat2 - lat1);
  final dLon = _radians(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(_radians(lat1)) *
          math.cos(_radians(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
}

double _radians(double degrees) => degrees * math.pi / 180.0;

bool? _checkDate(String op, List<String> values, DateTime now) {
  if (values.isEmpty) return null;
  try {
    final today = DateTime(now.year, now.month, now.day);
    DateTime dayOf(String raw) {
      final parsed = DateTime.parse(raw.trim());
      return DateTime(parsed.year, parsed.month, parsed.day);
    }

    switch (op) {
      case 'is-between':
        if (values.length < 2) return null;
        final start = dayOf(values[0]);
        final end = dayOf(values[1]);
        return !today.isBefore(start) && !today.isAfter(end);
      case 'on':
        // Was `today == target || today.isAfter(target)` -- i.e. "on or
        // AFTER". A campaign restricted to a single date therefore kept
        // playing every day that followed it, forever. "on" means that day
        // and no other.
        return today.isAtSameMomentAs(dayOf(values[0]));
      case 'not-on':
        return !today.isAtSameMomentAs(dayOf(values[0]));
      case 'is-before':
        return today.isBefore(dayOf(values[0]));
      case 'is-after':
        // Inclusive of the target day, matching the CMS's "from this date
        // onwards" reading and the behaviour already confirmed working in
        // the field.
        return !today.isBefore(dayOf(values[0]));
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

bool? _checkTime(String op, List<String> values, DateTime now) {
  if (values.isEmpty) return null;
  try {
    final nowMinutes = now.hour * 60 + now.minute;
    switch (op) {
      case 'is-between':
        if (values.length < 2) return null;
        final start = _minutesOfDay(values[0]);
        final end = _minutesOfDay(values[1]);
        // An overnight window (22:00-06:00) wraps past midnight, so the
        // valid range is "at/after start OR at/before end", not AND.
        return end < start
            ? (nowMinutes >= start || nowMinutes <= end)
            : (nowMinutes >= start && nowMinutes <= end);
      case 'on':
        return nowMinutes == _minutesOfDay(values[0]);
      case 'not-on':
        return nowMinutes != _minutesOfDay(values[0]);
      case 'is-before':
        return nowMinutes < _minutesOfDay(values[0]);
      case 'is-after':
        return nowMinutes >= _minutesOfDay(values[0]);
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

/// Minutes since midnight from "HH:mm" or "HH:mm:ss" (tolerates "07: 04").
int _minutesOfDay(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length < 2) throw FormatException('Invalid time: $raw');
  return int.parse(parts[0].trim()) * 60 + int.parse(parts[1].trim());
}

String _norm(String value) => value.trim().toLowerCase();
