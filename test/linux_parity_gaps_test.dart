import 'dart:convert';

import 'package:digital_signage/services/data_feed_binding.dart';
import 'package:digital_signage/services/linux_plugins.dart';
import 'package:digital_signage/services/linux_pop.dart';
import 'package:digital_signage/services/player_attributes.dart';
import 'package:digital_signage/services/proof_screenshots.dart';
import 'package:flutter_test/flutter_test.dart';

const key = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';

void main() {
  group('proof of play signing', () {
    test('matches the backend HMAC (Buffer.from(key, hex))', () {
      expect(PopSigning.sign(key, 1700000000, 'abc123', '[{"a":1}]'),
          '93eebb6eae0a93ac85450ae63e33a002b838467bdc3a8b93e91bcc59991f0764');
      expect(PopSigning.sha256Hex([1, 2, 3]),
          '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81');
      expect(PopSigning.isValidKey(key), isTrue);
      expect(PopSigning.isValidKey('abc'), isFalse);
    });

    test('signed REST body signs exactly contents_json', () {
      final entries = [
        {'content_id': 'c1', 'play_count': 1}
      ];
      final body = jsonDecode(PopEnvelope.restBody('abc123', entries, key, 1700000000)) as Map;
      expect(body['player_code'], 'abc123');
      expect(body['sender'], 'linux');
      expect(body['ts'], 1700000000);
      expect(body['signature'],
          PopSigning.sign(key, 1700000000, 'abc123', body['contents_json'] as String));
      expect(body.containsKey('contents'), isFalse);
    });

    test('unsigned v1 body has no sender over REST, but MQTT does', () {
      final rest = jsonDecode(PopEnvelope.restBody('p', [{'content_id': 'c'}], null, 1)) as Map;
      expect(rest.containsKey('sender'), isFalse);
      expect(rest['contents'], isA<List>());
      final mqtt = jsonDecode(PopEnvelope.mqttMessage('p', [{'content_id': 'c'}], null, 1)) as Map;
      expect(mqtt['action'], 'content_proof_of_play');
      expect(mqtt['sender'], 'linux');
    });
  });

  group('proof of play queue', () {
    final t = DateTime.utc(2026, 11, 11, 10);
    var n = 0;
    String id() => 'id${n++}';

    test('merges plays per content, day, status and reason', () {
      final q = PopQueue();
      q.record(PopPlay(contentId: 'c1', playedAt: t, seconds: 10), id);
      q.record(PopPlay(contentId: 'c1', playedAt: t.add(const Duration(minutes: 1)), seconds: 5), id);
      q.record(PopPlay(contentId: 'c1', playedAt: t, seconds: 5, reason: 'on_demand'), id);
      expect(q.items.length, 2);
      final first = q.items.first.toReport();
      expect(first['play_count'], 2);
      expect(first['playback_time'], 15);
      expect(first['playback_reason'], 'scheduled');
      expect(first.containsKey('user_touched'), isFalse);
    });

    test('a sealed batch is not merged into again', () {
      final q = PopQueue();
      q.record(PopPlay(contentId: 'c1', playedAt: t, seconds: 1), id);
      q.takeBatch(200);
      q.record(PopPlay(contentId: 'c1', playedAt: t, seconds: 1), id);
      expect(q.items.length, 2);
    });

    test('prunes MQTT-only entries after 24 h and anything after 30 days', () {
      final q = PopQueue();
      q.record(PopPlay(contentId: 'c1', playedAt: t, seconds: 1), id);
      final now = t.millisecondsSinceEpoch;
      q.markMqttSent({q.items.first.clientEventId}, now);
      expect(q.prune(now + PopQueue.mqttOnlyRetentionMs), 1);
    });

    test('unknown reasons become scheduled; touch sources interactivity', () {
      expect(PopReasons.normalize('weird'), 'scheduled');
      expect(PopReasons.normalize('touch_region'), 'interactivity');
      expect(PopReasons.normalize('on_demand'), 'on_demand');
    });
  });

  group('proof of play delivery', () {
    test('backoff 30 s doubling to 15 min', () {
      expect(PopDelivery.backoffMs(1), 30000);
      expect(PopDelivery.backoffMs(2), 60000);
      expect(PopDelivery.backoffMs(20), 15 * 60 * 1000);
    });

    test('classify by status and per-entry results', () {
      expect(PopDelivery.classify(500, null, ['a']).kind, PopOutcomeKind.retry);
      expect(PopDelivery.classify(401, null, ['a']).kind, PopOutcomeKind.unauthorized);
      expect(PopDelivery.classify(400, 'x', ['a']).kind, PopOutcomeKind.drop);
      final o = PopDelivery.classify(
          200,
          jsonEncode({
            'results': [
              {'error': null},
              {'error': 'Content not found'},
              {'error': 'temporary'}
            ]
          }),
          ['a', 'b', 'c']);
      expect(o.done, {'a', 'b'});
      expect(o.retry, {'c'});
    });
  });

  group('data feed bindings', () {
    final feed = {
      'dataFeed': {
        'columns': [
          {'id': 'c1', 'name': 'Name'},
          {'id': 'c2', 'name': 'Kind'}
        ],
        'rows': [
          {'order_index': 2, 'column_values': {'Name': 'B', 'Kind': 'x'}},
          {'order_index': 1, 'column_values': {'Name': 'A', 'Kind': 'y'}},
          {'order_index': 3, 'column_values': {'Name': '{"url":"https://i/c.png"}', 'Kind': 'x'}},
        ]
      }
    };

    test('only bound elements count', () {
      expect(FeedBinding.fromJson({'feedId': 'f'}), isNull);
      expect(FeedBinding.fromJson({'feedId': 'f', 'columnId': 'c1'}), isNotNull);
    });

    test('rows sorted, cycling by step, objects shown as their url', () {
      final b = FeedBinding.fromJson({'feedId': 'f', 'columnId': 'c1', 'step': 1})!;
      expect(FeedRules.valueAt(feed, b, 0), 'A');
      expect(FeedRules.valueAt(feed, b, FeedRules.next(feed, b, 0)), 'B');
      expect(FeedRules.valueAt(feed, b, 2), 'https://i/c.png');
      expect(FeedRules.next(feed, b, 2), 0);
    });

    test('match and fixed row modes', () {
      final m = FeedBinding.fromJson({
        'feedId': 'f', 'columnId': 'c1', 'rowMode': 'match', 'matchColumnId': 'c2', 'matchValue': 'y'
      })!;
      expect(FeedRules.valueAt(feed, m, 5), 'A');
      final fixed = FeedBinding.fromJson({'feedId': 'f', 'columnId': 'c1', 'rowMode': '2'})!;
      expect(FeedRules.valueAt(feed, fixed, 0), 'B');
    });

    test('start row and remembered position', () {
      final reset = FeedBinding.fromJson({'feedId': 'f', 'columnId': 'c1', 'initialRow': 2, 'enableCycleReset': true})!;
      expect(FeedRules.startIndex(reset, 0), 1);
      final keep = FeedBinding.fromJson({'feedId': 'f', 'columnId': 'c1', 'initialRow': 2})!;
      expect(FeedRules.startIndex(keep, 0), 0);
    });
  });

  group('player attributes', () {
    test('restriction operators', () {
      Object? v(String k) => {'temperature': 15, 'condition': 'rain'}[k];
      expect(PlayerAttributes.evaluate('is-between', ['temperature', '10', '20'], v), isTrue);
      expect(PlayerAttributes.evaluate('greater-than', ['temperature', '20'], v), isFalse);
      expect(PlayerAttributes.evaluate('is', ['condition', 'RAIN'], v), isTrue);
      expect(PlayerAttributes.evaluate('is-not', ['missing', 'x'], v), isFalse);
      expect(PlayerAttributes.evaluate('empty', ['missing'], v), isTrue);
      expect(PlayerAttributes.evaluate('not-empty', ['condition'], v), isTrue);
    });

    test('CMS values keep the newer timestamp and honour removed', () {
      final a = PlayerAttributes.instance..values.clear();
      a.applyFromCms({
        'attrs': {
          'promo': {'value': true, 'updated_at': '2026-11-10T10:00:00Z', 'source': 'manual'},
          'Bad Key': {'value': 1, 'updated_at': '2026-11-10T10:00:00Z'},
        }
      });
      expect(a.values.keys, ['promo']);
      a.applyFromCms({
        'attrs': {
          'promo': {'value': false, 'updated_at': '2026-11-09T10:00:00Z'}
        }
      });
      expect(a.values['promo']!.value, true);
      a.applyFromCms({'removed': ['promo']});
      expect(a.values, isEmpty);
    });

    test('plugin values are validated', () {
      final a = PlayerAttributes.instance..values.clear();
      final ok = a.setFromPlugin('i1', {'temperature': 21.5, 'x y': 1, 'obj': {}});
      expect(ok, {'temperature': 21.5});
    });
  });

  group('plugins', () {
    test('plugin list and wrapper', () {
      final list = PluginSpec.listFrom({
        'plugins': [
          {'instance_id': 'a', 'url': 'https://x/p', 'version': '1'},
          {'instance_id': 'a', 'url': 'https://x/p', 'version': '1'},
          {'instance_id': 'b', 'url': 'javascript:bad'},
        ]
      });
      expect(list.length, 1);
      final url = LinuxPlugins.wrapperUrl('https://x/p?v=1&a="b"');
      expect(url.startsWith('data:text/html;base64,'), isTrue);
      final html = utf8.decode(base64Decode(url.split(',').last));
      expect(html.contains('signagex-plugin'), isTrue);
      expect(html.contains('&quot;b&quot;'), isTrue);
    });

    test('title messages', () {
      expect(LinuxPlugins.parseTitle('sxp:3:{"type":"attributes","payload":{"t":1}}'),
          {'type': 'attributes', 'payload': {'t': 1}});
      expect(LinuxPlugins.parseTitle('Weather'), isNull);
    });
  });

  group('proof screenshots', () {
    test('schedule messages', () {
      expect(ScreenshotSchedule.fromMessage({'interval_minutes': 0}), isNull);
      final s = ScreenshotSchedule.fromMessage(
          {'interval_minutes': 10, 'until': '2026-11-12T00:00:00Z', 'campaign_id': 'c'})!;
      expect(s.intervalMinutes, 10);
      expect(s.isOver(DateTime.utc(2026, 11, 11)), isFalse);
      expect(s.isOver(DateTime.utc(2026, 11, 12)), isTrue);
    });
  });
}
