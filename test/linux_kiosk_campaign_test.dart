import 'dart:convert';
import 'dart:io';

import 'package:digital_signage/services/linux_kiosk_campaign.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> publish({String version = 'v-2', int no = 2, String? playerUrl}) => {
      'action': 'publish_kiosk_campaign',
      'sender': 'signagex_web',
      'data': {
        'campaign_id': 'c-1',
        'name': 'Visitor check-in',
        'version_id': version,
        'version_no': no,
        'published_at': '2026-11-10T06:46:19.000Z',
        'url': 'https://api.example.com/v1/kiosk-runtime/$version?player=ABC123',
        if (playerUrl != null) 'player_url': playerUrl,
      },
    };

String document(String version, {Object? schema = 2}) => jsonEncode({
      'campaign_id': 'c-1',
      'version_id': version,
      'document': {if (schema != null) 'schemaVersion': schema, 'home': 's1', 'screens': []},
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('messages', () {
    test('a publish is parsed, with player_url kept when sent', () {
      final message = KioskMessage.parse(
          jsonEncode(publish(playerUrl: 'https://app.example.com/kiosk-play?runtime=x')))!;
      expect(message.clear, isFalse);
      expect(message.publish!.versionId, 'v-2');
      expect(message.publish!.versionNo, 2);
      expect(message.publish!.playerUrl, 'https://app.example.com/kiosk-play?runtime=x');
    });

    test('without player_url the page URL is derived from the frontend', () {
      final message =
          KioskMessage.parse(jsonEncode(publish()), frontendBase: 'https://app.example.com/')!;
      expect(
          message.publish!.playerUrl,
          'https://app.example.com/kiosk-play?runtime=' +
              Uri.encodeComponent('https://api.example.com/v1/kiosk-runtime/v-2?player=ABC123'));
    });

    test('a player_url on the API host (backend without KIOSK_PLAYER_BASE_URL) is replaced', () {
      final message = KioskMessage.parse(
          jsonEncode(publish(playerUrl: 'https://api.example.com/kiosk-play?runtime=x')),
          frontendBase: 'https://app.example.com/')!;
      expect(message.publish!.playerUrl, startsWith('https://app.example.com/kiosk-play?runtime='));
    });

    test('a clear is recognised', () {
      final message = KioskMessage.parse(
          jsonEncode({'action': 'clear_kiosk_campaign', 'sender': 'signagex_web', 'data': null}))!;
      expect(message.clear, isTrue);
      expect(message.publish, isNull);
    });

    test('unusable messages are ignored', () {
      expect(KioskMessage.parse('not json'), isNull);
      expect(KioskMessage.parse(jsonEncode({'action': 'publish_campaign'})), isNull);
      final noUrl = publish()..['data'] = {...(publish()['data'] as Map), 'url': 'ftp://x'};
      expect(KioskMessage.parse(jsonEncode(noUrl)), isNull);
      final noVersion = publish()..['data'] = {...(publish()['data'] as Map), 'version_id': ''};
      expect(KioskMessage.parse(jsonEncode(noVersion)), isNull);
    });

    test('page states come from the title', () {
      expect(kioskPageStateFromTitle('sxk:session'), KioskPageState.session);
      expect(kioskPageStateFromTitle('sxk:idle'), KioskPageState.idle);
      expect(kioskPageStateFromTitle('Visitor check-in'), KioskPageState.none);
      expect(kioskPageStateFromTitle(null), KioskPageState.none);
    });
  });

  group('document validation', () {
    final payload = KioskMessage.parse(jsonEncode(publish()))!.publish!;
    test('a matching document is accepted', () {
      expect(validateKioskDocument(payload, document('v-2')), isNull);
    });
    test('another version, no schema, not JSON or too big are rejected', () {
      expect(validateKioskDocument(payload, document('v-1')), isNotNull);
      expect(validateKioskDocument(payload, document('v-2', schema: null)), isNotNull);
      expect(validateKioskDocument(payload, '<html>'), isNotNull);
      expect(validateKioskDocument(payload, document('v-2'), maxBytes: 10), isNotNull);
    });
  });

  group('version swap', () {
    final start = DateTime(2026, 11, 11, 10);
    test('applies at once when no customer is using the kiosk', () {
      for (final state in [KioskPageState.idle, KioskPageState.ready, KioskPageState.none, KioskPageState.error]) {
        expect(
            KioskSwapPolicy.decide(state: state, waitingSince: start, now: start),
            KioskSwapDecision.apply);
      }
    });
    test('waits during a session', () {
      expect(
          KioskSwapPolicy.decide(
              state: KioskPageState.session,
              waitingSince: start,
              now: start.add(const Duration(minutes: 14))),
          KioskSwapDecision.wait);
    });
    test('asks the page to end a session that ran 15 minutes, then forces after 60 s', () {
      final late = start.add(KioskSwapPolicy.maxWait);
      expect(
          KioskSwapPolicy.decide(state: KioskPageState.session, waitingSince: start, now: late),
          KioskSwapDecision.requestEnd);
      expect(
          KioskSwapPolicy.decide(
              state: KioskPageState.session,
              waitingSince: start,
              now: late.add(const Duration(seconds: 30)),
              endRequestedAt: late),
          KioskSwapDecision.wait);
      expect(
          KioskSwapPolicy.decide(
              state: KioskPageState.session,
              waitingSince: start,
              now: late.add(KioskSwapPolicy.forceAfter),
              endRequestedAt: late),
          KioskSwapDecision.apply);
    });
  });

  group('cache', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('kiosk-cache-'));
    tearDown(() async => temp.delete(recursive: true));

    KioskPayload payload(String version, int no) =>
        KioskMessage.parse(jsonEncode(publish(version: version, no: no)))!.publish!;

    test('keeps the current and the previous version, and leaves no temp file', () async {
      final cache = KioskCache(temp);
      await cache.save(payload('v-1', 1), document('v-1'));
      await cache.save(payload('v-2', 2), document('v-2'));
      expect((await cache.readCurrent())!.payload.versionId, 'v-2');
      expect((await cache.readPrevious())!.payload.versionId, 'v-1');
      final names = temp.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(names.where((n) => n.endsWith('.part')), isEmpty);
    });

    test('saving the same version again does not overwrite the previous one', () async {
      final cache = KioskCache(temp);
      await cache.save(payload('v-1', 1), document('v-1'));
      await cache.save(payload('v-2', 2), document('v-2'));
      await cache.save(payload('v-2', 2), document('v-2'));
      expect((await cache.readPrevious())!.payload.versionId, 'v-1');
    });

    test('a damaged file reads as nothing, and clear removes both', () async {
      final cache = KioskCache(temp);
      await File('${temp.path}/current.json').writeAsString('{broken');
      expect(await cache.readCurrent(), isNull);
      await cache.save(payload('v-1', 1), document('v-1'));
      await cache.clear();
      expect(await cache.readCurrent(), isNull);
      expect(await cache.readPrevious(), isNull);
    });
  });

  group('clear handling', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('kiosk-clear-'));
    tearDown(() async => temp.delete(recursive: true));

    test('a clear during a session waits; after it ends signage returns', () async {
      final cache = KioskCache(temp);
      final first = KioskMessage.parse(jsonEncode(publish(version: 'v-1', no: 1)))!.publish!;
      await cache.save(first, document('v-1'));
      final service = KioskCampaignService(cache: cache);
      await service.restore();
      expect(service.active!.versionId, 'v-1');

      service.debugSetState(KioskPageState.session);
      await service.handleMessage(
          jsonEncode({'action': 'clear_kiosk_campaign', 'sender': 'signagex_web', 'data': null}));
      expect(service.active, isNotNull, reason: 'never cut a customer off');
      expect(service.debugPendingClear, isTrue);

      service.onPageTitle('sxk:idle');
      expect(service.active, isNull);
      expect(service.showing, isFalse);
      service.dispose();
    });

    test('re-publishing the running version changes nothing', () async {
      final cache = KioskCache(temp);
      final first = KioskMessage.parse(jsonEncode(publish(version: 'v-1', no: 1)))!.publish!;
      await cache.save(first, document('v-1'));
      final service = KioskCampaignService(cache: cache);
      await service.restore();
      await service.handleMessage(jsonEncode(publish(version: 'v-1', no: 1)));
      expect(service.active!.versionId, 'v-1');
      expect(service.debugPending, isNull);
      service.dispose();
    });
  });
}
