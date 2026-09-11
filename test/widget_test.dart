// Smoke test for the app entry widget.
//
// Replaces the stale `flutter create` counter template that shipped here: it
// referenced a MyHomePage with a counter and a "+" button that this app's
// MyHomePage never had, so it could not compile or pass. This version matches
// the real widget. Behavioural coverage of pairing, scheduling, offline
// restore and playback is tracked as follow-up work.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:digital_signage/main.dart';

void main() {
  testWidgets('MyHomePage renders its welcome scaffold', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MyHomePage()));

    expect(find.text('Welcome to the MQTT App!'), findsOneWidget);
  });
}
