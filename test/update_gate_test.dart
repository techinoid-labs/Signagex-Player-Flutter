import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/services/update_check_service.dart';

void main() {
  group('recordAttempt — counts real install launches, per target', () {
    test('starts at 1 for a fresh target', () {
      final r = recordAttempt('v13', null, 0);
      expect(r.attemptTarget, 'v13');
      expect(r.attemptCount, 1);
    });
    test('bumps the same target', () {
      final r = recordAttempt('v13', 'v13', 1);
      expect(r.attemptCount, 2);
    });
    test('resets when the target changes', () {
      final r = recordAttempt('v14', 'v13', 2);
      expect(r.attemptTarget, 'v14');
      expect(r.attemptCount, 1);
    });
  });

  group('reconcileAndGate — offer only a strictly newer, non-looping build', () {
    test('offers a strictly newer build', () {
      expect(reconcileAndGate(current: 'v12', latest: 'v13').offer, isTrue);
    });
    test('never offers equal or older', () {
      expect(reconcileAndGate(current: 'v13', latest: 'v13').offer, isFalse);
      expect(reconcileAndGate(current: 'v13', latest: 'v12').offer, isFalse);
    });
    test('reaching the attempted target clears state and stops offering', () {
      final g = reconcileAndGate(
          current: 'v13', latest: 'v13', attemptTarget: 'v13', attemptCount: 1);
      expect(g.offer, isFalse);
      expect(g.attemptTarget, isNull);
      expect(g.attemptCount, 0);
    });
    test('gives up on a target that keeps installing but stays older', () {
      final g = reconcileAndGate(
          current: 'v12',
          latest: 'v13',
          attemptTarget: 'v13',
          attemptCount: 3,
          maxAttempts: 3);
      expect(g.abandonedTarget, 'v13');
      expect(g.attemptTarget, isNull);
      expect(g.offer, isFalse); // v13 is abandoned -> not offered again
    });
    test('does not re-offer an abandoned target', () {
      final g = reconcileAndGate(
          current: 'v12', latest: 'v13', abandonedTarget: 'v13');
      expect(g.offer, isFalse);
    });
    test('a strictly higher build re-arms after an abandoned target', () {
      final g = reconcileAndGate(
          current: 'v12', latest: 'v14', abandonedTarget: 'v13');
      expect(g.abandonedTarget, isNull);
      expect(g.offer, isTrue);
    });
  });
}
