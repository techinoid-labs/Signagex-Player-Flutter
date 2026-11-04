import 'package:digital_signage/utils/web_page_retry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retries back off and remain capped during sustained failure', () {
    final retry = WebPageRetry();
    var now = DateTime.utc(2026);
    for (final seconds in [5, 10, 20, 40, 60, 60, 60]) {
      expect(retry.shouldRetry(now), isTrue);
      retry.attempted(now);
      expect(retry.shouldRetry(now.add(Duration(seconds: seconds - 1))), isFalse);
      now = now.add(Duration(seconds: seconds));
      expect(retry.shouldRetry(now), isTrue);
    }
  });
  test('recovery resets delay for a later independent failure', () {
    final retry = WebPageRetry();
    final now = DateTime.utc(2026);
    retry.attempted(now);
    retry.attempted(now.add(const Duration(seconds: 5)));
    retry.recovered();
    expect(retry.shouldRetry(now), isTrue);
    retry.attempted(now);
    expect(retry.shouldRetry(now.add(const Duration(seconds: 5))), isTrue);
  });
}
