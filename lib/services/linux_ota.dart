import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// CMS "Update player" for managed Linux players (protocol linux_ota_v1).
///
/// The CMS sends a server-signed command; the remote-view adapter verifies it
/// against the packaged server key and this device's identity. Only then is the
/// root updater started with `--now`, which still installs nothing but a newer
/// package from its own packaged release channel. Progress goes back to the
/// CMS as a device-signed report in `capabilities.linux_ota`.
class LinuxOta {
  LinuxOta({
    this.stateFile,
    this.statusFile = '/var/lib/signagex-player/update-status.json',
    this.channelFile = '/usr/lib/signagex-player/update-channel.json',
    Future<String?> Function(String package)? installedVersion,
    Future<bool> Function(String a, String op, String b)? compareVersions,
    Future<ProcessResult> Function(List<String> arguments)? runUpdater,
    DateTime Function()? clock,
  })  : _installedVersion = installedVersion ?? _dpkgInstalled,
        _compare = compareVersions ?? _dpkgCompare,
        _runUpdater = runUpdater ?? _pkexecUpdater,
        _clock = clock ?? DateTime.now;

  static final LinuxOta instance = LinuxOta();
  static const protocol = 'linux_ota_v1';
  static const active = {'downloading', 'installing'};

  final String? stateFile;
  final String statusFile;
  final String channelFile;
  final Future<String?> Function(String package) _installedVersion;
  final Future<bool> Function(String a, String op, String b) _compare;
  final Future<ProcessResult> Function(List<String> arguments) _runUpdater;
  final DateTime Function() _clock;

  /// Called whenever the job phase changes, so the player can publish at once.
  void Function()? onChange;
  Future<void> Function(String message, String type)? event;

  Map<String, dynamic>? job;
  Future<void> _lock = Future.value();
  bool _loaded = false;

  /// Run the root updater; the CMS request and the hourly automatic check
  /// share this lock so two transactions never overlap.
  Future<ProcessResult> exclusiveUpdate({bool now = false}) {
    final result = _lock.then((_) =>
        _runUpdater(now ? ['/usr/lib/signagex-player/update-player', '--now'] : ['/usr/lib/signagex-player/update-player']));
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<File> _state() async {
    if (stateFile != null) return File(stateFile!);
    final home = Platform.environment['HOME'] ?? '.';
    return File('$home/.local/share/signagex-player/linux-ota.json');
  }

  Future<void> _save() async {
    final file = await _state();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(job), flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _setPhase(String phase, {String detail = ''}) async {
    if (job == null) return;
    if (job!['phase'] == phase && job!['detail'] == detail) return;
    job!['phase'] = phase;
    job!['detail'] = detail.length > 200 ? detail.substring(0, 200) : detail;
    await _save();
    onChange?.call();
  }

  Future<Map<String, dynamic>> channel() async {
    try {
      final value = jsonDecode(await File(channelFile).readAsString()) as Map;
      return {'platform': value['platform']?.toString() ?? 'linux', 'package': value['package']?.toString() ?? 'signagex-player'};
    } catch (_) {
      return {'platform': 'linux', 'package': 'signagex-player'};
    }
  }

  Future<Map?> _status() async {
    try {
      return jsonDecode(await File(statusFile).readAsString()) as Map;
    } catch (_) {
      return null;
    }
  }

  /// Load a persisted job. A successful update restarts the player in the
  /// middle of the transaction, so an in-flight job is resolved here.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _state();
      if (await file.exists()) job = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
    } catch (_) {
      job = null;
    }
    if (job != null && active.contains(job!['phase'])) await _resolve();
  }

  Future<bool> _reached(String target) async {
    final installed = await _installedVersion((await channel())['package']);
    return installed != null && await _compare(installed, 'ge', target);
  }

  /// Settle an interrupted job from the installed version and updater status.
  Future<void> _resolve({int? exitCode, String stdout = '', String stderr = ''}) async {
    final target = job!['target'] as String;
    if (await _reached(target)) return _setPhase('updated');
    final status = await _status() ?? const {};
    final started = (job!['started'] as num?)?.toDouble() ?? 0;
    final stamp = (status['timestamp'] as num?)?.toDouble() ?? 0;
    final fresh = status.isNotEmpty && stamp >= started;
    if (exitCode == null && fresh && active.contains(status['status']) &&
        _clock().millisecondsSinceEpoch / 1000 - stamp < 15 * 60) {
      return _setPhase(status['status'] as String);
    }
    if (fresh && status['status'] == 'rolled_back') {
      return _setPhase('failed', detail: 'Update rolled back: the new version did not pass its health check');
    }
    final reason = stderr.trim().isNotEmpty
        ? stderr.trim()
        : stdout.trim() == 'deferred'
            ? 'Update deferred'
            : exitCode == null
                ? 'Update did not complete'
                : 'Update did not reach version $target';
    return _setPhase('failed', detail: reason);
  }

  /// Run a verified CMS request. [verified] comes from the remote-view adapter.
  Future<void> run(Map verified, {required bool supported}) async {
    await load();
    final id = verified['job']?.toString() ?? '';
    final target = verified['version']?.toString() ?? '';
    if (id.isEmpty || target.isEmpty || id.length > 64 || target.length > 64) return;
    if (job != null && job!['job'] == id) return; // Delivered twice: already handled.
    if (job != null && active.contains(job!['phase'])) {
      await event?.call('Player update request ignored: another update is running', 'warning');
      return;
    }
    final started = _clock().millisecondsSinceEpoch / 1000;
    job = {'job': id, 'target': target, 'phase': 'downloading', 'detail': '', 'issued': verified['issued'], 'started': started};
    await _save();
    onChange?.call();
    if (!supported) {
      return _setPhase('failed', detail: 'Managed updates are not enabled on this device');
    }
    await event?.call('Player update requested from the CMS: $target', 'info');
    final poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      final status = await _status();
      if (status == null || ((status['timestamp'] as num?)?.toDouble() ?? 0) < started) return;
      if (active.contains(status['status'])) await _setPhase(status['status'] as String);
    });
    try {
      final result = await exclusiveUpdate(now: true).timeout(const Duration(minutes: 30));
      poll.cancel();
      await _resolve(exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString());
    } catch (error) {
      poll.cancel();
      await _setPhase('failed', detail: '$error');
    }
    await event?.call('Player update ${job!['phase']}: $target ${job!['detail']}'.trim(), job!['phase'] == 'updated' ? 'info' : 'error');
  }

  /// The unsigned report; signed by the adapter before it is published.
  Future<Map<String, dynamic>> report(String player, {required bool supported}) async {
    await load();
    final info = await channel();
    return {
      'protocol': protocol,
      'player': player,
      'platform': info['platform'],
      'package': info['package'],
      'version': await _installedVersion(info['package']) ?? '',
      'supported': supported,
      'job': job?['job'],
      'phase': job?['phase'],
      'detail': job?['detail'] ?? '',
    };
  }

  static Future<String?> _dpkgInstalled(String package) async {
    try {
      final result = await Process.run('dpkg-query', ['-W', '-f=\${Version}', package]).timeout(const Duration(seconds: 10));
      final value = result.stdout.toString().trim();
      return result.exitCode == 0 && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _dpkgCompare(String a, String op, String b) async {
    try {
      return (await Process.run('dpkg', ['--compare-versions', a, op, b]).timeout(const Duration(seconds: 10))).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<ProcessResult> _pkexecUpdater(List<String> arguments) => Process.run('pkexec', arguments);
}
