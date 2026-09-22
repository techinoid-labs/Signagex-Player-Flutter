import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/utils/transitions.dart';

// The bug these cover: the transition switches were written against names
// the CMS does not produce, so every transition fell through to the default
// and nothing animated, whichever option was picked in the CMS. Each case
// below is a name the CMS actually sends.
void main() {
  group('normalizeTransitionName', () {
    test('maps the names the campaign editor sends', () {
      expect(normalizeTransitionName('no-transition'), 'none');
      expect(normalizeTransitionName('fade'), 'fadeIn');
      expect(normalizeTransitionName('slide'), 'slideOverRightToLeft');
    });

    test('maps the names the playlist editor sends', () {
      expect(normalizeTransitionName('none'), 'none');
      expect(normalizeTransitionName('fade-in'), 'fadeIn');
      // A cross-fade already fades the outgoing item out, so fade-out is the
      // same animation rather than a separate one.
      expect(normalizeTransitionName('fade-out'), 'fadeIn');
      expect(normalizeTransitionName('slide'), 'slideOverRightToLeft');
    });

    test('ignores case, spaces, hyphens and underscores', () {
      // Payloads have been seen carrying "Fade" capitalised.
      for (final raw in ['Fade', 'FADE', ' fade ', 'fade_in', 'Fade In']) {
        expect(normalizeTransitionName(raw), 'fadeIn', reason: raw);
      }
      expect(normalizeTransitionName('No Transition'), 'none');
      expect(
        normalizeTransitionName('slide_over_left_to_right'),
        'slideOverLeftToRight',
      );
    });

    test('passes through the directional names already implemented', () {
      expect(
        normalizeTransitionName('slideInOutBottomToTop'),
        'slideInOutBottomToTop',
      );
      expect(
        normalizeTransitionName('slideOverTopToBottom'),
        'slideOverTopToBottom',
      );
    });

    test('falls back to none for absent or unknown names', () {
      // A transition nobody asked for is more jarring than none at all.
      expect(normalizeTransitionName(null), 'none');
      expect(normalizeTransitionName(''), 'none');
      expect(normalizeTransitionName('   '), 'none');
      expect(normalizeTransitionName('spin-around-twice'), 'none');
    });
  });
}
