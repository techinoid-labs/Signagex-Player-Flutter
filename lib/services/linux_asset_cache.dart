import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'linux_configuration.dart';

class LinuxAssetCache {
  static final instance = LinuxAssetCache();
  LinuxAssetCache({this.directory, this.maxBytes = 2 * 1024 * 1024 * 1024});
  final Directory? directory;
  final int maxBytes;
  final Map<String, Future<String?>> _pending = {};
  Future<void> retain(Set<String> urls) async {
    final root = directory ??
        Directory(
            '${Platform.environment['HOME']}/.local/share/signagex-player/trigger-cache');
    if (!await root.exists()) return;
    final names = urls.map((url) {
      final uri = Uri.parse(url);
      final extension =
          RegExp(r'\.([a-zA-Z0-9]{1,8})$').firstMatch(uri.path)?[1] ?? 'media';
      return '${sha256.convert(utf8.encode(url))}.$extension';
    }).toSet();
    await for (final entry in root.list()) {
      if (entry is File &&
          !entry.path.endsWith('.part') &&
          !names.contains(entry.uri.pathSegments.last)) await entry.delete();
    }
  }

  Future<String?> fetch(String url) {
    final existing = _pending[url];
    if (existing != null) return existing;
    final future = _fetch(url);
    _pending[url] = future;
    future.then<void>((_) {
      _pending.remove(url);
    }, onError: (Object _, StackTrace __) {
      _pending.remove(url);
    });
    return future;
  }

  Future<String?> _fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return url;
    final directory = this.directory ??
        Directory(
            '${Platform.environment['HOME']}/.local/share/signagex-player/trigger-cache');
    await directory.create(recursive: true);
    final extension =
        RegExp(r'\.([a-zA-Z0-9]{1,8})$').firstMatch(uri.path)?[1] ?? 'media';
    final file = File(
        '${directory.path}/${sha256.convert(utf8.encode(url))}.$extension');
    if (await file.exists() && await file.length() > 0) return file.path;
    if (!await LinuxConfiguration.instance
        .allowsDownload(checkInterval: false, destination: url)) return null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    final temporary = File('${file.path}.part');
    IOSink? sink;
    try {
      final request = await client.getUrl(uri);
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      final files = await directory
          .list()
          .where((entry) => entry is File && !entry.path.endsWith('.part'))
          .cast<File>()
          .toList();
      var bytes = 0;
      for (final cached in files) {
        bytes += await cached.length();
      }
      if (bytes +
              (response.contentLength > 0 ? response.contentLength : maxBytes) >
          4 * 1024 * 1024 * 1024)
        throw StateError(
            'Trigger cache limit reached; remove unused trigger content');
      final disk =
          (await LinuxConfiguration.runCommand('df', ['-Pk', directory.path]))
              .split('\n')
              .last
              .trim()
              .split(RegExp(r'\s+'));
      if (int.parse(disk[3]) * 1024 <
          (response.contentLength > 0 ? response.contentLength : maxBytes) +
              512 * 1024 * 1024)
        throw StateError('Insufficient space for trigger media');
      if (response.statusCode != 200)
        throw StateError('Trigger media HTTP ${response.statusCode}');
      sink = temporary.openWrite();
      var total = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        total += chunk.length;
        if (total > maxBytes) throw StateError('Trigger asset exceeds 2 GB');
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total == 0) throw StateError('Empty trigger asset');
      await temporary.rename(file.path);
      return file.path;
    } finally {
      client.close(force: true);
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
