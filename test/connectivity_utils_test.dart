import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/utils/connectivity_utils.dart';

void main() {
  group('canReachHost', () {
    test('returns true against a real listening local server', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final sub = server.listen((socket) => socket.destroy());
      addTearDown(sub.cancel);

      final reachable = await canReachHost(
        InternetAddress.loopbackIPv4.address,
        server.port,
      );
      expect(reachable, isTrue);
    });

    test('returns false when nothing is listening on the port', () async {
      // Bind then immediately close, so the port is very likely free but
      // nothing answers on it.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      final reachable = await canReachHost(
        InternetAddress.loopbackIPv4.address,
        port,
        timeout: const Duration(seconds: 1),
      );
      expect(reachable, isFalse);
    });
  });

  group('hostReachabilityStream', () {
    test('emits only on actual state changes, not every poll', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final sub = server.listen((socket) => socket.destroy());
      addTearDown(sub.cancel);

      final events = <bool>[];
      final streamSub = hostReachabilityStream(
        InternetAddress.loopbackIPv4.address,
        server.port,
        interval: const Duration(milliseconds: 50),
        timeout: const Duration(milliseconds: 500),
      ).listen(events.add);
      addTearDown(streamSub.cancel);

      // Several poll intervals' worth of time, with the server reachable
      // the whole time -- should still only ever see a single "true".
      await Future.delayed(const Duration(milliseconds: 300));
      expect(events, [true]);
    });
  });
}
