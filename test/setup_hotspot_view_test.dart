import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../lib/services/linux_setup_hotspot.dart';
import '../lib/views/setup_hotspot_view.dart';

// Separate from linux_setup_hotspot_test.dart: the widget binding replaces HttpClient there.
void main() {
  testWidgets('the screen shows both QR codes, the network and the password', (tester) async {
    final screen = LinuxSetupHotspot(runHelper: (_) async => ProcessResult(1, 0, '', ''), hasDefaultRoute: () => true);
    screen.info = SetupHotspotInfo.fromJson({'ssid': 'SignageX-Setup-AB12', 'password': 'k7m2pq9xw4tz', 'address': '10.42.0.1', 'port': 8080, 'expires': 1793840000, 'networks': []});
    screen.detail = "Could not connect to 'Office'.";
    screen.phase = 'failed';
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    await tester.pumpWidget(MaterialApp(home: SetupHotspotView(hotspot: screen)));
    final codes = tester.widgetList<QrImageView>(find.byType(QrImageView)).toList();
    expect(codes, hasLength(2));
    expect(find.textContaining('SignageX-Setup-AB12', findRichText: true), findsOneWidget);
    expect(find.textContaining('k7m2pq9xw4tz', findRichText: true), findsOneWidget);
    expect(find.textContaining('http://10.42.0.1:8080/', findRichText: true), findsOneWidget);
    expect(find.textContaining('Try again from the setup page'), findsOneWidget);
    await tester.binding.setSurfaceSize(null);
  });
}
