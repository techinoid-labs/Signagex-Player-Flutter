import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Which display stack the Linux player is running on, for remote view.
///
/// X11 (GNOME on Xorg, the Openbox kiosk) keeps the original tools: `scrot`
/// for the picture and `xdotool` for input. Wayland (the cage kiosk in
/// linux/packaging/wayland-kiosk) can't use either: `scrot` sees only
/// XWayland's root window and `xdotool` only reaches X clients. There the
/// picture comes from `grim` (wlr-screencopy, which cage implements) and
/// input from a virtual uinput device (kiosk/wayland_input.py), which the
/// compositor treats like a real absolute mouse and keyboard.
enum LinuxDisplaySession { x11, wayland }

/// Wayland when the process has a Wayland display, regardless of whether the
/// player itself was started as an XWayland client (GDK_BACKEND=x11): the
/// screen is still owned by the compositor, so only compositor-level capture
/// and kernel-level input reach everything on it.
LinuxDisplaySession linuxDisplaySession([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final wayland = (env['WAYLAND_DISPLAY'] ?? '').trim();
  return wayland.isNotEmpty
      ? LinuxDisplaySession.wayland
      : LinuxDisplaySession.x11;
}

/// `grim` arguments for one JPEG frame (quality matches the scrot path).
List<String> grimArguments(String path, {int quality = 60}) =>
    ['-t', 'jpeg', '-q', '${quality.clamp(1, 100)}', path];

/// A screen-pixel point as a 0..1 fraction of the screen. Remote-view clicks
/// arrive in the player's reported resolution (Flutter's physical size, which
/// on a fullscreen kiosk window is the output's pixel size); the virtual
/// pointer is absolute over the whole output, so a fraction lands on the same
/// pixel at any output scale or resolution.
({double x, double y}) normalisedPoint(
    double x, double y, double width, double height) {
  double unit(double value, double size) {
    if (!value.isFinite || !size.isFinite || size <= 0) return 0;
    return (value / size).clamp(0.0, 1.0).toDouble();
  }

  return (x: unit(x, width), y: unit(y, height));
}

String _fraction(double value) => value.toStringAsFixed(6);

/// Arguments for kiosk/wayland_input.py (after the script path).
List<String> waylandTapArguments(({double x, double y}) point) =>
    ['tap', _fraction(point.x), _fraction(point.y)];

List<String> waylandMoveArguments(({double x, double y}) point) =>
    ['move', _fraction(point.x), _fraction(point.y)];

List<String> waylandDragArguments(
        ({double x, double y}) start, ({double x, double y}) end,
        {int holdMs = 150}) =>
    [
      'drag',
      _fraction(start.x),
      _fraction(start.y),
      _fraction(end.x),
      _fraction(end.y),
      '${holdMs.clamp(0, 5000)}'
    ];

/// Text goes on stdin, never argv, so it can't show up in a process list.
const List<String> waylandTypeArguments = ['type'];

List<String> waylandKeyArguments(String combo) => ['key', combo];

/// The running bundle's input helper, else the source tree's (flutter run).
File? resolveWaylandInputHelper(String executable,
    {String developmentRoot = '.'}) {
  final bundled =
      File('${File(executable).parent.path}/kiosk/wayland_input.py');
  if (bundled.existsSync()) return bundled;
  final development =
      File('$developmentRoot/linux/packaging/kiosk/wayland_input.py');
  return development.existsSync() ? development : null;
}

typedef LinuxProcessRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments,
    {String? stdinText});

Future<ProcessResult> _runProcess(String executable, List<String> arguments,
    {String? stdinText}) async {
  if (stdinText == null) {
    return Process.run(executable, arguments)
        .timeout(const Duration(seconds: 10));
  }
  final process = await Process.start(executable, arguments);
  process.stdin.write(stdinText);
  await process.stdin.close();
  final stdout = process.stdout.transform(const SystemEncoding().decoder).join();
  final stderr = process.stderr.transform(const SystemEncoding().decoder).join();
  final code = await process.exitCode.timeout(const Duration(seconds: 10),
      onTimeout: () {
    process.kill();
    return -1;
  });
  return ProcessResult(process.pid, code, await stdout, await stderr);
}

