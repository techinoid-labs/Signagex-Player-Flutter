import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// MQTT remains in the player; the unprivileged adapter owns X11 and crypto.
class LinuxRemoteView {
  Process? _process;
  Timer? _timer;
  String? _code;
  String? _publicKey;
  bool Function()? allowed;
  void Function(String topic, String payload, bool retained)? publish;
  Future<void> Function(String, String)? event;
  DateTime? _lastAttempt;

  Future<void> start(String code) async {
    if (_process != null && code == _code) {
      announce();
      return;
    }
    if (_lastAttempt != null &&
        DateTime.now().difference(_lastAttempt!).inSeconds < 30) return;
    close();
    _lastAttempt = DateTime.now();
    final script = resolveRemoteViewAgent(Platform.resolvedExecutable);
    if (script == null) {
      await event?.call('Secure remote-view adapter missing from running bundle', 'warning');
      return;
    }
    try {
      _code = code;
      final process = await Process.start('python3', [script.path, code]);
      _process = process;
      process.stderr
          .drain<void>(); // Never forward command data or private keys.
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.length > 3 * 1024 * 1024 || _process != process) return;
        try {
          final value = jsonDecode(line) as Map;
          if (value['ready'] == true) {
            _publicKey = value['device_key'] as String;
            _enabled();
            announce();
          } else if (allowed?.call() == true && value['payload'] is Map) {
            final suffix = value['topic'] == 'frame'
                ? 'remote'
                : value['topic'] == 'events'
                    ? 'remote/v2/events'
                    : null;
            if (suffix != null)
              publish?.call(
                  '$code/$suffix', jsonEncode(value['payload']), false);
          }
        } catch (_) {}
      }, onError: (_) {});
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _enabled());
      unawaited(process.exitCode.then((_) async {
        if (_process != process) return;
        _process = null;
        _publicKey = null;
        _timer?.cancel();
        await event?.call(
            'Secure remote-view adapter stopped; reconnect will retry',
            'warning');
      }));
    } catch (_) {
      await event?.call('Secure remote-view adapter unavailable', 'warning');
    }
  }

  void _write(Map<String, dynamic> value) {
    try {
      _process?.stdin.writeln(jsonEncode(value));
    } catch (_) {}
  }

  void _enabled() => _write({'enabled': allowed?.call() == true});
  void receive(String topic, String payload, bool retained) {
    if (topic != '$_code/remote/v2/command' ||
        payload.length > 20000 ||
        retained ||
        allowed?.call() != true) return;
    try {
      _enabled();
      _write({'envelope': jsonDecode(payload), 'retained': retained});
    } catch (_) {}
  }

  void announce() {
    if (_code != null && _publicKey != null && allowed?.call() == true) {
      publish?.call(
          '$_code/remote/v2/hello',
          jsonEncode({
            'action': 'remote_hello',
            'sender': 'linux',
            'protocol': 2,
            'device_key': _publicKey
          }),
          true);
    }
  }

  void close() {
    _timer?.cancel();
    _process?.kill();
    _process = null;
    _publicKey = null;
  }
}

/// Select the running bundle's adapter; never borrow one from another release.
File? resolveRemoteViewAgent(String executable, {String developmentRoot = '.'}) {
  final bundled = File('${File(executable).parent.path}/kiosk/remote_view_agent.py');
  if (bundled.existsSync()) return bundled;
  final development = File('$developmentRoot/linux/packaging/kiosk/remote_view_agent.py');
  return development.existsSync() ? development : null;
}
