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

}
