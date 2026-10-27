#include "../runner/watchdog_policy.h"
#include <cstdlib>
#include <iostream>

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}

int main() {
  WatchdogPolicy policy;
  Check(policy.DelayAfterExit(0, 1000) == 0, "normal close must not restart");
  for (unsigned delay : {5u, 10u, 20u, 40u, 80u}) {
    Check(policy.DelayAfterExit(0xc0000005, 1000) == delay,
          "crash backoff must increase");
  }
  Check(policy.DelayAfterExit(1, 1000) == WatchdogPolicy::kCooldownSeconds,
        "crash loop must slow to the cooldown, not stop");
  Check(policy.DelayAfterExit(1, WatchdogPolicy::kStableRunMs - 1) ==
            WatchdogPolicy::kCooldownSeconds,
        "short uptime must not reset budget");
  Check(policy.DelayAfterExit(1, WatchdogPolicy::kStableRunMs) == 5,
        "stable uptime must restore restart budget");
  Check(policy.DelayAfterExit(0, WatchdogPolicy::kStableRunMs) == 0,
        "stable normal exit must still stop");
  std::cout << "watchdog policy checks passed\n";
}
