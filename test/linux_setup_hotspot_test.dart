import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_network.dart';
import '../lib/services/linux_setup_hotspot.dart';

/// nmcli answers for an Azulle with its cable unplugged and an idle Wi-Fi radio.
String _answer(String executable, List<String> arguments, bool savedWifi) {
  final command = '$executable ${arguments.join(' ')}';
  if (command == 'nmcli -t -f RUNNING general') return 'running\n';
  if (command == 'nmcli -t -f DEVICE,TYPE,STATE device') return 'enp2s0:ethernet:unavailable\nwlp3s0:wifi:disconnected\n';
  if (command.contains('device show wlp3s0')) return 'GENERAL.HWADDR:A4\\:34\\:D9\\:00\\:3C\\:7F\n';
  if (command == 'nmcli -t -f UUID,TYPE,ACTIVE connection show') {
    return 'u-hotspot:802-11-wireless:yes\n${savedWifi ? 'u-office:802-11-wireless:no\n' : ''}';
  }
  if (command.endsWith('connection show u-hotspot')) return '802-11-wireless.ssid:SignageX-Setup-AB12\n802-11-wireless.mode:ap\n';
  if (command.endsWith('connection show u-office')) return '802-11-wireless.ssid:Office\n802-11-wireless.mode:infrastructure\n';
  return '';
}

