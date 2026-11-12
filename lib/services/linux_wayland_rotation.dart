import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_log.dart' as debug;

/// Screen rotation on the Wayland (cage) kiosk, through wlr-randr.
///
/// xrandr only drives X11 outputs; cage implements wlr-output-management, so
/// wlr-randr turns the whole output there. The compositor then lays the
/// player out for the new size, remote-view capture (grim) comes out turned
/// the same way, and the virtual pointer's fractions follow the output, so
/// remote clicks still land where they appear.
///
/// A compositor forgets the transform when it restarts, so the last rotation
/// is saved and applied again when the player starts (or ROTATE from
/// /etc/signagex-kiosk.conf, passed by the session as SIGNAGEX_ROTATE, when
/// the CMS never set one).
class WaylandRotation {
  WaylandRotation({
    Future<ProcessResult> Function(String, List<String>)? run,
    Future<SharedPreferences> Function()? prefs,
  })  : _run = run ?? Process.run,
        _prefs = prefs ?? SharedPreferences.getInstance;

  static final instance = WaylandRotation();
  static const _key = 'linux_wayland_rotation';

  final Future<ProcessResult> Function(String, List<String>) _run;
  final Future<SharedPreferences> Function() _prefs;

  /// wlr-randr is installed.
  Future<bool> available() async {
    try {
      final result = await _run('wlr-randr', ['--help']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Turns the output to a CMS rotation (0/90/180/270, clockwise like the
  /// X11 player; "landscape" = 0) and remembers it. Returns what happened.
  Future<String> apply(String rotation, {bool remember = true}) async {
    final transform = waylandTransform(rotation);
    if (transform == null) throw const FormatException('Rotation must be 0, 90, 180 or 270');
    final output = await _output();
    final result = await _run('wlr-randr', ['--output', output, '--transform', transform]);
    if (result.exitCode != 0) {
      throw StateError('wlr-randr: ${'${result.stderr}'.trim()}');
    }
    if (remember) {
      try {
        (await _prefs()).setString(_key, normaliseRotation(rotation)!);
      } catch (_) {}
    }
    return 'Screen rotated to ${normaliseRotation(rotation)} on $output';
  }

  /// At start: the saved CMS rotation, else ROTATE from the kiosk settings.
  Future<void> restore() async {
    String? rotation;
    try {
      rotation = (await _prefs()).getString(_key);
    } catch (_) {}
    rotation ??= Platform.environment['SIGNAGEX_ROTATE'];
    if (rotation == null || normaliseRotation(rotation) == null) return;
    try {
      await apply(rotation, remember: false);
    } catch (error) {
      await debug.debugLog('Rotation', 'could not restore $rotation: $error');
    }
  }

  /// The first enabled output wlr-randr lists (a kiosk has one screen).
  Future<String> _output() async {
    final result = await _run('wlr-randr', []);
    if (result.exitCode != 0) throw StateError('wlr-randr: ${'${result.stderr}'.trim()}');
    final name = firstWaylandOutput('${result.stdout}');
    if (name == null) throw StateError('No display found by wlr-randr');
    return name;
  }
}

/// "0", "90", "180", "270" from what the CMS sends; null if unusable.
String? normaliseRotation(String rotation) {
  final r = rotation.trim().toLowerCase();
  if (r == 'landscape' || r == 'normal') return '0';
  return const {'0', '90', '180', '270'}.contains(r) ? r : null;
}

/// wlr-randr --transform value for a clockwise CMS rotation.
String? waylandTransform(String rotation) => switch (normaliseRotation(rotation)) {
      '0' => 'normal',
      '90' => '90',
      '180' => '180',
      '270' => '270',
      _ => null,
    };

/// The first output in `wlr-randr` output whose block says "Enabled: yes"
/// (or the first output when none says).
String? firstWaylandOutput(String listing) {
  String? first;
  String? current;
  for (final line in listing.split('\n')) {
    if (line.isEmpty) continue;
    if (!line.startsWith(' ')) {
      current = line.split(' ').first.trim();
      first ??= current;
    } else if (current != null && line.trim() == 'Enabled: yes') {
      return current;
    }
  }
  return first;
}
