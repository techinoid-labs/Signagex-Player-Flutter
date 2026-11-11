import 'dart:convert';

/// The backend's periodic re-send (`publish_campaign` with `resend: true`,
/// answering request_playback) repairs a push the screen missed. When its
/// content matches what is stored, it is not a new publish: playback must not
/// restart (Android MqttMessageManager.isSamePlaylist does the same).
///
/// [previousJson] is the stored message (SharedPreferences 'jsonObj').
bool sameContent(String previousJson, Map incoming) {
  try {
    final previous = jsonDecode(previousJson);
    if (previous is! Map) return false;
    if (previous['action'] != incoming['action']) return false;
    return jsonEncode(_canonical(previous['data'])) ==
        jsonEncode(_canonical(incoming['data']));
  } catch (_) {
    return false;
  }
}

/// Key order is not meaningful in JSON objects, so compare sorted.
dynamic _canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}
