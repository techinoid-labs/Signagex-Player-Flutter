import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// CMS network status and Wi-Fi management for Linux players (linux_network_v1).
///
/// Status comes from NetworkManager (`nmcli`) and is reported to the CMS as a
/// device-signed report in `capabilities.linux_network`. Wi-Fi changes arrive as
/// server-signed commands that the remote-view adapter verifies (and whose
/// password it decrypts); they are applied by the root network helper, which
/// rolls a failed "connect now" back to the previous connection.
class LinuxNetwork {
  LinuxNetwork({
    this.stateFile,
    this.helper = '/usr/lib/signagex-player/network-helper',
    Future<String> Function(String executable, List<String> arguments)? run,
    Future<ProcessResult> Function(String request)? runHelper,
    Future<bool> Function()? permitted,
    DateTime Function()? clock,
  })  : _run = run ?? _command,
        _runHelper = runHelper ?? pkexecHelper,
        _permitted = permitted ?? _inNetworkGroup,
        _clock = clock ?? DateTime.now;

  static final LinuxNetwork instance = LinuxNetwork();
  static const protocol = 'linux_network_v1';

  final String? stateFile;
  final String helper;
  final Future<String> Function(String executable, List<String> arguments) _run;
  final Future<ProcessResult> Function(String request) _runHelper;
  final Future<bool> Function() _permitted;
  final DateTime Function() _clock;

  /// Called whenever the job phase changes, so the player can publish at once.
  void Function()? onChange;
  Future<void> Function(String message, String type)? event;

  Map<String, dynamic>? job;
  Map<String, dynamic>? _status;
  DateTime? _statusAt;
  Future<void>? _loading;
  bool _running = false;

  /// A Wi-Fi change is being applied.
  bool get busy => _running;

  /// Split one `nmcli -t` line; ':' and '\' inside values arrive escaped.
  static List<String> fields(String line) {
    final values = <String>[];
    final current = StringBuffer();
    var escaped = false;
    for (final character in line.split('')) {
      if (escaped) {
        current.write(character);
        escaped = false;
      } else if (character == '\\') {
        escaped = true;
      } else if (character == ':') {
        values.add(current.toString());
        current.clear();
      } else {
        current.write(character);
      }
    }
    values.add(current.toString());
    return values;
  }

