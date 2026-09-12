import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/utils/time_range_utils.dart';

void main() {
  group('isNowInTimeRange — overnight wraparound (W12 follow-up)', () {
    test('a normal same-day range matches inside and rejects outside', () {
      final noon = DateTime(2026, 1, 1, 12, 0, 0);
      expect(isNowInTimeRange('09:00', '17:00', now: noon), isTrue);

      final earlyMorning = DateTime(2026, 1, 1, 6, 0, 0);
      expect(isNowInTimeRange('09:00', '17:00', now: earlyMorning), isFalse);
    });

    test('an overnight range (22:00-06:00) matches after midnight and before it', () {
      final elevenPm = DateTime(2026, 1, 1, 23, 0, 0);
      expect(isNowInTimeRange('22:00', '06:00', now: elevenPm), isTrue);

      final oneAm = DateTime(2026, 1, 1, 1, 0, 0);
      expect(isNowInTimeRange('22:00', '06:00', now: oneAm), isTrue);

      final noon = DateTime(2026, 1, 1, 12, 0, 0);
      expect(isNowInTimeRange('22:00', '06:00', now: noon), isFalse);
    });

    test('seconds are optional -- "HH:mm" does not throw', () {
      final noon = DateTime(2026, 1, 1, 12, 0, 0);
      expect(() => isNowInTimeRange('09:00', '17:00', now: noon), returnsNormally);
      expect(isNowInTimeRange('09:00', '17:00', now: noon), isTrue);
    });

    test('"HH:mm:ss" still works and honors the seconds boundary', () {
      final justBefore = DateTime(2026, 1, 1, 17, 0, 29);
      expect(isNowInTimeRange('09:00:00', '17:00:30', now: justBefore), isTrue);

      final justAfter = DateTime(2026, 1, 1, 17, 0, 31);
      expect(isNowInTimeRange('09:00:00', '17:00:30', now: justAfter), isFalse);
    });
  });
}
