import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_network.dart';

/// nmcli/ip answers for an Azulle on Ethernet with a connected Wi-Fi radio.
String _answer(String executable, List<String> arguments) {
  final command = '$executable ${arguments.join(' ')}';
  if (command == 'nmcli -t -f RUNNING general') return 'running\n';
  if (command == 'nmcli -t -f DEVICE,TYPE,STATE device') {
    return 'enp2s0:ethernet:connected\nwlp3s0:wifi:connected\nlo:loopback:connected (externally)\np2p-dev-wlp3s0:wifi-p2p:disconnected\n';
  }
  if (command.startsWith('nmcli -t -f GENERAL.HWADDR,IP4.ADDRESS,CAPABILITIES.SPEED device show enp2s0')) {
    return 'GENERAL.HWADDR:00\\:CE\\:39\\:D2\\:0D\\:85\nIP4.ADDRESS[1]:192.168.1.125/24\nCAPABILITIES.SPEED:1000 Mb/s\n';
  }
  if (command.startsWith('nmcli -t -f GENERAL.HWADDR,IP4.ADDRESS,CAPABILITIES.SPEED device show wlp3s0')) {
    return 'GENERAL.HWADDR:A4\\:34\\:D9\\:00\\:00\\:01\nIP4.ADDRESS[1]:192.168.1.140/24\nIP4.ADDRESS[2]:10.0.0.2/8\nCAPABILITIES.SPEED:unknown\n';
  }
  if (command.startsWith('nmcli -t -f IN-USE,SSID,SIGNAL device wifi list ifname wlp3s0')) {
    return ' :Neighbour:80\n*:Baig\\: 1000H:67\n';
  }
  if (command == 'ip -j route get 1.1.1.1') {
    return jsonEncode([{'dst': '1.1.1.1', 'gateway': '192.168.1.1', 'dev': 'enp2s0', 'prefsrc': '192.168.1.125'}]);
  }
  if (command == 'nmcli -t -f UUID,TYPE,ACTIVE connection show') {
    return 'u-wired:802-3-ethernet:yes\nu-office:802-11-wireless:yes\nu-guest:802-11-wireless:no\nu-corp:802-11-wireless:no\n';
  }
  if (command.endsWith('connection show u-office')) {
    return '802-11-wireless.ssid:Baig\\: 1000H\n802-11-wireless.hidden:no\n802-11-wireless-security.key-mgmt:wpa-psk\n';
  }
  if (command.endsWith('connection show u-guest')) return '802-11-wireless.ssid:Guest\n802-11-wireless.hidden:yes\n802-11-wireless-security.key-mgmt:\n';
  if (command.endsWith('connection show u-corp')) return '802-11-wireless.ssid:Corp\n802-11-wireless.hidden:no\n802-11-wireless-security.key-mgmt:wpa-eap\n';
  return '';
}

