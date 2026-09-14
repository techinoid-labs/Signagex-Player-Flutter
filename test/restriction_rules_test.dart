import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/models/compaign_model.dart';
import 'package:digital_signage/utils/restriction_rules.dart';

Restriction r(String type, String op, List<String> values) =>
    Restriction(type: type, operator: op, values: values);

// 2026-09-14 is a Monday; 14:30 local.
final _now = DateTime(2026, 9, 14, 14, 30);

RestrictionContext ctx({
  DateTime? now,
  String? os = 'windows',
  List<String>? tags,
  List<String>? playerGroups,
  String? locationName,
  double? latitude,
  double? longitude,
}) =>
    RestrictionContext(
      now: now ?? _now,
      os: os,
      tags: tags,
      playerGroups: playerGroups,
      locationName: locationName,
      latitude: latitude,
      longitude: longitude,
    );

bool allows(List<Restriction> rules, [RestrictionContext? context]) =>
    evaluateRestrictions(rules, context ?? ctx()).allowed;

void main() {
  group('operator normalization', () {
    test('accepts the spellings the backend actually sends', () {
      for (final spelling in ['is-between', 'is_between', 'isBetween', 'IS BETWEEN', 'between']) {
        expect(normalizeOperator(spelling), 'is-between', reason: spelling);
      }
      for (final spelling in ['not-on', 'not_on', 'notOn', 'is not', 'isNot']) {
        expect(normalizeOperator(spelling), 'not-on', reason: spelling);
      }
      for (final spelling in ['on', 'is', 'equals']) {
        expect(normalizeOperator(spelling), 'on', reason: spelling);
      }
      expect(normalizeOperator('is-after'), 'is-after');
      expect(normalizeOperator('is-before'), 'is-before');
    });

    test('type aliases collapse to canonical names', () {
      expect(normalizeType('player_os'), 'os');
      expect(normalizeType('platform'), 'os');
      expect(normalizeType('Tags'), 'tags');
      expect(normalizeType('locationName'), 'location');
      expect(normalizeType('playerGroups'), 'groups');
    });
  });

  group('date', () {
    test('is-between is inclusive of both endpoints', () {
      expect(allows([r('date', 'is-between', ['2026-09-14', '2026-09-20'])]), isTrue);
      expect(allows([r('date', 'is-between', ['2026-09-01', '2026-09-14'])]), isTrue);
      expect(allows([r('date', 'is-between', ['2026-09-15', '2026-09-20'])]), isFalse);
      expect(allows([r('date', 'is-between', ['2026-09-01', '2026-09-13'])]), isFalse);
    });

    test('on means THAT day only -- not "on or after"', () {
      expect(allows([r('date', 'on', ['2026-09-14'])]), isTrue);
      // The bug being fixed: a single-date campaign used to keep playing on
      // every subsequent day, forever.
      expect(allows([r('date', 'on', ['2026-09-13'])]), isFalse);
      expect(allows([r('date', 'on', ['2026-09-15'])]), isFalse);
    });

    test('not-on is the exact inverse of on', () {
      expect(allows([r('date', 'not-on', ['2026-09-14'])]), isFalse);
      expect(allows([r('date', 'not-on', ['2026-09-13'])]), isTrue);
    });

    test('is-after includes the target day, is-before excludes it', () {
      expect(allows([r('date', 'is-after', ['2026-09-14'])]), isTrue);
      expect(allows([r('date', 'is-after', ['2026-09-13'])]), isTrue);
      expect(allows([r('date', 'is-after', ['2026-09-15'])]), isFalse);

      expect(allows([r('date', 'is-before', ['2026-09-15'])]), isTrue);
      expect(allows([r('date', 'is-before', ['2026-09-14'])]), isFalse);
    });

    test('time of day never affects a date comparison', () {
      for (final hour in [0, 9, 23]) {
        final c = ctx(now: DateTime(2026, 9, 14, hour, 59));
        expect(allows([r('date', 'on', ['2026-09-14'])], c), isTrue,
            reason: 'hour $hour');
      }
    });

    test('full ISO timestamps are accepted as values', () {
      expect(allows([r('date', 'on', ['2026-09-14T00:00:00.000Z'])]), isTrue);
    });

    test('unparseable dates fail open rather than blanking the screen', () {
      expect(allows([r('date', 'on', ['not-a-date'])]), isTrue);
    });
  });

  group('time', () {
    test('is-between within the same day', () {
      expect(allows([r('time', 'is-between', ['14:00', '15:00'])]), isTrue);
      expect(allows([r('time', 'is-between', ['14:30', '15:00'])]), isTrue);
      expect(allows([r('time', 'is-between', ['09:00', '14:30'])]), isTrue);
      expect(allows([r('time', 'is-between', ['15:00', '16:00'])]), isFalse);
    });

    test('is-between wrapping past midnight', () {
      final lateNight = ctx(now: DateTime(2026, 9, 14, 23, 0));
      final earlyHours = ctx(now: DateTime(2026, 9, 14, 3, 0));
      final midday = ctx(now: DateTime(2026, 9, 14, 12, 0));
      final overnight = [r('time', 'is-between', ['22:00', '06:00'])];
      expect(allows(overnight, lateNight), isTrue);
      expect(allows(overnight, earlyHours), isTrue);
      expect(allows(overnight, midday), isFalse);
    });

    test('is-after is inclusive, is-before exclusive', () {
      expect(allows([r('time', 'is-after', ['14:30'])]), isTrue);
      expect(allows([r('time', 'is-after', ['14:29'])]), isTrue);
      expect(allows([r('time', 'is-after', ['14:31'])]), isFalse);
      expect(allows([r('time', 'is-before', ['14:31'])]), isTrue);
      expect(allows([r('time', 'is-before', ['14:30'])]), isFalse);
    });

    test('on and not-on match the exact minute', () {
      expect(allows([r('time', 'on', ['14:30'])]), isTrue);
      expect(allows([r('time', 'on', ['14:31'])]), isFalse);
      expect(allows([r('time', 'not-on', ['14:30'])]), isFalse);
      expect(allows([r('time', 'not-on', ['14:31'])]), isTrue);
    });

    test('seconds and sloppy spacing are tolerated', () {
      expect(allows([r('time', 'is-after', ['14:30:00'])]), isTrue);
      expect(allows([r('time', 'is-after', ['14: 30'])]), isTrue);
    });
  });

  group('player OS', () {
    test('on matches the running platform, case-insensitively', () {
      expect(allows([r('player_os', 'on', ['windows'])]), isTrue);
      expect(allows([r('player_os', 'on', ['Windows'])]), isTrue);
      expect(allows([r('os', 'on', ['android'])]), isFalse);
    });

    test('on passes when any listed OS matches', () {
      expect(allows([r('os', 'on', ['android', 'windows'])]), isTrue);
      expect(allows([r('os', 'on', ['android', 'ios'])]), isFalse);
    });

    test('not-on excludes the running platform', () {
      expect(allows([r('os', 'not-on', ['windows'])]), isFalse);
      expect(allows([r('os', 'not-on', ['android'])]), isTrue);
    });
  });

  group('tags and groups', () {
    test('on passes when the device carries ANY listed tag', () {
      final c = ctx(tags: ['lobby', 'retail']);
      expect(allows([r('tags', 'on', ['lobby'])], c), isTrue);
      expect(allows([r('tags', 'on', ['warehouse', 'retail'])], c), isTrue);
      expect(allows([r('tags', 'on', ['warehouse'])], c), isFalse);
    });

    test('not-on is the exact inverse', () {
      final c = ctx(tags: ['lobby']);
      expect(allows([r('tags', 'not-on', ['lobby'])], c), isFalse);
      expect(allows([r('tags', 'not-on', ['warehouse'])], c), isTrue);
    });

    test('a device KNOWN to have no tags legitimately fails a tag rule', () {
      final c = ctx(tags: const []);
      expect(allows([r('tags', 'on', ['lobby'])], c), isFalse);
      expect(allows([r('tags', 'not-on', ['lobby'])], c), isTrue);
    });

    test('tags the backend never sent cannot be judged -- fail open', () {
      final c = ctx(tags: null);
      expect(allows([r('tags', 'on', ['lobby'])], c), isTrue);
      expect(allows([r('tags', 'not-on', ['lobby'])], c), isTrue);
    });

    test('player groups behave like tags', () {
      final c = ctx(playerGroups: ['north-region']);
      expect(allows([r('playerGroups', 'on', ['north-region'])], c), isTrue);
      expect(allows([r('groups', 'on', ['south-region'])], c), isFalse);
    });
  });

  group('location', () {
    test('matches by name', () {
      final c = ctx(locationName: 'Lahore Store');
      expect(allows([r('location', 'on', ['Lahore Store'])], c), isTrue);
      expect(allows([r('location', 'on', ['lahore store'])], c), isTrue);
      expect(allows([r('location', 'on', ['Karachi Store'])], c), isFalse);
      expect(allows([r('location', 'not-on', ['Karachi Store'])], c), isTrue);
    });

    test('matches by coordinates within a radius', () {
      // Device sits at the coordinates this fleet actually reports.
      final c = ctx(latitude: 31.608004, longitude: 74.341942);
      // Same point, 500m default radius.
      expect(allows([r('location', 'on', ['31.608004', '74.341942'])], c), isTrue);
      // ~2km away, default radius -> outside.
      expect(allows([r('location', 'on', ['31.626', '74.341942'])], c), isFalse);
      // Same point but with a generous explicit radius -> inside.
      expect(allows([r('location', 'on', ['31.626', '74.341942', '5000'])], c), isTrue);
    });

    test('unknown position cannot be judged -- fail open', () {
      final c = ctx(latitude: null, longitude: null);
      expect(allows([r('location', 'on', ['31.6', '74.3'])], c), isTrue);
    });
  });

  group('combining rules', () {
    test('all restrictions must pass (AND)', () {
      expect(
          allows([
            r('date', 'is-after', ['2026-09-01']),
            r('time', 'is-between', ['09:00', '17:00']),
            r('os', 'on', ['windows']),
          ]),
          isTrue);
      expect(
          allows([
            r('date', 'is-after', ['2026-09-01']),
            r('time', 'is-between', ['18:00', '20:00']),
          ]),
          isFalse);
    });

    test('an empty or null restriction list allows playback', () {
      expect(evaluateRestrictions(null, ctx()).allowed, isTrue);
      expect(evaluateRestrictions(const [], ctx()).allowed, isTrue);
    });

    test('unknown types fail open but are recorded in the trace', () {
      final outcome =
          evaluateRestrictions([r('weather', 'on', ['sunny'])], ctx());
      expect(outcome.allowed, isTrue);
      expect(outcome.trace.join(' '), contains('UNEVALUATED'));
    });

    test('a nonsensical type/operator pairing fails open, not closed', () {
      // "is-between" makes no sense for a tag set.
      final c = ctx(tags: ['lobby']);
      expect(allows([r('tags', 'is-between', ['a', 'b'])], c), isTrue);
    });
  });
}
