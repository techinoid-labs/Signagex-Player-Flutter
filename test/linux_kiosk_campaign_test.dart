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


  group('schedule messages', () {
    Map<String, dynamic> entry(String campaign, String version,
            {Map<String, dynamic>? schedule, String source = 'player', String published = '2026-11-10T06:00:00.000Z'}) =>
        {
          'campaign_id': campaign,
          'name': 'Kiosk $campaign',
          'version_id': version,
          'version_no': 1,
          'published_at': published,
          'url': 'https://api.example.com/v1/kiosk-runtime/$version?player=ABC123',
          'player_url': 'https://app.example.com/kiosk-play?runtime=x',
          'schedule': schedule,
          'source': source,
        };

    test('a kiosk_schedule lists every campaign with its schedule and zone', () {
      final message = KioskMessage.parse(jsonEncode({
        'action': 'kiosk_schedule',
        'data': {
          'time_zone': 'Asia/Karachi',
          'campaigns': [
            entry('breakfast', 'b-1', schedule: {'startTime': '06:00', 'endTime': '11:00', 'days': [1, 2, 3, 4, 5]}),
            entry('lunch', 'l-1', schedule: {'startTime': '11:00', 'endTime': '15:00'}, source: 'group'),
          ],
        },
      }))!;
      expect(message.clear, isFalse);
      expect(message.publish, isNull);
      expect(message.schedule.timeZone, 'Asia/Karachi');
      expect(message.schedule.entries.map((e) => e.payload.versionId), ['b-1', 'l-1']);
      expect(message.schedule.entries.first.schedule.describe(), 'Mon–Fri 06:00–11:00');
      expect(message.schedule.entries.last.source, 'group');
    });

    test('an empty schedule means no kiosk; a missing schedule means always', () {
      final none = KioskMessage.parse(jsonEncode({'action': 'kiosk_schedule', 'data': {'campaigns': []}}))!;
      expect(none.clear, isTrue);
      final always = KioskMessage.parse(jsonEncode({
        'action': 'kiosk_schedule',
        'data': {'campaigns': [entry('a', 'a-1')]},
      }))!;
      expect(always.schedule.entries.single.schedule.describe(), 'always');
      expect(always.schedule.timeZone, isNull);
    });

    test('a legacy publish is one campaign that always plays; bad entries are skipped', () {
      final legacy = KioskMessage.parse(jsonEncode(publish()))!;
      expect(legacy.schedule.entries.single.schedule.describe(), 'always');
      final mixed = KioskMessage.parse(jsonEncode({
        'action': 'kiosk_schedule',
        'data': {
          'campaigns': [
            {'campaign_id': 'x'}, // no version or url
            entry('a', 'a-1'),
            entry('a', 'a-2'), // the same campaign twice keeps the first
          ],
        },
      }))!;
      expect(mixed.schedule.entries.map((e) => e.payload.versionId), ['a-1']);
    });
  });

  group('schedule rules', () {
    KioskSchedule s(Map<String, dynamic> json) => KioskSchedule.fromJson(json);
    // 2026-11-13 is a Friday, 2026-11-14 a Saturday.
    DateTime at(int day, int hour, [int minute = 0]) => DateTime.utc(2026, 11, day, hour, minute);

    test('always and all-day schedules', () {
      expect(KioskSchedule.always.activeAt(at(13, 3)), isTrue);
      expect(s({'days': [5]}).activeAt(at(13, 0)), isTrue);
      expect(s({'days': [5]}).activeAt(at(14, 0)), isFalse);
      expect(s({'days': [0, 1, 2, 3, 4, 5, 6]}).describe(), 'always');
    });

    test('a daytime window: start included, end excluded', () {
      final w = s({'startTime': '06:00', 'endTime': '11:00'});
      expect(w.activeAt(at(13, 5, 59)), isFalse);
      expect(w.activeAt(at(13, 6)), isTrue);
      expect(w.activeAt(at(13, 10, 59)), isTrue);
      expect(w.activeAt(at(13, 11)), isFalse);
    });

    test('an overnight window belongs to the day it starts', () {
      final fri = s({'startTime': '22:00', 'endTime': '02:00', 'days': [5]});
      expect(fri.activeAt(at(13, 22)), isTrue, reason: 'Fri 22:00');
      expect(fri.activeAt(at(14, 1, 30)), isTrue, reason: 'Sat 01:30 is Friday night');
      expect(fri.activeAt(at(14, 2)), isFalse, reason: 'ends at 02:00');
      expect(fri.activeAt(at(13, 1)), isFalse, reason: 'Fri 01:00 belongs to Thursday night');
      expect(fri.activeAt(at(14, 22)), isFalse, reason: 'not on Saturday');
      expect(fri.overnight, isTrue);
    });

    test('dates are inclusive, also for the overnight part', () {
      final w = s({'startDate': '2026-11-13', 'endDate': '2026-11-13', 'startTime': '22:00', 'endTime': '02:00'});
      expect(w.activeAt(at(12, 23)), isFalse);
      expect(w.activeAt(at(13, 23)), isTrue);
      expect(w.activeAt(at(14, 1)), isTrue, reason: 'the 13th\'s window runs into the 14th');
      expect(w.activeAt(at(14, 23)), isFalse);
      expect(s({'startDate': '2026-11-13'}).describe(), 'every day all day (13 Nov–…)');
    });

    test('bad values are ignored rather than blocking the screen', () {
      final w = s({'startTime': '25:00', 'endTime': '11:00', 'startDate': 'soon', 'days': [9, 'x']});
      expect(w.hasTimes, isFalse);
      expect(w.startDate, isNull);
      expect(w.days, isEmpty);
      expect(w.activeAt(at(13, 3)), isTrue);
    });
  });

  group('resolver', () {
    KioskScheduleEntry e(String id, Map<String, dynamic>? schedule,
        {String source = 'player', String published = '2026-11-10T06:00:00.000Z'}) {
      final payload = KioskPayload.fromJson({
        'campaign_id': id,
        'name': id,
        'version_id': '$id-1',
        'version_no': 1,
        'published_at': published,
        'url': 'https://api.example.com/v1/kiosk-runtime/$id-1?player=A',
      })!;
      return KioskScheduleEntry(payload, KioskSchedule.fromJson(schedule), source: source);
    }

    DateTime at(int day, int hour, [int minute = 0]) => DateTime.utc(2026, 11, day, hour, minute);
    final breakfast = e('breakfast', {'startTime': '06:00', 'endTime': '11:00', 'days': [1, 2, 3, 4, 5]});
    final lunch = e('lunch', {'startTime': '11:00', 'endTime': '15:00'});
    final late = e('late', {'startTime': '22:00', 'endTime': '02:00'});

    test('two campaigns on one screen at different times, signage in between', () {
      final all = [breakfast, lunch, late];
      expect(KioskScheduleResolver.activeAtWall(at(13, 7), all), breakfast);
      expect(KioskScheduleResolver.activeAtWall(at(13, 11), all), lunch);
      expect(KioskScheduleResolver.activeAtWall(at(13, 16), all), isNull);
      expect(KioskScheduleResolver.activeAtWall(at(14, 7), all), isNull, reason: 'breakfast is weekdays only');
      expect(KioskScheduleResolver.activeAtWall(at(14, 1), all), late);
    });

    test('defensive tie-break: own assignment beats a group, then the newest publish', () {
      final group = e('g', null, source: 'group', published: '2026-11-12T00:00:00.000Z');
      final mine = e('m', null, published: '2026-11-01T00:00:00.000Z');
      final newer = e('n', null, published: '2026-11-11T00:00:00.000Z');
      expect(KioskScheduleResolver.activeAtWall(at(13, 9), [group, mine]), mine);
      expect(KioskScheduleResolver.activeAtWall(at(13, 9), [mine, newer]), newer);
    });

    test('the next change is the next window edge that changes what shows', () {
      final all = [breakfast, lunch];
      final now = at(13, 7, 30);
      final next = KioskScheduleResolver.nextChangeWall(now, all)!;
      expect(next, at(13, 11), reason: 'breakfast → lunch');
      expect(KioskScheduleResolver.describeChange(now, next), '11:00');
      expect(KioskScheduleResolver.nextChangeWall(at(13, 16), all), at(14, 11), reason: 'lunch runs every day');
      final evening = KioskScheduleResolver.nextChangeWall(at(13, 16), [breakfast])!;
      expect(evening, at(16, 6), reason: 'nothing at the weekend; Monday breakfast');
      expect(KioskScheduleResolver.describeChange(at(13, 16), evening), 'Mon 06:00');
      expect(KioskScheduleResolver.nextChangeWall(at(13, 9), [e('x', null)]), isNull);
    });

    test('the screen clock follows the zone offset; unknown zones use the device clock', () {
      final saved = KioskClock.offsetOf;
      addTearDown(() => KioskClock.offsetOf = saved);
      KioskClock.offsetOf = (zone, utc) => zone == 'Asia/Karachi' ? const Duration(hours: 5) : null;
      // 02:30 UTC is 07:30 in Karachi: breakfast.
      expect(KioskScheduleResolver.activeAt(at(13, 2, 30), 'Asia/Karachi', [breakfast, lunch]), breakfast);
      final wall = KioskClock.wall(at(13, 2, 30), 'Mars/Base');
      final local = at(13, 2, 30).toLocal();
      expect([wall.hour, wall.minute], [local.hour, local.minute]);
    });
  });

  group('cache', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('kiosk-cache-'));
    tearDown(() async => temp.delete(recursive: true));

    KioskPayload payload(String version, int no) =>
        KioskMessage.parse(jsonEncode(publish(version: version, no: no)))!.publish!;

    test('the schedule and each document survive a restart, with no temp files left', () async {
      final cache = KioskCache(temp);
      await cache.saveDocument(payload('v-1', 1), document('v-1'));
      await cache.saveSchedule(KioskScheduleSet('Asia/Karachi', [
        KioskScheduleEntry(payload('v-1', 1), KioskSchedule.fromJson({'startTime': '06:00', 'endTime': '11:00'})),
      ]));
      final again = KioskCache(temp);
      final schedule = (await again.readSchedule())!;
      expect(schedule.timeZone, 'Asia/Karachi');
      expect(schedule.entries.single.schedule.describe(), 'every day 06:00–11:00');
      expect(await again.hasDocument('v-1'), isTrue);
      expect((await again.readDocument('v-1'))!.payload.versionId, 'v-1');
      final names = temp.listSync(recursive: true).map((e) => e.uri.pathSegments.last).toList();
      expect(names.where((n) => n.endsWith('.part')), isEmpty);
    });

    test('documents of campaigns no longer scheduled are removed', () async {
      final cache = KioskCache(temp);
      await cache.saveDocument(payload('v-1', 1), document('v-1'));
      await cache.saveDocument(payload('v-2', 2), document('v-2'));
      await cache.saveSchedule(KioskScheduleSet(null, [KioskScheduleEntry(payload('v-2', 2), KioskSchedule.always)]));
      await cache.prune({'v-2'});
      expect(await cache.hasDocument('v-1'), isFalse);
      expect(await cache.hasDocument('v-2'), isTrue);
    });

    test('a cache from before schedules reads as one always-on campaign', () async {
      await File('${temp.path}/current.json').writeAsString(
          jsonEncode({'payload': payload('v-1', 1).toJson(), 'document': document('v-1')}));
      final cache = KioskCache(temp);
      final schedule = (await cache.readSchedule())!;
      expect(schedule.entries.single.payload.versionId, 'v-1');
      expect(await cache.hasDocument('v-1'), isTrue);
    });

    test('damaged files read as nothing, and clear removes everything', () async {
      final cache = KioskCache(temp);
      await File('${temp.path}/schedule.json').writeAsString('{broken');
      expect(await cache.readSchedule(), isNull);
      await cache.save(payload('v-1', 1), document('v-1'));
      await cache.clear();
      expect(await cache.readSchedule(), isNull);
      expect(await cache.hasDocument('v-1'), isFalse);
    });

    test('an unsafe version id is never used as a file name', () async {
      final cache = KioskCache(temp);
      final bad = KioskPayload.fromJson({
        'campaign_id': 'c',
        'version_id': '../../etc/passwd',
        'url': 'https://api.example.com/x',
      })!;
      await expectLater(cache.saveDocument(bad, document('x')), throwsArgumentError);
      expect(await cache.hasDocument('../../etc/passwd'), isFalse);
    });
  });

  group('service', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('kiosk-service-'));
    tearDown(() async => temp.delete(recursive: true));

    KioskPayload payload(String version, {String campaign = 'c-1'}) => KioskPayload.fromJson({
          'campaign_id': campaign,
          'name': campaign,
          'version_id': version,
          'version_no': 1,
          'published_at': '2026-11-10T06:00:00.000Z',
          'url': 'https://api.example.com/v1/kiosk-runtime/$version?player=ABC123',
          'player_url': 'https://app.example.com/kiosk-play?runtime=$version',
        })!;

    String schedule(List<(KioskPayload, Map<String, dynamic>?)> items) => jsonEncode({
          'action': 'kiosk_schedule',
          'data': {
            'campaigns': [
              for (final (p, s) in items) {...p.toJson(), 'schedule': s, 'source': 'player'},
            ],
          },
        });

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

    test('a new campaign is shown at once while a broken page has fallen back to signage', () async {
      final cache = KioskCache(temp);
      await cache.save(payload('a-1', campaign: 'a'), document('a-1'));
      await cache.saveDocument(payload('b-1', campaign: 'b'), document('b-1'));
      final service = KioskCampaignService(cache: cache);
      await service.restore();
      expect(service.active!.versionId, 'a-1');
      // The first campaign's page fails three times: signage for 2 minutes.
      for (var i = 0; i < 3; i++) {
        service.onPageLoadFailed('code 404 at https://api.example.com/kiosk-play');
      }
      expect(service.showing, isFalse);

      await service.handleMessage(schedule([(payload('b-1', campaign: 'b'), null)]));
      service.debugTick();
      expect(service.active!.versionId, 'b-1', reason: 'not stuck behind the broken page');
      expect(service.showing, isTrue);
      expect(service.debugPending, isNull);
      service.dispose();
    });

    test('at the end of a window it waits for the session, then returns to signage', () async {
      final cache = KioskCache(temp);
      final breakfast = payload('b-1', campaign: 'breakfast');
      await cache.saveDocument(breakfast, document('b-1'));
      // Friday 10:58 on the device clock (no zone in the message).
      var now = DateTime(2026, 11, 13, 10, 58);
      final service = KioskCampaignService(cache: cache, clock: () => now);
      await service.handleMessage(schedule([(breakfast, {'startTime': '06:00', 'endTime': '11:00'})]));
      expect(service.active!.versionId, 'b-1');

      service.debugSetState(KioskPageState.session);
      now = DateTime(2026, 11, 13, 11, 1);
      service.debugTick();
      expect(service.active, isNotNull, reason: 'a customer is still using it');
      expect(service.debugPendingClear, isTrue);

      service.onPageTitle('sxk:idle');
      expect(service.active, isNull);
      expect(service.showing, isFalse);
      expect(await cache.hasDocument('b-1'), isTrue, reason: 'still scheduled tomorrow');
      service.dispose();
    });

    test('two campaigns on one screen switch at the window edge, between sessions', () async {
      final cache = KioskCache(temp);
      final breakfast = payload('b-1', campaign: 'breakfast');
      final lunch = payload('l-1', campaign: 'lunch');
      await cache.saveDocument(breakfast, document('b-1'));
      await cache.saveDocument(lunch, document('l-1'));
      var now = DateTime(2026, 11, 13, 10, 59);
      final service = KioskCampaignService(cache: cache, clock: () => now);
      await service.handleMessage(schedule([
        (breakfast, {'startTime': '06:00', 'endTime': '11:00'}),
        (lunch, {'startTime': '11:00', 'endTime': '15:00'}),
      ]));
      expect(service.active!.versionId, 'b-1');
      service.debugSetState(KioskPageState.idle);
      now = DateTime(2026, 11, 13, 11, 0);
      service.debugTick();
      expect(service.active!.versionId, 'l-1');
      now = DateTime(2026, 11, 13, 16, 0);
      service.debugSetState(KioskPageState.idle);
      service.debugTick();
      expect(service.active, isNull, reason: 'nothing scheduled after lunch');
      service.dispose();
    });

    test('removing a campaign from the schedule deletes its cached document', () async {
      final cache = KioskCache(temp);
      final a = payload('a-1', campaign: 'a');
      final b = payload('b-1', campaign: 'b');
      await cache.saveDocument(a, document('a-1'));
      await cache.saveDocument(b, document('b-1'));
      final service = KioskCampaignService(cache: cache);
      await service.handleMessage(schedule([(a, null), (b, {'days': <int>[]})]));
      await service.handleMessage(schedule([(a, null)]));
      expect(await cache.hasDocument('a-1'), isTrue);
      expect(await cache.hasDocument('b-1'), isFalse);
      service.dispose();
    });
  });

  group('on-screen approval', () {
    late Directory temp;
    setUp(() async => temp = await Directory.systemTemp.createTemp('kiosk-approval-'));
    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    final later = DateTime.now().toUtc().add(const Duration(hours: 23, minutes: 30));
    Map<String, dynamic> approval(String id, {DateTime? expires, String name = 'Lunch kiosk'}) => {
          'request_id': id,
          'campaign_id': 'c-lunch',
          'name': name,
          'version_id': 'l-1',
          'version_no': 1,
          'schedule': {'startTime': '11:00', 'endTime': '15:00', 'days': [1, 2, 3, 4, 5]},
          'replaces': [
            {'campaign_id': 'c-1', 'name': 'Breakfast kiosk', 'schedule': null},
          ],
          'expires_at': (expires ?? later).toIso8601String(),
          'url': 'https://api.example.com/v1/kiosk-runtime/l-1?player=ABC123',
          'player_url': 'https://app.example.com/kiosk-play?runtime=l-1',
        };

    String message({List<Map<String, dynamic>> campaigns = const [], List<Object?> approvals = const []}) =>
        jsonEncode({
          'action': 'kiosk_schedule',
          'data': {'campaigns': campaigns, 'approvals': approvals},
        });

    test('approvals are read from the schedule; bad ids are skipped, duplicates kept once', () {
      final parsed = KioskMessage.parse(message(approvals: [
        approval('req-1'),
        approval('req-1', name: 'Duplicate'),
        {'request_id': '../etc', 'name': 'Unsafe id'},
        {'name': 'No id'},
        'not an object',
      ]))!;
      final list = parsed.schedule.approvals;
      expect(list.map((a) => a.requestId), ['req-1']);
      final a = list.single;
      expect(a.name, 'Lunch kiosk');
      expect(a.schedule.describe(), isNot('Always'));
      expect(a.replaces.single.name, 'Breakfast kiosk');
      expect(a.replaces.single.schedule.describe(), 'Always');
      expect(parsed.schedule.entries, isEmpty, reason: 'a waiting campaign is not scheduled');
      expect(a.expiresIn(DateTime.now()), 'Expires in 23 h');
    });

    test('expired requests are not pending', () async {
      final service = KioskCampaignService(cache: KioskCache(temp));
      await service.handleMessage(message(approvals: [
        approval('old', expires: DateTime.now().toUtc().subtract(const Duration(minutes: 1))),
        approval('new'),
      ]));
      expect(service.pendingApprovals.map((a) => a.requestId), ['new']);
      expect(service.approvalPrompt.value!.requestId, 'new');
      service.dispose();
    });

    test('a waiting request survives a restart', () async {
      final cache = KioskCache(temp);
      final first = KioskCampaignService(cache: cache);
      await first.handleMessage(message(approvals: [approval('req-1')]));
      first.dispose();

      final restarted = KioskCampaignService(cache: cache);
      await restarted.restore();
      expect(restarted.approvalPrompt.value?.requestId, 'req-1');
      restarted.dispose();
    });

    test('the prompt waits for a customer session to end, then shows', () async {
      final cache = KioskCache(temp);
      final running = KioskMessage.parse(jsonEncode(publish(version: 'v-1', no: 1)))!.publish!;
      await cache.save(running, document('v-1'));
      final service = KioskCampaignService(cache: cache);
      await service.restore();
      expect(service.showing, isTrue);

      service.debugSetState(KioskPageState.session);
      await service.handleMessage(message(
        campaigns: [
          {...running.toJson(), 'schedule': null, 'source': 'player'},
        ],
        approvals: [approval('req-1')],
      ));
      expect(service.approvalPrompt.value, isNull, reason: 'never in front of a customer');

      service.onPageTitle('sxk:idle');
      expect(service.approvalPrompt.value?.requestId, 'req-1');
      service.dispose();
    });

    test('prompt gating rule', () {
      expect(KioskCampaignService.promptAllowed(kioskShowing: true, state: KioskPageState.session), isFalse);
      expect(KioskCampaignService.promptAllowed(kioskShowing: true, state: KioskPageState.idle), isTrue);
      expect(KioskCampaignService.promptAllowed(kioskShowing: true, state: KioskPageState.ready), isTrue);
      // Fallen back to signage: nobody can be mid-purchase.
      expect(KioskCampaignService.promptAllowed(kioskShowing: false, state: KioskPageState.session), isTrue);
    });

    test('the decision request and how each answer is handled', () {
      expect(
        KioskCampaignService.approvalDecisionUri('https://signagexai.com/v1/', 'req-1', 'AB 12').toString(),
        'https://signagexai.com/v1/kiosk-runtime/approvals/req-1?player=AB+12',
      );
      expect(jsonDecode(KioskCampaignService.approvalDecisionBody(approve: true)), {'decision': 'approve'});
      expect(jsonDecode(KioskCampaignService.approvalDecisionBody(approve: false)), {'decision': 'decline'});
      expect(KioskCampaignService.approvalOutcome(200), KioskApprovalSend.sent);
      expect(KioskCampaignService.approvalOutcome(204), KioskApprovalSend.sent);
      expect(KioskCampaignService.approvalOutcome(409), KioskApprovalSend.gone);
      expect(KioskCampaignService.approvalOutcome(404), KioskApprovalSend.gone);
      expect(KioskCampaignService.approvalOutcome(500), KioskApprovalSend.failed);
      expect(KioskCampaignService.approvalOutcome(null), KioskApprovalSend.failed);
    });

    test('an unpaired screen does not send, and the prompt stays', () async {
      final service = KioskCampaignService(cache: KioskCache(temp));
      await service.handleMessage(message(approvals: [approval('req-1')]));
      final shown = service.approvalPrompt.value!;
      expect(await service.decideApproval(shown, approve: true), KioskApprovalSend.failed);
      expect(service.approvalPrompt.value?.requestId, 'req-1');
      service.dispose();
    });

    test('a request the backend has dropped disappears from the screen', () async {
      final service = KioskCampaignService(cache: KioskCache(temp));
      await service.handleMessage(message(approvals: [approval('req-1')]));
      expect(service.approvalPrompt.value, isNotNull);
      // Approved from the CMS (or expired there): the next schedule no longer lists it.
      await service.handleMessage(message());
      expect(service.approvalPrompt.value, isNull);
      service.dispose();
    });
  });
}
