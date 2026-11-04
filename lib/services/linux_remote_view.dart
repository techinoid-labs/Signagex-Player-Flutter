import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// MQTT remains in the player; the unprivileged adapter owns X11 and crypto.
class LinuxRemoteView {
  LinuxRemoteView({this.writeOverride});

  /// Tests replace the adapter's stdin.
  final void Function(Map<String, dynamic> message)? writeOverride;
  Process? _process;
  Timer? _timer;
  String? _code;
  String? _publicKey;
  bool Function()? allowed;
  void Function(String topic, String payload, bool retained)? publish;
  Future<void> Function(String, String)? event;
  DateTime? _lastAttempt;
  final Map<int, (String, Completer<OtaReply>)> _otaPending = {};
  int _otaRequestId = 0;

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
          if (value.containsKey('ota_signed') || value.containsKey('ota_verified') || value.containsKey('network_verified') || value.containsKey('ota_rejected')) {
            handleOtaReply(value);
          } else if (value['ready'] == true) {
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
    if (writeOverride != null) return writeOverride!(value);
    try {
      _process?.stdin.writeln(jsonEncode(value));
    } catch (_) {}
  }

  /// Match an adapter reply to the request with the same id and expected type.
  void handleOtaReply(Map value) {
    final id = value['id'];
    if (id is! int) return;
    final pending = _otaPending[id];
    if (pending == null) return;
    final (expected, completer) = pending;
    if (value.containsKey('ota_rejected')) {
      _otaPending.remove(id);
      completer.complete(OtaReply(null, value['ota_rejected']?.toString() ?? 'rejected'));
    } else if (value[expected] is Map) {
      _otaPending.remove(id);
      completer.complete(OtaReply(Map.from(value[expected] as Map), null));
    }
  }

  Future<OtaReply> _otaRequest(String expected, Map<String, dynamic> message) async {
    if (writeOverride == null && (_process == null || _publicKey == null)) return const OtaReply(null, 'adapter_unavailable');
    final id = ++_otaRequestId;
    final completer = Completer<OtaReply>();
    _otaPending[id] = (expected, completer);
    _write({...message, 'id': id});
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _otaPending.remove(id);
      return const OtaReply(null, 'adapter_timeout');
    }
  }

  /// Device-signed update report for the CMS.
  Future<OtaReply> signOta(String data) => _otaRequest('ota_signed', {'ota_sign': data});

  /// The verified job of a server-signed CMS update command, or why it was refused.
  Future<OtaReply> verifyOta(Map envelope) => _otaRequest('ota_verified', {
        'ota_command': {'data': envelope['data'], 'signature': envelope['signature']}
      });

  /// The verified (and password-decrypted) job of a server-signed CMS Wi-Fi command.
  Future<OtaReply> verifyNetwork(Map envelope) => _otaRequest('network_verified', {
        'network_command': {'data': envelope['data'], 'signature': envelope['signature']}
      });

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

/// An adapter answer: [value] on success, otherwise [reason] (e.g. 'stale').
class OtaReply {
  const OtaReply(this.value, this.reason);
  final Map? value;
  final String? reason;
}

/// Select the running bundle's adapter; never borrow one from another release.
File? resolveRemoteViewAgent(String executable, {String developmentRoot = '.'}) {
  final bundled = File('${File(executable).parent.path}/kiosk/remote_view_agent.py');
  if (bundled.existsSync()) return bundled;
  final development = File('$developmentRoot/linux/packaging/kiosk/remote_view_agent.py');
  return development.existsSync() ? development : null;
}
