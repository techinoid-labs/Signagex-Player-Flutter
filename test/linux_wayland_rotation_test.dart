import 'dart:io';

import 'package:digital_signage/services/linux_wayland_rotation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _listing = '''
HDMI-A-1 "Some TV (HDMI-A-1)"
  Enabled: no
eDP-1 "AU Optronics 0x123D (eDP-1)"
  Make: AU Optronics
  Enabled: yes
  Modes:
    1920x1080 px, 60.056000 Hz (preferred, current)
  Transform: normal
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CMS values map to wlr-randr transforms', () {
    expect(waylandTransform('0'), 'normal');
    expect(waylandTransform('landscape'), 'normal');
    expect(waylandTransform('90'), '90');
    expect(waylandTransform('180'), '180');
    expect(waylandTransform(' 270 '), '270');
    expect(waylandTransform('45'), isNull);
    expect(waylandTransform('90; reboot'), isNull);
  });

  test('the enabled output is chosen', () {
    expect(firstWaylandOutput(_listing), 'eDP-1');
    expect(firstWaylandOutput('DP-1 "x"\n  Make: y\n'), 'DP-1');
    expect(firstWaylandOutput(''), isNull);
  });

  group('apply and restore', () {
    late List<List<String>> calls;
    late WaylandRotation rotation;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      calls = [];
      rotation = WaylandRotation(run: (exe, args) async {
        expect(exe, 'wlr-randr');
        calls.add(args);
        return ProcessResult(1, 0, args.isEmpty ? _listing : '', '');
      });
    });

    test('apply turns the enabled output and remembers it', () async {
      expect(await rotation.apply('90'), contains('eDP-1'));
      expect(calls.last, ['--output', 'eDP-1', '--transform', '90']);
      expect((await SharedPreferences.getInstance()).getString('linux_wayland_rotation'), '90');
    });

    test('restore applies the saved rotation without saving again', () async {
      SharedPreferences.setMockInitialValues({'linux_wayland_rotation': '270'});
      await rotation.restore();
      expect(calls.last, ['--output', 'eDP-1', '--transform', '270']);
    });

    test('a bad rotation is refused before anything runs', () async {
      await expectLater(rotation.apply('sideways'), throwsFormatException);
      expect(calls, isEmpty);
    });

    test('a wlr-randr failure is an error, not a silent success', () async {
      final failing = WaylandRotation(
          run: (exe, args) async => ProcessResult(1, args.isEmpty ? 0 : 1, args.isEmpty ? _listing : '', 'not supported'));
      await expectLater(failing.apply('180'), throwsStateError);
    });

    test('missing wlr-randr means unavailable', () async {
      final missing = WaylandRotation(
          run: (exe, args) async => throw const ProcessException('wlr-randr', [], 'not found'));
      expect(await missing.available(), isFalse);
    });
  });
}
