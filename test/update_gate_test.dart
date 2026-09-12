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

    // W19: the same build under different formatting must not look like a
    // different target -- reproduced bug: recordAttempt('13', 'v13', 2)
    // used to reset to 1 instead of continuing on to 3.
    test('bumps the same target across v-prefix/case/whitespace formatting', () {
      expect(recordAttempt('13', 'v13', 2).attemptCount, 3);
      expect(recordAttempt('V13', 'v13', 2).attemptCount, 3);
      expect(recordAttempt(' v13 ', 'v13', 2).attemptCount, 3);
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

    // W19: reproduced bug -- with 'v13' abandoned, a feed response of '13'
    // (same build, no v-prefix) used to fail the raw-string abandoned-target
    // check and get offered again anyway.
    test('recognizes an abandoned target across formatting when re-offered', () {
      final g = reconcileAndGate(
          current: 'v12', latest: '13', abandonedTarget: 'v13');
      expect(g.offer, isFalse);
    });

    // W19: same normalization applies to the "reached the attempted target"
    // success path -- the running build reporting itself without the
    // v-prefix must still be recognized as the attempted target.
    test('recognizes success across formatting, not just exact string match', () {
      final g = reconcileAndGate(
          current: '13', latest: '13', attemptTarget: 'v13', attemptCount: 1);
      expect(g.attemptTarget, isNull);
      expect(g.attemptCount, 0);
    });
  });
}
