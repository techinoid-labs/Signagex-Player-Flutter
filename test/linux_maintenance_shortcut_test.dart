import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_maintenance_shortcut.dart';

void main() {
  test('9700 opens once, is not a PIN, and slow/unrelated input resets it',
      () async {
    var now = DateTime(2026, 11, 11);
    var opens = 0;
    final shortcut = LinuxMaintenanceShortcut(
        launch: () async {
          opens++;
        },
        clock: () => now);
    for (final digit in ['9', '7', '0']) {
      expect(shortcut.key(digit), isFalse);
      now = now.add(const Duration(milliseconds: 120));
    }
    expect(shortcut.key('0'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(opens, 1);
    shortcut.key('9');
    now = now.add(const Duration(seconds: 3));
    for (final digit in ['7', '0', '0']) {
      shortcut.key(digit);
    }
    expect(opens, 1);
    shortcut.key('9');
    shortcut.key('A');
    for (final digit in ['7', '0', '0']) {
      shortcut.key(digit);
    }
    expect(opens, 1);
    expect(shortcut.key('M', openShortcut: true, modified: true), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(opens, 2);
  });

  test('scanner-speed numeric input never opens maintenance', () async {
    var opens = 0;
    var now = DateTime(2026, 11, 11);
    final shortcut = LinuxMaintenanceShortcut(
        launch: () async {
          opens++;
        },
        clock: () => now);
    for (final digit in '123456789700'.split('')) {
      now = now.add(const Duration(milliseconds: 5));
      expect(shortcut.key(digit), isFalse);
    }
    expect(opens, 0);
  });

  test('a missing OS launcher never throws into playback', () async {
    final shortcut = LinuxMaintenanceShortcut(launch: () async {
      throw StateError('not installed');
    });
    shortcut.key('M', openShortcut: true);
    await Future<void>.delayed(Duration.zero);
  });

  test('a held launch cannot spawn duplicate consoles', () async {
    final done = Completer<void>();
    var opens = 0;
    final shortcut = LinuxMaintenanceShortcut(launch: () {
      opens++;
      return done.future;
    });
    shortcut.key('M', openShortcut: true);
    shortcut.key('M', openShortcut: true);
    expect(opens, 1);
    done.complete();
    await Future<void>.delayed(Duration.zero);
  });

  testWidgets('typing in a text field does not open the console',
      (tester) async {
    var opens = 0;
    var now = DateTime(2026, 11, 11);
    final shortcut = LinuxMaintenanceShortcut(
        launch: () async {
          opens++;
        },
        clock: () => now);
    final focus = FocusNode();
    final text = TextEditingController();
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: EditableText(
          controller: text,
          focusNode: focus,
          style: const TextStyle(),
          cursorColor: const Color(0xff000000),
          backgroundCursorColor: const Color(0xff000000)),
    ));
    focus.requestFocus();
    await tester.pump();
    shortcut.attach();
    for (final digit in [
      LogicalKeyboardKey.digit9,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit0
    ]) {
      now = now.add(const Duration(milliseconds: 200));
      await tester.sendKeyEvent(digit);
    }
    expect(opens, 0);
    shortcut.dispose();
    await tester.pumpWidget(const SizedBox());
    focus.dispose();
    text.dispose();
  });

  testWidgets('Ctrl+Alt+M reaches the global handler and dispose detaches it',
      (tester) async {
    var opens = 0;
    final shortcut = LinuxMaintenanceShortcut(launch: () async {
      opens++;
    });
    shortcut.attach();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(opens, 1);
    shortcut.dispose();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyM);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(opens, 1);
  });
}
