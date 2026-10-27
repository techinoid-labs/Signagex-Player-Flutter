#pragma once

#include <cstdint>

// Process exits only: a live but frozen renderer requires a separate heartbeat.
class WatchdogPolicy {
 public:
  static constexpr std::uint64_t kStableRunMs = 10 * 60 * 1000;
  static constexpr unsigned kMaxRestarts = 5;
  // Once the fast restarts are used up. This used to be "give up", which left
  // an unattended screen black until somebody restarted it by hand -- and a
  // crash loop caused by something outside the player (a driver, a network
  // that isn't up yet at boot) can clear on its own, so keep trying, slowly.
  static constexpr unsigned kCooldownSeconds = 5 * 60;

  // Zero means do not restart. Reset the budget after ten stable minutes.
  unsigned DelayAfterExit(std::uint32_t exit_code, std::uint64_t runtime_ms) {
    if (exit_code == 0) return 0;
    if (runtime_ms >= kStableRunMs) failures_ = 0;
    if (failures_ >= kMaxRestarts) return kCooldownSeconds;
    return 5u << failures_++;  // 5, 10, 20, 40, 80 seconds.
  }

 private:
  unsigned failures_ = 0;
};
