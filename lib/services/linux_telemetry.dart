import 'dart:io';
import 'linux_configuration.dart';
import '../utils/linux_temperature.dart';

/// Backend units: memory MiB, disk KiB, network KiB per sample, uptime seconds.
class LinuxTelemetry {
  LinuxTelemetry({Directory? procRoot, Directory? thermalRoot, LinuxCommand? command})
      : procRoot = procRoot ?? Directory('/proc'),
        thermalRoot = thermalRoot ?? Directory('/sys/class/thermal'),
        command = command ?? LinuxConfiguration.runCommand;
  final Directory procRoot;
  final Directory thermalRoot;
  final LinuxCommand command;
  List<int>? _cpu;
  List<int>? _network;
  final Stopwatch uptime = Stopwatch()..start();

  Future<Map<String, dynamic>> sample() async {
    final memory = <String, int>{};
    for (final line in await File('${procRoot.path}/meminfo').readAsLines()) {
      final m = RegExp(r'^(\w+):\s+(\d+)').firstMatch(line);
      if (m != null) memory[m[1]!] = int.parse(m[2]!);
    }
    final cpu = (await File('${procRoot.path}/stat').readAsLines())
        .first
        .split(RegExp(r'\s+'))
        .skip(1)
        .where((v) => v.isNotEmpty)
        .map(int.parse)
        .toList();
    final total = cpu.take(8).fold<int>(0, (a, b) => a + b);
    final idle = cpu[3] + cpu[4];
    double? used;
    if (_cpu != null && total > _cpu![0])
      used = ((1 - (idle - _cpu![1]) / (total - _cpu![0])) * 100)
          .clamp(0, 100)
          .toDouble();
    _cpu = [total, idle];
    var rx = 0;
    var tx = 0;
    for (final line in await File('${procRoot.path}/net/dev').readAsLines()) {
      if (!line.contains(':') || line.split(':').first.trim() == 'lo') continue;
      final fields = line.split(':').last.trim().split(RegExp(r'\s+'));
      rx += int.parse(fields[0]);
      tx += int.parse(fields[8]);
    }
    final previous = _network;
    _network = [rx, tx];
    final df = (await command('df', ['-Pk', '/']))
        .split('\n')
        .last
        .trim()
        .split(RegExp(r'\s+'));
    final available = memory['MemAvailable'] ?? memory['MemFree'] ?? 0;
    final totalMemory = memory['MemTotal'] ?? 0;
    final temperature = await linuxCpuTemperature(thermalRoot);
    final result = <String, dynamic>{
      'memory': {
        'free': available / 1024,
        'used': (totalMemory - available) / 1024
      },
      'disk': {'free': int.parse(df[3]), 'used': int.parse(df[2])},
      'uptime': {
        'system': double.parse(
                (await File('${procRoot.path}/uptime').readAsString()).split(' ').first)
            .floor(),
        'app': uptime.elapsed.inSeconds
      },
      if (used != null) 'cpu': {'usedPercent': used, 'idlePercent': 100 - used},
      if (previous != null)
        'networkTraffic': {
          'inKB': (rx - previous[0]).clamp(0, 1 << 62) / 1024,
          'outKB': (tx - previous[1]).clamp(0, 1 << 62) / 1024
        },
      if (temperature != null) 'temperature': {'value': temperature},
    };
    return result;
  }
}