void main() {
  late Directory root;
  late List<String> requests;
  late ProcessResult Function() result;
  late int calls;
  late DateTime now;

  LinuxNetwork network({bool permitted = true, bool helper = true}) {
    final path = '${root.path}/network-helper';
    if (helper) File(path).writeAsStringSync('#!/bin/sh\n');
    return LinuxNetwork(
      stateFile: '${root.path}/linux-network.json',
      helper: path,
      run: (executable, arguments) async {
        calls++;
        return _answer(executable, arguments);
      },
      runHelper: (request) async {
        requests.add(request);
        return result();
      },
      permitted: () async => permitted,
      clock: () => now,
    );
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('signagex-network ');
    requests = [];
    calls = 0;
    now = DateTime(2026, 11, 4, 12);
    result = () => ProcessResult(1, 0, '{"phase":"applied","detail":"Connected to \'Office\'."}\n', '');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('nmcli fields unescape colons and backslashes', () {
    expect(LinuxNetwork.fields('a\\:b:c\\\\d:'), ['a:b', 'c\\d', '']);
  });

  test('status reports interfaces, primary route and saved networks without passwords', () async {
    final status = await network().status();
    expect(status['supported'], true);
    expect(status['wifi_hardware'], true);
    expect(status['primary'], {'type': 'ethernet', 'interface': 'enp2s0', 'ip': '192.168.1.125', 'gateway': '192.168.1.1', 'ssid': '', 'signal': null});
    final interfaces = status['interfaces'] as List;
    expect(interfaces.length, 2, reason: 'loopback and p2p devices are not network ports');
    expect(interfaces[0], containsPair('mac', '00:ce:39:d2:0d:85'));
    expect(interfaces[0], containsPair('speed_mbps', 1000));
    expect(interfaces[1], allOf(containsPair('ssid', 'Baig: 1000H'), containsPair('signal', 67), containsPair('ip', '192.168.1.140'), containsPair('speed_mbps', null)));
    expect(status['saved'], [
      {'ssid': 'Baig: 1000H', 'active': true, 'security': 'wpa', 'hidden': false},
      {'ssid': 'Guest', 'active': false, 'security': 'open', 'hidden': true},
      {'ssid': 'Corp', 'active': false, 'security': 'enterprise', 'hidden': false},
    ]);
  });

  test('status is cached for a minute so the player does not spawn nmcli every tick', () async {
    final service = network();
    await service.status();
    final first = calls;
    await service.status();
    expect(calls, first);
    now = now.add(const Duration(minutes: 1));
    await service.status();
    expect(calls, greaterThan(first));
  });

  test('unsupported without the group, the helper or NetworkManager', () async {
    expect((await network(permitted: false).status())['supported'], false);
    root.listSync().whereType<File>().forEach((file) => file.deleteSync());
    expect((await network(helper: false).status(force: true))['supported'], false);
  });

  test('a verified job runs the helper once and reports its outcome', () async {
    final service = network();
    final phases = <String>[];
    service.onChange = () => phases.add(service.job!['phase'] as String);
    final job = {'job': 'job-1', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'secret123', 'hidden': false, 'connect': true};
    await service.run(job);
    await service.run(job); // Delivered twice.
    expect(requests.length, 1);
    expect(jsonDecode(requests.single), {'job': 'job-1', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'secret123', 'hidden': false, 'connect': true});
    expect(phases, ['applying', 'applied']);
    final report = await service.report('ba1e8d');
    expect(report, allOf(containsPair('protocol', 'linux_network_v1'), containsPair('player', 'ba1e8d'), containsPair('job', 'job-1'), containsPair('phase', 'applied')));
    expect(jsonEncode(report), isNot(contains('secret123')));
    expect(File('${root.path}/linux-network.json').readAsStringSync(), isNot(contains('secret123')));
  });

  test('helper failure and rollback detail reach the CMS', () async {
    result = () => ProcessResult(1, 0, '{"phase":"failed","detail":"Could not connect to \'Office\' (wrong password or no internet). Restored previous connection."}\n', '');
    final service = network();
    await service.run({'job': 'job-2', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'wrong-pass', 'connect': true});
    expect(service.job!['phase'], 'failed');
    expect(service.job!['detail'], contains('Restored previous connection'));
    result = () => ProcessResult(1, 126, '', 'Not authorized');
    await service.run({'job': 'job-3', 'op': 'wifi_remove', 'ssid': 'Office'});
    expect(service.job!['detail'], 'Not authorized');
  });

  test('a device without permission fails the job without running the helper', () async {
    final service = network(permitted: false);
    await service.run({'job': 'job-4', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'secret123'});
    expect(requests, isEmpty);
    expect(service.job!['phase'], 'failed');
  });

  test('a change interrupted by a player restart is settled as failed', () async {
    File('${root.path}/linux-network.json').writeAsStringSync(jsonEncode({'job': 'job-5', 'op': 'wifi_add', 'ssid': 'Office', 'phase': 'applying', 'detail': ''}));
    final service = network();
    await service.load();
    expect(service.job!['phase'], 'failed');
  });

  test('fingerprint ignores small signal changes but not a new network', () async {
    final report = await network().report('ba1e8d');
    Map<String, dynamic> copy() => jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
    final flicker = copy()..['interfaces'][1]['signal'] = 63;
    final drop = copy()..['interfaces'][1]['signal'] = 35;
    final moved = copy()..['primary']['type'] = 'wifi';
    expect(LinuxNetwork.fingerprint(flicker), LinuxNetwork.fingerprint(report));
    expect(LinuxNetwork.fingerprint(drop), isNot(LinuxNetwork.fingerprint(report)));
    expect(LinuxNetwork.fingerprint(moved), isNot(LinuxNetwork.fingerprint(report)));
  });
}
