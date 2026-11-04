import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:digital_signage/services/linux_asset_cache.dart';
void main() {
  test('concurrent fetches share a transfer and a cached file works offline', () async {
    final directory=await Directory.systemTemp.createTemp('signagex-cache-test-');
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    var requests=0;
    server.listen((request) async { requests++; request.response.add([1,2,3,4]); await request.response.close(); });
    try {
      final cache=LinuxAssetCache(directory:directory,maxBytes:100);
      final url='http://127.0.0.1:${server.port}/test.png';
      final paths=await Future.wait([cache.fetch(url),cache.fetch(url)]);
      expect(paths[0],paths[1]); expect(requests,1);
      await server.close(force:true);
      expect(await cache.fetch(url),paths[0]);
      expect(await File(paths[0]!).readAsBytes(),[1,2,3,4]);
    } finally { await server.close(force:true); await directory.delete(recursive:true); }
  });
  test('oversized media does not leave a usable partial file', () async {
    final directory=await Directory.systemTemp.createTemp('signagex-cache-test-');
    final server=await HttpServer.bind(InternetAddress.loopbackIPv4,0);
    server.listen((request) async { request.response.add(List.filled(20,1)); await request.response.close(); });
    try {
      final cache=LinuxAssetCache(directory:directory,maxBytes:10);
      await expectLater(cache.fetch('http://127.0.0.1:${server.port}/test.png'),throwsStateError);
      expect(await directory.list().toList(),isEmpty);
    } finally { await server.close(force:true); await directory.delete(recursive:true); }
  });
}
