import 'package:digital_signage/services/linux_configuration.dart';
import 'package:digital_signage/services/linux_interactivity.dart';
import 'package:digital_signage/utils/configuration_policy.dart';
import 'package:digital_signage/widgets/linux_configured_surface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => LinuxConfiguration.debugWaylandOverride = false);
  tearDownAll(() => LinuxConfiguration.debugWaylandOverride = null);

  // Wednesday 12 Nov 2026, 20:00: outside a Mon-Fri 09:00-17:00 schedule.
  final evening = DateTime(2026, 11, 12, 20, 0);
  final weekdays = [
    {'days': '0111110', 'from': '09:00', 'to': '17:00'}
  ];

  group('outside working hours', () {
    late List<List<String>> calls;
    late LinuxConfiguration config;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      calls = [];
      config = LinuxConfiguration(
          clock: () => evening,
          command: (exe, args) async {
            calls.add([exe, ...args]);
            return '';
          });
    });
    tearDown(() => config.close());

    Future<void> schedule(Map<String, dynamic> offHours, [int revision = 1]) =>
        config.apply({
          'configuration_revision': revision,
          'working_schedule': {'type': 'custom', 'schedule': weekdays, 'off_hours': offHours},
        });

    test('a message shows with the next opening time', () async {
      await schedule({'mode': 'message', 'message': 'Closed for the night'});
      expect(config.working, isFalse);
      expect(config.offHoursMode, 'message');
      expect(config.offHoursMessage, 'Closed for the night');
      expect(config.opensAt, DateTime(2026, 11, 13, 9, 0));
      expect(LinuxOffHoursView.opensText(config.opensAt!, evening), 'Opens tomorrow at 09:00');
    });

    test('keep playing never closes; an empty message or missing content is black', () async {
      await schedule({'mode': 'continue'});
      expect(config.working, isTrue);
      await schedule({'mode': 'message', 'message': '  '}, 2);
      expect((config.working, config.offHoursMode), (false, 'black_screen'));
      await schedule({'mode': 'content', 'content': null}, 3);
      expect(config.offHoursMode, 'black_screen');
      await schedule({'mode': 'something-new'}, 4);
      expect(config.offHoursMode, 'black_screen', reason: 'unknown modes are black, never playback');
    });

    test('display off powers the X11 screen down, and back on at opening', () async {
      await schedule({'mode': 'display_off'});
      expect(calls, containsAllInOrder([
        ['xset', '+dpms'],
        ['xset', 'dpms', 'force', 'off'],
      ]));
      calls.clear();
      await config.apply({'configuration_revision': 2, 'working_schedule': {'type': 'always', 'schedule': []}});
      expect(config.working, isTrue);
      expect(calls, containsAllInOrder([
        ['xset', 'dpms', 'force', 'on'],
        ['xset', '-dpms'],
      ]));
    });
  });

  test('next opening: same day later, weekends skipped, none when no window', () {
    final morning = DateTime(2026, 11, 12, 7, 30); // Thursday
    expect(nextConfigurationStart(weekdays, morning), DateTime(2026, 11, 12, 9, 0));
    final friday = DateTime(2026, 11, 13, 18, 0);
    expect(nextConfigurationStart(weekdays, friday), DateTime(2026, 11, 16, 9, 0));
    expect(nextConfigurationStart([], friday), isNull);
    expect(LinuxOffHoursView.opensText(DateTime(2026, 11, 16, 9, 0), friday), 'Opens on Monday at 09:00');
  });

  test('Local API values match like Android: contains, ignoring case, or a regex', () {
    expect(localApiMatches('door-open', 'door-open'), isTrue);
    expect(localApiMatches('brazil-goal', 'Brazil-Goal-2'), isTrue);
    expect(localApiMatches(r'^sensor-\d+$', 'sensor-12'), isTrue);
    expect(localApiMatches('door-open', 'door-close'), isFalse);
    expect(localApiMatches('', 'anything'), isFalse);
    expect(localApiMatches('(', 'x'), isFalse, reason: 'a bad regex is just not a match');
  });

  test('a Local API call fires the matching trigger, and only the first unless it propagates', () {
    final api = LinuxInteractivity();
    Map<String, dynamic> item(String id, {bool propagate = false}) => {
          'id': id,
          'local_api': ['door'],
          'propagate': propagate,
          'triggers': [
            {'trigger_type': 'play', 'content': []}
          ],
        };
    api.items = [item('a'), item('b')];
    expect(api.triggerLocalApi('door-open'), 1);
    api.items = [item('a', propagate: true), item('b')];
    expect(api.triggerLocalApi('door-open'), 2);
    expect(api.triggerLocalApi('window'), 0);
  });
}
