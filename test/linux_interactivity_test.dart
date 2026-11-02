import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:digital_signage/services/linux_interactivity.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LinuxInteractivity runtime;
  Map<String,dynamic> item(String id,{String action='play'}) => {'id':id,'on_demand':true,'key_press':['Enter'],'touch_region':true,'control':[{'any_region':true}],'triggers':[{'trigger_type':action,'duration':10}]};
  setUp(() { SharedPreferences.setMockInitialValues({}); runtime=LinuxInteractivity(); });
  tearDown(()=>runtime.close());
  test('on demand is gated and definitions can be removed', () async {
    await runtime.replace([item('one')]);
    runtime.allowed=(_)=>false; expect(runtime.activate('one'),isFalse);
    runtime.allowed=(_)=>true; expect(runtime.activate('one'),isTrue);
    await runtime.replace([]); expect(runtime.active,isNull);
  });
  test('keys and touch use the new payload and stop ends playback', () async {
    await runtime.replace([item('one')]);
    expect(runtime.key('enter'),isTrue); runtime.finish();
    expect(runtime.touch(20,20,1024,600),isTrue);
    await runtime.replace([item('one'),item('stop',action:'stop')]);
    expect(runtime.activate('stop'),isTrue); expect(runtime.active,isNull);
  });
  test('propagation preserves activation while controlling input capture', () async {
    await runtime.replace([{...item('one'), 'propagate': true}]);
    expect(runtime.key('Enter', consumeOnly: true), isFalse);
    expect(runtime.active?['item']['id'], 'one');
    expect(runtime.captureRegions(1024, 600), isEmpty);
    await runtime.replace([{...item('one'), 'propagate': false}]);
    expect(runtime.key('Enter', consumeOnly: true), isTrue);
    expect(runtime.captureRegions(1024, 600), [[0.0, 0.0, 1024.0, 600.0]]);
    runtime.allowed = (_) => false;
    expect(runtime.captureRegions(1024, 600), isEmpty);
  });
  test('enqueue waits for boundary' , () async {
    await runtime.replace([item('one',action:'enqueue')]);
    runtime.activate('one'); expect(runtime.active,isNull);
    runtime.boundary(); expect(runtime.active?['item']['id'],'one');
  });
}
