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
    this.pollEvery = const Duration(seconds: 2),
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
  final Duration pollEvery;
  final Future<String?> Function(String package) _installedVersion;
  final Future<bool> Function(String a, String op, String b) _compare;
  final Future<ProcessResult> Function(List<String> arguments) _runUpdater;
  final DateTime Function() _clock;

  /// Called whenever the job phase changes, so the player can publish at once.
  void Function()? onChange;
  Future<void> Function(String message, String type)? event;

  Map<String, dynamic>? job;
  Future<void> _lock = Future.value();
  Future<void>? _loading;
  Timer? _poll;
  bool _running = false;

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
    final trimmed = detail.length > 200 ? detail.substring(0, 200) : detail;
    if (job!['phase'] == phase && job!['detail'] == trimmed) return;
    job!['phase'] = phase;
    job!['detail'] = trimmed;
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

  /// The updater's status, only if it was written for the current job.
  Future<Map> _freshStatus() async {
    try {
      final status = jsonDecode(await File(statusFile).readAsString()) as Map;
      final started = (job?['started'] as num?)?.toDouble() ?? double.infinity;
      return ((status['timestamp'] as num?)?.toDouble() ?? 0) >= started ? status : const {};
    } catch (_) {
      return const {};
    }
  }

  /// Load a persisted job once; concurrent callers share the same load. A
  /// successful update restarts the player mid-transaction, so an unfinished
  /// job is settled (and watched) here.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final file = await _state();
      if (await file.exists()) job = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
    } catch (_) {
      job = null;
    }
    if (job == null) return;
    if (active.contains(job!['phase']) || job!['phase'] == 'updated') await _resolve();
    if (active.contains(job!['phase'])) _watch();
  }

  Future<bool> _reached(String target) async {
    final installed = await _installedVersion((await channel())['package']);
    return installed != null && await _compare(installed, 'ge', target);
  }

  /// Settle the job from the updater's status. 'updated' is only reported once
  /// the updater says so: it installs first, then health-checks for up to 90 s
  /// and may roll back, so the installed version alone is not proof.
  Future<void> _resolve({int? exitCode, String stdout = '', String stderr = ''}) async {
    final target = job!['target'] as String;
    final status = await _freshStatus();
    final state = status['status'];
    final forTarget = status['version']?.toString() == target;
    // A rollback fails this job, unless it was already settled as updated and
    // that version is still installed (the rollback then belongs to a later run).
    if (state == 'rolled_back' && !(job!['phase'] == 'updated' && await _reached(target))) {
      return _setPhase('failed', detail: 'Update rolled back: the new version did not pass its health check');
    }
    if (state == 'updated' && forTarget) return _setPhase('updated');
    if (state == 'failed' && forTarget) {
      return _setPhase('failed', detail: stderr.trim().isNotEmpty ? stderr.trim() : 'Update download or verification failed');
    }
    final stamp = (status['timestamp'] as num?)?.toDouble() ?? 0;
    if (exitCode == null && active.contains(state) && forTarget &&
        _clock().millisecondsSinceEpoch / 1000 - stamp < 15 * 60) {
      return _setPhase(state as String);
    }
    if (job!['phase'] == 'updated' && await _reached(target)) return; // Settled earlier; still installed.
    // No transaction ran for this job: the player was already at (or past) the target.
    if (status.isEmpty && (exitCode == 0 || exitCode == null) && await _reached(target)) return _setPhase('updated');
    final reason = stderr.trim().isNotEmpty
        ? stderr.trim()
        : stdout.trim() == 'deferred'
            ? 'Update deferred'
            : exitCode == null
                ? 'Update did not complete'
                : 'Update did not reach version $target';
    return _setPhase('failed', detail: reason);
  }

  /// Follow the updater's status until the job reaches a terminal phase.
  void _watch() {
    _poll?.cancel();
    _poll = Timer.periodic(pollEvery, (timer) async {
      if (_running || job == null) return;
      await _resolve();
      if (!active.contains(job!['phase'])) timer.cancel();
    });
  }

  /// Run a verified CMS request. [verified] comes from the remote-view adapter.
  Future<void> run(Map verified, {required bool supported}) async {
    await load();
    final id = verified['job']?.toString() ?? '';
    final target = verified['version']?.toString() ?? '';
    if (id.isEmpty || target.isEmpty || id.length > 64 || target.length > 64) return;
    if (job != null && job!['job'] == id) return; // Delivered twice: already handled.
    if (job != null && active.contains(job!['phase'])) {
      if (!_running) await _resolve(); // A job left over from before a restart may have finished.
      if (active.contains(job!['phase'])) {
        await event?.call('Player update request ignored: another update is running', 'warning');
        return;
      }
    }
    _poll?.cancel();
    final started = _clock().millisecondsSinceEpoch / 1000;
    job = {'job': id, 'target': target, 'phase': 'downloading', 'detail': '', 'issued': verified['issued'], 'started': started};
    await _save();
    onChange?.call();
    if (!supported) {
      return _setPhase('failed', detail: 'Managed updates are not enabled on this device');
    }
    await event?.call('Player update requested from the CMS: $target', 'info');
    _running = true;
    final poll = Timer.periodic(pollEvery, (_) async {
      final status = await _freshStatus();
      if (active.contains(status['status']) && status['version']?.toString() == target) {
        await _setPhase(status['status'] as String);
      }
    });
    try {
      final result = await exclusiveUpdate(now: true).timeout(const Duration(minutes: 30));
      poll.cancel();
      _running = false;
      await _resolve(exitCode: result.exitCode, stdout: result.stdout.toString(), stderr: result.stderr.toString());
    } catch (error) {
      poll.cancel();
      _running = false;
      await _setPhase('failed', detail: '$error');
    }
    await event?.call('Player update ${job!['phase']}: $target ${job!['detail']}'.trim(), job!['phase'] == 'updated' ? 'info' : 'error');
  }

  /// The unsigned report; signed by the adapter before it is published. Every
  /// field is a string or bool so a player without a job still validates.
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
      'job': job?['job']?.toString() ?? '',
      'phase': job?['phase']?.toString() ?? '',
      'detail': job?['detail']?.toString() ?? '',
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
