import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// Bounded durable event spool. Transport uses the existing player_logs protocol.
class LinuxDiagnostics {
  static final instance = LinuxDiagnostics();
  final Stopwatch clock = Stopwatch()..start();
  int _lastTick = 0;
  Timer? _timer;
  Future<void> _writes = Future.value();
  bool _flushing = false;
  final Map<String, int> _recent = {};
  Future<void> record(String message, String type,
      {String? incident,
      StackTrace? stack,
      int? blockedMilliseconds,
      String? identity}) {
    final completer = Completer<void>();
    _writes = _writes.catchError((_) {}).then((_) async {
      try {
        final now = DateTime.now();
        final key = '$type:$message';
        if (incident == null &&
            now.millisecondsSinceEpoch - (_recent[key] ?? 0) < 60000) {
          completer.complete();
          return;
        }
        _recent[key] = now.millisecondsSinceEpoch;
        if (_recent.length > 100) _recent.remove(_recent.keys.first);
        final prefs = await SharedPreferences.getInstance();
        final queue = prefs.getStringList('linux_event_spool') ?? [];
        queue.add(jsonEncode({
          'action': 'player_logs',
          'log': message.substring(0, message.length.clamp(0, 1000)),
          'type': type,
          'sender': 'Linux',
          'name': 'Linux player',
          'date_time': now.toUtc().toIso8601String(),
          if (incident != null) ...{
            'incident_type': incident,
            'event_id': identity ?? '${now.microsecondsSinceEpoch}-$pid',
            'schema_version': 1,
            'app_version': const String.fromEnvironment('APP_BUILD_ID',
                defaultValue: 'linux-config-dev'),
            'process_id': pid,
            if (stack != null)
              'stack_trace': stack
                  .toString()
                  .substring(0, stack.toString().length.clamp(0, 64000)),
            if (blockedMilliseconds != null)
              'blocked_duration_ms': blockedMilliseconds,
          },
        }));
        await prefs.setStringList('linux_event_spool',
            queue.reversed.take(100).toList().reversed.toList());
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  void start() {
    if (_timer != null) return;
    _lastTick = clock.elapsedMilliseconds;
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      final now = clock.elapsedMilliseconds;
      final delay = now - _lastTick - 15000;
      _lastTick = now;
      if (delay >= 30000)
        unawaited(record('Player event loop was unresponsive', 'error',
                incident: 'suspected_anr', blockedMilliseconds: delay)
            .catchError((_) {}));
      unawaited(_writeHealth().catchError((_) {}));
      if (Platform.environment.containsKey('WATCHDOG_USEC')) {
        unawaited(Process.run('systemd-notify', ['WATCHDOG=1'])
            .then((_) {})
            .catchError((_) {}));
      }
    });
    unawaited(_collectNativeIncidents());
  }

  Future<void> _writeHealth() async {
    final directory = Directory(
        '${Platform.environment['HOME']}/.local/share/signagex-player');
    await directory.create(recursive: true);
    final file = File('${directory.path}/health.json.tmp');
    await file.writeAsString(jsonEncode({
      'pid': pid,
      'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      'build': const String.fromEnvironment('APP_BUILD_ID',
          defaultValue: 'linux-config-dev')
    }));
    await file.rename('${directory.path}/health.json');
  }

  Future<void> _collectNativeIncidents() async {
    try {
      final output = await Process.run('journalctl', [
        '--user-unit=signagex-player.service',
        '--since=24 hours ago',
        '--no-pager',
        '-o',
        'json',
        '-n',
        '5',
        '--grep=Main process exited'
      ]);
      if (output.exitCode != 0) return;
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getStringList('linux_native_incidents') ?? [];
      for (final line in output.stdout
          .toString()
          .split('\n')
          .where((line) => line.startsWith('{'))) {
        final entry = jsonDecode(line) as Map;
        final message = entry['MESSAGE']?.toString() ?? '';
        final key = entry['__CURSOR']?.toString();
        if (key == null ||
            seen.contains(key) ||
            !RegExp(r'code=dumped|status=(9/KILL|11/SEGV|6/ABRT)')
                .hasMatch(message)) continue;
        await record(message, 'error', incident: 'crash', identity: key);
        seen.add(key);
      }
      await prefs.setStringList(
          'linux_native_incidents', seen.reversed.take(50).toList());
    } catch (_) {/* unavailable journals do not prevent startup */}
  }

  Future<void> flush(void Function(String) publish) async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _writes;
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getStringList('linux_event_spool') ?? [];
      for (final message in pending) publish(message);
      // Serialize removal with concurrent writers; never discard newly recorded events.
      _writes = _writes.then((_) async {
        final current = prefs.getStringList('linux_event_spool') ?? [];
        for (final message in pending) current.remove(message);
        await prefs.setStringList('linux_event_spool', current);
      });
      await _writes;
    } finally {
      _flushing = false;
    }
  }
}
