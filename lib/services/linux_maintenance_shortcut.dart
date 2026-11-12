import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Discovery shortcuts only. The independent console authenticates changes
/// with a device-specific PIN; neither shortcut is an administrator credential.
class LinuxMaintenanceShortcut {
  LinuxMaintenanceShortcut(
      {Future<void> Function()? launch, DateTime Function()? clock})
      : _launch = launch ?? _openConsole,
        _clock = clock ?? DateTime.now;

  final Future<void> Function() _launch;
  final DateTime Function() _clock;
  String _digits = '';
  final List<DateTime> _digitTimes = [];
  DateTime? _lastKey;
  bool _opening = false;
  bool _attached = false;

  void attach() {
    if (!Platform.isLinux || _attached) return;
    HardwareKeyboard.instance.addHandler(onKey);
    _attached = true;
  }

  void dispose() {
    if (_attached) HardwareKeyboard.instance.removeHandler(onKey);
    _attached = false;
  }

  bool onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    final shortcut = keyboard.isControlPressed &&
        keyboard.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyM;
    final focus = FocusManager.instance.primaryFocus?.context;
    final editing = focus?.widget is EditableText ||
        focus?.findAncestorWidgetOfExactType<EditableText>() != null;
    return key(event.logicalKey.keyLabel,
        openShortcut: shortcut,
        modified: editing ||
            keyboard.isControlPressed ||
            keyboard.isAltPressed ||
            keyboard.isMetaPressed ||
            keyboard.isShiftPressed);
  }

  bool key(String label, {bool openShortcut = false, bool modified = false}) {
    final now = _clock();
    if (_lastKey == null ||
        now.difference(_lastKey!) > const Duration(seconds: 2)) {
      _digits = '';
      _digitTimes.clear();
    }
    _lastKey = now;
    if (modified || !RegExp(r'^[0-9]$').hasMatch(label)) {
      _digits = '';
      _digitTimes.clear();
    } else {
      _digits = '$_digits$label';
      _digitTimes.add(now);
      if (_digits.length > 4) _digits = _digits.substring(_digits.length - 4);
      if (_digitTimes.length > 4) _digitTimes.removeAt(0);
    }
    if (!openShortcut && _digits != '9700') return false;
    // USB barcode scanners type a whole value in a burst. Do not interrupt a
    // kiosk transaction because a scanned barcode ends in the discovery code.
    if (!openShortcut &&
        now.difference(_digitTimes.first) < const Duration(milliseconds: 150))
      return false;
    _digits = '';
    _digitTimes.clear();
    if (!_opening) {
      _opening = true;
      unawaited(_launch().catchError((Object _) {
        // Missing optional OS component must not interrupt playback.
      }).whenComplete(() => _opening = false));
    }
    return true;
  }

  static Future<void> _openConsole() async {
    const launcher = '/usr/bin/signagex-maintenance';
    if (!File(launcher).existsSync()) return;
    // Wait for launch only, not for the independently running console to close.
    await Process.start(launcher, const [], mode: ProcessStartMode.detached);
  }
}
