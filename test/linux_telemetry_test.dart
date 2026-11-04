import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_telemetry.dart';

void main() {
  late Directory root;
  late LinuxTelemetry telemetry;
  void fixture(String name, String content) {
    File('${root.path}/$name')..createSync(recursive: true)..writeAsStringSync(content);
  }
  setUp(() {
    root = Directory.systemTemp.createTempSync('linux-telemetry');
    fixture('proc/meminfo', 'MemTotal: 8192 kB\nMemAvailable: 4097 kB\n');
    fixture('proc/stat', 'cpu  100 0 100 800 0 0 0 0\n');
    fixture('proc/net/dev', 'lo: 999999 0 0 0 0 0 0 0 999999\neth0: 1024 0 0 0 0 0 0 0 2048\n');
    fixture('proc/uptime', '5400.75 1000\n');
    telemetry = LinuxTelemetry(procRoot: Directory('${root.path}/proc'),
      thermalRoot: Directory('${root.path}/thermal'), command: (_, __) async =>
        'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 9000000000 3000000000 6000000000 33% /');
  });
  tearDown(() => root.deleteSync(recursive: true));
  test('memory MiB, disk KiB and uptime seconds stay precise; unsupported readings are absent', () async {
    final sample = await telemetry.sample();
    expect(sample['memory'], {'free':4097/1024, 'used':4095/1024});
    expect(sample['disk'], {'free':6000000000, 'used':3000000000});
    expect(sample['uptime']['system'], 5400);
    for (final key in ['cpu','networkTraffic','temperature','battery']) {
      expect(sample.containsKey(key), isFalse);
    }
  });
  test('CPU deltas and per-sample network KiB preserve fractions', () async {
    await telemetry.sample();
    fixture('proc/stat', 'cpu  125 0 100 875 0 0 0 0\n');
    fixture('proc/net/dev', 'eth0: 1152 0 0 0 0 0 0 0 2176\n');
    final sample = await telemetry.sample();
    expect(sample['cpu'], {'usedPercent':25.0, 'idlePercent':75.0});
    expect(sample['networkTraffic'], {'inKB':0.125,'outKB':0.125});
  });
}
