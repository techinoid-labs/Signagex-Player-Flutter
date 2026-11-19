import 'package:digital_signage/models/intractivity_model.dart';
import 'package:digital_signage/services/kiosk_campaign.dart';
import 'package:digital_signage/view_models/interactivity_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// What the Windows port adds on top of the shared kiosk contract: the CMS
/// clock without a system zone database, the page's SignageXKiosk channel,
/// and triggers yielding to a kiosk.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('screen clock', () {
    test('fixed offsets the CMS can send', () {
      expect(KioskClock.fixedOffset('UTC+13:00'), const Duration(hours: 13));
      expect(KioskClock.fixedOffset('UTC-05:30'), const Duration(hours: -5, minutes: -30));
      expect(KioskClock.fixedOffset('GMT+5'), const Duration(hours: 5));
      expect(KioskClock.fixedOffset('+0530'), const Duration(hours: 5, minutes: 30));
      expect(KioskClock.fixedOffset('UTC'), Duration.zero);
      expect(KioskClock.fixedOffset('Asia/Karachi'), isNull);
      expect(KioskClock.fixedOffset('UTC+25:00'), isNull);
    });

    test('IANA zones come from the bundled database, daylight saving included', () {
      expect(KioskClock.zoneOffset('Asia/Karachi', DateTime.utc(2026, 1, 1)), const Duration(hours: 5));
      expect(KioskClock.zoneOffset('America/New_York', DateTime.utc(2026, 1, 15)), const Duration(hours: -5));
      expect(KioskClock.zoneOffset('America/New_York', DateTime.utc(2026, 7, 15)), const Duration(hours: -4));
      expect(KioskClock.zoneOffset('Mars/Base', DateTime.utc(2026, 1, 1)), isNull);
    });

    test('a UTC+13:00 screen reads the right wall clock', () {
      final wall = KioskClock.wall(DateTime.utc(2026, 11, 18, 12, 35), 'UTC+13:00');
      expect([wall.day, wall.hour, wall.minute], [19, 1, 35]);
    });
  });

  group('page channel', () {
    test('kiosk-state messages give the page state', () {
      expect(kioskPageStateFromMessage('{"type":"kiosk-state","state":"session"}'), KioskPageState.session);
      expect(kioskPageStateFromMessage({'type': 'kiosk-state', 'state': 'idle'}), KioskPageState.idle);
      expect(kioskPageStateFromMessage('{"type":"other","state":"idle"}'), KioskPageState.none);
      expect(kioskPageStateFromMessage('not json'), KioskPageState.none);
    });
  });

  group('triggers under a kiosk', () {
    Map<String, dynamic> item(String id, {bool onTop = false}) => {
          'id': id,
          'name': id,
          'key_press': ['F9'],
          'on_demand': true,
          'touch_region': true,
          'control': [
            {'any_region': true}
          ],
          'local_api': ['door'],
          'play_on_top': onTop,
          'triggers': [
            {
              'trigger_type': 'play',
              'duration': 30,
              'content': [
                {
                  'name': 'content',
                  'zones': [
                    {
                      'x': 0,
                      'y': 0,
                      'width': 1920,
                      'height': 1080,
                      'mediaItems': [
                        {'mediaType': 'image', 'mediaUrl': 'https://example.com/a.jpg', 'settings': {'duration': 10}}
                      ],
                    }
                  ],
                }
              ],
            }
          ],
        };

    late InteractivityController triggers;
    late List<String> warnings;
    var kiosk = false;

    setUp(() {
      kiosk = false;
      warnings = [];
      triggers = InteractivityController(
        checkRestrictions: (_) => true,
        localizeMedia: (_) async {},
        onChanged: () {},
        log: (_) {},
      )
        ..kioskCovering = (() => kiosk)
        ..warn = warnings.add;
      triggers.setList(InteractivityModel.fromJson({
        'action': 'create_interactivity',
        'data': {
          'interactivity': [item('plain'), item('emergency', onTop: true)]
        },
      }));
    });

    tearDown(() => triggers.dispose());

    test('the model reads play_on_top', () {
      expect(Interactivity.fromJson(item('x', onTop: true)).playOnTop, isTrue);
      expect(Interactivity.fromJson(item('x')).playOnTop, isFalse);
    });

    test('without a kiosk, triggers play as before', () {
      triggers.runById('plain');
      expect(triggers.activeCampaign, isNotNull);
    });

    test('under a kiosk nothing plays; Run now says why, keys and taps stay silent', () {
      kiosk = true;
      triggers.runById('plain');
      triggers.onKey(['F9']);
      triggers.onTap(10, 10, 1920, 1080);
      expect(triggers.activeCampaign, isNull);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('kiosk campaign is showing'));
    });

    test('Run now of a play-on-top trigger still waits (only Local API passes)', () {
      kiosk = true;
      triggers.runById('emergency');
      expect(triggers.activeCampaign, isNull);
    });

    test('a full-screen trigger ends when a kiosk starts', () {
      triggers.runById('plain');
      expect(triggers.activeCampaign, isNotNull);
      kiosk = true;
      triggers.yieldToKiosk();
      expect(triggers.activeCampaign, isNull);
    });
  });
}