  /// `nmcli -t -f A,B device show X` style output as {A: value}, first value per key.
  static Map<String, String> properties(String output) {
    final result = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final index = line.indexOf(':');
      if (index <= 0) continue;
      final key = line.substring(0, index).replaceAll(RegExp(r'\[\d+\]$'), '');
      result.putIfAbsent(key, () => fields(line.substring(index + 1)).join(':'));
    }
    return result;
  }

  static String _clip(String value, [int length = 64]) => value.length > length ? value.substring(0, length) : value;

  static String _deviceState(String value) {
    if (value.startsWith('connected')) return 'connected';
    if (value.startsWith('connecting')) return 'connecting';
    if (value == 'unavailable' || value == 'unmanaged') return 'unavailable';
    return 'disconnected';
  }

  Future<bool> _networkManager() async => (await _run('nmcli', ['-t', '-f', 'RUNNING', 'general'])).trim() == 'running';

  /// Current status; NetworkManager is queried at most once a minute (each query
  /// is a handful of short `nmcli` calls) unless [force] is set.
  Future<Map<String, dynamic>> status({bool force = false}) async {
    if (!force && _status != null && _statusAt != null && _clock().difference(_statusAt!) < const Duration(minutes: 1)) {
      return _status!;
    }
    final nm = await _networkManager();
    final interfaces = nm ? await _nmInterfaces() : await _ipInterfaces();
    final primary = await _primary(interfaces);
    _status = {
      'supported': nm && File(helper).existsSync() && await _permitted(),
      'wifi_hardware': interfaces.any((entry) => entry['type'] == 'wifi'),
      'primary': primary,
      'interfaces': interfaces,
      'saved': nm ? await _saved() : <Map<String, dynamic>>[],
    };
    _statusAt = _clock();
    return _status!;
  }

  Future<List<Map<String, dynamic>>> _nmInterfaces() async {
    final result = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(await _run('nmcli', ['-t', '-f', 'DEVICE,TYPE,STATE', 'device']))) {
      final values = fields(line);
      if (values.length < 3 || !['ethernet', 'wifi'].contains(values[1]) || result.length >= 8) continue;
      final details = properties(await _run('nmcli', ['-t', '-f', 'GENERAL.HWADDR,IP4.ADDRESS,CAPABILITIES.SPEED', 'device', 'show', values[0]]));
      final speed = int.tryParse((details['CAPABILITIES.SPEED'] ?? '').split(' ').first);
      final entry = <String, dynamic>{
        'name': _clip(values[0]),
        'type': values[1],
        'state': _deviceState(values[2]),
        'mac': _clip((details['GENERAL.HWADDR'] ?? '').toLowerCase()),
        'ip': _clip((details['IP4.ADDRESS'] ?? '').split('/').first),
        'ssid': '',
        'signal': null,
        'speed_mbps': speed != null && speed > 0 ? speed : null,
      };
      if (values[1] == 'wifi' && entry['state'] == 'connected') {
        for (final row in const LineSplitter().convert(
            await _run('nmcli', ['-t', '-f', 'IN-USE,SSID,SIGNAL', 'device', 'wifi', 'list', 'ifname', values[0], '--rescan', 'no']))) {
          final wifi = fields(row);
          if (wifi.length >= 3 && wifi[0] == '*') {
            entry['ssid'] = _clip(wifi[1], 32);
            entry['signal'] = int.tryParse(wifi[2])?.clamp(0, 100);
            break;
          }
        }
      }
      result.add(entry);
    }
    return result;
  }

  /// Without NetworkManager the CMS still gets interfaces and addresses.
  Future<List<Map<String, dynamic>>> _ipInterfaces() async {
    try {
      final addresses = jsonDecode(await _run('ip', ['-j', 'address', 'show'])) as List;
      return addresses.where((entry) => entry['link_type'] == 'ether').take(8).map((entry) {
        final name = entry['ifname'].toString();
        final ipv4 = (entry['addr_info'] as List? ?? []).firstWhere((a) => a['family'] == 'inet', orElse: () => null);
        return <String, dynamic>{
          'name': _clip(name),
          'type': Directory('/sys/class/net/$name/wireless').existsSync() ? 'wifi' : 'ethernet',
          'state': entry['operstate'] == 'UP' ? 'connected' : 'disconnected',
          'mac': _clip(entry['address']?.toString() ?? ''),
          'ip': _clip(ipv4?['local']?.toString() ?? ''),
          'ssid': '',
          'signal': null,
          'speed_mbps': null,
        };
      }).toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, dynamic>> _primary(List<Map<String, dynamic>> interfaces) async {
    final none = <String, dynamic>{'type': 'none', 'interface': '', 'ip': '', 'gateway': '', 'ssid': '', 'signal': null};
    try {
      final route = jsonDecode(await _run('ip', ['-j', 'route', 'get', '1.1.1.1'])) as List;
      if (route.isEmpty) return none;
      final device = route.first['dev']?.toString() ?? '';
      final entry = interfaces.firstWhere((item) => item['name'] == device, orElse: () => {});
      if (entry.isEmpty) return none;
      return {
        'type': entry['type'],
        'interface': entry['name'],
        'ip': _clip(route.first['prefsrc']?.toString() ?? entry['ip'] as String),
        'gateway': _clip(route.first['gateway']?.toString() ?? ''),
        'ssid': entry['ssid'],
        'signal': entry['signal'],
      };
    } catch (_) {
      return none;
    }
  }

  Future<List<Map<String, dynamic>>> _saved() async {
    final saved = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(await _run('nmcli', ['-t', '-f', 'UUID,TYPE,ACTIVE', 'connection', 'show']))) {
      final values = fields(line);
      if (values.length < 3 || values[1] != '802-11-wireless' || saved.length >= 16) continue;
      final details = properties(await _run('nmcli', [
        '-t', '-f', '802-11-wireless.ssid,802-11-wireless.mode,802-11-wireless.hidden,802-11-wireless-security.key-mgmt', 'connection', 'show', values[0]
      ]));
      final ssid = details['802-11-wireless.ssid'] ?? '';
      // The setup hotspot is an access point, not a network the player can join.
      if (ssid.isEmpty || utf8.encode(ssid).length > 32 || details['802-11-wireless.mode'] == 'ap') continue;
      final keyManagement = details['802-11-wireless-security.key-mgmt'] ?? '';
      saved.add({
        'ssid': ssid,
        'active': values[2] == 'yes',
        'security': keyManagement.contains('eap') ? 'enterprise' : keyManagement.isEmpty ? 'open' : 'wpa',
        'hidden': details['802-11-wireless.hidden'] == 'yes',
      });
    }
    return saved;
  }

  Future<File> _state() async {
    if (stateFile != null) return File(stateFile!);
    final home = Platform.environment['HOME'] ?? '.';
    return File('$home/.local/share/signagex-player/linux-network.json');
  }

  Future<void> load() => _loading ??= () async {
        try {
          final file = await _state();
          if (await file.exists()) job = Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);
        } catch (_) {
          job = null;
        }
        // The player stopped mid-change; the helper's own status says how it ended.
        if (job?['phase'] == 'applying') await _setPhase('failed', detail: 'The player restarted during the change');
      }();

  Future<void> _setPhase(String phase, {String detail = ''}) async {
    if (job == null) return;
    job!['phase'] = phase;
    job!['detail'] = detail.length > 200 ? detail.substring(0, 200) : detail;
    final file = await _state();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(job), flush: true);
    await temporary.rename(file.path);
    _statusAt = null; // Report the network as it is after the change.
    onChange?.call();
  }

  /// Run a verified CMS request. [verified] comes from the remote-view adapter
  /// and is the only place the decrypted password exists in the player (or from
  /// the setup hotspot page, [source]).
  Future<void> run(Map verified, {String source = 'the CMS'}) async {
    await load();
    final id = verified['job']?.toString() ?? '';
    if (id.isEmpty || id.length > 64 || (job != null && job!['job'] == id)) return;
    if (_running) {
      await event?.call('Network change ignored: another change is running', 'warning');
      return;
    }
    final ssid = verified['ssid']?.toString() ?? '';
    job = {'job': id, 'op': verified['op'], 'ssid': ssid, 'phase': 'applying', 'detail': ''};
    await _setPhase('applying');
    if (!(await status(force: true))['supported']) {
      return _setPhase('failed', detail: 'Wi-Fi management is not enabled on this device');
    }
    await event?.call('Network change requested from $source: ${verified['op']} "$ssid"', 'info');
    _running = true;
    try {
      final result = await _runHelper(jsonEncode({
        'job': id,
        'op': verified['op'],
        'ssid': ssid,
        'password': verified['password'] ?? '',
        'hidden': verified['hidden'] == true,
        'connect': verified['connect'] == true,
      })).timeout(const Duration(minutes: 3));
      final lines = const LineSplitter().convert(result.stdout.toString()).where((line) => line.startsWith('{'));
      final outcome = lines.isEmpty ? const {} : jsonDecode(lines.last) as Map;
      if (result.exitCode == 0 && ['applied', 'failed'].contains(outcome['phase'])) {
        await _setPhase(outcome['phase'] as String, detail: outcome['detail']?.toString() ?? '');
      } else {
        final error = result.stderr.toString().trim();
        await _setPhase('failed', detail: error.isNotEmpty ? error : 'The network change did not complete');
      }
    } catch (error) {
      await _setPhase('failed', detail: '$error');
    } finally {
      _running = false;
    }
    await event?.call('Network change ${job!['phase']}: ${job!['detail']}', job!['phase'] == 'applied' ? 'info' : 'error');
  }

  /// The unsigned report; signed by the adapter before it is published.
  Future<Map<String, dynamic>> report(String player) async {
    await load();
    return {
      'protocol': protocol,
      'player': player,
      ...await status(),
      'job': job?['job']?.toString() ?? '',
      'phase': job?['phase']?.toString() ?? '',
      'detail': job?['detail']?.toString() ?? '',
    };
  }

  /// What counts as a change worth re-publishing: signal moves in 10-point steps,
  /// so a fleet of screens does not re-report every flicker.
  static String fingerprint(Map<String, dynamic> report) {
    int? bucket(Object? signal) => signal is int ? signal ~/ 10 : null;
    final copy = jsonDecode(jsonEncode(report)) as Map;
    (copy['primary'] as Map?)?['signal'] = bucket((copy['primary'] as Map?)?['signal']);
    for (final entry in (copy['interfaces'] as List? ?? [])) {
      (entry as Map)['signal'] = bucket(entry['signal']);
    }
    return jsonEncode(copy);
  }

  static Future<String> _command(String executable, List<String> arguments) async {
    try {
      final result = await Process.run(executable, arguments).timeout(const Duration(seconds: 10));
      return result.exitCode == 0 ? result.stdout.toString() : '';
    } catch (_) {
      return '';
    }
  }

  static Future<bool> _inNetworkGroup() async =>
      (await _command('id', ['-nG'])).split(RegExp(r'\s+')).contains('signagex-network');

  static Future<ProcessResult> pkexecHelper(String request) async {
    final process = await Process.start('pkexec', ['/usr/lib/signagex-player/network-helper']);
    process.stdin.write(request);
    await process.stdin.close();
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    return ProcessResult(process.pid, await process.exitCode, await stdout, await stderr);
  }
}
