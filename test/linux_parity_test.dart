import 'package:digital_signage/services/content_resend.dart';
import 'package:digital_signage/services/now_playing.dart';
import 'package:digital_signage/services/on_demand_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OnDemandState', () {
    final now = DateTime(2026, 11, 11, 14, 30);

    test('on-demand items stay out of the rotation until fired', () {
      final s = OnDemandState();
      expect(s.allows('loop-1', false), isTrue);
      expect(s.allows('od-1', true), isFalse);
    });

    test('while active, only the fired item may play', () {
      final s = OnDemandState()..start('od-1', 2, 'play', now);
      expect(s.allows('od-1', true), isTrue);
      expect(s.allows('loop-1', false), isFalse);
      expect(s.allows('od-2', true), isFalse);
    });

    test('repeat counts loops, then the rotation resumes', () {
      final s = OnDemandState()..start('od-1', 2, 'play', now);
      s.countPlay();
      expect(s.expireIfDone(now), isFalse);
      s.countPlay();
      expect(s.expireIfDone(now), isTrue);
      expect(s.active, isFalse);
      expect(s.allows('loop-1', false), isTrue);
    });

    test('repeat 0 plays until midnight', () {
      final s = OnDemandState()..start('od-1', 0, 'play', now);
      for (var i = 0; i < 50; i++) s.countPlay();
      expect(s.expireIfDone(DateTime(2026, 11, 11, 23, 59)), isFalse);
      expect(s.expireIfDone(DateTime(2026, 11, 12, 0, 0)), isTrue);
    });

    test('stop ends it, blank ids and unknown modes are handled', () {
      final s = OnDemandState();
      expect(s.start('  ', 1, 'play', now), isFalse);
      expect(s.start('od-1', 1, 'bogus', now), isTrue);
      expect(s.mode, 'play');
      s.stop();
      expect(s.active, isFalse);
    });
  });

  group('NowPlaying', () {
    test('campaign message matches the backend contract', () {
      final m = NowPlaying.campaign(
        campaignId: 'c1',
        name: 'Menu',
        reason: 'scheduled',
        startedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        durationSeconds: 15,
        zoneCount: 2,
        sentAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      expect(m['action'], 'now_playing');
      final d = m['data'] as Map;
      expect(d['key'], 'c1');
      expect(d['reason'], 'scheduled');
      expect(d['started_at'], 1000);
      expect(d['sent_at'], 2000);
      expect(d['duration_s'], 15);
      expect(d['zone_count'], 2);
      expect(d.containsKey('child_index'), isTrue);
    });

    test('interactivity keys are prefixed once', () {
      expect(NowPlaying.keyFor('7', 'create_interactivity'), 'interactivity_7');
      expect(NowPlaying.keyFor('interactivity_7', 'create_interactivity'), 'interactivity_7');
      expect(NowPlaying.keyFor('7', 'campaign'), '7');
    });

    test('no content', () {
      final d = NowPlaying.noContent(DateTime.fromMillisecondsSinceEpoch(5))['data'] as Map;
      expect(d['key'], 'no_content');
      expect(d['reason'], 'no_content');
    });
  });

  group('sameContent', () {
    const stored = '{"action":"publish_campaign","data":{"b":2,"a":[1,{"y":1,"x":2}]}}';

    test('same data in another key order is unchanged', () {
      expect(sameContent(stored, {
        'action': 'publish_campaign',
        'resend': true,
        'data': {'a': [1, {'x': 2, 'y': 1}], 'b': 2},
      }), isTrue);
    });

    test('different data or action is new content', () {
      expect(sameContent(stored, {'action': 'publish_campaign', 'data': {'a': [1], 'b': 2}}), isFalse);
      expect(sameContent(stored, {'action': 'publish_playlist', 'data': {'b': 2, 'a': [1, {'y': 1, 'x': 2}]}}), isFalse);
      expect(sameContent('not json', {'action': 'publish_campaign'}), isFalse);
    });
  });
}
