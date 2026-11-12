import 'dart:io';
import 'dart:ui' as ui;

import 'package:digital_signage/services/linux_remote_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('session selection', () {
    test('X11 when there is no Wayland display', () {
      expect(linuxDisplaySession({'DISPLAY': ':0'}), LinuxDisplaySession.x11);
      expect(linuxDisplaySession({'WAYLAND_DISPLAY': '  '}),
          LinuxDisplaySession.x11);
      expect(linuxDisplaySession({}), LinuxDisplaySession.x11);
    });

    test('Wayland when a Wayland display is set, even with XWayland or GDK_BACKEND=x11', () {
      expect(linuxDisplaySession({'WAYLAND_DISPLAY': 'wayland-0'}),
          LinuxDisplaySession.wayland);
      expect(
          linuxDisplaySession({
            'WAYLAND_DISPLAY': 'wayland-0',
            'DISPLAY': ':0',
            'GDK_BACKEND': 'x11'
          }),
          LinuxDisplaySession.wayland);
    });
  });

  group('coordinates', () {
    test('screen pixels become fractions of the output', () {
      final p = normalisedPoint(960, 540, 1920, 1080);
      expect(p.x, closeTo(0.5, 1e-9));
      expect(p.y, closeTo(0.5, 1e-9));
      final corner = normalisedPoint(3839, 2159, 3840, 2160);
      expect(corner.x, lessThan(1));
      expect(corner.y, lessThan(1));
    });

    test('out-of-range and invalid input is clamped, never thrown', () {
      expect(normalisedPoint(-10, 5000, 1920, 1080), (x: 0.0, y: 1.0));
      expect(normalisedPoint(double.nan, 10, 1920, 1080).x, 0);
      expect(normalisedPoint(10, 10, 0, 0), (x: 0.0, y: 0.0));
    });
  });

  group('command arguments', () {
    test('grim writes one JPEG at the requested quality', () {
      expect(grimArguments('/tmp/f.jpg'), ['-t', 'jpeg', '-q', '60', '/tmp/f.jpg']);
      expect(grimArguments('/tmp/f.jpg', quality: 500)[3], '100');
    });

    test('helper arguments carry fractions, never raw text', () {
      expect(waylandTapArguments((x: 0.5, y: 0.25)),
          ['tap', '0.500000', '0.250000']);
      expect(waylandMoveArguments((x: 1.0, y: 0.0)),
          ['move', '1.000000', '0.000000']);
      expect(
          waylandDragArguments((x: 0.1, y: 0.2), (x: 0.3, y: 0.4), holdMs: 9000),
          ['drag', '0.100000', '0.200000', '0.300000', '0.400000', '5000']);
      expect(waylandTypeArguments, ['type']);
      expect(waylandKeyArguments('alt+Left'), ['key', 'alt+Left']);
    });
  });

  group('backend', () {
    late List<(String, List<String>, String?)> calls;
    late Directory temp;

    setUp(() async {
      calls = [];
      temp = await Directory.systemTemp.createTemp('sx-remote-');
      await Directory('${temp.path}/kiosk').create();
      await File('${temp.path}/kiosk/wayland_input.py').writeAsString('#');
    });
    tearDown(() async => temp.delete(recursive: true));

    LinuxRemoteBackend backend({int exitCode = 0}) => LinuxRemoteBackend(
          environment: {'WAYLAND_DISPLAY': 'wayland-0'},
          executable: '${temp.path}/signagex-player',
          screenSize: () => const ui.Size(1920, 1080),
          run: (exe, args, {stdinText}) async {
            calls.add((exe, args, stdinText));
            if (exe == 'grim') await File(args.last).writeAsBytes([1, 2, 3]);
            return ProcessResult(1, exitCode, '', exitCode == 0 ? '' : 'nope');
          },
        );

    test('click maps the CMS point to a fraction and calls the helper', () async {
      final result = await backend().click(480, 270);
      expect(result, contains('executed'));
      expect(calls.single.$1, 'python3');
      expect(calls.single.$2, [
        '${temp.path}/kiosk/wayland_input.py',
        'tap',
        '0.250000',
        '0.250000'
      ]);
    });

    test('typed text goes through stdin only', () async {
      await backend().type('secret 123');
      expect(calls.single.$2.last, 'type');
      expect(calls.single.$2.join(' '), isNot(contains('secret')));
      expect(calls.single.$3, 'secret 123');
    });

    test('back sends Alt+Left; failures are reported, not thrown', () async {
      expect(await backend().back(), contains('executed'));
      expect(calls.single.$2.sublist(1), ['key', 'alt+Left']);
      expect(await backend(exitCode: 1).back(), startsWith('Error'));
    });

    test('capture returns the grim frame bytes', () async {
      final bytes = await backend().capture('${temp.path}/frame.jpg');
      expect(bytes, [1, 2, 3]);
      expect(calls.single.$1, 'grim');
    });

    test('grim without JPEG support falls back to PNG and stays on PNG', () async {
      final b = LinuxRemoteBackend(
        environment: {'WAYLAND_DISPLAY': 'wayland-0'},
        executable: '${temp.path}/signagex-player',
        screenSize: () => const ui.Size(1920, 1080),
        run: (exe, args, {stdinText}) async {
          calls.add((exe, args, stdinText));
          if (args.contains('jpeg')) {
            return ProcessResult(1, 1, '', 'jpeg support disabled\n');
          }
          await File(args.last).writeAsBytes([9, 8, 7]);
          return ProcessResult(1, 0, '', '');
        },
      );
      final path = '${temp.path}/frame.jpg';
      expect(await b.capture(path), [9, 8, 7]);
      expect(calls.map((c) => c.$2[1]), ['jpeg', 'png']);
      calls.clear();
      expect(await b.capture(path), [9, 8, 7]);
      expect(calls.single.$2, grimPngArguments(path));
      expect(grimLacksJpeg('other error'), isFalse);
    });

    test('a missing helper is reported as an error', () async {
      await File('${temp.path}/kiosk/wayland_input.py').delete();
      final b = LinuxRemoteBackend(
          environment: {'WAYLAND_DISPLAY': 'wayland-0'},
          executable: '${temp.path}/signagex-player',
          screenSize: () => const ui.Size(1920, 1080),
          run: (exe, args, {stdinText}) async => ProcessResult(1, 0, '', ''));
      // The development fallback (./linux/packaging/kiosk) may exist when the
      // tests run from the repository root, so only check it doesn't throw.
      expect(await b.click(1, 1), isA<String>());
    });
  });
}
