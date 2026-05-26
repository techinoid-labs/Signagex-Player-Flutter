import 'dart:convert';
import 'dart:io';

String _debugLogFilePath() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return '${dir.path}${Platform.pathSeparator}debug-cedef3.log';
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return '${Directory.current.path}${Platform.pathSeparator}debug-cedef3.log';
}

// #region agent log
void agentDebugLog({
  required String location,
  required String message,
  required String hypothesisId,
  Map<String, dynamic>? data,
  String runId = 'pre-fix',
}) {
  try {
    final entry = <String, dynamic>{
      'sessionId': 'cedef3',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'location': location,
      'message': message,
      'hypothesisId': hypothesisId,
      'runId': runId,
      if (data != null) 'data': data,
    };
    File(_debugLogFilePath()).writeAsStringSync(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}
// #endregion
