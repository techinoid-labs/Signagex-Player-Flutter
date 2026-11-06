import 'package:digital_signage/views/player_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  for (final size in [
    const Size(1024, 600),
    const Size(800, 480),
    const Size(600, 1024),
    const Size(1280, 720),
    const Size(1920, 1080),
    const Size(3840, 2160),
    const Size(1080, 1920),
    const Size(2160, 3840),
    const Size(3440, 1440),
  ]) {
    testWidgets('complete pairing flow fits $size without scrolling',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
        home: PlayerPairingScreen(code: '0607c6'),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(QrImageView), findsOneWidget);
      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.maxScrollExtent, 0);
      for (final finder in [
        find.byKey(const ValueKey('pairing-code')),
        find.text('Waiting for pairing…'),
        find.text('Add a player and enter this code,\nor scan the QR code.'),
      ]) {
        final bounds = tester.getRect(finder);
        expect(bounds.top, greaterThanOrEqualTo(0));
        expect(bounds.bottom, lessThanOrEqualTo(size.height));
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(size.width));
      }
    });
  }

  testWidgets('4K pairing QR and code scale with the display', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<double> qrWidth(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(const MaterialApp(
        home: PlayerPairingScreen(code: '0607c6'),
      ));
      await tester.pumpAndSettle();
      final qr = find.byType(QrImageView);
      return tester.getBottomRight(qr).dx - tester.getTopLeft(qr).dx;
    }

    final hdWidth = await qrWidth(const Size(1280, 720));
    final uhdWidth = await qrWidth(const Size(3840, 2160));
    expect(uhdWidth, closeTo(hdWidth * 3, 0.1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty code shows a loading state rather than a fake QR',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: PlayerPairingScreen(code: ''),
    ));
    expect(find.byType(QrImageView), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connecting to SignageX…'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
      home: PlayerPairingScreen(code: '0607c6'),
    ));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('0607c6'), findsOneWidget);
  });

  testWidgets(
      'small screens with large text remain scrollable without overflow',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: const PlayerPairingScreen(code: '0607c6'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Waiting for pairing…'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
