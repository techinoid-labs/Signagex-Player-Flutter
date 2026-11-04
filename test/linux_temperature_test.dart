import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/utils/linux_temperature.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('thermal-test'));
  tearDown(() => root.deleteSync(recursive: true));
  void sensor(int index, String type, String value) {
    final dir = Directory('${root.path}/thermal_zone$index')..createSync();
    File('${dir.path}/type').writeAsStringSync(type);
    File('${dir.path}/temp').writeAsStringSync(value);
  }
  test('x86 package sensor takes precedence over ACPI and TCPU', () async {
    sensor(0, 'acpitz', '83000');
    sensor(2, 'TCPU', '83500');
    sensor(4, 'x86_pkg_temp', '84250');
    expect(await linuxCpuTemperature(root), 84.25);
  });
  test('Pi CPU sensor preserves fractional Celsius', () async {
    sensor(0, 'cpu-thermal', '56500');
    expect(await linuxCpuTemperature(root), 56.5);
  });
  test('unknown or invalid sensors are unavailable', () async {
    sensor(0, 'iwlwifi_1', '62000');
    sensor(1, 'x86_pkg_temp', 'NaN');
    expect(await linuxCpuTemperature(root), isNull);
  });
}
