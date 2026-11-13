import 'dart:convert';
import 'dart:io';

/// Serializes snapshots so concurrent proof-of-play records cannot overwrite a
/// newer queue or race on the same temporary file. Errors remain observable;
/// a failed write does not prevent later writes from being attempted.
class LinuxAtomicJson {
  Future<void> _writes = Future.value();
  Future<void> write(File file, Object value) {
    final snapshot = jsonEncode(value);
    final result = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.part');
      try {
        await temporary.writeAsString(snapshot, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }
}
