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
  test('same basename URLs stay distinct and corrupted bytes are fetched again', () async {
    final directory = await Directory.systemTemp.createTemp('signagex-integrity-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      request.response.add(request.uri.path.startsWith('/a/') ? [1, 2] : [3, 4]);
      await request.response.close();
    });
    try {
      final cache = LinuxAssetCache(directory: directory, maxBytes: 100);
      final first = 'http://127.0.0.1:${server.port}/a/video.mp4';
      final second = 'http://127.0.0.1:${server.port}/b/video.mp4';
      final a = await cache.fetch(first);
      final b = await cache.fetch(second);
      expect(a, isNot(b));
      await File(a!).writeAsBytes([9, 9]); // same length, wrong digest
      expect(await cache.fetch(first), a);
      expect(await File(a).readAsBytes(), [1, 2]);
      expect(requests, 3);
      await cache.retain({first});
      expect(await File(a).exists(), isTrue);
      expect(await File('$a.json').exists(), isTrue);
      expect(await File(b!).exists(), isFalse);
    } finally { await server.close(force: true); await directory.delete(recursive: true); }
  });
  test('publication refreshes reused URL; failed refresh keeps the last complete bytes', () async {
    final directory = await Directory.systemTemp.createTemp('signagex-refresh-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var content = [1, 2];
    var fail = false;
    server.listen((request) async {
      request.response.statusCode = fail ? 503 : 200;
      request.response.add(content);
      await request.response.close();
    });
    try {
      final cache = LinuxAssetCache(directory: directory, maxBytes: 100);
      final url = 'http://127.0.0.1:${server.port}/video.mp4';
      final path = (await cache.fetch(url))!;
      content = [3, 4];
      await cache.fetch(url, refresh: true);
      expect(await File(path).readAsBytes(), [3, 4]);
      fail = true;
      await expectLater(cache.fetch(url, refresh: true), throwsStateError);
      expect(await cache.fetch(url), path);
      expect(await File(path).readAsBytes(), [3, 4]);
      expect((await directory.list().toList()).any((f) => f.path.endsWith('.part')), isFalse);
    } finally { await server.close(force: true); await directory.delete(recursive: true); }
  });
  test('gzip transfer length is checked in the saved representation', () async {
    final directory = await Directory.systemTemp.createTemp('signagex-gzip-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final payload = List.filled(1000, 42);
    server.listen((request) async {
      final wire = gzip.encode(payload);
      request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.response.contentLength = wire.length;
      request.response.add(wire);
      await request.response.close();
    });
    try {
      final cache = LinuxAssetCache(directory: directory, maxBytes: 2000);
      final path = await cache.fetch('http://127.0.0.1:${server.port}/compressed.bin');
      expect(await File(path!).readAsBytes(), payload);
    } finally { await server.close(force: true); await directory.delete(recursive: true); }
  });

}
