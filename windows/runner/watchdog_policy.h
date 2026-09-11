#pragma once

#include <cstdint>

// Process exits only: a live but frozen renderer requires a separate heartbeat.
class WatchdogPolicy {
 public:
  static constexpr std::uint64_t kStableRunMs = 10 * 60 * 1000;
  static constexpr unsigned kMaxRestarts = 5;

  // Zero means do not restart. Reset the budget after ten stable minutes.
  unsigned DelayAfterExit(std::uint32_t exit_code, std::uint64_t runtime_ms) {
    if (exit_code == 0) return 0;
    if (runtime_ms >= kStableRunMs) failures_ = 0;
    if (failures_ >= kMaxRestarts) return 0;
    return 5u << failures_++;  // 5, 10, 20, 40, 80 seconds.
  }

 private:
  unsigned failures_ = 0;
};
