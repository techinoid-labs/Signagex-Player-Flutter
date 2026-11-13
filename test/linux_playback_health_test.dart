import 'package:flutter_test/flutter_test.dart';
import 'package:digital_signage/services/linux_playback_health.dart';

void main() {
  test('detects stuck playback but allows buffering and intentional pauses', () {
    final health = LinuxPlaybackHealth();
    bool sample(int time, {bool playing = true, bool buffering = false, int position = 0}) =>
        health.sample(now: time, position: Duration(milliseconds: position),
          expectedToPlay: playing, buffering: buffering);
    expect(sample(0), isFalse);
    expect(sample(44000), isFalse);
    expect(sample(45000), isTrue);
    expect(health.recoveries, 1);
    expect(sample(46000), isFalse);
    expect(sample(90000, buffering: true), isFalse);
    expect(sample(225000, buffering: true), isTrue);
    expect(sample(230000, playing: false), isFalse);
    expect(sample(500000), isFalse);
    expect(health.recoveries, 0);
  });
  test('loop wraps and position changes prove progress', () {
    final health = LinuxPlaybackHealth();
    for (var i = 0; i < 100; i++) {
      expect(health.sample(now: i * 10000, position: Duration(seconds: i % 3),
          expectedToPlay: true), isFalse);
    }
  });
}