void main() {
  late Directory root;
  late List<Map> helperRequests;
  late List<Map> wifiRequests;
  late Map wifiOutcome;
  late bool route;
  late bool savedWifi;
  late DateTime now;
  late int port;
  late LinuxSetupHotspot hotspot;

  Map<String, dynamic> started() => {
        'phase': 'applied',
        'detail': 'Setup hotspot running',
        'hotspot': {
          'ssid': 'SignageX-Setup-AB12',
          'password': 'k7m2pq9xw4tz',
          'address': '127.0.0.1',
          'port': port,
          'expires': now.add(const Duration(minutes: 15)).millisecondsSinceEpoch ~/ 1000,
          'networks': [
            {'ssid': 'Office', 'signal': 80, 'security': 'wpa'},
            {'ssid': '<b>Cafe</b>', 'signal': 60, 'security': 'open'},
            {'ssid': 'Corp', 'signal': 50, 'security': 'enterprise'},
          ],
        },
      };

  setUp(() async {
    root = await Directory.systemTemp.createTemp('setup-hotspot-test');
    File('${root.path}/network-helper').writeAsStringSync('#!/bin/sh\n');
    helperRequests = [];
    wifiRequests = [];
    wifiOutcome = {'phase': 'applied', 'detail': "Connected to 'Office'."};
    route = false;
    savedWifi = false;
    now = DateTime(2026, 11, 4, 12);
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = probe.port;
    await probe.close();
    final network = LinuxNetwork(
      stateFile: '${root.path}/linux-network.json',
      helper: '${root.path}/network-helper',
      run: (executable, arguments) async => _answer(executable, arguments, savedWifi),
      runHelper: (request) async {
        wifiRequests.add(jsonDecode(request) as Map);
        return ProcessResult(1, 0, jsonEncode(wifiOutcome), '');
      },
      permitted: () async => true,
      clock: () => now,
    );
    hotspot = LinuxSetupHotspot(
      network: network,
      runHelper: (request) async {
        final decoded = jsonDecode(request) as Map;
        helperRequests.add(decoded);
        final answer = decoded['op'] == 'hotspot_start' ? started() : {'phase': 'applied', 'detail': 'Setup hotspot stopped'};
        return ProcessResult(1, 0, jsonEncode(answer), '');
      },
      hasDefaultRoute: () => route,
      apiReachable: () async => false,
      clock: () => now,
      applyDelay: Duration.zero,
    );
  });

  tearDown(() async {
    await hotspot.stop('test finished');
    await root.delete(recursive: true);
  });

  Future<void> offlineFor(Duration duration, {bool paired = false}) async {
    await hotspot.tick(connected: false, paired: paired, code: 'XK4AB12');
    now = now.add(duration);
    await hotspot.tick(connected: false, paired: paired, code: 'XK4AB12');
  }

  Future<HttpClientResponse> send(String method, String path,
      {Object? body, String? host, String? origin, String type = 'application/json'}) async {
    final client = HttpClient();
    final request = await client.open(method, '127.0.0.1', port, path);
    if (host != null) request.headers.host = host;
    if (origin != null) request.headers.set('origin', origin);
    if (body != null) {
      request.headers.contentType = ContentType.parse(type);
      request.write(body is String ? body : jsonEncode(body));
    }
    final response = await request.close();
    client.close();
    return response;
  }

  Future<String> text(HttpClientResponse response) => response.transform(utf8.decoder).join();

  test('the join code is the standard Wi-Fi QR format, escaped', () {
    final info = SetupHotspotInfo.fromJson({'ssid': 'A;B', 'password': r'p:w\"', 'port': 8080, 'expires': 0});
    expect(info.joinCode, r'WIFI:T:WPA;S:A\;B;P:p\:w\\\";;');
    expect(info.url, 'http://10.42.0.1:8080/');
  });

  test('the name ends with the player code, or the Wi-Fi MAC before pairing', () {
    final status = {
      'interfaces': [
        {'type': 'ethernet', 'mac': '00:ce:39:d2:0d:85'},
        {'type': 'wifi', 'mac': 'a4:34:d9:00:3c:7f'},
      ]
    };
    expect(LinuxSetupHotspot.suffix('xk4-ab12', status), 'AB12');
    expect(LinuxSetupHotspot.suffix('', status), '3C7F');
    expect(LinuxSetupHotspot.suffix('', {}), '0000');
  });

  test('no hotspot while there is a network, or before three minutes offline', () async {
    route = true;
    await hotspot.tick(connected: true, paired: false, code: 'XK4AB12');
    now = now.add(const Duration(minutes: 10));
    await hotspot.tick(connected: true, paired: false, code: 'XK4AB12');
    route = false;
    await offlineFor(const Duration(minutes: 2, seconds: 50));
    expect(helperRequests, isEmpty);
    expect(hotspot.info, isNull);
  });

  test('a route without the API counts as offline', () async {
    route = true;
    await offlineFor(const Duration(minutes: 3));
    expect(helperRequests.single['op'], 'hotspot_start');
  });

  test('an unpaired player starts the hotspot after three minutes offline', () async {
    savedWifi = true;
    await offlineFor(const Duration(minutes: 3));
    expect(helperRequests.single, containsPair('suffix', 'AB12'));
    expect(hotspot.info!.ssid, 'SignageX-Setup-AB12');
  });

  test('a paired player waits for its saved Wi-Fi, but not for a lost cable', () async {
    savedWifi = true;
    await offlineFor(const Duration(minutes: 5), paired: true);
    expect(helperRequests, isEmpty);
    savedWifi = false; // The hotspot profile itself does not count as saved Wi-Fi.
    now = now.add(const Duration(seconds: 30));
    await hotspot.tick(connected: false, paired: true, code: 'XK4AB12');
    expect(helperRequests.single['op'], 'hotspot_start');
  });

  test('the page lists nearby networks, escaped, without enterprise ones', () async {
    await offlineFor(const Duration(minutes: 3));
    final page = await text(await send('GET', '/'));
    expect(page, contains('<option value="Office">Office</option>'));
    expect(page, contains('&lt;b&gt;Cafe&lt;&#47;b&gt; (open)'));
    expect(page, isNot(contains('<b>Cafe')));
    expect(page, isNot(contains('Corp')));
    expect(page, isNot(contains('k7m2pq9xw4tz')));
  });

  test('requests for any other host name, cross-site posts and form posts are refused', () async {
    await offlineFor(const Duration(minutes: 3));
    expect((await send('GET', '/', host: 'attacker.example')).statusCode, HttpStatus.misdirectedRequest);
    final wifi = {'ssid': 'Office', 'password': 'secret123'};
    expect((await send('POST', '/connect', body: wifi, origin: 'http://attacker.example')).statusCode, HttpStatus.forbidden);
    expect((await send('POST', '/connect', body: 'ssid=Office&password=secret123', type: 'application/x-www-form-urlencoded')).statusCode,
        HttpStatus.forbidden);
    expect((await send('POST', '/connect', body: {'ssid': 'Office', 'password': 'short'})).statusCode, HttpStatus.badRequest);
    expect((await send('POST', '/connect', body: {'ssid': '', 'password': 'secret123'})).statusCode, HttpStatus.badRequest);
    expect((await send('POST', '/connect', body: 'x' * 4096)).statusCode, HttpStatus.requestEntityTooLarge);
    expect(wifiRequests, isEmpty);
  });

  test('Wi-Fi from the page goes through the helper and ends the hotspot', () async {
    await offlineFor(const Duration(minutes: 3));
    final response = await send('POST', '/connect', body: {'ssid': 'Office', 'password': 'secret123'}, origin: 'http://127.0.0.1:$port');
    expect(response.statusCode, HttpStatus.accepted);
    await Future.delayed(const Duration(milliseconds: 50));
    expect(wifiRequests.single, containsPair('op', 'wifi_add'));
    expect(wifiRequests.single, containsPair('connect', true));
    expect(wifiRequests.single, containsPair('password', 'secret123'));
    expect(hotspot.phase, 'connected');
    expect(hotspot.info, isNull);
    expect(helperRequests.where((request) => request['op'] == 'hotspot_stop'), isEmpty, reason: 'the helper already removed it');
  });

  test('a wrong password keeps the hotspot for another try', () async {
    wifiOutcome = {'phase': 'failed', 'detail': "Could not connect to 'Office' (wrong password or no internet). Restored previous connection."};
    await offlineFor(const Duration(minutes: 3));
    await send('POST', '/connect', body: {'ssid': 'Office', 'password': 'wrongpass'});
    await Future.delayed(const Duration(milliseconds: 50));
    expect(hotspot.phase, 'failed');
    expect(hotspot.info, isNotNull);
    final status = jsonDecode(await text(await send('GET', '/status'))) as Map;
    expect(status['phase'], 'failed');
    expect(status['detail'], contains('wrong password'));
  });

  test('a phone is rate limited', () async {
    await offlineFor(const Duration(minutes: 3));
    var limited = 0;
    for (var i = 0; i < 65; i++) {
      final response = await send('GET', '/status');
      await response.drain<void>();
      if (response.statusCode == HttpStatus.tooManyRequests) limited++;
    }
    expect(limited, 5);
  });

  test('the hotspot stops when a network comes back or after 15 minutes', () async {
    await offlineFor(const Duration(minutes: 3));
    route = true;
    await hotspot.stop('a network connected');
    expect(helperRequests.last['op'], 'hotspot_stop');
    expect(hotspot.info, isNull);
    // Still offline: it comes back only after another three minutes.
    route = false;
    now = now.add(const Duration(minutes: 1));
    await hotspot.tick(connected: false, paired: false, code: 'XK4AB12');
    expect(helperRequests.where((request) => request['op'] == 'hotspot_start').length, 1);
    now = now.add(const Duration(minutes: 2));
    await hotspot.tick(connected: false, paired: false, code: 'XK4AB12');
    expect(helperRequests.where((request) => request['op'] == 'hotspot_start').length, 2);
  });
}
