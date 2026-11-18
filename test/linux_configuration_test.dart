import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:digital_signage/services/linux_configuration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<List<String>> calls;
  late LinuxConfiguration config;
  // These tests cover the X11 path (xrandr); don't follow the session they run in.
  setUpAll(() => LinuxConfiguration.debugWaylandOverride = false);
  tearDownAll(() => LinuxConfiguration.debugWaylandOverride = null);
  setUp(() {
    SharedPreferences.setMockInitialValues({}); calls=[];
    config = LinuxConfiguration(command:(exe,args) async {
      calls.add([exe,...args]);
      if (exe=='xrandr' && args.first=='--query') return 'HDMI-1 connected primary 1024x600\nHDMI-2 connected 800x600';
      if (exe=='wpctl' && args.first=='get-volume') return 'Volume: 0.40';
      if (exe=='ip') return '1.1.1.1 via 192.168.1.1 dev eth0';
      if (exe=='nmcli') return 'ethernet';
      return '';
    });
  });
  tearDown(()=>config.close());
  test('volume uses audio adapter, never brightness; mute preserves zero', () async {
    final ack=await config.apply({'configuration_revision':1,'volume':0,'mute_audio':true});
    expect(calls,contains(equals(['wpctl','set-volume','@DEFAULT_AUDIO_SINK@','0%'])));
    expect(calls.where((v)=>v.first=='xrandr'),isEmpty);
    expect(ack['results']['volume']['status'],'applied');
  });
  test('CMS null scalar defaults leave controls unconfigured', () async {
    final ack=await config.apply({'configuration_revision':1,'volume':null,'volume_timeout':null,'launch_on_boot':null,'mute_audio':null,'screen_rotation':null});
    expect(ack['results'],isEmpty);
    expect(config.values,isEmpty);
    expect(calls.where((call)=>call.first=='systemctl' || call.first=='xrandr' || (call.first=='wpctl' && call[1]=='set-volume')),isEmpty);
    await config.apply({'configuration_revision':2,'volume':0,'mute_audio':false});
    expect(config.values['volume'],0); expect(config.values['mute_audio'],false);
    await config.apply({'configuration_revision':3,'volume':null});
    expect(config.values['volume'],0);
  });
  test('brightness normalizes percentage and targets one display', () async {
    await config.apply({'configuration_revision':1,'brightness':{'value':50,'mode':'manual'}});
    expect(calls,contains(equals(['xrandr','--output','HDMI-1','--brightness','0.50'])));
  });
  test('bad setting does not block valid sibling, failures are explicit', () async {
    final ack=await config.apply({'configuration_revision':1,'volume':101,'mute_audio':false,'use_html5_webview':true});
    expect(ack['results']['volume']['status'],'failed');
    expect(ack['results']['mute_audio']['status'],'applied');
    expect(ack['results']['use_html5_webview']['status'],'unsupported');
  });
  test('duplicate and stale revisions do not reapply device commands', () async {
    await config.apply({'configuration_revision':3,'volume':20});
    final count=calls.length;
    await config.apply({'configuration_revision':2,'volume':90});
    await config.apply({'configuration_revision':3,'volume':90});
    expect(calls.length,count); expect(config.values['volume'],20);
  });
  test('new registration accepts a lower revision and applies portrait', () async {
    await config.apply({'configuration_revision':8,'screen_rotation':'0'},
      registrationScope:'staging:old-player');
    calls.clear();
    final ack=await config.apply({'configuration_revision':2,'screen_rotation':'90'},
      registrationScope:'production:new-player');
    expect(calls,contains(equals(['xrandr','--output','HDMI-1','--rotate','right'])));
    expect(ack['revision'],2);
    expect(ack['results']['screen_rotation']['value'],'90');
    final count=calls.length;
    await config.apply({'configuration_revision':1,'screen_rotation':'0'});
    expect(calls.length,count);
    expect(config.values['screen_rotation'],'90');
  });
  test('legacy unscoped revision cannot block the current CMS record', () async {
    SharedPreferences.setMockInitialValues({'linux_configuration':jsonEncode({
      'revision':2,'values':{'screen_rotation':'0'},'results':{}})});
    await config.apply({'configuration_revision':2,'screen_rotation':'90'},
      registrationScope:'production:current-player');
    expect(config.values['screen_rotation'],'90');
    expect(config.results['screen_rotation']['value'],'90');
    final stored=jsonDecode((await SharedPreferences.getInstance()).getString('linux_configuration')!);
    expect(stored['registration_scope'],'production:current-player');
  });
  test('registration scope persists and replay protection survives restart', () async {
    await config.apply({'configuration_revision':3,'screen_rotation':'90'},
      registrationScope:'production:current-player');
    config.close();
    config=LinuxConfiguration(command:(exe,args) async {
      calls.add([exe,...args]);
      return exe=='xrandr' && args.first=='--query' ? 'HDMI-1 connected primary 1080x1920' : '';
    });
    await config.start();
    calls.clear();
    await config.apply({'configuration_revision':2,'screen_rotation':'0'},
      registrationScope:'production:current-player');
    expect(config.values['screen_rotation'],'90');
    expect(calls,isEmpty);
  });
  test('data saving blocks downloads; no policy leaves downloads unrestricted', () async {
    await config.start(); expect(await config.allowsDownload(),isTrue);
    await config.apply({'configuration_revision':1,'content_update_interval':{'data_saving_mode':true,'schedule':[]}});
    expect(await config.allowsDownload(),isFalse);
  });
  test('restriction uses route device type, not interface presence', () async {
    await config.apply({'configuration_revision':1,'content_update_interval':{'download_restrictions':'wifi','interval':'realtime'}});
    expect(await config.allowsDownload(),isFalse);
    await config.apply({'configuration_revision':2,'content_update_interval':{'download_restrictions':'wired','interval':'realtime'}});
    expect(await config.allowsDownload(),isTrue);
  });
  test('working hours mute while inactive and restore output on resume', () async {
    await config.apply({'configuration_revision':1,'working_schedule':{'type':'custom','schedule':[{'days':['0000000'],'from':'00:00','to':'00:00'}]}});
    expect(config.working,isFalse);
    expect(calls,contains(equals(['wpctl','set-mute','@DEFAULT_AUDIO_SINK@','1'])));
    await config.apply({'configuration_revision':2,'working_schedule':{'type':'always','schedule':[]}});
    expect(config.working,isTrue);
    expect(calls.last,equals(['wpctl','set-mute','@DEFAULT_AUDIO_SINK@','0']));
  });
  test('restores persisted rotation and an expired volume timeout after restart', () async {
    SharedPreferences.setMockInitialValues({'linux_configuration':jsonEncode({'revision':4,'values':{'screen_rotation':'90','volume':10},'results':{},'volume_restore':{'value':40,'until':'2020-01-01T00:00:00Z'}})});
    await config.start();
    expect(calls,contains(equals(['xrandr','--output','HDMI-1','--rotate','right'])));
    expect(calls.last,equals(['wpctl','set-volume','@DEFAULT_AUDIO_SINK@','40%']));
  });
  test('a scheduled reboot is persisted before execution and is not repeated', () async {
    config.close();
    final now=DateTime(2026,11,2,3);
    config=LinuxConfiguration(clock:()=>now,command:(exe,args) async { calls.add([exe,...args]); return ''; });
    await config.apply({'configuration_revision':1,'reboot':{'day':'daily','time':'03:00'}});
    await config.tick();
    expect(calls.where((call)=>call.first=='systemctl').length,1);
  });

  group('no screen detected', () {
    // A stateful xrandr: outputs stay as the commands leave them.
    late Map<String, Map<String, dynamic>> outputs;
    late List<Map<String, dynamic>> reports;
    String query() => outputs.entries.map((e) {
      final o = e.value;
      final geometry = o['mode'] == null ? '' : ' ${o['mode']}+0+0';
      final rotation = o['mode'] == null || o['rotate'] == 'normal' ? '' : ' ${o['rotate']}';
      return '${e.key} ${o['connected'] ? 'connected' : 'disconnected'}${o['primary'] == true ? ' primary' : ''}$geometry$rotation (normal left inverted right x axis y axis)';
    }).join('\n');
    LinuxConfiguration screens() => LinuxConfiguration(command: (exe, args) async {
      calls.add([exe, ...args]);
      if (exe != 'xrandr') return '';
      if (args.first == '--query') return query();
      if (args.first == '--output') {
        final o = outputs[args[1]]!;
        if (args.contains('--off')) o['mode'] = null;
        if (args.contains('--mode')) o['mode'] = '1920x1080';
        if (args.contains('--primary')) {
          for (final other in outputs.values) {
            other['primary'] = false;
          }
          o['primary'] = true;
        }
        if (args.contains('--rotate')) o['rotate'] = args[args.indexOf('--rotate') + 1];
      }
      return '';
    });
    Map<String, dynamic> port({bool connected = false, String? mode}) =>
        {'connected': connected, 'mode': mode, 'rotate': 'normal', 'primary': false};
    setUp(() {
      config.close();
      outputs = {'DP-1': port(), 'HDMI-1': port(), 'HDMI-2': port()};
      reports = [];
      config = screens()..report = (ack) async => reports.add(ack);
    });
    tearDown(() => LinuxConfiguration.debugKioskOverride = null);

    test('xrandr output lines parse with size, primary and rotation', () {
      final parsed = XOutput.parse('Screen 0: minimum 320 x 200, current 1080 x 1920\n'
          'HDMI-1 connected primary 1080x1920+0+0 right (normal left inverted right x axis y axis) 0mm x 0mm\n'
          '   1920x1080     60.00*\n'
          'HDMI-2 disconnected (normal left inverted right x axis y axis)\n'
          'DP-1 disconnected 1920x1080+1080+0 (normal left inverted right x axis y axis)');
      expect(parsed.map((o) => o.name), ['HDMI-1', 'HDMI-2', 'DP-1']);
      expect(parsed[0].connected && parsed[0].primary && parsed[0].active, isTrue);
      expect([parsed[0].width, parsed[0].height, parsed[0].rotation], [1080, 1920, 'right']);
      expect(parsed[1].active, isFalse);
      expect([parsed[2].connected, parsed[2].active, parsed[2].rotation], [false, true, 'normal']);
      expect(XOutput.pick(parsed)!.name, 'HDMI-1');
      expect(XOutput.pick(parsed.skip(1).toList())!.name, 'DP-1');
    });

    test('the kiosk drives HDMI at 1080p and still turns the screen to portrait', () async {
      LinuxConfiguration.debugKioskOverride = true;
      final ack = await config.apply({'configuration_revision': 1, 'screen_rotation': '90'});
      expect(calls, contains(equals(['xrandr', '--addmode', 'HDMI-1', LinuxConfiguration.fallbackMode])));
      expect(calls, contains(equals(['xrandr', '--output', 'HDMI-1', '--mode', LinuxConfiguration.fallbackMode, '--primary'])));
      expect(outputs['HDMI-1']!['rotate'], 'right');
      expect(ack['results']['screen_rotation']['status'], 'applied');
      expect(outputs['DP-1']!['mode'], isNull);
    });

    test('the kiosk keeps a 1080p screen even with no rotation set', () async {
      LinuxConfiguration.debugKioskOverride = true;
      await config.start();
      expect(outputs['HDMI-1']!['mode'], '1920x1080');
      calls.clear();
      await config.tick();
      expect(calls.where((c) => c.contains('--addmode')), isEmpty, reason: 'already running');
    });

    test('outside the kiosk a rotation waits for a screen, then applies and reports', () async {
      LinuxConfiguration.debugKioskOverride = false;
      final ack = await config.apply({'configuration_revision': 1, 'screen_rotation': '90'});
      expect(ack['results']['screen_rotation']['status'], 'pending');
      expect(config.values['screen_rotation'], '90');
      expect(outputs.values.every((o) => o['mode'] == null), isTrue);
      outputs['HDMI-2'] = port(connected: true, mode: '1920x1080');
      await config.tick();
      expect(outputs['HDMI-2']!['rotate'], 'right');
      expect(config.results['screen_rotation']['status'], 'applied');
      expect(reports.single['results']['screen_rotation']['status'], 'applied');
    });

    test('a real screen replaces the stand-in and gets the rotation too', () async {
      LinuxConfiguration.debugKioskOverride = true;
      await config.apply({'configuration_revision': 1, 'screen_rotation': '90'});
      expect(outputs['HDMI-1']!['mode'], '1920x1080');
      outputs['HDMI-2'] = port(connected: true, mode: '1920x1080');
      await config.tick();
      expect(outputs['HDMI-1']!['mode'], isNull, reason: 'stand-in turned off');
      expect(outputs['HDMI-2']!['rotate'], 'right');
    });

    test('a screen that comes back unrotated is turned again, once', () async {
      LinuxConfiguration.debugKioskOverride = true;
      outputs['HDMI-1'] = port(connected: true, mode: '1920x1080');
      await config.apply({'configuration_revision': 1, 'screen_rotation': '270'});
      expect(outputs['HDMI-1']!['rotate'], 'left');
      outputs['HDMI-1']!['rotate'] = 'normal'; // swapped or re-plugged
      await config.tick();
      expect(outputs['HDMI-1']!['rotate'], 'left');
      calls.clear();
      await config.tick();
      expect(calls.where((c) => c.contains('--rotate')), isEmpty);
    });
  });
}
