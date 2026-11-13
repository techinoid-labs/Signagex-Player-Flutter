import 'package:digital_signage/services/linux_interactivity.dart';
import 'package:flutter_test/flutter_test.dart';

/// While a kiosk campaign covers the screen, triggers wait: taps belong to the
/// kiosk. Only a Local API trigger set to play on top shows (above the kiosk).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> item(String id, {bool onTop = false, bool touch = false}) => {
        'id': id,
        'name': id,
        'local_api': ['door'],
        'key_press': ['F9'],
        'on_demand': true,
        'touch_region': touch,
        'control': touch
            ? [
                {'any_region': true}
              ]
            : [],
        'play_on_top': onTop,
        'triggers': [
          {'trigger_type': 'play', 'content': []}
        ],
      };

  late LinuxInteractivity triggers;
  late List<String> events;
  var kiosk = false;

  setUp(() {
    kiosk = false;
    events = [];
    triggers = LinuxInteractivity()
      ..kioskCovering = (() => kiosk)
      ..event = (message, type) async => events.add(message);
  });

  test('without a kiosk, triggers play as before', () {
    triggers.items = [item('plain')];
    expect(triggers.activate('plain', source: 'on_demand'), isTrue);
    expect(triggers.active, isNotNull);
  });

  test('under a kiosk nothing plays; Run now and Local API say why, taps stay silent', () {
    kiosk = true;
    triggers.items = [item('plain', touch: true)];
    expect(triggers.activate('plain', source: 'on_demand'), isFalse);
    expect(triggers.triggerLocalApi('door'), 0);
    expect(triggers.key('F9'), isFalse);
    expect(triggers.activate('plain', source: 'touch'), isFalse);
    expect(triggers.active, isNull);
    expect(events.where((e) => e.contains('kiosk campaign is showing')), hasLength(2),
        reason: 'only the explicit requests are reported');
    expect(triggers.captureRegions(1080, 1920), isEmpty, reason: 'touch regions must not steal kiosk taps');
  });

  test('a Local API trigger set to play on top still shows over the kiosk', () {
    kiosk = true;
    triggers.items = [item('emergency', onTop: true)];
    expect(triggers.triggerLocalApi('door'), 1);
    expect(triggers.overlay, isTrue);
    // ...but not from other sources.
    triggers.finish();
    expect(triggers.activate('emergency', source: 'on_demand'), isFalse);
  });

  test('a full-screen trigger ends when a kiosk starts; an on-top one stays', () {
    triggers.items = [item('plain'), item('emergency', onTop: true)];
    triggers.activate('plain', source: 'on_demand');
    kiosk = true;
    triggers.yieldToKiosk();
    expect(triggers.active, isNull);

    kiosk = false;
    triggers.activate('emergency', source: 'on_demand');
    kiosk = true;
    triggers.yieldToKiosk();
    expect(triggers.active, isNotNull);
  });
}
