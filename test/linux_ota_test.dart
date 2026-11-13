import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_ota.dart';

int _compare(String a, String b) => int.parse(a).compareTo(int.parse(b));

void main() {
  late Directory root;
  late String installed;
  late List<List<String>> runs;
  late ProcessResult Function() result;
  late DateTime now;

  LinuxOta ota() => LinuxOta(
        stateFile: '${root.path}/linux-ota.json',
        statusFile: '${root.path}/update-status.json',
        channelFile: '${root.path}/update-channel.json',
        pollEvery: const Duration(milliseconds: 10),
        installedVersion: (_) async => installed,
        compareVersions: (a, op, b) async => op == 'eq' ? _compare(a, b) == 0 : op == 'ge' ? _compare(a, b) >= 0 : _compare(a, b) > 0,
        runUpdater: (arguments) async {
          runs.add(arguments);
          return result();
        },
        clock: () => now,
      );

  // Seconds, like update-player; the job under test starts at 1000000.
  void status(String value, {String version = '51', double timestamp = 1000005}) =>
      File('${root.path}/update-status.json').writeAsStringSync(jsonEncode({'status': value, 'version': version, 'timestamp': timestamp}));
  void persisted(String phase) => File('${root.path}/linux-ota.json').writeAsStringSync(
      jsonEncode({'sha256': 'a' * 64, 'job': 'job-1', 'target': '51', 'phase': phase, 'detail': '', 'started': 1000000.0}));

  setUp(() {
    root = Directory.systemTemp.createTempSync('signagex-ota ');
    File('${root.path}/update-channel.json')
        .writeAsStringSync(jsonEncode({'platform': 'linux', 'package': 'signagex-player'}));
    installed = '50';
    runs = [];
    now = DateTime.fromMillisecondsSinceEpoch(1000000000);
    result = () => ProcessResult(1, 0, 'updated', '');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('a player without any job reports strings so the CMS can list it', () async {
    final report = await ota().report('0607c6', supported: true);
    expect(report['job'], '');
    expect(report['phase'], '');
    expect(report['detail'], '');
    expect(report['version'], '50');
    expect(report['protocol'], 'linux_ota_v1');
  });

  test('a verified CMS request runs the updater now; updated only once the updater says so', () async {
    final updater = ota();
    final phases = <String?>[];
    updater.onChange = () => phases.add(updater.job?['phase'] as String?);
    result = () {
      installed = '51';
      status('updated');
      return ProcessResult(1, 0, 'updated', '');
    };
    await updater.run({'sha256': 'a' * 64, 'job': 'job-1', 'version': '51', 'issued': 5}, supported: true);
    expect(runs, [
      ['/usr/lib/signagex-player/update-player', '--now', '51', 'a' * 64]
    ]);
    expect(phases, ['downloading', 'updated']);
    final report = await updater.report('0607c6', supported: true);
    expect(report['job'], 'job-1');
    expect(report['phase'], 'updated');
    expect(report['version'], '51');
  });

  test('installed at the target but rolled back by the health check is a failure', () async {
    final updater = ota();
    result = () {
      installed = '51'; // the new package was installed...
      status('rolled_back', version: '50'); // ...then failed its health check
      return ProcessResult(1, 1, '', 'Updated player did not pass its event-loop health check');
    };
    await updater.run({'sha256': 'a' * 64, 'job': 'job-1', 'version': '51'}, supported: true);
    expect(updater.job?['phase'], 'failed');

    persisted('updated');
    installed = '50';
    status('rolled_back', version: '50');
    final reloaded = ota();
    await reloaded.load();
    expect(reloaded.job?['phase'], 'failed');
  });

  test('an already current player settles as updated without a transaction', () async {
    final updater = ota();
    installed = '51';
    result = () => ProcessResult(1, 0, 'up-to-date', '');
    await updater.run({'sha256': 'a' * 64, 'job': 'job-1', 'version': '51'}, supported: true);
    expect(updater.job?['phase'], 'updated');
  });

  test('a different installed version cannot satisfy an approved request', () async {
    final updater = ota();
    installed = '52';
    result = () => ProcessResult(1, 0, 'up-to-date', '');
    await updater.run({'sha256': 'a' * 64, 'job': 'job-1', 'version': '51'}, supported: true);
    expect(updater.job?['phase'], 'failed');
  });

  test('a rollback reports its actual installation stage after a restart', () async {
    persisted('installing');
    File('${root.path}/update-status.json').writeAsStringSync(jsonEncode({
      'status': 'rolled_back', 'version': '50', 'timestamp': 1000005,
      'stage': 'package_install', 'reason': 'Update failed during package install; previous package restored',
    }));
    final updater = ota();
    await updater.load();
    expect(updater.job?['detail'], 'Update failed during package install; previous package restored');
  });

  test('failures, unsupported devices and repeated deliveries are reported once', () async {
    final updater = ota();
    result = () {
      status('failed');
      return ProcessResult(1, 1, '', 'Update checksum mismatch');
    };
    await updater.run({'sha256': 'a' * 64, 'job': 'job-1', 'version': '51'}, supported: true);
    expect(updater.job?['phase'], 'failed');
    expect(updater.job?['detail'], 'Update checksum mismatch');
    await updater.run({'sha256': 'a' * 64, 'job': 'job-1', 'version': '51'}, supported: true);
    expect(runs.length, 1); // the same job delivered twice never runs twice

    await updater.run({'sha256': 'a' * 64, 'job': 'job-2', 'version': '51'}, supported: false);
    expect(runs.length, 1);
    expect(updater.job?['phase'], 'failed');
    expect(updater.job?['detail'], 'Managed updates are not enabled on this device');
  });

  test('after the update restarts the player, the job keeps being followed to the end', () async {
    persisted('installing');
    installed = '51';
    status('installing');
    final restarted = ota();
    await restarted.load();
    expect(restarted.job?['phase'], 'installing'); // installed, health check still running
    status('updated', timestamp: 1000090);
    for (var i = 0; i < 300 && restarted.job?['phase'] != 'updated'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await restarted.settled(); // its last save must finish before tearDown deletes the folder
    expect(restarted.job?['phase'], 'updated');
  });

  test('a finished job left over from a restart does not block a new request', () async {
    persisted('installing');
    status('installing');
    final updater = LinuxOta(
      stateFile: '${root.path}/linux-ota.json',
      statusFile: '${root.path}/update-status.json',
      channelFile: '${root.path}/update-channel.json',
      pollEvery: const Duration(hours: 1), // the watcher has not looked again yet
      installedVersion: (_) async => installed,
      compareVersions: (a, op, b) async => op == 'eq' ? _compare(a, b) == 0 : op == 'ge' ? _compare(a, b) >= 0 : _compare(a, b) > 0,
      runUpdater: (arguments) async {
        runs.add(arguments);
        return result();
      },
      clock: () => now,
    );
    await updater.load();
    expect(updater.job?['phase'], 'installing');
    status('rolled_back', version: '50'); // ...and then it finished
    result = () {
      installed = '52';
      status('updated', version: '52', timestamp: 1000100);
      return ProcessResult(1, 0, 'updated', '');
    };
    await updater.run({'sha256': 'a' * 64, 'job': 'job-2', 'version': '52'}, supported: true);
    expect(runs.length, 1);
    expect(updater.job?['job'], 'job-2');
    expect(updater.job?['phase'], 'updated');
  });

  test('reports wait for the persisted job to load', () async {
    persisted('updated');
    installed = '51';
    final updater = ota();
    final reports = await Future.wait([
      updater.report('0607c6', supported: true),
      updater.report('0607c6', supported: true),
    ]);
    expect(reports.map((r) => r['job']).toList(), ['job-1', 'job-1']);
    expect(reports.first['phase'], 'updated');
  });

  test('the CMS request and the hourly check never run the updater at the same time', () async {
    final order = <String>[];
    final updater = LinuxOta(
      stateFile: '${root.path}/linux-ota.json',
      runUpdater: (arguments) async {
        order.add('start ${arguments.length}');
        if (arguments.length == 1) await Future<void>.delayed(const Duration(milliseconds: 50));
        order.add('end ${arguments.length}');
        return ProcessResult(1, 0, 'up-to-date', '');
      },
    );
    await Future.wait([updater.exclusiveUpdate(), updater.exclusiveUpdate(now: true)]);
    expect(order, ['start 1', 'end 1', 'start 2', 'end 2']);
  });
}
