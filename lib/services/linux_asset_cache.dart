import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'linux_configuration.dart';

/// A file is playable only after its complete transfer and integrity record
/// have been atomically committed. Legacy basename downloads are not trusted.
class LinuxAssetCache {
  static final instance = LinuxAssetCache();
  static final media = LinuxAssetCache(directory: Directory(
      '${Platform.environment['HOME']}/.local/share/signagex-player/media-cache'));
  LinuxAssetCache({this.directory, this.maxBytes = 2 * 1024 * 1024 * 1024});
  final Directory? directory;
  final int maxBytes;
  final Map<String, Future<String?>> _pending = {};
  Future<void> _operations = Future.value();

  Directory get _root => directory ?? Directory(
      '${Platform.environment['HOME']}/.local/share/signagex-player/trigger-cache');

  String _name(String url) {
    final extension = RegExp(r'\.([a-zA-Z0-9]{1,8})$')
        .firstMatch(Uri.parse(url).path)?[1] ?? 'media';
    return '${sha256.convert(utf8.encode(url))}.$extension';
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final result = _operations.then((_) => action());
    _operations = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> retain(Set<String> urls) => _exclusive(() async {
    final root = _root;
    if (!await root.exists()) return;
    final names = urls.expand((url) => [_name(url), '${_name(url)}.json']).toSet();
    await for (final entry in root.list()) {
      if (entry is File && !names.contains(entry.uri.pathSegments.last)) {
        await entry.delete();
      }
    }
  });

  /// A new publication can request a fresh transfer even if its URL is reused.
  /// Failed refreshes preserve the previous bytes but never acknowledge them as
  /// the new content. Normal offline reads verify the saved digest first.
  Future<String?> fetch(String url, {bool refresh = false,
      void Function(int received, int total)? onProgress}) {
    final key = '$refresh:$url';
    final existing = _pending[key];
    if (existing != null) return existing;
    final future = _exclusive(() => _fetch(url, refresh, onProgress));
    _pending[key] = future;
    future.then<void>((_) { _pending.remove(key); },
        onError: (Object _, StackTrace __) { _pending.remove(key); });
    return future;
  }

  Future<bool> _valid(File file, File metadata, String url) async {
    try {
      final record = jsonDecode(await metadata.readAsString()) as Map;
      if (record['url'] != url || record['size'] != await file.length() ||
          record['size'] == 0) return false;
      return record['sha256'] == (await sha256.bind(file.openRead()).first).toString();
    } catch (_) { return false; }
  }

  Future<String?> _fetch(String url, bool refresh,
      void Function(int received, int total)? onProgress) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !['https', 'http'].contains(uri.scheme)) return url;
    final root = _root;
    await root.create(recursive: true);
    final file = File('${root.path}/${_name(url)}');
    final metadata = File('${file.path}.json');
    if (!refresh && await _valid(file, metadata, url)) return file.path;
    if (!await LinuxConfiguration.instance
        .allowsDownload(checkInterval: false, destination: url)) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final temporary = File('${file.path}.part');
    final record = File('${metadata.path}.part');
    IOSink? sink;
    try {
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw StateError('Media HTTP ${response.statusCode}');
      // HttpClient reports the wire length even when it transparently
      // decompresses gzip. Compare only lengths in the representation we save.
      final expected = response.compressionState == HttpClientResponseCompressionState.decompressed
          ? -1 : response.contentLength;
      if (expected > maxBytes) throw StateError('Asset exceeds cache size limit');
      var bytes = 0;
      await for (final entry in root.list()) {
        if (entry is File) bytes += await entry.length();
      }
      final reservation = expected > 0 ? expected : maxBytes;
      if (bytes + reservation > 4 * 1024 * 1024 * 1024) {
        throw StateError('Media cache limit reached; remove unused content');
      }
      final disk = (await LinuxConfiguration.runCommand('df', ['-Pk', root.path]))
          .trim().split('\n').last.trim().split(RegExp(r'\s+'));
      if (int.parse(disk[3]) * 1024 < reservation + 512 * 1024 * 1024) {
        throw StateError('Insufficient space for media');
      }
      sink = temporary.openWrite();
      var total = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        total += chunk.length;
        if (total > maxBytes) throw StateError('Asset exceeds cache size limit');
        sink.add(chunk);
        onProgress?.call(total, expected);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (total == 0 || (expected >= 0 && total != expected)) {
        throw StateError('Incomplete media transfer');
      }
      final digest = (await sha256.bind(temporary.openRead()).first).toString();
      await record.writeAsString(jsonEncode({
        'url': url, 'size': total, 'sha256': digest,
      }), flush: true);
      await temporary.rename(file.path);
      await record.rename(metadata.path);
      return file.path;
    } finally {
      client.close(force: true);
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      if (await record.exists()) await record.delete();
    }
  }
}
