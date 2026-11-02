#pragma once
#include <unordered_set>

namespace signagex {
// CEF UI-thread owned. Keep the previous texture while a main document loads
// or fails; child frames must never release its paint gate.
class PageFrameGate {
 public:
  void Begin(int browser) { ready_.erase(browser); }
  void Loaded(int browser, bool success) {
    if (success) ready_.insert(browser);
    else ready_.erase(browser);
  }
  void Close(int browser) { ready_.erase(browser); }
  bool Ready(int browser) const { return ready_.count(browser) != 0; }
 private:
  std::unordered_set<int> ready_;
};
}
