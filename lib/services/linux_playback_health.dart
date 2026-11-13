/// Monotonic progress tracking, independent of a controller implementation.
/// Intentional pauses, completed clips and newly activated players reset the
/// deadline. Buffering gets a longer grace period than a stalled decoder.
class LinuxPlaybackHealth {
  Duration? _position;
  int? _lastProgress;
  int recoveries = 0;

  bool sample({required int now, required Duration position,
      required bool expectedToPlay, bool buffering = false}) {
    if (!expectedToPlay) {
      _position = null;
      _lastProgress = null;
      recoveries = 0;
      return false;
    }
    if (_position != position || _lastProgress == null) {
      _position = position;
      _lastProgress = now;
      recoveries = 0;
      return false;
    }
    final deadline = buffering ? 180000 : 45000;
    if (now - _lastProgress! < deadline) return false;
    _lastProgress = now; // rate-limit recovery attempts
    recoveries++;
    return true;
  }
}
