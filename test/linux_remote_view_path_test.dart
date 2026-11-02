import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/services/linux_remote_view.dart';

void main() {
  test('relocated staging bundle uses its own adapter ahead of development', () {
    final root = Directory.systemTemp.createTempSync('signagex bundle ');
    addTearDown(() => root.deleteSync(recursive: true));
    final bundled = File('${root.path}/staging/kiosk/remote_view_agent.py')
      ..createSync(recursive: true);
    final development = File('${root.path}/linux/packaging/kiosk/remote_view_agent.py')
      ..createSync(recursive: true);
    expect(resolveRemoteViewAgent('${root.path}/staging/signagex-player', developmentRoot: root.path)?.path, bundled.path);
    bundled.deleteSync();
    expect(resolveRemoteViewAgent('${root.path}/staging/signagex-player', developmentRoot: root.path)?.path, development.path);
    development.deleteSync();
    expect(resolveRemoteViewAgent('${root.path}/staging/signagex-player', developmentRoot: root.path), isNull);
  });
}
