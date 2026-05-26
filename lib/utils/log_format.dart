/// Shortens values for console / debug logs (never dumps full SVG, HTML, or base64).
String formatForLog(dynamic value, {int maxLen = 120}) {
  if (value == null) return 'null';
  final s = value.toString();
  if (s.length <= maxLen) return s;
  if (s.contains('<svg') ||
      s.startsWith('data:image') ||
      s.startsWith('iVBOR') ||
      s.contains('<?xml')) {
    return '<${s.length} chars ${s.contains('<svg') ? 'svg' : 'binary'}>';
  }
  return '${s.substring(0, maxLen)}…(${s.length} chars)';
}

/// Recursively trims strings in debug log payloads.
Map<String, dynamic> sanitizeLogData(Map<String, dynamic> data) {
  final out = <String, dynamic>{};
  for (final e in data.entries) {
    final v = e.value;
    if (v is String) {
      out[e.key] = formatForLog(v);
    } else if (v is Map) {
      out[e.key] = sanitizeLogData(Map<String, dynamic>.from(v));
    } else if (v is List) {
      out[e.key] = v.map((item) {
        if (item is String) return formatForLog(item);
        if (item is Map) {
          return sanitizeLogData(Map<String, dynamic>.from(item));
        }
        return item;
      }).toList();
    } else {
      out[e.key] = v;
    }
  }
  return out;
}
