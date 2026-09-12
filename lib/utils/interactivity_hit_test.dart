// W22: pure hit-test/match logic extracted out of MqttViewModel so it has
// real regression tests -- the view model itself has too many live side
// effects (MQTT connect, SharedPreferences, platform channels) to safely
// instantiate in a plain unit test, matching every other extraction in this
// codebase (cache_path_utils, url_encoding_utils, time_range_utils).

/// Whether point ([x], [y]) falls within the rectangle described by
/// [regionX]/[regionY]/[regionWidth]/[regionHeight] (inclusive of the
/// boundary).
bool isPointInRegion({
  required double x,
  required double y,
  required double regionX,
  required double regionY,
  required double regionWidth,
  required double regionHeight,
}) {
  return x >= regionX &&
      x <= regionX + regionWidth &&
      y >= regionY &&
      y <= regionY + regionHeight;
}

/// Whether [key] matches any entry in [keyPress], case-insensitively.
bool keyMatches(List<String> keyPress, String key) {
  return keyPress.any((k) => k.toUpperCase() == key.toUpperCase());
}
