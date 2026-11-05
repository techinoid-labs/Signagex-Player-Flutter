import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../lib/services/linux_setup_hotspot.dart';
import '../lib/views/setup_hotspot_view.dart';

// Separate from linux_setup_hotspot_test.dart: the widget binding replaces HttpClient there.
void main() {
  LinuxSetupHotspot screen() {
    final hotspot = LinuxSetupHotspot(runHelper: (_) async => ProcessResult(1, 0, '', ''), hasDefaultRoute: () => true);
    hotspot.info = SetupHotspotInfo.fromJson({'ssid': 'SignageX-Setup-AB12', 'password': 'k7m2pq9xw4tz', 'address': '10.42.0.1', 'port': 8080, 'expires': 1793840000, 'networks': []});
    hotspot.detail = "Could not connect to 'Office'.";
    hotspot.phase = 'failed';
    return hotspot;
  }

  Future<void> show(WidgetTester tester, LinuxSetupHotspot hotspot) async {
    await tester.binding.setSurfaceSize(const Size(1920, 1080));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: SetupHotspotView(hotspot: hotspot, revealFor: const Duration(seconds: 30))));
  }

  void expectHidden(WidgetTester tester) {
    expect(find.byKey(const ValueKey('setup-hotspot-prompt')), findsOneWidget);
    expect(find.textContaining('Tap the screen or press any key'), findsOneWidget);
    expect(find.textContaining('k7m2pq9xw4tz', findRichText: true), findsNothing);
    expect(find.textContaining('SignageX-Setup-AB12', findRichText: true), findsNothing);
    expect(find.textContaining('10.42.0.1', findRichText: true), findsNothing);
    expect(find.byType(ImageFiltered), findsOneWidget);
  }

  void expectRevealed(WidgetTester tester) {
    expect(find.byKey(const ValueKey('setup-hotspot-prompt')), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    final codes = tester.widgetList<QrImageView>(find.byType(QrImageView)).toList();
    expect(codes, hasLength(2));
    expect(find.textContaining('SignageX-Setup-AB12', findRichText: true), findsOneWidget);
    expect(find.textContaining('k7m2pq9xw4tz', findRichText: true), findsOneWidget);
    expect(find.textContaining('http://10.42.0.1:8080/', findRichText: true), findsOneWidget);
    expect(find.textContaining('Try again from the setup page'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-hotspot-hide-note')), findsOneWidget);
  }

  testWidgets('starts blurred with a prompt and no hotspot secrets on screen', (tester) async {
    await show(tester, screen());
    expectHidden(tester);
  });

  testWidgets('a tap shows both QR codes, the network and the password, then they hide again', (tester) async {
    await show(tester, screen());
    await tester.tapAt(const Offset(960, 540));
    await tester.pump();
    expectRevealed(tester);

    // Input while shown keeps them shown.
    await tester.pump(const Duration(seconds: 20));
    await tester.tapAt(const Offset(100, 100));
    await tester.pump(const Duration(seconds: 20));
    expectRevealed(tester);

    await tester.pump(const Duration(seconds: 11));
    expectHidden(tester);
  });

  testWidgets('any key press shows the details', (tester) async {
    await show(tester, screen());
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expectRevealed(tester);
    await tester.pump(const Duration(seconds: 31));
    expectHidden(tester);
  });
}
