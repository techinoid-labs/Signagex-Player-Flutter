/// Limits retries during a sustained outage without refreshing healthy pages.
class WebPageRetry {
  DateTime? _nextAttempt;
  int _attempts = 0;

  bool shouldRetry(DateTime now) =>
      _nextAttempt == null || !now.isBefore(_nextAttempt!);

  void attempted(DateTime now) {
    const delays = [5, 10, 20, 40, 60];
    final seconds = delays[_attempts.clamp(0, delays.length - 1)];
    _attempts++;
    _nextAttempt = now.add(Duration(seconds: seconds));
  }

  void recovered() {
    _nextAttempt = null;
    _attempts = 0;
  }
}