/// Wayland capture and input for remote view. X11 callers keep their own
/// scrot/xdotool code and only consult [session].
class LinuxRemoteBackend {
  LinuxRemoteBackend({
    Map<String, String>? environment,
    LinuxProcessRunner? run,
    String? executable,
    ui.Size Function()? screenSize,
  })  : session = linuxDisplaySession(environment),
        _run = run ?? _runProcess,
        _executable = executable ?? Platform.resolvedExecutable,
        _screenSize = screenSize ?? _flutterScreenSize;

  static final instance = LinuxRemoteBackend();

  final LinuxDisplaySession session;
  final LinuxProcessRunner _run;
  final String _executable;
  final ui.Size Function() _screenSize;
  bool _reportedMissingGrim = false;
  bool _reportedMissingHelper = false;

  bool get isWayland => session == LinuxDisplaySession.wayland;

  static ui.Size _flutterScreenSize() {
    final views = ui.PlatformDispatcher.instance.views;
    return views.isEmpty ? ui.Size.zero : views.first.physicalSize;
  }

  /// The helper is runnable: python3-evdev present and /dev/uinput writable
  /// are checked by the helper itself (`check`), so a missing piece is
  /// reported truthfully instead of offering input that silently fails.
  Future<bool> inputAvailable() async {
    final helper = resolveWaylandInputHelper(_executable);
    if (helper == null) {
      _logOnce(() => _reportedMissingHelper, (v) => _reportedMissingHelper = v,
          'Wayland remote input helper (kiosk/wayland_input.py) is missing from the bundle');
      return false;
    }
    try {
      final result = await _run('python3', [helper.path, 'check']);
      if (result.exitCode != 0) {
        _logOnce(() => _reportedMissingHelper,
            (v) => _reportedMissingHelper = v,
            'Wayland remote input unavailable: ${result.stdout}${result.stderr}'.trim());
      }
      return result.exitCode == 0;
    } catch (e) {
      _logOnce(() => _reportedMissingHelper, (v) => _reportedMissingHelper = v,
          'Wayland remote input unavailable: $e');
      return false;
    }
  }

  void _logOnce(bool Function() done, void Function(bool) mark, String text) {
    if (done()) return;
    mark(true);
    debugPrint('MQTT_LOGS:: $text');
  }

  /// One JPEG of the whole output via grim, or null (caller may fall back).
  Future<Uint8List?> capture(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
      final result = await _run('grim', grimArguments(path));
      if (result.exitCode != 0) {
        debugPrint('MQTT_LOGS:: grim failed (exit ${result.exitCode}): '
            '${result.stderr}');
        return null;
      }
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } on ProcessException catch (e) {
      _logOnce(() => _reportedMissingGrim, (v) => _reportedMissingGrim = v,
          'grim is not installed (sudo apt install grim): ${e.message}');
      return null;
    } catch (e) {
      debugPrint('MQTT_LOGS:: grim exception: $e');
      return null;
    }
  }

  ({double x, double y}) _point(double x, double y) {
    final size = _screenSize();
    return normalisedPoint(x, y, size.width, size.height);
  }

  Future<String> _helper(List<String> arguments, {String? stdinText}) async {
    final helper = resolveWaylandInputHelper(_executable);
    if (helper == null) {
      _logOnce(() => _reportedMissingHelper, (v) => _reportedMissingHelper = v,
          'Wayland remote input helper (kiosk/wayland_input.py) is missing from the bundle');
      return 'Error: Wayland input helper missing';
    }
    try {
      final result = await _run('python3', [helper.path, ...arguments],
          stdinText: stdinText);
      if (result.exitCode != 0) {
        // stderr carries only the helper's own reason, never typed text.
        debugPrint('MQTT_LOGS:: Wayland input ${arguments.first} failed: '
            '${result.stderr}');
        return 'Error: ${result.stderr}'.trim();
      }
      return 'Wayland ${arguments.first} executed';
    } catch (e) {
      debugPrint('MQTT_LOGS:: Wayland input ${arguments.first} exception: $e');
      return 'Error: $e';
    }
  }

  Future<String> click(double x, double y) =>
      _helper(waylandTapArguments(_point(x, y)));

  Future<String> move(double x, double y) =>
      _helper(waylandMoveArguments(_point(x, y)));

  Future<String> drag(double startX, double startY, double endX, double endY) =>
      _helper(waylandDragArguments(_point(startX, startY), _point(endX, endY)));

  Future<String> type(String text) =>
      _helper(waylandTypeArguments, stdinText: text);

  /// Back = Alt+Left, the same key the X11 adapter sends for press_back.
  Future<String> back() => _helper(waylandKeyArguments('alt+Left'));
}
