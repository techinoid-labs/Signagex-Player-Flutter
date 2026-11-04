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
        installedVersion: (_) async => installed,
        compareVersions: (a, op, b) async => op == 'ge' ? _compare(a, b) >= 0 : _compare(a, b) > 0,
        runUpdater: (arguments) async {
          runs.add(arguments);
          return result();
        },
        clock: () => now,
      );

  void status(String value, double timestamp) =>
      File('${root.path}/update-status.json').writeAsStringSync(jsonEncode({'status': value, 'version': '51', 'timestamp': timestamp}));

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

  test('a verified CMS request runs the updater now and reports updated', () async {
    final updater = ota();
    final phases = <String?>[];
    updater.onChange = () => phases.add(updater.job?['phase'] as String?);
    result = () {
      installed = '51';
      return ProcessResult(1, 0, 'updated', '');
    };
    await updater.run({'job': 'job-1', 'version': '51', 'issued': 5}, supported: true);
    expect(runs, [
      ['/usr/lib/signagex-player/update-player', '--now']
    ]);
    expect(phases, ['downloading', 'updated']);
    final report = await updater.report('0607c6', supported: true);
    expect(report['job'], 'job-1');
    expect(report['phase'], 'updated');
    expect(report['version'], '51');
    expect(report['platform'], 'linux');
    expect(report['protocol'], 'linux_ota_v1');
  });

  test('failures, unsupported devices and repeated deliveries are reported once', () async {
    final updater = ota();
    result = () => ProcessResult(1, 1, '', 'Update checksum mismatch');
    await updater.run({'job': 'job-1', 'version': '51'}, supported: true);
    expect(updater.job?['phase'], 'failed');
    expect(updater.job?['detail'], 'Update checksum mismatch');
    await updater.run({'job': 'job-1', 'version': '51'}, supported: true);
    expect(runs.length, 1); // the same job delivered twice never runs twice

    await updater.run({'job': 'job-2', 'version': '51'}, supported: false);
    expect(runs.length, 1);
    expect(updater.job?['phase'], 'failed');
    expect(updater.job?['detail'], 'Managed updates are not enabled on this device');
  });

  test('a job interrupted by the player restart is settled from the device state', () async {
    File('${root.path}/linux-ota.json').writeAsStringSync(jsonEncode(
        {'job': 'job-1', 'target': '51', 'phase': 'installing', 'detail': '', 'started': 999990.0}));
    installed = '51';
    final upgraded = ota();
    await upgraded.load();
    expect(upgraded.job?['phase'], 'updated');

    File('${root.path}/linux-ota.json').writeAsStringSync(jsonEncode(
        {'job': 'job-1', 'target': '51', 'phase': 'installing', 'detail': '', 'started': 999990.0}));
    installed = '50';
    status('rolled_back', 999995);
    final rolledBack = ota();
    await rolledBack.load();
    expect(rolledBack.job?['phase'], 'failed');

    File('${root.path}/linux-ota.json').writeAsStringSync(jsonEncode(
        {'job': 'job-1', 'target': '51', 'phase': 'downloading', 'detail': '', 'started': 999990.0}));
    status('installing', 999995);
    final stillRunning = ota();
    await stillRunning.load();
    expect(stillRunning.job?['phase'], 'installing');
  });

  test('the CMS request and the hourly check never run the updater at the same time', () async {
    final order = <String>[];
    final updater = LinuxOta(
      stateFile: '${root.path}/linux-ota.json',
      runUpdater: (arguments) async {
        order.add('start ${arguments.length}');
        if (arguments.length == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        order.add('end ${arguments.length}');
        return ProcessResult(1, 0, 'up-to-date', '');
      },
    );
    await Future.wait([updater.exclusiveUpdate(), updater.exclusiveUpdate(now: true)]);
    expect(order, ['start 1', 'end 1', 'start 2', 'end 2']);
  });
}
