import 'dart:convert';
import 'dart:io';

import 'package:digital_signage/utils/log_format.dart';
import 'package:flutter/foundation.dart';

String? _resolvedLogPath;

/// NDJSON debug log path (session `cedef3`).
/// Primary: `<project>/debug-cedef3.log`
/// Fallback: `%TEMP%/digital-signage-debug-cedef3.log`
String debugLogFilePath() {
  if (_resolvedLogPath != null) return _resolvedLogPath!;

  final candidates = <String>[];

  var dir = Directory.current;
  for (var i = 0; i < 12; i++) {
    final pubspec = File('${dir.path}${Platform.pathSeparator}pubspec.yaml');
    if (pubspec.existsSync()) {
      candidates.add(
        '${dir.path}${Platform.pathSeparator}debug-cedef3.log',
      );
      break;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  final temp = Platform.environment['TEMP'] ??
      Platform.environment['TMP'] ??
      Directory.systemTemp.path;
  candidates.add(
    '$temp${Platform.pathSeparator}digital-signage-debug-cedef3.log',
  );

  _resolvedLogPath = candidates.first;
  return _resolvedLogPath!;
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
      if (data != null) 'data': sanitizeLogData(data),
    };
    final path = debugLogFilePath();
    File(path).writeAsStringSync(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
    );
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[agentDebugLog] write failed: $e');
    }
  }
}
// #endregion
