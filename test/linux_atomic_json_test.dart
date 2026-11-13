import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:digital_signage/services/linux_atomic_json.dart';

void main() {
  test('concurrent snapshots persist the latest queue without temporary races', () async {
    final directory = await Directory.systemTemp.createTemp('signagex-spool-');
    try {
      final store = LinuxAtomicJson();
      final file = File('${directory.path}/queue.json');
      await Future.wait([for (var i = 0; i < 100; i++) store.write(file, {'sequence': i})]);
      expect(jsonDecode(await file.readAsString()), {'sequence': 99});
      expect(await File('${file.path}.part').exists(), isFalse);
    } finally { await directory.delete(recursive: true); }
  });
  test('a failed write is reported and does not poison future persistence', () async {
    final directory = await Directory.systemTemp.createTemp('signagex-spool-');
    try {
      final store = LinuxAtomicJson();
      final blocker = File('${directory.path}/blocker');
      await blocker.writeAsString('not a directory');
      await expectLater(store.write(File('${blocker.path}/queue.json'), {}), throwsA(isA<FileSystemException>()));
      final valid = File('${directory.path}/queue.json');
      await store.write(valid, {'sequence': 1});
      expect(jsonDecode(await valid.readAsString()), {'sequence': 1});
    } finally { await directory.delete(recursive: true); }
  });
}
