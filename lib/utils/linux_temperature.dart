import 'dart:io';

/// CPU temperature only. ACPI, Wi-Fi and unrelated zones are not substitutes.
Future<double?> linuxCpuTemperature(Directory thermalRoot) async {
  const types = ['x86_pkg_temp', 'cpu-thermal', 'cpu_thermal', 'TCPU'];
  if (!await thermalRoot.exists()) return null;
  final readings = <String, double>{};
  await for (final entry in thermalRoot.list()) {
    if (!entry.path.split('/').last.startsWith('thermal_zone')) continue;
    try {
      final type = (await File('${entry.path}/type').readAsString()).trim();
      if (!types.contains(type)) continue;
      final value = double.tryParse((await File('${entry.path}/temp').readAsString()).trim());
      if (value != null && value.isFinite && value >= -40000 && value <= 150000) {
        readings[type] = value / 1000;
      }
    } on FileSystemException {
      // A disappearing or unreadable sensor means unavailable, not zero.
    }
  }
  for (final type in types) {
    if (readings.containsKey(type)) return readings[type];
  }
  return null;
}
