import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/utils/interactivity_hit_test.dart';

void main() {
  group('isPointInRegion', () {
    test('a point inside the rectangle matches', () {
      expect(
        isPointInRegion(
            x: 50, y: 50, regionX: 0, regionY: 0, regionWidth: 100, regionHeight: 100),
        isTrue,
      );
    });

    test('a point exactly on the boundary matches (inclusive)', () {
      expect(
        isPointInRegion(
            x: 100, y: 100, regionX: 0, regionY: 0, regionWidth: 100, regionHeight: 100),
        isTrue,
      );
    });

    test('a point outside the rectangle does not match', () {
      expect(
        isPointInRegion(
            x: 150, y: 50, regionX: 0, regionY: 0, regionWidth: 100, regionHeight: 100),
        isFalse,
      );
    });

    test('a rectangle not anchored at the origin', () {
      expect(
        isPointInRegion(
            x: 220, y: 130, regionX: 200, regionY: 100, regionWidth: 50, regionHeight: 50),
        isTrue,
      );
      expect(
        isPointInRegion(
            x: 190, y: 130, regionX: 200, regionY: 100, regionWidth: 50, regionHeight: 50),
        isFalse,
      );
    });
  });

  group('keyMatches', () {
    test('matches case-insensitively', () {
      expect(keyMatches(['Escape', 'Enter'], 'escape'), isTrue);
      expect(keyMatches(['Escape', 'Enter'], 'ESCAPE'), isTrue);
    });

    test('no match returns false', () {
      expect(keyMatches(['Escape', 'Enter'], 'Tab'), isFalse);
    });

    test('an empty key list never matches', () {
      expect(keyMatches([], 'Escape'), isFalse);
    });
  });
}
